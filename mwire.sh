#!/bin/bash
# --- MGRE Modular Sub-Core (mwire.sh) | MDesign Core v1.0.0 (Template) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    clear; echo ""
    local str1=" MWIRE Crypto Matrix v1.0.0 "
    local str2=" IP: $s_ip "
    local raw_len=$(( ${#str1} + 1 + ${#str2} ))
    local pad_len=$(( 92 - raw_len ))
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ WIREGUARD SECURE MATRIX ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Initialize WireGuard Server Core${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Generate Secure Peer Configuration (Client Key)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Show Active Peer Connections (wg show)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Remove Crypto Peer / Turn Off Server${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    echo -ne "  ${G}MWIRE ❯❯ ${NC}"; read opt
    case $opt in
        0) break ;;
    esac
done
