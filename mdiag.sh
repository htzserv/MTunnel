#!/bin/bash
# --- MDesign Modular Core (mdiag.sh) | Network Diagnostics v1.2.5 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mgre/tunnels"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    clear; echo ""
    local str1=" MDesign Health Scanner 1.2.5 "
    local str2=" IP: $s_ip "
    local raw_len=$(( ${#str1} + 1 + ${#str2} ))
    local pad_len=$(( 92 - raw_len ))
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

run_ping_diagnostics() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured.${NC}"; sleep 1.5; return; fi

    echo -e "\n  ${Y}● Running Deep Ping Diagnostics (10 Packets per Tunnel)... Please Wait.${NC}"
    echo -e "  ${B}╭────────────────┬─────────────────┬────────┬───────────┬──────────┬────────────┬──────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-14s${NC} ${B}│${NC} ${W}%-15s${NC} ${B}│${NC} ${W}%-6s${NC} ${B}│${NC} ${W}%-9s${NC} ${B}│${NC} ${W}%-8s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${W}%-8s${NC} ${B}│${NC}\n" "TUNNEL" "REMOTE IP" "LOSS %" "LATENCY" "JITTER" "UPTIME" "STATUS"
    echo -e "  ${B}├────────────────┼─────────────────┼────────┼───────────┼──────────┼────────────┼──────────┤${NC}"

    for conf in "${configs[@]}"; do
        source "$conf"
        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        
        local ping_stats=$(ping -c 10 -i 0.2 -q "$main_tip" 2>/dev/null)
        local loss="100%"; local avg_lat="---"; local jitter="---"; local status_text="● FAIL"; local stat_color="${R}"

        if [ -n "$ping_stats" ]; then
            loss=$(echo "$ping_stats" | grep -oP '\d+(?=% packet loss)')
            [ -z "$loss" ] && loss="100"
            if [ "$loss" -lt 100 ]; then
                local rtt=$(echo "$ping_stats" | tail -1 | awk '{print $4}')
                if [[ "$rtt" == *"/"* ]]; then
                    avg_lat=$(echo "$rtt" | cut -d '/' -f 2 | awk '{printf "%.1f", $1}')"ms"
                    jitter=$(echo "$rtt" | cut -d '/' -f 4 | awk '{printf "%.1f", $1}')"ms"
                fi
                if [ "$loss" -eq 0 ]; then status_text="● GOOD"; stat_color="${G}"
                elif [ "$loss" -le 20 ]; then status_text="● WARN"; stat_color="${Y}"
                else status_text="● FAIL"; stat_color="${R}"; fi
            fi
            loss="${loss}%"
        fi

        local sys_uptime="Offline"
        if ip link show "$T_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" != "down" ]; then
            local created=$(stat -c %Y "/sys/class/net/$T_NAME" 2>/dev/null)
            if [ -n "$created" ]; then
                local diff=$(($(date +%s) - created))
                local d=$((diff / 86400)); local h=$(( (diff % 86400) / 3600 )); local m=$(( (diff % 3600) / 60 ))
                if [ "$d" -gt 0 ]; then sys_uptime="${d}d ${h}h"
                elif [ "$h" -gt 0 ]; then sys_uptime="${h}h ${m}m"
                else sys_uptime="${m}m"; fi
            fi
        fi

        local t_name_short="${T_NAME:0:14}"
        printf "  ${B}│${NC} ${C}%-14s${NC} ${B}│${NC} ${DIM}%-15s${NC} ${B}│${NC} %b%-6s%b ${B}│${NC} ${W}%-9s${NC} ${B}│${NC} ${W}%-8s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} %b%-8s%b ${B}│${NC}\n" "$t_name_short" "$main_tip" "$stat_color" "$loss" "$NC" "$avg_lat" "$jitter" "$sys_uptime" "$stat_color" "$status_text" "$NC"
    done
    echo -e "  ${B}╰────────────────┴─────────────────┴────────┴───────────┴──────────┴────────────┴──────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

run_speedtest() {
    if ! command -v iperf3 >/dev/null 2>&1; then
        echo -e "\n  ${Y}● Core dependency 'iPerf3' missing. Deploying dependencies...${NC}"
        apt-get update -y && apt-get install -y iperf3
    fi

    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return; fi
    
    echo -e "\n  ${B}╭────────────────── Select Tunnel for Speedtest ──────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        local conf_name=$(basename "${configs[$i]}" .conf)
        printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-55s${NC} ${B}│${NC}\n" "$i" "$conf_name"
    done
    echo -e "  ${B}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}  ${R}0${NC} ${C}❯${NC} ${DIM}Cancel and Return${NC}                                         ${B}│${NC}"
    echo -e "  ${B}╰─────────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Tunnel Index or 0: ${NC}"; read t_idx
    
    [[ "$t_idx" == "0" || -z "$t_idx" ]] && return
    
    if [[ -n "${configs[$t_idx]}" ]]; then
        source "${configs[$t_idx]}"
        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local main_lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")

        echo -e "\n  ${DIM}┌─[ SPEEDTEST MODE ]${NC}"
        echo -e "  ${DIM}│${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Run as Receiver (Server)${NC} ${DIM}- Listens for incoming test${NC}"
        echo -e "  ${DIM}│${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Run as Sender (Client)${NC} ${DIM}- Starts the speedtest${NC}"
        echo -e "  ${DIM}│${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel and Go Back${NC}"
        echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read st_mode

        [[ "$st_mode" == "0" || -z "$st_mode" ]] && return

        if [ "$st_mode" == "1" ]; then
            pkill iperf3 2>/dev/null; iperf3 -s -B "$main_lip" -D >/dev/null 2>&1
            echo -e "\n  ${G}● Receiver Mode Activated!${NC}\n  ${DIM}├─ Listening on: ${W}${main_lip}${NC}\n  ${DIM}└─ Trigger 'Sender' on the remote endpoint.${NC}"
            echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
        elif [ "$st_mode" == "2" ]; then
            echo -e "\n  ${Y}● Evaluating 10-Sec Core Bandwidth to ${main_tip}...${NC}"
            local result=$(iperf3 -c "$main_tip" -t 10 --format m 2>&1)
            if echo "$result" | grep -q "Connection refused"; then
                echo -e "  ${R}● Connection Refused! Activate Receiver Mode on target first.${NC}"
            elif echo "$result" | grep -q "error"; then
                echo -e "  ${R}● Packet rejection detected.${NC}"
            else
                local s_speed=$(echo "$result" | grep "sender" | awk '{print $7" "$8}')
                local r_speed=$(echo "$result" | grep "receiver" | awk '{print $7" "$8}')
                [ -z "$s_speed" ] && s_speed=$(echo "$result" | grep "sec" | tail -1 | awk '{print $7" "$8}')
                echo -e "  ${B}╭──────────────────────────────────────────────────╮${NC}"
                printf "  ${B}│${NC} ${W}%-15s${NC} ${C}❯❯${NC}  ${G}%-26s${NC} ${B}│${NC}\n" "Upload Speed" "$s_speed"
                printf "  ${B}│${NC} ${W}%-15s${NC} ${C}❯❯${NC}  ${G}%-26s${NC} ${B}│${NC}\n" "Download Speed" "${r_speed:-$s_speed}"
                echo -e "  ${B}╰──────────────────────────────────────────────────╯${NC}"
            fi
            echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
        fi
    fi
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ NETWORK DIAGNOSTICS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Deep Ping & Latency Scan (All Tunnels)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Tunnel Throughput Speedtest (iPerf3)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MDiag ❯❯ ${NC}"; read opt
    case $opt in
        1) run_ping_diagnostics ;;
        2) run_speedtest ;;
        0) exit 0 ;;
    esac
done
