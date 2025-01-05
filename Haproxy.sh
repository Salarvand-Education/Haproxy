#!/bin/bash

CONFIG_FILE="/etc/haproxy/haproxy.cfg"
RULES_FILE="/etc/haproxy/forward_rules.conf"

# نصب HAProxy در صورت عدم وجود
install_haproxy() {
    if ! command -v haproxy &>/dev/null; then
        echo "HAProxy not found. Installing..."
        apt update && apt install -y haproxy
        echo "HAProxy installed successfully."
    fi
}

# ایجاد فایل‌های مورد نیاز در صورت عدم وجود
initialize_files() {
    if [ ! -f "$CONFIG_FILE" ]; then
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

    if [ ! -f "$RULES_FILE" ]; then
        echo "Creating $RULES_FILE..."
        touch "$RULES_FILE"
    fi
}

# نمایش قوانین موجود
view_rules() {
    echo "======================="
    echo " Forwarding Rules"
    echo "======================="
    if [ ! -s "$RULES_FILE" ]; then
        echo "No rules found."
    else
        awk -F':' '{print NR " | Frontend Port: " $1 " | Backend: " $2 ":" $3}' "$RULES_FILE"
    fi
    echo "======================="
}

# افزودن قانون جدید
add_rule() {
    echo "Enter frontend port:"
    read -r frontend_port
    echo "Enter backend IP:"
    read -r backend_ip
    echo "Enter backend port:"
    read -r backend_port

    echo "$frontend_port:$backend_ip:$backend_port" >>"$RULES_FILE"
    echo "Rule added: $frontend_port -> $backend_ip:$backend_port"
    restart_haproxy
}

# حذف قانون
delete_rule() {
    view_rules
    echo "Enter the rule number to delete:"
    read -r rule_number

    if sed -i "${rule_number}d" "$RULES_FILE"; then
        echo "Rule deleted successfully."
        restart_haproxy
    else
        echo "Failed to delete rule. Check the rule number and try again."
    fi
}

# پاکسازی تمام قوانین
clear_rules() {
    echo "Are you sure you want to delete all rules? (yes/no)"
    read -r confirm
    if [ "$confirm" == "yes" ]; then
        sudo >"$RULES_FILE"
        generate_config
        echo "All rules deleted and configuration reset."
        restart_haproxy
    else
        echo "Operation canceled."
    fi
}

# تولید پیکربندی HAProxy
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

# ری‌استارت HAProxy
restart_haproxy() {
    generate_config
    echo "Restarting HAProxy..."
    if systemctl restart haproxy; then
        echo "HAProxy restarted successfully."
    else
        echo "Failed to restart HAProxy. Check the configuration."
    fi
}

# منوی اصلی
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
    echo "Select an option:"
    read -r option

    case $option in
    1) view_rules ;;
    2) add_rule ;;
    3) delete_rule ;;
    4) clear_rules ;;
    5) exit ;;
    *) echo "Invalid option. Please try again." ;;
    esac
done
