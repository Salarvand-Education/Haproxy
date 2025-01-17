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

# Installation
install_haproxy() {
    if ! command_exists haproxy; then
        echo "Installing HAProxy..."
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy
        mkdir -p "$BACKUP_DIR"
    fi
}

# Initialize Configuration
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

# Status Function
check_status() {
    echo -e "\n=== HAProxy Status Check ===\n"
    
    if ! command_exists haproxy; then
        echo "❌ HAProxy is not installed"
        return 1
    fi

    if systemctl is-active --quiet haproxy; then
        echo "✓ HAProxy Service: Running"
        
        local pid=$(pgrep haproxy | head -n 1)
        if [[ -n "$pid" ]]; then
            echo -e "\n-- Process Information --"
            ps -p "$pid" -o pid,ppid,user,%cpu,%mem,start,time,cmd | head -n 1
            ps -p "$pid" -o pid,ppid,user,%cpu,%mem,start,time,cmd | tail -n 1
        fi

        if command_exists netstat; then
            echo -e "\n-- Active Port Bindings --"
            netstat -tlnp 2>/dev/null | grep haproxy | awk '{print $4}' | sort -n | \
                while read -r port; do
                    echo "Listening on: $port"
                done
        fi

        echo -e "\n-- Memory Usage --"
        free -h | grep -E "^Mem|^Swap" | awk '{print $1 ": " $3 " used of " $2}'

        echo -e "\n-- Version Information --"
        haproxy -v | head -n 1

        echo -e "\n-- Configuration Check --"
        if haproxy -c -f "$CONFIG_FILE" >/dev/null 2>&1; then
            echo "✓ Configuration syntax is valid"
            echo "✓ Current rules in use: $(wc -l < "$RULES_FILE")"
        else
            echo "❌ Configuration has errors"
        fi
        
        echo -e "\n-- Current Connections --"
        if [ -S /run/haproxy/admin.sock ]; then
            echo "show stat" | socat unix-connect:/run/haproxy/admin.sock stdio 2>/dev/null | \
            cut -d',' -f1,2,5,18 | column -s, -t
        else
            echo "Stats socket not available"
        fi
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
        while IFS=: read -r port address backend status; do
            [ -z "$port" ] && continue
            cat <<EOF

frontend front_${port}
    bind *:${port}
    mode tcp
    default_backend back_${port}

backend back_${port}
    mode tcp
    balance roundrobin
    option tcp-check
    server server_${port} ${address:-127.0.0.1}:${backend:-80} check inter 2000 rise 2 fall 3
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

# Rule Management
view_rules() {
    echo -e "\n=== Current Forwarding Rules ==="
    if [ ! -s "$RULES_FILE" ]; then
        echo "No rules configured."
    else
        # Header
        printf "%-4s %-8s %-15s %-15s %-10s\n" "No." "Port" "Local Address" "Backend" "Status"
        printf "%s\n" "------------------------------------------------"
        
        # Read and display each rule
        local n=0
        while IFS=: read -r port address backend status; do
            [ -z "$port" ] && continue
            status=${status:-unknown}
            printf "%-4d %-8s %-15s %-15s %-10s\n" "$((++n))" \
                "$port" \
                "${address:-unknown}" \
                "${backend:-unknown}" \
                "$status"
        done < "$RULES_FILE"
    fi
    echo "=============================="
}

add_rule() {
    local port address backend

    while true; do
        read -rp "Port: " port
        validate_port "$port" && break
    done

    read -rp "Local Address [press Enter for default]: " address
    address=${address:-unknown}

    read -rp "Backend [press Enter for default]: " backend
    backend=${backend:-unknown}

    if grep -q "^${port}:" "$RULES_FILE"; then
        echo "Error: Port $port already exists" >&2
        return 1
    fi

    echo "${port}:${address}:${backend}:unknown" >> "$RULES_FILE"
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
