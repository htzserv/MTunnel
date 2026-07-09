#!/bin/bash
# --- MDesign Modular Core (mstats.sh) | MStats Omni-Radar v1.3.6 (Laser Filter Patch) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_mstats_header() {
    local s_ip=$(get_local_ip)
    echo ""
    local str1=" MStats Omni-Radar 1.3.6 "
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

show_live_radar() {
    tput civis
    clear
    declare -A rx_old tx_old

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
        local wg_ifs=""
        [ -f "/etc/wireguard/wg0.conf" ] && wg_ifs="wg0"

        local all_ifs="$phys_ifs $gre_ifs $vx_ifs $wg_ifs"

        for iface in $all_ifs; do
            if [ -z "${rx_old[$iface]}" ] && [ -d "/sys/class/net/$iface" ]; then
                rx_old[$iface]=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
                tx_old[$iface]=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
            fi
        done

        declare -A rx_new tx_new
        for iface in $all_ifs; do
            [ ! -d "/sys/class/net/$iface" ] && continue
            rx_new[$iface]=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
            tx_new[$iface]=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        done

        local active_count=0

        render_category() {
            local cat_name=$1; local cat_color=$2; local if_list=$3
            for iface in $if_list; do
                [ ! -d "/sys/class/net/$iface" ] && continue
                
                local r_old=${rx_old[$iface]:-0}; local t_old=${tx_old[$iface]:-0}
                local r_new=${rx_new[$iface]:-0}; local t_new=${tx_new[$iface]:-0}
                local rx_sec=$((r_new - r_old)); local tx_sec=$((t_new - t_old))
                
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
            printf "  ${B}│${NC} ${DIM}%-83s${NC} ${B}│${NC}\n" "  Standby... No active MDesign tunnels or physical traffic detected right now."
        fi

        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key
        if [[ $key == "q" || $key == "Q" ]]; then break; fi
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
            [ ! -d "/sys/class/net/$iface" ] && continue
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
    clear; draw_mstats_header
    echo -e "\n  ${DIM}┌─[ MDESIGN CONNECTION TRACKER ]${NC}"
    echo -e "  ${C}●${NC} ${W}Exclusive Core Engine Filter (HAProxy & Gost)...${NC}\n"

    # پیدا کردن دقیق پورت‌هایی که دست گوست و هپروکسی هستن
    local core_ports=$(ss -tulpn 2>/dev/null | grep -iE '"(gost|haproxy)"' | awk '{print $5}' | rev | cut -d: -f1 | rev | sort -u | tr '\n' '|' | sed 's/|$//')

    echo -e "  ${B}╭─────────┬───────────────┬─────────────────┬─────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${C}%-13s${NC} ${B}│${NC} ${M}%-15s${NC} ${B}│${NC} ${G}%-11s${NC} ${B}│${NC}\n" "RANK" "LOCAL PORT" "CORE ENGINE" "CONNECTIONS"
    echo -e "  ${B}├─────────┼───────────────┼─────────────────┼─────────────┤${NC}"
    
    if [ -z "$core_ports" ]; then
        printf "  ${B}│${NC} ${DIM}%-51s${NC} ${B}│${NC}\n" "  No active Gost or HAProxy services running."
    else
        # استخراج کانکشن‌هایی که فقط روی این پورت‌های اصلی هستند
        local top_ports=$(ss -tun state established 2>/dev/null | awk 'NR>1 {print $4}' | rev | cut -d: -f1 | rev | grep -E "^($core_ports)$" | sort | uniq -c | sort -nr | head -n 5)
        
        local rank=1
        if [ -z "$top_ports" ]; then
            printf "  ${B}│${NC} ${DIM}%-51s${NC} ${B}│${NC}\n" "  No active external connections to Core Engines."
        else
            while read -r count port; do
                local app_name=$(ss -tulpn 2>/dev/null | grep ":$port " | grep -iE -o 'users:(("(gost|haproxy)"' | head -n 1 | cut -d'"' -f2)
                [ -z "$app_name" ] && app_name="Unknown"
                app_name=${app_name^^}
                printf "  ${B}│${NC} ${DIM}#%-6s${NC} ${B}│${NC} ${W}Port %-8s${NC} ${B}│${NC} ${Y}%-15s${NC} ${B}│${NC} ${G}%-11s${NC} ${B}│${NC}\n" "$rank" "$port" "$app_name" "$count"
                ((rank++))
            done <<< "$top_ports"
        fi
    fi
    echo -e "  ${B}╰─────────┴───────────────┴─────────────────┴─────────────╯${NC}\n"

    echo -e "  ${B}╭─────────┬──────────────────────────┬─────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${Y}%-24s${NC} ${B}│${NC} ${M}%-11s${NC} ${B}│${NC}\n" "RANK" "TOP CLIENT IPs (PEERS)" "CONNECTIONS"
    echo -e "  ${B}├─────────┼──────────────────────────┼─────────────┤${NC}"
    
    if [ -z "$core_ports" ]; then
        printf "  ${B}│${NC} ${DIM}%-46s${NC} ${B}│${NC}\n" "  No active external clients."
    else
        # استخراج آی‌پی‌هایی که فقط و فقط به پورت‌های هاست و هپروکسی ما وصل شدن (حذف آی‌پی‌های بک‌گراند)
        local top_ips=$(ss -tun state established 2>/dev/null | awk -v cp="^(${core_ports})$" '{
            n = split($4, a, ":"); port = a[n];
            if(port ~ cp) print $5;
        }' | rev | cut -d: -f2- | rev | tr -d '[]' | sed 's/^::ffff://' | grep -Ev '^(127\.0\.0\.1|0\.0\.0\.0|\*)$' | sort | uniq -c | sort -nr | head -n 5)
        
        local rank2=1
        if [ -z "$top_ips" ]; then
            printf "  ${B}│${NC} ${DIM}%-46s${NC} ${B}│${NC}\n" "  No active external clients connected to Cores."
        else
            while read -r count ip; do
                printf "  ${B}│${NC} ${DIM}#%-6s${NC} ${B}│${NC} ${W}%-24s${NC} ${B}│${NC} ${G}%-11s${NC} ${B}│${NC}\n" "$rank2" "$ip" "$count"
                ((rank2++))
            done <<< "$top_ips"
        fi
    fi
    echo -e "  ${B}╰─────────┴──────────────────────────┴─────────────╯${NC}"
    
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

qos_manager() {
    clear; draw_mstats_header
    echo -e "\n  ${DIM}┌─[ QoS & TRAFFIC SHAPING MANAGER ]${NC}"
    echo -e "  ${C}●${NC} ${W}Limit bandwidth on specific interfaces to prevent network saturation.${NC}\n"
    
    local all_ifs=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(gre|br_|wg|eth|ens|eno|enp)' | xargs)
    
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

iperf_benchmark() {
    clear; draw_mstats_header
    echo -e "\n  ${DIM}┌─[ iPerf3 BANDWIDTH BENCHMARK ]${NC}"
    echo -e "  ${C}●${NC} ${W}Active end-to-end speed test using iPerf3 engine.${NC}\n"

    if ! command -v iperf3 >/dev/null 2>&1; then
        echo -e "  ${Y}● iPerf3 engine not found. Installing now...${NC}"
        apt-get update >/dev/null 2>&1
        apt-get install -y iperf3 >/dev/null 2>&1
    fi

    echo -e "  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}  ${Y}1${NC} ${DIM}❯${NC} ${G}Run as Server (Listener Mode)${NC}                         ${B}│${NC}"
    echo -e "  ${B}│${NC}  ${Y}2${NC} ${DIM}❯${NC} ${C}Run as Client (Test against remote node)${NC}              ${B}│${NC}"
    echo -e "  ${B}├────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}  ${Y}0${NC} ${DIM}❯${NC} ${DIM}Cancel and Return${NC}                                     ${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}\n"
    echo -ne "  ${C}Select Mode ❯❯ ${NC}"; read i_mode

    if [ "$i_mode" == "1" ]; then
        echo -ne "  ${C}●${NC} ${W}Port to listen on [Default: 5201]: ${NC}"; read i_port
        i_port=${i_port:-5201}
        echo -e "\n  ${G}● iPerf3 Server is now running on port ${W}${i_port}${G}. (Press Ctrl+C to stop)${NC}"
        echo -e "  ${DIM}──────────────────────────────────────────────────────────────${NC}"
        iperf3 -s -p "$i_port"
    elif [ "$i_mode" == "2" ]; then
        echo -ne "  ${C}●${NC} ${W}Target Server IP (e.g. Tunnel IP): ${NC}"; read i_ip
        [ -z "$i_ip" ] && return
        echo -ne "  ${C}●${NC} ${W}Target Port [Default: 5201]: ${NC}"; read i_port
        i_port=${i_port:-5201}
        echo -ne "  ${C}●${NC} ${W}Parallel Streams (Bypass limits) [Default: 4]: ${NC}"; read i_p
        i_p=${i_p:-4}
        echo -ne "  ${C}●${NC} ${W}Reverse Mode (Test Download Speed)? (y/n) [n]: ${NC}"; read i_rev
        
        local rev_flag=""
        [ "$i_rev" == "y" ] && rev_flag="-R"

        echo -e "\n  ${Y}● Initiating Active Benchmark to ${W}${i_ip}${Y}...${NC}"
        echo -e "  ${DIM}──────────────────────────────────────────────────────────────${NC}"
        iperf3 -c "$i_ip" -p "$i_port" -P "$i_p" $rev_flag
        echo -e "  ${DIM}──────────────────────────────────────────────────────────────${NC}"
        echo -ne "\n  ${G}● Benchmark Completed. Press Enter to return...${NC}"; read
    fi
}

while true; do
    clear; draw_mstats_header
    echo -e "\n  ${DIM}┌─[ TRAFFIC & BANDWIDTH ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Live Omni-Radar${NC} ${DIM}(Bandwidth & Historical Total)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Total Historical Usage${NC} ${DIM}(Static Traffic Snapshot)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}TCP/UDP Connection Tracker${NC} ${DIM}(Exclusive Core Filter)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Fabric QoS & Speed Limiter${NC} ${DIM}(Throttle specific interfaces)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${W}Active Bandwidth Benchmark${NC} ${DIM}(iPerf3 Client/Server)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MSTATS ❯❯ ${NC}"; read opt
    case $opt in
        1) show_live_radar ;;
        2) show_total_usage ;;
        3) show_connection_tracker ;;
        4) qos_manager ;;
        5) iperf_benchmark ;;
        0) break ;;
    esac
done
