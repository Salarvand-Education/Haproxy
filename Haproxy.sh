#!/bin/bash

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Variables
CONFIG_FILE="/etc/haproxy/haproxy.cfg"
RULES_FILE="/etc/haproxy/forward_rules.conf"

# Install HAProxy if not present
install_haproxy() {
    if ! command -v haproxy &>/dev/null; then
        echo -e "${YELLOW}HAProxy not found. Installing...${NC}"
        if apt update && apt install -y haproxy; then
            echo -e "${GREEN}HAProxy installed successfully.${NC}"
        else
            echo -e "${RED}Failed to install HAProxy. Exiting...${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}HAProxy is already installed.${NC}"
    fi
}

# Initialize necessary files
initialize_files() {
    # Create config file if it doesn't exist
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}Creating $CONFIG_FILE...${NC}"
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

    # Create rules file if it doesn't exist
    [[ ! -f "$RULES_FILE" ]] && touch "$RULES_FILE"
}

# Display existing rules
view_rules() {
    echo -e "${BLUE}================================================================================"
    printf "%-10s | %-20s | %-30s\n" "Rule No." "Frontend Port" "Backend Address"
    echo -e "--------------------------------------------------------------------------------${NC}"
    if [[ ! -s "$RULES_FILE" ]]; then
        echo -e "${YELLOW}No forwarding rules found.${NC}"
    else
        nl -w1 -s" | " "$RULES_FILE" | awk -F':' '{
            frontend = $1;
            backend_ip = $2;
            backend_port = $3;
            # Check if backend IP is IPv6 or 6to4 and wrap it in brackets
            if (backend_ip ~ /:/) {
                backend_ip = "[" backend_ip "]";
            }
            printf "%-10s | %-20s | %-30s\n", $1, frontend, backend_ip ":" backend_port
        }' | while read line; do
            echo -e "${CYAN}$line${NC}"
        done
    fi
    echo -e "${BLUE}================================================================================${NC}"
}

# Add a new rule
add_rule() {
    read -p "Enter frontend port: " frontend_port
    read -p "Enter backend IP (IPv4, IPv6, or 6to4): " backend_ip
    read -p "Enter backend port: " backend_port

    if [[ -z "$frontend_port" || -z "$backend_ip" || -z "$backend_port" ]]; then
        echo -e "${RED}All fields are required. Please try again.${NC}"
        return 1
    fi

    # Wrap IPv6 or 6to4 addresses in brackets
    if [[ "$backend_ip" == *":"* ]]; then
        backend_ip="[$backend_ip]"
    fi

    echo "$frontend_port:$backend_ip:$backend_port" >>"$RULES_FILE"
    echo -e "${GREEN}Rule added: Frontend Port $frontend_port -> Backend $backend_ip:$backend_port${NC}"
    restart_haproxy
}

# Delete a rule
delete_rule() {
    view_rules
    read -p "Enter the rule number to delete: " rule_number

    if [[ ! "$rule_number" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid rule number. Please enter a valid number.${NC}"
        return 1
    fi

    if sed -i "${rule_number}d" "$RULES_FILE"; then
        echo -e "${GREEN}Rule deleted successfully.${NC}"
        restart_haproxy
    else
        echo -e "${RED}Failed to delete rule. Check the rule number and try again.${NC}"
    fi
}

# Clear all rules
clear_rules() {
    read -p "Are you sure you want to delete ALL rules? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        truncate -s 0 "$RULES_FILE"
        generate_config
        echo -e "${GREEN}All rules have been deleted, and the configuration has been reset.${NC}"
        restart_haproxy
    else
        echo -e "${YELLOW}Operation canceled.${NC}"
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
        # Wrap IPv6 or 6to4 addresses in brackets for HAProxy
        if [[ "$backend_ip" == *":"* ]]; then
            backend_ip="[$backend_ip]"
        fi
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

    echo -e "${GREEN}HAProxy configuration updated successfully.${NC}"
}

# Restart HAProxy
restart_haproxy() {
    generate_config
    echo -e "${YELLOW}Restarting HAProxy...${NC}"
    if systemctl restart haproxy; then
        echo -e "${GREEN}HAProxy restarted successfully.${NC}"
    else
        echo -e "${RED}Failed to restart HAProxy. Check the configuration or run 'systemctl status haproxy' for more details.${NC}"
    fi
}

# Main menu
install_haproxy
initialize_files

while true; do
    echo -e "${BLUE}========================================"
    echo -e "           ${CYAN}HAProxy Management${NC}${BLUE}"
    echo -e "========================================${NC}"
    echo -e "   ${YELLOW}1)${NC} View forwarding rules"
    echo -e "   ${YELLOW}2)${NC} Add a forwarding rule"
    echo -e "   ${YELLOW}3)${NC} Delete a forwarding rule"
    echo -e "   ${YELLOW}4)${NC} Clear all forwarding rules"
    echo -e "   ${YELLOW}5)${NC} Exit"
    echo -e "${BLUE}========================================${NC}"
    read -p "Select an option: " option

    case $option in
        1) view_rules ;;
        2) add_rule ;;
        3) delete_rule ;;
        4) clear_rules ;;
        5) 
            echo -e "${GREEN}Exiting HAProxy management tool. Goodbye!${NC}"
            break ;;
        *) echo -e "${RED}Invalid option. Please select a valid option from the menu.${NC}" ;;
    esac
done
