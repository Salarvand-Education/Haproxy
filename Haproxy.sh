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
LOG_FILE="/var/log/haproxy_manager.log"

# Initialize log file
initialize_log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        echo "[$(date)] - Log file created." >>"$LOG_FILE"
    fi
}

# Log a message
log_message() {
    local message="$1"
    echo "[$(date)] - $message" >>"$LOG_FILE"
    echo -e "${CYAN}[$(date)] - $message${NC}"
}

# Install HAProxy if not present
install_haproxy() {
    clear
    if ! command -v haproxy &>/dev/null; then
        log_message "HAProxy not found. Installing..."
        if apt update && apt install -y haproxy; then
            log_message "HAProxy installed successfully."
        else
            log_message "Failed to install HAProxy. Exiting..."
            exit 1
        fi
    else
        log_message "HAProxy is already installed."
    fi
    sleep 2
}

# Initialize necessary files
initialize_files() {
    clear
    # Create config file if it doesn't exist
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_message "Creating $CONFIG_FILE..."
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
    clear
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
    echo -e "${YELLOW}Press Enter to return to the main menu...${NC}"
    read # Wait for user input before returning to the menu
}

# Add a new rule
add_rule() {
    clear
    read -p "Enter frontend port: " frontend_port
    read -p "Enter backend IP (IPv4, IPv6, or 6to4): " backend_ip
    read -p "Enter backend port: " backend_port
    if [[ -z "$frontend_port" || -z "$backend_ip" || -z "$backend_port" ]]; then
        log_message "All fields are required. Please try again."
        return 1
    fi
    # Wrap IPv6 or 6to4 addresses in brackets
    if [[ "$backend_ip" == *":"* ]]; then
        backend_ip="[$backend_ip]"
    fi
    echo "$frontend_port:$backend_ip:$backend_port" >>"$RULES_FILE"
    log_message "Rule added: Frontend Port $frontend_port -> Backend $backend_ip:$backend_port"
    restart_haproxy
}

# Delete a rule
delete_rule() {
    view_rules
    read -p "Enter the rule number to delete: " rule_number
    if [[ ! "$rule_number" =~ ^[0-9]+$ ]]; then
        log_message "Invalid rule number. Please enter a valid number."
        return 1
    fi
    if sed -i "${rule_number}d" "$RULES_FILE"; then
        log_message "Rule deleted successfully."
        restart_haproxy
    else
        log_message "Failed to delete rule. Check the rule number and try again."
    fi
    echo -e "${YELLOW}Press Enter to return to the main menu...${NC}"
    read # Wait for user input before returning to the menu
}

# Clear all rules
clear_rules() {
    clear
    read -p "Are you sure you want to delete ALL rules? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        truncate -s 0 "$RULES_FILE"
        generate_config
        log_message "All rules have been deleted, and the configuration has been reset."
        restart_haproxy
    else
        log_message "Operation canceled."
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
    log_message "HAProxy configuration updated successfully."
}

# Restart HAProxy
restart_haproxy() {
    generate_config
    log_message "Restarting HAProxy..."
    if systemctl restart haproxy; then
        log_message "HAProxy restarted successfully."
    else
        log_message "Failed to restart HAProxy. Check the configuration or run 'systemctl status haproxy' for more details."
    fi
}

# Main menu
initialize_log
install_haproxy
initialize_files
while true; do
    clear
    echo -e "${BLUE}========================================"
    echo -e "           ${CYAN}HAProxy Management${NC}${BLUE}"
    echo -e "========================================${NC}"
    echo -e "   ${YELLOW}1)${NC} View forwarding rules"
    echo -e "   ${YELLOW}2)${NC} Add a forwarding rule"
    echo -e "   ${YELLOW}3)${NC} Delete a forwarding rule"
    echo -e "   ${YELLOW}4)${NC} Clear all forwarding rules"
    echo -e "   ${RED}0)${NC} Exit"
    echo -e "${BLUE}========================================${NC}"
    read -p "Select an option: " option
    case $option in
        1) view_rules ;;
        2) add_rule ;;
        3) delete_rule ;;
        4) clear_rules ;;
        0)
            log_message "Exiting HAProxy management tool. Goodbye!"
            exit 0 ;; # Exit with success code
        *) log_message "Invalid option selected." ;;
    esac
done
