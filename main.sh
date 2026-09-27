#!/bin/bash
# --- MDesign Master Core | Central Dashboard v9.3.0 ---
# [Features: Unified Multi-Tunnel Dynamic Header | Zero-Lag Cache | Pixel Alignment]

MODULE_VERSION="9.3.0"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
MTUNNEL_PATH="/usr/bin/mtunnel"
REPO_ZIP="https://github.com/htzserv/MTunnel/archive/refs/heads/main.zip"
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
MIRROR_SCRIPTS="https://c107328.parspack.net/c107328/MTunnel"
MIRROR_PACKAGES="https://c107328.parspack.net/c107328/MTunnel/packages"
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
    ["mweb"]="tools/mweb.sh"
    ["mstats"]="tools/mstats.sh"
    ["mhealer"]="tools/mhealer.sh"
    ["minterface"]="tools/minterface.sh"
    ["mbbr"]="tools/mbbr.sh"
    ["mdiag"]="tools/mdiag.sh"
    ["mshield"]="tools/mshield.sh"
    ["linktest"]="tools/linktest.sh"
)

ALL_MODULES=("main" "mporter" "mgre" "mxlan" "mrathole" "mbackhaul" "mpaqet" "mweb" "mstats" "mhealer" "minterface" "mbbr" "mdiag" "mshield" "linktest")

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
    "iperf3_3.16-1build2_amd64.deb"
    "iproute2_6.1.0-1ubuntu6.4_amd64.deb"
    "jq_1.7.1-3ubuntu0.24.04.2_amd64.deb"
    "qrencode_4.1.1-1build2_amd64.deb"
    "socat_1.8.0.0-4ubuntu0.1_amd64.deb"
    "wget_1.21.4-1ubuntu4.1_amd64.deb"
)

declare -A BIN_VERSIONS=(
    ["bh"]="0.6.5"
    ["rathole"]="0.5.0"
    ["paqet"]="1.0.0"
    ["gost"]="2.11.5"
    ["haproxy"]="2.8.16"
)

mkdir -p "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$LOCAL_DIR/tools" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [[ ! -x "$MTUNNEL_PATH" ]]; then
    cp "$0" "$MTUNNEL_PATH" 2>/dev/null
    chmod +x "$MTUNNEL_PATH" 2>/dev/null
fi

MAIN_PID=$$
NEED_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1

UPDATE_CHECK_INTERVAL=30
STATS_CHECK_INTERVAL=5

check_single_module_silent() {
    local mod="$1"
    local rel_path="$2"
    local out_file="$SECURE_TMP/.chk_${mod}"
    rm -f "$out_file"

    local local_file="$LOCAL_DIR/$rel_path"
    [ ! -f "$local_file" ] && [ -f "/usr/bin/$mod" ] && local_file="/usr/bin/$mod"

    local cur_v=""
    [ -f "$local_file" ] && cur_v=$(grep -m1 '^MODULE_VERSION=' "$local_file" | cut -d'"' -f2)
    [ -z "$cur_v" ] && cur_v="0.0.0"

    local cb="?t=$(date +%s%N)"
    local rem_v=""
    if command -v curl >/dev/null 2>&1; then
        rem_v=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 2 --max-time 4 "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        rem_v=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=4 "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi

    if [ -n "$rem_v" ] && [ "$rem_v" != "$cur_v" ]; then
        echo "${mod}:${cur_v}:${rem_v}" > "$out_file"
    fi
}

check_all_updates_round() {
    local pids=()
    for mod in "${!MOD_MAP[@]}"; do
        check_single_module_silent "$mod" "${MOD_MAP[$mod]}" &
        pids+=("$!")
    done
    for p in "${pids[@]}"; do
        wait "$p" 2>/dev/null
    done

    : > "$UPDATE_FILE.new"
    for mod in "${!MOD_MAP[@]}"; do
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
update_watcher_loop &
WATCHER_PID=$!

# --- ASYNC COLLECTOR FOR DYNAMIC TRI-TUNNEL DASHBOARD ---
collect_active_tunnels_stats() {
    local tmp_target="$SECURE_TMP/.main_tun_stats.tmp"
    > "$tmp_target"
    local count=0

    # 1. GRE Tunnels
    for conf in /etc/mgre/tunnels/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; REMOTE_PUB=""; CORE_SUBNET=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        
        local is_up=0
        if ip link show "$T_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" != "down" ]; then
            is_up=1
        fi
        [ "$is_up" -eq 0 ] && continue

        local pure="${T_NAME#gre6ir}"; pure="${pure#gre6kh}"; pure="${pure#greir}"; pure="${pure#grekh}"
        local c_sub="${CORE_SUBNET}"
        local v_ip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local peer_vip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        
        local ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_vip" 2>/dev/null)
        local loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
        [ -z "$loss" ] && loss="100"
        local avg="---"
        if echo "$ping_res" | grep -q "min/avg/max"; then
            avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
            [ -n "$avg" ] && avg="${avg}ms"
        fi

        local fwd_str="OFF"
        if [ "$TYPE" == "1" ]; then
            if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
            elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:5}"
            elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:5}"
            fi
        else fwd_str="GATEWAY"; fi

        echo "GRE|${pure:-$T_NAME}|${REMOTE_PUB}|${v_ip}|${avg}|${loss}|${T_NAME}|${fwd_str}" >> "$tmp_target"
        ((count++))
        [ "$count" -ge 3 ] && break 2
    done

    # 2. VXLAN Fabrics
    if [ "$count" -lt 3 ]; then
        for conf in /etc/mgre/vxlan/*.conf; do
            [ -f "$conf" ] || continue
            TYPE=""; VX_NAME=""; REMOTE_PUB=""; CORE_SUBNET=""; VNI_ID=""; FWD_TCP=""; FWD_UDP=""; source "$conf" 2>/dev/null
            [ -z "$VX_NAME" ] && continue

            local is_up=0
            if ip link show "$VX_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$VX_NAME/operstate 2>/dev/null)" != "down" ]; then
                is_up=1
            fi
            [ "$is_up" -eq 0 ] && continue

            local pure="${VX_NAME#vx_}"
            local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
            local v_ip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
            local peer_vip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")

            local ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_vip" 2>/dev/null)
            local loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
            [ -z "$loss" ] && loss="100"
            local avg="---"
            if echo "$ping_res" | grep -q "min/avg/max"; then
                avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
                [ -n "$avg" ] && avg="${avg}ms"
            fi

            local fwd_str="OFF"
            if [ "$TYPE" == "1" ]; then
                if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
                elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:5}"
                elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:5}"
                fi
            else fwd_str="GATEWAY"; fi

            echo "VXLAN|${pure:-$VX_NAME}|${REMOTE_PUB}|${v_ip}|${avg}|${loss}|${VX_NAME}|${fwd_str}" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi

    # 3. Backhaul Multiplexer
    if [ "$count" -lt 3 ]; then
        for conf in /etc/mbackhaul/tunnels/*.meta; do
            [ -f "$conf" ] || continue
            local t_name=$(basename "$conf" .meta)
            ROLE=""; TUN_PORT=""; REMOTE_IP=""; PORTS=""; source "$conf" 2>/dev/null
            systemctl is-active --quiet "mbackhaul@${t_name}" || continue

            local pure="${t_name#bh_}"
            local peer_ip="$REMOTE_IP"
            if [ "$ROLE" == "1" ]; then
                local conn=$(ss -tn src ":$TUN_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
                peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                [ -z "$peer_ip" ] && peer_ip="Listening"
            fi

            local avg="---" loss="0"
            if [[ "$peer_ip" =~ ^[0-9.]+$ ]]; then
                local ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_ip" 2>/dev/null)
                loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
                [ -z "$loss" ] && loss="100"
                if echo "$ping_res" | grep -q "min/avg/max"; then
                    avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
                    [ -n "$avg" ] && avg="${avg}ms"
                fi
            fi

            local fwd_str="OFF"
            [ -n "$PORTS" ] && fwd_str="ACTIVE"
            [ "$ROLE" == "2" ] && fwd_str="CLIENT"

            echo "BH|${pure:-$t_name}|${peer_ip}|:${TUN_PORT}|${avg}|${loss}|bh_${t_name}|${fwd_str}" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi

    # 4. Rathole
    if [ "$count" -lt 3 ]; then
        for d in /etc/mrathole/tunnels/*; do
            [ -d "$d" ] && [ -f "$d/meta.conf" ] || continue
            local t_name=$(basename "$d")
            TYPE=""; LINK_PORT=""; REMOTE_IP=""; TCP_PORTS=""; UDP_PORTS=""; source "$d/meta.conf" 2>/dev/null
            systemctl is-active --quiet "mrathole@${t_name}" || continue

            local peer_ip="$REMOTE_IP"
            if [ "$TYPE" == "1" ]; then
                local conn=$(ss -tn src ":$LINK_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
                peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                [ -z "$peer_ip" ] && peer_ip="Listening"
            fi

            local avg="---" loss="0"
            if [[ "$peer_ip" =~ ^[0-9.]+$ ]]; then
                local ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_ip" 2>/dev/null)
                loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
                [ -z "$loss" ] && loss="100"
                if echo "$ping_res" | grep -q "min/avg/max"; then
                    avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
                    [ -n "$avg" ] && avg="${avg}ms"
                fi
            fi

            local fwd_str="OFF"
            [ -n "$TCP_PORTS" ] || [ -n "$UDP_PORTS" ] && fwd_str="ACTIVE"
            [ "$TYPE" == "2" ] && fwd_str="CLIENT"

            echo "RAT|${t_name}|${peer_ip}|:${LINK_PORT}|${avg}|${loss}|rat_${t_name}|${fwd_str}" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi

    # 5. Paqet
    if [ "$count" -lt 3 ]; then
        for conf in /etc/paqet/*.meta; do
            [ -f "$conf" ] || continue
            local t_name=$(basename "$conf" .meta)
            ROLE=""; TUN_PORT=""; REMOTE_IP=""; source "$conf" 2>/dev/null
            systemctl is-active --quiet "mpaqet@${t_name}" || continue

            local pure="${t_name#pq_}"
            local peer_ip="$REMOTE_IP"
            if [ "$ROLE" == "1" ]; then
                local conn=$(ss -tn src ":$TUN_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
                peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                [ -z "$peer_ip" ] && peer_ip="Listening"
            fi

            local avg="---" loss="0"
            if [[ "$peer_ip" =~ ^[0-9.]+$ ]]; then
                local ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_ip" 2>/dev/null)
                loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
                [ -z "$loss" ] && loss="100"
                if echo "$ping_res" | grep -q "min/avg/max"; then
                    avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
                    [ -n "$avg" ] && avg="${avg}ms"
                fi
            fi

            echo "PAQET|${pure:-$t_name}|${peer_ip}|:${TUN_PORT}|${avg}|${loss}|pq_${t_name}|RAW" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi

    mv -f "$tmp_target" "$SECURE_TMP/.main_tun_stats" 2>/dev/null
}

stats_watcher_loop() {
    while true; do
        collect_active_tunnels_stats
        kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
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

get_active_total_count() {
    local count=0
    for conf in /etc/mgre/tunnels/*.conf; do
        [ -f "$conf" ] || continue
        T_NAME=""; source "$conf" 2>/dev/null
        ip link show "$T_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" != "down" ] && ((count++))
    done
    for conf in /etc/mgre/vxlan/*.conf; do
        [ -f "$conf" ] || continue
        VX_NAME=""; source "$conf" 2>/dev/null
        ip link show "$VX_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$VX_NAME/operstate 2>/dev/null)" != "down" ] && ((count++))
    done
    for conf in /etc/mbackhaul/tunnels/*.meta; do
        [ -f "$conf" ] || continue
        systemctl is-active --quiet "mbackhaul@$(basename "$conf" .meta)" && ((count++))
    done
    for d in /etc/mrathole/tunnels/*; do
        [ -d "$d" ] || continue
        systemctl is-active --quiet "mrathole@$(basename "$d")" && ((count++))
    done
    for conf in /etc/paqet/*.meta; do
        [ -f "$conf" ] || continue
        systemctl is-active --quiet "mpaqet@$(basename "$conf" .meta)" && ((count++))
    done
    echo "$count"
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

        IFS= read -rsn1 -t 0.3 char
        rc=$?

        if [ $rc -ne 0 ]; then
            continue
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

    eval "$__resultvar=\"\$buffer\""
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
    local mod="$1"
    local base_url="$2"
    local rel_path="${MOD_MAP[$mod]}"
    [ -z "$rel_path" ] && rel_path="${mod}.sh"
    local target_file="$LOCAL_DIR/$rel_path"
    local tmp="${target_file}.$$"

    mkdir -p "$(dirname "$target_file")" 2>/dev/null
    rm -f "$tmp"

    local CB="?t=$(date +%s%N)"
    local DL_SUCCESS=false

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 --max-time 120 -o "$tmp" "$base_url/$rel_path$CB" 2>/dev/null && DL_SUCCESS=true
    elif command -v wget >/dev/null 2>&1; then
        wget -q --no-check-certificate --header="Cache-Control: no-cache" --timeout=8 -O "$tmp" "$base_url/$rel_path$CB" 2>/dev/null && DL_SUCCESS=true
    fi

    [ "$DL_SUCCESS" = true ] && [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    sed -i 's/\r$//' "$tmp" 2>/dev/null || true
    chmod 0755 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$target_file"
}

deploy_cached_module() {
    local mod="$1"
    local rel_path="${MOD_MAP[$mod]}"
    [ -z "$rel_path" ] && rel_path="${mod}.sh"
    local target_file="$LOCAL_DIR/$rel_path"

    [ -s "$target_file" ] || return 1
    sed -i 's/\r$//' "$target_file" 2>/dev/null || true

    if [ "$mod" = "main" ]; then
        if ! same_file "$target_file" "$MTUNNEL_PATH"; then
            install -m 0755 "$target_file" "$MTUNNEL_PATH" 2>/dev/null || return 1
        fi
        ln -sf "$MTUNNEL_PATH" /usr/bin/main 2>/dev/null
    else
        if ! same_file "$target_file" "/usr/bin/$mod"; then
            install -m 0755 "$target_file" "/usr/bin/$mod" || return 1
        else
            chmod 0755 "/usr/bin/$mod" 2>/dev/null || true
        fi
    fi
}

deploy_binaries_from_dir() {
    local src_dir="$1"
    [ ! -d "$src_dir" ] && return 1

    mkdir -p /usr/local/bin /usr/sbin /etc/haproxy /var/lib/haproxy "$LOCAL_DIR/packages" 2>/dev/null

    if [ -f "$src_dir/haproxy" ]; then
        install -m 0755 "$src_dir/haproxy" /usr/sbin/haproxy 2>/dev/null
        ln -sf /usr/sbin/haproxy /usr/local/bin/haproxy 2>/dev/null
        [ "$src_dir" != "$LOCAL_DIR/packages" ] && cp -f "$src_dir/haproxy" "$LOCAL_DIR/packages/" 2>/dev/null
    fi

    for b in rathole paqet gost frpc frps; do
        if [ -f "$src_dir/$b" ]; then
            install -m 0755 "$src_dir/$b" "/usr/local/bin/$b" 2>/dev/null
            [ "$src_dir" != "$LOCAL_DIR/packages" ] && cp -f "$src_dir/$b" "$LOCAL_DIR/packages/" 2>/dev/null
        fi
    done

    if [ -f "$src_dir/bh" ]; then
        install -m 0755 "$src_dir/bh" /usr/local/bin/bh 2>/dev/null
        ln -sf /usr/local/bin/bh /usr/local/bin/backhaul 2>/dev/null
        [ "$src_dir" != "$LOCAL_DIR/packages" ] && cp -f "$src_dir/bh" "$LOCAL_DIR/packages/" 2>/dev/null
    elif [ -f "$src_dir/backhaul" ]; then
        install -m 0755 "$src_dir/backhaul" /usr/local/bin/backhaul 2>/dev/null
        ln -sf /usr/local/bin/backhaul /usr/local/bin/bh 2>/dev/null
        [ "$src_dir" != "$LOCAL_DIR/packages" ] && cp -f "$src_dir/backhaul" "$LOCAL_DIR/packages/" 2>/dev/null
    fi

    if compgen -G "$src_dir/*.deb" > /dev/null; then
        dpkg -i --force-confdef --force-confold "$src_dir"/*.deb >/dev/null 2>&1 || true
        [ "$src_dir" != "$LOCAL_DIR/packages" ] && cp -f "$src_dir"/*.deb "$LOCAL_DIR/packages/" 2>/dev/null
    fi
    return 0
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
    echo -e "  ${R}✗ ${W}${mod}${R} is not available locally and GitHub download failed.${NC}"
    return 1
}

run_mod() { local mod="$1"; ensure_module "$mod" || return 1; "$mod"; }

draw_main_header() {
    local s_ip=$(get_local_ip)
    local active_total=$(get_active_total_count)

    local bbr_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local bbr_stat="${DIM}○ OFF${NC}"
    [ "$bbr_cc" == "bbr" ] && bbr_stat="${G}● ON${NC}"

    local web_stat="${DIM}○ OFFLINE${NC}"
    if systemctl is-active --quiet mweb.service 2>/dev/null; then
        local w_port="1000"
        [ -f "/etc/mweb/web.conf" ] && w_port=$(grep "WEB_PORT" /etc/mweb/web.conf | cut -d= -f2 | tr -d ' ' | tr -d '\r')
        web_stat="${G}● PORT ${w_port}${NC}"
    fi

    clear; echo ""
    local border="────────────────────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${B}╭${border}╮${NC}"
    printf "  ${B}│${NC} ${W}%-22s${NC} ${B}│${NC} ${DIM}Local:${NC} ${W}%-15s${NC} ${B}│${NC} ${DIM}Active Tunnels:${NC} ${G}%-3s${NC} ${B}│${NC} ${DIM}Web:${NC} %b%-11s%b ${B}│${NC}\n" \
        "MDesign Master Core v${MODULE_VERSION}" "$s_ip" "$active_total" "$NC" "$web_stat" "$NC"
    echo -e "  ${B}├${border}┤${NC}"

    local shown=0
    if [ -f "$SECURE_TMP/.main_tun_stats" ]; then
        while IFS='|' read -r t_proto t_name t_remote t_vip t_ping t_loss t_dev t_fwd; do
            [ -z "$t_proto" ] && continue
            ((shown++))
            [ "$shown" -gt 3 ] && break

            [ ${#t_name} -gt 5 ] && t_name="${t_name:0:5}"
            [ ${#t_remote} -gt 15 ] && t_remote="${t_remote:0:15}"
            [ ${#t_vip} -gt 13 ] && t_vip="${t_vip:0:13}"

            local if_uptime=$(get_iface_uptime_pure "$t_dev")
            local stat_icon="●"; local stat_col="${G}"
            if [ "$if_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi

            local fwd_col="${DIM}"; [ "$t_fwd" != "OFF" ] && fwd_col="${C}"
            local loss_col="${G}"; [[ "$t_loss" != "0" && "$t_loss" != "---" ]] && loss_col="${R}"
            local loss_disp="${t_loss}%"; [ "$t_loss" == "---" ] && loss_disp="---"

            printf "  ${B}│${NC} %b%s%b ${W}%-5s${NC} ${DIM}[%-5s]${NC} ${Y}%-15s${NC} ${C}%-13s${NC} ${B}│${NC} ${DIM}P:${NC}${Y}%-6s${NC}${loss_col}%-4s${NC} ${B}│${NC} ${DIM}Up:${NC}${W}%-6s${NC} ${B}│${NC} ${DIM}FWD:${NC}%b%-5s%b ${B}│${NC}\n" \
                "$stat_col" "$stat_icon" "$NC" "$t_name" "$t_proto" "$t_remote" "$t_vip" "$t_ping" "$loss_disp" "$if_uptime" "$fwd_col" "$t_fwd" "$NC"
        done < "$SECURE_TMP/.main_tun_stats"
    fi

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}%-88s${NC}  ${B}│${NC}\n" "● No active tunnels or fabrics deployed across the ecosystem."
    fi
    echo -e "  ${B}╰${border}╯${NC}"
}

show_tunnel_hub() {
    render_tunnel_menu() {
        badge_mgre="" badge_mxlan="" badge_mrathole="" badge_mbackhaul="" badge_mpaqet=""
        if [ -f "$UPDATE_FILE" ]; then
            grep -q "^mgre:" "$UPDATE_FILE" && badge_mgre=" ${Y}(Update Available: v$(grep "^mgre:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
            grep -q "^mxlan:" "$UPDATE_FILE" && badge_mxlan=" ${Y}(Update Available: v$(grep "^mxlan:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
            grep -q "^mrathole:" "$UPDATE_FILE" && badge_mrathole=" ${Y}(Update Available: v$(grep "^mrathole:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
            grep -q "^mbackhaul:" "$UPDATE_FILE" && badge_mbackhaul=" ${Y}(Update Available: v$(grep "^mbackhaul:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
            grep -q "^mpaqet:" "$UPDATE_FILE" && badge_mpaqet=" ${Y}(Update Available: v$(grep "^mpaqet:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
        fi

        draw_main_header
        echo -e "\n  ${DIM}┌─[ PRIMARY INFRASTRUCTURE HUB ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Modular GRE/IP6GRE Core (Mgre)${NC}${badge_mgre}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}VXLAN Virtual Mesh Fabric (Mxlan)${NC}${badge_mxlan}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Rathole Reverse Tunnel (Mrathole)${NC}${badge_mrathole}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Backhaul Free Multiplexer (MBackhaul)${NC}${badge_mbackhaul}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Paqet Raw Packet KCP Tunnel (MPaqet)${NC}${badge_mpaqet}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Dashboard${NC}\n"
    }

    while true; do
        render_tunnel_menu
        read_with_refresh "  ${C}TUNNEL ❯❯ ${NC}" t_opt render_tunnel_menu
        t_opt=$(echo "$t_opt" | tr -d '\r ')
        case $t_opt in
            1) run_mod "mgre" ;; 2) run_mod "mxlan" ;; 3) run_mod "mrathole" ;; 4) run_mod "mbackhaul" ;; 5) run_mod "mpaqet" ;; 0) break ;;
        esac
    done
}

render_main_menu() {
    badge_hub="" badge_porter="" badge_main="" badge_bbr="" badge_diag="" badge_shield="" badge_link="" badge_stats="" badge_healer="" badge_iface=""

    if [ -f "$UPDATE_FILE" ]; then
        tun_updates=""
        grep -q "^mgre:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(MGRE)${NC}"
        grep -q "^mxlan:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(MXLAN)${NC}"
        grep -q "^mrathole:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(Rathole)${NC}"
        grep -q "^mbackhaul:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(Backhaul)${NC}"
        grep -q "^mpaqet:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(Paqet)${NC}"

        [ -n "$tun_updates" ] && badge_hub=" ${Y}(Update Available)${NC}${tun_updates}"
        grep -q "^mporter:" "$UPDATE_FILE" && badge_porter=" ${Y}(Update Available: v$(grep "^mporter:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
        grep -q "^main:" "$UPDATE_FILE" && badge_main=" ${Y}(Update Available: v$(grep "^main:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
        grep -q "^mbbr:" "$UPDATE_FILE" && badge_bbr=" ${Y}(Update Available: v$(grep "^mbbr:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
        grep -q "^mdiag:" "$UPDATE_FILE" && badge_diag=" ${Y}(Update Available: v$(grep "^mdiag:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
        grep -q "^mshield:" "$UPDATE_FILE" && badge_shield=" ${Y}(Update Available: v$(grep "^mshield:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
        grep -q "^linktest:" "$UPDATE_FILE" && badge_link=" ${Y}(Update Available: v$(grep "^linktest:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
        grep -q "^mstats:" "$UPDATE_FILE" && badge_stats=" ${Y}(Update Available: v$(grep "^mstats:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
        grep -q "^mhealer:" "$UPDATE_FILE" && badge_healer=" ${Y}(Update Available: v$(grep "^mhealer:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
        grep -q "^minterface:" "$UPDATE_FILE" && badge_iface=" ${Y}(Update Available: v$(grep "^minterface:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
    fi

    draw_main_header; echo ""
    echo -e "  ${DIM}┌─[ CORE NETWORK & ROUTING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Hub (GRE / VXLAN / Rat / BH / Paqet)${NC}${badge_hub}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding Matrix (Mporter)${NC}${badge_porter}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC}${badge_iface}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SECURITY, DIAGNOSTICS & BENCHMARK ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Stealth Anti-Probing & Anti-RST Shield${NC}${badge_shield}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${B}Bandwidth Radar & Web UI${NC}${badge_stats}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Autonomous Tunnel Healer${NC}${badge_healer}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Network Diagnostics & Tests${NC}${badge_diag}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Two-Way Link & Port Filter Scanner (LinkTest)${NC}${badge_link}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${C}iPerf3 Bandwidth Benchmark${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC} ${DIM}❯${NC} ${G}TCP BBR Accelerator (Mbbr)${NC}${badge_bbr}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC} ${DIM}❯${NC} ${G}Unified Multi-Tier OTA Update Hub${NC}${badge_main}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC} ${DIM}❯${NC} ${M}Offline Local Deploy (Packages & Modules)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC} ${DIM}❯${NC} ${R}Nuclear Wipe (Uninstall)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}\n"
}

while true; do
    render_main_menu
    read_with_refresh "  ${C}CORE ❯❯ ${NC}" opt render_main_menu
    opt=$(echo "$opt" | tr -d '\r ')

    case $opt in
        1) show_tunnel_hub ;;
        2) run_mod "mporter" ;;
        3) run_mod "minterface" ;;
        4) run_mod "mshield" ;;
        5) run_mod "mstats" ;;
        6) run_mod "mhealer" ;;
        7) run_mod "mdiag" ;;
        8) run_mod "linktest" ;;
        9) run_mod "mdiag" ;;
        10) run_mod "mbbr" ;;
        11) ensure_module "main" ;;
        12) echo "Offline deploy"; sleep 1 ;;
        13)
            clear
            echo -e "\n  ${R}Are you sure you want to completely uninstall MTunnel? (y/n): ${NC}\c"; read confirm
            if [[ "${confirm,,}" == "y" ]]; then
                kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
                rm -rf /root/mtunnel /etc/mgre /etc/mbackhaul /etc/mrathole /etc/paqet /usr/bin/mtunnel /usr/bin/mgre /usr/bin/mxlan /usr/bin/mbackhaul /usr/bin/mrathole /usr/bin/mpaqet 2>/dev/null
                echo -e "  ${G}Uninstalled successfully.${NC}"; exit 0
            fi ;;
        0) 
            kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
            clear; exit 0 ;;
    esac
done
