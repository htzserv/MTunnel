#!/bin/bash
# --- MXLAN Layer-2 Fabric (mxlan.sh) | MDesign Core v1.3.0 (Full Advanced Edit) ---

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

destroy_fabric_dev() {
    local vx_name="$1"; local br_name="$2"
    ip link del "$vx_name" >/dev/null 2>&1
    ip link del "$br_name" >/dev/null 2>&1
}

apply_fabric() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; source "$conf"
    
    local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
    local local_br_ip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
    
    local eth_iface=$(ip route get "$REMOTE_PUB" 2>/dev/null | awk '{print $5}' | head -n 1)
    [ -z "$eth_iface" ] && eth_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -n 1)
    
    destroy_fabric_dev "$VX_NAME" "$BR_NAME"
    
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
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; source "$conf"
        if ip link show "$VX_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$VX_NAME/operstate 2>/dev/null)" != "down" ]; then ((active_fabrics++)); fi
        total_vips=$((total_vips + MAX_IPS))
    done
    clear; echo ""
    local str1=" MXLAN Layer-2 Fabric 1.3.0 "
    local raw_len=$(( ${#str1} + 1 + 6 + ${#s_ip} + 1 + 17 + ${#active_fabrics} + 1 + 14 + ${#total_vips} ))
    local pad_len=$(( 92 - raw_len )); [ "$pad_len" -lt 0 ] && pad_len=0; local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} ACTIVE FABRICS:${NC}${M} ${active_fabrics} ${NC}${B}│${NC}${DIM} TOTAL V-IPS:${NC}${Y} ${total_vips} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

edit_fabric() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No fabrics configured yet!${NC}"; sleep 1.5; return; fi
    
    echo -e "\n  ${B}╭────────────────── Select Fabric to Edit ───────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        local conf_name=$(basename "${configs[$i]}" .conf)
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$conf_name"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Fabric Index or 'q': ${NC}"; read t_idx
    [[ "$t_idx" == "q" || -z "$t_idx" ]] && return
    
    if [[ -n "${configs[$t_idx]}" ]]; then
        local sel_conf="${configs[$t_idx]}"
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; source "$sel_conf"
        local old_vx="$VX_NAME"; local old_br="$BR_NAME"

        echo -e "\n  ${DIM}┌─[ ADVANCED EDIT: ${W}${old_vx}${DIM} ] (Press Enter to keep current value)${NC}"
        
        echo -ne "  ${C}●${NC} ${W}Server Mode [Current: ${Y}${TYPE}${W}] (1:IR | 2:KH): ${NC}"; read n_type
        n_type=$(echo "$n_type" | tr -d '\r' | tr -d ' '); [ -n "$n_type" ] && TYPE="$n_type"

        echo -ne "  ${C}●${NC} ${W}VXLAN Device Name [Current: ${Y}${VX_NAME}${W}]: ${NC}"; read n_vx
        n_vx=$(echo "$n_vx" | tr -d '\r' | tr -d ' '); [ -n "$n_vx" ] && VX_NAME="$n_vx"

        echo -ne "  ${C}●${NC} ${W}Bridge Device Name [Current: ${Y}${BR_NAME}${W}]: ${NC}"; read n_br
        n_br=$(echo "$n_br" | tr -d '\r' | tr -d ' '); [ -n "$n_br" ] && BR_NAME="$n_br"

        echo -ne "  ${C}●${NC} ${W}Local Public IP [Current: ${Y}${LOCAL_PUB}${W}]: ${NC}"; read n_local
        n_local=$(echo "$n_local" | tr -d '\r' | tr -d ' '); [ -n "$n_local" ] && LOCAL_PUB="$n_local"

        echo -ne "  ${C}●${NC} ${W}Remote Public IP [Current: ${Y}${REMOTE_PUB}${W}]: ${NC}"; read n_remote
        n_remote=$(echo "$n_remote" | tr -d '\r' | tr -d ' '); [ -n "$n_remote" ] && REMOTE_PUB="$n_remote"

        echo -ne "  ${C}●${NC} ${W}VNI ID [Current: ${Y}${VNI_ID}${W}] (1-16777215): ${NC}"; read n_vni
        n_vni=$(echo "$n_vni" | tr -d '\r' | tr -d ' ')
        if [ -n "$n_vni" ]; then
            VNI_ID="$n_vni"
            hash_c=$(echo -n "vni_${VNI_ID}" | sha256sum)
            c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
            CORE_SUBNET="${c1}.${c2}.${c3}"
        fi

        destroy_fabric_dev "$old_vx" "$old_br"
        [ "$old_vx" != "$VX_NAME" ] && rm -f "$sel_conf" "${STATE_DIR}/${old_vx}.state"

        local new_conf_path="$CONF_DIR/${VX_NAME}.conf"
        cat <<EOF > "$new_conf_path"
TYPE=$TYPE
LOCAL_PUB=$LOCAL_PUB
REMOTE_PUB=$REMOTE_PUB
MAX_IPS=$MAX_IPS
SYNC_KEY=$SYNC_KEY
VX_NAME=$VX_NAME
BR_NAME=$BR_NAME
VNI_ID=$VNI_ID
CORE_SUBNET=$CORE_SUBNET
EOF

        apply_fabric "$new_conf_path"
        echo -e "\n  ${G}● Fabric [${VX_NAME}] completely updated!${NC}"; sleep 2
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
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${M}Setup New VXLAN Fabric (VNI Mesh)${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Virtual IP Manager (Add/Purge vIPs)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Delete Fabrics (Specific / ALL)${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Advanced Edit Fabric (All Parameters)${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${M}View Fabric Configurations & MAC Tables${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    echo -ne "  ${M}MXLAN ❯❯ ${NC}"; read opt
    case $opt in
        1) 
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IR | 2:KH | q:Back]: ${NC}"; read s_type; [[ "$s_type" =~ ^[12q]$ ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           while true; do echo -ne "  ${C}●${NC} ${W}Fabric Suffix Name (e.g. ir): ${NC}"; read suffix; [[ -n "$suffix" || "$suffix" == "q" ]] && break; done
           [[ "$suffix" == "q" ]] && continue
           vx_name="vx_${suffix}"; br_name="br_${suffix}"
           local_ip=$(get_local_ip)
           echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}]: ${NC}"; read custom_ip
           [ -n "$custom_ip" ] && local_ip=$custom_ip
           while true; do echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IP: ${NC}"; read r_ip; [[ -n "$r_ip" || "$r_ip" == "q" ]] && break; done
           [[ "$r_ip" == "q" ]] && continue
           while true; do echo -ne "  ${C}●${NC} ${W}VNI ID (1-16777215): ${NC}"; read vni_id; [[ -n "$vni_id" || "$vni_id" == "q" ]] && break; done
           [[ "$vni_id" == "q" ]] && continue
           
           hash_c=$(echo -n "vni_${vni_id}" | sha256sum); c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           core_sub="${c1}.${c2}.${c3}"
           conf_path="$CONF_DIR/${vx_name}.conf"
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=\nVX_NAME=$vx_name\nBR_NAME=$br_name\nVNI_ID=$vni_id\nCORE_SUBNET=$core_sub" > "$conf_path"
           apply_fabric "$conf_path"
           if ip link show "$vx_name" >/dev/null 2>&1; then setup_service; echo -e "  ${G}● Deployed!${NC}"; sleep 1.5; fi ;;
        2)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && continue
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -ne "  ${C}● Select Index: ${NC}"; read t_idx; [[ -z "${configs[$t_idx]}" ]] && continue
           sel_conf="${configs[$t_idx]}"
           echo -ne "  ${C}● Virtual IPs Count: ${NC}"; read n
           echo -ne "  ${C}● Sync Key: ${NC}"; read k
           sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$sel_conf"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$sel_conf"
           apply_fabric "$sel_conf"; echo -e "  ${G}● Synced!${NC}"; sleep 1.5 ;;
        3) while true; do draw_mxlan_header; read -t 2 -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        4)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -ne "  ${C}● Enter Index or 'all': ${NC}"; read del_idx
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do source "$conf"; destroy_fabric_dev "$VX_NAME" "$BR_NAME"; rm -f "$conf" "${STATE_DIR}/${VX_NAME}.state"; done
           elif [[ -n "${configs[$del_idx]}" ]]; then
               source "${configs[$del_idx]}"; destroy_fabric_dev "$VX_NAME" "$BR_NAME"; rm -f "${configs[$del_idx]}" "${STATE_DIR}/${VX_NAME}.state"
           fi; echo -e "  ${G}● Destroyed!${NC}"; sleep 1.5 ;;
        5) edit_fabric ;; 6) break ;; 0) break ;;
    esac
done
