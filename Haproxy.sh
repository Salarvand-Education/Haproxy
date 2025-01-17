#!/bin/bash

# Set strict error handling
set -euo pipefail

# Configuration files
CONFIG_FILE="/etc/haproxy/haproxy.cfg"
RULES_FILE="/etc/haproxy/forward_rules.conf"
BACKUP_DIR="/etc/haproxy/backups"

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Helper Functions
command_exists() {
    command -v "$1" &>/dev/null
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

validate_ip() {
    local ip=$1 version=$2
    
    case "$version" in
        ipv4)
            [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && IFS='.' read -ra octets <<< "$ip" && \
            [[ "${octets[@]}" =~ ^([0-9]+ ){3}[0-9]+$ ]] && \
            [[ "${octets[@]}" =~ ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5]) ){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]]
            ;;
        ipv6)
            [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]
            ;;
        *)
            echo "Invalid IP version" >&2
            return 1
            ;;
    esac
}

# Installation and Setup
setup_haproxy() {
    if ! command_exists haproxy; then
        echo "Installing HAProxy..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy
    fi
    
    mkdir -p "$BACKUP_DIR"
    touch "$RULES_FILE"
    chmod 600 "$CONFIG_FILE" "$RULES_FILE"
}

# Configuration Management
update_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$CONFIG_FILE" "${BACKUP_DIR}/haproxy_${timestamp}.cfg"

    {
        cat <<'EOF'
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

        while IFS=: read -r fport ipver bip bport status; do
            [[ -z "$fport" || "$status" != "active" ]] && continue
            cat <<EOF

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
    } > "${CONFIG_FILE}.new"

    if haproxy -c -f "${CONFIG_FILE}.new"; then
        mv "${CONFIG_FILE}.new" "$CONFIG_FILE"
        echo "Configuration updated successfully"
        return 0
    else
        rm -f "${CONFIG_FILE}.new"
        echo "Configuration validation failed" >&2
        return 1
    fi
}

# Rule Management
list_rules() {
    echo -e "\n=== Current Forwarding Rules ==="
    if [[ ! -s "$RULES_FILE" ]]; then
        echo "No rules configured."
        return 0
    fi

    printf "%-4s %-12s %-6s %-20s %-8s %-8s\n" "No." "Front Port" "IP Ver" "Back IP" "Back Port" "Status"
    echo "-------------------------------------------------------------"
    
    local n=0
    while IFS=: read -r fport ipver bip bport status; do
        printf "%-4d %-12s %-6s %-20s %-8s %-8s\n" "$((++n))" \
            "${fport:-0}" \
            "${ipver:-ipv4}" \
            "${bip:-unknown}" \
            "${bport:-0}" \
            "${status:-disable}"
    done < "$RULES_FILE"
    echo "=============================="
}

add_rule() {
    local fport ipver bip bport status

    while true; do
        read -rp "Front port: " fport
        validate_port "$fport" && break
    done

    if grep -q "^${fport}:" "$RULES_FILE"; then
        echo "Error: Port $fport already exists" >&2
        return 1
    fi

    while true; do
        read -rp "IP version (ipv4/ipv6) [ipv4]: " ipver
        ipver=${ipver:-ipv4}
        [[ "$ipver" =~ ^(ipv4|ipv6)$ ]] && break
        echo "Please enter 'ipv4' or 'ipv6'" >&2
    done

    while true; do
        read -rp "Backend IP: " bip
        validate_ip "$bip" "$ipver" && break
    done

    while true; do
        read -rp "Backend port: " bport
        validate_port "$bport" && break
    done

    read -rp "Status (active/disable) [active]: " status
    status=${status:-active}
    [[ "$status" =~ ^(active|disable)$ ]] || status="disable"

    echo "${fport}:${ipver}:${bip}:${bport}:${status}" >> "$RULES_FILE"
    echo "Rule added successfully"
    update_config && systemctl reload haproxy
}

delete_rule() {
    list_rules
    local rule_number
    read -rp "Enter rule number to delete: " rule_number

    if [[ "$rule_number" =~ ^[0-9]+$ ]] && [[ -n $(sed -n "${rule_number}p" "$RULES_FILE") ]]; then
        sed -i "${rule_number}d" "$RULES_FILE"
        echo "Rule deleted successfully"
        update_config && systemctl reload haproxy
    else
        echo "Invalid rule number" >&2
        return 1
    fi
}

check_status() {
    echo -e "\n=== HAProxy Status ==="
    
    if ! systemctl is-active --quiet haproxy; then
        echo "❌ Service: Stopped"
        return 1
    fi

    echo "✓ Service: Running"
    
    # Process info
    local pid
    pid=$(pgrep -o haproxy) || true
    if [[ -n "$pid" ]]; then
        echo -e "\n-- Process Info --"
        ps -p "$pid" -o pid,ppid,%cpu,%mem,start,time,cmd
    fi

    # Active ports
    echo -e "\n-- Active Ports --"
    netstat -tlnp 2>/dev/null | grep haproxy || echo "No active ports"

    # Configuration
    echo -e "\n-- Configuration --"
    if haproxy -c -f "$CONFIG_FILE" >/dev/null 2>&1; then
        echo "✓ Config valid"
        echo "Active rules: $(grep -c "^.*:.*:.*:.*:active$" "$RULES_FILE" || echo 0)"
    else
        echo "❌ Config invalid"
    fi

    echo "========================="
}

# Service Management
manage_service() {
    local action=$1
    echo "Executing: $action HAProxy..."
    
    if systemctl "$action" haproxy; then
        echo "Operation successful"
        systemctl status haproxy --no-pager
        return 0
    else
        echo "Operation failed" >&2
        return 1
    fi
}

# Main Menu
main_menu() {
    while true; do
        echo -e "\n=== HAProxy Management ==="
        echo "1. List rules"
        echo "2. Add rule"
        echo "3. Delete rule"
        echo "4. Clear rules"
        echo "5. Check status"
        echo "6. Service control"
        echo "7. Exit"
        echo "======================="
        
        read -rp "Select option: " option
        case $option in
            1) list_rules ;;
            2) add_rule ;;
            3) delete_rule ;;
            4) 
                read -rp "Clear all rules? [y/N]: " confirm
                [[ "${confirm,,}" == "y" ]] && : > "$RULES_FILE" && update_config
                ;;
            5) check_status ;;
            6)
                echo -e "\nService Control:"
                echo "1. Start"
                echo "2. Stop"
                echo "3. Restart"
                echo "4. Back"
                read -rp "Select: " service_option
                case $service_option in
                    1) manage_service start ;;
                    2) manage_service stop ;;
                    3) manage_service restart ;;
                    4) continue ;;
                    *) echo "Invalid option" ;;
                esac
                ;;
            7) exit 0 ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# Script Entry Point
{
    setup_haproxy
    main_menu
}
