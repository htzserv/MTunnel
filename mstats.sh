#!/bin/bash
# --- MDesign Modular Core (mstats.sh) | Bandwidth Radar v3.1.0 (Pixel-Perfect Alignment) ---

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
    echo -e "  ${B}│${NC} ${W}MStats Bandwidth Radar v3.1.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC}                              ${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
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

    trap 'return' SIGINT
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
            
            # Use ANSI safely in printf for alignment
            printf "\r\033[K  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${m_color}%-8s${NC} ${B}│${NC} ${G}▼ %-20s${NC} ${B}│${NC} ${C}▲ %-20s${NC} ${B}│${NC}\n" "$name" "$mode" "$rx_mbps" "$tx_mbps"
            
            last_rx[$name]=$cur_rx; last_tx[$name]=$cur_tx
        done
        printf "\r\033[K  ${B}╰──────────────┴──────────┴────────────────────────┴────────────────────────╯${NC}\n"
        
        sleep 1
        printf "\033[%dA" $(( ${#configs[@]} + 4 ))
    done
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ LIVE NETWORK RADAR ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}L3 Interfaces Radar${NC} ${DIM}(GRE, VXLAN, Wireguard, L2TP)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Backhaul L4 Radar${NC}   ${DIM}(Live TCP/UDP/QUIC Multiplexer Stats)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MSTATS ❯❯ ${NC}"; read opt

    case $opt in
        1) live_interfaces_radar ;;
        2) live_backhaul_radar ;;
        0) break ;;
    esac
done
