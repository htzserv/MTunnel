#!/bin/bash
# --- MDesign Modular Core (mstats.sh) | Omni-Radar & Stats v3.4.0 (MWeb Integrated) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_BH="/etc/mbackhaul/tunnels"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MStats Omni-Radar & Stats v3.4.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC}                           ${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_hardware() {
    draw_header
    echo -e "\n  ${M}● Scanning Hardware & System Metrics...${NC}"
    
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    local mem_info=$(free -m | grep Mem)
    local ram_total=$(echo $mem_info | awk '{print $2}')
    local ram_used=$(echo $mem_info | awk '{print $3}')
    local ram_percent=$(awk "BEGIN {printf \"%.1f\", ($ram_used/$ram_total)*100}")
    local disk_total=$(df -h / | awk 'NR==2 {print $2}')
    local disk_used=$(df -h / | awk 'NR==2 {print $3}')
    local disk_percent=$(df -h / | awk 'NR==2 {print $5}')
    local uptime=$(uptime -p | sed 's/up //')
    local load=$(uptime | awk -F'load average:' '{ print $2 }' | xargs)

    echo -e "\n  ${B}╭────────────────── SYSTEM METRICS ──────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-15s${NC} ${DIM}❯${NC} ${C}%-32s${NC} ${B}│${NC}\n" "CPU Usage" "${cpu_usage}%"
    printf "  ${B}│${NC} ${W}%-15s${NC} ${DIM}❯${NC} ${M}%-32s${NC} ${B}│${NC}\n" "RAM Usage" "${ram_used}MB / ${ram_total}MB (${ram_percent}%)"
    printf "  ${B}│${NC} ${W}%-15s${NC} ${DIM}❯${NC} ${Y}%-32s${NC} ${B}│${NC}\n" "Disk Usage (/)" "${disk_used} / ${disk_total} (${disk_percent})"
    printf "  ${B}│${NC} ${W}%-15s${NC} ${DIM}❯${NC} ${G}%-32s${NC} ${B}│${NC}\n" "System Uptime" "${uptime}"
    printf "  ${B}│${NC} ${W}%-15s${NC} ${DIM}❯${NC} ${DIM}%-32s${NC} ${B}│${NC}\n" "Load Average" "${load}"
    echo -e "  ${B}╰────────────────────────────────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

show_connections() {
    draw_header
    echo -e "\n  ${Y}● Analyzing Active Network Connections...${NC}"
    
    local tcp_estab=$(ss -tn state established 2>/dev/null | wc -l)
    local tcp_estab=$((tcp_estab - 1)); [ "$tcp_estab" -lt 0 ] && tcp_estab=0
    local tcp_time=$(ss -tn state time-wait 2>/dev/null | wc -l)
    local tcp_time=$((tcp_time - 1)); [ "$tcp_time" -lt 0 ] && tcp_time=0
    local udp_total=$(ss -un 2>/dev/null | wc -l)
    local udp_total=$((udp_total - 1)); [ "$udp_total" -lt 0 ] && udp_total=0

    echo -e "\n  ${B}╭──────────────── CONNECTION STATES ─────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-20s${NC} ${DIM}❯${NC} ${G}%-28s${NC} ${B}│${NC}\n" "TCP Established" "${tcp_estab}"
    printf "  ${B}│${NC} ${W}%-20s${NC} ${DIM}❯${NC} ${Y}%-28s${NC} ${B}│${NC}\n" "TCP Time-Wait" "${tcp_time}"
    printf "  ${B}│${NC} ${W}%-20s${NC} ${DIM}❯${NC} ${C}%-28s${NC} ${B}│${NC}\n" "UDP Active" "${udp_total}"
    echo -e "  ${B}├────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC} ${M}Top 5 Connected Foreign IPs:${NC}                       ${B}│${NC}"
    
    local top_ips=$(ss -ntu 2>/dev/null | awk '{print $5}' | cut -d: -f1 | grep -E "^[0-9]" | grep -v "127.0.0.1" | sort | uniq -c | sort -nr | head -n 5)
    if [ -z "$top_ips" ]; then
        printf "  ${B}│${NC} ${DIM}%-50s${NC} ${B}│${NC}\n" "No external connections found."
    else
        while read count ip; do
            printf "  ${B}│${NC}   ${DIM}▪${NC} ${W}%-15s${NC} ${DIM}━ ${C}%-5s${NC} ${DIM}connections         ${B}│${NC}\n" "$ip" "$count"
        done <<< "$top_ips"
    fi
    echo -e "  ${B}╰────────────────────────────────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

run_speedtest() {
    draw_header
    echo -e "\n  ${C}● Checking Speedtest-CLI module...${NC}"
    if ! command -v speedtest-cli >/dev/null 2>&1; then
        echo -e "  ${DIM}Installing speedtest-cli for the first time...${NC}"
        apt-get update -q -y >/dev/null 2>&1
        apt-get install -q -y speedtest-cli >/dev/null 2>&1
    fi
    echo -e "  ${Y}● Running Network Speed Test. Please wait (Takes ~20s)...${NC}\n"
    speedtest-cli --simple | sed 's/^/    /'
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

run_iperf3() {
    draw_header
    echo -e "\n  ${C}● Checking iperf3 module...${NC}"
    if ! command -v iperf3 >/dev/null 2>&1; then
        echo -e "  ${DIM}Installing iperf3 for the first time...${NC}"
        apt-get update -q -y >/dev/null 2>&1
        apt-get install -q -y iperf3 >/dev/null 2>&1
    fi

    echo -e "\n  ${DIM}┌─[ IPERF3 SERVER-TO-SERVER BANDWIDTH TEST ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run as Server${NC} ${DIM}(Listen for connections)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run as Client${NC} ${DIM}(Test Speed to another Server)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Mode ❯❯ ${NC}"; read iperf_mode
    iperf_mode=$(echo "$iperf_mode" | tr -d '\r' | tr -d ' ')

    case $iperf_mode in
        1)
            echo -ne "  ${C}●${NC} ${W}Listen Port [5201]: ${NC}"; read i_port
            i_port=$(echo "$i_port" | tr -d '\r' | tr -d ' ')
            [ -z "$i_port" ] && i_port=5201
            
            iptables -I INPUT -p tcp --dport "$i_port" -j ACCEPT 2>/dev/null
            iptables -I INPUT -p udp --dport "$i_port" -j ACCEPT 2>/dev/null
            
            echo -e "\n  ${G}● iperf3 Server is RUNNING on port ${i_port}...${NC}"
            echo -e "  ${DIM}Press [Ctrl+C] to stop listening.${NC}\n"
            iperf3 -s -p "$i_port"
            ;;
        2)
            echo -ne "  ${C}●${NC} ${W}Target Server IP: ${NC}"; read i_ip
            i_ip=$(echo "$i_ip" | tr -d '\r' | tr -d ' ')
            [ -z "$i_ip" ] && return
            
            echo -ne "  ${C}●${NC} ${W}Target Port [5201]: ${NC}"; read i_port
            i_port=$(echo "$i_port" | tr -d '\r' | tr -d ' ')
            [ -z "$i_port" ] && i_port=5201
            
            echo -ne "  ${C}●${NC} ${W}Test Mode [1: Upload to Target | 2: Download from Target (Reverse)]: ${NC}"; read i_rev
            i_rev=$(echo "$i_rev" | tr -d '\r' | tr -d ' ')
            
            local rev_flag=""; local threads="-P 4"
            [ "$i_rev" == "2" ] && rev_flag="-R"
            
            echo -e "\n  ${Y}● Initiating iperf3 Client (4 Threads) to ${i_ip}:${i_port}...${NC}\n"
            iperf3 -c "$i_ip" -p "$i_port" $threads $rev_flag
            echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
            ;;
        0) return ;;
        *) echo -e "  ${R}● Invalid option!${NC}"; sleep 1 ;;
    esac
}

live_interfaces_radar() {
    draw_header
    echo -e "\n  ${M}● Initializing Layer-3 Interface Radar...${NC}"
    
    local ifaces=()
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -vE "^lo$|^eth|^ens|^eno"); do
        ifaces+=("$iface")
    done

    if [ ${#ifaces[@]} -eq 0 ]; then
        echo -e "  ${R}● No MDesign Tunnel Interfaces found!${NC}"; sleep 2; return
    fi

    echo -e "  ${DIM}Press [Ctrl+C] to exit radar.${NC}\n"
    
    declare -A last_rx; declare -A last_tx
    for iface in "${ifaces[@]}"; do
        last_rx[$iface]=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        last_tx[$iface]=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
    done

    trap 'tput cnorm; return' SIGINT
    tput civis
    while true; do
        printf "\r\033[K  ${B}╭──────────────┬────────────────────────┬────────────────────────╮${NC}\n"
        printf "\r\033[K  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${G}%-22s${NC} ${B}│${NC} ${C}%-22s${NC} ${B}│${NC}\n" "INTERFACE" "DOWNLOAD (RX)" "UPLOAD (TX)"
        printf "\r\033[K  ${B}├──────────────┼────────────────────────┼────────────────────────┤${NC}\n"
        
        for iface in "${ifaces[@]}"; do
            local cur_rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
            local cur_tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
            
            local rx_diff=$(( cur_rx - ${last_rx[$iface]:-0} ))
            local tx_diff=$(( cur_tx - ${last_tx[$iface]:-0} ))
            
            local rx_mbps=$(echo "$rx_diff" | awk '{printf "%.2f Mbps", $1 * 8 / 1024 / 1024}')
            local tx_mbps=$(echo "$tx_diff" | awk '{printf "%.2f Mbps", $1 * 8 / 1024 / 1024}')
            
            printf "\r\033[K  ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${G}▼ %-20s${NC} ${B}│${NC} ${C}▲ %-20s${NC} ${B}│${NC}\n" "$iface" "$rx_mbps" "$tx_mbps"
            
            last_rx[$iface]=$cur_rx; last_tx[$iface]=$cur_tx
        done
        printf "\r\033[K  ${B}╰──────────────┴────────────────────────┴────────────────────────╯${NC}\n"
        
        sleep 1
        printf "\033[%dA" $(( ${#ifaces[@]} + 4 ))
    done
    tput cnorm
}

clean_bh_rules() {
    iptables -S INPUT 2>/dev/null | grep "MBH_RX_" | sed 's/^-A /-D /' | while read rule; do iptables $rule 2>/dev/null; done
    iptables -S OUTPUT 2>/dev/null | grep "MBH_TX_" | sed 's/^-A /-D /' | while read rule; do iptables $rule 2>/dev/null; done
}

setup_bh_rules() {
    clean_bh_rules
    for conf in "$CONF_BH"/*.toml; do
        [ ! -f "$conf" ] && continue
        local name=$(basename "$conf" .toml)
        
        if grep -q "\[server\]" "$conf"; then
            local port=$(grep 'bind =' "$conf" | grep -oP ':[0-9]+' | head -1 | tr -d ':')
            if [ -n "$port" ]; then
                iptables -I INPUT -p tcp --dport $port -m comment --comment "MBH_RX_${name}" 2>/dev/null
                iptables -I INPUT -p udp --dport $port -m comment --comment "MBH_RX_${name}" 2>/dev/null
                iptables -I OUTPUT -p tcp --sport $port -m comment --comment "MBH_TX_${name}" 2>/dev/null
                iptables -I OUTPUT -p udp --sport $port -m comment --comment "MBH_TX_${name}" 2>/dev/null
            fi
        elif grep -q "\[client\]" "$conf"; then
            local remote=$(grep 'remote =' "$conf" | grep -oP '"\K[^"]+' | cut -d'?' -f1)
            local r_ip=$(echo "$remote" | cut -d: -f1); local r_port=$(echo "$remote" | cut -d: -f2)
            if [ -n "$r_ip" ] && [ -n "$r_port" ]; then
                iptables -I INPUT -s $r_ip -p tcp --sport $r_port -m comment --comment "MBH_RX_${name}" 2>/dev/null
                iptables -I INPUT -s $r_ip -p udp --sport $r_port -m comment --comment "MBH_RX_${name}" 2>/dev/null
                iptables -I OUTPUT -d $r_ip -p tcp --dport $r_port -m comment --comment "MBH_TX_${name}" 2>/dev/null
                iptables -I OUTPUT -d $r_ip -p udp --dport $r_port -m comment --comment "MBH_TX_${name}" 2>/dev/null
            fi
        fi
    done
}

get_bh_bytes() {
    local node=$1; local dir=$2
    local bytes=$(iptables -xnvL 2>/dev/null | grep "MBH_${dir}_${node}" | awk '{sum+=$2} END {print sum}')
    echo "${bytes:-0}"
}

live_backhaul_radar() {
    draw_header
    local configs=($(ls "$CONF_BH"/*.toml 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "\n  ${R}● No Backhaul nodes configured!${NC}"; sleep 2; return
    fi

    echo -e "\n  ${Y}● Injecting Phantom L4 Trackers into Kernel...${NC}"
    setup_bh_rules
    echo -e "  ${DIM}Press [Ctrl+C] to exit radar and clean rules.${NC}\n"
    
    declare -A last_rx; declare -A last_tx
    for conf in "${configs[@]}"; do
        local name=$(basename "$conf" .toml)
        last_rx[$name]=$(get_bh_bytes "$name" "RX")
        last_tx[$name]=$(get_bh_bytes "$name" "TX")
    done

    trap 'clean_bh_rules; tput cnorm; return' SIGINT
    tput civis
    
    while true; do
        printf "\r\033[K  ${B}╭──────────────┬──────────┬────────────────────────┬────────────────────────╮${NC}\n"
        printf "\r\033[K  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${M}%-8s${NC} ${B}│${NC} ${G}%-22s${NC} ${B}│${NC} ${C}%-22s${NC} ${B}│${NC}\n" "BH NODE" "MODE" "DOWNLOAD (RX)" "UPLOAD (TX)"
        printf "\r\033[K  ${B}├──────────────┼──────────┼────────────────────────┼────────────────────────┤${NC}\n"
        
        for conf in "${configs[@]}"; do
            local name=$(basename "$conf" .toml)
            local mode="Unknown"; local m_color=""
            if grep -q "\[server\]" "$conf"; then mode="Server"; m_color="${Y}"; fi
            if grep -q "\[client\]" "$conf"; then mode="Client"; m_color="${C}"; fi

            local cur_rx=$(get_bh_bytes "$name" "RX")
            local cur_tx=$(get_bh_bytes "$name" "TX")
            
            local rx_diff=$(( cur_rx - ${last_rx[$name]:-0} ))
            local tx_diff=$(( cur_tx - ${last_tx[$name]:-0} ))
            
            [ "$rx_diff" -lt 0 ] && rx_diff=0
            [ "$tx_diff" -lt 0 ] && tx_diff=0
            
            local rx_mbps=$(echo "$rx_diff" | awk '{printf "%.2f Mbps", $1 * 8 / 1024 / 1024}')
            local tx_mbps=$(echo "$tx_diff" | awk '{printf "%.2f Mbps", $1 * 8 / 1024 / 1024}')
            
            printf "\r\033[K  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${m_color}%-8s${NC} ${B}│${NC} ${G}▼ %-20s${NC} ${B}│${NC} ${C}▲ %-20s${NC} ${B}│${NC}\n" "$name" "$mode" "$rx_mbps" "$tx_mbps"
            
            last_rx[$name]=$cur_rx; last_tx[$name]=$cur_tx
        done
        printf "\r\033[K  ${B}╰──────────────┴──────────┴────────────────────────┴────────────────────────╯${NC}\n"
        
        sleep 1
        printf "\033[%dA" $(( ${#configs[@]} + 4 ))
    done
}

# --- NEW: Launch Web Dashboard ---
launch_mweb() {
    if [ -x "/usr/bin/mweb" ]; then
        echo -e "\n  ${G}● Launching MDesign Web Enterprise UI...${NC}"
        echo -e "  ${DIM}Press [Ctrl+C] to stop the web server.${NC}\n"
        /usr/bin/mweb
    elif [ -f "/root/mtunnel/mweb.sh" ]; then
        echo -e "\n  ${G}● Launching MDesign Web Enterprise UI...${NC}"
        echo -e "  ${DIM}Press [Ctrl+C] to stop the web server.${NC}\n"
        bash /root/mtunnel/mweb.sh
    else
        echo -e "\n  ${R}● MWeb module not found! Please run the installer (Install Core Scripts) to sync it.${NC}"
        sleep 2
    fi
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ LIVE NETWORK RADAR & STATS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Hardware & Resource Radar${NC} ${DIM}(CPU, RAM, Disk, Uptime)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Active Connections Analyzer${NC} ${DIM}(Live TCP/UDP Tracker)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}L3 Interfaces Bandwidth${NC} ${DIM}(GRE, VXLAN, Wireguard, L2TP)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}L4 Backhaul Bandwidth${NC}   ${DIM}(TCP/UDP/QUIC Multiplexer)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${W}Internet Speed Test${NC}     ${DIM}(Speedtest-CLI Engine)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Server-to-Server Speed${NC} ${DIM}(iperf3 Engine)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${C}MDesign Web Dashboard${NC}  ${DIM}(Launch Enterprise UI)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MSTATS ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r' | tr -d ' ')

    case $opt in
        1) show_hardware ;;
        2) show_connections ;;
        3) live_interfaces_radar ;;
        4) live_backhaul_radar ;;
        5) run_speedtest ;;
        6) run_iperf3 ;;
        7) launch_mweb ;;
        0) break ;;
    esac
done
