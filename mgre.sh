#!/bin/bash
# --- MGRE Modular Core (mgre.sh) | MDesign Core v4.2.15 ---
# [PATCHED: Variable scoping fixed during sourcing]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mgre/tunnels"
SERVICE_FILE="/etc/systemd/system/mgre.service"
STATE_DIR="/etc/mgre/states"

mkdir -p "$CONF_DIR" "$STATE_DIR"

apply_tunnel() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    unset TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET T_NAME TUN_ID CORE_SUBNET TUN_PROTO LOCAL_IP6 REMOTE_IP6
    source "$conf"
    
    local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
    local local_tun=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
    
    ip tunnel del "$T_NAME" >/dev/null 2>&1
    local mtu_val=$([ "$TYPE" == "1" ] && echo "1436" || echo "1476")
    ip tunnel add "$T_NAME" mode gre remote "$REMOTE_PUB" local "$LOCAL_PUB" ttl 255 key "$TUN_ID" 2>/dev/null
    ip link set "$T_NAME" up 2>/dev/null; ip addr add "$local_tun"/30 dev "$T_NAME" 2>/dev/null
    ip link set dev "$T_NAME" mtu "$mtu_val" 2>/dev/null
}

apply_all_tunnels() {
    for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && apply_tunnel "$conf"; done
}
if [[ "$1" == "--apply" ]]; then apply_all_tunnels; exit 0; fi
echo "MGRE is running..."
