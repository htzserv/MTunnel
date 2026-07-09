#!/bin/bash
# --- MGRE Modular Sub-Core (mxlan.sh) | MDesign Core v1.0.0 (Template) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    clear; echo ""
    local str1=" MXLAN Fabric v1.0.0 "
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
    echo -e "\n  ${DIM}┌─[ VXLAN LAYER-2 FABRIC ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${M}Deploy New VXLAN Interface (VNI Mesh)${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${W}Bridge Interface Status & MAC Table${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Destroy VXLAN Interface${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    echo -ne "  ${M}MXLAN ❯❯ ${NC}"; read opt
    case $opt in
        0) break ;;
    esac
done
