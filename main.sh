#!/bin/bash
# --- MHDesign Ultimate Dashboard | Main Core v1.0 ---

# Colors
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

# Paths
MGRE_MODULE="/usr/bin/mgre" # مسیر نهایی اجرای ماژول تانل

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_main_header() {
    local s_ip=$(get_local_ip)
    clear
    echo ""
    
    local str1=" MHDesign Master Core "
    local str2=" IP: $s_ip "
    local str3=" SYSTEM: Active "
    
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} STATUS:${NC}${G} ${str3}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

while true; do
    draw_main_header
    echo ""
    echo -e "  ${DIM}┌─[ MAIN DASHBOARD ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Manager${NC} ${G}(mgre.sh)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${DIM}Port Forwarding Module (Future Porter)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}"
    echo ""
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read opt
    
    case $opt in
        1) 
           # بررسی وجود فایل ماژول تانل قبل از اجرا
           if [ -f "$MGRE_MODULE" ] && [ -x "$MGRE_MODULE" ]; then
               # اجرای ماژول تانل
               $MGRE_MODULE
           elif [ -f "./mgre.sh" ]; then
               bash ./mgre.sh
           else
               echo -e "\n  ${R}● Error: mgre.sh module not found or not installed!${NC}"
               sleep 2
           fi
           ;;
        2) 
           echo -e "\n  ${Y}● This module can be linked to your Porter script later.${NC}"
           sleep 2 
           ;;
        0) clear; exit 0 ;;
    esac
done
