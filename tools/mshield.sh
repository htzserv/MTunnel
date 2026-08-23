#!/bin/bash
# --- MDesign Modular Core (mshield.sh) | Zero-Trust Firewall v3.1.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'

OBFS_DIR="/etc/mshield/obfs"
SVC_FILE="/etc/systemd/system/mshield-obfs.service"
mkdir -p "$OBFS_DIR" 2>/dev/null

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    local fw_stat="${DIM}OFFLINE${NC}"
    if iptables -C INPUT -j MSHIELD >/dev/null 2>&1; then fw_stat="${G}ACTIVE${NC}"; fi
    local obfs_stat="${DIM}OFFLINE${NC}"
    if systemctl is-active --quiet mshield-obfs.service 2>/dev/null; then obfs_stat="${C}RCVR ACTIVE${NC}"; fi

    clear; echo ""
    local str1=" MShield Zero-Trust Warden 3.1.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 39 )); [ "$pad_len" -lt 0 ] && pad_len=0; local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} Firewall:${NC} ${fw_stat} ${DIM}│ Kharej:${NC} ${obfs_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

activate_firewall() {
    echo -e "\n  ${DIM}● Scanning MDesign ecosystem for active configurations...${NC}"
    iptables -D INPUT -j MSHIELD >/dev/null 2>&1
    iptables -F MSHIELD >/dev/null 2>&1; iptables -X MSHIELD >/dev/null 2>&1
    iptables -N MSHIELD

    iptables -A MSHIELD -i lo -j ACCEPT
    iptables -A MSHIELD -m state --state RELATED,ESTABLISHED -j ACCEPT

    local ssh_port=$(ss -tlnp 2>/dev/null | grep -i sshd | awk '{print $4}' | rev | cut -d: -f1 | rev | head -n 1)
    [ -z "$ssh_port" ] && ssh_port=22
    iptables -A MSHIELD -p tcp --dport "$ssh_port" -j ACCEPT
    echo -e "  ${G}✔${NC} Secured SSH Management Port (${ssh_port})"

    local peer_ips=""
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf; do 
        if [ -f "$conf" ]; then
            local r_ip=$(grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$conf" | grep -vE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.)' | head -n 1)
            [ -n "$r_ip" ] && peer_ips="$peer_ips $r_ip\n"
        fi
    done
    if [ -n "$peer_ips" ]; then
        local unique_peers=$(echo -e "$peer_ips" | sort -u | grep -v '^$')
        for pip in $unique_peers; do
            iptables -A MSHIELD -s "$pip" -j ACCEPT
            echo -e "  ${G}✔${NC} Whitelisted Core Peer IP: ${C}$pip${NC}"
        done
    fi

    local fw_ports=""
    [ -f "/etc/haproxy/haproxy.cfg" ] && fw_ports+=$(awk '/frontend ft_/ {print $2}' /etc/haproxy/haproxy.cfg | sed 's/ft_//')"\n"

    if [ -f "$OBFS_DIR/server_main.conf" ]; then
        local obfs_p=$(grep -oP '://:\K[0-9]+' "$OBFS_DIR/server_main.conf" | head -n 1)
        [ -n "$obfs_p" ] && fw_ports+="${obfs_p}\n"
    fi

    if [ -n "$fw_ports" ]; then
        local unique_ports=$(echo -e "$fw_ports" | sort -n -u | grep -v '^$')
        for port in $unique_ports; do
            iptables -A MSHIELD -p tcp --dport "$port" --syn -m limit --limit 25/s --limit-burst 100 -j ACCEPT
            iptables -A MSHIELD -p udp --dport "$port" -j ACCEPT
            iptables -A MSHIELD -p tcp --dport "$port" --syn -j DROP
            iptables -A MSHIELD -p tcp --dport "$port" -j ACCEPT
        done
        echo -e "  ${G}✔${NC} Secured Active Ports with Anti-Flood & UDP Access."
    fi

    iptables -A MSHIELD -p gre -j DROP
    iptables -A MSHIELD -p udp --dport 4789 -j DROP
    iptables -A MSHIELD -p tcp -m tcp --dport 1:65535 --tcp-flags SYN,RST,ACK SYN -m recent --name M_SCANNER --set -j ACCEPT
    iptables -A MSHIELD -m recent --name M_SCANNER --rcheck --seconds 3600 --hitcount 8 -j DROP
    iptables -A MSHIELD -p icmp --icmp-type echo-request -j DROP
    iptables -A MSHIELD -p tcp --syn -j DROP

    iptables -I INPUT 1 -j MSHIELD
    echo -e "\n  ${G}● Zero-Trust Shield Activated Successfully!${NC}"; sleep 2
}

disable_firewall() {
    echo -e "\n  ${Y}● Disarming network defense lines...${NC}"
    while iptables -D INPUT -j MSHIELD >/dev/null 2>&1; do :; done
    iptables -F MSHIELD 2>/dev/null; iptables -X MSHIELD 2>/dev/null
    echo -e "  ${G}● Firewall deactivated. Standard WAN probing allowed.${NC}"; sleep 1.5
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ FIREWALL & SECURITY ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Activate Zero-Trust Firewall${NC}  ${DIM}(Auto-Protect Open Ports)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Disable Firewall${NC}              ${DIM}(Revert to open WAN)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MShield ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1) activate_firewall ;; 2) disable_firewall ;; 0) exit 0 ;;
    esac
done
