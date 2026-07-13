#!/bin/bash
# --- MDesign Modular Core (mshield.sh) | Zero-Trust Firewall v2.5.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
OBFS_DIR="/etc/mshield/obfs"; SVC_FILE="/etc/systemd/system/mshield-obfs.service"
mkdir -p "$OBFS_DIR" 2>/dev/null

get_local_ip() { local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n'); echo "${ip:-$(hostname -I | awk '{print $1}')}"; }
draw_header() {
    local s_ip=$(get_local_ip); local fw_stat="${DIM}OFFLINE${NC}"; iptables -C INPUT -j MSHIELD >/dev/null 2>&1 && fw_stat="${G}ACTIVE${NC}"
    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} MShield Zero-Trust Firewall 2.5.0 ${B}│${NC} IP: ${W}${s_ip}${NC} ${B}│${NC} FW: ${fw_stat} ${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
}

activate_firewall() {
    iptables -F MSHIELD 2>/dev/null; iptables -X MSHIELD 2>/dev/null; iptables -D INPUT -j MSHIELD 2>/dev/null
    iptables -N MSHIELD; iptables -A MSHIELD -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A MSHIELD -i lo -j ACCEPT; iptables -A MSHIELD -p icmp -j ACCEPT; iptables -A MSHIELD -p tcp --dport 22 -j ACCEPT
    
    for conf in /etc/ml2tp/tunnels/*.conf; do [ -f "$conf" ] && source "$conf" && [ -n "$TUN_PORT" ] && iptables -A MSHIELD -p udp --dport "$TUN_PORT" -j ACCEPT; done
    for conf in /etc/mhysteria/tunnels/*.conf; do [ -f "$conf" ] && source "$conf" && [ "$TYPE" == "2" ] && iptables -A MSHIELD -p udp --dport "$TUN_PORT" -j ACCEPT; done
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && source "$conf" && iptables -A MSHIELD -s "${REMOTE_PUB:-$T_REMOTE}" -j ACCEPT; done
    [ -f "/etc/wireguard/wg0.conf" ] && iptables -A MSHIELD -p udp --dport 51820 -j ACCEPT
    if [ -f "/etc/mweb/web.conf" ]; then source "/etc/mweb/web.conf" 2>/dev/null; [ -n "$WEB_PORT" ] && iptables -A MSHIELD -p tcp --dport "$WEB_PORT" -j ACCEPT; fi
    
    iptables -A MSHIELD -j DROP; iptables -I INPUT 1 -j MSHIELD; mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4
}

disable_firewall() { iptables -D INPUT -j MSHIELD 2>/dev/null; iptables -F MSHIELD 2>/dev/null; iptables -X MSHIELD 2>/dev/null; mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4; }

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Activate Firewall${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Disable Firewall${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit${NC}\n"
    echo -ne "  ${C}MSHIELD ❯❯ ${NC}"; read opt
    case $opt in 1) activate_firewall; echo "Enabled!"; sleep 1 ;; 2) disable_firewall; echo "Disabled!"; sleep 1 ;; 0) break ;; esac
done
