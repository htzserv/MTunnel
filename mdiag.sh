#!/bin/bash
# --- MDesign Modular Core (mdiag.sh) | Network Diagnostics v1.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mgre/tunnels"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    clear; echo ""
    local str1=" MDiag Health Scanner "
    local str2=" IP: $s_ip "
    local raw_len=$(( ${#str1} + 1 + ${#str2} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

run_diagnostics() {
    draw_header
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "\n  ${R}● No tunnels configured for diagnostics.${NC}"; sleep 2; return
    fi

    echo -e "\n  ${Y}● Running Deep Ping Diagnostics (10 Packets per Tunnel)... Please Wait.${NC}"
    echo -e "  ${B}╭────────────────┬────────────────────┬───────────┬──────────────┬──────────────┬────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-14s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} ${W}%-9s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-6s${NC} ${B}│${NC}\n" "TUNNEL" "REMOTE IP" "LOSS %" "AVG LATENCY" "JITTER (dev)" "STATUS"
    echo -e "  ${B}├────────────────┼────────────────────┼───────────┼──────────────┼──────────────┼────────┤${NC}"

    for conf in "${configs[@]}"; do
        source "$conf"
        local main_tip=$([ "$TYPE" == "1" ] && echo "10.76.${TUN_ID}.2" || echo "10.76.${TUN_ID}.1")
        
        # ارسال ۱۰ پکت برای بررسی پایداری خط
        local ping_stats=$(ping -c 10 -i 0.2 -q "$main_tip" 2>/dev/null)
        
        local loss="100%"
        local avg_lat="---"
        local jitter="---"
        local status_icon="${R}● FAIL${NC}"
        local color="${DIM}"

        if [ -n "$ping_stats" ]; then
            loss=$(echo "$ping_stats" | grep -oP '\d+(?=% packet loss)')
            [ -z "$loss" ] && loss="100"
            
            if [ "$loss" -lt 100 ]; then
                local rtt=$(echo "$ping_stats" | tail -1 | awk '{print $4}')
                if [[ "$rtt" == *"/"* ]]; then
                    avg_lat=$(echo "$rtt" | cut -d '/' -f 2 | awk '{printf "%.1f", $1}')"ms"
                    jitter=$(echo "$rtt" | cut -d '/' -f 4 | awk '{printf "%.1f", $1}')"ms"
                fi
                
                if [ "$loss" -eq 0 ]; then status_icon="${G}● GOOD${NC}"; color="${G}"
                elif [ "$loss" -le 20 ]; then status_icon="${Y}● WARN${NC}"; color="${Y}"
                else status_icon="${R}● BAD${NC}"; color="${R}"; fi
                
                loss="${loss}%"
            fi
        fi

        local t_name_short="${T_NAME:0:14}"
        printf "  ${B}│${NC} ${C}%-14s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${color}%-9s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} %b%-15s%b ${B}│${NC}\n" "$t_name_short" "$main_tip" "$loss" "$avg_lat" "$jitter" "" "$status_icon" "${NC}"
    done
    echo -e "  ${B}╰────────────────┴────────────────────┴───────────┴──────────────┴──────────────┴────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

while true; do run_diagnostics; break; done
