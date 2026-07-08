#!/bin/bash
# --- MGRE Modular Core (mgre.sh) | MDesign Core v4.2.4 (Tunnel Registry) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mgre/tunnels"
SERVICE_FILE="/etc/systemd/system/mgre.service"
STATE_DIR="/etc/mgre/states"

mkdir -p "$CONF_DIR" "$STATE_DIR"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

apply_tunnel() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    source "$conf"
    
    local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
    local local_tun=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
    
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1396 >/dev/null 2>&1
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1436 >/dev/null 2>&1
    ip tunnel del "$T_NAME" >/dev/null 2>&1; ip tunnel del "sit_$T_NAME" >/dev/null 2>&1

    if [[ "$TUN_PROTO" == "6to4" ]]; then
        ip tunnel add "sit_$T_NAME" mode sit remote "$REMOTE_PUB" local "$LOCAL_PUB" 2>/dev/null
        ip link set dev "sit_$T_NAME" mtu 1480 2>/dev/null; ip link set "sit_$T_NAME" up 2>/dev/null
        ip -6 addr add "$LOCAL_IP6/64" dev "sit_$T_NAME" 2>/dev/null
        ip -6 tunnel add "$T_NAME" mode ip6gre remote "$REMOTE_IP6" local "$LOCAL_IP6" key "$TUN_ID" 2>/dev/null
        ip link set dev "$T_NAME" mtu 1436 2>/dev/null; ip link set "$T_NAME" up 2>/dev/null
        ip addr add "$local_tun"/30 dev "$T_NAME" 2>/dev/null
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1396 2>/dev/null
    else
        local mtu_val=$([ "$TYPE" == "1" ] && echo "1436" || echo "1476")
        ip tunnel add "$T_NAME" mode gre remote "$REMOTE_PUB" local "$LOCAL_PUB" ttl 255 key "$TUN_ID" 2>/dev/null
        ip link set "$T_NAME" up 2>/dev/null; ip addr add "$local_tun"/30 dev "$T_NAME" 2>/dev/null
        ip link set dev "$T_NAME" mtu "$mtu_val" 2>/dev/null
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss $((mtu_val - 40)) 2>/dev/null
    fi

    if [[ "$MAX_IPS" -gt 0 ]]; then
        local s_file="${STATE_DIR}/${T_NAME}.state"
        echo "0" > "$s_file"
        for ((i=1; i<=MAX_IPS; i++)); do
            idx=$(cat "$s_file")
            hash=$(echo "${SYNC_KEY}_${idx}" | sha256sum)
            range_selector=$(( 0x${hash:0:2} % 3 ))
            if [[ "$range_selector" == "0" ]]; then
                o1="10"; o2=$(( (0x${hash:2:2} % 254) + 1 ))
            elif [[ "$range_selector" == "1" ]]; then
                o1="172"; o2=$(( (0x${hash:2:2} % 16) + 16 ))
            else
                o1="192"; o2="168"
            fi
            o3=$(( (0x${hash:4:2} % 254) + 1 ))
            last_octet=$([ "$TYPE" == "1" ] && echo "1" || echo "2")
            nip="$o1.$o2.$o3.$last_octet"
            ip addr add "$nip/30" dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null
            echo $((idx + 1)) > "$s_file"
        done
    fi
}

apply_all_tunnels() {
    for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && apply_tunnel "$conf"; done
}

draw_mgre_header() {
    local s_ip=$(get_local_ip); local active_tunnels=0; local total_vips=0
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; source "$conf"
        if ip link show "$T_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" != "down" ]; then ((active_tunnels++)); fi
        total_vips=$((total_vips + MAX_IPS))
    done
    clear; echo ""
    local str1=" MGRE Core 4.2.4 "
    local str2=" IP: $s_ip "
    local str3=" ACTIVE TUNNELS: $active_tunnels "
    local str4=" TOTAL V-IPS: $total_vips "
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} + 1 + ${#str4} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} ACTIVE TUNNELS:${NC}${G} ${active_tunnels} ${NC}${B}│${NC}${DIM} TOTAL V-IPS:${NC}${Y} ${total_vips} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_mgre_monitor() {
    echo -e "\n  ${C}Live Monitoring${NC}"
    local has_ips=false
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; source "$conf"; has_ips=true
        mapfile -t v_ips < <(ip -4 addr show dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
        local title_color="${C}"; local proto_lbl="IPv4"
        [[ "$TUN_PROTO" == "6to4" ]] && { title_color="${M}"; proto_lbl="IP6GRE"; }

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} %b▼ Tunnel: %-80s%b ${B}│${NC}\n" "${title_color}" "${T_NAME} [${proto_lbl}]" "${NC}"
        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local main_lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        
        ping_res=$(ping -c 1 -W 1 "$main_tip" 2>/dev/null)
        if [ $? -eq 0 ]; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
        
        local m_icon="├─"; [ ${#v_ips[@]} -eq 0 ] && m_icon="└─"
        printf "  ${B}│${NC} ${W}%s %-15s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%s %-10s%b ${B}│${NC}\n" "${m_icon}" "Core IP" "$main_lip" "$main_tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        
        local total_v=${#v_ips[@]}
        for ((idx=0; idx<total_v; idx++)); do
            local lip="${v_ips[$idx]}"; local base_ip=$(echo "$lip" | cut -d'.' -f1-3); local last=$(echo "$lip" | cut -d'.' -f4); local tip="$base_ip.$([ "$last" == "1" ] && echo "2" || echo "1")"
            ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
            if [ $? -eq 0 ]; then
                lat=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
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

    echo -e "\n  ${Y}● Deployed Tunnels Registry:${NC}"
    for conf in "${configs[@]}"; do
        source "$conf"
        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access)" || echo "KHAREJ (Gateway)")
        local s_key="${SYNC_KEY:-[ NOT SET ]}"
        local proto_lbl="IPv4 GRE"
        [[ "$TUN_PROTO" == "6to4" ]] && proto_lbl="6to4 IP6GRE"

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $T_NAME"
        local right_p="Role: $t_role"
        local pad=$(( 89 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp} ${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="Sync Key: ${s_key}"; local r1="Protocol: ${proto_lbl}"
        local pad1=$(( 89 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Sync Key:${NC} ${W}${s_key}${NC}${sp1} ${DIM}Protocol:${NC} ${W}${proto_lbl}${NC} ${B}│${NC}"
        
        local l2="Public IPs : ${LOCAL_PUB} -> ${REMOTE_PUB}"
        local pad2=$(( 90 - ${#l2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${DIM}Public IPs :${NC} ${W}${LOCAL_PUB}${NC} ${DIM}->${NC} ${W}${REMOTE_PUB}${NC}${sp2} ${B}│${NC}"
        
        local l3="Core IPs   : ${lip} -> ${tip}"
        local pad3=$(( 90 - ${#l3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${DIM}Core IPs   :${NC} ${G}${lip}${NC} ${DIM}->${NC} ${Y}${tip}${NC}${sp3} ${B}│${NC}"
        
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read
}

edit_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return; fi
    
    echo -e "\n  ${B}╭────────────────── Select Tunnel to Edit ───────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        local conf_name=$(basename "${configs[$i]}" .conf)
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$conf_name"
    done
    echo -e "  ${B}├────────────────────────────────────────────────────────────┤${NC}"
    printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${DIM}%-53s${NC} ${B}│${NC}\n" "q" "Cancel and Return"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Tunnel Index or 'q': ${NC}"; read t_idx
    
    [[ "$t_idx" == "q" || -z "$t_idx" ]] && return
    
    if [[ -n "${configs[$t_idx]}" ]]; then
        local sel_conf="${configs[$t_idx]}"; source "$sel_conf"
        echo -e "\n  ${DIM}┌─[ HOT-SWAP PUBLIC IPs ]${NC}"
        echo -ne "  ${C}●${NC} ${W}New Local Public IP [${Y}${LOCAL_PUB}${W}] (Or Enter to Skip): ${NC}"; read new_local
        echo -ne "  ${C}●${NC} ${W}New Remote Public IP [${Y}${REMOTE_PUB}${W}] (Or Enter to Skip): ${NC}"; read new_remote
        [ -n "$new_local" ] && sed -i "s/^LOCAL_PUB=.*/LOCAL_PUB=$new_local/" "$sel_conf"
        [ -n "$new_remote" ] && sed -i "s/^REMOTE_PUB=.*/REMOTE_PUB=$new_remote/" "$sel_conf"
        apply_tunnel "$sel_conf"
        echo -e "  ${G}● Pipeline re-routed successfully!${NC}"; sleep 1.5
    fi
}

setup_service() {
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=MGRE Multi-Tunnel Service
After=network.target
[Service]
ExecStart=/usr/bin/mgre --apply
Type=oneshot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable mgre.service >/dev/null 2>&1
}

if [[ "$1" == "--apply" ]]; then apply_all_tunnels; exit 0; fi

while true; do
    draw_mgre_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Setup New Tunnel (IPv4 / IP6GRE)${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Generate Sync IPs (Select Tunnel)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Live Monitoring (All Tunnels)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Delete Specific Tunnel${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Edit Tunnel Public IPs (Hot-Swap)${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${C}View Tunnel Configurations & Sync Keys${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MGRE ❯❯ ${NC}"; read opt
    case $opt in
        1) 
           echo -e "\n  ${DIM}┌─[ TUNNEL PROTOCOL ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Standard IPv4 GRE${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}6to4 IP6GRE Encapsulation${NC}\n  ${DIM}├─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel and Go Back${NC}"
           echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read proto_choice
           [[ "$proto_choice" == "q" || -z "$proto_choice" ]] && continue
           
           tun_proto="ipv4"; [ "$proto_choice" == "2" ] && tun_proto="6to4"
           
           echo -ne "  ${C}●${NC} ${W}Server Mode [1:IR | 2:KH | q:Back]: ${NC}"; read s_type
           [[ "$s_type" == "q" || -z "$s_type" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Interface Suffix Name (Max 4-5 chars, e.g. fr): ${NC}"; read suffix
               [[ "$suffix" == "q" ]] && break 2
               pfx=$([ "$tun_proto" == "6to4" ] && echo "$([ "$s_type" == "1" ] && echo "gre6ir" || echo "gre6kh")" || echo "$([ "$s_type" == "1" ] && echo "greir" || echo "grekh")")
               t_name="${pfx}${suffix}"
               
               check_len=${#t_name}
               [ "$tun_proto" == "6to4" ] && check_len=$((check_len + 4))
               
               if [ "$check_len" -gt 15 ]; then
                   echo -e "  ${R}● Error: Name too long! Kernel limit is 15 chars.${NC}"
               else
                   break
               fi
           done
           
           if [ -f "$CONF_DIR/${t_name}.conf" ]; then
               echo -e "\n  ${R}● Error: Tunnel interface name [${W}${t_name}${R}] already exists!${NC}"
               sleep 2; continue
           fi
           
           local_ip=$(get_local_ip); echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}]: ${NC}"; read custom_ip
           [[ "$custom_ip" == "q" ]] && continue
           [ -n "$custom_ip" ] && local_ip=$custom_ip
           
           echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IP: ${NC}"; read r_ip
           [[ "$r_ip" == "q" || -z "$r_ip" ]] && continue
           
           local_ip6=""; remote_ip6=""
           if [[ "$tun_proto" == "6to4" ]]; then
               echo -ne "  ${C}●${NC} ${M}Tunnel Secret Key: ${NC}"; read tun_secret
               [[ "$tun_secret" == "q" || -z "$tun_secret" ]] && continue
               hash_str=$(echo -n "${tun_secret}_MHDesign" | sha256sum)
               pfx_v6="fd${hash_str:0:2}:${hash_str:2:4}:${hash_str:6:4}:${hash_str:10:4}"
               if [[ "$s_type" == "1" ]]; then local_ip6="${pfx_v6}::1"; remote_ip6="${pfx_v6}::2"; else local_ip6="${pfx_v6}::2"; remote_ip6="${pfx_v6}::1"; fi
           fi
           
           echo -ne "  ${C}●${NC} ${W}Tunnel Network ID (1-250): ${NC}"; read user_tun_id
           [[ "$user_tun_id" == "q" || -z "$user_tun_id" ]] && continue
           
           if grep -q "TUN_ID=$user_tun_id$" "$CONF_DIR"/*.conf 2>/dev/null; then
               echo -e "\n  ${R}● Error: Network ID [${W}${user_tun_id}${R}] is already assigned!${NC}"
               sleep 2; continue
           fi
           
           tun_id=$user_tun_id
           hash_c=$(echo -n "core_${tun_id}" | sha256sum)
           class_selector=$(( tun_id % 3 ))
           
           if [ "$class_selector" == "1" ]; then
               c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           elif [ "$class_selector" == "2" ]; then
               c1="172"; c2=$(( (0x${hash_c:2:2} % 16) + 16 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           else
               c1="192"; c2="168"; c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           fi
           
           core_sub="${c1}.${c2}.${c3}"
           conf_path="$CONF_DIR/${t_name}.conf"
           
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=\nT_NAME=$t_name\nTUN_ID=$tun_id\nCORE_SUBNET=$core_sub\nTUN_PROTO=$tun_proto\nLOCAL_IP6=$local_ip6\nREMOTE_IP6=$remote_ip6" > "$conf_path"
           
           apply_tunnel "$conf_path"
           
           if ip link show "$t_name" >/dev/null 2>&1; then
               setup_service
               echo -e "  ${G}● Tunnel [${t_name}] deployed successfully (Subnet: ${core_sub}.x)${NC}"
               sleep 1.5
           else
               echo -e "\n  ${R}● FATAL ERROR: Kernel rejected tunnel creation!${NC}"
               echo -e "  ${DIM}├─ Causes: Invalid IPs, network unreachable, or missing modules.${NC}"
               echo -e "  ${DIM}└─ Auto-Rollback: Purging ghost configuration files...${NC}"
               rm -f "$conf_path" "${STATE_DIR}/${t_name}.state"
               sleep 3.5
           fi
           ;;
        2)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && echo -e "\n  ${R}● No tunnels configured yet!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel for vIPs ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do
               conf_name=$(basename "${configs[$i]}" .conf)
               printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$conf_name"
           done
           echo -e "  ${B}├────────────────────────────────────────────────────────────┤${NC}"
           printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${DIM}%-53s${NC} ${B}│${NC}\n" "q" "Cancel and Go Back"
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx
           [[ "$t_idx" == "q" || -z "$t_idx" ]] && continue
           if [[ -n "${configs[$t_idx]}" ]]; then
               sel_conf="${configs[$t_idx]}"; source "$sel_conf"
               echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read n
               echo -ne "  ${C}●${NC} ${W}Sync Key: ${NC}"; read k
               sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$sel_conf"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$sel_conf"
               apply_tunnel "$sel_conf"
               echo -e "  ${G}● IPs synchronized successfully.${NC}"; sleep 1.5
           fi ;;
        3) while true; do draw_mgre_header; show_mgre_monitor; echo -e "  Press '${Y}q${NC}' to go back."; read -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        4)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && echo -e "\n  ${R}● No active tunnels to remove!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Erase ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do
               conf_name=$(basename "${configs[$i]}" .conf)
               printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$conf_name"
           done
           echo -e "  ${B}├────────────────────────────────────────────────────────────┤${NC}"
           printf "  ${B}│${NC}  ${R}%-3s${NC} ${C}❯${NC} ${R}%-53s${NC} ${B}│${NC}\n" "all" "Delete ALL Tunnels"
           printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${DIM}%-53s${NC} ${B}│${NC}\n" "q" "Cancel and Go Back"
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter Index, 'all', or 'q': ${NC}"; read del_idx
           
           [[ "$del_idx" == "q" || -z "$del_idx" ]] && continue
           
           if [[ "$del_idx" == "all" ]]; then
               echo -ne "  ${R}● DANGER: Are you sure you want to delete ALL tunnels? (y/n): ${NC}"; read confirm_all
               if [[ "$confirm_all" == "y" ]]; then
                   for conf in "${configs[@]}"; do
                       source "$conf"
                       ip tunnel del "$T_NAME" >/dev/null 2>&1
                       ip tunnel del "sit_$T_NAME" >/dev/null 2>&1
                       rm -f "$conf" "${STATE_DIR}/${T_NAME}.state"
                   done
                   echo -e "  ${G}● All tunnels have been purged.${NC}"; sleep 1.5
               fi
               continue
           fi
           
           if [[ -n "${configs[$del_idx]}" ]]; then
               source "${configs[$del_idx]}"
               ip tunnel del "$T_NAME" >/dev/null 2>&1
               ip tunnel del "sit_$T_NAME" >/dev/null 2>&1
               rm -f "${configs[$del_idx]}" "${STATE_DIR}/${T_NAME}.state"
               echo -e "  ${G}● Tunnel [${T_NAME}] destroyed.${NC}"; sleep 1.5
           fi ;;
        5) edit_tunnel ;;
        6) show_tunnel_details ;;
        0) break ;;
    esac
done
