cat << 'EOF_MSTATS' > /usr/bin/mstats
#!/bin/bash
# --- MDesign Modular Core (mstats.sh) | MStats Omni-Radar v1.4.4 (Ghost Counter Integration) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_mstats_header() {
    local s_ip=$(get_local_ip)
    echo ""
    local str1=" MStats Omni-Radar 1.4.4 "
    local str2=" IP: $s_ip "
    local raw_len=$(( ${#str1} + 1 + ${#str2} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

format_speed() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B/s"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B/s"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB/s"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB/s\", $bytes/1048576}"
    else awk "BEGIN {printf \"%.2f GB/s\", $bytes/1073741824}"; fi
}

format_total() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -lt 1099511627776 ]; then awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    else awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"; fi
}

get_iface_rx() {
    local r_base=$(cat /sys/class/net/$1/statistics/rx_bytes 2>/dev/null || echo 0)
    local obfs_rx=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep "OBFS_CNT_RX_$1" | awk '{sum+=$2} END {print sum}')
    [ -n "$obfs_rx" ] && r_base=$((r_base + obfs_rx))
    echo "$r_base"
}

get_iface_tx() {
    local t_base=$(cat /sys/class/net/$1/statistics/tx_bytes 2>/dev/null || echo 0)
    local obfs_tx=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null | grep "OBFS_CNT_TX_$1" | awk '{sum+=$2} END {print sum}')
    [ -n "$obfs_tx" ] && t_base=$((t_base + obfs_tx))
    echo "$t_base"
}

show_live_radar() {
    tput civis; clear; declare -A rx_old tx_old
    while true; do
        printf "\033[H"
        draw_mstats_header
        echo -e "\n  ${DIM}┌─[ UNIFIED TRAFFIC RADAR ]${NC} ${C}(Real-time 1s Auto-Refresh | Press 'q' to stop)${NC}\n"
        echo -e "  ${B}╭──────────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "INTERFACE" "CATEGORY" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL DOWN" "∑ TOTAL UP"
        echo -e "  ${B}├──────────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤${NC}"

        local phys_ifs=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(eth|ens|eno|enp)' | xargs)
        local gre_ifs=""
        for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && source "$conf" && gre_ifs="$gre_ifs $T_NAME"; done
        local vx_ifs=""
        for conf in /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && source "$conf" && vx_ifs="$vx_ifs $BR_NAME"; done
        local wg_ifs=""; [ -f "/etc/wireguard/wg0.conf" ] && wg_ifs="wg0"

        local all_ifs="$phys_ifs $gre_ifs $vx_ifs $wg_ifs"

        for iface in $all_ifs; do
            if [ -z "${rx_old[$iface]}" ] && [ -d "/sys/class/net/$iface" ]; then
                rx_old[$iface]=$(get_iface_rx "$iface"); tx_old[$iface]=$(get_iface_tx "$iface")
            fi
        done

        declare -A rx_new tx_new
        for iface in $all_ifs; do
            [ ! -d "/sys/class/net/$iface" ] && continue
            rx_new[$iface]=$(get_iface_rx "$iface"); tx_new[$iface]=$(get_iface_tx "$iface")
        done

        local active_count=0
        render_category() {
            local cat_name=$1; local cat_color=$2; local if_list=$3
            for iface in $if_list; do
                [ ! -d "/sys/class/net/$iface" ] && continue
                local r_old=${rx_old[$iface]:-0}; local t_old=${tx_old[$iface]:-0}
                local r_new=${rx_new[$iface]:-0}; local t_new=${tx_new[$iface]:-0}
                local rx_sec=$((r_new - r_old)); local tx_sec=$((t_new - t_old))
                
                active_count=$((active_count + 1))
                local c_rx="${DIM}"; [ "$rx_sec" -gt 0 ] && c_rx="${G}"
                local c_tx="${DIM}"; [ "$tx_sec" -gt 0 ] && c_tx="${Y}"
                
                printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} %b%-10s%b ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "$iface" "$cat_color" "$cat_name" "$NC" "$c_rx" "$(format_speed $rx_sec)" "$NC" "$c_tx" "$(format_speed $tx_sec)" "$NC" "$(format_total $r_new)" "$(format_total $t_new)"
                rx_old[$iface]=$r_new; tx_old[$iface]=$t_new
            done
        }

        [ -n "$phys_ifs" ] && render_category "WAN / PHYS" "${W}" "$phys_ifs"
        [ -n "$gre_ifs" ] && render_category "GRE / L3" "${C}" "$gre_ifs"
        [ -n "$vx_ifs" ] && render_category "VXLAN / L2" "${M}" "$vx_ifs"
        [ -n "$wg_ifs" ] && render_category "WG CRYPTO" "${G}" "$wg_ifs"

        if [ "$active_count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-83s${NC} ${B}│${NC}\n" "  Standby... No active MDesign tunnels or physical traffic detected right now."
        fi
        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ $key == "q" || $key == "Q" ]]; then break; fi
    done
    tput cnorm
}

show_total_usage() {
    clear; draw_mstats_header
    echo -e "\n  ${DIM}┌─[ HISTORICAL TRAFFIC USAGE ]${NC}"
    echo -e "  ${C}●${NC} ${W}Data accumulated since system boot or interface creation.${NC}\n"
    
    local phys_ifs=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(eth|ens|eno|enp)' | xargs)
    local all_tuns=""
    for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && source "$conf" && all_tuns="$all_tuns $T_NAME"; done
    for conf in /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && source "$conf" && all_tuns="$all_tuns $BR_NAME"; done
    [ -f "/etc/wireguard/wg0.conf" ] && all_tuns="$all_tuns wg0"
    
    echo -e "  ${B}╭──────────────────┬───────────────────────┬───────────────────────┬────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${C}%-21s${NC} ${B}│${NC} ${M}%-21s${NC} ${B}│${NC} ${G}%-22s${NC} ${B}│${NC}\n" "INTERFACE" "▼ TOTAL DOWNLOAD" "▲ TOTAL UPLOAD" "∑ COMBINED TRAFFIC"
    echo -e "  ${B}├──────────────────┴───────────────────────┴───────────────────────┴────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" " PHYSICAL / WAN UPLINKS"
    echo -e "  ${B}├──────────────────┬───────────────────────┬───────────────────────┬────────────────────────┤${NC}"
    
    for iface in $phys_ifs; do
        [ ! -d "/sys/class/net/$iface" ] && continue
        local rx=$(get_iface_rx "$iface"); local tx=$(get_iface_tx "$iface"); local total=$((rx + tx))
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${C}%-21s${NC} ${B}│${NC} ${M}%-21s${NC} ${B}│${NC} ${G}%-22s${NC} ${B}│${NC}\n" "$iface" "$(format_total $rx)" "$(format_total $tx)" "$(format_total $total)"
    done

    if [ -n "$all_tuns" ]; then
        echo -e "  ${B}├──────────────────┴───────────────────────┴───────────────────────┴────────────────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" " VIRTUAL FABRICS (GRE, VXLAN, WG)"
        echo -e "  ${B}├──────────────────┬───────────────────────┬───────────────────────┬────────────────────────┤${NC}"
        for iface in $all_tuns; do
            [ ! -d "/sys/class/net/$iface" ] && continue
            local rx=$(get_iface_rx "$iface"); local tx=$(get_iface_tx "$iface"); local total=$((rx + tx))
            printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${C}%-21s${NC} ${B}│${NC} ${M}%-21s${NC} ${B}│${NC} ${G}%-22s${NC} ${B}│${NC}\n" "$iface" "$(format_total $rx)" "$(format_total $tx)" "$(format_total $total)"
        done
    fi
    echo -e "  ${B}╰──────────────────┴───────────────────────┴───────────────────────┴────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

while true; do
    clear; draw_mstats_header
    echo -e "\n  ${DIM}┌─[ TRAFFIC & BANDWIDTH ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Live Omni-Radar${NC} ${DIM}(Bandwidth & Historical Total)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Total Historical Usage${NC} ${DIM}(Static Traffic Snapshot)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MSTATS ❯❯ ${NC}"; read opt
    case $opt in
        1) show_live_radar ;;
        2) show_total_usage ;;
        0) break ;;
    esac
done
EOF_MSTATS
chmod +x /usr/bin/mstats
