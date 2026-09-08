#!/bin/bash
# --- MGRE Modular Core (mgre.sh) | MDesign Core v5.4.1 ---
# [Features: Live PUB IPs | Dynamic Subnet | L4 Load Balancing | Hardened Sanitization]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mgre/tunnels"
SERVICE_FILE="/etc/systemd/system/mgre.service"

mkdir -p "$CONF_DIR"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

clean_fwd_rules() {
    local t="$1"
    iptables -t nat -S PREROUTING 2>/dev/null | grep "MGRE_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t nat $r 2>/dev/null; done
    iptables -t nat -S POSTROUTING 2>/dev/null | grep "MGRE_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t nat $r 2>/dev/null; done
    iptables -t filter -S FORWARD 2>/dev/null | grep "MGRE_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t filter $r 2>/dev/null; done
}

apply_tunnel() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf"
    
    local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
    local local_tun=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
    local remote_tun=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
    
    # Cleanup old rules
    iptables -t mangle -S FORWARD 2>/dev/null | grep "MGRE_MSS_${T_NAME}\"" | sed 's/^-A /-D /' | while read r; do iptables -t mangle $r 2>/dev/null; done
    clean_fwd_rules "$T_NAME"
    
    ip tunnel del "$T_NAME" >/dev/null 2>&1; ip tunnel del "sit_$T_NAME" >/dev/null 2>&1

    if [[ "$TUN_PROTO" == "6to4" ]]; then
        ip tunnel add "sit_$T_NAME" mode sit remote "$REMOTE_PUB" local "$LOCAL_PUB" 2>/dev/null
        ip link set dev "sit_$T_NAME" mtu 1480 2>/dev/null; ip link set "sit_$T_NAME" up 2>/dev/null
        ip -6 addr add "$LOCAL_IP6/64" dev "sit_$T_NAME" 2>/dev/null
        ip -6 tunnel add "$T_NAME" mode ip6gre remote "$REMOTE_IP6" local "$LOCAL_IP6" key "$TUN_ID" 2>/dev/null
        ip link set dev "$T_NAME" mtu 1436 2>/dev/null; ip link set "$T_NAME" up 2>/dev/null
        ip addr add "$local_tun"/30 dev "$T_NAME" 2>/dev/null
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1396 -m comment --comment "MGRE_MSS_$T_NAME" 2>/dev/null
    else
        local mtu_val=$([ "$TYPE" == "1" ] && echo "1436" || echo "1476")
        ip tunnel add "$T_NAME" mode gre remote "$REMOTE_PUB" local "$LOCAL_PUB" ttl 255 key "$TUN_ID" 2>/dev/null
        ip link set "$T_NAME" up 2>/dev/null; ip addr add "$local_tun"/30 dev "$T_NAME" 2>/dev/null
        ip link set dev "$T_NAME" mtu "$mtu_val" 2>/dev/null
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss $((mtu_val - 40)) -m comment --comment "MGRE_MSS_$T_NAME" 2>/dev/null
    fi

    local all_targets=("$remote_tun")
    
    # Generate and Apply vIPs
    if [[ "$MAX_IPS" -gt 0 ]]; then
        for ((i=0; i<MAX_IPS; i++)); do
            local hash=$(echo "${SYNC_KEY}_${i}" | sha256sum)
            local range_selector=$(( 0x${hash:0:2} % 3 ))
            local o1 o2 o3
            if [[ "$range_selector" == "0" ]]; then o1="10"; o2=$(( (0x${hash:2:2} % 254) + 1 ))
            elif [[ "$range_selector" == "1" ]]; then o1="172"; o2=$(( (0x${hash:2:2} % 16) + 16 ))
            else o1="192"; o2="168"; fi
            o3=$(( (0x${hash:4:2} % 254) + 1 ))
            
            local last_local=$([ "$TYPE" == "1" ] && echo "1" || echo "2")
            local last_remote=$([ "$TYPE" == "1" ] && echo "2" || echo "1")
            
            local nip="$o1.$o2.$o3.$last_local"
            local tip="$o1.$o2.$o3.$last_remote"
            
            all_targets+=("$tip")
            if ! ip route show | grep -q "$nip"; then ip addr add "$nip/30" dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null; fi
        done
    fi

    # Native NAT Port Forwarding (Iran Server Only) with Layer 4 Load Balancing
    if [[ "$TYPE" == "1" ]]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        local t_count=${#all_targets[@]}
        
        # Apply TCP NAT
        if [ -n "$FWD_TCP" ]; then
            IFS=',' read -ra TCP_ARR <<< "$FWD_TCP"
            for p in "${TCP_ARR[@]}"; do
                p=$(echo "$p" | tr -dc '0-9')
                [ -z "$p" ] && continue
                if [[ "$LB_MODE" == "1" && "$t_count" -gt 1 ]]; then
                    for ((idx=0; idx<t_count; idx++)); do
                        local dst_ip="${all_targets[$idx]}"
                        local remaining=$((t_count - idx))
                        if [ "$remaining" -gt 1 ]; then
                            iptables -t nat -A PREROUTING -p tcp -m tcp --dport "$p" -m statistic --mode nth --every "$remaining" --packet 0 -j DNAT --to-destination "$dst_ip" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        else
                            iptables -t nat -A PREROUTING -p tcp -m tcp --dport "$p" -j DNAT --to-destination "$dst_ip" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        fi
                        iptables -t nat -A POSTROUTING -p tcp -m tcp -d "$dst_ip" --dport "$p" -j MASQUERADE -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        iptables -t filter -A FORWARD -p tcp -d "$dst_ip" --dport "$p" -j ACCEPT -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    done
                else
                    iptables -t nat -A PREROUTING -p tcp -m tcp --dport "$p" -j DNAT --to-destination "$remote_tun" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    iptables -t nat -A POSTROUTING -p tcp -m tcp -d "$remote_tun" --dport "$p" -j MASQUERADE -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    iptables -t filter -A FORWARD -p tcp -d "$remote_tun" --dport "$p" -j ACCEPT -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                fi
            done
        fi
        
        # Apply UDP NAT
        if [ -n "$FWD_UDP" ]; then
            IFS=',' read -ra UDP_ARR <<< "$FWD_UDP"
            for p in "${UDP_ARR[@]}"; do
                p=$(echo "$p" | tr -dc '0-9')
                [ -z "$p" ] && continue
                if [[ "$LB_MODE" == "1" && "$t_count" -gt 1 ]]; then
                    for ((idx=0; idx<t_count; idx++)); do
                        local dst_ip="${all_targets[$idx]}"
                        local remaining=$((t_count - idx))
                        if [ "$remaining" -gt 1 ]; then
                            iptables -t nat -A PREROUTING -p udp -m udp --dport "$p" -m statistic --mode nth --every "$remaining" --packet 0 -j DNAT --to-destination "$dst_ip" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        else
                            iptables -t nat -A PREROUTING -p udp -m udp --dport "$p" -j DNAT --to-destination "$dst_ip" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        fi
                        iptables -t nat -A POSTROUTING -p udp -m udp -d "$dst_ip" --dport "$p" -j MASQUERADE -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        iptables -t filter -A FORWARD -p udp -d "$dst_ip" --dport "$p" -j ACCEPT -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    done
                else
                    iptables -t nat -A PREROUTING -p udp -m udp --dport "$p" -j DNAT --to-destination "$remote_tun" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    iptables -t nat -A POSTROUTING -p udp -m udp -d "$remote_tun" --dport "$p" -j MASQUERADE -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    iptables -t filter -A FORWARD -p udp -d "$remote_tun" --dport "$p" -j ACCEPT -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                fi
            done
        fi
    fi
}

apply_all_tunnels() {
    for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && apply_tunnel "$conf"; done
}

draw_mgre_header() {
    local s_ip=$(get_local_ip); local active_tunnels=0; local total_vips=0
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf"
        if ip link show "$T_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" != "down" ]; then ((active_tunnels++)); fi
        total_vips=$((total_vips + MAX_IPS))
    done
    
    local ip_fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    local fwd_val=$([ "$ip_fwd" == "1" ] && echo "ON" || echo "OFF")
    local fwd_color="${R}"; [ "$ip_fwd" == "1" ] && fwd_color="${G}"
    
    clear; echo ""
    local str1=" MDesign Core 5.4.1 "
    local str2=" IP: $s_ip "
    local str3=" TUNNELS: $active_tunnels "
    local str4=" V-IPS: $total_vips "
    local str5=" FWD: $fwd_val "
    
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} + 1 + ${#str4} + 1 + ${#str5} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} TUNNELS:${NC}${G} ${active_tunnels} ${NC}${B}│${NC}${DIM} V-IPS:${NC}${Y} ${total_vips} ${NC}${B}│${NC}${DIM} FWD:${NC}${fwd_color} ${fwd_val} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_mgre_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf"
        mapfile -t v_ips < <(ip -4 addr show dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
        local title_color="${C}"; local proto_lbl="IPv4"
        [[ "$TUN_PROTO" == "6to4" ]] && { title_color="${M}"; proto_lbl="IP6GRE"; }

        local pub_lbl=" ${DIM}| PUB: ${W}${LOCAL_PUB} ${DIM}→${W} ${REMOTE_PUB}${NC}"
        local fwd_lbl=""
        if [ "$TYPE" == "1" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then
            local lb_stat=$([ "$LB_MODE" == "1" ] && echo "${G}ON${NC}" || echo "${DIM}OFF${NC}")
            fwd_lbl=" ${DIM}| NAT: ${Y}T:[${FWD_TCP:-0}] ${C}U:[${FWD_UDP:-0}] ${DIM}LB: [${lb_stat}${DIM}]${NC}"
        fi

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} %b▼ %-22s%b%b%b\n" "${title_color}" "${T_NAME} [${proto_lbl}]" "${NC}" "${pub_lbl}" "${fwd_lbl}"
        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local main_lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        
        local ping_res=$(ping -c 1 -W 1 "$main_tip" 2>/dev/null)
        local lat lat_raw lat_color stat_icon stat_text stat_color
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
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf"
        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access)" || echo "KHAREJ (Gateway)")
        local s_key="${SYNC_KEY:-[ NOT SET ]}"
        local t_id="${TUN_ID:-[ NOT SET ]}"
        
        # Security: Mask Tunnel Secret
        local t_sec="[ NOT SET ]"
        [ -n "$TUN_SECRET" ] && t_sec="********"

        local proto_lbl="IPv4 GRE"; [[ "$TUN_PROTO" == "6to4" ]] && proto_lbl="6to4 IP6GRE"

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $T_NAME"; local right_p="Role: $t_role"
        local pad=$(( 89 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp} ${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="vIP Sync Key : ${s_key}"; local r1="Protocol: ${proto_lbl}"
        local pad1=$(( 89 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}vIP Sync Key :${NC} ${W}${s_key}${NC}${sp1} ${DIM}Protocol:${NC} ${W}${proto_lbl}${NC} ${B}│${NC}"
        
        local l2="Tunnel Secret: ${t_sec}"; local r2="Network ID: ${t_id}"
        local pad2=$(( 89 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}Tunnel Secret:${NC} ${W}${t_sec}${NC}${sp2} ${DIM}Network ID:${NC} ${W}${t_id}${NC} ${B}│${NC}"
        
        local l3="Public IPs   : ${LOCAL_PUB} -> ${REMOTE_PUB}"
        local pad3=$(( 90 - ${#l3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${DIM}Public IPs   :${NC} ${W}${LOCAL_PUB}${NC} ${DIM}->${NC} ${W}${REMOTE_PUB}${NC}${sp3} ${B}│${NC}"
        
        if [ "$TYPE" == "1" ]; then
            local lb_txt=$([ "$LB_MODE" == "1" ] && echo "Active (All vIPs)" || echo "Direct (Core IP)")
            local l5="NAT FWD TCP  : ${FWD_TCP:-None}"; local r5="Load Balancer: ${lb_txt}"
            local pad5=$(( 89 - ${#l5} - ${#r5} )); [ "$pad5" -lt 0 ] && pad5=0; local sp5=$(printf '%*s' "$pad5" "")
            echo -e "  ${B}│${NC} ${Y}NAT FWD TCP  :${NC} ${W}${FWD_TCP:-None}${NC}${sp5} ${C}Load Balancer:${NC} ${W}${lb_txt}${NC} ${B}│${NC}"
        fi
        
        local ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
        local lat lat_raw lat_color stat_icon stat_text stat_color
        if [ $? -eq 0 ]; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
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
    for i in "${!configs[@]}"; do
        local conf_name=$(basename "${configs[$i]}" .conf)
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$conf_name"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Tunnel Index or 'q': ${NC}"; read t_idx
    [[ "$t_idx" == "q" || -z "$t_idx" ]] && return
    
    if [[ -n "${configs[$t_idx]}" ]]; then
        local sel_conf="${configs[$t_idx]}"; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$sel_conf"
        
        echo -e "\n  ${DIM}┌─[ ADVANCED EDIT: ${W}${T_NAME}${DIM} ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Edit Public IPs (Local / Remote)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Edit Tunnel Network ID (Current: ${TUN_ID})${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Edit Core Subnet (Current: ${CORE_SUBNET}.x)${NC}"
        if [ "$TYPE" == "1" ]; then
            echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Edit Port Forwarding & Load Balancer${NC}"
        fi
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"; read e_opt

        case $e_opt in
            1)
                echo -ne "  ${C}●${NC} ${W}New Local Public IP [${Y}${LOCAL_PUB}${W}] (Enter to Skip): ${NC}"; read new_local
                echo -ne "  ${C}●${NC} ${W}New Remote Public IP [${Y}${REMOTE_PUB}${W}] (Enter to Skip): ${NC}"; read new_remote
                # Sanitization
                new_local=$(echo "$new_local" | tr -dc '0-9.')
                new_remote=$(echo "$new_remote" | tr -dc '0-9.')
                
                [ -n "$new_local" ] && sed -i "s/^LOCAL_PUB=.*/LOCAL_PUB=$new_local/" "$sel_conf"
                [ -n "$new_remote" ] && sed -i "s/^REMOTE_PUB=.*/REMOTE_PUB=$new_remote/" "$sel_conf"
                ;;
            2)
                echo -ne "  ${C}●${NC} ${W}New Tunnel Network ID (1-250) [Enter to Skip]: ${NC}"; read new_tun_id
                new_tun_id=$(echo "$new_tun_id" | tr -dc '0-9')
                if [ -n "$new_tun_id" ]; then
                    if grep -q "TUN_ID=$new_tun_id$" "$CONF_DIR"/*.conf 2>/dev/null; then
                        echo -e "  ${R}✖ Network ID [${new_tun_id}] is already in use!${NC}"; sleep 1.5; return
                    fi
                    
                    # Auto-calculate new Subnet based on new TUN_ID (Removed local keywords here)
                    hash_c=$(echo -n "core_${new_tun_id}" | sha256sum)
                    class_selector=$(( new_tun_id % 3 ))
                    c1=""; c2=""; c3=""
                    
                    if [ "$class_selector" == "1" ]; then c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
                    elif [ "$class_selector" == "2" ]; then c1="172"; c2=$(( (0x${hash_c:2:2} % 16) + 16 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
                    else c1="192"; c2="168"; c3=$(( (0x${hash_c:4:2} % 254) + 1 )); fi
                    
                    new_core_sub="${c1}.${c2}.${c3}"
                    
                    sed -i "s/^TUN_ID=.*/TUN_ID=$new_tun_id/" "$sel_conf"
                    sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_core_sub/" "$sel_conf"
                    echo -e "  ${G}● Network ID updated. Subnet automatically changed to ${new_core_sub}.x${NC}"
                fi
                ;;
            3)
                echo -ne "  ${C}●${NC} ${W}New Core Subnet Base (e.g. 10.76.5) [Enter to Skip]: ${NC}"; read new_sub
                new_sub=$(echo "$new_sub" | tr -dc '0-9.')
                if [ -n "$new_sub" ]; then
                    sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_sub/" "$sel_conf"
                fi
                ;;
            4)
                if [ "$TYPE" != "1" ]; then return; fi
                echo -ne "  ${C}●${NC} ${W}New TCP Ports (e.g. 80,443)  [Current: ${Y}${FWD_TCP:-None}${W}]: ${NC}"; read new_tcp
                echo -ne "  ${C}●${NC} ${W}New UDP Ports (e.g. 53,7000) [Current: ${C}${FWD_UDP:-None}${W}]: ${NC}"; read new_udp
                new_tcp=$(echo "$new_tcp" | tr -dc '0-9,')
                new_udp=$(echo "$new_udp" | tr -dc '0-9,')
                
                new_lb="0"
                if [ -n "$new_tcp" ] || [ -n "$new_udp" ]; then
                    echo -ne "  ${C}●${NC} ${W}Load Balance (Distribute) traffic across all Virtual IPs? (y/n): ${NC}"; read ask_lb
                    ask_lb=$(echo "$ask_lb" | tr -d '\r' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
                    if [[ "$ask_lb" == "y" || "$ask_lb" == "yes" ]]; then new_lb="1"; fi
                fi
                
                grep -v "^FWD_TCP=" "$sel_conf" | grep -v "^FWD_UDP=" | grep -v "^LB_MODE=" > "${sel_conf}.tmp"
                echo "FWD_TCP=$new_tcp" >> "${sel_conf}.tmp"
                echo "FWD_UDP=$new_udp" >> "${sel_conf}.tmp"
                echo "LB_MODE=$new_lb" >> "${sel_conf}.tmp"
                mv "${sel_conf}.tmp" "$sel_conf"
                ;;
            *) return ;;
        esac

        apply_tunnel "$sel_conf"
        echo -e "  ${G}● Tunnel [${T_NAME}] updated and applied successfully!${NC}"; sleep 1.5
    fi
}

setup_service() {
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=MGRE Native Edge Service
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
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Setup New Tunnel (IPv4 / IP6GRE)${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Virtual IP Manager (Add/Purge vIPs)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Delete Tunnels (Specific / ALL)${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Advanced Edit Tunnel (IPs / NetID / Subnet / NAT)${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${M}View Tunnel Configurations & Details${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MGRE ❯❯ ${NC}"; read opt
    case $opt in
        1) 
           echo -e "\n  ${DIM}┌─[ TUNNEL PROTOCOL ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Standard IPv4 GRE${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}6to4 IP6GRE Encapsulation${NC}\n  ${DIM}├─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel and Go Back${NC}"
           
           while true; do
               echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read proto_choice
               [[ "$proto_choice" == "q" ]] && break
               [[ "$proto_choice" == "1" || "$proto_choice" == "2" ]] && break
           done
           [[ "$proto_choice" == "q" ]] && continue
           
           tun_proto="ipv4"; [ "$proto_choice" == "2" ] && tun_proto="6to4"
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Server Mode [1:IR | 2:KH | q:Back]: ${NC}"; read s_type
               [[ "$s_type" == "q" ]] && break
               [[ "$s_type" == "1" || "$s_type" == "2" ]] && break
           done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Interface Suffix Name (Max 4-5 chars, e.g. fr): ${NC}"; read suffix
               suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
               [[ "$suffix" == "q" ]] && break
               [[ -z "$suffix" ]] && continue
               
               pfx=$([ "$tun_proto" == "6to4" ] && echo "$([ "$s_type" == "1" ] && echo "gre6ir" || echo "gre6kh")" || echo "$([ "$s_type" == "1" ] && echo "greir" || echo "grekh")")
               t_name="${pfx}${suffix}"
               
               check_len=${#t_name}
               [ "$tun_proto" == "6to4" ] && check_len=$((check_len + 4))
               
               if [ "$check_len" -gt 15 ]; then echo -e "  ${R}● Error: Name too long! Kernel limit is 15 chars.${NC}"; else break; fi
           done
           [[ "$suffix" == "q" ]] && continue
           
           if [ -f "$CONF_DIR/${t_name}.conf" ]; then
               echo -e "\n  ${R}● Error: Tunnel interface name [${W}${t_name}${R}] already exists!${NC}"; sleep 2; continue
           fi
           
           local_ip=$(get_local_ip)
           while true; do
               echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}] (Enter for default | q:Back): ${NC}"; read custom_ip
               [[ "$custom_ip" == "q" ]] && break
               custom_ip=$(echo "$custom_ip" | tr -dc '0-9.') # Security Sanitize
               [ -n "$custom_ip" ] && local_ip=$custom_ip
               break
           done
           [[ "$custom_ip" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IP: ${NC}"; read r_ip
               [[ "$r_ip" == "q" ]] && break
               r_ip=$(echo "$r_ip" | tr -dc '0-9.') # Security Sanitize
               [[ -n "$r_ip" ]] && break
           done
           [[ "$r_ip" == "q" ]] && continue

           local_ip6=""; remote_ip6=""; tun_secret=""
           if [[ "$tun_proto" == "6to4" ]]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${M}Tunnel Secret Key: ${NC}"; read tun_secret
                   [[ "$tun_secret" == "q" ]] && break
                   tun_secret=$(echo "$tun_secret" | tr -dc 'a-zA-Z0-9_-') # Security Sanitize
                   [[ -n "$tun_secret" ]] && break
               done
               [[ "$tun_secret" == "q" ]] && continue
               
               hash_str=$(echo -n "${tun_secret}_MHDesign" | sha256sum)
               pfx_v6="fd${hash_str:0:2}:${hash_str:2:4}:${hash_str:6:4}:${hash_str:10:4}"
               if [[ "$s_type" == "1" ]]; then local_ip6="${pfx_v6}::1"; remote_ip6="${pfx_v6}::2"; else local_ip6="${pfx_v6}::2"; remote_ip6="${pfx_v6}::1"; fi
           fi
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Tunnel Network ID (1-250): ${NC}"; read user_tun_id
               [[ "$user_tun_id" == "q" ]] && break
               user_tun_id=$(echo "$user_tun_id" | tr -dc '0-9')
               [[ -z "$user_tun_id" ]] && continue
               
               if grep -q "TUN_ID=$user_tun_id$" "$CONF_DIR"/*.conf 2>/dev/null; then echo -e "  ${R}● Error: Network ID [${W}${user_tun_id}${R}] is already assigned!${NC}"; continue; fi
               break
           done
           [[ "$user_tun_id" == "q" ]] && continue
           
           tun_id=$user_tun_id
           hash_c=$(echo -n "core_${tun_id}" | sha256sum)
           class_selector=$(( tun_id % 3 ))
           
           c1=""; c2=""; c3=""
           if [ "$class_selector" == "1" ]; then c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           elif [ "$class_selector" == "2" ]; then c1="172"; c2=$(( (0x${hash_c:2:2} % 16) + 16 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           else c1="192"; c2="168"; c3=$(( (0x${hash_c:4:2} % 254) + 1 )); fi
           
           core_sub="${c1}.${c2}.${c3}"
           conf_path="$CONF_DIR/${t_name}.conf"
           
           # Generate base configuration safely
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=\nTUN_SECRET=$tun_secret\nT_NAME=$t_name\nTUN_ID=$tun_id\nCORE_SUBNET=$core_sub\nTUN_PROTO=$tun_proto\nLOCAL_IP6=$local_ip6\nREMOTE_IP6=$remote_ip6\nFWD_TCP=\nFWD_UDP=\nLB_MODE=0" > "$conf_path"
           chmod 600 "$conf_path"
           
           apply_tunnel "$conf_path"
           
           if ip link show "$t_name" >/dev/null 2>&1; then
               setup_service
               echo -e "  ${G}● Tunnel [${t_name}] deployed successfully (Subnet: ${core_sub}.x)${NC}"
               
               remote_tip=$([ "$s_type" == "1" ] && echo "${core_sub}.2" || echo "${core_sub}.1")
               
               # 1. PING TEST
               echo -ne "\n  ${C}●${NC} ${W}Run initial ping test to peer now? (y/n): ${NC}"; read run_initial_ping
               run_initial_ping=$(echo "$run_initial_ping" | tr -d '\r' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
               if [[ "$run_initial_ping" == "y" || "$run_initial_ping" == "yes" ]]; then
                   echo -e "  ${DIM}┌─[ INITIAL PING TEST TO PEER ]${NC}"
                   echo -e "  ${DIM}│${NC} Pinging ${remote_tip} (4 Packets)..."
                   ping_res=$(ping -c 4 -W 1 "$remote_tip" 2>&1)
                   if [ $? -eq 0 ]; then
                       lat=$(echo "$ping_res" | grep -oP 'min/avg/max/mdev = \K[^/]+/[^/]+' | cut -d/ -f2)
                       echo -e "  ${DIM}└─${NC} ${G}SUCCESS!${NC} Average Latency: ${Y}${lat}ms${NC}"
                   else
                       echo -e "  ${DIM}└─${NC} ${R}FAILED!${NC} Destination Host Unreachable."
                   fi
               fi
               
               # 2. VIRTUAL IP SETUP
               echo -ne "\n  ${C}●${NC} ${W}Do you want to setup Virtual IPs now? (y/n): ${NC}"; read setup_vip
               setup_vip=$(echo "$setup_vip" | tr -d '\r' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
               if [[ "$setup_vip" == "y" || "$setup_vip" == "yes" ]]; then
                   while true; do echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read n; [[ "$n" == "q" ]] && break; [[ -n "$n" ]] && break; done
                   if [[ "$n" != "q" ]]; then
                       while true; do 
                           echo -ne "  ${C}●${NC} ${W}Sync Key: ${NC}"; read k; 
                           [[ "$k" == "q" ]] && break; 
                           k=$(echo "$k" | tr -dc 'a-zA-Z0-9_-'); # Security Sanitize
                           [[ -n "$k" ]] && break; 
                       done
                       if [[ "$k" != "q" ]]; then
                           sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$conf_path"
                           sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$conf_path"
                           apply_tunnel "$conf_path"
                           echo -e "  ${G}● Virtual IPs applied successfully.${NC}"
                       fi
                   fi
               fi

               # 3. PORT FORWARDING & LOAD BALANCING SETUP
               if [ "$s_type" == "1" ]; then
                   echo -ne "\n  ${C}●${NC} ${W}Do you want to setup Port Forwarding? (y/n): ${NC}"; read setup_pf
                   setup_pf=$(echo "$setup_pf" | tr -d '\r' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
                   if [[ "$setup_pf" == "y" || "$setup_pf" == "yes" ]]; then
                       echo -ne "  ${C}●${NC} ${Y}NAT Forward TCP Ports (e.g. 80,443)  [Enter to skip]: ${NC}"; read fwd_tcp
                       echo -ne "  ${C}●${NC} ${C}NAT Forward UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read fwd_udp
                       fwd_tcp=$(echo "$fwd_tcp" | tr -dc '0-9,')
                       fwd_udp=$(echo "$fwd_udp" | tr -dc '0-9,')
                       
                       run_lb="0" # Fixed scope error
                       if [ -n "$fwd_tcp" ] || [ -n "$fwd_udp" ]; then
                           echo -ne "  ${C}●${NC} ${W}Load Balance (Distribute) traffic across all Virtual IPs? (y/n): ${NC}"; read ask_lb
                           ask_lb=$(echo "$ask_lb" | tr -d '\r' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
                           if [[ "$ask_lb" == "y" || "$ask_lb" == "yes" ]]; then run_lb="1"; fi
                       fi
                       
                       grep -v "^FWD_TCP=" "$conf_path" | grep -v "^FWD_UDP=" | grep -v "^LB_MODE=" > "${conf_path}.tmp"
                       echo "FWD_TCP=$fwd_tcp" >> "${conf_path}.tmp"
                       echo "FWD_UDP=$fwd_udp" >> "${conf_path}.tmp"
                       echo "LB_MODE=$run_lb" >> "${conf_path}.tmp"
                       mv "${conf_path}.tmp" "$conf_path"
                       
                       apply_tunnel "$conf_path"
                       echo -e "  ${G}● Port Forwarding applied successfully.${NC}"
                   fi
               fi
               
               sleep 2
           else
               echo -e "\n  ${R}● FATAL ERROR: Kernel rejected tunnel creation!${NC}"
               rm -f "$conf_path"
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
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx
               [[ "$t_idx" == "q" ]] && break 2
               [[ -n "$t_idx" ]] && break
           done
           
           if [[ -n "${configs[$t_idx]}" ]]; then
               sel_conf="${configs[$t_idx]}"; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$sel_conf"
               
               echo -e "\n  ${DIM}┌─[ vIP ACTIONS for ${T_NAME} ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup / Update Virtual IPs${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Purge All Virtual IPs${NC}\n  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
               while true; do echo -ne "  ${C}●${NC} ${W}Select Action: ${NC}"; read vip_action; [[ "$vip_action" == "q" || "$vip_action" == "1" || "$vip_action" == "2" ]] && break; done
               [[ "$vip_action" == "q" ]] && continue
               
               if [[ "$vip_action" == "1" ]]; then
                   while true; do echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read n; [[ "$n" == "q" ]] && break; [[ -n "$n" ]] && break; done
                   [[ "$n" == "q" ]] && continue
                   while true; do 
                       echo -ne "  ${C}●${NC} ${W}Sync Key: ${NC}"; read k; 
                       [[ "$k" == "q" ]] && break; 
                       k=$(echo "$k" | tr -dc 'a-zA-Z0-9_-'); # Security Sanitize
                       [[ -n "$k" ]] && break; 
                   done
                   [[ "$k" == "q" ]] && continue
                   sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$sel_conf"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$sel_conf"
                   apply_tunnel "$sel_conf"; echo -e "  ${G}● IPs synchronized successfully.${NC}"; sleep 1.5
               elif [[ "$vip_action" == "2" ]]; then
                   if [[ "$MAX_IPS" == "0" || -z "$MAX_IPS" ]]; then echo -e "  ${Y}● No Virtual IPs found!${NC}"; sleep 1.5; continue; fi
                   echo -ne "  ${R}● Delete all ${MAX_IPS} vIPs from [${T_NAME}]? (y/n): ${NC}"; read confirm_vip
                   if [[ "$confirm_vip" == "y" ]]; then sed -i "s/^MAX_IPS=.*/MAX_IPS=0/" "$sel_conf"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=/" "$sel_conf"; apply_tunnel "$sel_conf"; echo -e "  ${G}● Virtual IPs purged.${NC}"; sleep 1.5; fi
               fi
           fi ;;
        3) while true; do draw_mgre_header; show_mgre_monitor; read -t 2 -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        4)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && echo -e "\n  ${R}● No active tunnels to remove!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Erase ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter Index, 'all', or 'q': ${NC}"; read del_idx
           [[ "$del_idx" == "q" || -z "$del_idx" ]] && continue
           
           if [[ "$del_idx" == "all" ]]; then
               echo -ne "  ${R}● DANGER: Delete ALL tunnels? (y/n): ${NC}"; read confirm_all
               if [[ "$confirm_all" == "y" ]]; then
                   for conf in "${configs[@]}"; do
                       TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf"
                       clean_fwd_rules "$T_NAME"
                       ip tunnel del "$T_NAME" >/dev/null 2>&1
                       ip tunnel del "sit_$T_NAME" >/dev/null 2>&1
                       rm -f "$conf"
                   done
                   [ -x "/usr/bin/mporter" ] && /usr/bin/mporter --cleanup-orphans >/dev/null 2>&1 &
                   echo -e "  ${G}● All tunnels safely purged.${NC}"; sleep 1.5
               fi; continue
           fi
           if [[ -n "${configs[$del_idx]}" ]]; then
               TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "${configs[$del_idx]}"
               clean_fwd_rules "$T_NAME"
               ip tunnel del "$T_NAME" >/dev/null 2>&1
               ip tunnel del "sit_$T_NAME" >/dev/null 2>&1
               rm -f "${configs[$del_idx]}"
               [ -x "/usr/bin/mporter" ] && /usr/bin/mporter --cleanup-orphans >/dev/null 2>&1 &
               echo -e "  ${G}● Tunnel [${T_NAME}] destroyed.${NC}"; sleep 1.5
           fi ;;
        5) edit_tunnel ;; 6) show_tunnel_details ;; 0) break ;;
    esac
done
