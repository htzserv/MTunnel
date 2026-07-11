cat << 'EOF_MWALL' > /usr/bin/mwall
#!/bin/bash
# --- MWALL Engine (mwall.sh) | MDesign Core v1.1.0 (Full Options & Hot-Swap) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mwall/tunnels"
STATE_DIR="/etc/mwall/states"
SERVICE_TPL="/etc/systemd/system/mwall@.service"
LOCAL_DIR="/root/mtunnel"

mkdir -p "$CONF_DIR" "$STATE_DIR"

if [ ! -f "$SERVICE_TPL" ]; then
    cat <<EOF > "$SERVICE_TPL"
[Unit]
Description=WaterWall Stealth Tunnel (%i)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/waterwall -c $CONF_DIR/%i.json
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
fi

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_percentage() {
    local pid=$1; local text=$2; local progress=0
    tput civis
    while kill -0 $pid 2>/dev/null; do
        ((progress++))
        if (( progress > 95 )); then progress=95; fi
        printf "\r  %b⟳%b %b%-25s%b %b%3d%%%%%b" "$C" "$NC" "$W" "$text" "$NC" "$C" "$progress" "$NC"
        sleep 0.2
    done
    printf "\r  %b✔%b %b%-25s%b %b100%%%%%b \n" "$G" "$NC" "$W" "$text" "$NC" "$G" "$NC"
    tput cnorm
}

check_ww_binary() {
    if [ ! -f "/usr/local/bin/waterwall" ]; then
        echo -e "\n  ${DIM}● Deploying WaterWall Core Engine...${NC}"
        (
            mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
            wget -qO /tmp/ww.zip "https://github.com/radkesvat/WaterWall/releases/download/v1.46.0/Waterwall-linux-clang-x64.zip" || \
            wget -qO /tmp/ww.zip "https://github.com/radkesvat/WaterWall/releases/latest/download/Waterwall-linux-x64.zip"
            apt-get install -y -q unzip >/dev/null 2>&1
            unzip -q -o /tmp/ww.zip -d /tmp/ww_bin 2>/dev/null
            WW_BIN=$(find /tmp/ww_bin -type f -name "*aterwall*" | head -n 1)
            if [ -n "$WW_BIN" ]; then
                cp "$WW_BIN" /usr/local/bin/waterwall
                chmod +x /usr/local/bin/waterwall
                cp /usr/local/bin/waterwall "$LOCAL_DIR/"
            fi
            rm -rf /tmp/ww.zip /tmp/ww_bin
        ) >/dev/null 2>&1 &
        draw_percentage $! "Compiling WW Engine"
        sleep 1
    fi
}

apply_tunnel() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    source "$conf"
    
    local c_sub="${CORE_SUBNET:-10.88.${TUN_ID}}"
    local local_tun=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")

    cat <<EOF > "$CONF_DIR/${T_NAME}.json"
{
  "log": { "core": { "loglevel": "WARNING", "console": true } },
  "nodes": [
EOF
    if [ "$TYPE" == "1" ]; then
        cat <<EOF >> "$CONF_DIR/${T_NAME}.json"
    {
      "name": "listener", "type": "TcpListener",
      "settings": { "bind": "0.0.0.0", "port": ${WW_PORT} },
      "next": "obfs"
    },
    {
      "name": "obfs", "type": "HalfDuplex",
      "settings": { "password": "${WW_PASS}" },
      "next": "tun"
    },
    {
      "name": "tun", "type": "TunBuilder",
      "settings": { "interface": "${T_NAME}", "ipv4": "${local_tun}/30", "mtu": 1400 }
    }
EOF
    else
        cat <<EOF >> "$CONF_DIR/${T_NAME}.json"
    {
      "name": "tun", "type": "TunBuilder",
      "settings": { "interface": "${T_NAME}", "ipv4": "${local_tun}/30", "mtu": 1400 },
      "next": "obfs"
    },
    {
      "name": "obfs", "type": "HalfDuplex",
      "settings": { "password": "${WW_PASS}" },
      "next": "conn"
    },
    {
      "name": "conn", "type": "TcpConnector",
      "settings": { "address": "${REMOTE_PUB}", "port": ${WW_PORT} }
    }
EOF
    fi
    echo "  ]" >> "$CONF_DIR/${T_NAME}.json"
    echo "}" >> "$CONF_DIR/${T_NAME}.json"

    systemctl daemon-reload
    systemctl enable mwall@${T_NAME} >/dev/null 2>&1
    systemctl restart mwall@${T_NAME} >/dev/null 2>&1
    
    sleep 3
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1360 >/dev/null 2>&1
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1360 >/dev/null 2>&1
    ip link set dev "$T_NAME" up 2>/dev/null

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

draw_mwall_header() {
    local s_ip=$(get_local_ip); local active_tunnels=0; local total_vips=0
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; source "$conf"
        if ip link show "$T_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" != "down" ]; then ((active_tunnels++)); fi
        total_vips=$((total_vips + MAX_IPS))
    done
    clear; echo ""
    local str1=" MWALL Core 1.1.0 (WaterWall) "
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

show_mwall_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; source "$conf"
        mapfile -t v_ips < <(ip -4 addr show dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} %b▼ Tunnel: %-80s%b ${B}│${NC}\n" "${Y}" "${T_NAME} [L3-WaterWall]" "${NC}"
        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        local c_sub="${CORE_SUBNET:-10.88.${TUN_ID}}"
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

    echo -e "\n  ${Y}● Deployed WaterWall Registry (Scanning Network Latency...):${NC}"
    for conf in "${configs[@]}"; do
        source "$conf"
        local c_sub="${CORE_SUBNET:-10.88.${TUN_ID}}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local s_key="${SYNC_KEY:-[ NOT SET ]}"
        local w_pass="${WW_PASS:-[ NOT SAVED ]}"
        local w_port="${WW_PORT:-[ NOT SET ]}"
        local t_id="${TUN_ID:-[ NOT SET ]}"
        local proto_lbl="WaterWall L3"

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $T_NAME"
        local right_p="Role: $t_role"
        local pad=$(( 89 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp} ${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="vIP Sync Key : ${s_key}"; local r1="Protocol: ${proto_lbl}"
        local pad1=$(( 89 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}vIP Sync Key :${NC} ${W}${s_key}${NC}${sp1} ${DIM}Protocol:${NC} ${W}${proto_lbl}${NC} ${B}│${NC}"
        
        local l2="WW Password  : ${w_pass}"; local r2="WW Port: ${w_port} | Net ID: ${t_id}"
        local pad2=$(( 89 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}WW Password  :${NC} ${W}${w_pass}${NC}${sp2} ${DIM}WW Port:${NC} ${W}${w_port}${NC} ${DIM}| Net ID:${NC} ${W}${t_id}${NC} ${B}│${NC}"
        
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
        
        if [[ "$MAX_IPS" -gt 0 ]]; then
            for ((idx=0; idx<MAX_IPS; idx++)); do
                local hash=$(echo "${SYNC_KEY}_${idx}" | sha256sum)
                local range_selector=$(( 0x${hash:0:2} % 3 ))
                local o1 o2 o3
                if [[ "$range_selector" == "0" ]]; then
                    o1="10"; o2=$(( (0x${hash:2:2} % 254) + 1 ))
                elif [[ "$range_selector" == "1" ]]; then
                    o1="172"; o2=$(( (0x${hash:2:2} % 16) + 16 ))
                else
                    o1="192"; o2="168"
                fi
                o3=$(( (0x${hash:4:2} % 254) + 1 ))
                local lo=$([ "$TYPE" == "1" ] && echo "1" || echo "2")
                local to=$([ "$TYPE" == "1" ] && echo "2" || echo "1")
                local v_lip="${o1}.${o2}.${o3}.${lo}"
                local v_tip="${o1}.${o2}.${o3}.${to}"
                
                ping_res_vip=$(ping -c 1 -W 1 "$v_tip" 2>/dev/null)
                if [ $? -eq 0 ]; then
                    v_lat=$(echo "$ping_res_vip" | grep -oP 'time=\K\S+'); v_lat_raw="${v_lat}ms"; v_stat_color="${G}"
                else v_lat_raw="---"; v_stat_color="${R}"; fi
                
                local v_prefix="Virtual IPs  : "
                if [ "$idx" -ne 0 ]; then v_prefix="               "; fi
                local l_str="${v_prefix}${v_lip} -> ${v_tip}"
                local r_str="[${v_lat_raw}]"
                local p_len=$(( 89 - ${#l_str} - ${#r_str} ))
                [ "$p_len" -lt 0 ] && p_len=0; local p_sp=$(printf '%*s' "$p_len" "")
                
                if [ "$idx" -eq 0 ]; then
                    echo -e "  ${B}│${NC} ${DIM}Virtual IPs  :${NC} ${M}${v_lip}${NC} ${DIM}->${NC} ${M}${v_tip}${NC}${p_sp} ${v_stat_color}${r_str}${NC} ${B}│${NC}"
                else
                    echo -e "  ${B}│${NC} ${DIM}               ${M}${v_lip}${NC} ${DIM}->${NC} ${M}${v_tip}${NC}${p_sp} ${v_stat_color}${r_str}${NC} ${B}│${NC}"
                fi
            done
        else
            local l_str="Virtual IPs  : None"
            local p_len=$(( 90 - ${#l_str} )); [ "$p_len" -lt 0 ] && p_len=0; local p_sp=$(printf '%*s' "$p_len" "")
            echo -e "  ${B}│${NC} ${DIM}Virtual IPs  :${NC} ${DIM}None${NC}${p_sp} ${B}│${NC}"
        fi
        
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
        echo -e "  ${G}● WaterWall Node re-routed successfully!${NC}"; sleep 1.5
    fi
}

if [[ "$1" == "--apply" ]]; then apply_all_tunnels; exit 0; fi

while true; do
    draw_mwall_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Setup New WaterWall Tunnel${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Virtual IP Manager (Add/Purge vIPs)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Delete Tunnels (Specific / ALL)${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Edit Tunnel Public IPs (Hot-Swap)${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${C}View Tunnel Configurations & Sync Keys${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MWALL ❯❯ ${NC}"; read opt
    case $opt in
        1) 
           check_ww_binary
           echo -e "\n  ${DIM}┌─[ TUNNEL PROTOCOL ]${NC}\n  ${DIM}├─${NC} ${C}WaterWall Advanced Stealth Engine (Layer 3)${NC}\n  ${DIM}└────────────────────────────────────────────────────────${NC}"
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Server Mode [1:IRAN (Server) | 2:KHAREJ (Client) | q:Back]: ${NC}"; read s_type
               [[ "$s_type" == "q" || "$s_type" == "1" || "$s_type" == "2" ]] && break
           done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Interface Suffix Name (Max 4 chars, e.g. fa): ${NC}"; read suffix
               [[ "$suffix" == "q" ]] && break
               [[ -z "$suffix" ]] && continue
               t_name="ww_$suffix"
               if [ "${#t_name}" -gt 15 ]; then echo -e "  ${R}● Error: Name too long!${NC}"; else break; fi
           done
           [[ "$suffix" == "q" ]] && continue
           
           if [ -f "$CONF_DIR/${t_name}.conf" ]; then
               echo -e "\n  ${R}● Error: Interface [${W}${t_name}${R}] already exists!${NC}"; sleep 2; continue
           fi
           
           local_ip=$(get_local_ip)
           while true; do
               echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}] (Enter for default): ${NC}"; read custom_ip
               [ -n "$custom_ip" ] && local_ip=$custom_ip
               break
           done
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IP: ${NC}"; read r_ip
               [[ -n "$r_ip" ]] && break
           done
           
           while true; do echo -ne "  ${C}●${NC} ${M}WaterWall Stealth Password: ${NC}"; read ww_pass; [[ -n "$ww_pass" ]] && break; done
           while true; do echo -ne "  ${C}●${NC} ${W}WaterWall Connection Port (e.g. 443): ${NC}"; read ww_port; [[ -n "$ww_port" ]] && break; done
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Tunnel Network ID (1-250): ${NC}"; read tun_id
               if grep -q "TUN_ID=$tun_id$" "$CONF_DIR"/*.conf 2>/dev/null; then echo -e "  ${R}● Network ID in use!${NC}"; continue; fi
               [[ -n "$tun_id" ]] && break
           done
           
           hash_c=$(echo -n "core_${tun_id}" | sha256sum); class_selector=$(( tun_id % 3 ))
           if [ "$class_selector" == "1" ]; then c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           elif [ "$class_selector" == "2" ]; then c1="172"; c2=$(( (0x${hash_c:2:2} % 16) + 16 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           else c1="192"; c2="168"; c3=$(( (0x${hash_c:4:2} % 254) + 1 )); fi
           
           core_sub="${c1}.${c2}.${c3}"
           conf_path="$CONF_DIR/${t_name}.conf"
           
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=\nWW_PASS=$ww_pass\nWW_PORT=$ww_port\nT_NAME=$t_name\nTUN_ID=$tun_id\nCORE_SUBNET=$core_sub" > "$conf_path"
           apply_tunnel "$conf_path"
           echo -e "  ${G}● WaterWall Tunnel [${t_name}] deployed (Subnet: ${core_sub}.x)${NC}"; sleep 1.5 ;;
        2)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && echo -e "\n  ${R}● No tunnels configured yet!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel for vIPs ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Select Index: ${NC}"; read t_idx
           if [[ -n "${configs[$t_idx]}" ]]; then
               sel_conf="${configs[$t_idx]}"; source "$sel_conf"
               echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read n
               echo -ne "  ${C}●${NC} ${W}Sync Key: ${NC}"; read k
               sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$sel_conf"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$sel_conf"
               apply_tunnel "$sel_conf"
               echo -e "  ${G}● IPs synchronized successfully.${NC}"; sleep 1.5
           fi ;;
        3) 
           while true; do draw_mwall_header; show_mwall_monitor; read -t 2 -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        4)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Erase ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter Index or 'all': ${NC}"; read del_idx
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do
                   source "$conf"; systemctl stop mwall@$T_NAME 2>/dev/null; ip link del "$T_NAME" >/dev/null 2>&1
                   rm -f "$conf" "${STATE_DIR}/${T_NAME}.state" "$CONF_DIR/${T_NAME}.json"
               done
               echo -e "  ${G}● All tunnels purged.${NC}"; sleep 1.5
           elif [[ -n "${configs[$del_idx]}" ]]; then
               source "${configs[$del_idx]}"; systemctl stop mwall@$T_NAME 2>/dev/null; ip link del "$T_NAME" >/dev/null 2>&1
               rm -f "${configs[$del_idx]}" "${STATE_DIR}/${T_NAME}.state" "$CONF_DIR/${T_NAME}.json"
               echo -e "  ${G}● Tunnel [${T_NAME}] destroyed.${NC}"; sleep 1.5
           fi ;;
        5) edit_tunnel ;;
        6) show_tunnel_details ;;
        0) break ;;
    esac
done
EOF_MWALL
chmod +x /usr/bin/mwall
