#!/bin/bash
# --- MTunnel Master Core | Central Dashboard v1.1.2 ---
# [Features: Universal Persistent Header | In-Place Live Refresh | Smart Skip-Installed Cache | Dynamic IPv6 Peer Width]
MODULE_VERSION="1.1.2"
MTUNNEL_REQUIRED_CORE_API=1
MTUNNEL_REQUIRED_LAYOUT_REV=2
umask 077
# MTUNNEL_COMMON_LOADER -- common API 1, required by this module.
# Source next to a checkout first, or from the system-wide installed location.
# No network calls, implicit fallbacks to generated code, or silent failures.
mt_load_common() {
    local script_dir candidate
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    for candidate in \
        "$script_dir/core/common.sh" \
        "$script_dir/../core/common.sh" \
        /usr/lib/mtunnel/common.sh \
        /root/mtunnel/core/common.sh; do
        if [[ -f "$candidate" && -r "$candidate" ]]; then
            # A bad or incompatible shared core must fail loudly, not fall back.
            source "$candidate" || return 1
            if [[ "${MTUNNEL_CORE_API:-}" == "${MTUNNEL_REQUIRED_CORE_API:-1}" && "${MTUNNEL_LAYOUT_REV:-}" == "${MTUNNEL_REQUIRED_LAYOUT_REV:-2}" ]]; then return 0; fi
            printf 'MTunnel: incompatible shared core: %s\n' "$candidate" >&2
            return 1
        fi
    done
    echo 'MTunnel: core/common.sh is missing. Reinstall the complete bundle (bash install.sh --local .).' >&2
    return 1
}
mt_load_common || exit 1
unset -f mt_load_common
if [ "$EUID" != 0 ]; then echo "Run MTunnel with sudo." >&2; exit 1; fi
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
MTUNNEL_PATH="/usr/bin/mtunnel"
REPO_SCRIPTS="$MTUNNEL_GITHUB_BASE"
MIRROR_SCRIPTS="$MTUNNEL_MIRROR_BASE"
MIRROR_PACKAGES="$MTUNNEL_MIRROR_BASE/packages"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
UPDATE_FILE="$SECURE_TMP/.modules_update_status"
declare -A MOD_MAP=(
    ["main"]="main.sh"
    ["mporter"]="mporter.sh"
    ["mgre"]="tunnels/mgre.sh"
    ["mxlan"]="tunnels/mxlan.sh"
    ["mrathole"]="tunnels/mrathole.sh"
    ["mbackhaul"]="tunnels/mbackhaul.sh"
    ["mpaqet"]="tunnels/mpaqet.sh"
)
ALL_MODULES=("main" "mporter" "mgre" "mxlan" "mrathole" "mbackhaul" "mpaqet")
# Every shell component can also be updated independently from GitHub/mirror,
# a direct link, or Manual Code Paste. Bundle sync remains available separately.
declare -A COMPONENT_MAP=(
    ["main"]="main.sh"
    ["mporter"]="mporter.sh"
    ["mgre"]="tunnels/mgre.sh"
    ["mxlan"]="tunnels/mxlan.sh"
    ["mrathole"]="tunnels/mrathole.sh"
    ["mbackhaul"]="tunnels/mbackhaul.sh"
    ["mpaqet"]="tunnels/mpaqet.sh"
    ["common"]="core/common.sh"
    ["install"]="install.sh"
)
EDITABLE_COMPONENTS=("main" "mporter" "mgre" "mxlan" "mrathole" "mbackhaul" "mpaqet" "common" "install")
UPDATE_COMPONENTS=("main" "mporter" "mgre" "mxlan" "mrathole" "mbackhaul" "mpaqet" "common" "install")
ALL_PACKAGES=(
    "bh"
    "rathole"
    "paqet"
    "gost"
    "haproxy"
    "cron_3.0pl1-184ubuntu2_amd64.deb"
    "curl_8.5.0-2ubuntu10.11_amd64.deb"
    "gzip_1.12-1ubuntu3.2_amd64.deb"
    "haproxy_2.8.16-0ubuntu0.24.04.3_amd64.deb"
    "libiperf0_3.20-2.1_amd64.deb"
    "iperf3_3.16-1build2_amd64.deb"
    "iproute2_6.1.0-1ubuntu6.4_amd64.deb"
    "jq_1.7.1-3ubuntu0.24.04.2_amd64.deb"
    "qrencode_4.1.1-1build2_amd64.deb"
    "socat_1.8.0.0-4ubuntu0.1_amd64.deb"
    "wget_1.21.4-1ubuntu4.1_amd64.deb"
)
declare -A BIN_VERSIONS=(
    ["bh"]="0.7.2"
    ["rathole"]="0.5.0"
    ["paqet"]="1.0.0"
    ["gost"]="2.11.5"
    ["haproxy"]="2.8.16"
)
mkdir -p "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null
if [[ ! -x "$MTUNNEL_PATH" ]]; then
    cp "$0" "$MTUNNEL_PATH" 2>/dev/null
    chmod +x "$MTUNNEL_PATH" 2>/dev/null
fi
MAIN_PID=$$
NEED_REFRESH=false
NEED_LIVE_HEADER_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1
trap 'NEED_LIVE_HEADER_REFRESH=true' SIGUSR2
UPDATE_CHECK_INTERVAL=30
STATS_CHECK_INTERVAL=5
fetch_bundle_version() {
    # One tiny request for the whole bundle. Empty output means: use per-module fallback.
    local v='' cb="?t=$(date +%s%N)"
    if command -v curl >/dev/null 2>&1; then
        v=$(curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 2 --max-time 4 "$REPO_SCRIPTS/VERSION$cb" 2>/dev/null | head -c 32 | tr -d '\r\n ')
    elif command -v wget >/dev/null 2>&1; then
        v=$(wget -qO- --header="Cache-Control: no-cache" --timeout=4 "$REPO_SCRIPTS/VERSION$cb" 2>/dev/null | head -c 32 | tr -d '\r\n ')
    fi
    [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$v"
    return 0
}
component_local_version_for_watch() {
    local mod="$1" file=''
    case "$mod" in
        main) file="$MTUNNEL_PATH";;
        common) file=/usr/lib/mtunnel/common.sh;;
        install) file="$LOCAL_DIR/install.sh";;
        *) file="/usr/bin/$mod";;
    esac
    [ -f "$file" ] || file="$LOCAL_DIR/${COMPONENT_MAP[$mod]}"
    if [ "$mod" == common ]; then
        sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$file" 2>/dev/null | head -n1
    else
        sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$file" 2>/dev/null | head -n1
    fi
}
check_single_module_silent() {
    local mod="$1" rel_path="${COMPONENT_MAP[$1]:-}" out_file="$SECURE_TMP/.chk_${1}"
    local cur_v='' rem_v='' cb="?t=$(date +%s%N)" payload=''
    rm -f "$out_file"
    [ -n "$rel_path" ] || return 0
    cur_v=$(component_local_version_for_watch "$mod"); [ -n "$cur_v" ] || cur_v='0.0.0'
    # Per-file checks are intentional: independent component versions are supported,
    # so the bundle VERSION marker must never be reused as a module's remote version.
    if command -v curl >/dev/null 2>&1; then
        payload=$(curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 2 --max-time 5 "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null) || payload=''
    elif command -v wget >/dev/null 2>&1; then
        payload=$(wget -qO- --header="Cache-Control: no-cache" --timeout=5 "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null) || payload=''
    fi
    if [ "$mod" == common ]; then
        rem_v=$(printf '%s\n' "$payload" | sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' | head -n1)
    else
        rem_v=$(printf '%s\n' "$payload" | sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' | head -n1)
    fi
    if [ -n "$rem_v" ] && mt_update_available "$rem_v" "$cur_v"; then
        echo "${mod}:${cur_v}:${rem_v}" > "$out_file"
    fi
}
check_all_updates_round() {
    local pids=() mod p f
    for mod in "${UPDATE_COMPONENTS[@]}"; do
        check_single_module_silent "$mod" &
        pids+=("$!")
    done
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null; done
    : > "$UPDATE_FILE.new"
    for mod in "${UPDATE_COMPONENTS[@]}"; do
        f="$SECURE_TMP/.chk_${mod}"
        [ -s "$f" ] && cat "$f" >> "$UPDATE_FILE.new"
        rm -f "$f"
    done
    mv -f "$UPDATE_FILE.new" "$UPDATE_FILE" 2>/dev/null
    kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
}
update_watcher_loop() {
    while true; do
        check_all_updates_round
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
if [[ "${1:-}" != --* ]]; then update_watcher_loop & fi
WATCHER_PID=$!
format_bytes_speed() {
    local b=$1
    if [ -z "$b" ] || [ "$b" -le 0 ] 2>/dev/null; then echo "0 B/s"; return; fi
    if [ "$b" -lt 1024 ]; then 
        echo "${b} B/s"
    elif [ "$b" -lt 1048576 ]; then 
        local kb=$(( b / 1024 ))
        if [ "$kb" -lt 100 ]; then awk -v v="$b" 'BEGIN {printf "%.1f KB/s", v/1024}'
        else echo "${kb} KB/s"; fi
    elif [ "$b" -lt 1073741824 ]; then 
        local mb=$(( b / 1048576 ))
        if [ "$mb" -lt 100 ]; then awk -v v="$b" 'BEGIN {printf "%.1f MB/s", v/1048576}'
        else echo "${mb} MB/s"; fi
    else 
        awk -v v="$b" 'BEGIN {printf "%.1f GB/s", v/1073741824}'
    fi
}
collect_system_vitals() {
    local sys_target="$SECURE_TMP/.main_sys_stats.tmp"
    
    local cpu_cores=$(nproc 2>/dev/null)
    [ -z "$cpu_cores" ] && cpu_cores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
    [ -z "$cpu_cores" ] && cpu_cores=1
    local cpu_pct=0
    if [ -f "$SECURE_TMP/.cpu_last" ]; then
        read p_idle p_total < "$SECURE_TMP/.cpu_last"
        read _ u n s i io ir st _ < <(grep '^cpu ' /proc/stat 2>/dev/null)
        local cur_idle=$(( i + io ))
        local cur_total=$(( u + n + s + i + io + ir + st ))
        local d_idle=$(( cur_idle - p_idle ))
        local d_total=$(( cur_total - p_total ))
        if [ "$d_total" -gt 0 ]; then
            cpu_pct=$(( (d_total - d_idle) * 100 / d_total ))
            [ "$cpu_pct" -lt 0 ] && cpu_pct=0
            [ "$cpu_pct" -gt 100 ] && cpu_pct=100
        fi
        echo "$cur_idle $cur_total" > "$SECURE_TMP/.cpu_last"
    else
        read _ u n s i io ir st _ < <(grep '^cpu ' /proc/stat 2>/dev/null)
        echo "$(( i + io )) $(( u + n + s + i + io + ir + st ))" > "$SECURE_TMP/.cpu_last"
        cpu_pct=5
    fi
    local r_used="0G" r_total="0G" r_pct=0
    if [ -f /proc/meminfo ]; then
        local mt=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
        local ma=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)
        [ -z "$ma" ] && ma=$(awk '/MemFree/ {print $2}' /proc/meminfo 2>/dev/null)
        if [ -n "$mt" ] && [ "$mt" -gt 0 ] 2>/dev/null; then
            local mu=$(( mt - ma ))
            r_pct=$(( mu * 100 / mt ))
            r_used=$(awk -v v="$mu" 'BEGIN {if(v<1048576) printf "%.0fM", v/1024; else printf "%.1fG", v/1048576}')
            r_total=$(awk -v v="$mt" 'BEGIN {printf "%.1fG", v/1048576}')
        fi
    fi
    local def_dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
    [ -z "$def_dev" ] && def_dev=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n 1)
    
    local rx_speed="0 B/s" tx_speed="0 B/s"
    local now_ts=$(date +%s)
    if [ -n "$def_dev" ] && [ -f "/sys/class/net/$def_dev/statistics/rx_bytes" ]; then
        local cur_rx=$(cat "/sys/class/net/$def_dev/statistics/rx_bytes" 2>/dev/null)
        local cur_tx=$(cat "/sys/class/net/$def_dev/statistics/tx_bytes" 2>/dev/null)
        if [ -f "$SECURE_TMP/.net_last" ]; then
            read p_ts p_rx p_tx < "$SECURE_TMP/.net_last"
            local dt=$(( now_ts - p_ts ))
            if [ "$dt" -gt 0 ]; then
                local drx=$(( (cur_rx - p_rx) / dt ))
                local dtx=$(( (cur_tx - p_tx) / dt ))
                [ "$drx" -lt 0 ] && drx=0
                [ "$dtx" -lt 0 ] && dtx=0
                rx_speed=$(format_bytes_speed "$drx")
                tx_speed=$(format_bytes_speed "$dtx")
            fi
        fi
        echo "$now_ts $cur_rx $cur_tx" > "$SECURE_TMP/.net_last"
    fi
    local v6_status="OFF"
    if ip -6 route show default 2>/dev/null | grep -q default || ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
        v6_status="ON"
    fi
    echo "${cpu_pct}|${cpu_cores}|${r_used}|${r_total}|${r_pct}|${rx_speed}|${tx_speed}|${v6_status}" > "$sys_target"
    mv -f "$sys_target" "$SECURE_TMP/.main_sys_stats" 2>/dev/null
}

mt_endpoint_host() {
    local ep="$1" host
    [ -n "$ep" ] || return 1
    if [[ "$ep" == \[*\]:* ]]; then
        host="${ep#\[}"; host="${host%\]:*}"
    else
        host="${ep%:*}"
    fi
    host="${host#::ffff:}"
    printf '%s' "$host"
}

# Resolve the TCP peer for exactly one systemd instance. PID scoping keeps
# same-engine tunnels from borrowing each other's live socket.
mt_unit_peer_ip() {
    local unit="$1" local_port="${2:-}" pid line lep pep p
    pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null | tr -dc '0-9')
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == *"pid=$pid,"* || "$line" == *"pid=$pid)"* ]] || continue
        lep=$(awk '{print $3}' <<< "$line"); pep=$(awk '{print $4}' <<< "$line")
        [ -n "$pep" ] || continue
        if [ -n "$local_port" ] && [[ "$local_port" =~ ^[0-9]+$ ]]; then
            p="${lep##*:}"; [ "$p" = "$local_port" ] || continue
        fi
        mt_endpoint_host "$pep"; return 0
    done < <(ss -Htnp state established 2>/dev/null)
    return 1
}

# Exact-instance TCP RTT fallback for hosts that block ICMP. Loss is left
# unknown in that case rather than incorrectly showing 100%.
mt_unit_tcp_rtt() {
    local unit="$1" target="$2" pid line rtt hit=0
    pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null | tr -dc '0-9')
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS= read -r line; do
        if [[ "$line" == *"pid=$pid,"* || "$line" == *"pid=$pid)"* ]]; then
            if [[ "$line" == *"$target"* ]]; then
                if [[ "$line" =~ rtt:([0-9.]+) ]]; then rtt="${BASH_REMATCH[1]}"; break; fi
                hit=1; continue
            fi
            hit=0
        elif [ "$hit" = 1 ]; then
            if [[ "$line" =~ rtt:([0-9.]+) ]]; then rtt="${BASH_REMATCH[1]}"; break; fi
            [[ "$line" =~ ^[[:space:]] ]] || hit=0
        fi
    done < <(ss -Htinp 2>/dev/null)
    [ -n "$rtt" ] || return 1
    awk -v v="$rtt" 'BEGIN {printf "%.0fms*", v}'
}

mt_ping_stats() {
    local target="$1" iface="${2:-}" unit="${3:-}" ping_res loss avg='---' tcp_rtt
    local -a cmd=(ping)
    mt_valid_host "$target" || { printf '%s|%s' '---' '---'; return 1; }
    [[ "$target" == *:* ]] && cmd=(ping -6)
    if [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1; then cmd+=(-I "$iface"); fi
    ping_res=$(timeout 3 "${cmd[@]}" -c 2 -i 0.2 -W 1 "$target" 2>/dev/null || true)
    loss=$(printf '%s\n' "$ping_res" | grep -oP '[0-9]+(?=% packet loss)' | head -n1)
    [ -n "$loss" ] || loss=100
    if printf '%s\n' "$ping_res" | grep -q 'min/avg/max'; then
        avg=$(printf '%s\n' "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2 | head -n1)
        [ -n "$avg" ] && avg="$(awk -v v="$avg" 'BEGIN {printf "%.0fms", v}')"
    elif [ -n "$unit" ]; then
        tcp_rtt=$(mt_unit_tcp_rtt "$unit" "$target" 2>/dev/null || true)
        if [ -n "$tcp_rtt" ]; then avg="$tcp_rtt"; loss='---'; fi
    fi
    printf '%s|%s' "$avg" "$loss"
}

collect_active_tunnels_stats() {
    local tmp_target
    tmp_target=$(mktemp "$SECURE_TMP/.main_tun_stats.XXXXXX") || return 1
    local count=0
    # 1. GRE
    for conf in /etc/mgre/tunnels/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; REMOTE_PUB=""; LOCAL_PUB=""; CORE_SUBNET=""; CORE_V6=""; TUN_ID=""; VNI_ID=""; TUN_PROTO="ipv4"; FAB_PROTO="ipv4"; LOCAL_PUB6=""; REMOTE_PUB6=""; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        
        ip link show "$T_NAME" >/dev/null 2>&1 || continue
        [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" == "down" ] && continue
        local pure="${T_NAME#gre6ir}"; pure="${pure#gre6kh}"; pure="${pure#greir}"; pure="${pure#grekh}"
        local c_sub="${CORE_SUBNET}"
        mt_tunnel_addresses || continue
        local peer_vip="$MT_CORE_PEER"; REMOTE_PUB="$MT_REMOTE_PUBLIC"
        
        local vip_stat="OFF"
        [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null && vip_stat="+${MAX_IPS}"
        local avg="---" loss="---"
        IFS='|' read -r avg loss <<< "$(mt_ping_stats "$peer_vip" "$T_NAME")"
        local fwd_str="OFF"
        if [ "$TYPE" == "1" ]; then
            if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
            elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:4}"
            elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:4}"
            fi
        else fwd_str="GW"; fi
        echo "GRE|${pure:-$T_NAME}|${REMOTE_PUB}|${vip_stat}|${avg}|${loss}|${T_NAME}|${fwd_str}" >> "$tmp_target"
        ((count++))
        [ "$count" -ge 3 ] && break 2
    done
    # 2. VXLAN
    if [ "$count" -lt 3 ]; then
        for conf in /etc/mgre/vxlan/*.conf; do
            [ -f "$conf" ] || continue
                TYPE=""; VX_NAME=""; BR_NAME=""; TUN_PROTO="ipv4"; CORE_V6=""; LOCAL_PUB=""; LOCAL_PUB6=""; REMOTE_PUB6=""; FAB_PROTO="ipv4"; REMOTE_PUB=""; CORE_SUBNET=""; TUN_ID=""; VNI_ID=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; source "$conf" 2>/dev/null
            [ -z "$VX_NAME" ] && continue
            ip link show "$VX_NAME" >/dev/null 2>&1 || continue
            [ "$(cat /sys/class/net/$VX_NAME/operstate 2>/dev/null)" == "down" ] && continue
            local pure="${VX_NAME#vx_}"
            local c_sub="${CORE_SUBNET:-$(mt_legacy_core_subnet "$VNI_ID" vxlan)}"
            mt_tunnel_addresses || continue
            local peer_vip="$MT_CORE_PEER"; REMOTE_PUB="$MT_REMOTE_PUBLIC"
            local vip_stat="OFF"
            [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null && vip_stat="+${MAX_IPS}"
            local avg="---" loss="---"
            IFS='|' read -r avg loss <<< "$(mt_ping_stats "$peer_vip" "$BR_NAME")"
            local fwd_str="OFF"
            if [ "$TYPE" == "1" ]; then
                if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
                elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:4}"
                elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:4}"
                fi
            else fwd_str="GW"; fi
            echo "VXLAN|${pure:-$VX_NAME}|${REMOTE_PUB}|${vip_stat}|${avg}|${loss}|${VX_NAME}|${fwd_str}" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi
    # 3. Backhaul
    if [ "$count" -lt 3 ]; then
        for conf in /etc/mbackhaul/tunnels/*.meta; do
            [ -f "$conf" ] || continue
            local t_name=$(basename "$conf" .meta)
            ROLE=$(mt_read_kv "$conf" ROLE) || continue
            TUN_PORT=$(mt_read_kv "$conf" TUN_PORT) || continue
            REMOTE_IP=$(mt_read_kv "$conf" REMOTE_IP 2>/dev/null || true)
            PORTS=$(mt_read_kv "$conf" PORTS 2>/dev/null || true)
            TRANSPORT=$(mt_read_kv "$conf" TRANSPORT 2>/dev/null || true); [ -n "$TRANSPORT" ] || TRANSPORT=tcp
            [[ "$ROLE" =~ ^[12]$ && "$TRANSPORT" =~ ^(tcp|tcpmux|ws|wss|wsmux|wssmux|udp)$ ]] && mt_valid_port "$TUN_PORT" || continue
            systemctl is-active --quiet "mbackhaul@${t_name}" || continue
            local pure="${t_name#bh_}"
            local peer_ip="$REMOTE_IP"
            if [ "$ROLE" == "1" ]; then
                if [ "$TRANSPORT" = udp ]; then
                    peer_ip="UDP Listening"
                else
                    peer_ip=$(mt_unit_peer_ip "mbackhaul@${t_name}" "$TUN_PORT" 2>/dev/null || true)
                    [ -z "$peer_ip" ] && peer_ip="Listening"
                fi
            fi
            local avg="---" loss="---"
            if mt_valid_host "$peer_ip" 2>/dev/null; then
                IFS='|' read -r avg loss <<< "$(mt_ping_stats "$peer_ip" "" "mbackhaul@${t_name}")"
            fi
            local fwd_str="OFF"
            [ -n "$PORTS" ] && fwd_str="ACT"
            [ "$ROLE" == "2" ] && fwd_str="CLI"
            echo "BH|${pure:-$t_name}|${peer_ip}|OFF|${avg}|${loss}|bh_${t_name}|${fwd_str}" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi
    # 4. Rathole
    if [ "$count" -lt 3 ]; then
        for d in /etc/mrathole/tunnels/*; do
            [ -d "$d" ] && [ -f "$d/meta.conf" ] || continue
            local t_name=$(basename "$d")
            TYPE=$(mt_read_kv "$d/meta.conf" TYPE) || continue
            LINK_PORT=$(mt_read_kv "$d/meta.conf" LINK_PORT) || continue
            REMOTE_IP=$(mt_read_kv "$d/meta.conf" REMOTE_IP 2>/dev/null || true)
            TCP_PORTS=$(mt_read_kv "$d/meta.conf" TCP_PORTS 2>/dev/null || true)
            UDP_PORTS=$(mt_read_kv "$d/meta.conf" UDP_PORTS 2>/dev/null || true)
            [[ "$TYPE" =~ ^[12]$ ]] && mt_valid_port "$LINK_PORT" || continue
            systemctl is-active --quiet "mrathole@${t_name}" || continue
            local peer_ip="$REMOTE_IP"
            if [ "$TYPE" == "1" ]; then
                peer_ip=$(mt_unit_peer_ip "mrathole@${t_name}" "$LINK_PORT" 2>/dev/null || true)
                [ -z "$peer_ip" ] && peer_ip="Listening"
            fi
            local avg="---" loss="---"
            if mt_valid_host "$peer_ip" 2>/dev/null; then
                IFS='|' read -r avg loss <<< "$(mt_ping_stats "$peer_ip" "" "mrathole@${t_name}")"
            fi
            local fwd_str="OFF"
            [ -n "$TCP_PORTS" ] || [ -n "$UDP_PORTS" ] && fwd_str="ACT"
            [ "$TYPE" == "2" ] && fwd_str="CLI"
            echo "RAT|${t_name}|${peer_ip}|OFF|${avg}|${loss}|rat_${t_name}|${fwd_str}" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi
    # 5. Paqet
    if [ "$count" -lt 3 ]; then
        for conf in /etc/paqet/*.meta; do
            [ -f "$conf" ] || continue
            local t_name=$(basename "$conf" .meta)
            ROLE=$(mt_read_kv "$conf" ROLE) || continue
            TUN_PORT=$(mt_read_kv "$conf" TUN_PORT) || continue
            REMOTE_IP=$(mt_read_kv "$conf" REMOTE_IP 2>/dev/null || true)
            [[ "$ROLE" =~ ^[12]$ ]] && mt_valid_port "$TUN_PORT" || continue
            systemctl is-active --quiet "mpaqet@${t_name}" || continue
            local pure="${t_name#pq_}"
            local peer_ip="$REMOTE_IP"
            if [ "$ROLE" == "1" ]; then
                local recent="/proc/net/xt_recent/mpq_${t_name}" cache="/root/mtunnel/tmp/.mpaqet_peer_${t_name}"
                if [ -r "$recent" ]; then
                    peer_ip=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^src=/){print substr($i,5); exit}}' "$recent" 2>/dev/null)
                fi
                [ -n "$peer_ip" ] || peer_ip=$(cat "$cache" 2>/dev/null)
                [ -n "$peer_ip" ] || peer_ip="Listening"
            fi
            local avg="---" loss="---"
            if mt_valid_host "$peer_ip" 2>/dev/null; then
                IFS='|' read -r avg loss <<< "$(mt_ping_stats "$peer_ip" "" "mpaqet@${t_name}")"
            fi
            echo "PAQET|${pure:-$t_name}|${peer_ip}|OFF|${avg}|${loss}|pq_${t_name}|RAW" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi
    mv -f "$tmp_target" "$SECURE_TMP/.main_tun_stats" 2>/dev/null
}
stats_watcher_loop() {
    while true; do
        collect_system_vitals
        collect_active_tunnels_stats
        kill -SIGUSR2 "$MAIN_PID" 2>/dev/null
        sleep "$STATS_CHECK_INTERVAL"
    done
}
stats_watcher_loop &
STATS_PID=$!
trap 'kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null' EXIT
get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}
get_local_ipv6() {
    local v6
    v6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ && !/deprecated/ {sub(/\/.*/,"",$2); print $2; exit}')
    echo "${v6:-}"
}
get_iface_uptime_pure() {
    local dev="$1"
    if [[ "$dev" == bh_* || "$dev" == rat_* || "$dev" == pq_* ]]; then
        local srv_name="mbackhaul@${dev#bh_}"
        [[ "$dev" == rat_* ]] && srv_name="mrathole@${dev#rat_}"
        [[ "$dev" == pq_* ]] && srv_name="mpaqet@${dev#pq_}"
        local started=$(systemctl show "$srv_name" --property=ActiveEnterTimestampMonotonic 2>/dev/null | cut -d= -f2)
        if [ -n "$started" ] && [ "$started" -gt 0 ]; then
            local now=$(cut -d' ' -f1 /proc/uptime | tr -d '.')
            local sec=$(( (now * 10000 - started) / 1000000 ))
            [ "$sec" -lt 0 ] && sec=0
            local d=$(( sec / 86400 )); local h=$(( (sec % 86400) / 3600 )); local m=$(( (sec % 3600) / 60 ))
            if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
            elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
            else printf "%dm" "$m"; fi
            return
        fi
        echo "ACTIVE"
        return
    fi
    if [ ! -d "/sys/class/net/$dev" ] || [ "$(cat /sys/class/net/$dev/operstate 2>/dev/null)" == "down" ]; then
        echo "DOWN"
        return
    fi
    local sys_uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    local if_sec=$(ip -s -d link show "$dev" 2>/dev/null | grep -oP 'trans_start \K[0-9]+')
    local delta=0
    if [ -n "$if_sec" ] && [ "$if_sec" -gt 0 ]; then
        delta=$(( (sys_uptime * 100 - if_sec) / 100 ))
        [ "$delta" -lt 0 ] && delta=0
    else
        local created=$(stat -c %Y "/sys/class/net/$dev" 2>/dev/null)
        local now=$(date +%s)
        delta=$(( now - created ))
        [ "$delta" -lt 0 ] && delta=0
    fi
    local d=$(( delta / 86400 )); local h=$(( (delta % 86400) / 3600 )); local m=$(( (delta % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
    else printf "%dm" "$m"; fi
}
is_iperf3_valid() {
    command -v iperf3 >/dev/null 2>&1 && iperf3 -v >/dev/null 2>&1
}
is_package_or_bin_installed() {
    local item="$1"
    if [ "$item" == "bh" ]; then
        command -v bh >/dev/null 2>&1 || [ -x /usr/local/bin/bh ]
    elif [ "$item" == "rathole" ]; then
        command -v rathole >/dev/null 2>&1 || [ -x /usr/local/bin/rathole ]
    elif [ "$item" == "paqet" ]; then
        command -v paqet >/dev/null 2>&1 || [ -x /usr/local/bin/paqet ]
    elif [ "$item" == "gost" ]; then
        command -v gost >/dev/null 2>&1 || [ -x /usr/local/bin/gost ]
    elif [ "$item" == "haproxy" ]; then
        command -v haproxy >/dev/null 2>&1 || [ -x /usr/sbin/haproxy ]
    elif [[ "$item" == *.deb ]]; then
        local pkg_name=$(echo "$item" | cut -d'_' -f1)
        if [ "$pkg_name" == "iperf3" ]; then
            is_iperf3_valid
        elif [ "$pkg_name" == "libiperf0" ]; then
            dpkg -s libiperf0 2>/dev/null | grep -q "Status: install ok installed" || ldconfig -p 2>/dev/null | grep -q "libiperf\.so\.0"
        else
            command -v "$pkg_name" >/dev/null 2>&1 || dpkg -s "$pkg_name" 2>/dev/null | grep -q "Status: install ok installed"
        fi
    else
        command -v "$item" >/dev/null 2>&1
    fi
}
# Terminal-frame helpers: strip SGR sequences only for measuring visible columns.
# C.UTF-8 ensures box glyphs and status symbols count as characters, not bytes.
mt_main_visible_text() {
    local rendered
    rendered=$(printf '%b' "$1")
    printf '%s' "$rendered" | sed -E $'s/\033\\[[0-9;]*m//g'
}
mt_main_frame_row() {
    local raw="$1" width="$2" frame_color="${3:-$B}"
    local rendered plain padding
    local LC_CTYPE=C.UTF-8
    rendered=$(printf '%b' "$raw")
    plain=$(mt_main_visible_text "$rendered")
    if (( ${#plain} > width )); then
        rendered="${plain:0:width}"   # safe overflow fallback, do not split ANSI codes
        plain="$rendered"
    fi
    padding=$((width-${#plain}))
    printf '  %b│%b%s%*s%b│%b\033[K\n' "$frame_color" "$NC" "$rendered" "$padding" '' "$frame_color" "$NC"
}
mt_main_header_cell() {
    local width="$1" raw="$2" rendered plain padding
    local LC_CTYPE=C.UTF-8
    rendered=$(printf '%b' "$raw")
    plain=$(mt_main_visible_text "$rendered")
    if (( ${#plain} > width-2 )); then
        rendered="${plain:0:width-2}"
        plain="$rendered"
    fi
    padding=$((width-2-${#plain}))
    printf ' %s%*s ' "$rendered" "$padding" ''
}
mt_main_header_row4() {
    # Dynamic wide header. Base width 120, extra terminal width is given to title/local area.
    local total="${MT_MAIN_HEADER_WIDTH:-120}" extra join
    (( total < 120 )) && total=120
    extra=$((total-120))
    join=$(printf '%b' " ${B}│${NC} ")
    mt_main_frame_row "$(mt_main_header_cell $((33+extra)) "$1")${join}$(mt_main_header_cell 23 "$2")${join}$(mt_main_header_cell 29 "$3")${join}$(mt_main_header_cell 26 "$4")" "$total"
}
mt_main_header_row7() {
    # Keep the tunnel identity readable while still reserving a wide Peer cell.
    # Base: 22+31+9+10+9+11+10 + 6 x ' │ ' = 120.
    # Extra terminal width is donated to Peer so long/compressed IPv6 peers fit.
    local total="${MT_MAIN_HEADER_WIDTH:-120}" extra join
    (( total < 120 )) && total=120
    extra=$((total-120))
    join=$(printf '%b' " ${B}│${NC} ")
    mt_main_frame_row "$(mt_main_header_cell 22 "$1")${join}$(mt_main_header_cell $((31+extra)) "$2")${join}$(mt_main_header_cell 9 "$3")${join}$(mt_main_header_cell 10 "$4")${join}$(mt_main_header_cell 9 "$5")${join}$(mt_main_header_cell 11 "$6")${join}$(mt_main_header_cell 10 "$7")" "$total"
}
mt_main_menu_separator() {
    local w="$1" title="${2:-}" border=''
    printf -v border '%*s' "$w" ''
    border="${border// /─}"
    if [[ -n $title ]]; then
        local prefix="─[ $title ]" title_len
        local LC_CTYPE=C.UTF-8
        title_len=${#prefix}
        if (( title_len < w )); then
            border="${prefix}${border:0:w-title_len}"
        fi
    fi
    printf '  %b├%s┤%b\033[K\n' "$DIM" "$border" "$NC"
}
mt_main_menu_option() {
    local w="$1" number="$2" color="$3" label="$4" module="${5:-}" badge=''
    [[ -z "$module" ]] || badge=$(module_update_badge "$module")
    mt_main_frame_row "  ${W}$(printf '%-2s' "$number")${NC} ${DIM}❯${NC} ${color}${label}${NC}${badge}" "$w" "$DIM"
}

draw_header_lines_only() {
    local s_ip=$(get_local_ip)
    s_ip="${s_ip:0:16}"

    local bbr_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')

    local porter_col="${DIM}" porter_icon="○" porter_text="OFF"
    if systemctl is-active --quiet mporter.service 2>/dev/null || \
       systemctl is-active --quiet haproxy 2>/dev/null || \
       systemctl is-active --quiet gost 2>/dev/null || \
       systemctl is-active --quiet mporter-iptables 2>/dev/null; then
        porter_col="${G}"; porter_icon="●"; porter_text="ON"
    fi

    local bbr_col="${DIM}" bbr_icon="○" bbr_text="OFF"
    [ "$bbr_cc" == "bbr" ] && { bbr_col="${G}"; bbr_icon="●"; bbr_text="ON"; }

    local cpu_pct=0 cpu_cores=1 r_used="0G" r_total="0G" r_pct=0 rx_speed="0 B/s" tx_speed="0 B/s" v6_status="OFF"
    if [ -f "$SECURE_TMP/.main_sys_stats" ]; then
        IFS='|' read -r cpu_pct cpu_cores r_used r_total r_pct rx_speed tx_speed v6_status < "$SECURE_TMP/.main_sys_stats"
    fi

    local cpu_col="${G}"
    [ "$cpu_pct" -gt 60 ] 2>/dev/null && cpu_col="${Y}"
    [ "$cpu_pct" -gt 85 ] 2>/dev/null && cpu_col="${R}"
    local cpu_str="${cpu_pct}%"

    local core_label="${cpu_cores} Cores"
    [ "$cpu_cores" -eq 1 ] 2>/dev/null && core_label="1 Core"

    local ram_col="${G}"
    [ "$r_pct" -gt 70 ] 2>/dev/null && ram_col="${Y}"
    [ "$r_pct" -gt 88 ] 2>/dev/null && ram_col="${R}"
    local ram_str="${r_used}/${r_total} [${r_pct}%]"

    local rx_col="${DIM}"
    [[ "$rx_speed" != "0 B/s" && -n "$rx_speed" ]] && rx_col="${G}"

    local tx_col="${DIM}"
    [[ "$tx_speed" != "0 B/s" && -n "$tx_speed" ]] && tx_col="${Y}"

    local v6_col="${DIM}" v6_icon="○" v6_text="OFF"
    if [ "$v6_status" == "ON" ]; then
        v6_col="${G}"; v6_icon="●"; v6_text="ON"
    fi

    local term_cols boxw content_w compact_line border
    term_cols=$(tput cols 2>/dev/null || echo "${COLUMNS:-120}")
    if [ "$term_cols" -lt 72 ]; then
        local tun_count=0
        boxw=$((term_cols - 4)); [ "$boxw" -lt 32 ] && boxw=32; [ "$boxw" -gt 66 ] && boxw=66
        content_w=$((boxw - 2))
        printf -v border '%*s' "$content_w" ''; border="${border// /─}"
        [ -f "$SECURE_TMP/.main_tun_stats" ] && tun_count=$(awk -F'|' 'NF>2{n++} END{print n+0}' "$SECURE_TMP/.main_tun_stats" 2>/dev/null)
        printf "\033[K\n  ${B}╭${border}╮${NC}\033[K\n"
        compact_line="MDesign v${MODULE_VERSION} | ${s_ip}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        compact_line="CPU ${cpu_str} | RAM ${ram_str} | BBR ${bbr_text} | IPv6 ${v6_text}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        compact_line="Tunnels ${tun_count} | Porter ${porter_text}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        printf "  ${B}╰${border}╯${NC}\033[K\n"
        return 0
    fi
    if [ "$term_cols" -lt 124 ]; then
        boxw=$((term_cols - 4)); [ "$boxw" -lt 32 ] && boxw=32; [ "$boxw" -gt 78 ] && boxw=78
        content_w=$((boxw - 2))
        printf -v border '%*s' "$content_w" ''; border="${border// /─}"
        printf "\033[K\n  ${B}╭${border}╮${NC}\033[K\n"
        compact_line="MDesign v${MODULE_VERSION} | Local: ${s_ip}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        compact_line="CPU ${cpu_str} | RAM ${ram_str} | BBR ${bbr_text} | IPv6 ${v6_text}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        compact_line="Porter ${porter_text} | RX ${rx_speed} | TX ${tx_speed}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        printf "  ${B}├${border}┤${NC}\033[K\n"
        local cshown=0
        if [ -f "$SECURE_TMP/.main_tun_stats" ]; then
            while IFS='|' read -r t_proto t_name t_remote t_vip t_ping t_loss t_dev t_fwd; do
                [ -n "$t_proto" ] || continue; ((cshown++)); [ "$cshown" -gt 3 ] && break
                local compact_loss="${t_loss:----}"; [[ "$t_loss" =~ ^[0-9]+$ ]] && compact_loss="${t_loss}%"
                compact_line="${t_name} [${t_proto}] | ${t_remote} | Ping ${t_ping:-} | Loss ${compact_loss}"
                printf "  ${B}│${NC} %-*.*s ${B}│${NC}[K
" "$((content_w-2))" "$((content_w-2))" "$compact_line"
            done < "$SECURE_TMP/.main_tun_stats"
        fi
        if [ "$cshown" -eq 0 ]; then
            compact_line='No active tunnels configured.'
            printf "  ${B}│${NC} %-*.*s ${B}│${NC}[K
" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        fi
        printf "  ${B}╰${border}╯${NC}[K
"
        return 0
    fi

    # Wide dashboard: base width 117 (original main layout). Any extra terminal width
    # (up to 150 columns total) is donated to the Peer cell and the last cells of rows 1-2.
    local total=$((term_cols - 4)) extra peer_w v6_addr
    (( total < 117 )) && total=117
    (( total > 150 )) && total=150
    extra=$((total - 117)); peer_w=$((16 + extra))
    v6_addr=$(get_local_ipv6)
    if [ -n "$v6_addr" ]; then v6_col="${M}"; v6_icon="●"; v6_text="$v6_addr"
    else v6_col="${DIM}"; v6_icon="○"; v6_text="OFF"; fi
    printf -v border '%*s' "$total" ''
    border="${border// /─}"

    printf '\033[K\n  %b╭%s╮%b\033[K\n' "$B" "$border" "$NC"
    # Row 1: 31 | 25 | 21 | 37(+extra) = 117(+extra) columns (Web cell removed)
    printf "  ${B}│${NC} ${W}%-29.29s${NC} ${B}│${NC} ${C}◆${NC} ${DIM}IPv4${NC}  ${M}%-15.15s${NC} ${B}│${NC} ${DIM}Porter:${NC} %b%s%b %-9.9s ${B}│${NC} ${DIM}BBR:${NC} %b%s%b %-3.3s ${M}◆${NC} ${DIM}IPv6${NC}  %b%-*.*s%b ${B}│${NC}\033[K\n" \
        "MDesign Master Core v${MODULE_VERSION}" "$s_ip" \
        "$porter_col" "$porter_icon" "$NC" "$porter_text" \
        "$bbr_col" "$bbr_icon" "$NC" "$bbr_text" \
        "$v6_col" "$((16+extra))" "$((16+extra))" "$v6_text" "$NC"
    printf "  ${B}├${border}┤${NC}\033[K\n"
    # Row 2: 31 | 25 | 21 | 37(+extra)
    printf "  ${B}│${NC} ${DIM}CPU:${NC} %b%-4.4s%b   ${DIM}Cores:${NC} ${W}%-10.10s${NC} ${B}│${NC} ${DIM}RAM:${NC} %b%-18.18s%b ${B}│${NC} ${DIM}Net ▼:${NC} %b%-12.12s%b ${B}│${NC} ${DIM}Net ▲:${NC} %b%-*.*s%b ${B}│${NC}\033[K\n" \
        "$cpu_col" "$cpu_str" "$NC" "$core_label" \
        "$ram_col" "$ram_str" "$NC" \
        "$rx_col" "$rx_speed" "$NC" \
        "$tx_col" "$((28+extra))" "$((28+extra))" "$tx_speed" "$NC"
    printf "  ${B}├${border}┤${NC}\033[K\n"

    local shown=0
    if [ -f "$SECURE_TMP/.main_tun_stats" ]; then
        while IFS='|' read -r t_proto t_name t_remote t_vip t_ping t_loss t_dev t_fwd; do
            [ -z "$t_proto" ] && continue
            ((shown++))
            [ "$shown" -gt 3 ] && break

            local pure_name=$(echo "$t_name" | tr -d ' ')
            [ ${#pure_name} -gt 8 ] && pure_name="${pure_name:0:8}"
            local name_tag="${pure_name} [${t_proto}]"
            [ ${#name_tag} -gt 17 ] && name_tag="${name_tag:0:17}"

            [ ${#t_remote} -gt "$peer_w" ] && t_remote="${t_remote:0:$peer_w}"

            local if_uptime=$(get_iface_uptime_pure "$t_dev")
            local stat_icon="●"; local stat_col="${G}"
            if [ "$if_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi
            [ ${#if_uptime} -gt 10 ] && if_uptime="${if_uptime:0:10}"

            local fwd_col="${DIM}"; [ "$t_fwd" != "OFF" ] && fwd_col="${C}"
            local fwd_str="${t_fwd:0:9}"

            local vip_col="${DIM}"; [ "$t_vip" != "OFF" ] && vip_col="${G}"
            local vip_stat="${t_vip:0:5}"

            local live_ping="---"
            if [ -n "$t_ping" ] && [ "$t_ping" != "---" ]; then
                local num_p="${t_ping%ms}"
                if [[ "$num_p" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    live_ping=$(awk -v v="$num_p" 'BEGIN {printf "%.0fms", v}')
                else
                    live_ping="$t_ping"
                fi
            fi
            [ ${#live_ping} -gt 5 ] && live_ping="${live_ping:0:5}"

            local loss_col="${DIM}"; local loss_disp="---"
            if [ "$t_loss" != "---" ] && [ -n "$t_loss" ]; then
                loss_disp="${t_loss}%"
                if [ "$t_loss" -eq 0 ] 2>/dev/null; then loss_col="${G}"
                elif [ "$t_loss" -lt 30 ] 2>/dev/null; then loss_col="${Y}"
                else loss_col="${R}"; fi
            fi
            [ ${#loss_disp} -gt 4 ] && loss_disp="${loss_disp:0:4}"

            printf "  ${B}│${NC} %b%s%b ${W}%-17.17s${NC} ${B}│${NC} ${DIM}Peer:${NC} ${Y}%-*.*s${NC} ${B}│${NC} ${DIM}vIP:${NC}%b%-5.5s%b ${B}│${NC} ${DIM}Ping:${NC}${Y}%-5.5s${NC} ${B}│${NC} ${DIM}Loss:${NC}%b%-4.4s%b ${B}│${NC} ${DIM}Up:${NC} ${W}%-10.10s${NC} ${B}│${NC} ${DIM}FWD:${NC} %b%-9.9s%b ${B}│${NC}\033[K\n" \
                "$stat_col" "$stat_icon" "$NC" "$name_tag" "$peer_w" "$peer_w" "$t_remote" "$vip_col" "$vip_stat" "$NC" "$live_ping" "$loss_col" "$loss_disp" "$NC" "$if_uptime" "$fwd_col" "$fwd_str" "$NC"
        done < "$SECURE_TMP/.main_tun_stats"
    fi

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}● %-*.*s${NC}  ${B}│${NC}\033[K\n" "$((111+extra))" "$((111+extra))" "No active tunnels or fabrics deployed across the ecosystem."
    fi
    printf "  ${B}╰${border}╯${NC}\033[K\n"
}

draw_main_header() {
    clear
    draw_header_lines_only
}

refresh_header_live() {
    tput civis 2>/dev/null || true
    printf "\033[s"      # Save cursor position (ANSI)
    printf "\0337"       # Save cursor position (DEC)
    printf "\033[1;1H"   # Row 1, Col 1
    draw_header_lines_only
    printf "\0338"       # Restore cursor position (DEC)
    printf "\033[u"      # Restore cursor position (ANSI)
    tput cnorm 2>/dev/null || true
}
read_with_refresh() {
    local prompt="$1"
    local __resultvar="$2"
    local redraw_func="$3"
    local buffer=""
    local char rc
    echo -ne "$prompt"
    while true; do
        if [ "$NEED_REFRESH" = true ]; then
            NEED_REFRESH=false
            if [ -n "$redraw_func" ]; then
                "$redraw_func"
            fi
            echo -ne "$prompt$buffer"
        fi
        if [ "$NEED_LIVE_HEADER_REFRESH" = true ]; then
            NEED_LIVE_HEADER_REFRESH=false
            refresh_header_live
        fi
        IFS= read -rsn1 -t 0.3 char
        rc=$?
        if [ $rc -ne 0 ]; then
            { [ "$rc" -eq 142 ] || [ "$rc" -gt 128 ]; } && continue
            return "$rc"
        fi
        if [[ -z "$char" ]]; then
            echo ""
            break
        fi
        if [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
            if [ -n "$buffer" ]; then
                buffer="${buffer%?}"
                echo -ne "\b \b"
            fi
            continue
        fi
        buffer+="$char"
        echo -ne "$char"
    done
    printf -v "$__resultvar" '%s' "$buffer"
}
draw_progress_bar() {
    local pid=$1 text=$2 width=30 progress=0 filled empty bar rest
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        ((progress++))
        [ "$progress" -gt 95 ] && progress=95
        filled=$(( progress * width / 100 ))
        empty=$(( width - filled ))
        bar="$(printf '%*s' "$filled" '' | tr ' ' '#')"
        rest="$(printf '%*s' "$empty" '' | tr ' ' '-')"
        printf "\r  %b→%b %-26s %b[%s%b%s%b] %3d%%" "$C" "$NC" "$text" "$W" "$bar" "$DIM" "$rest" "$NC" "$progress"
        sleep 0.12
    done
    bar="$(printf '%*s' "$width" '' | tr ' ' '#')"
    printf "\r  %b✔%b %-26s %b[%b%s%b] %3d%%\n" "$G" "$NC" "$text" "$W" "$G" "$bar" "$W" 100
    tput cnorm 2>/dev/null || true
}
same_file() {
    local a="$1" b="$2"
    [ -f "$a" ] && [ -f "$b" ] && [ "$(readlink -f "$a" 2>/dev/null)" = "$(readlink -f "$b" 2>/dev/null)" ]
}
download_file_to_cache() {
    local mod="$1" base_url="$2" rel_path="${MOD_MAP[$1]:-}" tmp
    [ -n "$rel_path" ] || return 1
    tmp=$(mktemp "$SECURE_TMP/module.XXXXXX") || return 1
    if ! mt_download "$base_url/$rel_path" "$tmp" || ! mt_validate_script "$tmp"; then rm -f "$tmp"; return 1; fi
    local installed="/usr/bin/$mod"; [ "$mod" != main ] || installed="$MTUNNEL_PATH"
    local cur new; cur=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$installed" 2>/dev/null); new=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$tmp")
    mt_validate_module_core_contract "$tmp" || { rm -f "$tmp"; return 1; }
    mt_install_files 755 "$tmp" "$LOCAL_DIR/$rel_path"
    local rc=$?; rm -f "$tmp"; return "$rc"
}
deploy_cached_module() {
    local mod="$1" rel_path="${MOD_MAP[$1]:-}" installed="/usr/bin/$1"
    [ -n "$rel_path" ] || return 1
    [ "$mod" != main ] || installed="$MTUNNEL_PATH"
    mt_install_script "$LOCAL_DIR/$rel_path" "$rel_path" "$installed"
}
deploy_binaries_from_dir() {
    local src_dir="$1" name source unit rc=0 deb arch
    [ -d "$src_dir" ] || return 1
    for name in bh rathole paqet gost haproxy; do
        source="$src_dir/$name"
        [ "$name" != bh ] || [ -f "$source" ] || source="$src_dir/backhaul"
        [ -f "$source" ] || continue
        mt_valid_elf "$source" || { echo "Invalid/incompatible binary: $source" >&2; rc=1; continue; }
        case "$name" in bh) unit=mbackhaul;; rathole) unit=mrathole;; paqet) unit=mpaqet;; *) unit="$name";; esac
        mt_update_core "$name" "$unit" "$source" local || rc=1
        if [ "$src_dir" != "$LOCAL_DIR/packages" ]; then mt_install_files 755 "$source" "$LOCAL_DIR/packages/$name" || rc=1; fi
    done
    local -a debs=()
    for deb in "$src_dir"/*.deb; do
        [ -f "$deb" ] || continue
        arch=$(dpkg-deb -f "$deb" Architecture 2>/dev/null) || { rc=1; continue; }
        if [ "$arch" != all ] && [ "$arch" != "$(dpkg --print-architecture)" ]; then echo "Wrong package architecture: $deb" >&2; rc=1; continue; fi
        debs+=("$deb")
    done
    if [ "${#debs[@]}" -gt 0 ]; then
        dpkg -i --force-confdef --force-confold "${debs[@]}" || rc=1
        ldconfig || rc=1
    fi
    return "$rc"
}
ensure_module() {
    local mod="$1"
    local rel_path="${MOD_MAP[$mod]}"
    [ -z "$rel_path" ] && rel_path="${mod}.sh"
    local target_file="$LOCAL_DIR/$rel_path"
    mkdir -p "$(dirname "$target_file")" 2>/dev/null
    if [ -s "$target_file" ]; then deploy_cached_module "$mod" && return 0; fi
    if [ -s "/usr/bin/$mod" ]; then
        cp -f "/usr/bin/$mod" "$target_file" 2>/dev/null || true
        chmod 0755 "$target_file" 2>/dev/null || true
        deploy_cached_module "$mod" && return 0
    fi
    if download_file_to_cache "$mod" "$REPO_SCRIPTS"; then deploy_cached_module "$mod" && return 0; fi
    echo -e "  ${R}✗ ${W}${mod}${R} is not available locally and source download failed.${NC}"
    return 1
}
run_mod() { local mod="$1"; ensure_module "$mod" || return 1; "$mod"; }
install_bundle_scripts() {
    local source="$1" mod rel candidate target cur new bundle_version=''
    local -a files=() mods=()
    [ -d "$source" ] || return 1
    # Entire bundles must include the shared core. Never deploy loader scripts
    # without their matching dependency.
    [ -s "$source/core/common.sh" ] && bash -n "$source/core/common.sh" &&
        grep -q '^MTUNNEL_CORE_API=1$' "$source/core/common.sh" &&
        grep -q '^MTUNNEL_LAYOUT_REV=2$' "$source/core/common.sh" || {
        echo 'MTunnel shared core missing or invalid in the bundle.' >&2; return 1;
    }
    files+=("$source/core/common.sh" /usr/lib/mtunnel/common.sh
            "$source/core/common.sh" "$LOCAL_DIR/core/common.sh")
    for mod in "${ALL_MODULES[@]}"; do
        rel="${MOD_MAP[$mod]}"; candidate="$source/$rel"
        mt_validate_script "$candidate" || { echo "Incomplete MTunnel bundle: $rel" >&2; return 1; }
        local candidate_version
        candidate_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$candidate")
        if [ -z "${bundle_version:-}" ]; then bundle_version="$candidate_version"; fi
        [ "$candidate_version" = "$bundle_version" ] || { echo "Mixed module versions in bundle: $rel" >&2; return 1; }
        mods+=("$mod")
    done
    local core_version
    core_version=$(sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$source/core/common.sh")
    [ "$core_version" = "$bundle_version" ] || { echo 'Module/Core version mismatch. Refusing mixed bundle.' >&2; return 1; }
    # Installer must be included too: otherwise the installed release is mixed
    # after a successful "Sync All Scripts" downgrade.
    mt_validate_script "$source/install.sh" || { echo 'Missing installer in complete bundle.' >&2; return 1; }
    local installer_version
    installer_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$source/install.sh")
    [ "$installer_version" = "$bundle_version" ] || { echo 'Installer/bundle versions differ.' >&2; return 1; }
    # Compare ALL installed scripts to the candidate and authorize one coherent
    # downgrade of the entire bundle (not seven separate prompts).
    local installed_highest='' installed_version unknown_installed=0 conf_installed
    for mod in "${mods[@]}"; do
        target="/usr/bin/$mod"; [ "$mod" != main ] || target="$MTUNNEL_PATH"
        installed_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$target" 2>/dev/null)
        if [ -z "$installed_version" ]; then
            [ ! -f "$target" ] || unknown_installed=1
        elif [ -z "$installed_highest" ] || mt_is_newer_version "$installed_version" "$installed_highest"; then
            installed_highest="$installed_version"
        fi
    done
    # Also compare the installed copy of install.sh and the installed shared core.
    for target in "$LOCAL_DIR/install.sh" /usr/lib/mtunnel/common.sh; do
        case "$target" in
            */install.sh) installed_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$target" 2>/dev/null);;
            *) installed_version=$(sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$target" 2>/dev/null);;
        esac
        if [ -n "$installed_version" ] && { [ -z "$installed_highest" ] || mt_is_newer_version "$installed_version" "$installed_highest"; }; then
            installed_highest="$installed_version"
        fi
    done
    # A retired 15.x/16.x bundle (e.g. a stale mirror) must never silently replace 1.x.
    if mt_retired_bundle_blocked "$bundle_version" "$installed_highest"; then
        echo "Bundle v$bundle_version belongs to the retired 15.x/16.x line (stale mirror or cache?)." >&2
        echo "Installed is v$installed_highest. Refusing; refresh the source or set MT_ALLOW_RETIRED=1." >&2
        return 1
    fi
    conf_installed="$installed_highest"
    # An unreadable installed version is treated as unknown unless the bundle is
    # strictly newer than every readable installed version.
    if [ "$unknown_installed" == 1 ] && { [ -z "$conf_installed" ] || ! mt_is_newer_version "$bundle_version" "$conf_installed"; }; then conf_installed=unknown; fi
    mt_confirm_downgrade "$conf_installed" "$bundle_version" 'Full MTunnel Bundle' || return $?
    files+=("$source/install.sh" "$LOCAL_DIR/install.sh")
    for mod in "${mods[@]}"; do
        rel="${MOD_MAP[$mod]}"; candidate="$source/$rel"; target="/usr/bin/$mod"
        [ "$mod" != main ] || target="$MTUNNEL_PATH"
        files+=("$candidate" "$LOCAL_DIR/$rel" "$candidate" "$target")
    done
    mt_install_files 755 "${files[@]}" || return 1
    if [ "${2:-0}" == 1 ]; then
        local current=0 version total="${#mods[@]}"
        for mod in "${mods[@]}"; do
            current=$((current+1)); rel="${MOD_MAP[$mod]}"
            version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$source/$rel")
            draw_item_progress "$current" "$total" "$mod" "$version"
        done
    fi
    return 0
}
sync_script_bundle() {
    local base="$1" stage mod rel rc=0
    stage=$(mktemp -d "$SECURE_TMP/sync.XXXXXX") || return 1
    # Stage the shared core and all scripts before committing any module.
    mkdir -p "$stage/core"
    if ! mt_download "$base/core/common.sh" "$stage/core/common.sh" ||
       ! bash -n "$stage/core/common.sh" ||
       ! grep -q '^MTUNNEL_CORE_API=1$' "$stage/core/common.sh" ||
       ! grep -q '^MTUNNEL_LAYOUT_REV=2$' "$stage/core/common.sh"; then
        rm -rf "$stage"; return 1
    fi
    # Optional release marker: if the source publishes VERSION it must match the
    # core, otherwise the mirror/cache is only partly refreshed.
    local marker core_ver
    core_ver=$(sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$stage/core/common.sh")
    if mt_download "$base/VERSION" "$stage/VERSION" 2>/dev/null; then
        marker=$(head -c 32 "$stage/VERSION" | tr -d '\r\n ')
        if [ "$marker" != "$core_ver" ]; then
            echo "Source is inconsistent: VERSION says v$marker but shared core is v$core_ver. Refresh the mirror/cache." >&2
            rm -rf "$stage"; return 1
        fi
    fi
    for mod in "${ALL_MODULES[@]}"; do
        rel="${MOD_MAP[$mod]}"
        mkdir -p "$(dirname "$stage/$rel")" || { rc=1; break; }
        if ! mt_download "$base/$rel" "$stage/$rel" || ! mt_validate_script "$stage/$rel"; then rc=1; break; fi
    done
    if [ "$rc" == 0 ] && { ! mt_download "$base/install.sh" "$stage/install.sh" || ! mt_validate_script "$stage/install.sh"; }; then rc=1; fi
    [ "$rc" != 0 ] || install_bundle_scripts "$stage" "${2:-0}" || rc=$?
    rm -rf "$stage"
    return "$rc"
}
offline_local_deploy() {
    local source="$1" stage='' bundle rc=0
    [ -n "$source" ] || source="$PWD"
    if [ -f "$source" ]; then
        stage=$(mktemp -d "$SECURE_TMP/offline.XXXXXX") || return 1
        mt_extract_archive "$source" "$stage" || { rm -rf "$stage"; return 1; }
        source="$stage"
    fi
    [ -d "$source" ] || return 1
    bundle=$(find "$source" -maxdepth 3 -type f -name main.sh -printf '%h\n' | head -n 1)
    if [ -n "$bundle" ]; then
        install_bundle_scripts "$bundle" "${2:-0}" || { rc=$?; [ -z "$stage" ] || rm -rf "$stage"; return "$rc"; }
        [ ! -d "$bundle/packages" ] || deploy_binaries_from_dir "$bundle/packages" || rc=1
    else deploy_binaries_from_dir "$source" || rc=1; fi
    [ -z "$stage" ] || rm -rf "$stage"
    return "$rc"
}
fetch_package_group() {
    local base="$1" kind="$2" item file rc=0
    local -a items=()
    if [ "$kind" == cores ]; then items=(bh rathole paqet gost haproxy); else items=("${ALL_PACKAGES[@]}"); fi
    local stage; stage=$(mktemp -d "$SECURE_TMP/packages.XXXXXX") || return 1
    for item in "${items[@]}"; do
        file="$stage/$item"
        if ! mt_download "$base/$item" "$file"; then rc=1; break; fi
        case "$item" in *.deb) dpkg-deb --info "$file" >/dev/null || { rc=1; break; };; *) mt_valid_elf "$file" || { rc=1; break; };; esac
    done
    if [ "$rc" == 0 ]; then
        local -a files=()
        for item in "${items[@]}"; do files+=("$stage/$item" "$LOCAL_DIR/packages/$item"); done
        mt_install_files 755 "${files[@]}" || rc=1
        if [ "$kind" == cores ] && [ "$rc" == 0 ]; then deploy_binaries_from_dir "$stage" || rc=1; fi
    fi
    if [ "$rc" == 0 ] && [ "${3:-0}" == 1 ]; then
        local current=0 version label
        for item in "${items[@]}"; do
            current=$((current+1)); label="$item"; version="${BIN_VERSIONS[$item]:-Core}"
            if [[ "$item" == *.deb ]]; then label="${item%%_*}"; version="${item#*_}"; version="${version%%_*}"; fi
            draw_item_progress "$current" "${#items[@]}" "$label" "$version"
        done
    fi
    rm -rf "$stage"
    return "$rc"
}
render_ota_menu() {
    draw_main_header
    echo -e "\n  ${DIM}┌─[ Update & Local Install ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SCRIPT CORE ENGINE UPDATES ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Sync All Scripts from Official GitHub (Up/Down)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Sync All Scripts from Iranian Mirror (Up/Down)${NC}"
    local main_sub_badge="$(updates_summary_badge)"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Repair Dashboard & All Shared Modules (Official)${NC}${main_sub_badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ BINARY CORES ONLY (BH, RAT, PAQET, GOST, HAPROXY) ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Fetch Binary Cores from Official GitHub${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${G}Fetch Binary Cores from Iranian Mirror${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ FULL PREREQUISITES & DEB PACKAGES ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${C}Fetch All Packages & Prerequisites from GitHub${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${G}Fetch All Packages & Prerequisites from Iranian Mirror${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MANUAL & OVERRIDE METHODS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${Y}Custom Personal Link (.sh Script or ZIP)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${M}Manual Code Paste (Nano / Ctrl+X Auto Apply)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ LOCAL INSTALL ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${M}Offline Local Install (Directory / ZIP / Archive)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ INDIVIDUAL COMPONENT UPDATE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${C}Update One File from Official GitHub${NC}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${G}Update One File from Iranian Mirror${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├────────────────────────────${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Dashboard${NC}\n"
}
draw_item_progress() {
    local n="$1" total="$2" label="$3" version="$4" state="${5:-ok}" width=30
    local percent=$((n*100/total)) filled empty bar_f bar_e suffix padding pad_len
    filled=$((percent*width/100)); empty=$((width-filled))
    bar_f=$(printf '%*s' "$filled" '' | tr ' ' '#')
    bar_e=$(printf '%*s' "$empty" '' | tr ' ' '-')
    suffix=" (v${version})"; [ "$state" != failed ] || suffix=' (FAILED)'
    pad_len=$((26-${#label}-${#suffix})); [ "$pad_len" -ge 0 ] || pad_len=0
    padding=$(printf '%*s' "$pad_len" '')
    if [ "$state" == failed ]; then
        printf "  ${R}✖${NC} ${R}%s%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$label" "$suffix" "$padding" "$bar_f" "$bar_e" "$percent"
    else
        printf "  ${G}✔${NC} ${W}%s${NC}${Y}%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$label" "$suffix" "$padding" "$bar_f" "$bar_e" "$percent"
    fi
}
choose_module() {
    local i selection branch mode="${1:-OVERWRITE}"
    draw_main_header
    if [ "$mode" == EDITOR ]; then
        echo -e "\n  ${DIM}┌─[ MANUAL CODE PASTE (NANO) ]${NC}\n  ${DIM}│${NC}"
    else
        echo -e "\n  ${DIM}┌─[ SELECT COMPONENT TARGET ]${NC}\n  ${DIM}│${NC}"
    fi
    for i in "${!EDITABLE_COMPONENTS[@]}"; do
        branch='├─'; [ "$i" -ne "$((${#EDITABLE_COMPONENTS[@]}-1))" ] || branch='└─'
        echo -e "  ${DIM}${branch}${NC} ${W}$((i+1))${NC} ${DIM}❯${NC} ${C}${EDITABLE_COMPONENTS[$i]}${NC} ${DIM}(${COMPONENT_MAP[${EDITABLE_COMPONENTS[$i]}]})${NC}$(module_update_badge "${EDITABLE_COMPONENTS[$i]}")"
    done
    echo -ne "\n  ${C}${mode} ❯❯ ${NC}"; read -r selection
    [[ "$selection" =~ ^[0-9]{1,2}$ ]] && ((10#$selection>=1 && 10#$selection<=${#EDITABLE_COMPONENTS[@]})) || return 1
    CHOSEN_MODULE="${EDITABLE_COMPONENTS[$((10#$selection-1))]}"
}

component_primary_target() {
    case "$1" in
        main) printf '%s\n' "$MTUNNEL_PATH";;
        common) printf '%s\n' '/usr/lib/mtunnel/common.sh';;
        install) printf '%s\n' "$LOCAL_DIR/install.sh";;
        *) printf '/usr/bin/%s\n' "$1";;
    esac
}
component_version_from_file() {
    local component="$1" file="$2"
    if [ "$component" == common ]; then
        sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$file" | head -n1
    else
        sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$file" | head -n1
    fi
}
validate_component_candidate() {
    local component="$1" file="$2" rel="${COMPONENT_MAP[$1]:-}" api layout
    [ -n "$rel" ] || return 1
    if [ "$component" == common ]; then
        [ -s "$file" ] && bash -n "$file" || return 1
        grep -q '^MTUNNEL_CORE_API=[0-9][0-9]*$' "$file" || return 1
        grep -q '^MTUNNEL_LAYOUT_REV=[0-9][0-9]*$' "$file" || return 1
        grep -q '^MTUNNEL_RELEASE_VERSION="[0-9][0-9.]*"$' "$file" || return 1
        api=$(sed -n 's/^MTUNNEL_CORE_API=\([0-9][0-9]*\)$/\1/p' "$file" | head -n1)
        layout=$(sed -n 's/^MTUNNEL_LAYOUT_REV=\([0-9][0-9]*\)$/\1/p' "$file" | head -n1)
        if [ "$api" != "${MTUNNEL_CORE_API:-}" ] || [ "$layout" != "${MTUNNEL_LAYOUT_REV:-}" ]; then
            echo "Shared-core API/layout change ($api/$layout) requires Full Bundle Sync; independent core updates may only keep the current API/layout contract." >&2
            return 1
        fi
        return 0
    fi
    mt_validate_script "$file" || return 1
    if [ "$component" == install ]; then
        head -n 5 "$file" | grep -Fq '# MTunnel standalone installer:' || { echo 'Incorrect installer script pasted. Existing file preserved.' >&2; return 1; }
        return 0
    fi
    mt_validate_module_role "$file" "$rel" || return 1
    mt_validate_module_core_contract "$file" || return 1
}
install_component_candidate() {
    local component="$1" file="$2" rel="${COMPONENT_MAP[$1]:-}" target current_v new_v
    validate_component_candidate "$component" "$file" || return 1
    target=$(component_primary_target "$component")
    current_v=$(component_version_from_file "$component" "$target" 2>/dev/null)
    new_v=$(component_version_from_file "$component" "$file")
    if [ -n "$current_v" ]; then mt_module_downgrade_allowed "$current_v" "$new_v" || return $?; fi
    case "$component" in
        common) mt_install_files 644 "$file" /usr/lib/mtunnel/common.sh "$file" "$LOCAL_DIR/core/common.sh";;
        install) mt_install_files 755 "$file" "$LOCAL_DIR/install.sh";;
        *) mt_install_script "$file" "$rel" "$target";;
    esac
}
capture_manual_component() {
    local output="$1" component="$2"
    [[ -t 0 && -t 1 ]] || { echo 'Manual Code Paste requires an interactive SSH terminal (TTY).' >&2; return 1; }
    mt_ensure_nano || return 1
    : > "$output" || return 1
    printf '\033[2J\033[H'
    nano -t -- "$output" || return 1
    [ -s "$output" ] || { echo 'Nothing saved; existing component preserved.' >&2; return 1; }
    sed -i 's/\r$//' "$output" || return 1
    if [[ "$(head -n1 "$output")" == \`\`\`bash || "$(head -n1 "$output")" == \`\`\`sh ]]; then sed -i '1d; ${/^```$/d;}' "$output" || return 1; fi
    sed -i '1s/^\xEF\xBB\xBF//' "$output" || return 1
    validate_component_candidate "$component" "$output"
}

ota_pause() {
    local dummy
    echo -ne "  ${DIM}Press Enter to return...${NC}\n"; read -r dummy
}
reload_dashboard() {
    [ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null || true
    [ -z "${STATS_PID:-}" ] || kill "$STATS_PID" 2>/dev/null || true
    exec "$MTUNNEL_PATH"
}
show_ota_update_hub() {
    local option base work url file module rel target confirm new_ver current_v kind source_name sync_rc
    while true; do
        render_ota_menu
        read_with_refresh "  ${C}OTA-HUB ❯❯ ${NC}" option render_ota_menu || return 0
        option="${option//[$' \r']/}"
        case "$option" in
            0|'') return 0;;
            1|2)
                draw_main_header
                base="$REPO_SCRIPTS"; source_name='OFFICIAL GITHUB'
                if [ "$option" == 2 ]; then base="$MIRROR_SCRIPTS"; source_name='IRANIAN MIRROR'; fi
                echo -e "\n  ${DIM}┌─[ SYNCING ALL SCRIPTS FROM ${source_name} ]${NC}\n"
                sync_script_bundle "$base" 1 && sync_rc=0 || sync_rc=$?
                if [ "$sync_rc" == 0 ]; then
                    : > "$UPDATE_FILE"
                    echo -e "\n\n  ${G}● Script sync finished. Press Enter to reload core...${NC}\n"
                    read -r confirm
                    reload_dashboard
                elif [ "$sync_rc" == 2 ]; then
                    echo -e "\n  ${Y}● Downgrade cancelled by operator. Existing scripts preserved.${NC}\n"
                else
                    echo -e "\n  ${R}✖ Script update failed. Previous scripts preserved.${NC}\n" >&2
                fi;;
            3)
                draw_main_header
                echo -e "\n  ${DIM}┌─[ REPAIRING FULL MODULAR BUNDLE ]${NC}\n"
                # Modular dashboard and core must be updated as one compatible pair.
                sync_script_bundle "$REPO_SCRIPTS" 0 && sync_rc=0 || sync_rc=$?
                if [ "$sync_rc" == 0 ]; then
                    new_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$LOCAL_DIR/main.sh")
                    draw_item_progress 1 1 main "$new_ver"
                    echo -e "\n\n  ${G}● Modular bundle successfully updated! Reloading...${NC}\n"
                    reload_dashboard
                elif [ "$sync_rc" == 2 ]; then
                    echo -e "\n  ${Y}● Downgrade cancelled by operator. Existing installation preserved.${NC}\n"
                else
                    draw_item_progress 1 1 main '' failed
                    echo -e "\n  ${R}✖ Bundle repair failed. Previous installation preserved.${NC}\n" >&2
                fi;;
            4|5|6|7)
                draw_main_header
                base="$REPO_SCRIPTS/packages"; source_name='OFFICIAL GITHUB'
                if [[ "$option" == 5 || "$option" == 7 ]]; then base="$MIRROR_PACKAGES"; source_name='IRANIAN MIRROR'; fi
                kind=cores
                if [[ "$option" == 6 || "$option" == 7 ]]; then
                    kind=all
                    echo -e "\n  ${DIM}┌─[ FETCHING ALL PREREQUISITES & PACKAGES FROM ${source_name} ]${NC}\n"
                else
                    echo -e "\n  ${DIM}┌─[ FETCHING BINARY CORES FROM ${source_name} ]${NC}\n"
                fi
                if fetch_package_group "$base" "$kind" 1; then
                    echo -e "\n\n  ${G}● Package operation completed successfully.${NC}\n"
                else
                    echo -e "\n  ${R}✖ Package operation failed. Check the reported error.${NC}\n" >&2
                fi;;
            8|9)
                work=$(mktemp -d "$SECURE_TMP/manual.XXXXXX") || return 1
                file="$work/input"
                if [ "$option" == 8 ]; then
                    draw_main_header
                    echo -e "\n  ${DIM}┌─[ CUSTOM DIRECT LINK DEPLOYMENT ]${NC}\n"
                    echo -ne "  ${C}●${NC} ${W}Enter Direct (.sh or .zip) URL: ${NC}"; read -r url
                    [ -n "$url" ] || { rm -rf "$work"; continue; }
                    mt_download "$url" "$file" &
                    local pid=$!
                    draw_progress_bar "$pid" 'Downloading Custom Resource'
                    if ! wait "$pid"; then
                        echo -e "\n  ${R}✖ Download failed! Check URL.${NC}\n" >&2
                        rm -rf "$work"; ota_pause; continue
                    fi
                    mkdir "$work/extracted"
                    if mt_extract_archive "$file" "$work/extracted" 2>/dev/null; then
                        offline_local_deploy "$work/extracted" 1 && sync_rc=0 || sync_rc=$?
                        if [ "$sync_rc" == 0 ]; then
                            echo -e "\n  ${G}✔ Archive extracted and modules deployed successfully!${NC}\n"
                            rm -rf "$work"; reload_dashboard
                        elif [ "$sync_rc" == 2 ]; then
                            echo -e "\n  ${Y}● Downgrade cancelled by operator. Existing installation preserved.${NC}\n"
                        else
                            echo -e "\n  ${R}✖ Bundle deployment failed.${NC}\n" >&2
                        fi
                        rm -rf "$work"; ota_pause; continue
                    fi
                    if ! choose_module; then
                        echo -e "\n  ${R}✖ Component selection cancelled.${NC}\n"
                        rm -rf "$work"; ota_pause; continue
                    fi
                    module="$CHOSEN_MODULE"
                    if ! validate_component_candidate "$module" "$file"; then
                        echo -e "\n  ${R}✖ Invalid or incompatible component file.${NC}\n"
                        rm -rf "$work"; ota_pause; continue
                    fi
                else
                    if ! choose_module EDITOR; then rm -rf "$work"; continue; fi
                    module="$CHOSEN_MODULE"
                    : > "$file"
                    if ! capture_manual_component "$file" "$module"; then
                        echo -e "\n  ${R}✖ Manual paste failed or cancelled. Previous component preserved.${NC}\n"
                        rm -rf "$work"; ota_pause; continue
                    fi
                fi
                rel="${COMPONENT_MAP[$module]}"; target=$(component_primary_target "$module")
                new_ver=$(component_version_from_file "$module" "$file")
                current_v=$(component_version_from_file "$module" "$target" 2>/dev/null)
                draw_main_header
                echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}\n  ${DIM}│${NC}"
                echo -e "  ${DIM}├─${NC} ${W}Target Component:${NC} ${C}${module}${NC} ${DIM}(${rel})${NC}"
                echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${current_v:-Unknown}${NC}"
                echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver:-Unknown}${NC}"
                echo -e "  ${DIM}│${NC}"
                if [ "$option" == 9 ]; then
                    confirm=y
                    echo -e "  ${G}✔ Nano file validated — applying selected component automatically.${NC}"
                else
                    echo -ne "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}"; read -r confirm
                fi
                if [[ "${confirm,,}" == y || "${confirm,,}" == yes ]]; then
                    if install_component_candidate "$module" "$file"; then
                        echo -e "\n  ${G}✔ Component ${module} (v${new_ver:-Unknown}) successfully applied!${NC}\n"
                        rm -rf "$work"
                        [ "$module" == install ] || reload_dashboard
                    else
                        echo -e "\n  ${R}✖ Component install failed. Previous file preserved.${NC}\n" >&2
                    fi
                else
                    echo -e "\n  ${Y}● Manual update cancelled by user.${NC}\n"
                fi
                rm -rf "$work";;
            10) show_local_install; continue;;
            11|12)
                base="$REPO_SCRIPTS"; source_name='OFFICIAL GITHUB'
                [ "$option" == 12 ] && { base="$MIRROR_SCRIPTS"; source_name='IRANIAN MIRROR'; }
                if ! choose_module UPDATE; then continue; fi
                module="$CHOSEN_MODULE"; rel="${COMPONENT_MAP[$module]}"
                work=$(mktemp -d "$SECURE_TMP/onefile.XXXXXX") || return 1
                file="$work/input"
                draw_main_header
                echo -e "\n  ${DIM}┌─[ INDIVIDUAL UPDATE: ${module} FROM ${source_name} ]${NC}\n"
                if ! mt_download "$base/$rel?t=$(date +%s)" "$file"; then
                    echo -e "  ${R}✖ Download failed. Existing component preserved.${NC}"
                    rm -rf "$work"; ota_pause; continue
                fi
                if ! validate_component_candidate "$module" "$file"; then
                    echo -e "  ${R}✖ Downloaded file is invalid or incompatible. Existing component preserved.${NC}"
                    rm -rf "$work"; ota_pause; continue
                fi
                target=$(component_primary_target "$module")
                current_v=$(component_version_from_file "$module" "$target" 2>/dev/null)
                new_ver=$(component_version_from_file "$module" "$file")
                echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${current_v:-Unknown}${NC}"
                echo -e "  ${DIM}├─${NC} ${W}Remote Version  :${NC} ${G}v${new_ver:-Unknown}${NC}"
                echo -ne "  ${DIM}└─${NC} ${C}Apply only this file? (y/n): ${NC}"; read -r confirm
                if [[ "${confirm,,}" == y || "${confirm,,}" == yes ]]; then
                    if install_component_candidate "$module" "$file"; then
                        echo -e "\n  ${G}✔ Only ${rel} was updated successfully.${NC}\n"
                        rm -rf "$work"
                        [ "$module" == install ] || reload_dashboard
                    else
                        echo -e "\n  ${R}✖ Individual update failed. Previous file preserved.${NC}\n"
                    fi
                fi
                rm -rf "$work";;
            *) continue;;
        esac
        ota_pause
    done
}
install_iperf3_source() {
    local src_choice="$1"
    local deb_iperf="iperf3_3.16-1build2_amd64.deb"
    local deb_lib="libiperf0_3.20-2.1_amd64.deb"
    case $src_choice in
        1)
            echo -e "\n  ${DIM}● Preparing APT environment...${NC}"
            # Wait for the package-manager lock; never kill apt/dpkg.
            dpkg --configure -a >/dev/null 2>&1 || true
            (
                DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 update -y -q >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -q libiperf0 iperf3 >/dev/null 2>&1
            ) &
            local pid=$!
            draw_progress_bar "$pid" "Installing iPerf3 via APT"
            wait "$pid" 2>/dev/null
            ldconfig 2>/dev/null || true
            ;;
        2|3)
            local base_url="$MIRROR_PACKAGES"
            local fb_url="${MTUNNEL_GITHUB_BASE}/packages"
            local src_name="Iranian Mirror"
            if [ "$src_choice" == "3" ]; then
                base_url="${MTUNNEL_GITHUB_BASE}/packages"
                fb_url="$MIRROR_PACKAGES"
                src_name="Official GitHub"
            fi
            echo -e "\n  ${DIM}● Fetching iPerf3 & Libs from ${src_name}...${NC}"
            (
                for deb in "$deb_lib" "$deb_iperf"; do
                    local out_f="$SECURE_TMP/$deb"
                    local ok=false
                    if command -v curl >/dev/null 2>&1; then
                        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 -o "$out_f" "$base_url/$deb" 2>/dev/null && ok=true
                    elif command -v wget >/dev/null 2>&1; then
                        wget -q  --header="Cache-Control: no-cache" --timeout=8 -O "$out_f" "$base_url/$deb" 2>/dev/null && ok=true
                    fi
                    if [ "$ok" != true ] || [ ! -s "$out_f" ]; then
                        if command -v curl >/dev/null 2>&1; then
                            curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 -o "$out_f" "$fb_url/$deb" 2>/dev/null || true
                        fi
                    fi
                done
            ) &
            local pid=$!
            draw_progress_bar "$pid" "Downloading iPerf3 & Libs"
            wait "$pid" 2>/dev/null
            for deb_f in "$SECURE_TMP"/libiperf*.deb "$SECURE_TMP"/iperf3*.deb; do
                if [ -s "$deb_f" ]; then
                    dpkg -i --force-confdef --force-confold "$deb_f" >/dev/null 2>&1
                    mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
                    cp -f "$deb_f" "$LOCAL_DIR/packages/" 2>/dev/null
                    rm -f "$deb_f"
                fi
            done
            apt-get -o DPkg::Lock::Timeout=180 install -f -y -q >/dev/null 2>&1 || true
            ldconfig 2>/dev/null || true
            ;;
        4)
            echo -e "\n  ${DIM}● Checking local packages directory for iperf3 and libiperf...${NC}"
            local found_any=false
            for deb in $(find "$LOCAL_DIR/packages" -type f \( -name "*libiperf*.deb" -o -name "*iperf3*.deb" \) 2>/dev/null | sort -V); do
                if [ -s "$deb" ]; then
                    dpkg -i --force-confdef --force-confold "$deb" >/dev/null 2>&1
                    found_any=true
                fi
            done
            if [ "$found_any" = true ]; then
                apt-get -o DPkg::Lock::Timeout=180 install -f -y -q >/dev/null 2>&1 || true
                ldconfig 2>/dev/null || true
            else
                echo -e "  ${R}✖ No iPerf3 or libiperf .deb packages found in ${LOCAL_DIR}/packages/${NC}"
                sleep 2
                return 1
            fi
            ;;
        5)
            echo -ne "  ${C}● Enter HTTPS Direct (.deb) Link: ${NC}"; read -r custom_url
            custom_url=$(echo "$custom_url" | tr -d '\r\n ')
            [[ "$custom_url" == https://* ]] || { echo -e "  ${R}✖ Custom packages require HTTPS.${NC}"; return 1; }
            echo -ne "  ${C}● Expected SHA256 (64 hex chars): ${NC}"; read -r custom_sha
            custom_sha=$(echo "$custom_sha" | tr -d '\r\n ' | tr 'A-F' 'a-f')
            [[ "$custom_sha" =~ ^[0-9a-f]{64}$ ]] || { echo -e "  ${R}✖ A valid SHA256 is required.${NC}"; return 1; }
            echo -e "\n  ${DIM}● Downloading and verifying custom package...${NC}"
            local dl_target="$SECURE_TMP/custom_iperf.deb"
            rm -f "$dl_target"
            if ! mt_download "$custom_url" "$dl_target" "$custom_sha"; then
                echo -e "  ${R}✖ HTTPS download or SHA256 verification failed.${NC}"; rm -f "$dl_target"; return 1
            fi
            if ! dpkg-deb --info "$dl_target" >/dev/null 2>&1; then
                echo -e "  ${R}✖ Downloaded file is not a valid Debian package.${NC}"; rm -f "$dl_target"; return 1
            fi
            if ! dpkg -i --force-confdef --force-confold "$dl_target" >/dev/null 2>&1; then
                apt-get -o DPkg::Lock::Timeout=180 install -f -y -q >/dev/null 2>&1 || { rm -f "$dl_target"; return 1; }
                dpkg -i --force-confdef --force-confold "$dl_target" >/dev/null 2>&1 || { rm -f "$dl_target"; return 1; }
            fi
            ldconfig 2>/dev/null || true
            mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
            cp -f "$dl_target" "$LOCAL_DIR/packages/" 2>/dev/null
            rm -f "$dl_target"
            ;;
    esac
    if is_iperf3_valid; then
        echo -e "\n  ${G}✔ iPerf3 and shared libraries verified and functional.${NC}\n"
        sleep 1.5
        return 0
    else
        echo -e "\n  ${R}✖ Installation failed or shared libraries (libiperf.so.0) missing!${NC}\n"
        echo -e "  ${Y}Tip: Run 'apt-get install -y libiperf0 iperf3' or check package dependencies.${NC}\n"
        echo -ne "  ${DIM}Press Enter to return...${NC}\n"; read dummy
        return 1
    fi
}
run_iperf3() {
    if ! is_iperf3_valid; then
        draw_main_header
        echo -e "\n  ${DIM}┌─[ IPERF3 BENCHMARK INSTALLER ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official APT Repository (apt-get install libiperf0 iperf3)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Iranian Mirror (.deb Packages)${NC} ${DIM}(${MTUNNEL_MIRROR_BASE})${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Official GitHub Packages (.deb)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Custom Direct Link (.deb)${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel / Return to Main Core${NC}\n"
        echo -ne "  ${C}Select Source ❯❯ ${NC}"; read inst_opt
        inst_opt=$(echo "$inst_opt" | tr -d '\r ')
        if [[ "$inst_opt" =~ ^[1-5]$ ]]; then
            install_iperf3_source "$inst_opt" || return 1
        else
            return 0
        fi
    fi
    render_iperf_menu() {
        draw_main_header
        echo -e "\n  ${DIM}┌─[ IPERF3 BANDWIDTH BENCHMARK (Port: 5201 TCP/UDP) ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run as Server (Listener Mode)${NC} ${DIM}(Wait for peer connections)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run as Client (Sender Mode)${NC}   ${DIM}(Push bandwidth stream to server)${NC}"
        echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    }
    while true; do
        render_iperf_menu
        read_with_refresh "  ${C}iPerf3 ❯❯ ${NC}" i_opt render_iperf_menu || break
        i_opt=$(echo "$i_opt" | tr -d '\r ' )
        case $i_opt in
            1)
                echo -e "\n  ${G}● iPerf3 Server listening on port 5201 (Press Ctrl+C to stop)...${NC}\n"
                iperf3 -s -p 5201
                echo -ne "\n  ${DIM}Press Enter to return...${NC}\n"; read dummy ;;
            2)
                echo -ne "\n  ${C}●${NC} ${W}Enter Target Server IP / Tunnel IP: ${NC}"; read t_ip
                t_ip=$(echo "$t_ip" | tr -d '\r ' )
                [ -z "$t_ip" ] && continue
                echo -ne "  ${C}●${NC} ${W}Test Duration in Seconds [Default 10]: ${NC}"; read t_sec
                t_sec=${t_sec:-10}
                echo -e "\n  ${Y}● Running Benchmark against $t_ip (10s)...${NC}\n"
                iperf3 -c "$t_ip" -p 5201 -t "$t_sec"
                echo -ne "\n  ${DIM}Press Enter to return...${NC}\n"; read dummy ;;
            0) break ;;
        esac
    done
}
module_update_badge() {
    local version
    version=$(awk -F: -v mod="$1" '$1==mod {print $3;exit}' "$UPDATE_FILE" 2>/dev/null)
    [ -z "$version" ] || printf ' %b' "${Y}(Update Available: v${version})${NC}"
    return 0
}
updates_summary_badge() {
    [ -s "$UPDATE_FILE" ] || return 0
    local versions count version
    versions=$(awk -F: 'NF>=3 && $3!="" {print $3}' "$UPDATE_FILE" 2>/dev/null | sort -Vu)
    count=$(printf '%s
' "$versions" | sed '/^$/d' | wc -l)
    if [ "$count" -eq 1 ] 2>/dev/null; then
        version=$(printf '%s
' "$versions" | head -n1)
        printf ' %b' "${Y}(Update Available: v${version})${NC}"
    else
        printf ' %b' "${Y}(Updates Available)${NC}"
    fi
}
use_peer_code() {
    local link kind mod
    draw_main_header
    echo -e "\n  ${DIM}┌─[ USE PEER CODE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -ne "  ${DIM}└─${NC} ${C}Paste Peer Setup Link (q: back) ❯❯ ${NC}"; read -r link || return 0
    link="${link//[$' \r\n\t']/}"
    [[ "$link" == q || -z "$link" ]] && return 0
    kind=$(printf '%s' "$link" | sed -n 's#^mtunnel://[123]/\([a-z]*\)/.*#\1#p')
    case "$kind" in
        gre) mod=mgre;; vxlan) mod=mxlan;; rathole) mod=mrathole;;
        backhaul) mod=mbackhaul;; paqet) mod=mpaqet;;
        *) echo -e "  ${R}✖ Not a valid peer link.${NC}"; read -r -p '  Press Enter to continue...' _; return 0;;
    esac
    MT_PEER_LINK="$link" run_mod "$mod"
}
render_main_menu() {
    draw_main_header
    printf '\n'
    printf '  %b┌─[ TUNNEL CORE & FABRIC MODULES ]%b\n' "$DIM" "$NC"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├─%b %b1%b %b❯%b %bUse Peer Code%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
    printf '  %b├─%b %b2%b %b❯%b %bGRE / GRE6 / IPIP Tunnel%b%s\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC" "$(module_update_badge mgre)"
    printf '  %b├─%b %b3%b %b❯%b %bVXLAN Virtual Mesh Fabric%b%s\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$M" "$NC" "$(module_update_badge mxlan)"
    printf '  %b├─%b %b4%b %b❯%b %bRathole Reverse Tunnel%b%s\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$R" "$NC" "$(module_update_badge mrathole)"
    printf '  %b├─%b %b5%b %b❯%b %bBackhaul Multiplexer%b%s\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC" "$(module_update_badge mbackhaul)"
    printf '  %b├─%b %b6%b %b❯%b %bPaqet Raw Packet KCP Tunnel%b%s\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$M" "$NC" "$(module_update_badge mpaqet)"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├─[ TOOLS & BENCHMARK UTILITIES ]%b\n' "$DIM" "$NC"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├─%b %b7%b %b❯%b %bPort Forwarding Matrix (Mporter)%b%s\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC" "$(module_update_badge mporter)"
    printf '  %b├─%b %b8%b %b❯%b %biPerf3 Bandwidth Benchmark%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├─[ SYSTEM UPDATE & MAINTENANCE ]%b\n' "$DIM" "$NC"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├─%b %b9%b %b❯%b %bUpdate & Local Install%b%s\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC" "$(updates_summary_badge)"
    printf '  %b├─%b %b10%b %b❯%b %bNuclear Wipe (Uninstall)%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$R" "$NC"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b└─%b %b0%b %b❯%b %bExit Terminal%b\n\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$DIM" "$NC"
}
show_local_install() {
    local local_input
    draw_main_header
    echo -e "\n  ${DIM}┌─[ OFFLINE LOCAL INSTALL ]${NC}\n"
    echo -ne "  ${C}●${NC} ${W}Enter local path (Directory, .zip, or .tar.gz) [Enter for current]: ${NC}"; read -r local_input
    draw_main_header
    echo -e "\n  ${DIM}┌─[ INSTALLING FROM LOCAL SOURCE ]${NC}\n"
    local deploy_rc=0
    offline_local_deploy "$local_input" 1 || deploy_rc=$?
    if [ "$deploy_rc" == 0 ]; then
        echo -e "\n\n  ${G}● Local scripts and available binary packages installed successfully.${NC}\n"
    elif [ "$deploy_rc" == 2 ]; then
        echo -e "\n  ${Y}● Downgrade cancelled by operator. Existing installation preserved.${NC}\n"
    else echo -e "\n  ${R}✖ Local install failed. Check the reported error.${NC}\n" >&2; fi
    ota_pause
}
while true; do
    render_main_menu
    read_with_refresh "  ${C}CORE ❯❯ ${NC}" opt render_main_menu || break
    opt=$(echo "$opt" | tr -d '\r ')
    case $opt in
        1) use_peer_code ;;
        2) run_mod "mgre" ;;
        3) run_mod "mxlan" ;;
        4) run_mod "mrathole" ;;
        5) run_mod "mbackhaul" ;;
        6) run_mod "mpaqet" ;;
        7) run_mod "mporter" ;;
        8) run_iperf3 ;;
        0) kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null; clear; exit 0 ;;
        9) show_ota_update_hub ;;
        10)
            draw_main_header
            echo -e "\n  ${R}╭────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${R}│${NC} ${W}MTunnel Nuclear Wipe (Complete Uninstaller)${NC}                  ${R}│${NC}"
            echo -e "  ${R}╰────────────────────────────────────────────────────────────╯${NC}\n"
            echo -e "  ${Y}⚠ Warning: This will stop and remove all tunnels, services,${NC}"
            echo -e "  ${Y}  MTunnel tunnel cores, MTunnel services, and MTunnel-owned configs!${NC}\n"
            echo -ne "  ${R}Type WIPE-MTUNNEL to continue: ${NC}"; read del_confirm
            del_confirm="${del_confirm//[$' \r\n']/}"
            if [[ "$del_confirm" == "WIPE-MTUNNEL" ]]; then
                echo -e "\n  ${C}● Terminating services and wiping files...${NC}"
                
                systemctl stop mgre-watchdog.timer mxlan-watchdog.timer mporter-watchdog.service 2>/dev/null || true
                /usr/bin/mgre --teardown-all 2>/dev/null || true
                /usr/bin/mxlan --teardown-all 2>/dev/null || true
                for bin in iptables ip6tables; do
                    command -v "$bin" >/dev/null 2>&1 || continue
                    for table in filter nat mangle raw; do
                        for chain in INPUT OUTPUT FORWARD PREROUTING POSTROUTING; do
                            for tag in MGRE_ MXLAN_ MPORTER_ MBH_ RAT_ MPAQET_ OBFS_CNT_; do mt_delete_tagged_rules "$bin" "$table" "$chain" "$tag" prefix; done
                        done
                    done
                    for chain in MGRE_GUARD MGRE6_GUARD MXLAN_GUARD MXLAN6_GUARD; do
                        "$bin" -F "$chain" 2>/dev/null; "$bin" -X "$chain" 2>/dev/null
                    done
                done
                if command -v crontab >/dev/null 2>&1; then
                    cron_tmp=$(mktemp "$SECURE_TMP/uninstall-cron.XXXXXX")
                    crontab -l 2>/dev/null | awk '!/mbackhaul@|mrathole@|mpaqet@|\/usr\/bin\/mgre|\/usr\/bin\/mxlan|\/usr\/local\/bin\/mporter-watchdog/' > "$cron_tmp"
                    crontab "$cron_tmp"; rm -f "$cron_tmp"
                fi
                systemctl stop mgre-watchdog.timer mxlan-watchdog.timer mbackhaul-apply.service mrathole-apply.service mpaqet-apply.service mporter-iptables.service mporter-obfs.service 2>/dev/null || true
                systemctl disable mgre-watchdog.timer mxlan-watchdog.timer mbackhaul-apply.service mrathole-apply.service mpaqet-apply.service mporter-iptables.service mporter-obfs.service 2>/dev/null || true
                rm -f /etc/systemd/system/mgre-watchdog.{service,timer} /etc/systemd/system/mxlan-watchdog.{service,timer} /etc/systemd/system/{mbackhaul,mrathole,mpaqet}-apply.service /etc/systemd/system/mporter-{iptables,obfs}.service
                rm -f /usr/local/bin/mhealer_daemon.sh /usr/local/bin/mporter-{watchdog,iptables,obfs}.sh /etc/mhealer.conf
                rm -f /var/lock/mporter-state.lock /run/mporter-backends.tsv
                # Generic Gost/Realm installations may belong to another project. Remove only when MPorter explicitly marked ownership.
                if [ -f /etc/mporter/.owns_gost ]; then systemctl disable --now gost.service 2>/dev/null || true; rm -f /etc/systemd/system/gost.service /usr/local/bin/gost; rm -rf /etc/gost; fi
                if [ -f /etc/mporter/.owns_realm ]; then systemctl disable --now realm.service 2>/dev/null || true; rm -f /etc/systemd/system/realm.service /usr/local/bin/realm; rm -rf /etc/realm; fi
                rm -rf /run/mtunnel-healer
                systemctl stop mgre.service mxlan.service mporter.service mporter-watchdog.service mbackhaul@* mrathole@* mpaqet@* 2>/dev/null || true
                systemctl disable mgre.service mxlan.service mporter.service mporter-watchdog.service mbackhaul@* mrathole@* mpaqet@* 2>/dev/null || true
                
                rm -f /etc/systemd/system/mgre.service \
                      /etc/systemd/system/mxlan.service \
                      /etc/systemd/system/mporter.service \
                      /etc/systemd/system/mporter-watchdog.service \
                      /etc/systemd/system/mbackhaul@.service \
                      /etc/systemd/system/mrathole@.service \
                      /etc/systemd/system/mpaqet@.service 2>/dev/null || true
                systemctl daemon-reload 2>/dev/null || true
                # Only delete MTunnel-provisioned cores whose stored hash still matches.
                for core_bin in bh rathole paqet; do
                    mt_owned_binary_remove "$core_bin" "/usr/local/bin/$core_bin" "/usr/bin/$core_bin" || true
                done
                rm -rf /var/lib/mtunnel/owned-binaries /usr/lib/mtunnel /etc/mgre /etc/mporter /etc/mrathole /etc/mbackhaul /etc/paqet /root/mtunnel 2>/dev/null || true
                rm -f /usr/bin/mtunnel /usr/bin/mgre /usr/bin/mxlan /usr/bin/mbackhaul /usr/bin/mpaqet /usr/bin/mporter /usr/bin/mrathole
                rm -f /usr/local/bin/mtunnel
                kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
                echo -e "\n  ${G}✓ MTunnel ecosystem completely wiped from this system.${NC}\n"; exit 0
            else
                echo -e "\n  ${Y}● Wipe cancelled.${NC}"; sleep 1.5
            fi
            ;;
    esac
done
