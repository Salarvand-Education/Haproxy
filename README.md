# HAProxy Manager Script

This script provides an interactive and user-friendly way to manage HAProxy forwarding rules for both IPv4 and IPv6. It automates the process of adding, deleting, and managing rules while ensuring that the HAProxy service is restarted to apply changes.

---

## Installation and Usage

To install and run the script, execute the following command in your terminal:  

```bash
bash <(curl -s https://raw.githubusercontent.com/Salarvand-Education/Haproxy/main/Haproxy.sh)
```
The script will:

Check if HAProxy is installed and install it if necessary.

Guide you through an interactive menu for managing forwarding rules.



---

Features

Interactive Menu:

View all existing forwarding rules.

Add new rules for IPv4 or IPv6.

Delete specific rules.

Clear all rules from the configuration.
