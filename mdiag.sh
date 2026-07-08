#!/bin/bash
# --- MDesign Modular Core (mdiag.sh) | Network Diagnostics v1.1.2 (Instant Boot) ---

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
    local str1=" MDesign Health Scanner 1.1.2 "
    local str2=" IP: $s_ip "
    local raw_len=$(( ${#str1} + 1 + ${#str2} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

run_ping_diagnostics() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "\n  ${R}● No tunnels configured for diagnostics.${NC}"; sleep 2; return
    fi

    echo -e "\n  ${Y}● Running Deep Ping Diagnostics (10 Packets per Tunnel)... Please Wait.${NC}"
    echo -e "  ${B}╭────────────────┬────────────────────┬───────────┬──────────────┬──────────────┬───────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-14s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} ${W}%-9s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-13s${NC} ${B}│${NC}\n" "TUNNEL" "REMOTE IP" "LOSS %" "AVG LATENCY" "JITTER (dev)" "STATUS"
    echo -e "  ${B}├────────────────┼────────────────────┼───────────┼──────────────┼──────────────┼───────────────┤${NC}"

    for conf in "${configs[@]}"; do
        source "$conf"
        local main_tip=$([ "$TYPE" == "1" ] && echo "10.76.${TUN_ID}.2" || echo "10.76.${TUN_ID}.1")
        
        local ping_stats=$(ping -c 10 -i 0.2 -q "$main_tip" 2>/dev/null)
        local loss="100%"
        local avg_lat="---"
        local jitter="---"
        local status_text="● FAIL"
        local stat_color="${R}"

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
                else status_text="● BAD"; stat_color="${R}"; fi
            fi
            loss="${loss}%"
        fi

        local t_name_short="${T_NAME:0:14}"
        printf "  ${B}│${NC} ${C}%-14s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${stat_color}%-9s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${stat_color}%-13s${NC} ${B}│${NC}\n" "$t_name_short" "$main_tip" "$loss" "$avg_lat" "$jitter" "$status_text"
    done
    echo -e "  ${B}╰────────────────┴────────────────────┴───────────┴──────────────┴──────────────┴───────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

run_speedtest() {
    # چک کردن و نصب پکیج iperf3 دقیقاً در زمان نیاز
    if ! command -v iperf3 >/dev/null 2>&1; then
        echo -e "\n  ${Y}● Core dependency 'iPerf3' is missing. Installing now...${NC}"
        echo -e "  ${DIM}├─ Updating package mirrors...${NC}"
        apt-get update -y
        echo -e "  ${DIM}└─ Installing iperf3 multiplexer...${NC}"
        apt-get install -y iperf3
        if ! command -v iperf3 >/dev/null 2>&1; then
            echo -e "\n  ${R}● Critical Error: Installation failed. Check server internet or mirrors.${NC}"
            sleep 2.5; return
        fi
    fi

    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return; fi
    
    echo -e "\n  ${B}╭────────────────── Select Tunnel for Speedtest ──────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        local conf_name=$(basename "${configs[$i]}" .conf)
        printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-55s${NC} ${B}│${NC}\n" "$i" "$conf_name"
    done
    echo -e "  ${B}╰───────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Tunnel Index: ${NC}"; read -t 20 t_idx
    
    if [[ -n "${configs[$t_idx]}" ]]; then
        source "${configs[$t_idx]}"
        local main_lip=$([ "$TYPE" == "1" ] && echo "10.76.${TUN_ID}.1" || echo "10.76.${TUN_ID}.2")
        local main_tip=$([ "$TYPE" == "1" ] && echo "10.76.${TUN_ID}.2" || echo "10.76.${TUN_ID}.1")

        echo -e "\n  ${DIM}┌─[ SPEEDTEST MODE ]${NC}"
        echo -e "  ${DIM}│${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Run as Receiver (Server)${NC} ${DIM}- Listens for incoming test${NC}"
        echo -e "  ${DIM}│${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Run as Sender (Client)${NC} ${DIM}- Starts the speedtest${NC}"
        echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read st_mode

        if [ "$st_mode" == "1" ]; then
            pkill iperf3 2>/dev/null
            iperf3 -s -B "$main_lip" -D >/dev/null 2>&1
            echo -e "\n  ${G}● Receiver Mode Activated!${NC}"
            echo -e "  ${DIM}├─ iPerf3 is listening on Local IP: ${W}${main_lip}${NC}"
            echo -e "  ${DIM}└─ Go to the OTHER server, select this tunnel, and run as 'Sender'.${NC}"
            echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read

        elif [ "$st_mode" == "2" ]; then
            echo -e "\n  ${Y}● Initiating 10-Second Throughput Test to ${main_tip}...${NC}"
            echo -e "  ${DIM}├─ Measuring Bandwidth. Please wait...${NC}"
            
            local result=$(iperf3 -c "$main_tip" -t 10 --format m 2>&1)
            
            if echo "$result" | grep -q "Connection refused"; then
                echo -e "  ${DIM}│${NC}\n  ${R}● Connection Refused!${NC}"
                echo -e "  ${DIM}└─ You must activate 'Receiver (Server)' mode on the remote server first.${NC}"
            elif echo "$result" | grep -q "error"; then
                echo -e "  ${DIM}│${NC}\n  ${R}● Test Failed! Check tunnel connectivity (Ping) first.${NC}"
            else
                local sender_speed=$(echo "$result" | grep "sender" | awk '{print $7" "$8}')
                local receiver_speed=$(echo "$result" | grep "receiver" | awk '{print $7" "$8}')
                [ -z "$sender_speed" ] && sender_speed=$(echo "$result" | grep "sec" | tail -1 | awk '{print $7" "$8}')
                
                echo -e "  ${DIM}│${NC}"
                echo -e "  ${B}╭──────────────────────────────────────────────────╮${NC}"
                printf "  ${B}│${NC} ${W}%-15s${NC} ${C}❯❯${NC}  ${G}%-26s${NC} ${B}│${NC}\n" "Upload Speed" "$sender_speed"
                printf "  ${B}│${NC} ${W}%-15s${NC} ${C}❯❯${NC}  ${G}%-26s${NC} ${B}│${NC}\n" "Download Speed" "${receiver_speed:-$sender_speed}"
                echo -e "  ${B}╰──────────────────────────────────────────────────╯${NC}"
                echo -e "  ${G}● Test Completed Successfully.${NC}"
                pkill iperf3 2>/dev/null
            fi
            echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
        else
            echo -e "  ${R}● Invalid selection!${NC}"; sleep 1.5
        fi
    else
        echo -e "  ${R}● Invalid selection!${NC}"; sleep 1.5
    fi
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ NETWORK DIAGNOSTICS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Deep Ping & Latency Scan (All Tunnels)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Tunnel Throughput Speedtest (iPerf3)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}"
    echo ""
    echo -ne "  ${C}MDiag ❯❯ ${NC}"; read -t 60 opt
    
    case $opt in
        1) run_ping_diagnostics ;;
        2) run_speedtest ;;
        0) clear; exit 0 ;;
        *) echo -e "  ${R}● Invalid selection!${NC}"; sleep 1 ;;
    esac
done
