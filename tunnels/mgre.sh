#!/bin/bash
# --- MGRE Modular Core (mgre.sh) | MDesign Core v4.3.0 (Full Advanced Edit) ---

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

destroy_tunnel_dev() {
    local t_name="$1"
    [ -z "$t_name" ] && return
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$t_name" -j TCPMSS --set-mss 1396 >/dev/null 2>&1
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$t_name" -j TCPMSS --set-mss 1436 >/dev/null 2>&1
    ip tunnel del "$t_name" >/dev/null 2>&1
    ip tunnel del "sit_$t_name" >/dev/null 2>&1
    ip link del "$t_name" >/dev/null 2>&1
    ip link del "sit_$t_name" >/dev/null 2>&1
}

apply_tunnel() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; source "$conf"
    
    local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
    local local_tun=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
    
    destroy_tunnel_dev "$T_NAME"

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
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; source "$conf"
        if ip link show "$T_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" != "down" ]; then ((active_tunnels++)); fi
        total_vips=$((total_vips + MAX_IPS))
    done
    clear; echo ""
    local str1=" MGRE Core 4.3.0 "
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
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; source "$conf"
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
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; source "$conf"
        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access)" || echo "KHAREJ (Gateway)")
        local s_key="${SYNC_KEY:-[ NOT SET ]}"
        local t_sec="${TUN_SECRET:-[ NOT SAVED ]}"
        local t_id="${TUN_ID:-[ NOT SET ]}"
        
        local proto_lbl="IPv4 GRE"
        [[ "$TUN_PROTO" == "6to4" ]] && proto_lbl="6to4 IP6GRE"

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $T_NAME"
        local right_p="Role: $t_role"
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
        
        ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
        if [ $? -eq 0 ]; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
        
        local l4="Core IPs     : ${lip} -> ${tip}"
        local r4_raw="Link: * ${stat_text} (${lat_raw})"
        local pad4=$(( 89 - ${#l4} - ${#r4_raw} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Core IPs     :${NC} ${G}${lip}${NC} ${DIM}->${NC} ${Y}${tip}${NC}${sp4} ${DIM}Link:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${lat_color}(${lat_raw})${NC} ${B}│${NC}"
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
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Tunnel Index or 'q': ${NC}"; read t_idx
    [[ "$t_idx" == "q" || -z "$t_idx" ]] && return
    
    if [[ -n "${configs[$t_idx]}" ]]; then
        local sel_conf="${configs[$t_idx]}"
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; source "$sel_conf"
        local old_tname="$T_NAME"

        echo -e "\n  ${DIM}┌─[ EDITING TUNNEL: ${W}${old_tname}${DIM} ] (Press Enter to keep current value)${NC}"
        
        echo -ne "  ${C}●${NC} ${W}Server Mode [Current: ${Y}${TYPE}${W}] (1:IR | 2:KH): ${NC}"; read n_type
        n_type=$(echo "$n_type" | tr -d '\r' | tr -d ' '); [ -n "$n_type" ] && TYPE="$n_type"

        echo -ne "  ${C}●${NC} ${W}Tunnel Protocol [Current: ${Y}${TUN_PROTO}${W}] (1:ipv4 | 2:6to4): ${NC}"; read n_proto_choice
        n_proto_choice=$(echo "$n_proto_choice" | tr -d '\r' | tr -d ' ')
        if [ "$n_proto_choice" == "1" ]; then TUN_PROTO="ipv4"; elif [ "$n_proto_choice" == "2" ]; then TUN_PROTO="6to4"; fi

        echo -ne "  ${C}●${NC} ${W}Interface Name [Current: ${Y}${T_NAME}${W}]: ${NC}"; read n_name
        n_name=$(echo "$n_name" | tr -d '\r' | tr -d ' '); [ -n "$n_name" ] && T_NAME="$n_name"

        echo -ne "  ${C}●${NC} ${W}Local Public IP [Current: ${Y}${LOCAL_PUB}${W}]: ${NC}"; read n_local
        n_local=$(echo "$n_local" | tr -d '\r' | tr -d ' '); [ -n "$n_local" ] && LOCAL_PUB="$n_local"

        echo -ne "  ${C}●${NC} ${W}Remote Public IP [Current: ${Y}${REMOTE_PUB}${W}]: ${NC}"; read n_remote
        n_remote=$(echo "$n_remote" | tr -d '\r' | tr -d ' '); [ -n "$n_remote" ] && REMOTE_PUB="$n_remote"

        echo -ne "  ${C}●${NC} ${W}Tunnel Network ID [Current: ${Y}${TUN_ID}${W}] (1-250): ${NC}"; read n_tun_id
        n_tun_id=$(echo "$n_tun_id" | tr -d '\r' | tr -d ' ')
        if [ -n "$n_tun_id" ]; then
            TUN_ID="$n_tun_id"
            hash_c=$(echo -n "core_${TUN_ID}" | sha256sum)
            class_selector=$(( TUN_ID % 3 ))
            if [ "$class_selector" == "1" ]; then c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
            elif [ "$class_selector" == "2" ]; then c1="172"; c2=$(( (0x${hash_c:2:2} % 16) + 16 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
            else c1="192"; c2="168"; c3=$(( (0x${hash_c:4:2} % 254) + 1 )); fi
            CORE_SUBNET="${c1}.${c2}.${c3}"
        fi

        if [[ "$TUN_PROTO" == "6to4" ]]; then
            echo -ne "  ${C}●${NC} ${M}Tunnel Secret Key [Current: ${Y}${TUN_SECRET}${M}]: ${NC}"; read n_secret
            n_secret=$(echo "$n_secret" | tr -d '\r' | tr -d ' ')
            [ -n "$n_secret" ] && TUN_SECRET="$n_secret"
            hash_str=$(echo -n "${TUN_SECRET}_MHDesign" | sha256sum)
            pfx_v6="fd${hash_str:0:2}:${hash_str:2:4}:${hash_str:6:4}:${hash_str:10:4}"
            if [[ "$TYPE" == "1" ]]; then LOCAL_IP6="${pfx_v6}::1"; REMOTE_IP6="${pfx_v6}::2"; else LOCAL_IP6="${pfx_v6}::2"; REMOTE_IP6="${pfx_v6}::1"; fi
        else
            TUN_SECRET=""; LOCAL_IP6=""; REMOTE_IP6=""
        fi

        destroy_tunnel_dev "$old_tname"
        [ "$old_tname" != "$T_NAME" ] && rm -f "$sel_conf" "${STATE_DIR}/${old_tname}.state"

        local new_conf_path="$CONF_DIR/${T_NAME}.conf"
        cat <<EOF > "$new_conf_path"
TYPE=$TYPE
LOCAL_PUB=$LOCAL_PUB
REMOTE_PUB=$REMOTE_PUB
MAX_IPS=$MAX_IPS
SYNC_KEY=$SYNC_KEY
TUN_SECRET=$TUN_SECRET
T_NAME=$T_NAME
TUN_ID=$TUN_ID
CORE_SUBNET=$CORE_SUBNET
TUN_PROTO=$TUN_PROTO
LOCAL_IP6=$LOCAL_IP6
REMOTE_IP6=$REMOTE_IP6
EOF

        apply_tunnel "$new_conf_path"
        echo -e "\n  ${G}● Tunnel [${T_NAME}] completely updated and rebuilt!${NC}"; sleep 2
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
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Setup New Tunnel (IPv4 / IP6GRE)${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Virtual IP Manager (Add/Purge vIPs)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Delete Tunnels (Specific / ALL)${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Advanced Edit Tunnel (All Parameters)${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${C}View Tunnel Configurations & Sync Keys${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MGRE ❯❯ ${NC}"; read opt
    case $opt in
        1) 
           echo -e "\n  ${DIM}┌─[ TUNNEL PROTOCOL ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Standard IPv4 GRE${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}6to4 IP6GRE Encapsulation${NC}\n  ${DIM}├─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel and Go Back${NC}"
           while true; do echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read proto_choice; [[ "$proto_choice" == "q" || "$proto_choice" == "1" || "$proto_choice" == "2" ]] && break; done
           [[ "$proto_choice" == "q" ]] && continue
           tun_proto="ipv4"; [ "$proto_choice" == "2" ] && tun_proto="6to4"
           
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IR | 2:KH | q:Back]: ${NC}"; read s_type; [[ "$s_type" =~ ^[12q]$ ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Interface Suffix Name (e.g. fr): ${NC}"; read suffix
               [[ "$suffix" == "q" ]] && break; [[ -z "$suffix" ]] && continue
               pfx=$([ "$tun_proto" == "6to4" ] && echo "$([ "$s_type" == "1" ] && echo "gre6ir" || echo "gre6kh")" || echo "$([ "$s_type" == "1" ] && echo "greir" || echo "grekh")")
               t_name="${pfx}${suffix}"
               [ "${#t_name}" -le 15 ] && break
               echo -e "  ${R}● Error: Name too long! Kernel limit is 15 chars.${NC}"
           done
           [[ "$suffix" == "q" ]] && continue
           
           [ -f "$CONF_DIR/${t_name}.conf" ] && { echo -e "\n  ${R}● Error: Interface already exists!${NC}"; sleep 2; continue; }
           
           local_ip=$(get_local_ip)
           echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}]: ${NC}"; read custom_ip
           [ -n "$custom_ip" ] && local_ip=$custom_ip
           
           while true; do echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IP: ${NC}"; read r_ip; [[ -n "$r_ip" || "$r_ip" == "q" ]] && break; done
           [[ "$r_ip" == "q" ]] && continue
           
           local_ip6=""; remote_ip6=""; tun_secret=""
           if [[ "$tun_proto" == "6to4" ]]; then
               while true; do echo -ne "  ${C}●${NC} ${M}Tunnel Secret Key: ${NC}"; read tun_secret; [[ -n "$tun_secret" || "$tun_secret" == "q" ]] && break; done
               [[ "$tun_secret" == "q" ]] && continue
               hash_str=$(echo -n "${tun_secret}_MHDesign" | sha256sum)
               pfx_v6="fd${hash_str:0:2}:${hash_str:2:4}:${hash_str:6:4}:${hash_str:10:4}"
               if [[ "$s_type" == "1" ]]; then local_ip6="${pfx_v6}::1"; remote_ip6="${pfx_v6}::2"; else local_ip6="${pfx_v6}::2"; remote_ip6="${pfx_v6}::1"; fi
           fi
           
           while true; do echo -ne "  ${C}●${NC} ${W}Tunnel Network ID (1-250): ${NC}"; read user_tun_id; [[ -n "$user_tun_id" || "$user_tun_id" == "q" ]] && break; done
           [[ "$user_tun_id" == "q" ]] && continue
           
           tun_id=$user_tun_id; hash_c=$(echo -n "core_${tun_id}" | sha256sum); class_selector=$(( tun_id % 3 ))
           if [ "$class_selector" == "1" ]; then c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           elif [ "$class_selector" == "2" ]; then c1="172"; c2=$(( (0x${hash_c:2:2} % 16) + 16 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           else c1="192"; c2="168"; c3=$(( (0x${hash_c:4:2} % 254) + 1 )); fi
           
           core_sub="${c1}.${c2}.${c3}"
           conf_path="$CONF_DIR/${t_name}.conf"
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=\nTUN_SECRET=$tun_secret\nT_NAME=$t_name\nTUN_ID=$tun_id\nCORE_SUBNET=$core_sub\nTUN_PROTO=$tun_proto\nLOCAL_IP6=$local_ip6\nREMOTE_IP6=$remote_ip6" > "$conf_path"
           apply_tunnel "$conf_path"
           
           if ip link show "$t_name" >/dev/null 2>&1; then
               setup_service
               echo -e "  ${G}● Tunnel [${t_name}] deployed successfully!${NC}"; sleep 1.5
           fi ;;
        2)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && continue
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -ne "  ${C}● Select Index: ${NC}"; read t_idx; [[ -z "${configs[$t_idx]}" ]] && continue
           sel_conf="${configs[$t_idx]}"
           echo -ne "  ${C}● Virtual IPs Count: ${NC}"; read n
           echo -ne "  ${C}● Sync Key: ${NC}"; read k
           sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$sel_conf"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$sel_conf"
           apply_tunnel "$sel_conf"; echo -e "  ${G}● Synced!${NC}"; sleep 1 ;;
        3) while true; do draw_mgre_header; show_mgre_monitor; read -t 2 -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        4)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -ne "  ${C}● Enter Index or 'all': ${NC}"; read del_idx
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do source "$conf"; destroy_tunnel_dev "$T_NAME"; rm -f "$conf" "${STATE_DIR}/${T_NAME}.state"; done
           elif [[ -n "${configs[$del_idx]}" ]]; then
               source "${configs[$del_idx]}"; destroy_tunnel_dev "$T_NAME"; rm -f "${configs[$del_idx]}" "${STATE_DIR}/${T_NAME}.state"
           fi; echo -e "  ${G}● Destroyed!${NC}"; sleep 1 ;;
        5) edit_tunnel ;; 6) show_tunnel_details ;; 0) break ;;
    esac
done
