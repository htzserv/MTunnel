#!/bin/bash
# --- MDesign Modular Core (mdiag.sh) | MDiag Omni-Scanner v4.0.0 (Full Edition) ---
# [PATCHED: Safe Variable Reset matching 1.sh logic]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'

GRE_DIR="/etc/mgre/tunnels"
VX_DIR="/etc/mgre/vxlan"
L2TP_DIR="/etc/ml2tp/tunnels"
HYS_DIR="/etc/mhysteria/tunnels"
WG_CONF="/etc/wireguard/wg0.conf"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_progress_bar() {
    local pid=$1; local text=$2; local width=25; local progress=0
    tput civis
    while kill -0 $pid 2>/dev/null; do
        progress=$((progress + 1)); [ $progress -gt 95 ] && progress=95
        local filled=$(( progress * width / 100 )); local empty=$(( width - filled ))
        local bar=$(printf "%${filled}s" | tr ' ' '#'); local empty_bar=$(printf "%${empty}s" | tr ' ' '-')
        printf "\r  ${C}⟳${NC} ${W}%-22s${NC} ${M}[${bar}${DIM}${empty_bar}${M}]${NC} ${C}%3d%%${NC}" "$text" "$progress"
        sleep 0.15
    done
    local bar=$(printf "%${width}s" | tr ' ' '#')
    printf "\r  ${G}✔${NC} ${W}%-22s${NC} ${G}[${bar}]${NC} ${G}100%%${NC} \n" "$text"
    tput cnorm
}

draw_mdiag_header() {
    local s_ip=$(get_local_ip)
    local gre_c=$(ls -1 "$GRE_DIR"/*.conf 2>/dev/null | wc -l)
    local vx_c=$(ls -1 "$VX_DIR"/*.conf 2>/dev/null | wc -l)
    local l2tp_c=$(ls -1 "$L2TP_DIR"/*.conf 2>/dev/null | wc -l)
    local hys_c=$(ls -1 "$HYS_DIR"/*.conf 2>/dev/null | wc -l)
    local wg_c=0; [ -f "$WG_CONF" ] && wg_c=1
    local total_nodes=$((gre_c + vx_c + l2tp_c + hys_c + wg_c))

    clear; echo ""
    local str1=" MDiag Omni-Scanner 4.0.0 "
    local str2=" IP: $s_ip "
    local str3=" NODES DETECTED: $total_nodes "
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} NODES DETECTED:${NC}${C} ${total_nodes} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

run_full_infrastructure_scan() {
    echo -e "\n  ${DIM}┌─[ OMNI-SCAN MATRIX ]${NC}"
    echo -e "  ${B}╭───────────────┬────────────┬──────────────────────┬──────────────┬──────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-13s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC}\n" "INTERFACE" "PROTOCOL" "PUBLIC PEER IP" "STATE" "LATENCY"
    echo -e "  ${B}├───────────────┼────────────┼──────────────────────┼──────────────┼──────────────┤${NC}"

    local has_any=false

    for conf in "$GRE_DIR"/*.conf "$VX_DIR"/*.conf "$L2TP_DIR"/*.conf "$HYS_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; has_any=true; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; source "$conf"
        
        local proto_lbl="GRE L3"; local iface="$T_NAME"
        if [ -n "$BR_NAME" ]; then proto_lbl="VXLAN L2"; iface="$BR_NAME"; fi
        [[ "$conf" == *"/ml2tp/"* ]] && proto_lbl="L2TPv3"
        [[ "$conf" == *"/mhysteria/"* ]] && proto_lbl="Hysteria2"
        [[ "$TUN_PROTO" == "6to4" ]] && proto_lbl="IP6GRE"

        local state_color="${R}"; local state_text="DOWN"; local lat_color="${DIM}"; local lat_text="---"
        if ip link show "$iface" >/dev/null 2>&1; then
            if [ "$(cat /sys/class/net/$iface/operstate 2>/dev/null)" != "down" ]; then state_color="${G}"; state_text="UP"; fi
            local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
            local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
            ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
            if [ $? -eq 0 ]; then
                local ms=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_text="${ms}ms"; lat_color="${Y}"; state_text="ONLINE"; state_color="${G}"
            else state_text="OFFLINE"; state_color="${R}"; fi
        fi
        printf "  ${B}│${NC} ${C}%-13s${NC} ${B}│${NC} ${DIM}%-10s${NC} ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC}\n" "$iface" "$proto_lbl" "$REMOTE_PUB" "$state_color" "$state_text" "$NC" "$lat_color" "$lat_text" "$NC"
    done

    if [ -f "$WG_CONF" ]; then
        has_any=true
        local state_color="${R}"; local state_text="DOWN"; local lat_color="${DIM}"; local lat_text="---"
        if ip link show wg0 >/dev/null 2>&1; then
            state_color="${G}"; state_text="UP"
            local handshakes=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
            local is_online=false; local now=$(date +%s)
            for hs in $handshakes; do
                if [ "$hs" != "0" ] && [ $((now - hs)) -lt 180 ]; then is_online=true; break; fi
            done
            if [ "$is_online" = true ]; then state_color="${G}"; state_text="ONLINE"; lat_color="${G}"; lat_text="Active"
            else state_color="${Y}"; state_text="IDLE"; fi
        fi
        local active_peers=$(wg show wg0 peers 2>/dev/null | wc -l)
        printf "  ${B}│${NC} ${G}%-13s${NC} ${B}│${NC} ${DIM}%-10s${NC} ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC}\n" "wg0" "WG Crypto" "${active_peers} Peers Reg." "$state_color" "$state_text" "$NC" "$lat_color" "$lat_text" "$NC"
    fi

    if [ "$has_any" = false ]; then printf "  ${B}│${NC} ${DIM}%-76s${NC} ${B}│${NC}\n" "No tunnel interfaces detected in the system."; fi
    echo -e "  ${B}╰───────────────┴────────────┴──────────────────────┴──────────────┴──────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

deep_ping_analysis() {
    echo -e "\n  ${DIM}┌─[ DEEP PING & PACKET LOSS TEST ]${NC}"
    local all_ips=()
    for conf in "$GRE_DIR"/*.conf "$VX_DIR"/*.conf "$L2TP_DIR"/*.conf "$HYS_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; source "$conf"
        local tip=""
        if [ -n "$TUN_ID" ]; then
            local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
            tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        elif [ -n "$VNI_ID" ]; then
            local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
            tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        fi
        [ -n "$tip" ] && all_ips+=("$tip")
    done

    if [ ${#all_ips[@]} -eq 0 ]; then echo -e "  ${R}● No testable endpoints found.${NC}"; sleep 2; return; fi

    for target in "${all_ips[@]}"; do
        echo -e "\n  ${C}● Testing Core IP: ${W}${target}${NC}"
        local tmp_file=$(mktemp)
        (ping -c 10 -i 0.2 -W 1 "$target" > "$tmp_file" 2>&1) &
        draw_progress_bar $! "Sending 10 Packets"
        local loss=$(grep -oP '\d+(?=% packet loss)' "$tmp_file")
        local avg_lat=$(grep -oP 'min/avg/max/mdev = \K[^/]+/[^/]+' "$tmp_file" | cut -d/ -f2)
        if [ -z "$loss" ]; then loss="100"; fi
        local c_loss="${G}"; [ "$loss" -gt 0 ] && c_loss="${Y}"; [ "$loss" -gt 50 ] && c_loss="${R}"
        local c_lat="${G}"; [ "${avg_lat%.*}" -gt 150 ] 2>/dev/null && c_lat="${Y}"; [ -z "$avg_lat" ] && c_lat="${R}"
        echo -e "  ${DIM}├─ Packet Loss :${NC} ${c_loss}${loss}%${NC}"
        echo -e "  ${DIM}└─ Avg Latency :${NC} ${c_lat}${avg_lat:-N/A} ms${NC}"
        rm -f "$tmp_file"
    done
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

check_mtu_routing() {
    echo -e "\n  ${DIM}┌─[ MTU & ROUTING MATRIX ]${NC}"
    echo -e "  ${B}╭───────────────┬──────┬──────────────────────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-13s${NC} ${B}│${NC} ${W}%-4s${NC} ${B}│${NC} ${W}%-56s${NC} ${B}│${NC}\n" "INTERFACE" "MTU" "TCPMSS / ROUTING STATUS"
    echo -e "  ${B}├───────────────┼──────┼──────────────────────────────────────────────────────────┤${NC}"

    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(gre|br_|vx_|wg|l2tp_|hys_)'); do
        local mtu=$(ip -o link show "$iface" | grep -oP 'mtu \K\d+')
        local mss_rule=$(iptables -t mangle -S FORWARD 2>/dev/null | grep -w "$iface" | grep TCPMSS | head -n 1)
        local stat_color="${DIM}"; local stat_text="Standard L2/L3 Routing"
        if [ -n "$mss_rule" ]; then
            local clamp=$(echo "$mss_rule" | grep -oP '--set-mss \K\d+')
            stat_color="${G}"; stat_text="TCPMSS Clamped to ${clamp}"
        elif [[ "$iface" == "wg0" ]] || [[ "$iface" == hys_* ]]; then stat_color="${M}"; stat_text="Crypto Kernel Routing"; fi
        printf "  ${B}│${NC} ${C}%-13s${NC} ${B}│${NC} ${Y}%-4s${NC} ${B}│${NC} %b%-56s%b ${B}│${NC}\n" "$iface" "$mtu" "$stat_color" "$stat_text" "$NC"
    done
    echo -e "  ${B}╰───────────────┴──────┴──────────────────────────────────────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

while true; do
    draw_mdiag_header
    echo -e "\n  ${DIM}┌─[ DIAGNOSTIC ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Omni-Scan Infrastructure${NC} ${DIM}(GRE, VXLAN, L2TP, HYS2, WG)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Deep Ping & Packet Loss Test${NC} ${DIM}(Quality Check)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}MTU & TCPMSS Routing Matrix${NC} ${DIM}(Fragmentation Check)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MDIAG ❯❯ ${NC}"; read opt
    case $opt in
        1) run_full_infrastructure_scan ;; 2) deep_ping_analysis ;; 3) check_mtu_routing ;; 0) break ;;
    esac
done
