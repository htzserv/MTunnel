#!/bin/bash
# --- MTunnel Doctor | System Diagnostics v1.2.0 ---
# [Features: Full Health Scan | Network/IPv6 | Firewall/Ports | Core & Script Health | Safe Repair | Export Report]
MODULE_VERSION="1.2.0"
MTUNNEL_REQUIRED_CORE_API=1
MTUNNEL_REQUIRED_LAYOUT_REV=2
umask 077

# MTUNNEL_COMMON_LOADER -- common API 1, required by this module.
mt_load_common() {
    local script_dir candidate
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    for candidate in \
        "$script_dir/../core/common.sh" \
        "$script_dir/core/common.sh" \
        /usr/lib/mtunnel/common.sh \
        /root/mtunnel/core/common.sh; do
        if [[ -f "$candidate" && -r "$candidate" ]]; then
            source "$candidate" || return 1
            if [[ "${MTUNNEL_CORE_API:-}" == "${MTUNNEL_REQUIRED_CORE_API:-1}" && "${MTUNNEL_LAYOUT_REV:-}" == "${MTUNNEL_REQUIRED_LAYOUT_REV:-2}" ]]; then return 0; fi
            printf 'MTunnel Doctor: incompatible shared core: %s\n' "$candidate" >&2
            return 1
        fi
    done
    echo 'MTunnel Doctor: core/common.sh is missing. Reinstall the complete bundle.' >&2
    return 1
}
mt_load_common || exit 1
unset -f mt_load_common
if [ "$EUID" != 0 ]; then echo "Run MTunnel Doctor with sudo." >&2; exit 1; fi

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
REPORT_DIR="$LOCAL_DIR/reports"
mkdir -p "$SECURE_TMP" "$REPORT_DIR" 2>/dev/null
chmod 700 "$SECURE_TMP" "$REPORT_DIR" 2>/dev/null || true

MAIN_PID=$$
NEED_REFRESH=false
NEED_LIVE_HEADER_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1
trap 'NEED_LIVE_HEADER_REFRESH=true' SIGUSR2
STATS_CHECK_INTERVAL=5

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

mt_unit_peer_ip() { mt_unit_live_peer "$1" "${2:-}"; }

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
                    [ -n "$peer_ip" ] || peer_ip=$(mt_unit_link_reason "mbackhaul@${t_name}" 1 "$TUN_PORT" 2>/dev/null || true)
                    [ -n "$peer_ip" ] || peer_ip="Listening"
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
                [ -n "$peer_ip" ] || peer_ip=$(mt_unit_link_reason "mrathole@${t_name}" 1 "$LINK_PORT" 2>/dev/null || true)
                [ -n "$peer_ip" ] || peer_ip="Listening"
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
        local now_ts mtime
        now_ts=$(date +%s)
        mtime=$(stat -c %Y "$SECURE_TMP/.main_sys_stats" 2>/dev/null || echo 0)
        if [ $(( now_ts - mtime )) -gt 7 ]; then
            collect_system_vitals
            collect_active_tunnels_stats
        fi
        kill -SIGUSR2 "$MAIN_PID" 2>/dev/null
        sleep "$STATS_CHECK_INTERVAL"
    done
}

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
                printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
            done < "$SECURE_TMP/.main_tun_stats"
        fi
        if [ "$cshown" -eq 0 ]; then
            compact_line='No active tunnels configured.'
            printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        fi
        printf "  ${B}╰${border}╯${NC}\033[K\n"
        return 0
    fi

    # Wide dashboard (responsive): the frame is sized from what has to be shown.
    local total extra peer_w v6_addr v6_need peer_need need_total w6 w4 v6_field
    v6_addr=$(get_local_ipv6)
    if [ -n "$v6_addr" ]; then v6_col="${M}"; v6_text="$v6_addr"; v6_need=$(( ${#v6_addr} + 10 ))
    else v6_col="${DIM}"; v6_text="OFF"; v6_need=21; fi
    (( v6_need < 21 )) && v6_need=21
    peer_need=16
    if [ -f "$SECURE_TMP/.main_tun_stats" ]; then
        peer_need=$(awk -F'|' 'NF>2 && n<3 {n++; l=length($3); if(l>m)m=l} END{print (m<16?16:m)}' "$SECURE_TMP/.main_tun_stats" 2>/dev/null)
        [[ "$peer_need" =~ ^[0-9]+$ ]] || peer_need=16
    fi
    need_total=$(( 31 + 25 + v6_need + 29 + 3 ))
    (( need_total < 117 )) && need_total=117
    (( 117 + peer_need - 16 > need_total )) && need_total=$(( 117 + peer_need - 16 ))
    total=$(( term_cols - 4 ))
    (( total > 150 )) && total=150
    (( total > need_total )) && total=$need_total
    (( total < 117 )) && total=117
    extra=$(( total - 117 )); peer_w=$(( 16 + extra ))
    w6=$v6_need
    (( w6 > total - 31 - 25 - 29 - 3 )) && w6=$(( total - 31 - 25 - 29 - 3 ))
    w4=$(( total - 31 - 25 - w6 - 3 ))
    v6_field=$(( w6 - 10 ))
    printf -v border '%*s' "$total" ''
    border="${border// /─}"

    printf '\033[K\n  %b╭%s╮%b\033[K\n' "$B" "$border" "$NC"
    # Row 1: title 31 | IPv4 25 | IPv6 w6 | BBR + Porter w4
    printf "  ${B}│${NC} ${W}%-29.29s${NC} ${B}│${NC} ${C}◆${NC} ${DIM}IPv4${NC}  ${M}%-15.15s${NC} ${B}│${NC} ${M}◆${NC} ${DIM}IPv6${NC}  %b%-*.*s%b ${B}│${NC} ${DIM}BBR:${NC} %b%s%b %-3.3s  ${DIM}Porter:${NC} %b%s%b %-*.*s ${B}│${NC}\033[K\n" \
        "MDesign Master Core v${MODULE_VERSION}" "$s_ip" \
        "$v6_col" "$v6_field" "$v6_field" "$v6_text" "$NC" \
        "$bbr_col" "$bbr_icon" "$NC" "$bbr_text" \
        "$porter_col" "$porter_icon" "$NC" "$((w4-24))" "$((w4-24))" "$porter_text"
    printf "  ${B}├${border}┤${NC}\033[K\n"
    # Row 2: CPU 31 | RAM 25 | Net ▼ w6 | Net ▲ w4
    printf "  ${B}│${NC} ${DIM}CPU:${NC} %b%-4.4s%b   ${DIM}Cores:${NC} ${W}%-10.10s${NC} ${B}│${NC} ${DIM}RAM:${NC} %b%-18.18s%b ${B}│${NC} ${DIM}Net ▼:${NC} %b%-*.*s%b ${B}│${NC} ${DIM}Net ▲:${NC} %b%-*.*s%b ${B}│${NC}\033[K\n" \
        "$cpu_col" "$cpu_str" "$NC" "$core_label" \
        "$ram_col" "$ram_str" "$NC" \
        "$rx_col" "$((w6-9))" "$((w6-9))" "$rx_speed" "$NC" \
        "$tx_col" "$((w4-9))" "$((w4-9))" "$tx_speed" "$NC"
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

draw_doctor_header() {
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

DOC_PASS=0
DOC_WARN=0
DOC_FAIL=0
DOC_TOTAL=0
DOC_LAST_SUMMARY="Not scanned"
DOC_LAST_COLOR="$DIM"
DOC_PLAIN=0

_doc_color() { [ "$DOC_PLAIN" = 1 ] && printf '' || printf '%b' "$1"; }
_doc_reset() { [ "$DOC_PLAIN" = 1 ] && printf '' || printf '%b' "$NC"; }
_doc_icon() {
    case "$1" in
        PASS) printf '✔';;
        WARN) printf '⚠';;
        FAIL) printf '✖';;
        INFO) printf '●';;
        *) printf '·';;
    esac
}
_doc_status_color() {
    case "$1" in PASS) printf '%b' "$G";; WARN) printf '%b' "$Y";; FAIL) printf '%b' "$R";; INFO) printf '%b' "$C";; *) printf '%b' "$DIM";; esac
}

doc_reset_counts() { DOC_PASS=0; DOC_WARN=0; DOC_FAIL=0; DOC_TOTAL=0; }
doc_count() {
    case "$1" in
        PASS) DOC_PASS=$((DOC_PASS+1)); DOC_TOTAL=$((DOC_TOTAL+1));;
        WARN) DOC_WARN=$((DOC_WARN+1)); DOC_TOTAL=$((DOC_TOTAL+1));;
        FAIL) DOC_FAIL=$((DOC_FAIL+1)); DOC_TOTAL=$((DOC_TOTAL+1));;
    esac
}

doc_group() {
    local title="$1"
    if [ "$DOC_PLAIN" = 1 ]; then
        printf '\n[%s]\n' "$title"
    else
        printf '\n  %b┌─[ %s ]%b\n' "$DIM" "$title" "$NC"
        printf '  %b│%b\n' "$DIM" "$NC"
    fi
}

doc_row() {
    local state="$1" label="$2" value="$3" color icon
    doc_count "$state"
    if [ "$DOC_PLAIN" = 1 ]; then
        printf '  %-4s %-27s %s\n' "$state" "$label" "$value"
        return
    fi
    color=$(_doc_status_color "$state"); icon=$(_doc_icon "$state")
    printf '  %b├─%b %b%s%b %-27s %b%s%b\n' "$DIM" "$NC" "$color" "$icon" "$NC" "$label" "$color" "$value" "$NC"
}

doc_info() {
    local label="$1" value="$2"
    if [ "$DOC_PLAIN" = 1 ]; then printf '  INFO %-27s %s\n' "$label" "$value"
    else printf '  %b├─%b %b●%b %-27s %b%s%b\n' "$DIM" "$NC" "$C" "$NC" "$label" "$W" "$value" "$NC"; fi
}

doc_note() {
    if [ "$DOC_PLAIN" = 1 ]; then printf '  NOTE %s\n' "$*"; else printf '  %b│%b  %b%s%b\n' "$DIM" "$NC" "$DIM" "$*" "$NC"; fi
}

doc_footer() {
    [ "$DOC_PLAIN" = 1 ] && return
    printf '  %b└────────────────────────────────────────────────────────────%b\n' "$DIM" "$NC"
}

doc_pause() {
    local _
    [ "$DOC_PLAIN" = 1 ] && return 0
    printf '\n  %bPress Enter to return...%b' "$DIM" "$NC"
    read -r _
}

doc_local_dev() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

doc_default_mtu() {
    local dev; dev=$(doc_local_dev)
    [ -n "$dev" ] || return 1
    ip -o link show dev "$dev" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") {print $(i+1); exit}}'
}

doc_public_source_check() {
    local url="${MTUNNEL_GITHUB_BASE%/}/VERSION" out=''
    if command -v curl >/dev/null 2>&1; then
        out=$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 2 --max-time 5 "$url?t=$(date +%s)" 2>/dev/null | head -c 32 | tr -d '\r\n ')
    elif command -v wget >/dev/null 2>&1; then
        out=$(wget -qO- --https-only --timeout=5 "$url?t=$(date +%s)" 2>/dev/null | head -c 32 | tr -d '\r\n ')
    fi
    [[ "$out" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && { printf '%s' "$out"; return 0; }
    return 1
}

doc_kernel_module_status() {
    local mod="$1"
    if [ -d "/sys/module/$mod" ]; then printf 'loaded'; return 0; fi
    if command -v modprobe >/dev/null 2>&1 && modprobe -n "$mod" >/dev/null 2>&1; then printf 'available'; return 0; fi
    return 1
}

doc_iptables_backend() {
    local v
    v=$(iptables --version 2>/dev/null | head -n1)
    [ -n "$v" ] || return 1
    case "$v" in *nf_tables*) printf 'iptables-nft';; *legacy*) printf 'iptables-legacy';; *) printf '%s' "$v";; esac
}

doc_version_of() {
    sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$1" 2>/dev/null | head -n1
}

doc_script_check() {
    local label="$1" file="$2" version
    if [ ! -f "$file" ]; then doc_row WARN "$label" "not installed"; return; fi
    if ! bash -n "$file" >/dev/null 2>&1; then doc_row FAIL "$label" "syntax error"; return; fi
    version=$(doc_version_of "$file"); [ -n "$version" ] || version='unknown'
    doc_row PASS "$label" "v${version} / syntax OK"
}

doc_os_name() {
    local p='Linux'
    if [ -r /etc/os-release ]; then
        p=$(awk '$0 ~ /^PRETTY_NAME=/{v=substr($0,index($0,"=")+1); gsub(/^"|"$/,"",v); print v; exit}' /etc/os-release)
    fi
    printf '%s' "${p:-Linux}"
}

doc_scan_system() {
    local diskp sync pid1
    doc_group 'SYSTEM HEALTH'
    doc_row PASS 'Operating System' "$(doc_os_name)"
    doc_row PASS 'Kernel' "$(uname -r) / $(uname -m)"
    pid1=$(cat /proc/1/comm 2>/dev/null)
    if [ "$pid1" = systemd ] && command -v systemctl >/dev/null 2>&1; then doc_row PASS 'systemd' 'running as PID 1'; else doc_row FAIL 'systemd' "PID1=${pid1:-unknown}"; fi
    diskp=$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5);print $5}')
    if [[ "$diskp" =~ ^[0-9]+$ ]]; then
        if [ "$diskp" -ge 95 ]; then doc_row FAIL 'Root Disk Usage' "${diskp}% used"
        elif [ "$diskp" -ge 85 ]; then doc_row WARN 'Root Disk Usage' "${diskp}% used"
        else doc_row PASS 'Root Disk Usage' "${diskp}% used"; fi
    else doc_row WARN 'Root Disk Usage' 'unable to read'; fi
    sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [ "$sync" = yes ]; then doc_row PASS 'Clock Synchronization' 'NTP synchronized'; else doc_row WARN 'Clock Synchronization' "NTP=${sync:-unknown}"; fi
    if [ -r /proc/sys/net/ipv4/ip_forward ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ]; then doc_row PASS 'IPv4 Forwarding' 'enabled'; else doc_row FAIL 'IPv4 Forwarding' 'disabled'; fi
    if [ -r /proc/sys/net/ipv6/conf/all/forwarding ]; then
        if [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" = 1 ]; then doc_row PASS 'IPv6 Forwarding' 'enabled';
        elif [ -n "$(mt_local_ipv6 2>/dev/null)" ]; then doc_row WARN 'IPv6 Forwarding' 'disabled'; else doc_row PASS 'IPv6 Forwarding' 'disabled / no global IPv6'; fi
    else doc_row WARN 'IPv6 Forwarding' 'sysctl unavailable'; fi
    doc_footer
}

doc_scan_network() {
    local v4 v6 dev mtu source_v
    doc_group 'NETWORK & IPv6'
    v4=$(mt_local_ipv4 2>/dev/null); v6=$(mt_local_ipv6 2>/dev/null); dev=$(doc_local_dev); mtu=$(doc_default_mtu)
    [ -n "$v4" ] && doc_row PASS 'Local IPv4' "$v4" || doc_row FAIL 'Local IPv4' 'not detected'
    if ip -4 route show default 2>/dev/null | grep -q '^default'; then doc_row PASS 'IPv4 Default Route' "dev ${dev:-unknown}"; else doc_row FAIL 'IPv4 Default Route' 'missing'; fi
    [ -n "$v6" ] && doc_row PASS 'Global IPv6' "$v6" || doc_row WARN 'Global IPv6' 'not detected'
    if ip -6 route show default 2>/dev/null | grep -q '^default'; then doc_row PASS 'IPv6 Default Route' 'present'; elif [ -n "$v6" ]; then doc_row FAIL 'IPv6 Default Route' 'missing'; else doc_row WARN 'IPv6 Default Route' 'not configured'; fi
    if getent ahostsv4 github.com >/dev/null 2>&1; then doc_row PASS 'DNS Resolution' 'github.com resolves'; else doc_row FAIL 'DNS Resolution' 'resolution failed'; fi
    if source_v=$(doc_public_source_check); then doc_row PASS 'Official Source HTTPS' "reachable / v${source_v}"; else doc_row WARN 'Official Source HTTPS' 'unreachable or blocked'; fi
    [ -n "$mtu" ] && doc_row PASS 'Default Interface MTU' "${mtu} on ${dev:-unknown}" || doc_row WARN 'Default Interface MTU' 'unable to read'
    if command -v ping >/dev/null 2>&1 && ping -4 -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then doc_row PASS 'IPv4 Internet Probe' '1.1.1.1 reachable'; else doc_row WARN 'IPv4 Internet Probe' 'ICMP blocked or unreachable'; fi
    if [ -n "$v6" ]; then
        if command -v ping >/dev/null 2>&1 && ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then doc_row PASS 'IPv6 Internet Probe' 'Cloudflare IPv6 reachable'; else doc_row WARN 'IPv6 Internet Probe' 'ICMPv6 blocked or unreachable'; fi
    fi
    doc_footer
}

doc_scan_kernel() {
    local s
    doc_group 'TUNNEL KERNEL SUPPORT'
    for s in 'ip_gre|GRE / GRE6' 'ipip|IPIP' 'vxlan|VXLAN' 'xfrm_user|XFRM / IPsec'; do
        local mod="${s%%|*}" label="${s#*|}" state
        if state=$(doc_kernel_module_status "$mod"); then doc_row PASS "$label" "$mod $state"; else doc_row FAIL "$label" "$mod unavailable"; fi
    done
    if ip xfrm state >/dev/null 2>&1; then doc_row PASS 'XFRM Userspace' 'ip xfrm operational'; else doc_row WARN 'XFRM Userspace' 'xfrm query failed'; fi
    doc_footer
}

doc_scan_firewall() {
    local backend listeners mt_rules=0 ufw_state='inactive' fw_state='inactive'
    doc_group 'FIREWALL & PORTS'
    if backend=$(doc_iptables_backend); then doc_row PASS 'iptables Backend' "$backend"; else doc_row FAIL 'iptables Backend' 'not available'; fi
    if command -v nft >/dev/null 2>&1; then doc_row PASS 'nftables Tooling' "$(nft --version 2>/dev/null | head -n1)"; else doc_row WARN 'nftables Tooling' 'nft command missing'; fi
    if command -v ufw >/dev/null 2>&1; then ufw_state=$(ufw status 2>/dev/null | awk 'NR==1{print tolower($2)}'); fi
    if [ "$ufw_state" = active ]; then doc_row WARN 'UFW' 'active — verify MTunnel rules are permitted'; else doc_row PASS 'UFW' "${ufw_state:-inactive}"; fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then fw_state='active'; fi
    if [ "$fw_state" = active ]; then doc_row WARN 'firewalld' 'active — verify MTunnel zones/rules'; else doc_row PASS 'firewalld' 'inactive/not installed'; fi
    if command -v ss >/dev/null 2>&1; then
        listeners=$(ss -H -lntu 2>/dev/null | wc -l | tr -d ' ')
        doc_row PASS 'Listening Sockets' "${listeners:-0} TCP/UDP listeners"
    else doc_row FAIL 'Socket Inspector' 'ss command missing'; fi
    if command -v iptables-save >/dev/null 2>&1; then
        mt_rules=$(iptables-save 2>/dev/null | grep -Ec 'MGRE_|MXLAN_|MPORTER_|MBH_|RAT_|MPAQET_|OBFS_CNT_' || true)
        doc_row PASS 'MTunnel IPv4 Rules' "$mt_rules tagged rules"
    else doc_row WARN 'MTunnel IPv4 Rules' 'iptables-save unavailable'; fi
    doc_footer
}

doc_scan_mtunnel() {
    local corev core_file=/usr/lib/mtunnel/common.sh bin corepath
    doc_group 'MTUNNEL CORE & SCRIPT HEALTH'
    if [ -f "$core_file" ] && bash -n "$core_file" >/dev/null 2>&1 && grep -q '^MTUNNEL_CORE_API=1$' "$core_file"; then
        corev=$(sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$core_file" | head -n1)
        doc_row PASS 'Shared Core' "v${corev:-unknown} / API 1"
    else doc_row FAIL 'Shared Core' 'missing or invalid'; fi
    doc_script_check 'MTunnel Dashboard' /usr/bin/mtunnel
    doc_script_check 'GRE Engine' /usr/bin/mgre
    doc_script_check 'VXLAN Engine' /usr/bin/mxlan
    doc_script_check 'Rathole Engine' /usr/bin/mrathole
    doc_script_check 'Backhaul Engine' /usr/bin/mbackhaul
    doc_script_check 'Paqet Engine' /usr/bin/mpaqet
    doc_script_check 'MPorter' /usr/bin/mporter
    doc_script_check 'MTunnel Doctor' /usr/bin/mdoctor
    for bin in bh rathole paqet; do
        corepath=$(command -v "$bin" 2>/dev/null || true)
        [ -n "$corepath" ] && doc_row PASS "Binary Core: $bin" "$corepath" || doc_row WARN "Binary Core: $bin" 'not installed yet'
    done
    doc_footer
}

doc_scan_services() {
    local failed mt_failed
    doc_group 'SERVICES & RUNTIME'
    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk 'NF{c++} END{print c+0}')
    if [ "${failed:-0}" -eq 0 ]; then doc_row PASS 'Failed systemd Units' '0'; else doc_row WARN 'Failed systemd Units' "$failed total failed units"; fi
    mt_failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '$1 ~ /^(mgre|mxlan|mporter|mbackhaul|mrathole|mpaqet)/ {print $1}' | paste -sd, -)
    [ -z "$mt_failed" ] && doc_row PASS 'Failed MTunnel Units' 'none' || doc_row FAIL 'Failed MTunnel Units' "$mt_failed"
    if systemctl is-system-running --quiet 2>/dev/null; then doc_row PASS 'systemd Overall State' 'running'; else
        local state; state=$(systemctl is-system-running 2>/dev/null || true)
        [ "$state" = degraded ] && doc_row WARN 'systemd Overall State' 'degraded' || doc_row WARN 'systemd Overall State' "${state:-unknown}"
    fi
    doc_footer
}

doc_print_summary() {
    local score=100 color="$G" verdict='HEALTHY'
    if [ "$DOC_TOTAL" -gt 0 ]; then
        score=$(( (DOC_PASS*100 + DOC_WARN*50) / DOC_TOTAL ))
    fi
    if [ "$DOC_FAIL" -gt 0 ]; then color="$R"; verdict='ACTION REQUIRED'
    elif [ "$DOC_WARN" -gt 0 ]; then color="$Y"; verdict='CHECK WARNINGS'; fi
    DOC_LAST_SUMMARY="${DOC_PASS} pass / ${DOC_WARN} warn / ${DOC_FAIL} fail — ${score}%"
    DOC_LAST_COLOR="$color"
    if [ "$DOC_PLAIN" = 1 ]; then
        printf '\nSUMMARY: %s | %s\n' "$verdict" "$DOC_LAST_SUMMARY"
    else
        printf '\n  %b┌─[ DOCTOR RESULT ]%b\n' "$DIM" "$NC"
        printf '  %b│%b\n' "$DIM" "$NC"
        printf '  %b├─%b %b%-17s%b %b%s%b\n' "$DIM" "$NC" "$color" "$verdict" "$NC" "$W" "$DOC_LAST_SUMMARY" "$NC"
        printf '  %b└────────────────────────────────────────────────────────────%b\n' "$DIM" "$NC"
    fi
}

doc_full_scan() {
    local mode="${1:-screen}"
    [ "$mode" = plain ] && DOC_PLAIN=1 || DOC_PLAIN=0
    doc_reset_counts
    if [ "$DOC_PLAIN" != 1 ]; then draw_doctor_header; fi
    doc_scan_system
    doc_scan_network
    doc_scan_kernel
    doc_scan_firewall
    doc_scan_mtunnel
    doc_scan_services
    doc_print_summary
    [ "$DOC_PLAIN" = 1 ] || doc_pause
    DOC_PLAIN=0
}

doc_network_screen() {
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_network; doc_scan_kernel; doc_print_summary; doc_pause
}

doc_firewall_screen() {
    local line n=0
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_firewall
    doc_group 'LISTENING PORT PREVIEW'
    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r line; do
            n=$((n+1)); [ "$n" -gt 18 ] && break
            printf '  %b├─%b %b●%b %s\n' "$DIM" "$NC" "$C" "$NC" "$line"
        done < <(ss -H -lntup 2>/dev/null | awk '{printf "%-4s %-24s %s\n", $1, $5, $NF}')
        [ "$n" -gt 0 ] || doc_note 'No TCP/UDP listeners found.'
        [ "$n" -lt 18 ] || doc_note 'Preview limited to first 18 listeners.'
    else doc_note 'ss command is not available.'; fi
    doc_footer; doc_print_summary; doc_pause
}

doc_core_screen() {
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_mtunnel; doc_scan_services; doc_print_summary; doc_pause
}

doc_services_screen() {
    local line n=0
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_services
    doc_group 'FAILED UNIT DETAILS'
    while IFS= read -r line; do
        [ -n "$line" ] || continue; n=$((n+1)); [ "$n" -gt 15 ] && break
        printf '  %b├─%b %b⚠%b %s\n' "$DIM" "$NC" "$Y" "$NC" "$line"
    done < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1 " — " $4}')
    [ "$n" -gt 0 ] || doc_note 'No failed systemd units.'
    doc_footer; doc_print_summary; doc_pause
}

doc_persist_forwarding() {
    local v4="$1" v6="$2" file=/etc/sysctl.d/99-mtunnel-doctor.conf tmp
    tmp=$(mktemp "$SECURE_TMP/doctor-sysctl.XXXXXX") || return 1
    {
        echo '# Managed by MTunnel Doctor'
        [ "$v4" = 1 ] && echo 'net.ipv4.ip_forward = 1'
        [ "$v6" = 1 ] && echo 'net.ipv6.conf.all.forwarding = 1'
    } > "$tmp"
    install -m 0644 "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    sysctl --system >/dev/null 2>&1 || return 1
}

doc_confirm() {
    local answer
    printf '  %bType YES to continue ❯❯ %b' "$Y" "$NC"; read -r answer
    [ "$answer" = YES ]
}

render_repair_menu() {
    draw_doctor_header
    printf '\n  %b┌─[ SAFE REPAIR ACTIONS ]%b\n' "$DIM" "$NC"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├─%b %b1%b %b❯%b %bEnable & Persist IPv4 Forwarding%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC"
    printf '  %b├─%b %b2%b %b❯%b %bEnable & Persist IPv6 Forwarding%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$M" "$NC"
    printf '  %b├─%b %b3%b %b❯%b %bLoad Tunnel Kernel Modules%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
    printf '  %b├─%b %b4%b %b❯%b %bReload systemd Unit Database%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├────────────────────────────%b\n' "$DIM" "$NC"
    printf '  %b└─%b %b0%b %b❯%b %bReturn to Doctor%b\n\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$DIM" "$NC"
}

doc_safe_repair() {
    local choice mod ok=1
    while true; do
        render_repair_menu
        read_with_refresh "  ${C}REPAIR ❯❯ ${NC}" choice render_repair_menu || return 0
        choice="${choice//[$' \r\n\t']/}"
        case "$choice" in
            0|'') return 0;;
            1)
                echo -e "\n  ${Y}This writes /etc/sysctl.d/99-mtunnel-doctor.conf and enables IPv4 forwarding.${NC}"
                if doc_confirm && doc_persist_forwarding 1 0; then echo -e "  ${G}✔ IPv4 forwarding enabled and persisted.${NC}"; else echo -e "  ${R}✖ Cancelled or repair failed.${NC}"; fi; doc_pause;;
            2)
                echo -e "\n  ${Y}This writes /etc/sysctl.d/99-mtunnel-doctor.conf and enables IPv6 forwarding.${NC}"
                if doc_confirm && doc_persist_forwarding 0 1; then echo -e "  ${G}✔ IPv6 forwarding enabled and persisted.${NC}"; else echo -e "  ${R}✖ Cancelled or repair failed.${NC}"; fi; doc_pause;;
            3)
                echo -e "\n  ${DIM}Loading: ip_gre ipip vxlan xfrm_user${NC}"
                if doc_confirm; then
                    ok=1; for mod in ip_gre ipip vxlan xfrm_user; do modprobe "$mod" >/dev/null 2>&1 || ok=0; done
                    [ "$ok" = 1 ] && echo -e "  ${G}✔ Tunnel modules loaded.${NC}" || echo -e "  ${Y}⚠ One or more modules are unavailable on this kernel.${NC}"
                fi; doc_pause;;
            4)
                if doc_confirm && systemctl daemon-reload; then echo -e "  ${G}✔ systemd daemon-reload completed.${NC}"; else echo -e "  ${R}✖ Cancelled or reload failed.${NC}"; fi; doc_pause;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1;;
        esac
    done
}

doc_export_report() {
    local ts file tmp
    ts=$(date +%Y%m%d-%H%M%S); file="$REPORT_DIR/doctor-${ts}.txt"; tmp=$(mktemp "$SECURE_TMP/doctor-report.XXXXXX") || return 1
    {
        echo 'MTunnel Doctor Diagnostic Report'
        echo "Generated: $(date -Is)"
        echo "Doctor Version: $MODULE_VERSION"
        echo "Hostname: $(hostname 2>/dev/null)"
        echo '============================================================'
        doc_full_scan plain
    } > "$tmp"
    chmod 600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" || return 1
    DOC_PLAIN=0
    if [ "${DOC_NONINTERACTIVE:-0}" = 1 ]; then
        printf '%s\n' "$file"
        return 0
    fi
    draw_doctor_header
    echo -e "\n  ${DIM}┌─[ REPORT EXPORTED ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${G}✔${NC} ${W}Diagnostic report saved successfully.${NC}"
    echo -e "  ${DIM}└─${NC} ${C}${file}${NC}"
    doc_pause
}

render_doctor_menu() {
    draw_doctor_header
    printf '\n  %b┌─[ MTUNNEL DOCTOR & DIAGNOSTICS ]%b\n' "$DIM" "$NC"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├─%b %b1%b %b❯%b %bRun Full Health Scan%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
    printf '  %b├─%b %b2%b %b❯%b %bNetwork & IPv6 Diagnostics%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC"
    printf '  %b├─%b %b3%b %b❯%b %bFirewall & Port Diagnostics%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$Y" "$NC"
    printf '  %b├─%b %b4%b %b❯%b %bTunnel Engines & Core & Script Health%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$M" "$NC"
    printf '  %b├─%b %b5%b %b❯%b %bSystem Services & Failed Units%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC"
    printf '  %b├─%b %b6%b %b❯%b %bSafe Repair Actions%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
    printf '  %b├─%b %b7%b %b❯%b %bExport Diagnostic Report%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$W" "$NC"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├────────────────────────────%b\n' "$DIM" "$NC"
    printf '  %b└─%b %b0%b %b❯%b %bReturn to Dashboard%b\n\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$DIM" "$NC"
}

case "${1:-}" in
    --report) DOC_NONINTERACTIVE=1; doc_export_report; exit $?;;
    --scan|--status) doc_full_scan plain; exit $?;;
    --version|-V) printf 'MTunnel Doctor %s\n' "$MODULE_VERSION"; exit 0;;
    --help|-h)
        cat <<EOF ! "$SECURE_TMP/.main_sys_stats" "$STATS_PID" & 'kill --report --scan, --status --version -f 0;; 2 Doctor EOF Export MTunnel Run STATS_PID="$!" Show Usage: [ [--scan|--status|--report|--version] ]; a and collect_system_vitals diagnostic esac exit fi full health if its mdoctor non-interactive path print report scan stats_watcher_loop then trap v$MODULE_VERSION version>/dev/null' EXIT

while true; do
    render_doctor_menu
    read_with_refresh "  ${C}DOCTOR ❯❯ ${NC}" opt render_doctor_menu || break
    opt="${opt//[$' \r\n\t']/}"
    case "$opt" in
        1) doc_full_scan;;
        2) doc_network_screen;;
        3) doc_firewall_screen;;
        4) doc_core_screen;;
        5) doc_services_screen;;
        6) doc_safe_repair;;
        7) doc_export_report;;
        0|'') kill "$STATS_PID" 2>/dev/null; clear; exit 0;;
        *) echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1;;
    esac
done
