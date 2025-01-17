#!/bin/bash

CONFIG_FILE="/etc/haproxy/haproxy.cfg"
RULES_FILE="/etc/haproxy/forward_rules.conf"

install_haproxy() {
    command -v haproxy &>/dev/null || (echo "Installing HAProxy..." && apt update && apt install -y haproxy && echo "HAProxy installed.")
}

init_files() {
    [ ! -f "$CONFIG_FILE" ] && echo "Creating $CONFIG_FILE..." && cat >"$CONFIG_FILE" <<EOF
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
    ssl-default-bind-ciphers HIGH:!aNULL:!MD5 no-sslv3

defaults
    log global
    option tcplog
    option dontlognull
    timeout connect 5s
    timeout client 50s
    timeout server 50s
EOF

    [ ! -f "$RULES_FILE" ] && echo "Creating $RULES_FILE..." && touch "$RULES_FILE"
}

view_rules() {
    echo "==== Forwarding Rules ===="
    [ ! -s "$RULES_FILE" ] && echo "No rules found." || awk -F':' '{print NR ") " $1 " -> " $2 ":" $3}' "$RULES_FILE"
    echo "=========================="
}

add_rule() {
    read -p "Frontend port: " frontend_port
    read -p "Backend IP: " backend_ip  
    read -p "Backend port: " backend_port
    echo "$frontend_port:$backend_ip:$backend_port" >>"$RULES_FILE"
    echo "Rule added: $frontend_port -> $backend_ip:$backend_port"
    restart_haproxy
}

delete_rule() {
    view_rules
    read -p "Rule to delete (number): " rule_number
    sed -i "${rule_number}d" "$RULES_FILE" && echo "Rule deleted." && restart_haproxy || echo "Failed to delete rule."
}

clear_rules() {
    read -p "Confirm deleting all rules (yes/no): " confirm
    [ "$confirm" == "yes" ] && >"$RULES_FILE" && gen_config && echo "Rules cleared." && restart_haproxy || echo "Cancelled."
}

gen_config() {
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
    ssl-default-bind-ciphers HIGH:!aNULL:!MD5 no-sslv3

defaults
    log global
    option tcplog
    option dontlognull  
    timeout connect 5s
    timeout client 50s
    timeout server 50s
EOF

    while IFS=':' read -r frontend backend_ip backend_port; do
        cat >>"$CONFIG_FILE" <<EOF

frontend fe_$frontend
    bind :::$frontend
    mode tcp
    default_backend be_$frontend  

backend be_$frontend
    mode tcp
    server srv_$frontend $backend_ip:$backend_port check
EOF
    done <"$RULES_FILE"

    echo "Config file updated."  
}

restart_haproxy() {
    gen_config
    echo "Restarting HAProxy..."
    systemctl restart haproxy && echo "HAProxy restarted." || echo "Failed to restart HAProxy."
}

install_haproxy
init_files

while true; do
    echo "==== HAProxy Manager ===="
    echo "1. View rules" 
    echo "2. Add rule"
    echo "3. Delete rule"
    echo "4. Clear rules"
    echo "5. Quit"
    echo "=========================="
    read -p "Select an option: " opt

    case $opt in
        1) view_rules ;;  
        2) add_rule ;;
        3) delete_rule ;;
        4) clear_rules ;;
        5) exit ;;
        *) echo "Invalid option." ;;
    esac
done
