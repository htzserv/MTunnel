#!/bin/bash
# --- ML2TP Modular Core (ml2tp.sh) | MDesign Core v2.1.0 (Sanitized) ---
# [PATCHED: Safe Variable Reset matching 1.sh logic + Orphan Cleanup]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/ml2tp/tunnels"
SERVICE_FILE="/etc/systemd/system/ml2tp.service"
STATE_DIR="/etc/ml2tp/states"
LOCAL_DIR="/root/mtunnel"

mkdir -p "$CONF_DIR" "$STATE_DIR" "$LOCAL_DIR/packages"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_progress_bar() {
    local pid=$1; local text=$2; local width=25; local progress=0
    tput civis
    while kill -0 $pid 2>/dev/null; do
        ((progress++)); if (( progress > 95 )); then progress=95; fi
        local filled=$(( progress * width / 100 )); local empty=$(( width - filled ))
        local bar=$(printf "%${filled}s" "" | tr ' ' '#'); local empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')
        printf "\r  %b⟳%b %b%-22s%b %b[%b%b%b%b]%b %b%3d%%%%%b" "$C" "$NC" "$W" "$text" "$NC" "$M" "$bar" "$DIM" "$empty_bar" "$M" "$NC" "$C" "$progress" "$NC"
        sleep 0.2
    done
    local bar=$(printf "%${width}s" "" | tr ' ' '#')
    printf "\r  %b✔%b %b%-22s%b %b[%b]%b %b100%%%%%b \n" "$G" "$NC" "$W" "$text" "$NC" "$G" "$bar" "$NC" "$G" "$NC"
    tput cnorm
}

check_dependencies() {
    local missing=0; modinfo l2tp_eth >/dev/null 2>&1 || missing=1
    if [ "$missing" -eq 1 ]; then
        echo -e "\n  ${DIM}● Injecting Native L2TP Kernel Modules...${NC}"
        (
            apt-get update -y -q >/dev/null 2>&1
            apt-get install --download-only -y -q iproute2 linux-modules-extra-$(uname -r) >/dev/null 2>&1
            cp -a /var/cache/apt/archives/*.deb "$LOCAL_DIR/packages/" 2>/dev/null
            dpkg -i "$LOCAL_DIR/packages"/*.deb >/dev/null 2>&1; apt-get install -f -y -q >/dev/null 2>&1
            modprobe l2tp_core l2tp_netlink l2tp_eth l2tp_ip 2>/dev/null
        ) >/dev/null 2>&1 &
        draw_progress_bar $! "Patching Linux Kernel"; sleep 1
    fi
}

apply_tunnel() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; source "$conf"
    
    local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
    local local_tun=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
    
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1360 >/dev/null 2>&1
    ip l2tp del session tunnel_id "$TUN_ID" session_id "$TUN_ID" >/dev/null 2>&1
    ip l2tp del tunnel tunnel_id "$TUN_ID" >/dev/null 2>&1; ip link del "$T_NAME" >/dev/null 2>&1
    modprobe l2tp_core l2tp_netlink l2tp_eth l2tp_ip 2>/dev/null

    local REAL_LOCAL=$(ip route get "$REMOTE_PUB" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1)
    [ -z "$REAL_LOCAL" ] && REAL_LOCAL=$(hostname -I | awk '{print $1}')

    ip l2tp add tunnel tunnel_id "$TUN_ID" peer_tunnel_id "$TUN_ID" encap udp local "$REAL_LOCAL" remote "$REMOTE_PUB" udp_sport "$TUN_PORT" udp_dport "$TUN_PORT" 2>/dev/null
    ip l2tp add session name "$T_NAME" tunnel_id "$TUN_ID" session_id "$TUN_ID" peer_session_id "$TUN_ID" 2>/dev/null
    ip link set dev "$T_NAME" mtu 1400 2>/dev/null; ip link set "$T_NAME" up 2>/dev/null
    ip addr add "$local_tun"/30 dev "$T_NAME" 2>/dev/null
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1360 2>/dev/null

    if [[ "$MAX_IPS" -gt 0 ]]; then
        local s_file="${STATE_DIR}/${T_NAME}.state"; echo "0" > "$s_file"
        for ((i=1; i<=MAX_IPS; i++)); do
            idx=$(cat "$s_file"); hash=$(echo "${SYNC_KEY}_${idx}" | sha256sum); range_selector=$(( 0x${hash:0:2} % 3 ))
            if [[ "$range_selector" == "0" ]]; then o1="10"; o2=$(( (0x${hash:2:2} % 254) + 1 ))
            elif [[ "$range_selector" == "1" ]]; then o1="172"; o2=$(( (0x${hash:2:2} % 16) + 16 ))
            else o1="192"; o2="168"; fi
            o3=$(( (0x${hash:4:2} % 254) + 1 )); last_octet=$([ "$TYPE" == "1" ] && echo "1" || echo "2")
            nip="$o1.$o2.$o3.$last_octet"
            ip addr add "$nip/30" dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null
            echo $((idx + 1)) > "$s_file"
        done
    fi
}

apply_all_tunnels() { for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && apply_tunnel "$conf"; done; }

setup_service() {
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=ML2TP Native Tunnel Service
After=network.target
[Service]
ExecStart=/usr/bin/ml2tp --apply
Type=oneshot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable ml2tp.service >/dev/null 2>&1
}

draw_ml2tp_header() {
    local s_ip=$(get_local_ip); local active_tunnels=0; local total_vips=0
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; source "$conf"
        if ip link show "$T_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" != "down" ]; then ((active_tunnels++)); fi
        total_vips=$((total_vips + MAX_IPS))
    done
    clear; echo ""
    local str1=" ML2TP Core 2.1.0 (Native L2TPv3) "
    local raw_len=$(( ${#str1} + 1 + 5 + ${#s_ip} + 1 + 17 + ${#active_tunnels} + 1 + 14 + ${#total_vips} ))
    local pad_len=$(( 92 - raw_len )); [ "$pad_len" -lt 0 ] && pad_len=0; local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} ACTIVE TUNNELS:${NC}${G} ${active_tunnels} ${NC}${B}│${NC}${DIM} TOTAL V-IPS:${NC}${Y} ${total_vips} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_ml2tp_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; source "$conf"
        mapfile -t v_ips < <(ip -4 addr show dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} %b▼ Tunnel: %-80s%b ${B}│${NC}\n" "${C}" "${T_NAME} [L2TPv3 Native]" "${NC}"
        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local main_lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        
        ping_res=$(ping -c 1 -W 1 "$main_tip" 2>/dev/null)
        if [ $? -eq 0 ]; then lat=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
        
        local m_icon="├─"; [ ${#v_ips[@]} -eq 0 ] && m_icon="└─"
        printf "  ${B}│${NC} ${W}%s %-15s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%s %-10s%b ${B}│${NC}\n" "${m_icon}" "Core IP" "$main_lip" "$main_tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        
        local total_v=${#v_ips[@]}
        for ((idx=0; idx<total_v; idx++)); do
            local lip="${v_ips[$idx]}"; local base_ip=$(echo "$lip" | cut -d'.' -f1-3); local last=$(echo "$lip" | cut -d'.' -f4); local tip="$base_ip.$([ "$last" == "1" ] && echo "2" || echo "1")"
            ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
            if [ $? -eq 0 ]; then lat=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
            else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
            local v_icon="│  ├─"; [ $idx -eq $((total_v - 1)) ] && v_icon="│  └─"
            printf "  ${B}│${NC} ${DIM}%s %-12s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%s %-10s%b ${B}│${NC}\n" "${v_icon}" "vIP" "$lip" "$tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        done
        echo -e "  ${B}╰────────────────────┴────────────────────┴────────────────────┴──────────────┴──────────────╯${NC}\n"
    done
}

show_tunnel_details() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return; fi

    echo -e "\n  ${Y}● Deployed L2TPv3 Registry:${NC}"
    for conf in "${configs[@]}"; do
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; source "$conf"
        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local s_key="${SYNC_KEY:-[ NOT SET ]}"

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $T_NAME"; local right_p="Role: $t_role"
        local pad=$(( 89 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp} ${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="vIP Sync Key : ${s_key}"; local r1="UDP Port: ${TUN_PORT} | Net ID: ${TUN_ID}"
        local pad1=$(( 89 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}vIP Sync Key :${NC} ${W}${s_key}${NC}${sp1} ${DIM}UDP Port:${NC} ${W}${TUN_PORT}${NC} ${DIM}| Net ID:${NC} ${W}${TUN_ID}${NC} ${B}│${NC}"
        
        local l3="Public IPs   : ${LOCAL_PUB} -> ${REMOTE_PUB}"
        local pad3=$(( 90 - ${#l3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${DIM}Public IPs   :${NC} ${W}${LOCAL_PUB}${NC} ${DIM}->${NC} ${W}${REMOTE_PUB}${NC}${sp3} ${B}│${NC}"
        
        ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
        if [ $? -eq 0 ]; then lat=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
        
        local l4="Core IPs     : ${lip} -> ${tip}"; local r4_raw="Link: * ${stat_text} (${lat_raw})"
        local pad4=$(( 89 - ${#l4} - ${#r4_raw} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Core IPs     :${NC} ${G}${lip}${NC} ${DIM}->${NC} ${Y}${tip}${NC}${sp4} ${DIM}Link:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${lat_color}(${lat_raw})${NC} ${B}│${NC}"
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

edit_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return; fi
    
    echo -e "\n  ${B}╭────────────────── Select Tunnel to Edit ───────────────────╮${NC}"
    for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
    echo -e "  ${B}├────────────────────────────────────────────────────────────┤${NC}"
    printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${DIM}%-53s${NC} ${B}│${NC}\n" "q" "Cancel and Return"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Tunnel Index or 'q': ${NC}"; read t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r')
    [[ "$t_idx" == "q" || -z "$t_idx" ]] && return
    
    if [[ -n "${configs[$t_idx]}" ]]; then
        local sel_conf="${configs[$t_idx]}"; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; source "$sel_conf"
        echo -e "\n  ${DIM}┌─[ HOT-SWAP PUBLIC IPs ]${NC}"
        echo -ne "  ${C}●${NC} ${W}New Local Public IP [${Y}${LOCAL_PUB}${W}] (Or Enter to Skip): ${NC}"; read new_local
        new_local=$(echo "$new_local" | tr -d '\r' | tr -d ' ')
        echo -ne "  ${C}●${NC} ${W}New Remote Public IP [${Y}${REMOTE_PUB}${W}] (Or Enter to Skip): ${NC}"; read new_remote
        new_remote=$(echo "$new_remote" | tr -d '\r' | tr -d ' ')
        [ -n "$new_local" ] && sed -i "s/^LOCAL_PUB=.*/LOCAL_PUB=$new_local/" "$sel_conf"
        [ -n "$new_remote" ] && sed -i "s/^REMOTE_PUB=.*/REMOTE_PUB=$new_remote/" "$sel_conf"
        apply_tunnel "$sel_conf"; echo -e "  ${G}● Pipeline re-routed successfully!${NC}"; sleep 1.5
    fi
}

if [[ "$1" == "--apply" ]]; then apply_all_tunnels; exit 0; fi

while true; do
    draw_ml2tp_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Setup New L2TPv3 Tunnel (UDP)${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Virtual IP Manager (Add/Purge vIPs)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Delete Tunnels (Specific / ALL)${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Edit Tunnel Public IPs (Hot-Swap)${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${C}View Tunnel Configurations & Ports${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit${NC}\n"
    echo -ne "  ${C}ML2TP ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1) 
           check_dependencies
           echo -e "\n  ${DIM}┌─[ TUNNEL PROTOCOL ]${NC}\n  ${DIM}├─${NC} ${C}L2TPv3 Native Engine (Layer 3 over UDP)${NC}\n  ${DIM}└────────────────────────────────────────────────────────${NC}"
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IRAN (Server) | 2:KHAREJ (Client) | q:Back]: ${NC}"; read s_type; s_type=$(echo "$s_type" | tr -d '\r' | tr -d ' '); [[ "$s_type" == "q" || "$s_type" == "1" || "$s_type" == "2" ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           while true; do echo -ne "  ${C}●${NC} ${W}Interface Suffix Name (Max 4 chars, e.g. fa): ${NC}"; read suffix; suffix=$(echo "$suffix" | tr -d '\r' | tr -d ' '); [[ "$suffix" == "q" ]] && break; [[ -z "$suffix" ]] && continue; t_name="l2tp_$suffix"; if [ "${#t_name}" -gt 15 ]; then echo -e "  ${R}● Error: Name too long!${NC}"; else break; fi; done
           [[ "$suffix" == "q" ]] && continue
           if [ -f "$CONF_DIR/${t_name}.conf" ]; then echo -e "\n  ${R}● Error: Interface [${W}${t_name}${R}] already exists!${NC}"; sleep 2; continue; fi
           local_ip=$(get_local_ip)
           while true; do echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}] (Enter for default): ${NC}"; read custom_ip; custom_ip=$(echo "$custom_ip" | tr -d '\r' | tr -d ' '); [ -n "$custom_ip" ] && local_ip=$custom_ip; break; done
           while true; do echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IP: ${NC}"; read r_ip; r_ip=$(echo "$r_ip" | tr -d '\r' | tr -d ' '); [[ -n "$r_ip" ]] && break; done
           while true; do echo -ne "  ${C}●${NC} ${W}L2TP UDP Connection Port (e.g. 5000): ${NC}"; read tun_port; tun_port=$(echo "$tun_port" | tr -d '\r' | tr -d ' '); [[ -n "$tun_port" ]] && break; done
           while true; do echo -ne "  ${C}●${NC} ${W}Tunnel Network ID (1-250): ${NC}"; read tun_id; tun_id=$(echo "$tun_id" | tr -d '\r' | tr -d ' '); if grep -q "TUN_ID=$tun_id$" "$CONF_DIR"/*.conf 2>/dev/null; then echo -e "  ${R}● Network ID in use!${NC}"; continue; fi; [[ -n "$tun_id" ]] && break; done
           
           hash_c=$(echo -n "core_${tun_id}" | sha256sum); class_selector=$(( tun_id % 3 ))
           if [ "$class_selector" == "1" ]; then c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           elif [ "$class_selector" == "2" ]; then c1="172"; c2=$(( (0x${hash:2:2} % 16) + 16 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           else c1="192"; c2="168"; c3=$(( (0x${hash_c:4:2} % 254) + 1 )); fi
           
           core_sub="${c1}.${c2}.${c3}"; conf_path="$CONF_DIR/${t_name}.conf"
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=\nTUN_PORT=$tun_port\nT_NAME=$t_name\nTUN_ID=$tun_id\nCORE_SUBNET=$core_sub" > "$conf_path"
           
           apply_tunnel "$conf_path"; setup_service
           if ip link show "$t_name" >/dev/null 2>&1; then echo -e "  ${G}● L2TPv3 Tunnel [${t_name}] deployed successfully!${NC}"; sleep 1.5
           else echo -e "\n  ${R}● FATAL ERROR: Kernel rejected tunnel!${NC}"; rm -f "$conf_path"; sleep 2; fi ;;
        2)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null)); [ ${#configs[@]} -eq 0 ] && echo -e "\n  ${R}● No tunnels configured yet!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel for vIPs ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Select Index: ${NC}"; read t_idx; t_idx=$(echo "$t_idx" | tr -d '\r')
           if [[ -n "${configs[$t_idx]}" ]]; then
               sel_conf="${configs[$t_idx]}"; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; source "$sel_conf"
               echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read n; n=$(echo "$n" | tr -d '\r')
               echo -ne "  ${C}●${NC} ${W}Sync Key: ${NC}"; read k; k=$(echo "$k" | tr -d '\r')
               sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$sel_conf"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$sel_conf"
               apply_tunnel "$sel_conf"; echo -e "  ${G}● IPs synchronized successfully.${NC}"; sleep 1.5
           fi ;;
        3) while true; do draw_ml2tp_header; show_ml2tp_monitor; read -t 2 -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        4)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Erase ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter Index or 'all': ${NC}"; read del_idx; del_idx=$(echo "$del_idx" | tr -d '\r')
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; source "$conf"; ip l2tp del session tunnel_id "$TUN_ID" session_id "$TUN_ID" >/dev/null 2>&1; ip l2tp del tunnel tunnel_id "$TUN_ID" >/dev/null 2>&1; ip link del "$T_NAME" >/dev/null 2>&1; rm -f "$conf" "${STATE_DIR}/${T_NAME}.state"; done
               [ -x "/usr/bin/mporter" ] && /usr/bin/mporter --cleanup-orphans >/dev/null 2>&1 &
               echo -e "  ${G}● All tunnels purged.${NC}"; sleep 1.5
           elif [[ -n "${configs[$del_idx]}" ]]; then
               TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; TUN_PORT=""; HYS_PASS=""; VX_NAME=""; source "${configs[$del_idx]}"; ip l2tp del session tunnel_id "$TUN_ID" session_id "$TUN_ID" >/dev/null 2>&1; ip l2tp del tunnel tunnel_id "$TUN_ID" >/dev/null 2>&1; ip link del "$T_NAME" >/dev/null 2>&1; rm -f "${configs[$del_idx]}" "${STATE_DIR}/${T_NAME}.state"
               [ -x "/usr/bin/mporter" ] && /usr/bin/mporter --cleanup-orphans >/dev/null 2>&1 &
               echo -e "  ${G}● Tunnel [${T_NAME}] destroyed.${NC}"; sleep 1.5
           fi ;;
        5) edit_tunnel ;; 6) show_tunnel_details ;; 0) break ;;
    esac
done
