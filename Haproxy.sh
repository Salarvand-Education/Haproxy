#!/bin/bash

set -euo pipefail  # Enable strict error handling

CONFIG_FILE="/etc/haproxy/haproxy.cfg"
RULES_FILE="/etc/haproxy/forward_rules.conf"
BACKUP_DIR="/etc/haproxy/backups"

# Previous functions remain the same until main_menu...

# New function for detailed status
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

# Modified restart function with more options
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

# Modified main menu with new options
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

# Script initialization
install_haproxy
initialize_files
main_menu
