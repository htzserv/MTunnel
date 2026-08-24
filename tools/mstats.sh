#!/bin/bash
# --- MDesign Modular Core (mstats.sh) | MStats Omni-Radar & Web Controller v3.8.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_FILE="/etc/mweb/web.conf"
WEB_SVC_FILE="/etc/systemd/system/mweb.service"
source "$CONF_FILE" 2>/dev/null
WEB_PORT=${WEB_PORT:-1000}
CONF_BH="/etc/mbackhaul/tunnels"
CONF_RH="/etc/mrathole/tunnels"
CONF_PQ="/etc/paqet"

export CACHE_IPT_IN=""
export CACHE_IPT_OUT=""

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_mstats_header() {
    local s_ip=$(get_local_ip)
    local w_stat="${DIM}DISABLED${NC}"
    if systemctl is-active --quiet mweb.service 2>/dev/null; then w_stat="${C}PORT ${WEB_PORT}${NC}"; fi
    clear; echo ""
    local str1=" MStats Omni-Radar Core 3.8.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Web:${NC} ${w_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

format_speed() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B/s"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B/s"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB/s"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf "%.1f MB/s", $bytes/1048576}"
    else awk "BEGIN {printf "%.2f GB/s", $bytes/1073741824}"; fi
}

format_total() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf "%.1f MB", $bytes/1048576}"
    elif [ "$bytes" -lt 1099511627776 ]; then awk "BEGIN {printf "%.2f GB", $bytes/1073741824}"
    else awk "BEGIN {printf "%.2f TB", $bytes/1099511627776}"; fi
}

get_iface_rx() {
    local r_base=0
    [ -d "/sys/class/net/$1" ] && r_base=$(cat "/sys/class/net/$1/statistics/rx_bytes" 2>/dev/null || echo 0)
    echo "$r_base"
}

get_iface_tx() {
    local t_base=0
    [ -d "/sys/class/net/$1" ] && t_base=$(cat "/sys/class/net/$1/statistics/tx_bytes" 2>/dev/null || echo 0)
    echo "$t_base"
}

get_bh_rx() {
    local bytes=$(echo "$CACHE_IPT_IN" | grep "MBH_RX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${bytes:-0}"
}

get_bh_tx() {
    local bytes=$(echo "$CACHE_IPT_OUT" | grep "MBH_TX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${bytes:-0}"
}

get_rat_rx() {
    local bytes=$(echo "$CACHE_IPT_IN" | grep "RAT_RX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${bytes:-0}"
}

get_rat_tx() {
    local bytes=$(echo "$CACHE_IPT_OUT" | grep "RAT_TX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${bytes:-0}"
}

get_pq_rx() {
    local bytes=$(echo "$CACHE_IPT_IN" | grep "MPAQET_RX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${bytes:-0}"
}

get_pq_tx() {
    local bytes=$(echo "$CACHE_IPT_OUT" | grep "MPAQET_TX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${bytes:-0}"
}

show_live_radar() {
    tput civis; clear; declare -A rx_old tx_old
    while true; do
        CACHE_IPT_IN=$(iptables -t mangle -xnvL INPUT 2>/dev/null)
        CACHE_IPT_OUT=$(iptables -t mangle -xnvL OUTPUT 2>/dev/null)
        
        printf "\033[H"; draw_mstats_header
        echo -e "\n  ${DIM}┌─[ UNIFIED TRAFFIC RADAR ]${NC} ${C}(Real-time 1s Auto-Refresh | Press 'q' to stop)${NC}\n"
        echo -e "  ${B}╭──────────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "INTERFACE" "CATEGORY" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL DOWN" "∑ TOTAL UP"
        echo -e "  ${B}├──────────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤${NC}"

        local phys_ifs=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(eth|ens|eno|enp)' | xargs)
        local gre_ifs=""
        for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && unset T_NAME && source "$conf" && gre_ifs="$gre_ifs $T_NAME"; done
        local vx_ifs=""
        for conf in /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && unset BR_NAME && source "$conf" && vx_ifs="$vx_ifs $BR_NAME"; done
        
        local bh_nodes=""
        for conf in "$CONF_BH"/*.meta; do [ -f "$conf" ] && bh_nodes="$bh_nodes $(basename "$conf" .meta)"; done

        local rh_nodes=""
        for conf in "$CONF_RH"/*; do [ -d "$conf" ] && rh_nodes="$rh_nodes $(basename "$conf")"; done

        local pq_nodes=""
        for conf in "$CONF_PQ"/*.yaml; do [ -f "$conf" ] && pq_nodes="$pq_nodes $(basename "$conf" .yaml)"; done

        local all_ifs="$phys_ifs $gre_ifs $vx_ifs $bh_nodes $rh_nodes $pq_nodes"
        for iface in $all_ifs; do
            if [ -z "${rx_old[$iface]}" ]; then
                if [[ " $bh_nodes " =~ " $iface " ]]; then rx_old[$iface]=$(get_bh_rx "$iface"); tx_old[$iface]=$(get_bh_tx "$iface");
                elif [[ " $rh_nodes " =~ " $iface " ]]; then rx_old[$iface]=$(get_rat_rx "$iface"); tx_old[$iface]=$(get_rat_tx "$iface");
                elif [[ " $pq_nodes " =~ " $iface " ]]; then rx_old[$iface]=$(get_pq_rx "$iface"); tx_old[$iface]=$(get_pq_tx "$iface");
                else rx_old[$iface]=$(get_iface_rx "$iface"); tx_old[$iface]=$(get_iface_tx "$iface"); fi
            fi
        done

        local active_count=0
        render_category() {
            local cat_name=$1; local cat_color=$2; local if_list=$3; local is_phantom=$4
            for iface in $if_list; do
                local r_old=${rx_old[$iface]:-0}; local t_old=${tx_old[$iface]:-0}
                local r_new=0; local t_new=0
                
                if [ "$is_phantom" == "bh" ]; then r_new=$(get_bh_rx "$iface"); t_new=$(get_bh_tx "$iface");
                elif [ "$is_phantom" == "rh" ]; then r_new=$(get_rat_rx "$iface"); t_new=$(get_rat_tx "$iface");
                elif [ "$is_phantom" == "pq" ]; then r_new=$(get_pq_rx "$iface"); t_new=$(get_pq_tx "$iface");
                else
                    [ ! -d "/sys/class/net/$iface" ] && continue
                    r_new=$(get_iface_rx "$iface"); t_new=$(get_iface_tx "$iface")
                fi
                
                local rx_sec=$((r_new - r_old)); local tx_sec=$((t_new - t_old))
                [ "$rx_sec" -lt 0 ] && rx_sec=0; [ "$tx_sec" -lt 0 ] && tx_sec=0
                active_count=$((active_count + 1))

                local c_rx="${DIM}"; [ "$rx_sec" -gt 0 ] && c_rx="${G}"
                local c_tx="${DIM}"; [ "$tx_sec" -gt 0 ] && c_tx="${Y}"
                
                printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} %b%-10s%b ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "$iface" "$cat_color" "$cat_name" "$NC" "$c_rx" "$(format_speed $rx_sec)" "$NC" "$c_tx" "$(format_speed $tx_sec)" "$NC" "$(format_total $r_new)" "$(format_total $t_new)"
                rx_old[$iface]=$r_new; tx_old[$iface]=$t_new
            done
        }

        [ -n "$phys_ifs" ] && render_category "WAN / PHYS" "${W}" "$phys_ifs" "net"
        [ -n "$gre_ifs" ] && render_category "GRE / L3" "${C}" "$gre_ifs" "net"
        [ -n "$vx_ifs" ] && render_category "VXLAN / L2" "${M}" "$vx_ifs" "net"
        [ -n "$bh_nodes" ] && render_category "BACKHAUL" "${Y}" "$bh_nodes" "bh"
        [ -n "$rh_nodes" ] && render_category "RATHOLE" "${R}" "$rh_nodes" "rh"
        [ -n "$pq_nodes" ] && render_category "PAQET RAW" "${M}" "$pq_nodes" "pq"

        if [ "$active_count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" "  Standby... No active tunnels or physical traffic detected."
        fi
        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\e' ]]; then break; fi
    done
    tput cnorm
}

while true; do
    clear; draw_mstats_header
    echo -e "\n  ${DIM}┌─[ TRAFFIC & BANDWIDTH ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Live Omni-Radar${NC} ${DIM}(CLI Real-Time Monitor)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}TCP/UDP Connection Tracker${NC} ${DIM}(Active Clients)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MSTATS ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r' | tr -d ' ')
    case $opt in
        1) show_live_radar ;;
        2) 
           echo -e "\n  ${DIM}┌─[ TOP ACTIVE CLIENTS ]${NC}"
           ss -tun state established 2>/dev/null | awk 'NR>1 {print $5}' | rev | cut -d: -f2- | rev | tr -d '[]' | grep -Ev '^(127\.0\.0\.1|0\.0\.0\.0|\*)$' | sort | uniq -c | sort -nr | head -n 10
           echo -ne "\n  ${DIM}Press Enter...${NC}"; read dummy ;;
        0) break ;;
    esac
done
