#!/bin/bash
# --- MGRE Modular Core (mgre.sh) | MDesign Core v4.0 (Custom Core IP Edition) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

INSTALL_PATH="/usr/bin/mgre"
CONF_DIR="/etc/mgre/tunnels"
SERVICE_FILE="/etc/systemd/system/mgre.service"
STATE_DIR="/etc/mgre/states"

mkdir -p "$CONF_DIR" "$STATE_DIR"

if [[ "$1" != "--apply" ]]; then
    if [[ ! -x "$INSTALL_PATH" ]]; then cp "$0" "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH" 2>/dev/null; fi
fi

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

apply_tunnel() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    source "$conf"
    
    # پشتیبانی از نسخه‌های قدیمی و خواندن Core IP سفارشی
    if [ -z "$LOCAL_CORE_IP" ]; then
        LOCAL_CORE_IP=$([ "$TYPE" == "1" ] && echo "10.76.${TUN_ID}.1" || echo "10.76.${TUN_ID}.2")
        REMOTE_CORE_IP=$([ "$TYPE" == "1" ] && echo "10.76.${TUN_ID}.2" || echo "10.76.${TUN_ID}.1")
    fi
    local local_tun="$LOCAL_CORE_IP"
    
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1396 >/dev/null 2>&1
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1436 >/dev/null 2>&1
    ip tunnel del "$T_NAME" >/dev/null 2>&1
    ip tunnel del "sit_$T_NAME" >/dev/null 2>&1

    if [[ "$TUN_PROTO" == "6to4" ]]; then
        ip tunnel add "sit_$T_NAME" mode sit remote "$REMOTE_PUB" local "$LOCAL_PUB"
        ip link set dev "sit_$T_NAME" mtu 1480; ip link set "sit_$T_NAME" up
        ip -6 addr add "$LOCAL_IP6/64" dev "sit_$T_NAME"
        ip -6 tunnel add "$T_NAME" mode ip6gre remote "$REMOTE_IP6" local "$LOCAL_IP6"
        ip link set dev "$T_NAME" mtu 1436; ip link set "$T_NAME" up
        ip addr add "$local_tun"/30 dev "$T_NAME"
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1396
    else
        local mtu_val=$([ "$TYPE" == "1" ] && echo "1436" || echo "1476")
        ip tunnel add "$T_NAME" mode gre remote "$REMOTE_PUB" local "$LOCAL_PUB" ttl 255
        ip link set "$T_NAME" up; ip addr add "$local_tun"/30 dev "$T_NAME"
        ip link set dev "$T_NAME" mtu "$mtu_val"
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss $((mtu_val - 40))
    fi

    if [[ "$MAX_IPS" -gt 0 ]]; then
        local s_file="${STATE_DIR}/${T_NAME}.state"
        echo "0" > "$s_file"
        for ((i=1; i<=MAX_IPS; i++)); do
            idx=$(cat "$s_file")
            hash=$(echo "${SYNC_KEY}_${idx}" | sha256sum)
            range_selector=$(( 0x${hash:0:2} % 3 ))
            if [[ "$range_selector" == "0" ]]; then o1="10"
            elif [[ "$range_selector" == "1" ]]; then o1="172"
            else o1="192"; fi
            o2=$(( (0x${hash:2:2} % 254) + 1 )); o3=$(( (0x${hash:4:2} % 254) + 1 ))
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
    local str1=" MGRE Core 4.0 "
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
        if [[ "$TUN_PROTO" == "6to4" ]]; then title_color="${M}"; proto_lbl="IP6GRE"; fi

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} %b▼ Tunnel: %-80s%b ${B}│${NC}\n" "${title_color}" "${T_NAME} [${proto_lbl}]" "${NC}"
        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        local main_lip="${LOCAL_CORE_IP}"
        local main_tip="${REMOTE_CORE_IP}"
        if [ -z "$main_lip" ]; then
            main_lip=$([ "$TYPE" == "1" ] && echo "10.76.${TUN_ID}.1" || echo "10.76.${TUN_ID}.2")
            main_tip=$([ "$TYPE" == "1" ] && echo "10.76.${TUN_ID}.2" || echo "10.76.${TUN_ID}.1")
        fi
        
        ping_res=$(ping -c 1 -W 1 "$main_tip" 2>/dev/null)
        if [ $? -eq 0 ]; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
        
        local m_icon="├─"
        if [ ${#v_ips[@]} -eq 0 ]; then m_icon="└─"; fi
        
        printf "  ${B}│${NC} ${W}%s %-15s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%s %-10s%b ${B}│${NC}\n" "${m_icon}" "Core IP" "$main_lip" "$main_tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        
        local total_v=${#v_ips[@]}
        for ((idx=0; idx<total_v; idx++)); do
            local lip="${v_ips[$idx]}"; local base_ip=$(echo "$lip" | cut -d'.' -f1-3); local last=$(echo "$lip" | cut -d'.' -f4); local tip="$base_ip.$([ "$last" == "1" ] && echo "2" || echo "1")"
            ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
            if [ $? -eq 0 ]; then
                lat=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
            else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
            local v_icon="│  ├─"; if [ $idx -eq $((total_v - 1)) ]; then v_icon="│  └─"; fi
            printf "  ${B}│${NC} ${DIM}%s %-12s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%s %-10s%b ${B}│${NC}\n" "${v_icon}" "vIP" "$lip" "$tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        done
        echo -e "  ${B}╰────────────────────┴────────────────────┴────────────────────┴──────────────┴──────────────╯${NC}\n"
    done
    if [ "$has_ips" = false ]; then
        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} ${DIM}%-90s${NC} ${B}│${NC}\n" " No tunnels are currently active."
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
    fi
}

edit_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return; fi
    
    echo -e "\n  ${B}╭────────────────── Select Tunnel to Edit ──────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        local conf_name=$(basename "${configs[$i]}" .conf)
        local proto_label="IPv4 GRE"
        grep -q "TUN_PROTO=6to4" "${configs[$i]}" && proto_label="6to4 IP6GRE"
        printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-32s${NC} ${M}[%-10s]${NC} ${B}│${NC}\n" "$i" "$conf_name" "$proto_label"
    done
    echo -e "  ${B}╰───────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Tunnel Index: ${NC}"; read -t 20 t_idx
    
    if [[ -n "${configs[$t_idx]}" ]]; then
        local sel_conf="${configs[$t_idx]}"; source "$sel_conf"
        
        if [ -z "$LOCAL_CORE_IP" ]; then
            LOCAL_CORE_IP=$([ "$TYPE" == "1" ] && echo "10.76.${TUN_ID}.1" || echo "10.76.${TUN_ID}.2")
            REMOTE_CORE_IP=$([ "$TYPE" == "1" ] && echo "10.76.${TUN_ID}.2" || echo "10.76.${TUN_ID}.1")
        fi
        
        echo -e "\n  ${DIM}┌─[ EDIT INFRASTRUCTURE: ${Y}${T_NAME}${DIM} ]${NC}"
        echo -e "  ${DIM}├─ Current Local Public IP: ${W}${LOCAL_PUB}${NC}"
        echo -e "  ${DIM}├─ Current Remote Public IP: ${W}${REMOTE_PUB}${NC}"
        echo -e "  ${DIM}├─ Current Local Core IP: ${W}${LOCAL_CORE_IP}${NC}"
        echo -e "  ${DIM}├─ Current Remote Core IP: ${W}${REMOTE_CORE_IP}${NC}"
        echo -e "  ${DIM}│${NC}"
        
        echo -ne "  ${C}●${NC} ${W}Enter New Local Public IP [Default: ${Y}${LOCAL_PUB}${W}]: ${NC}"; read -t 30 new_local
        local final_local="${new_local:-$LOCAL_PUB}"; final_local=$(echo "$final_local" | tr -d '[:space:]')
        
        echo -ne "  ${C}●${NC} ${W}Enter New Remote Public IP [Default: ${Y}${REMOTE_PUB}${W}]: ${NC}"; read -t 30 new_remote
        local final_remote="${new_remote:-$REMOTE_PUB}"; final_remote=$(echo "$final_remote" | tr -d '[:space:]')
        
        echo -ne "  ${C}●${NC} ${W}Enter New Local Core IP [Default: ${Y}${LOCAL_CORE_IP}${W}]: ${NC}"; read -t 30 new_lcore
        local final_lcore="${new_lcore:-$LOCAL_CORE_IP}"; final_lcore=$(echo "$final_lcore" | tr -d '[:space:]')
        
        echo -ne "  ${C}●${NC} ${W}Enter New Remote Core IP [Default:
