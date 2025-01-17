#!/bin/bash

# Set strict error handling
set -euo pipefail

# Configuration files
CONFIG_FILE="/etc/haproxy/haproxy.cfg"
RULES_FILE="/etc/haproxy/forward_rules.conf"
BACKUP_DIR="/etc/haproxy/backups"
LOG_FILE="/var/log/haproxy_manager.log"

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

# Helper Functions
command_exists() {
    type "$1" &>/dev/null
}

validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log "Invalid port: $port (must be 1-65535)"
        return 1
    fi
    return 0
}

validate_ip() {
    local ip=$1 version=$2
    case "$version" in
        ipv4)
            if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                log "Invalid IPv4 format: $ip"
                return 1
            fi
            IFS='.' read -ra octets <<< "$ip"
            for octet in "${octets[@]}"; do
                if [ "$octet" -gt 255 ] || [ "$octet" -lt 0 ]; then
                    log "Invalid IPv4 octet value in: $ip"
                    return 1
                fi
            done
            ;;
        ipv6)
            if [[ ! $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
                log "Invalid IPv6 format: $ip"
                return 1
            fi
            ;;
        *)
            log "Invalid IP version: $version"
            return 1
            ;;
    esac
    return 0
}

# Installation and Setup
setup_haproxy() {
    if ! command_exists haproxy; then
        log "Installing HAProxy..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy || {
            log "Failed to install HAProxy"
            exit 1
        }
    fi
    
    mkdir -p "$BACKUP_DIR"
    touch "$RULES_FILE"
    chmod 600 "$CONFIG_FILE" "$RULES_FILE"
}

# Configuration Management
update_config() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$CONFIG_FILE" "${BACKUP_DIR}/haproxy_${timestamp}.cfg"

    {
        cat > "${CONFIG_FILE}.new" <<'EOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 4096

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms
    timeout check   5000ms
EOF

        while IFS=: read -r fport ipver bip bport status || [ -n "$fport" ]; do
            [[ -z "$fport" || "$status" != "active" ]] && continue
            cat >> "${CONFIG_FILE}.new" <<EOF

frontend front_${fport}
    bind *:${fport}
    mode tcp
    default_backend back_${fport}

backend back_${fport}
    mode tcp
    balance roundrobin
    option tcp-check
    server server_${fport} ${bip}:${bport} check inter 2000 rise 2 fall 3
EOF
        done < "$RULES_FILE"
    }

    if haproxy -c -f "${CONFIG_FILE}.new"; then
        mv "${CONFIG_FILE}.new" "$CONFIG_FILE"
        log "Configuration updated successfully"
        return 0
    else
        rm -f "${CONFIG_FILE}.new"
        log "Configuration validation failed"
        return 1
    fi
}

# Rule Management
list_rules() {
    log "\n=== Current Forwarding Rules ==="
    if [ ! -s "$RULES_FILE" ]; then
        log "No rules configured."
        return 0
    fi

    printf "%-4s %-12s %-6s %-20s %-8s %-8s\n" "No." "Front Port" "IP Ver" "Back IP" "Back Port" "Status"
    echo "-------------------------------------------------------------"
    
    local n=0
    while IFS=: read -r fport ipver bip bport status || [ -n "$fport" ]; do
        printf "%-4d %-12s %-6s %-20s %-8s %-8s\n" "$((++n))" \
            "${fport:-0}" \
            "${ipver:-ipv4}" \
            "${bip:-unknown}" \
            "${bport:-0}" \
            "${status:-disable}"
    done < "$RULES_FILE"
    log "=============================="
}

# Add similar modifications to `add_rule`, `delete_rule`, `check_status`, and `main_menu` as required.

# Script Entry Point
{
    exec 200>/var/lock/haproxy_manager.lock
    flock -n 200 || { log "Another instance is running"; exit 1; }
    setup_haproxy
    main_menu
}
