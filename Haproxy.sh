#!/bin/bash

CONFIG_FILE="/etc/haproxy/haproxy.cfg"
RULES_FILE="/etc/haproxy/forward_rules.conf"
BACKUP_DIR="/etc/haproxy/backups"

# Validate root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Helper Functions
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "Invalid port number: $port (must be between 1-65535)" >&2
        return 1
    fi
    return 0
}

validate_ip() {
    local ip=$1 version=$2
    
    if [[ "$version" == "ipv4" ]]; then
        if ! [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "Invalid IPv4 format" >&2
            return 1
        fi
        local IFS='.'
        read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [ $i -lt 0 ] || [ $i -gt 255 ]; then
                echo "Invalid IPv4 octet value" >&2
                return 1
            fi
        done
    elif [[ "$version" == "ipv6" ]]; then
        if ! [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
            echo "Invalid IPv6 format" >&2
            return 1
        fi
    else
        echo "Invalid IP version specified" >&2
        return 1
    fi
    return 0
}

# Installation Functions
install_haproxy() {
    if ! command_exists haproxy; then
        echo "Installing HAProxy..."
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy
        mkdir -p "$BACKUP_DIR"
    fi
}

initialize_files() {
    local default_config=$(cat <<'EOF'
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
    tune.ssl.default-dh-param 2048

    ca-base /etc/ssl/certs
    crt-base /etc/ssl/private
    ssl-default-bind-options no-sslv3
    ssl-default-bind-ciphers ECDH+AESGCM:DH+AESGCM:ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES:RSA+AESGCM:RSA+AES:!aNULL:!MD5:!DSS

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    option  tcp-smart-accept
    option  tcp-smart-connect
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms
    timeout check   5000ms
EOF
)
    [ ! -f "$CONFIG_FILE" ] && echo "$default_config" > "$CONFIG_FILE"
    [ ! -f "$RULES_FILE" ] && touch "$RULES_FILE"
    chmod 600 "$CONFIG_FILE" "$RULES_FILE"
}

check_status() {
    echo -e "\n=== HAProxy Service Status ===\n"
    
    if ! command_exists haproxy; then
        echo "❌ HAProxy is not installed"
        return 1
    fi

    if systemctl is-active --quiet haproxy; then
        echo "✓ HAProxy Service: Running"
        
        # Process info
        echo -e "\n-- Process Information --"
        ps aux | grep "[h]aproxy" || echo "No HAProxy process found"
        
        # Port bindings
        echo -e "\n-- Active Ports --"
        netstat -tlnp 2>/dev/null | grep haproxy || echo "No active ports found"
        
        # Config validation
        echo -e "\n-- Configuration --"
        if haproxy -c -f "$CONFIG_FILE" >/dev/null 2>&1; then
            echo "✓ Configuration valid"
            echo "Total rules: $(wc -l < "$RULES_FILE")"
        else
            echo "❌ Configuration invalid"
        fi

        # Service uptime
        echo -e "\n-- Uptime --"
        systemctl status haproxy --no-pager | grep "Active:"
    else
        echo "❌ HAProxy Service: Stopped"
    fi
    
    echo -e "\n==========================="
}

# Service Management
manage_service() {
    local action=$1
    echo -e "\nExecuting: $action HAProxy..."
    
    systemctl "$action" haproxy
    
    if [ $? -eq 0 ]; then
        echo "Operation successful!"
        systemctl status haproxy --no-pager
    else
        echo "Operation failed!" >&2
        return 1
    fi
}

# Configuration Management
generate_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$CONFIG_FILE" "${BACKUP_DIR}/haproxy_${timestamp}.cfg"

    {
        cat "$CONFIG_FILE" | grep -E '^(global|defaults|$)'
        while IFS=: read -r fport ipver bip bport status; do
            [ -z "$fport" ] && continue
            if [ "$status" == "active" ]; then
                cat <<EOF

frontend front_${fport}
    bind ${ipver}@:${fport}
    mode tcp
    default_backend back_${fport}

backend back_${fport}
    mode tcp
    balance roundrobin
    option tcp-check
    server server_${fport} ${bip}:${bport} check inter 2000 rise 2 fall 3
EOF
            fi
        done < "$RULES_FILE"
    } > "${CONFIG_FILE}.new"

    if haproxy -c -f "${CONFIG_FILE}.new"; then
        mv "${CONFIG_FILE}.new" "$CONFIG_FILE"
        return 0
    else
        rm "${CONFIG_FILE}.new"
        echo "Configuration validation failed!" >&2
        return 1
    fi
}

# Rule Management
view_rules() {
    echo -e "\n=== Current Forwarding Rules ==="
    if [ ! -s "$RULES_FILE" ]; then
        echo "No rules configured."
    else
        printf "%-4s %-12s %-6s %-20s %-8s %-8s\n" "No." "Front Port" "IP Ver" "Back IP" "Back Port" "Status"
        printf "%s\n" "-------------------------------------------------------------"
        
        local n=0
        while IFS=: read -r fport ipver bip bport status; do
            [ -z "$fport" ] && continue
            status=${status:-disable}
            printf "%-4d %-12s %-6s %-20s %-8s %-8s\n" "$((++n))" \
                "$fport" \
                "${ipver:-ipv4}" \
                "${bip:-unknown}" \
                "${bport:-0}" \
                "$status"
        done < "$RULES_FILE"
    fi
    echo "=============================="
}

add_rule() {
    local fport ipver bip bport status

    while true; do
        read -rp "Front port: " fport
        validate_port "$fport" && break
    done

    while true; do
        read -rp "IP version (ipv4/ipv6): " ipver
        if [[ "$ipver" == "ipv4" || "$ipver" == "ipv6" ]]; then
            break
        fi
        echo "Please enter either 'ipv4' or 'ipv6'"
    done

    while true; do
        read -rp "Backend IP: " bip
        validate_ip "$bip" "$ipver" && break
    done

    while true; do
        read -rp "Backend port: " bport
        validate_port "$bport" && break
    done

    while true; do
        read -rp "Status (active/disable) [active]: " status
        status=${status:-active}
        if [[ "$status" == "active" || "$status" == "disable" ]]; then
            break
        fi
        echo "Please enter either 'active' or 'disable'"
    done

    if grep -q "^${fport}:" "$RULES_FILE"; then
        echo "Error: Front port $fport already exists" >&2
        return 1
    fi

    echo "${fport}:${ipver}:${bip}:${bport}:${status}" >> "$RULES_FILE"
    echo "Rule added successfully."
    generate_config && manage_service restart
}

delete_rule() {
    view_rules
    local rule_number
    read -rp "Enter rule number to delete: " rule_number

    if [[ "$rule_number" =~ ^[0-9]+$ ]] && [ -n "$(sed -n "${rule_number}p" "$RULES_FILE")" ]; then
        sed -i "${rule_number}d" "$RULES_FILE"
        generate_config && manage_service restart
        echo "Rule deleted successfully."
    else
        echo "Invalid rule number." >&2
        return 1
    fi
}

# Main Menu
main_menu() {
    while true; do
        echo -e "\n=== HAProxy Management ==="
        echo "1. View rules"
        echo "2. Add rule"
        echo "3. Delete rule"
        echo "4. Clear all rules"
        echo "5. Service status"
        echo "6. Service control"
        echo "7. Exit"
        echo "======================="
        
        read -rp "Select option: " option
        case $option in
            1) view_rules ;;
            2) add_rule ;;
            3) delete_rule ;;
            4) 
                read -rp "Clear all rules? [y/N]: " confirm
                [[ "${confirm,,}" == "y" ]] && : > "$RULES_FILE" && generate_config && manage_service restart
                ;;
            5) check_status ;;
            6)
                echo -e "\nService Control Options:"
                echo "1. Start HAProxy"
                echo "2. Stop HAProxy"
                echo "3. Restart HAProxy"
                echo "4. Back to main menu"
                
                read -rp "Select option: " service_option
                case $service_option in
                    1) manage_service start ;;
                    2) manage_service stop ;;
                    3) manage_service restart ;;
                    4) continue ;;
                    *) echo "Invalid option!" ;;
                esac
                ;;
            7) exit 0 ;;
            *) echo "Invalid option!" ;;
        esac
    done
}

# Main Script Execution
{
    install_haproxy
    initialize_files
    main_menu
}
