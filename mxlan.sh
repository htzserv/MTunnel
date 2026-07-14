#!/bin/bash
# --- MXLAN Layer-2 Fabric (mxlan.sh) | MDesign Core v1.2.0 (Sanitized) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mgre/vxlan"
SERVICE_FILE="/etc/systemd/system/mxlan.service"
STATE_DIR="/etc/mgre/states_vx"

mkdir -p "$CONF_DIR" "$STATE_DIR"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

apply_fabric() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    source "$conf"
    
    local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
    local local_br_ip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
    
    local eth_iface=$(ip route get "$REMOTE_PUB" 2>/dev/null | awk '{print $5}' | head -n 1)
    [ -z "$eth_iface" ] && eth_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -n 1)
    
    ip link del "$VX_NAME" >/dev/null 2>&1
    ip link del "$BR_NAME" >/dev/null 2>&1
    
    ip link add "$BR_NAME" type bridge 2>/dev/null
    ip link set "$BR_NAME" up 2>/dev/null
    
    if ip addr show 2>/dev/null | grep -q "$LOCAL_PUB"; then
        ip link add "$VX_NAME" type vxlan id "$VNI_ID" dev "$eth_iface" remote "$REMOTE_PUB" local "$LOCAL_PUB" dstport 4789 2>/dev/null
    else
        ip link add "$VX_NAME" type vxlan id "$VNI_ID" dev "$eth_iface" remote "$REMOTE_PUB" dstport 4789 2>/dev/null
    fi
    
    ip link set "$VX_NAME" master "$BR_NAME" 2>/dev/null
    ip link set "$VX_NAME" up 2>/dev/null
    ip addr add "${local_br_ip}/24" dev "$BR_NAME" 2>/dev/null

    if [[ "$MAX_IPS" -gt 0 ]]; then
        local s_file="${STATE_DIR}/${VX_NAME}.state"
        echo "0" > "$s_file"
        for ((i=1; i<=MAX_IPS; i++)); do
            idx=$(cat "$s_file")
            hash=$(echo "${SYNC_KEY}_${idx}" | sha256sum)
            range_selector=$(( 0x${hash:0:2} % 3 ))
            if [[ "$range_selector" == "0" ]]; then o1="10"; o2=$(( (0x${hash:2:2} % 254) + 1 ))
            elif [[ "$range_selector" == "1" ]]; then o1="172"; o2=$(( (0x${hash:2:2} % 16) + 16 ))
            else o1="192"; o2="168"; fi
            o3=$(( (0x${hash:4:2} % 254) + 1 ))
            last_octet=$([ "$TYPE" == "1" ] && echo "1" || echo "2")
            nip="$o1.$o2.$o3.$last_octet"
            ip addr add "$nip/30" dev "$BR_NAME" label "${BR_NAME}:m" 2>/dev/null
            echo $((idx + 1)) > "$s_file"
        done
    fi
}

apply_all_fabrics() { for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && apply_fabric "$conf"; done; }

draw_mxlan_header() {
    local s_ip=$(get_local_ip); local active_fabrics=0; local total_vips=0
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; source "$conf"
        if ip link show "$VX_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$VX_NAME/operstate 2>/dev/null)" != "down" ]; then ((active_fabrics++)); fi
        total_vips=$((total_vips + MAX_IPS))
    done
    clear; echo ""
    local str1=" MXLAN Layer-2 Fabric 1.2.0 "
    local raw_len=$(( ${#str1} + 1 + 6 + ${#s_ip} + 1 + 17 + ${#active_fabrics} + 1 + 14 + ${#total_vips} ))
    local pad_len=$(( 92 - raw_len )); [ "$pad_len" -lt 0 ] && pad_len=0; local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} ACTIVE FABRICS:${NC}${M} ${active_fabrics} ${NC}${B}│${NC}${DIM} TOTAL V-IPS:${NC}${Y} ${total_vips} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_mxlan_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; source "$conf"
        mapfile -t v_ips < <(ip -4 addr show dev "$BR_NAME" label "${BR_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} %b▼ Fabric: %-80s%b ${B}│${NC}\n" "${M}" "${VX_NAME} / ${BR_NAME} [VXLAN L2]" "${NC}"
        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        local main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local main_lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        
        ping_res=$(ping -c 1 -W 1 "$main_tip" 2>/dev/null)
        if [ $? -eq 0 ]; then lat=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
        
        local m_icon="├─"; [ ${#v_ips[@]} -eq 0 ] && m_icon="└─"
        printf "  ${B}│${NC} ${W}%s %-15s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%s %-10s%b ${B}│${NC}\n" "${m_icon}" "Bridge IP" "$main_lip" "$main_tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        
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

show_fabric_details() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No VXLAN fabrics configured!${NC}"; sleep 1.5; return; fi

    echo -e "\n  ${M}● Deployed Fabrics Registry:${NC}"
    for conf in "${configs[@]}"; do
        source "$conf"
        local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access)" || echo "KHAREJ (Gateway)")
        local s_key="${SYNC_KEY:-[ NOT SET ]}"
        
        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Fabric: $VX_NAME"; local right_p="Role: $t_role"
        local pad=$(( 89 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${M}${left_p}${NC}${sp} ${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="vIP Sync Key : ${s_key}"; local r1="Protocol: Layer-2 VXLAN"
        local pad1=$(( 89 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${Y}vIP Sync Key :${NC} ${W}${s_key}${NC}${sp1} ${DIM}Protocol:${NC} ${W}Layer-2 VXLAN${NC} ${B}│${NC}"
        
        local l2="Network VNI  : ${VNI_ID}"; local r2=" "
        local pad2=$(( 89 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}Network VNI  :${NC} ${W}${VNI_ID}${NC}${sp2} ${B}│${NC}"
        
        local l3="Public IPs   : ${LOCAL_PUB} -> ${REMOTE_PUB}"
        local pad3=$(( 90 - ${#l3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${DIM}Public IPs   :${NC} ${W}${LOCAL_PUB}${NC} ${DIM}->${NC} ${W}${REMOTE_PUB}${NC}${sp3} ${B}│${NC}"
        
        ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
        if [ $? -eq 0 ]; then lat=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
        
        local l4="Bridge IPs   : ${lip} -> ${tip}"; local r4_raw="Link: * ${stat_text} (${lat_raw})"
        local pad4=$(( 89 - ${#l4} - ${#r4_raw} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Bridge IPs   :${NC} ${G}${lip}${NC} ${DIM}->${NC} ${Y}${tip}${NC}${sp4} ${DIM}Link:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${lat_color}(${lat_raw})${NC} ${B}│${NC}"
        
        echo -e "  ${B}│${NC} ${C}Forwarding Database (Remote MAC Table):${NC}                                                ${B}│${NC}"
        local has_mac=false
        while read -r mac dst; do
            if [ -n "$mac" ]; then
                has_mac=true; local l_mac="  ├─ MAC: ${mac}  -->  ${dst}"
                local p_mac=$(( 89 - ${#l_mac} )); [ "$p_mac" -lt 0 ] && p_mac=0; local sp_mac=$(printf '%*s' "$p_mac" "")
                echo -e "  ${B}│${NC} ${DIM}  ├─ MAC:${NC} ${Y}${mac}${NC}  ${DIM}-->${NC}  ${W}${dst}${NC}${sp_mac} ${B}│${NC}"
            fi
        done < <(bridge fdb show dev "$VX_NAME" 2>/dev/null | grep -v "00:00:00:00:00:00" | grep dst | awk '{for(i=1;i<=NF;i++) if($i=="dst") print $1, $(i+1)}')
        
        if [ "$has_mac" = false ]; then echo -e "  ${B}│${NC} ${DIM}  └─ No remote MAC addresses learned yet.${NC}                                              ${B}│${NC}"; fi
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

edit_fabric() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No fabrics configured yet!${NC}"; sleep 1.5; return; fi
    
    echo -e "\n  ${B}╭────────────────── Select Fabric to Edit ───────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        local conf_name=$(basename "${configs[$i]}" .conf)
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$conf_name"
    done
    echo -e "  ${B}├────────────────────────────────────────────────────────────┤${NC}"
    printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${DIM}%-53s${NC} ${B}│${NC}\n" "q" "Cancel and Return"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Fabric Index or 'q': ${NC}"; read t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r')
    
    [[ "$t_idx" == "q" || -z "$t_idx" ]] && return
    
    if [[ -n "${configs[$t_idx]}" ]]; then
        local sel_conf="${configs[$t_idx]}"; source "$sel_conf"
        echo -e "\n  ${DIM}┌─[ HOT-SWAP PUBLIC IPs ]${NC}"
        echo -ne "  ${C}●${NC} ${W}New Local Public IP [${Y}${LOCAL_PUB}${W}] (Or Enter to Skip): ${NC}"; read new_local
        new_local=$(echo "$new_local" | tr -d '\r' | tr -d ' ')
        echo -ne "  ${C}●${NC} ${W}New Remote Public IP [${Y}${REMOTE_PUB}${W}] (Or Enter to Skip): ${NC}"; read new_remote
        new_remote=$(echo "$new_remote" | tr -d '\r' | tr -d ' ')
        [ -n "$new_local" ] && sed -i "s/^LOCAL_PUB=.*/LOCAL_PUB=$new_local/" "$sel_conf"
        [ -n "$new_remote" ] && sed -i "s/^REMOTE_PUB=.*/REMOTE_PUB=$new_remote/" "$sel_conf"
        apply_fabric "$sel_conf"
        echo -e "  ${G}● Fabric re-routed successfully!${NC}"; sleep 1.5
    fi
}

setup_service() {
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=MXLAN Multi-Fabric Service
After=network.target
[Service]
ExecStart=/usr/bin/mxlan --apply
Type=oneshot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable mxlan.service >/dev/null 2>&1
}

if [[ "$1" == "--apply" ]]; then apply_all_fabrics; exit 0; fi

while true; do
    draw_mxlan_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${M}Setup New VXLAN Fabric (VNI Mesh)${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Virtual IP Manager (Add/Purge vIPs)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Delete Fabrics (Specific / ALL)${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Edit Fabric Public IPs (Hot-Swap)${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${M}View Fabric Configurations & MAC Tables${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    echo -ne "  ${M}MXLAN ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1) 
           echo -e "\n  ${DIM}┌─[ VXLAN DEPLOYMENT ]${NC}"
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Server Mode [1:IR | 2:KH | q:Back]: ${NC}"; read s_type
               s_type=$(echo "$s_type" | tr -d '\r' | tr -d ' ')
               [[ "$s_type" == "q" || "$s_type" == "1" || "$s_type" == "2" ]] && break
           done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Fabric Suffix Name (e.g. ir, kh): ${NC}"; read suffix
               suffix=$(echo "$suffix" | tr -d '\r' | tr -d ' ')
               [[ "$suffix" == "q" ]] && break
               [[ -z "$suffix" ]] && continue
               
               vx_name="vx_${suffix}"; br_name="br_${suffix}"
               if [ -f "$CONF_DIR/${vx_name}.conf" ] || ip link show "$vx_name" >/dev/null 2>&1; then
                   echo -e "  ${R}● Error: Fabric interface [${W}${vx_name}${R}] already exists!${NC}"; continue
               fi
               break
           done
           [[ "$suffix" == "q" ]] && continue
           
           local_ip=$(get_local_ip)
           while true; do
               echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}] (Enter for default): ${NC}"; read custom_ip
               custom_ip=$(echo "$custom_ip" | tr -d '\r' | tr -d ' ')
               [[ "$custom_ip" == "q" ]] && break
               [ -n "$custom_ip" ] && local_ip=$custom_ip
               break
           done
           [[ "$custom_ip" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IP: ${NC}"; read r_ip
               r_ip=$(echo "$r_ip" | tr -d '\r' | tr -d ' ')
               [[ "$r_ip" == "q" ]] && break
               [[ -n "$r_ip" ]] && break
           done
           [[ "$r_ip" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Tunnel Network ID / VNI (1-16777215): ${NC}"; read vni_id
               vni_id=$(echo "$vni_id" | tr -d '\r' | tr -d ' ')
               [[ "$vni_id" == "q" ]] && break
               [[ -z "$vni_id" ]] && continue
               if ! [[ "$vni_id" =~ ^[0-9]+$ ]] || [ "$vni_id" -lt 1 ] || [ "$vni_id" -gt 16777215 ]; then echo -e "  ${Y}● Invalid VNI. Must be a number between 1 and 16777215.${NC}"; continue; fi
               if grep -q "VNI_ID=$vni_id$" "$CONF_DIR"/*.conf 2>/dev/null; then echo -e "  ${R}● Error: VNI [${W}${vni_id}${R}] is already assigned!${NC}"; continue; fi
               break
           done
           [[ "$vni_id" == "q" ]] && continue
           
           hash_c=$(echo -n "vni_${vni_id}" | sha256sum)
           c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           core_sub="${c1}.${c2}.${c3}"
           conf_path="$CONF_DIR/${vx_name}.conf"
           
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=\nVX_NAME=$vx_name\nBR_NAME=$br_name\nVNI_ID=$vni_id\nCORE_SUBNET=$core_sub" > "$conf_path"
           
           apply_fabric "$conf_path"
           if ip link show "$vx_name" >/dev/null 2>&1; then
               setup_service; echo -e "  ${G}● Fabric [${vx_name}] deployed successfully (Subnet: ${core_sub}.x)${NC}"; sleep 1.5
           else
               echo -e "\n  ${R}● FATAL ERROR: Kernel rejected VXLAN creation!${NC}"; rm -f "$conf_path"; sleep 3.5
           fi ;;
        2)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && echo -e "\n  ${R}● No fabrics configured yet!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Fabric for vIPs ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           
           while true; do echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx; t_idx=$(echo "$t_idx" | tr -d '\r'); [[ "$t_idx" == "q" ]] && break 2; [[ -n "$t_idx" ]] && break; done
           
           if [[ -n "${configs[$t_idx]}" ]]; then
               sel_conf="${configs[$t_idx]}"; source "$sel_conf"
               echo -e "\n  ${DIM}┌─[ vIP ACTIONS for ${VX_NAME} ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup / Update Virtual IPs${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Purge All Virtual IPs${NC}\n  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
               while true; do echo -ne "  ${C}●${NC} ${W}Select Action: ${NC}"; read vip_action; vip_action=$(echo "$vip_action" | tr -d '\r'); [[ "$vip_action" =~ ^[12q]$ ]] && break; done
               [[ "$vip_action" == "q" ]] && continue
               
               if [[ "$vip_action" == "1" ]]; then
                   while true; do echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read n; n=$(echo "$n" | tr -d '\r'); [[ -n "$n" ]] && break; done
                   [[ "$n" == "q" ]] && continue
                   while true; do echo -ne "  ${C}●${NC} ${W}Sync Key: ${NC}"; read k; k=$(echo "$k" | tr -d '\r'); [[ -n "$k" ]] && break; done
                   [[ "$k" == "q" ]] && continue
                   sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$sel_conf"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$sel_conf"; apply_fabric "$sel_conf"; echo -e "  ${G}● IPs synchronized successfully.${NC}"; sleep 1.5
               elif [[ "$vip_action" == "2" ]]; then
                   if [[ "$MAX_IPS" == "0" || -z "$MAX_IPS" ]]; then echo -e "  ${Y}● No Virtual IPs found!${NC}"; sleep 1.5; continue; fi
                   echo -ne "  ${R}● Delete all ${MAX_IPS} vIPs from [${VX_NAME}]? (y/n): ${NC}"; read confirm_vip; confirm_vip=$(echo "$confirm_vip" | tr -d '\r')
                   if [[ "$confirm_vip" == "y" ]]; then sed -i "s/^MAX_IPS=.*/MAX_IPS=0/" "$sel_conf"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=/" "$sel_conf"; apply_fabric "$sel_conf"; echo -e "  ${G}● Virtual IPs purged.${NC}"; sleep 1.5; fi
               fi
           fi ;;
        3) while true; do draw_mxlan_header; show_mxlan_monitor; read -t 2 -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        4)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && echo -e "\n  ${R}● No active fabrics to remove!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Fabric to Erase ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}├────────────────────────────────────────────────────────────┤${NC}"
           printf "  ${B}│${NC}  ${R}%-3s${NC} ${C}❯${NC} ${R}%-53s${NC} ${B}│${NC}\n" "all" "Delete ALL Fabrics"
           printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${DIM}%-53s${NC} ${B}│${NC}\n" "q" "Cancel and Go Back"
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter Index, 'all', or 'q': ${NC}"; read del_idx
           del_idx=$(echo "$del_idx" | tr -d '\r' | tr -d ' ')
           [[ "$del_idx" == "q" || -z "$del_idx" ]] && continue
           
           if [[ "$del_idx" == "all" ]]; then
               echo -ne "  ${R}● DANGER: Delete ALL VXLAN fabrics? (y/n): ${NC}"; read confirm_all; confirm_all=$(echo "$confirm_all" | tr -d '\r')
               if [[ "$confirm_all" == "y" ]]; then
                   for conf in "${configs[@]}"; do source "$conf"; ip link del "$VX_NAME" >/dev/null 2>&1; ip link del "$BR_NAME" >/dev/null 2>&1; rm -f "$conf" "${STATE_DIR}/${VX_NAME}.state"; done
                   echo -e "  ${G}● All fabrics safely purged.${NC}"; sleep 1.5
               fi; continue
           fi
           if [[ -n "${configs[$del_idx]}" ]]; then
               source "${configs[$del_idx]}"; ip link del "$VX_NAME" >/dev/null 2>&1; ip link del "$BR_NAME" >/dev/null 2>&1
               rm -f "${configs[$del_idx]}" "${STATE_DIR}/${VX_NAME}.state"
               echo -e "  ${G}● Fabric [${VX_NAME}] destroyed.${NC}"; sleep 1.5
           fi ;;
        5) edit_fabric ;; 6) show_fabric_details ;; 0) break ;;
    esac
done
