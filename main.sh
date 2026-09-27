#!/bin/bash
# --- MDesign Master Core | Central Dashboard v9.6.6 ---
# [Features: Fixed Syntax Error | Balanced Case Blocks | Expanded 106-Col Header]

MODULE_VERSION="9.6.6"

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
STATS_CHECK_INTERVAL=10

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
        local f="$SECURE_TMP/.chk_${mod}"
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

collect_active_tunnels_stats() {
    local tmp_target="$SECURE_TMP/.main_tun_stats.tmp"
    > "$tmp_target"
    local count=0

    # 1. GRE
    for conf in /etc/mgre/tunnels/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; REMOTE_PUB=""; CORE_SUBNET=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        
        ip link show "$T_NAME" >/dev/null 2>&1 || continue
        [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" == "down" ] && continue

        local pure="${T_NAME#gre6ir}"; pure="${pure#gre6kh}"; pure="${pure#greir}"; pure="${pure#grekh}"
        local c_sub="${CORE_SUBNET}"
        local peer_vip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        
        local vip_stat="OFF"
        [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null && vip_stat="+${MAX_IPS}"

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
            TYPE=""; VX_NAME=""; REMOTE_PUB=""; CORE_SUBNET=""; VNI_ID=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; source "$conf" 2>/dev/null
            [ -z "$VX_NAME" ] && continue

            ip link show "$VX_NAME" >/dev/null 2>&1 || continue
            [ "$(cat /sys/class/net/$VX_NAME/operstate 2>/dev/null)" == "down" ] && continue

            local pure="${VX_NAME#vx_}"
            local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
            local peer_vip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")

            local vip_stat="OFF"
            [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null && vip_stat="+${MAX_IPS}"

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

            echo "PAQET|${pure:-$t_name}|${peer_ip}|OFF|${avg}|${loss}|pq_${t_name}|RAW" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi

    mv -f "$tmp_target" "$SECURE_TMP/.main_tun_stats" 2>/dev/null
}

stats_watcher_loop() {
    while true; do
        collect_active_tunnels_stats
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

show_ota_update_hub() {
    render_ota_menu() {
        clear; echo ""
        echo -e "  ${B}╭──────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC} ${W}MDesign Ecosystem Central Updater${NC}                           ${B}│${NC}"
        echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"

        echo -e "\n  ${DIM}┌─[ SCRIPT CORE ENGINE UPDATES ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Sync All Scripts from Official GitHub${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Sync All Scripts from Iranian Mirror (ParsPack)${NC}"

        local main_sub_badge=""
        if [ -f "$UPDATE_FILE" ]; then
            local m_line=$(grep "^main:" "$UPDATE_FILE")
            if [ -n "$m_line" ]; then
                local o_v=$(echo "$m_line" | cut -d: -f2)
                local n_v=$(echo "$m_line" | cut -d: -f3)
                main_sub_badge="  ${Y}(v${o_v} ➔ v${n_v})${NC}"
            fi
        fi
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Update Master Core Dashboard (Main Script Only)${NC}${main_sub_badge}"

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
        echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${M}Manual Code Paste (Raw Editor)${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Dashboard${NC}\n"
    }

    while true; do
        render_ota_menu
        read_with_refresh "  ${C}OTA-HUB ❯❯ ${NC}" ota_opt render_ota_menu
        ota_opt=$(echo "$ota_opt" | tr -d '\r ')

        case $ota_opt in
            1|2)
                clear
                local s_url="$REPO_SCRIPTS"
                local sync_name="OFFICIAL GITHUB"
                [ "$ota_opt" == "2" ] && s_url="$MIRROR_SCRIPTS" && sync_name="IRANIAN MIRROR (PARSPACK)"

                echo -e "\n  ${DIM}┌─[ SYNCING ALL SCRIPTS FROM ${sync_name} ]${NC}\n"

                local total_mods=${#ALL_MODULES[@]}
                local current=0
                local width=30

                for mod in "${ALL_MODULES[@]}"; do
                    ((current++))
                    local rel_p="${MOD_MAP[$mod]}"
                    
                    local percent=$(( current * 100 / total_mods ))
                    local filled=$(( percent * width / 100 ))
                    local empty=$(( width - filled ))
                    
                    local bar_f=$(printf "%${filled}s" "" | tr ' ' '#')
                    local bar_e=$(printf "%${empty}s" "" | tr ' ' '-')

                    if download_file_to_cache "$mod" "$s_url"; then
                        deploy_cached_module "$mod"
                        local n_v=$(grep -m1 '^MODULE_VERSION=' "$LOCAL_DIR/$rel_p" 2>/dev/null | cut -d'"' -f2)
                        n_v="${n_v:-Unknown}"
                        
                        local ver_str=" (v${n_v})"
                        local plain_len=$(( ${#mod} + ${#ver_str} ))
                        local pad_len=$(( 26 - plain_len ))
                        [ "$pad_len" -lt 0 ] && pad_len=0
                        local padding=$(printf '%*s' "$pad_len" "")

                        printf "  ${G}✔${NC} ${W}%s${NC}${Y}%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$mod" "$ver_str" "$padding" "$bar_f" "$bar_e" "$percent"
                    else
                        local ver_str=" (FAILED)"
                        local plain_len=$(( ${#mod} + ${#ver_str} ))
                        local pad_len=$(( 26 - plain_len ))
                        [ "$pad_len" -lt 0 ] && pad_len=0
                        local padding=$(printf '%*s' "$pad_len" "")

                        printf "  ${R}✖${NC} ${R}%s%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$mod" "$ver_str" "$padding" "$bar_f" "$bar_e" "$percent"
                    fi
                done
                
                > "$UPDATE_FILE"
                echo -e "\n\n  ${G}● Script sync finished. Press Enter to reload core...${NC}\n"
                read dummy
                kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
                exec "$MTUNNEL_PATH"
                ;;

            3)
                clear
                echo -e "\n  ${DIM}┌─[ UPDATING MASTER CORE (MAIN.SH) ]${NC}\n"
                local width=30
                local bar_full=$(printf "%${width}s" "" | tr ' ' '#')

                if download_file_to_cache "main" "$REPO_SCRIPTS"; then
                    deploy_cached_module "main"
                    local m_new_v=$(grep -m1 '^MODULE_VERSION=' "$LOCAL_DIR/main.sh" 2>/dev/null | cut -d'"' -f2)
                    m_new_v="${m_new_v:-Unknown}"
                    
                    local ver_str=" (v${m_new_v})"
                    local plain_len=$(( 4 + ${#ver_str} ))
                    local pad_len=$(( 26 - plain_len ))
                    [ "$pad_len" -lt 0 ] && pad_len=0
                    local padding=$(printf '%*s' "$pad_len" "")

                    printf "  ${G}✔${NC} ${W}main${NC}${Y}%s${NC}%s ${W}[%s] 100%%${NC}\n" "$ver_str" "$padding" "$bar_full"
                    echo -e "\n\n  ${G}● Master Core successfully updated! Reloading...${NC}\n"
                    sleep 1.5
                    kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
                    exec "$MTUNNEL_PATH"
                else
                    local ver_str=" (FAILED)"
                    local plain_len=$(( 4 + ${#ver_str} ))
                    local pad_len=$(( 26 - plain_len ))
                    [ "$pad_len" -lt 0 ] && pad_len=0
                    local padding=$(printf '%*s' "$pad_len" "")
                    local bar_empty=$(printf "%${width}s" "" | tr ' ' '-')

                    printf "  ${R}✖${NC} ${R}main%s${NC}%s ${W}[${DIM}%s${W}]   0%%${NC}\n" "$ver_str" "$padding" "$bar_empty"
                    echo -ne "\n\n  ${DIM}Press Enter to return...${NC}\n"; read dummy
                fi
                ;;

            4|5)
                clear
                local target_name="OFFICIAL GITHUB"
                local pkg_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/packages"
                if [ "$ota_opt" == "5" ]; then
                    target_name="PARSPACK IRANIAN MIRROR"
                    pkg_url="$MIRROR_PACKAGES"
                fi

                echo -e "\n  ${DIM}┌─[ FETCHING BINARY CORES FROM ${target_name} ]${NC}\n"
                mkdir -p "$LOCAL_DIR/packages" /usr/local/bin /usr/sbin 2>/dev/null
                local bins=("bh" "rathole" "paqet" "gost" "haproxy")
                local CB="?t=$(date +%s)"
                
                local total_bins=${#bins[@]}
                local current=0
                local width=30

                for b in "${bins[@]}"; do
                    ((current++))
                    local t_out="$LOCAL_DIR/packages/$b"
                    local dl_ok=false
                    
                    local percent=$(( current * 100 / total_bins ))
                    local filled=$(( percent * width / 100 ))
                    local empty=$(( width - filled ))
                    
                    local bar_f=$(printf "%${filled}s" "" | tr ' ' '#')
                    local bar_e=$(printf "%${empty}s" "" | tr ' ' '-')

                    if command -v curl >/dev/null 2>&1; then
                        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 -o "$t_out" "$pkg_url/$b$CB" 2>/dev/null && dl_ok=true
                    elif command -v wget >/dev/null 2>&1; then
                        wget -q --no-check-certificate --header="Cache-Control: no-cache" --timeout=8 -O "$t_out" "$pkg_url/$b$CB" 2>/dev/null && dl_ok=true
                    fi

                    local b_ver="${BIN_VERSIONS[$b]:-Core}"
                    local ver_str=" (v${b_ver})"
                    local plain_len=$(( ${#b} + ${#ver_str} ))
                    local pad_len=$(( 26 - plain_len ))
                    [ "$pad_len" -lt 0 ] && pad_len=0
                    local padding=$(printf '%*s' "$pad_len" "")

                    if [ "$dl_ok" = true ] && [ -s "$t_out" ]; then
                        chmod +x "$t_out"
                        if [ "$b" == "haproxy" ]; then
                            install -m 0755 "$t_out" /usr/sbin/haproxy 2>/dev/null
                            ln -sf /usr/sbin/haproxy /usr/local/bin/haproxy 2>/dev/null
                        elif [ "$b" == "bh" ]; then
                            install -m 0755 "$t_out" /usr/local/bin/bh 2>/dev/null
                            ln -sf /usr/local/bin/bh /usr/local/bin/backhaul 2>/dev/null
                        else
                            install -m 0755 "$t_out" "/usr/local/bin/$b" 2>/dev/null
                        fi

                        printf "  ${G}✔${NC} ${W}%s${NC}${Y}%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$b" "$ver_str" "$padding" "$bar_f" "$bar_e" "$percent"
                    else
                        local ver_str=" (FAILED)"
                        local plain_len=$(( ${#b} + ${#ver_str} ))
                        local pad_len=$(( 26 - plain_len ))
                        [ "$pad_len" -lt 0 ] && pad_len=0
                        local padding=$(printf '%*s' "$pad_len" "")

                        printf "  ${R}✖${NC} ${R}%s%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$b" "$ver_str" "$padding" "$bar_f" "$bar_e" "$percent"
                    fi
                done

                echo -e "\n\n  ${G}● Binary cores deployed successfully.${NC}\n"
                echo -ne "  ${DIM}Press Enter to return...${NC}\n"; read dummy
                ;;

            6|7)
                clear
                local target_name="OFFICIAL GITHUB"
                local pkg_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/packages"
                if [ "$ota_opt" == "7" ]; then
                    target_name="PARSPACK IRANIAN MIRROR"
                    pkg_url="$MIRROR_PACKAGES"
                fi

                echo -e "\n  ${DIM}┌─[ FETCHING ALL PREREQUISITES & PACKAGES FROM ${target_name} ]${NC}\n"
                mkdir -p "$LOCAL_DIR/packages" /usr/local/bin /usr/sbin 2>/dev/null
                local CB="?t=$(date +%s)"
                
                local total_pkgs=${#ALL_PACKAGES[@]}
                local current=0
                local width=30

                for item in "${ALL_PACKAGES[@]}"; do
                    ((current++))
                    local t_out="$LOCAL_DIR/packages/$item"
                    local dl_ok=false
                    
                    local percent=$(( current * 100 / total_pkgs ))
                    local filled=$(( percent * width / 100 ))
                    local empty=$(( width - filled ))
                    
                    bar_f=$(printf "%${filled}s" "" | tr ' ' '#')
                    bar_e=$(printf "%${empty}s" "" | tr ' ' '-')

                    if command -v curl >/dev/null 2>&1; then
                        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 -o "$t_out" "$pkg_url/$item$CB" 2>/dev/null && dl_ok=true
                    elif command -v wget >/dev/null 2>&1; then
                        wget -q --no-check-certificate --header="Cache-Control: no-cache" --timeout=8 -O "$t_out" "$pkg_url/$item$CB" 2>/dev/null && dl_ok=true
                    fi

                    local item_name="" item_ver=""
                    if [[ "$item" == *.deb ]]; then
                        item_name=$(echo "$item" | cut -d'_' -f1)
                        item_ver=$(echo "$item" | cut -d'_' -f2 | cut -d'-' -f1)
                    else
                        item_name="$item"
                        item_ver="${BIN_VERSIONS[$item]:-Core}"
                    fi

                    local ver_str=" (v${item_ver})"
                    local plain_len=$(( ${#item_name} + ${#ver_str} ))
                    local pad_len=$(( 26 - plain_len ))
                    [ "$pad_len" -lt 0 ] && pad_len=0
                    local padding=$(printf '%*s' "$pad_len" "")

                    if [ "$dl_ok" = true ] && [ -s "$t_out" ]; then
                        if [[ "$item" == *.deb ]]; then
                            dpkg -i --force-confdef --force-confold "$t_out" >/dev/null 2>&1 || true
                        else
                            chmod +x "$t_out"
                            if [ "$item" == "haproxy" ]; then
                                install -m 0755 "$t_out" /usr/sbin/haproxy 2>/dev/null
                                ln -sf /usr/sbin/haproxy /usr/local/bin/haproxy 2>/dev/null
                            elif [ "$item" == "bh" ]; then
                                install -m 0755 "$t_out" /usr/local/bin/bh 2>/dev/null
                                ln -sf /usr/local/bin/bh /usr/local/bin/backhaul 2>/dev/null
                            else
                                install -m 0755 "$t_out" "/usr/local/bin/$item" 2>/dev/null
                            fi
                        fi

                        printf "  ${G}✔${NC} ${W}%s${NC}${Y}%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$item_name" "$ver_str" "$padding" "$bar_f" "$bar_e" "$percent"
                    else
                        local ver_str=" (FAILED)"
                        local plain_len=$(( ${#item_name} + ${#ver_str} ))
                        local pad_len=$(( 26 - plain_len ))
                        [ "$pad_len" -lt 0 ] && pad_len=0
                        local padding=$(printf '%*s' "$pad_len" "")

                        printf "  ${R}✖${NC} ${R}%s%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$item_name" "$ver_str" "$padding" "$bar_f" "$bar_e" "$percent"
                    fi
                done

                echo -e "\n\n  ${G}● All prerequisite packages and cores deployed successfully.${NC}\n"
                echo -ne "  ${DIM}Press Enter to return...${NC}\n"; read dummy
                ;;

            8)
                clear
                echo -e "\n  ${DIM}┌─[ CUSTOM DIRECT LINK DEPLOYMENT ]${NC}\n"
                echo -ne "  ${C}●${NC} ${W}Enter Direct (.sh or .zip) URL: ${NC}"; read custom_url
                custom_url=$(echo "$custom_url" | tr -d '\r ')
                [ -z "$custom_url" ] && continue

                local tmp_dl="$SECURE_TMP/.custom_download.$$"
                rm -f "$tmp_dl"

                (
                    if command -v curl >/dev/null 2>&1; then
                        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 10 -o "$tmp_dl" "$custom_url" 2>/dev/null
                    elif command -v wget >/dev/null 2>&1; then
                        wget -q --no-check-certificate --header="Cache-Control: no-cache" --timeout=10 -O "$tmp_dl" "$custom_url" 2>/dev/null
                    fi
                ) &
                local pid=$!
                draw_progress_bar "$pid" "Downloading Custom Resource"
                wait "$pid" 2>/dev/null

                if [ -s "$tmp_dl" ]; then
                    if ! command -v unzip >/dev/null 2>&1; then
                        DEBIAN_FRONTEND=noninteractive apt-get update -y -q >/dev/null 2>&1
                        DEBIAN_FRONTEND=noninteractive apt-get install -y -q unzip >/dev/null 2>&1
                    fi

                    if command -v unzip >/dev/null 2>&1 && unzip -t "$tmp_dl" >/dev/null 2>&1; then
                        local t_dir="$(mktemp -d /tmp/custom-unzip.XXXXXX)"
                        unzip -q -o "$tmp_dl" -d "$t_dir" 2>/dev/null
                        
                        local r_root="$(find "$t_dir" -type f -name "main.sh" -exec dirname {} \; | head -n 1)"
                        
                        if [ -n "$r_root" ] && [ -d "$r_root" ]; then
                            cp -rf "$r_root"/* "$LOCAL_DIR/" 2>/dev/null
                            for m in "${ALL_MODULES[@]}"; do deploy_cached_module "$m" 2>/dev/null; done
                            
                            if [ -d "$r_root/packages" ]; then
                                deploy_binaries_from_dir "$r_root/packages"
                            elif [ -d "$t_dir/packages" ]; then
                                deploy_binaries_from_dir "$t_dir/packages"
                            elif [ -d "$LOCAL_DIR/packages" ]; then
                                deploy_binaries_from_dir "$LOCAL_DIR/packages"
                            fi

                            echo -e "\n  ${G}✔ Archive fully extracted, modules and binary cores deployed!${NC}\n"
                            sleep 1.5
                            kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
                            exec "$MTUNNEL_PATH"
                        else
                            echo -e "\n  ${Y}● No main.sh found in archive. Scanning for packages, scripts and binaries...${NC}\n"
                            
                            local deployed_anything=false

                            while IFS= read -r dir_cand; do
                                if deploy_binaries_from_dir "$dir_cand"; then
                                    deployed_anything=true
                                fi
                            done < <(find "$t_dir" -type d)

                            while IFS= read -r sh_cand; do
                                local bname=$(basename "$sh_cand" .sh)
                                cp -f "$sh_cand" "$LOCAL_DIR/${bname}.sh" 2>/dev/null
                                chmod +x "$LOCAL_DIR/${bname}.sh" 2>/dev/null
                                deploy_cached_module "$bname" 2>/dev/null || true
                                deployed_anything=true
                            done < <(find "$t_dir" -type f -name "*.sh")

                            if [ "$deployed_anything" = true ]; then
                                echo -e "\n  ${G}✔ Fallback success: All packages, .deb files, and scripts from archive deployed successfully!${NC}\n"
                            else
                                echo -e "\n  ${R}✖ Error: No valid scripts, binaries, or debian packages found inside the ZIP!${NC}\n"
                            fi
                        fi
                        rm -rf "$t_dir"
                    elif grep -q "#!/bin/bash" "$tmp_dl"; then
                        clear
                        echo -e "\n  ${DIM}┌─[ SELECT MODULE TARGET TO OVERWRITE ]${NC}\n  ${DIM}│${NC}"
                        local idx=1
                        local tot_m=${#ALL_MODULES[@]}
                        for m in "${ALL_MODULES[@]}"; do
                            local branch="├─"
                            [ "$idx" -eq "$tot_m" ] && branch="└─"
                            echo -e "  ${DIM}${branch}${NC} ${W}${idx}${NC} ${DIM}❯${NC} ${C}${m}${NC}"
                            ((idx++))
                        done
                        echo -ne "\n  ${C}OVERWRITE ❯❯ ${NC}"; read m_num
                        local chosen_mod="${ALL_MODULES[$((m_num - 1))]}"
                        if [ -n "$chosen_mod" ]; then
                            local dest="$LOCAL_DIR/${MOD_MAP[$chosen_mod]}"
                            mkdir -p "$(dirname "$dest")" 2>/dev/null
                            cat "$tmp_dl" > "$dest"
                            deploy_cached_module "$chosen_mod"
                            echo -e "\n  ${G}✔ Successfully applied to ${chosen_mod}!${NC}\n"
                            if [ "$chosen_mod" = "main" ]; then
                                sleep 1.5
                                kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
                                exec "$MTUNNEL_PATH"
                            fi
                        fi
                    else
                        echo -e "\n  ${R}✖ Downloaded file is neither a valid ZIP nor a bash script!${NC}\n"
                    fi
                else
                    echo -e "\n  ${R}✖ Download failed! Check URL.${NC}\n"
                fi
                rm -f "$tmp_dl"; sleep 2
                ;;

            9)
                clear
                echo -e "\n  ${DIM}┌─[ MANUAL RAW CODE PASTE (EDITOR) ]${NC}\n  ${DIM}│${NC}"
                local idx=1
                local tot_m=${#ALL_MODULES[@]}
                for m in "${ALL_MODULES[@]}"; do
                    local branch="├─"
                    [ "$idx" -eq "$tot_m" ] && branch="└─"
                    echo -e "  ${DIM}${branch}${NC} ${W}${idx}${NC} ${DIM}❯${NC} ${C}${m}${NC}"
                    ((idx++))
                done
                echo -ne "\n  ${C}EDITOR ❯❯ ${NC}"; read m_num
                local chosen_mod="${ALL_MODULES[$((m_num - 1))]}"
                if [ -n "$chosen_mod" ]; then
                    local dest="$LOCAL_DIR/${MOD_MAP[$chosen_mod]}"
                    mkdir -p "$(dirname "$dest")" 2>/dev/null

                    local temp_paste_file="$SECURE_TMP/.manual_paste.$$"
                    > "$temp_paste_file"

                    if command -v nano >/dev/null 2>&1; then
                        echo -e "\n  ${DIM}● Opening clean editor... Paste your raw code, save (Ctrl+O, Enter) and exit (Ctrl+X).${NC}\n"
                        sleep 1.5
                        nano "$temp_paste_file"
                    elif command -v vi >/dev/null 2>&1; then
                        vi "$temp_paste_file"
                    fi

                    if [ -s "$temp_paste_file" ] && grep -q "#!/bin/bash" "$temp_paste_file"; then
                        local new_ver=$(grep -m1 '^MODULE_VERSION=' "$temp_paste_file" | cut -d'"' -f2)
                        [ -z "$new_ver" ] && new_ver="Unknown"

                        local current_v="Unknown"
                        [ -f "$dest" ] && current_v=$(grep -m1 '^MODULE_VERSION=' "$dest" 2>/dev/null | cut -d'"' -f2)
                        [ -z "$current_v" ] && current_v="Unknown"

                        clear
                        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}\n  ${DIM}│${NC}"
                        echo -e "  ${DIM}├─${NC} ${W}Target Module   :${NC} ${C}${chosen_mod}${NC}"
                        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${current_v}${NC}"
                        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
                        echo -e "  ${DIM}│${NC}"
                        echo -ne "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}"; read confirm

                        if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
                            sed -i 's/\r$//' "$temp_paste_file" 2>/dev/null
                            chmod +x "$temp_paste_file"
                            cat "$temp_paste_file" > "$dest"
                            rm -f "$temp_paste_file"

                            deploy_cached_module "$chosen_mod"
                            echo -e "\n  ${G}✔ Module ${chosen_mod} (v${new_ver}) successfully applied! Rebooting core...${NC}\n"
                            sleep 1.5
                            kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
                            exec "$MTUNNEL_PATH"
                        else
                            echo -e "\n  ${Y}● Manual update cancelled by user.${NC}\n"
                            rm -f "$temp_paste_file"
                        fi
                    else
                        echo -e "\n  ${R}✖ Invalid format (Missing #!/bin/bash) or empty paste!${NC}\n"
                        rm -f "$temp_paste_file"
                    fi
                    sleep 2
                fi
                ;;

            0) break ;;
        esac
    done
}

run_iperf3() {
    clear
    if ! command -v iperf3 >/dev/null 2>&1; then
        echo -e "\n  ${DIM}┌─[ IPERF3 PACKAGE INSTALLER ]${NC}\n"
        killall -9 apt-get apt dpkg 2>/dev/null || true
        rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock 2>/dev/null || true
        dpkg --configure -a >/dev/null 2>&1 || true

        (
            DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::ForceIPv4=true -y -q >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -o Acquire::ForceIPv4=true -y -q iperf3 >/dev/null 2>&1
        ) &
        local pid=$!
        draw_progress_bar "$pid" "Installing iPerf3 Benchmark"
        wait "$pid" 2>/dev/null

        if command -v iperf3 >/dev/null 2>&1; then
            echo -e "\n  ${G}✔ iPerf3 installed successfully.${NC}\n"
        else
            echo -e "\n  ${R}✘ Direct install attempt...${NC}\n"
            apt-get install -y iperf3 >/dev/null 2>&1
        fi
        sleep 1
    fi

    render_iperf_menu() {
        clear; echo ""
        local s_ip=$(get_local_ip)
        local str1=" iPerf3 Network Bandwidth Benchmark "
        local raw_len=$(( ${#str1} ))
        local pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
        local padding=$(printf '%*s' "$pad_len" "")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Port:${NC} ${C}5201 TCP/UDP${NC} ${padding}${B}│${NC}"
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"

        echo -e "\n  ${DIM}┌─[ BENCHMARK MODE ]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run as Server (Listener Mode)${NC} ${DIM}(Wait for peer connections)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run as Client (Sender Mode)${NC}   ${DIM}(Push bandwidth stream to server)${NC}"
        echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    }

    while true; do
        render_iperf_menu
        read_with_refresh "  ${C}iPerf3 ❯❯ ${NC}" i_opt render_iperf_menu
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

draw_main_header() {
    local s_ip=$(get_local_ip)

    local bbr_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local bbr_stat="${DIM}○ OFF${NC}"
    [ "$bbr_cc" == "bbr" ] && bbr_stat="${G}● ON${NC}"

    local web_stat="${DIM}○ OFFLINE${NC}"
    if systemctl is-active --quiet mweb.service 2>/dev/null; then
        local w_port="1000"
        [ -f "/etc/mweb/web.conf" ] && w_port=$(grep "WEB_PORT" /etc/mweb/web.conf | cut -d= -f2 | tr -d ' ' | tr -d '\r')
        web_stat="${G}● PORT ${w_port}${NC}"
    fi

    local porter_stat="${DIM}○ OFF${NC}"
    systemctl is-active --quiet mporter.service 2>/dev/null && porter_stat="${G}● ON${NC}"

    clear; echo ""
    local border="──────────────────────────────────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${B}╭${border}╮${NC}"
    echo -e "  ${B}│${NC} ${W}MDesign Master Core v${MODULE_VERSION}${NC}   ${B}│${NC}   ${DIM}Local:${NC} ${W}%-15s${NC}   ${B}│${NC}   ${DIM}Web:${NC} ${web_stat}    ${B}│${NC}   ${DIM}Porter:${NC} ${porter_stat}   ${B}│${NC}   ${DIM}BBR:${NC} ${bbr_stat}     ${B}│${NC}" | sed "s/%-15s/$(printf '%-15s' "$s_ip")/"
    echo -e "  ${B}├${border}┤${NC}"

    local shown=0
    if [ -f "$SECURE_TMP/.main_tun_stats" ]; then
        while IFS='|' read -r t_proto t_name t_remote t_vip t_ping t_loss t_dev t_fwd; do
            [ -z "$t_proto" ] && continue
            ((shown++))
            [ "$shown" -gt 3 ] && break

            [ ${#t_name} -gt 5 ] && t_name="${t_name:0:5}"
            [ ${#t_remote} -gt 15 ] && t_remote="${t_remote:0:15}"

            local if_uptime=$(get_iface_uptime_pure "$t_dev")
            local stat_icon="●"; local stat_col="${G}"
            if [ "$if_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi

            local fwd_col="${DIM}"; [ "$t_fwd" != "OFF" ] && fwd_col="${C}"
            local vip_col="${DIM}"; [ "$t_vip" != "OFF" ] && vip_col="${G}"

            local loss_col="${DIM}"; local loss_disp="---"
            if [ "$t_loss" != "---" ] && [ -n "$t_loss" ]; then
                loss_disp="${t_loss}%"
                if [ "$t_loss" -eq 0 ] 2>/dev/null; then loss_col="${G}"
                elif [ "$t_loss" -lt 30 ] 2>/dev/null; then loss_col="${Y}"
                else loss_col="${R}"; fi
            fi

            local proto_box="[${t_proto}]"

            printf "  ${B}│${NC} %b%s%b ${W}%-5s${NC} ${DIM}%-7s${NC} ${B}│${NC}  ${DIM}Peer:${NC} ${Y}%-15s${NC} ${B}│${NC}  ${DIM}vIP:%b%-4s%b  ${B}│${NC}  ${DIM}P:${NC}${Y}%-6s${NC} ${DIM}L:${NC}%b%-4s%b  ${B}│${NC}  ${DIM}Up:${NC}${W}%-6s${NC}  ${B}│${NC}  ${DIM}FWD:${NC}%b%-4s%b  ${B}│${NC}\n" \
                "$stat_col" "$stat_icon" "$NC" "$t_name" "$proto_box" "$t_remote" "$vip_col" "$t_vip" "$NC" "$t_ping" "$loss_col" "$loss_disp" "$NC" "$if_uptime" "$fwd_col" "$t_fwd" "$NC"
        done < "$SECURE_TMP/.main_tun_stats"
    fi

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}%-102s${NC}  ${B}│${NC}\n" "● No active tunnels or fabrics deployed across the ecosystem."
    fi
    echo -e "  ${B}╰${border}╯${NC}"
}

show_tunnel_hub() {
    render_tunnel_menu() {
        local badge_mgre="" badge_mxlan="" badge_mrathole="" badge_mbackhaul="" badge_mpaqet=""
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
            1) run_mod "mgre" ;; 
            2) run_mod "mxlan" ;; 
            3) run_mod "mrathole" ;; 
            4) run_mod "mbackhaul" ;; 
            5) run_mod "mpaqet" ;; 
            0) break ;;
        esac
    done
}

render_main_menu() {
    local badge_hub="" badge_porter="" badge_main="" badge_bbr="" badge_diag="" badge_shield="" badge_link="" badge_stats="" badge_healer="" badge_iface=""

    if [ -f "$UPDATE_FILE" ]; then
        local tun_updates=""
        grep -q "^mgre:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(MGRE)${NC}"
        grep -q "^mxlan:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(MXLAN)${NC}"
        grep -q "^mrathole:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(Rathole)${NC}"
        grep -q "^mbackhaul:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(Backhaul)${NC}"
        grep -q "^mpaqet:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(Paqet)${NC}"

        if [ -n "$tun_updates" ]; then
            badge_hub=" ${Y}(Update Available)${NC}${tun_updates}"
        fi

        if grep -q "^mporter:" "$UPDATE_FILE"; then
            local p_ver=$(grep "^mporter:" "$UPDATE_FILE" | cut -d: -f3)
            badge_porter=" ${Y}(Update Available: v${p_ver})${NC}"
        fi
        if grep -q "^main:" "$UPDATE_FILE"; then
            local m_ver=$(grep "^main:" "$UPDATE_FILE" | cut -d: -f3)
            badge_main=" ${Y}(Update Available: v${m_ver})${NC}"
        fi
        if grep -q "^mbbr:" "$UPDATE_FILE"; then
            local b_ver=$(grep "^mbbr:" "$UPDATE_FILE" | cut -d: -f3)
            badge_bbr=" ${Y}(Update Available: v${b_ver})${NC}"
        fi
        if grep -q "^mdiag:" "$UPDATE_FILE"; then
            local d_ver=$(grep "^mdiag:" "$UPDATE_FILE" | cut -d: -f3)
            badge_diag=" ${Y}(Update Available: v${d_ver})${NC}"
        fi
        if grep -q "^mshield:" "$UPDATE_FILE"; then
            local s_ver=$(grep "^mshield:" "$UPDATE_FILE" | cut -d: -f3)
            badge_shield=" ${Y}(Update Available: v${s_ver})${NC}"
        fi
        if grep -q "^linktest:" "$UPDATE_FILE"; then
            local l_ver=$(grep "^linktest:" "$UPDATE_FILE" | cut -d: -f3)
            badge_link=" ${Y}(Update Available: v${l_ver})${NC}"
        fi
        if grep -q "^mstats:" "$UPDATE_FILE"; then
            local st_ver=$(grep "^mstats:" "$UPDATE_FILE" | cut -d: -f3)
            badge_stats=" ${Y}(Update Available: v${st_ver})${NC}"
        fi
        if grep -q "^mhealer:" "$UPDATE_FILE"; then
            local h_ver=$(grep "^mhealer:" "$UPDATE_FILE" | cut -d: -f3)
            badge_healer=" ${Y}(Update Available: v${h_ver})${NC}"
        fi
        if grep -q "^minterface:" "$UPDATE_FILE"; then
            local if_ver=$(grep "^minterface:" "$UPDATE_FILE" | cut -d: -f3)
            badge_iface=" ${Y}(Update Available: v${if_ver})${NC}"
        fi
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
        9) run_iperf3 ;;
        10) run_mod "mbbr" ;;
        11) show_ota_update_hub ;;
        12)
            clear
            echo -e "\n  ${DIM}┌─[ OFFLINE LOCAL DEPLOY ENGINE ]${NC}\n"
            echo -ne "  ${C}●${NC} ${W}Enter local path (Directory, .zip, or .tar.gz) [Enter for current]: ${NC}"; read local_input
            local_input=$(echo "$local_input" | tr -d '\r ')
            [ -z "$local_input" ] && local_input="$(pwd)"

            if [ ! -e "$local_input" ]; then
                echo -e "\n  ${R}✖ Path not found: ${local_input}${NC}\n"
                sleep 2
                continue
            fi

            clear
            echo -e "\n  ${DIM}┌─[ DEPLOYING FROM LOCAL SOURCE ]${NC}\n"

            work_dir="$local_input"
            is_temp_archive=false

            if [ -f "$local_input" ]; then
                work_dir="$(mktemp -d /tmp/mtunnel-local-deploy.XXXXXX)"
                is_temp_archive=true
                if [[ "$local_input" == *.zip ]]; then
                    if ! command -v unzip >/dev/null 2>&1; then
                        DEBIAN_FRONTEND=noninteractive apt-get update -y -q >/dev/null 2>&1
                        DEBIAN_FRONTEND=noninteractive apt-get install -y -q unzip >/dev/null 2>&1
                    fi
                    unzip -q -o "$local_input" -d "$work_dir" 2>/dev/null
                elif [[ "$local_input" == *.tar.gz || "$local_input" == *.tgz ]]; then
                    tar -xzf "$local_input" -C "$work_dir" 2>/dev/null
                fi
            fi

            while IFS= read -r sh_file; do
                bname=$(basename "$sh_file" .sh)
                dest_rel="${MOD_MAP[$bname]:-${bname}.sh}"
                mkdir -p "$(dirname "$LOCAL_DIR/$dest_rel")" 2>/dev/null
                cp -f "$sh_file" "$LOCAL_DIR/$dest_rel" 2>/dev/null
                chmod +x "$LOCAL_DIR/$dest_rel" 2>/dev/null
                deploy_cached_module "$bname" 2>/dev/null || true
            done < <(find "$work_dir" -type f -name "*.sh")

            matched_items=()
            for item in "${ALL_PACKAGES[@]}"; do
                if [ -n "$(find "$work_dir" -type f -name "$item" | head -n 1)" ]; then
                    matched_items+=("$item")
                fi
            done

            total_local=${#matched_items[@]}
            if [ "$total_local" -gt 0 ]; then
                current=0
                width=30

                for item in "${matched_items[@]}"; do
                    ((current++))
                    f_found="$(find "$work_dir" -type f -name "$item" | head -n 1)"

                    percent=$(( current * 100 / total_local ))
                    filled=$(( percent * width / 100 ))
                    empty=$(( width - filled ))

                    bar_f=$(printf "%${filled}s" "" | tr ' ' '#')
                    bar_e=$(printf "%${empty}s" "" | tr ' ' '-')

                    if [[ "$item" == *.deb ]]; then
                        item_name=$(echo "$item" | cut -d'_' -f1)
                        item_ver=$(echo "$item" | cut -d'_' -f2 | cut -d'-' -f1)
                    else
                        item_name="$item"
                        item_ver="${BIN_VERSIONS[$item]:-Core}"
                    fi

                    ver_str=" (v${item_ver})"
                    plain_len=$(( ${#item_name} + ${#ver_str} ))
                    pad_len=$(( 26 - plain_len ))
                    [ "$pad_len" -lt 0 ] && pad_len=0
                    padding=$(printf '%*s' "$pad_len" "")

                    if [ -n "$f_found" ] && [ -s "$f_found" ]; then
                        cp -f "$f_found" "$LOCAL_DIR/packages/" 2>/dev/null
                        if [[ "$item" == *.deb ]]; then
                            dpkg -i --force-confdef --force-confold "$f_found" >/dev/null 2>&1 || true
                        else
                            chmod +x "$f_found" 2>/dev/null
                            if [ "$item" == "haproxy" ]; then
                                install -m 0755 "$f_found" /usr/sbin/haproxy 2>/dev/null
                                ln -sf /usr/sbin/haproxy /usr/local/bin/haproxy 2>/dev/null
                            elif [ "$item" == "bh" ]; then
                                install -m 0755 "$f_found" /usr/local/bin/bh 2>/dev/null
                                ln -sf /usr/local/bin/bh /usr/local/bin/backhaul 2>/dev/null
                            else
                                install -m 0755 "$f_found" "/usr/local/bin/$item" 2>/dev/null
                            fi
                        fi

                        printf "  ${G}✔${NC} ${W}%s${NC}${Y}%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$item_name" "$ver_str" "$padding" "$bar_f" "$bar_e" "$percent"
                    else
                        ver_str=" (FAILED)"
                        plain_len=$(( ${#item_name} + ${#ver_str} ))
                        pad_len=$(( 26 - plain_len ))
                        [ "$pad_len" -lt 0 ] && pad_len=0
                        padding=$(printf '%*s' "$pad_len" "")

                        printf "  ${R}✖${NC} ${R}%s%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$item_name" "$ver_str" "$padding" "$bar_f" "$bar_e" "$percent"
                    fi
                done
                echo -e "\n\n  ${G}● All local packages, binaries and scripts deployed successfully.${NC}\n"
            else
                while IFS= read -r dir_cand; do
                    deploy_binaries_from_dir "$dir_cand" >/dev/null 2>&1 || true
                done < <(find "$work_dir" -type d)
                echo -e "\n\n  ${G}● Offline scan finished and binary packages linked.${NC}\n"
            fi

            [ "$is_temp_archive" = true ] && rm -rf "$work_dir"
            echo -ne "  ${DIM}Press Enter to return...${NC}\n"; read dummy
            ;;

        13)
            clear
            echo -e "\n  ${R}╭────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${R}│${NC} ${W}MTunnel Nuclear Wipe (Complete Uninstaller)${NC}                  ${R}│${NC}"
            echo -e "  ${R}╰────────────────────────────────────────────────────────────╯${NC}\n"
            echo -e "  ${Y}⚠ Warning: This will stop and remove all tunnels, services,${NC}"
            echo -e "  ${Y}  binary cores (rathole, backhaul, paqet, gost), and configs!${NC}\n"
            echo -ne "  ${R}Type WIPE-MTUNNEL to continue: ${NC}"; read del_confirm
            del_confirm="${del_confirm//[$' \r\n']/}"
            if [[ "$del_confirm" == "WIPE-MTUNNEL" ]]; then
                echo -e "\n  ${C}● Terminating services and wiping files...${NC}"
                
                systemctl stop mgre.service mxlan.service mporter.service mporter-watchdog.service mweb.service mhealer.service mshield.service mbackhaul@* mrathole@* mpaqet@* gost@* 2>/dev/null || true
                systemctl disable mgre.service mxlan.service mporter.service mporter-watchdog.service mweb.service mhealer.service mshield.service mbackhaul@* mrathole@* mpaqet@* gost@* 2>/dev/null || true
                
                rm -f /etc/systemd/system/mgre.service \
                      /etc/systemd/system/mxlan.service \
                      /etc/systemd/system/mporter.service \
                      /etc/systemd/system/mporter-watchdog.service \
                      /etc/systemd/system/mweb.service \
                      /etc/systemd/system/mhealer.service \
                      /etc/systemd/system/mshield.service \
                      /etc/systemd/system/mbackhaul@.service \
                      /etc/systemd/system/mrathole@.service \
                      /etc/systemd/system/mpaqet@.service \
                      /etc/systemd/system/gost@.service 2>/dev/null || true
                systemctl daemon-reload 2>/dev/null || true

                rm -rf /etc/mgre /etc/mporter /etc/mweb /etc/mshield /etc/mstats /etc/mrathole /etc/mbackhaul /etc/paqet /etc/mhealer /etc/minterface /etc/mdiag /etc/linktest /etc/mbbr /root/mtunnel /tmp/custom-unzip.* /tmp/mtunnel-local-deploy.* 2>/dev/null || true

                rm -f /usr/bin/mtunnel /usr/bin/main /usr/bin/mgre /usr/bin/mxlan /usr/bin/mbackhaul /usr/bin/mpaqet /usr/bin/mporter /usr/bin/minterface /usr/bin/mdiag /usr/bin/mshield /usr/bin/mstats /usr/bin/mhealer /usr/bin/mweb /usr/bin/mrathole /usr/bin/mbbr /usr/bin/linktest

                rm -f /usr/local/bin/rathole /usr/local/bin/bh /usr/local/bin/backhaul /usr/local/bin/paqet /usr/local/bin/gost /usr/local/bin/frpc /usr/local/bin/frps /usr/local/bin/haproxy /usr/sbin/haproxy

                kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
                echo -e "\n  ${G}✓ MTunnel ecosystem completely wiped from this system.${NC}\n"; exit 0
            else
                echo -e "\n  ${Y}● Wipe cancelled.${NC}"; sleep 1.5
            fi
            ;;

        0) 
            kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
            clear; exit 0
            ;;
    esac
done
