#!/bin/bash
# --- MPorter Modular Core (mporter.sh) | MDesign Port Engine v5.1.5 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    echo "${ip:-Unknown}"
}

draw_mporter_header() {
    clear; echo ""
    local s_ip=$(get_local_ip)
    local str1=" MPorter Engine 5.1.5 "
    local str2=" IP: $s_ip "
    local raw_len=$(( ${#str1} + 1 + ${#str2} ))
    local pad_len=$(( 92 - raw_len ))
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

while true; do
    draw_mporter_header
    echo -e "\n  ${DIM}┌─[ MULTIPLEXER CORE ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Configure HAProxy Standard Forwarding / Load Balance${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Configure GOST Advanced Multi-Protocol Routing${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MPorter ❯❯ ${NC}"; read opt
    case $opt in
        1) echo -e "\n  ${G}● HAProxy Management Sub-system Loaded.${NC}; Option to go back: 0"; sleep 1.5 ;;
        2) echo -e "\n  ${M}● GOST Router Engine Sub-system Loaded.${NC}; Option to go back: 0"; sleep 1.5 ;;
        0) break ;;
    esac
done
