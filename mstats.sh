#!/bin/bash
# --- MDesign Modular Core (mstats.sh) | Bandwidth Radar Matrix v1.0.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mgre/tunnels"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    clear; echo ""
    local str1=" MDesign Bandwidth Radar 1.0 "
    local str2=" IP: $s_ip "
    local padding=$(printf '%*s' "$(( 92 - ${#str1} - 1 - ${#str2} ))" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

render_stats() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No configured tunnels found to evaluate statistics.${NC}"; sleep 1.5; return; fi
    
    echo -e "\n  ${Y}● Live Network Interface Data Transmission Matrix:${NC}"
    echo -e "  ${B}╭────────────────┬────────────────────────────┬────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-14s${NC} ${B}│${NC} ${G}%-26s${NC} ${B}│${NC} ${Y}%-26s${NC} ${B}│${NC}\n" "INTERFACE" "DOWNLOAD (RX)" "UPLOAD (TX)"
    echo -e "  ${B}├────────────────┼────────────────────────────┼────────────────────────────┤${NC}"
    
    for conf in "${configs[@]}"; do
        source "$conf"
        local rx_bytes=0; local tx_bytes=0
        if [ -f "/sys/class/net/$T_NAME/statistics/rx_bytes" ]; then
            rx_bytes=$(cat "/sys/class/net/$T_NAME/statistics/rx_bytes")
            tx_bytes=$(cat "/sys/class/net/$T_NAME/statistics/tx_bytes")
        fi
        
        # تبدیل بایت به گیگابایت با دقت اعشاری بالا
        local rx_gb=$(awk "BEGIN {printf \"%.2f GB\", $rx_bytes/1073741824}")
        local tx_gb=$(awk "BEGIN {printf \"%.2f GB\", $tx_bytes/1073741824}")
        
        printf "  ${B}│${NC} ${C}%-14s${NC} ${B}│${NC} ${W}%-26s${NC} ${B}│${NC} ${W}%-26s${NC} ${B}│${NC}\n" "${T_NAME:0:14}" "$rx_gb" "$tx_gb"
    done
    echo -e "  ${B}╰────────────────┴────────────────────────────┴────────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

while true; do
    draw_header; render_stats; break
done
