#!/bin/bash
# --- MDesign Modular Core (mstats.sh) | MStats Traffic & QoS Manager v1.1.2 (Clean Radar) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_mstats_header() {
    local s_ip=$(get_local_ip)
    clear; echo ""
    local str1=" MStats Traffic & QoS 1.1.2 "
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
    if [ -z "$bytes" ]; then echo "0 B/s"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B/s"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB/s"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB/s\", $bytes/1048576}"
    else awk "BEGIN {printf \"%.2f GB/s\", $bytes/1073741824}"; fi
}

format_total() {
    local bytes=$1
    if [ -z "$bytes" ]; then echo "0 B"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -lt 1099511627776 ]; then awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    else awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"; fi
}

show_live_radar() {
    tput civis
    
    # گرفتن تمام اینترفیس‌ها و حذف زوائد (مثل @NONE)
    local raw_ifs=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | sort -u)
    
    # فیلتر هوشمند: فقط کارت شبکه اصلی و تانل‌هایی که خودمون ساختیم رو نگه دار
    local clean_ifs=$(echo "$raw_ifs" | grep -vE '^(lo|gre0|gretap0|erspan0|sit0|ip6tnl0|ip6gre0|dummy.*)$' | xargs)
    
    local phys_ifs=""; local gre_ifs=""; local vx_ifs=""; local wg_ifs=""
    for iface in $clean_ifs; do
        if [[ "$iface" =~ ^(vx_|br_) ]]; then vx_ifs="$vx_ifs $iface"
        elif [[ "$iface" =~ ^wg ]]; then wg_ifs="$wg_ifs $iface"
        elif [[ "$iface" =~ ^(gre|sit_gre) ]]; then gre_ifs="$gre_ifs $iface"
        else phys_ifs="$phys_ifs $iface"; fi
    done

    local all_ifs="$phys_ifs $gre_ifs $vx_ifs $wg_ifs"
    declare -A rx_old tx_old
    
    for iface in $all_ifs; do
        rx_old[$iface]=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        tx_old[$iface]=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
    done

    while true; do
        draw_mstats_header
        echo -e "\n  ${DIM}┌─[ LIVE TRAFFIC RADAR ]${NC} ${C}(Auto-Refreshing every 1s | Only Active Links | Press 'q' to stop)${NC}\n"
        echo -e "  ${B}╭──────────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "INTERFACE" "CATEGORY" "▼ RX SPEED" "▲ TX SPEED" "TOTAL RX" "TOTAL TX"
        echo -e "  ${B}├──────────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤${NC}"

        declare -A rx_new tx_new
        for iface in $all_ifs; do
            rx_new[$iface]=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
            tx_new[$iface]=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        done

        local active_count=0

        render_category() {
            local cat_name=$1; local cat_color=$2; local if_list=$3
            for iface in $if_list; do
                local r_old=${rx_old[$iface]:-0}; local t_old=${tx_old[$iface]:-0}
                local r_new=${rx_new[$iface]:-0}; local t_new=${tx_new[$iface]:-0}
                local rx_sec=$((r_new - r_old)); local tx_sec=$((t_new - t_old))
                
                # جادوی اصلی: اگر ترافیکی عبور نمی‌کنه، کلاً خط رو تو جدول نکش!
                if [ "$rx_sec" -eq 0 ] && [ "$tx_sec" -eq 0 ]; then
                    rx_old[$iface]=$r_new; tx_old[$iface]=$t_new
                    continue
                fi
                
                active_count=$((active_count + 1))
                
                local c_rx="${C}"; [ "$rx_sec" -gt 0 ] && c_rx="${G}"
                local c_tx="${M}"; [ "$tx_sec" -gt 0 ] && c_tx="${Y}"
                
                local str_rx_s=$(format_speed $rx_sec); local str_tx_s=$(format_speed $tx_sec)
                local str_rx_t=$(format_total $r_new); local str_tx_t=$(format_total $t_new)

                printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} %b%-10s%b ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "$iface" "$cat_color" "$cat_name" "$NC" "$c_rx" "$str_rx_s" "$NC" "$c_tx" "$str_tx_s" "$NC" "$str_rx_t" "$str_tx_t"
                
                rx_old[$iface]=$r_new; tx_old[$iface]=$t_new
            done
        }

        [ -n "$phys_ifs" ] && render_category "WAN / PHYS" "${W}" "$phys_ifs"
        [ -n "$gre_ifs" ] && render_category "GRE / L3" "${C}" "$gre_ifs"
        [ -n "$vx_ifs" ] && render_category "VXLAN / L2" "${M}" "$vx_ifs"
        [ -n "$wg_ifs" ] && render_category "WG CRYPTO" "${G}" "$wg_ifs"

        if [ "$active_count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-83s${NC} ${B}│${NC}\n" "  Idle... No active traffic detected on any interface right now."
        fi

        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        
        read -t 1 -n 1 -s key
        if [[ $key == "q" || $key == "Q" ]]; then break; fi
    done
    tput cnorm
}

show_total_usage() {
    draw_mstats_header
    echo -e "\n  ${DIM}┌─[ HISTORICAL TRAFFIC USAGE ]${NC}"
    echo -e "  ${C}●${NC} ${W}Data accumulated since system boot or interface creation.${NC}\n"
    
    local raw_ifs=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | sort -u)
    local clean_ifs=$(echo "$raw_ifs" | grep -vE '^(lo|gre0|gretap0|erspan0|sit0|ip6tnl0|ip6gre0|dummy.*)$' | xargs)
    
    local phys_ifs=""; local all_tuns=""
    for iface in $clean_ifs; do
        if [[ "$iface" =~ ^(gre|sit_gre|vx_|br_|wg) ]]; then all_tuns="$all_tuns $iface"
        else phys_ifs="$phys_ifs $iface"; fi
    done
    
    echo -e "  ${B}╭──────────────────┬───────────────────────┬───────────────────────┬────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${C}%-21s${NC} ${B}│${NC} ${M}%-21s${NC} ${B}│${NC} ${G}%-22s${NC} ${B}│${NC}\n" "INTERFACE" "▼ TOTAL DOWNLOAD" "▲ TOTAL UPLOAD" "∑ COMBINED TRAFFIC"
    echo -e "  ${B}├──────────────────┴───────────────────────┴───────────────────────┴────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" " PHYSICAL / WAN UPLINKS"
    echo -e "  ${B}├──────────────────┬───────────────────────┬───────────────────────┬────────────────────────┤${NC}"
    
    for iface in $phys_ifs; do
        local rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        local tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        local total=$((rx + tx))
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${C}%-21s${NC} ${B}│${NC} ${M}%-21s${NC} ${B}│${NC} ${G}%-22s${NC} ${B}│${NC}\n" "$iface" "$(format_total $rx)" "$(format_total $tx)" "$(format_total $total)"
    done

    if [ -n "$all_tuns" ]; then
        echo -e "  ${B}├──────────────────┴───────────────────────┴───────────────────────┴────────────────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" " VIRTUAL FABRICS (GRE, VXLAN, WG)"
        echo -e "  ${B}├──────────────────┬───────────────────────┬───────────────────────┬────────────────────────┤${NC}"
        for iface in $all_tuns; do
            local rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
            local tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
            local total=$((rx + tx))
            printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${C}%-21s${NC} ${B}│${NC} ${M}%-21s${NC} ${B}│${NC} ${G}%-22s${NC} ${B}│${NC}\n" "$iface" "$(format_total $rx)" "$(format_total $tx)" "$(format_total $total)"
        done
    fi
    echo -e "  ${B}╰──────────────────┴───────────────────────┴───────────────────────┴────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

show_connection_tracker() {
    draw_mstats_header
    echo -e "\n  ${DIM}┌─[ TCP/UDP CONNECTION TRACKER ]${NC}"
    echo -e "  ${C}●${NC} ${W}Scanning established connections in Kernel...${NC}\n"

    echo -e "  ${B}╭─────────┬──────────────────────┬─────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${C}%-20s${NC} ${B}│${NC} ${M}%-11s${NC} ${B}│${NC}\n" "RANK" "HEAVIEST LOCAL PORTS" "CONNECTIONS"
    echo -e "  ${B}├─────────┼──────────────────────┼─────────────┤${NC}"
    
    local top_ports=$(ss -tun state established 2>/dev/null | awk 'NR>1 {print $4}' | rev | cut -d: -f1 | rev | sort | uniq -c | sort -nr | head -n 5)
    local rank=1
    if [ -z "$top_ports" ]; then
        printf "  ${B}│${NC} ${DIM}%-42s${NC} ${B}│${NC}\n" "  No active connections detected."
    else
        while read -r count port; do
            printf "  ${B}│${NC} ${DIM}#%-6s${NC} ${B}│${NC} ${W}Port %-15s${NC} ${B}│${NC} ${G}%-11s${NC} ${B}│${NC}\n" "$rank" "$port" "$count"
            ((rank++))
        done <<< "$top_ports"
    fi
    echo -e "  ${B}╰─────────┴──────────────────────┴─────────────╯${NC}\n"

    echo -e "  ${B}╭─────────┬──────────────────────┬─────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${Y}%-20s${NC} ${B}│${NC} ${M}%-11s${NC} ${B}│${NC}\n" "RANK" "TOP CLIENT IPs (PEERS)" "CONNECTIONS"
    echo -e "  ${B}├─────────┼──────────────────────┼─────────────┤${NC}"
    
    local top_ips=$(ss -tun state established 2>/dev/null | awk 'NR>1 {print $5}' | rev | cut -d: -f2- | rev | tr -d '[]' | grep -Ev '127\.0\.0\.1|0\.0\.0\.0|\*' | sort | uniq -c | sort -nr | head -n 5)
    local rank2=1
    if [ -z "$top_ips" ]; then
        printf "  ${B}│${NC} ${DIM}%-42s${NC} ${B}│${NC}\n" "  No active external clients."
    else
        while read -r count ip; do
            printf "  ${B}│${NC} ${DIM}#%-6s${NC} ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} ${G}%-11s${NC} ${B}│${NC}\n" "$rank2" "$ip" "$count"
            ((rank2++))
        done <<< "$top_ips"
    fi
    echo -e "  ${B}╰─────────┴──────────────────────┴─────────────╯${NC}"
    
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

qos_manager() {
    draw_mstats_header
    echo -e "\n  ${DIM}┌─[ QoS & TRAFFIC SHAPING MANAGER ]${NC}"
    echo -e "  ${C}●${NC} ${W}Limit bandwidth on specific interfaces to prevent network saturation.${NC}\n"
    
    local all_ifs=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(gre|vx_|br_|wg|eth|ens|ensp)' | xargs)
    
    echo -e "  ${B}╭─────┬──────────────────┬──────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-3s${NC} ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "IDX" "INTERFACE" "CURRENT BANDWIDTH LIMIT"
    echo -e "  ${B}├─────┼──────────────────┼──────────────────────────────┤${NC}"
    
    local iface_arr=()
    local idx=0
    for iface in $all_ifs; do
        iface_arr+=("$iface")
        local limit=$(tc qdisc show dev "$iface" 2>/dev/null | grep -oP 'rate \K\S+')
        local stat_color="${G}"; local stat_text="UNLIMITED (Native Speed)"
        if [ -n "$limit" ]; then stat_color="${Y}"; stat_text="${limit} (Capped)"; fi
        
        printf "  ${B}│${NC} ${C}%-3s${NC} ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} %b%-28s%b ${B}│${NC}\n" "$idx" "$iface" "$stat_color" "$stat_text" "$NC"
        ((idx++))
    done
    echo -e "  ${B}╰─────┴──────────────────┴──────────────────────────────╯${NC}\n"
    
    echo -ne "  ${C}●${NC} ${W}Select Interface Index (or 'q' to cancel): ${NC}"; read sel_idx
    [[ "$sel_idx" == "q" || -z "$sel_idx" ]] && return
    
    local target_if="${iface_arr[$sel_idx]}"
    if [ -z "$target_if" ]; then echo -e "  ${R}● Invalid selection!${NC}"; sleep 1.5; return; fi
    
    echo -ne "  ${C}●${NC} ${W}Enter New Limit in Mbit/s (e.g. 50) or '0' to UNLIMITED: ${NC}"; read speed_val
    if ! [[ "$speed_val" =~ ^[0-9]+$ ]]; then echo -e "  ${R}● Invalid number!${NC}"; sleep 1.5; return; fi
    
    tc qdisc del dev "$target_if" root 2>/dev/null
    
    if [ "$speed_val" -gt 0 ]; then
        tc qdisc add dev "$target_if" root tbf rate ${speed_val}mbit burst 32kbit latency 400ms 2>/dev/null
        echo -e "\n  ${G}● Speed limit of ${speed_val} Mbps successfully applied to ${target_if}.${NC}"
    else
        echo -e "\n  ${G}● Speed limit removed. ${target_if} is now UNLIMITED.${NC}"
    fi
    sleep 2
}

while true; do
    draw_mstats_header
    echo -e "\n  ${DIM}┌─[ TRAFFIC & BANDWIDTH ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Live Bandwidth Radar${NC} ${DIM}(Categorized Real-time Speeds)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Total Historical Usage${NC} ${DIM}(Since Boot / Up)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}TCP/UDP Connection Tracker${NC} ${DIM}(Find Floods & Top IPs)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Fabric QoS & Speed Limiter${NC} ${DIM}(Throttle specific interfaces)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MSTATS ❯❯ ${NC}"; read opt
    case $opt in
        1) show_live_radar ;;
        2) show_total_usage ;;
        3) show_connection_tracker ;;
        4) qos_manager ;;
        0) break ;;
    esac
done
