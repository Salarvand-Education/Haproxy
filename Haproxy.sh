#!/bin/bash

set -euo pipefail  # Enable strict error handling

CONFIG_FILE="/etc/haproxy/haproxy.cfg"
RULES_FILE="/etc/haproxy/forward_rules.conf"
BACKUP_DIR="/etc/haproxy/backups"

# Validate root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Helper function for input validation
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "Invalid port number: $port (must be between 1-65535)" >&2
        return 1
    fi
    return 0
}

validate_ip() {
    local ip=$1
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Invalid IP address format: $ip" >&2
        return 1
    fi
    return 0
}

# Installation and initialization
install_haproxy() {
    if ! command -v haproxy &>/dev/null; then
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

# Configuration management
generate_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$CONFIG_FILE" "${BACKUP_DIR}/haproxy_${timestamp}.cfg"

    {
        cat "$CONFIG_FILE" | grep -E '^(global|defaults|$)'
        while IFS=':' read -r frontend backend_ip backend_port; do
            [ -z "$frontend" ] && continue
            cat <<EOF

frontend front_${frontend}
    bind :::${frontend} v4v6
    mode tcp
    default_backend back_${frontend}

backend back_${frontend}
    mode tcp
    balance roundrobin
    option tcp-check
    server server_${frontend} ${backend_ip}:${backend_port} check inter 2000 rise 2 fall 3
EOF
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

restart_haproxy() {
    echo "Restarting HAProxy..."
    systemctl restart haproxy || {
        echo "Failed to restart HAProxy!" >&2
        return 1
    }
    systemctl status haproxy --no-pager
}

# Rule management functions
view_rules() {
    echo -e "\n=== Current Forwarding Rules ==="
    if [ ! -s "$RULES_FILE" ]; then
        echo "No rules configured."
    else
        awk -F':' '
            BEGIN {printf "%-4s %-15s %-15s %-8s\n", "No.", "Front Port", "Back IP", "Back Port"}
            {printf "%-4d %-15s %-15s %-8s\n", NR, $1, $2, $3}
        ' "$RULES_FILE"
    fi
    echo "=============================="
}

add_rule() {
    local frontend_port backend_ip backend_port

    while true; do
        read -rp "Frontend port: " frontend_port
        validate_port "$frontend_port" && break
    done

    while true; do
        read -rp "Backend IP: " backend_ip
        validate_ip "$backend_ip" && break
    done

    while true; do
        read -rp "Backend port: " backend_port
        validate_port "$backend_port" && break
    done

    # Check for duplicate frontend port
    if grep -q "^${frontend_port}:" "$RULES_FILE"; then
        echo "Error: Frontend port $frontend_port already exists" >&2
        return 1
    fi

    echo "${frontend_port}:${backend_ip}:${backend_port}" >> "$RULES_FILE"
    generate_config && restart_haproxy
}

delete_rule() {
    view_rules
    local rule_number
    read -rp "Enter rule number to delete: " rule_number

    if [[ "$rule_number" =~ ^[0-9]+$ ]] && [ -n "$(sed -n "${rule_number}p" "$RULES_FILE")" ]; then
        sed -i "${rule_number}d" "$RULES_FILE"
        generate_config && restart_haproxy
        echo "Rule deleted successfully."
    else
        echo "Invalid rule number." >&2
        return 1
    fi
}

# Service management functions
check_status() {
    echo -e "\n=== HAProxy Status ==="
    if systemctl is-active haproxy >/dev/null 2>&1; then
        echo "Status: Running ✓"
        echo -e "\nProcess Information:"
        ps aux | grep -v grep | grep haproxy

        echo -e "\nPort Bindings:"
        netstat -tulpn 2>/dev/null | grep haproxy

        echo -e "\nCurrent Connections:"
        echo "show stat" | socat unix-connect:/run/haproxy/admin.sock stdio 2>/dev/null | cut -d ',' -f 1,2,5,7,8 | column -s, -t || echo "Unable to get connection stats"

        echo -e "\nSystem Resources:"
        top -b -n 1 | grep haproxy || echo "No resource usage data available"

        echo -e "\nLast 5 Log Entries:"
        journalctl -u haproxy -n 5 --no-pager
    else
        echo "Status: Stopped ✗"
        echo "HAProxy is not running!"
    fi
    echo "======================="
}

manage_service() {
    local action=$1
    echo -e "\nExecuting: $action HAProxy..."
    
    case $action in
        "restart")
            systemctl restart haproxy
            ;;
        "start")
            systemctl start haproxy
            ;;
        "stop")
            systemctl stop haproxy
            ;;
        *)
            echo "Invalid action!" >&2
            return 1
            ;;
    esac

    if [ $? -eq 0 ]; then
        echo "Operation successful!"
        systemctl status haproxy --no-pager
    else
        echo "Operation failed!" >&2
        return 1
    fi
}

# Main menu function
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
                [[ "${confirm,,}" == "y" ]] && : > "$RULES_FILE" && generate_config && restart_haproxy
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
                    1) manage_service "start" ;;
                    2) manage_service "stop" ;;
                    3) manage_service "restart" ;;
                    4) continue ;;
                    *) echo "Invalid option!" ;;
                esac
                ;;
            7) exit 0 ;;
            *) echo "Invalid option!" ;;
        esac
    done
}

# Main script execution
{
    install_haproxy
    initialize_files
    main_menu
}
