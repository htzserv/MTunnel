#!/bin/bash
# --- MDesign Modular Core (mshield.sh) | Stealth Anti-Probing & Anti-RST Shield v3.0.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_FILE="/etc/mshield/shield.conf"
mkdir -p /etc/mshield 2>/dev/null

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    local sh_stat="${DIM}DISABLED${NC}"
    if [ -f "$CONF_FILE" ] && grep -q "SHIELD_ENABLED=true" "$CONF_FILE"; then sh_stat="${G}ACTIVE (Anti-RST + NOTRACK)${NC}"; fi
    clear; echo ""
    local str1=" Stealth Anti-Probing & Anti-RST Shield 3.0.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Shield:${NC} ${sh_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

enable_shield() {
    # 1. Drop Inactive RST Packets & Apply NOTRACK
    iptables -t mangle -C OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null
    iptables -t raw -C PREROUTING -p tcp -m multiport --dports 80,443,8443,8888,9443,9643,9743 -j NOTRACK 2>/dev/null || iptables -t raw -A PREROUTING -p tcp -m multiport --dports 80,443,8443,8888,9443,9643,9743 -j NOTRACK 2>/dev/null
    
    # 2. Block Active Port Scanners (SYN Rate Limit)
    iptables -N MSHIELD_PORT_SCAN 2>/dev/null || true
    iptables -C INPUT -p tcp --syn -j MSHIELD_PORT_SCAN 2>/dev/null || iptables -I INPUT -p tcp --syn -j MSHIELD_PORT_SCAN 2>/dev/null
    iptables -F MSHIELD_PORT_SCAN 2>/dev/null
    iptables -A MSHIELD_PORT_SCAN -m limit --limit 25/s --limit-burst 100 -j RETURN 2>/dev/null
    iptables -A MSHIELD_PORT_SCAN -j DROP 2>/dev/null

    echo "SHIELD_ENABLED=true" > "$CONF_FILE"
    echo -e "\n  ${G}● Stealth Shield & Anti-RST Protection Enabled!${NC}"; sleep 1.5
}

disable_shield() {
    iptables -t mangle -D OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || true
    iptables -t raw -D PREROUTING -p tcp -m multiport --dports 80,443,8443,8888,9443,9643,9743 -j NOTRACK 2>/dev/null || true
    iptables -D INPUT -p tcp --syn -j MSHIELD_PORT_SCAN 2>/dev/null || true
    iptables -F MSHIELD_PORT_SCAN 2>/dev/null || true
    iptables -X MSHIELD_PORT_SCAN 2>/dev/null || true

    rm -f "$CONF_FILE"
    echo -e "\n  ${Y}● Stealth Shield Disabled.${NC}"; sleep 1.5
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ SECURITY & FIREWALL ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Enable Stealth Shield (Anti-RST + Drop Probing Scans)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Disable Shield & Restore Default Kernel Flags${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}SHIELD ❯❯ ${NC}"; read opt
    case $opt in
        1) enable_shield ;; 2) disable_shield ;; 0) break ;;
    esac
done
