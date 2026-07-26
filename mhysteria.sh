#!/bin/bash
# --- MHysteria Modular Core | Hysteria2+WG Engine v1.1.0 (Sanitized) ---
# [PATCHED: Variable scoping fixed during sourcing]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mhysteria/tunnels"
STATE_DIR="/etc/mhysteria/states"
SERVICE_TPL="/etc/systemd/system/mhysteria@.service"
LOCAL_DIR="/root/mtunnel"

mkdir -p "$CONF_DIR" "$STATE_DIR" /etc/mhysteria/certs "$LOCAL_DIR" 2>/dev/null

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

check_deps() {
    if ! command -v wg >/dev/null 2>&1 || ! command -v hysteria >/dev/null 2>&1; then
        echo -e "\n  ${DIM}● Deploying Hysteria2 & WireGuard Cores...${NC}"
        apt-get update -y -q >/dev/null 2>&1
        apt-get install -y -q wireguard-tools python3 >/dev/null 2>&1
        if [ ! -f "/usr/local/bin/hysteria" ]; then
            wget -qO /tmp/hys.gz https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64.gz
            gzip -d /tmp/hys.gz; mv /tmp/hys /usr/local/bin/hysteria; chmod +x /usr/local/bin/hysteria
        fi
        ln -sf /usr/local/bin/hysteria /usr/bin/hysteria 2>/dev/null
    fi
    if [ ! -f "/etc/mhysteria/certs/server.crt" ]; then
        openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/mhysteria/certs/server.key -out /etc/mhysteria/certs/server.crt -days 3650 -subj "/CN=bing.com" >/dev/null 2>&1
    fi
}

apply_tunnel() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    unset TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET T_NAME TUN_ID CORE_SUBNET TUN_PROTO LOCAL_IP6 REMOTE_IP6 VNI_ID BR_NAME TUN_PORT HYS_PASS VX_NAME 2>/dev/null; source "$conf"
    
    local c_sub="${CORE_SUBNET:-10.99.${TUN_ID}}"
    local local_tun=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
    local wg_port=$((20000 + TUN_ID))
    
    IR_PRIV=$(python3 -c "import hashlib, base64; print(base64.b64encode(hashlib.sha256(b'${SYNC_KEY}_IRAN').digest()).decode())")
    KH_PRIV=$(python3 -c "import hashlib, base64; print(base64.b64encode(hashlib.sha256(b'${SYNC_KEY}_KHAREJ').digest()).decode())")
    IR_PUB=$(echo "$IR_PRIV" | wg pubkey); KH_PUB=$(echo "$KH_PRIV" | wg pubkey)

    mkdir -p "$CONF_DIR/$T_NAME"
    rm -f "$CONF_DIR/$T_NAME/wg.conf" "$CONF_DIR/$T_NAME/hys.yaml"

    if [ "$TYPE" == "1" ]; then
        cat <<EOF > "$CONF_DIR/$T_NAME/wg.conf"
[Interface]
PrivateKey = $IR_PRIV
Address = $local_tun/30
MTU = 1300
[Peer]
PublicKey = $KH_PUB
Endpoint = 127.0.0.1:$wg_port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
EOF
        cat <<EOF > "$CONF_DIR/$T_NAME/hys.yaml"
server: $REMOTE_PUB:$TUN_PORT
auth: $HYS_PASS
obfs:
  type: salamander
  salamander:
    password: $HYS_PASS
tls:
  sni: bing.com
  insecure: true
udpForwarding:
  - listen: 127.0.0.1:$wg_port
    remote: 127.0.0.1:$wg_port
    timeout: 60s
EOF
    else
        cat <<EOF > "$CONF_DIR/$T_NAME/wg.conf"
[Interface]
PrivateKey = $KH_PRIV
Address = $local_tun/30
ListenPort = $wg_port
MTU = 1300
[Peer]
PublicKey = $IR_PUB
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
EOF
        cat <<EOF > "$CONF_DIR/$T_NAME/hys.yaml"
listen: :$TUN_PORT
tls:
  cert: /etc/mhysteria/certs/server.crt
  key: /etc/mhysteria/certs/server.key
auth:
  type: password
  password: $HYS_PASS
obfs:
  type: salamander
  salamander:
    password: $HYS_PASS
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOF
    fi

    cat <<EOF > "/etc/systemd/system/mhysteria@${T_NAME}.service"
[Unit]
Description=MHysteria Tunnel (%i)
After=network.target
[Service]
Type=simple
WorkingDirectory=$CONF_DIR/%i
ExecStartPre=-/usr/bin/wg-quick down $CONF_DIR/%i/wg.conf
ExecStartPre=/usr/bin/wg-quick up $CONF_DIR/%i/wg.conf
ExecStart=/usr/local/bin/hysteria $([ "$TYPE" == "1" ] && echo "client" || echo "server") -c $CONF_DIR/%i/hys.yaml
ExecStopPost=-/usr/bin/wg-quick down $CONF_DIR/%i/wg.conf
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable mhysteria@${T_NAME} >/dev/null 2>&1; systemctl restart mhysteria@${T_NAME}

    if [[ "$MAX_IPS" -gt 0 ]]; then
        local s_file="${STATE_DIR}/${T_NAME}.state"; echo "0" > "$s_file"
        for ((i=1; i<=MAX_IPS; i++)); do
            idx=$(cat "$s_file"); hash=$(echo "${SYNC_KEY}_${idx}" | sha256sum); range_selector=$(( 0x${hash:0:2} % 3 ))
            if [[ "$range_selector" == "0" ]]; then o1="10"; o2=$(( (0x${hash:2:2} % 254) + 1 ))
            elif [[ "$range_selector" == "1" ]]; then o1="172"; o2=$(( (0x${hash:2:2} % 16) + 16 ))
            else o1="192"; o2="168"; fi
            o3=$(( (0x${hash:4:2} % 254) + 1 )); last_octet=$([ "$TYPE" == "1" ] && echo "1" || echo "2")
            nip="$o1.$o2.$o3.$last_octet"
            ip addr add "$nip/30" dev "$T_NAME" 2>/dev/null
            echo $((idx + 1)) > "$s_file"
        done
    fi
}

apply_all_tunnels() { for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && apply_tunnel "$conf"; done; }
if [[ "$1" == "--apply" ]]; then apply_all_tunnels; exit 0; fi

draw_header() {
    local s_ip=$(get_local_ip); local active_tunnels=0
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; unset TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET T_NAME TUN_ID CORE_SUBNET TUN_PROTO LOCAL_IP6 REMOTE_IP6 VNI_ID BR_NAME TUN_PORT HYS_PASS VX_NAME 2>/dev/null; source "$conf"
        if ip link show "$T_NAME" >/dev/null 2>&1; then ((active_tunnels++)); fi
    done
    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MHysteria QUIC Engine v1.1.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}TUNNELS:${NC} ${G}${active_tunnels}${NC} ${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Setup New Hysteria2+WG Tunnel${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Virtual IP Manager${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit${NC}\n"
    echo -ne "  ${C}MHYSTERIA ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1) 
           check_deps
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IRAN (Client) | 2:KHAREJ (Server) | q:Back]: ${NC}"; read s_type; s_type=$(echo "$s_type" | tr -d '\r' | tr -d ' '); [[ "$s_type" =~ ^[12q]$ ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           while true; do echo -ne "  ${C}●${NC} ${W}Interface Suffix (e.g. fa): ${NC}"; read suffix; suffix=$(echo "$suffix" | tr -d '\r' | tr -d ' '); t_name="hys_$suffix"; break; done
           local_ip=$(get_local_ip); echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}]: ${NC}"; read custom_ip; custom_ip=$(echo "$custom_ip" | tr -d '\r' | tr -d ' '); [ -n "$custom_ip" ] && local_ip=$custom_ip
           echo -ne "  ${C}●${NC} ${W}Remote Public IP: ${NC}"; read r_ip; r_ip=$(echo "$r_ip" | tr -d '\r' | tr -d ' ')
           echo -ne "  ${C}●${NC} ${W}Hysteria Obfs Password: ${NC}"; read h_pass; h_pass=$(echo "$h_pass" | tr -d '\r')
           echo -ne "  ${C}●${NC} ${W}Hysteria UDP Port (e.g. 443): ${NC}"; read t_port; t_port=$(echo "$t_port" | tr -d '\r' | tr -d ' ')
           echo -ne "  ${C}●${NC} ${W}Tunnel Network ID (1-250): ${NC}"; read t_id; t_id=$(echo "$t_id" | tr -d '\r' | tr -d ' ')
           echo -ne "  ${C}●${NC} ${W}vIP Master Sync Key: ${NC}"; read s_key; s_key=$(echo "$s_key" | tr -d '\r')
           
           c_sub="10.99.$t_id"
           conf_path="$CONF_DIR/${t_name}.conf"
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=$s_key\nTUN_PORT=$t_port\nT_NAME=$t_name\nTUN_ID=$t_id\nHYS_PASS=$h_pass\nCORE_SUBNET=$c_sub" > "$conf_path"
           apply_tunnel "$conf_path"; echo -e "  ${G}● Tunnel Deployed!${NC}"; sleep 1.5 ;;
        2)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null)); [ ${#configs[@]} -eq 0 ] && continue
           for i in "${!configs[@]}"; do echo "  $i ❯ $(basename "${configs[$i]}" .conf)"; done
           echo -ne "  Index: "; read t_idx; t_idx=$(echo "$t_idx" | tr -d '\r'); sel_conf="${configs[$t_idx]}"
           echo -ne "  vIP Count: "; read n; n=$(echo "$n" | tr -d '\r'); sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$sel_conf"; apply_tunnel "$sel_conf"; echo -e "  ${G}Synced!${NC}"; sleep 1 ;;
        3)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           for i in "${!configs[@]}"; do echo "  $i ❯ $(basename "${configs[$i]}" .conf)"; done
           echo -ne "  Index (or 'all'): "; read del_idx; del_idx=$(echo "$del_idx" | tr -d '\r' | tr -d ' ')
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do unset TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET T_NAME TUN_ID CORE_SUBNET TUN_PROTO LOCAL_IP6 REMOTE_IP6 VNI_ID BR_NAME TUN_PORT HYS_PASS VX_NAME 2>/dev/null; source "$conf"; systemctl stop mhysteria@$T_NAME 2>/dev/null; systemctl disable mhysteria@$T_NAME 2>/dev/null; ip link del "$T_NAME" 2>/dev/null; rm -rf "$CONF_DIR/$T_NAME" "$conf"; done
           else
               unset TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET T_NAME TUN_ID CORE_SUBNET TUN_PROTO LOCAL_IP6 REMOTE_IP6 VNI_ID BR_NAME TUN_PORT HYS_PASS VX_NAME 2>/dev/null; source "${configs[$del_idx]}"; systemctl stop mhysteria@$T_NAME 2>/dev/null; ip link del "$T_NAME" 2>/dev/null; rm -rf "$CONF_DIR/$T_NAME" "${configs[$del_idx]}"
           fi; echo -e "  ${G}Purged!${NC}"; sleep 1 ;;
        0) break ;;
    esac
done
