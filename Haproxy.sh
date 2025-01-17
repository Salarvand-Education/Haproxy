#!/bin/bash

CONFIG_FILE="/etc/haproxy/haproxy.cfg"
RULES_FILE="/etc/haproxy/forward_rules.conf"

# Install HAProxy if not present
install_haproxy() {
    if ! command -v haproxy &>/dev/null; then
        echo "HAProxy not found. Installing..."
        apt update && apt install -y haproxy
        if [[ $? -eq 0 ]]; then
            echo "HAProxy installed successfully."
        else
            echo "HAProxy installation failed."
            exit 1
        fi
    fi
}

# Create necessary files if they don't exist
initialize_files() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Creating $CONFIG_FILE..."
        cat >"$CONFIG_FILE" <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    ca-base /etc/ssl/certs
    crt-base /etc/ssl/private
    ssl-default-bind-options no-sslv3
    ssl-default-bind-ciphers HIGH:!aNULL:!MD5

defaults
    log     global
    option  tcplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms
EOF
    fi

    [[ ! -f "$RULES_FILE" ]] && touch "$RULES_FILE"
}

# Display existing rules
view_rules() {
    echo "======================="
    echo " Forwarding Rules"
    echo "======================="
    if [[ ! -s "$RULES_FILE" ]]; then
        echo "No rules found."
    else
        nl -w1 -s" | " "$RULES_FILE" | awk -F':' '{print $1 " | Frontend Port: " $2 " | Backend: " $3 ":" $4}'
    fi
    echo "======================="
}

# Add a new rule
add_rule() {
    read -p "Enter frontend port: " frontend_port
    read -p "Enter backend IP: " backend_ip
    read -p "Enter backend port: " backend_port

    if [[ -z "$frontend_port" || -z "$backend_ip" || -z "$backend_port" ]]; then
      echo "All fields are required."
      return 1
    fi

    echo "$frontend_port:$backend_ip:$backend_port" >>"$RULES_FILE"
    echo "Rule added: $frontend_port -> $backend_ip:$backend_port"
    restart_haproxy
}

# Delete a rule
delete_rule() {
    view_rules
    read -p "Enter the rule number to delete: " rule_number

    if [[ ! "$rule_number" =~ ^[0-9]+$ ]]; then
        echo "Invalid rule number."
        return 1
    fi

    if sed -i "${rule_number}d" "$RULES_FILE"; then
        echo "Rule deleted successfully."
        restart_haproxy
    else
        echo "Failed to delete rule. Check the rule number."
    fi
}

# Clear all rules
clear_rules() {
    read -p "Are you sure you want to delete all rules? (yes/no) " confirm
    if [[ "$confirm" == "yes" ]]; then
        truncate -s 0 "$RULES_FILE" #More efficient than >
        generate_config
        echo "All rules deleted and configuration reset."
        restart_haproxy
    else
        echo "Operation canceled."
    fi
}

# Generate HAProxy configuration
generate_config() {
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    cat >"$CONFIG_FILE" <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    ca-base /etc/ssl/certs
    crt-base /etc/ssl/private
    ssl-default-bind-options no-sslv3
    ssl-default-bind-ciphers HIGH:!aNULL:!MD5

defaults
    log     global
    option  tcplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms
EOF

    while IFS=':' read -r frontend backend_ip backend_port; do
        cat >>"$CONFIG_FILE" <<EOF

frontend frontend_$frontend
    bind :::$frontend
    mode tcp
    default_backend backend_$frontend

backend backend_$frontend
    mode tcp
    server server_$frontend $backend_ip:$backend_port check
EOF
    done <"$RULES_FILE"

    echo "Configuration file generated and updated."
}

# Restart HAProxy
restart_haproxy() {
    generate_config
    echo "Restarting HAProxy..."
    if systemctl restart haproxy; then
        echo "HAProxy restarted successfully."
    else
        echo "Failed to restart HAProxy. Check the configuration or HAProxy status: systemctl status haproxy"
    fi
}

# Main menu
install_haproxy
initialize_files

while true; do
    echo "======================="
    echo " HAProxy Management"
    echo "======================="
    echo "1. View rules"
    echo "2. Add forwarding rule"
    echo "3. Delete forwarding rule"
    echo "4. Clear all rules"
    echo "5. Exit"
    echo "======================="
    read -p "Select an option: " option

    case $option in
        1) view_rules ;;
        2) add_rule ;;
        3) delete_rule ;;
        4) clear_rules ;;
        5) break ;; # Exit the loop
        *) echo "Invalid option. Please try again." ;;
    esac
done
