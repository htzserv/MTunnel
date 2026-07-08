#!/bin/bash
# --- MDesign Modular Core (mshield.sh) | Anti-Probing Firewall Shield v1.0.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    clear; echo ""
    local str1=" MDesign Anti-Probing Shield 1.0 "
    local str2=" IP: $s_ip "
    local padding=$(printf '%*s' "$(( 92 - ${#str1} - 1 - ${#str2} ))" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ SECURITY MANAGEMENT ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Activate Stealth Mode (Drop Probing Scans & RST Floods)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Disable Shielding (Allow standard WAN Probes)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MShield ❯❯ ${NC}"; read opt
    case $opt in
        1)
           iptables -A INPUT -p tcp --tcp-flags ALL ACK,RST,SYN,FIN -j DROP 2>/dev/null
           iptables -A INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null
           echo -e "\n  ${G}● Shield Active! Prober packets are now dropped silently.${NC}"; sleep 1.5 ;;
        2)
           iptables -D INPUT -p tcp --tcp-flags ALL ACK,RST,SYN,FIN -j DROP 2>/dev/null
           iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null
           echo -e "\n  ${Y}● Shield Deactivated. Standard network probing allowed.${NC}"; sleep 1.5 ;;
        0) exit 0 ;;
    esac
done
