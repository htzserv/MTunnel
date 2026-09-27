#!/bin/bash
# --- MXLAN Layer-2 Fabric (mxlan.sh) | MDesign Core v1.7.5 ---
# [Features: Pure Suffix | Explicit Loss Label | Exact Border Alignment | Zero ANSI Leaks]

MODULE_VERSION="1.7.7"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mxlan"
CONF_DIR="/etc/mgre/vxlan"
SERVICE_FILE="/etc/systemd/system/mxlan.service"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mxlan" ] && rm -f "/usr/local/bin/mxlan" 2>/dev/null

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

MAIN_PID=$$
NEED_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1

UPDATE_CHECK_INTERVAL=30
PING_CHECK_INTERVAL=5

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

check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tunnels/mxlan.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tunnels/mxlan.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mxlan_remote_ver"
}

update_watcher_loop() {
    while true; do
        check_update_bg
        kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
update_watcher_loop &
WATCHER_PID=$!

check_ping_bg() {
    local count=0
    > "$SECURE_TMP/.mxlan_stats_cache.tmp"
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; VX_NAME=""; CORE_SUBNET=""; VNI_ID=""; source "$conf" 2>/dev/null
        [ -z "$VX_NAME" ] && continue
        
        ((count++))
        [ "$count" -gt 3 ] && break

        local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local res=$(timeout 2 ping -c 3 -i 0.2 -W 1 "$tip" 2>/dev/null)
        local loss=$(echo "$res" | grep -oP '[0-9]+(?=% packet loss)')
        [ -z "$loss" ] && loss="100"
        
        local avg="---"
        if echo "$res" | grep -q "min/avg/max"; then
            avg=$(echo "$res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
            [ -n "$avg" ] && avg="${avg}ms"
        fi
        echo "${VX_NAME}|${avg}|${loss}" >> "$SECURE_TMP/.mxlan_stats_cache.tmp"
    done
    mv -f "$SECURE_TMP/.mxlan_stats_cache.tmp" "$SECURE_TMP/.mxlan_stats_cache" 2>/dev/null
}

ping_watcher_loop() {
    while true; do
        check_ping_bg
        kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        sleep "$PING_CHECK_INTERVAL"
    done
}
ping_watcher_loop &
PING_WATCHER_PID=$!

trap 'kill "$WATCHER_PID" "$PING_WATCHER_PID" 2>/dev/null' EXIT

self_update_module() {
    local rel_path="tunnels/mxlan.sh"
    local cb="?t=$(date +%s)"
    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (MXLAN Fabric) ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Server${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_opt
    
    local dl_url=""
    [ "$src_opt" == "1" ] && dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path$cb"
    [ "$src_opt" == "2" ] && dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path$cb"
    [ -z "$dl_url" ] && return

    local tmp_file="$SECURE_TMP/.mxlan_update.$$"
    curl -fsSL --connect-timeout 10 -o "$tmp_file" "$dl_url" 2>/dev/null || wget -q --timeout=15 -O "$tmp_file" "$dl_url" 2>/dev/null

    if [ -s "$tmp_file" ] && grep -q "#!/bin/bash" "$tmp_file"; then
        chmod +x "$tmp_file"
        cat "$tmp_file" > "$INSTALL_PATH" 2>/dev/null
        [ -f "$0" ] && cat "$tmp_file" > "$0" 2>/dev/null
        rm -f "$tmp_file"
        echo -e "  ${G}✔ Update applied! Restarting...${NC}"; sleep 1.5
        exec "$INSTALL_PATH" "$@"
    else
        echo -e "  ${R}✖ Download failed!${NC}"; rm -f "$tmp_file"; sleep 1.5
    fi
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

get_pure_vx_name() {
    local pure="${1#vx_}"
    echo "${pure:-$1}"
}

get_iface_uptime() {
    local iface="$1"
    if [ ! -d "/sys/class/net/$iface" ] || [ "$(cat /sys/class/net/$iface/operstate 2>/dev/null)" == "down" ]; then
        echo "DOWN"
        return
    fi
    local sys_uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    local if_sec=$(ip -s -d link show "$iface" 2>/dev/null | grep -oP 'trans_start \K[0-9]+')
    local delta=0
    if [ -n "$if_sec" ] && [ "$if_sec" -gt 0 ]; then
        delta=$(( (sys_uptime * 100 - if_sec) / 100 ))
        [ "$delta" -lt 0 ] && delta=0
    else
        local created=$(stat -c %Y "/sys/class/net/$iface" 2>/dev/null)
        local now=$(date +%s)
        delta=$(( now - created ))
        [ "$delta" -lt 0 ] && delta=0
    fi
    local d=$(( delta / 86400 )); local h=$(( (delta % 86400) / 3600 )); local m=$(( (delta % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
    else printf "%dm" "$m"; fi
}

clean_fwd_rules() {
    local t="$1"
    iptables -t nat -S PREROUTING 2>/dev/null | grep "MXLAN_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t nat $r 2>/dev/null; done
    iptables -t nat -S POSTROUTING 2>/dev/null | grep "MXLAN_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t nat $r 2>/dev/null; done
    iptables -t filter -S FORWARD 2>/dev/null | grep "MXLAN_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t filter $r 2>/dev/null; done
}

merge_ports() {
    local current="$1"; local add="$2"
    local -a result=()
    local IFS=','
    local -a cur_arr=($current)
    local -a add_arr=($add)
    for p in "${cur_arr[@]}"; do [ -n "$p" ] && result+=("$p"); done
    for p in "${add_arr[@]}"; do
        [ -z "$p" ] && continue
        local found=0
        for e in "${result[@]}"; do [ "$e" == "$p" ] && found=1 && break; done
        [ "$found" -eq 0 ] && result+=("$p")
    done
    local out=""
    for p in "${result[@]}"; do out+="${p},"; done
    echo "${out%,}"
}

remove_ports() {
    local current="$1"; local rem="$2"
    [ -z "$rem" ] && { echo "$current"; return; }
    local IFS=','
    local -a cur_arr=($current)
    local -a rem_arr=($rem)
    local out=""
    for p in "${cur_arr[@]}"; do
        [ -z "$p" ] && continue
        local skip=0
        for r in "${rem_arr[@]}"; do [ "$p" == "$r" ] && skip=1 && break; done
        [ "$skip" -eq 0 ] && out+="${p},"
    done
    echo "${out%,}"
}

apply_fabric() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; VNI_ID=""; BR_NAME=""; VX_NAME=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf"
    
    local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
    local local_br_ip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
    local remote_br_ip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
    
    clean_fwd_rules "$VX_NAME"
    local eth_iface=$(ip route get "$REMOTE_PUB" 2>/dev/null | awk '{print $5}' | head -n 1)
    [ -z "$eth_iface" ] && eth_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -n 1)
    
    ip link del "$VX_NAME" >/dev/null 2>&1
    ip link del "$BR_NAME" >/dev/null 2>&1
    
    ip link add "$BR_NAME" type bridge 2>/dev/null
    ip link set dev "$BR_NAME" mtu 1450 2>/dev/null
    ip link set "$BR_NAME" up 2>/dev/null
    
    if ip addr show 2>/dev/null | grep -q "$LOCAL_PUB"; then
        ip link add "$VX_NAME" type vxlan id "$VNI_ID" dev "$eth_iface" remote "$REMOTE_PUB" local "$LOCAL_PUB" dstport 4789 2>/dev/null
    else
        ip link add "$VX_NAME" type vxlan id "$VNI_ID" dev "$eth_iface" remote "$REMOTE_PUB" dstport 4789 2>/dev/null
    fi
    
    ip link set "$VX_NAME" master "$BR_NAME" 2>/dev/null
    ip link set "$VX_NAME" up 2>/dev/null
    ip addr add "${local_br_ip}/24" dev "$BR_NAME" 2>/dev/null

    local all_targets=("$remote_br_ip")

    if [[ "$MAX_IPS" -gt 0 ]]; then
        for ((i=0; i<MAX_IPS; i++)); do
            local hash=$(echo "${SYNC_KEY}_${i}" | sha256sum)
            local range_selector=$(( 0x${hash:0:2} % 3 ))
            local o1 o2 o3
            if [[ "$range_selector" == "0" ]]; then o1="10"; o2=$(( (0x${hash:2:2} % 254) + 1 ))
            elif [[ "$range_selector" == "1" ]]; then o1="172"; o2=$(( (0x${hash:2:2} % 16) + 16 ))
            else o1="192"; o2="168"; fi
            o3=$(( (0x${hash:4:2} % 254) + 1 ))
            
            local last_local=$([ "$TYPE" == "1" ] && echo "1" || echo "2")
            local last_remote=$([ "$TYPE" == "1" ] && echo "2" || echo "1")
            local nip="$o1.$o2.$o3.$last_local"
            local tip="$o1.$o2.$o3.$last_remote"
            all_targets+=("$tip")
            if ! ip route show 2>/dev/null | grep -q "$nip"; then
                ip addr add "$nip/30" dev "$BR_NAME" label "${BR_NAME}:m" 2>/dev/null
            fi
        done
    fi

    if [[ "$TYPE" == "1" ]]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        local t_count=${#all_targets[@]}

        if [ -n "$FWD_TCP" ]; then
            IFS=',' read -ra TCP_ARR <<< "$FWD_TCP"
            for p in "${TCP_ARR[@]}"; do
                p=$(echo "$p" | tr -dc '0-9')
                [ -z "$p" ] && continue
                if [[ "$LB_MODE" == "1" && "$t_count" -gt 1 ]]; then
                    for ((idx=0; idx<t_count; idx++)); do
                        local dst_ip="${all_targets[$idx]}"
                        local remaining=$((t_count - idx))
                        if [ "$remaining" -gt 1 ]; then
                            iptables -t nat -A PREROUTING -p tcp -m tcp --dport "$p" -m statistic --mode nth --every "$remaining" --packet 0 -j DNAT --to-destination "$dst_ip" -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                        else
                            iptables -t nat -A PREROUTING -p tcp -m tcp --dport "$p" -j DNAT --to-destination "$dst_ip" -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                        fi
                        iptables -t nat -A POSTROUTING -p tcp -m tcp -d "$dst_ip" --dport "$p" -j MASQUERADE -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                        iptables -t filter -A FORWARD -p tcp -d "$dst_ip" --dport "$p" -j ACCEPT -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                    done
                else
                    iptables -t nat -A PREROUTING -p tcp -m tcp --dport "$p" -j DNAT --to-destination "$remote_br_ip" -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                    iptables -t nat -A POSTROUTING -p tcp -m tcp -d "$remote_br_ip" --dport "$p" -j MASQUERADE -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                    iptables -t filter -A FORWARD -p tcp -d "$remote_br_ip" --dport "$p" -j ACCEPT -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                fi
            done
        fi

        if [ -n "$FWD_UDP" ]; then
            IFS=',' read -ra UDP_ARR <<< "$FWD_UDP"
            for p in "${UDP_ARR[@]}"; do
                p=$(echo "$p" | tr -dc '0-9')
                [ -z "$p" ] && continue
                if [[ "$LB_MODE" == "1" && "$t_count" -gt 1 ]]; then
                    for ((idx=0; idx<t_count; idx++)); do
                        local dst_ip="${all_targets[$idx]}"
                        local remaining=$((t_count - idx))
                        if [ "$remaining" -gt 1 ]; then
                            iptables -t nat -A PREROUTING -p udp -m udp --dport "$p" -m statistic --mode nth --every "$remaining" --packet 0 -j DNAT --to-destination "$dst_ip" -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                        else
                            iptables -t nat -A PREROUTING -p udp -m udp --dport "$p" -j DNAT --to-destination "$dst_ip" -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                        fi
                        iptables -t nat -A POSTROUTING -p udp -m udp -d "$dst_ip" --dport "$p" -j MASQUERADE -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                        iptables -t filter -A FORWARD -p udp -d "$dst_ip" --dport "$p" -j ACCEPT -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                    done
                else
                    iptables -t nat -A PREROUTING -p udp -m udp --dport "$p" -j DNAT --to-destination "$remote_br_ip" -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                    iptables -t nat -A POSTROUTING -p udp -m udp -d "$remote_br_ip" --dport "$p" -j MASQUERADE -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                    iptables -t filter -A FORWARD -p udp -d "$remote_br_ip" --dport "$p" -j ACCEPT -m comment --comment "MXLAN_FWD_$VX_NAME" 2>/dev/null
                fi
            done
        fi
    fi
}

apply_all_fabrics() { for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && apply_fabric "$conf"; done; }

select_fabric_interactive() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No fabrics configured yet!${NC}"; sleep 1.5; return 1; fi
    echo -e "\n  ${B}╭────────────────── Select Target Fabric ───────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Fabric Index or 'q': ${NC}"; read t_idx
    [[ "$t_idx" == "q" || -z "$t_idx" || -z "${configs[$t_idx]}" ]] && return 1
    SELECTED_CONF="${configs[$t_idx]}"
    return 0
}

draw_mxlan_header() {
    local s_ip=$(get_local_ip)
    local active_fabrics=0
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue
        VX_NAME=""; source "$conf" 2>/dev/null
        if ip link show "$VX_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$VX_NAME/operstate 2>/dev/null)" != "down" ]; then
            ((active_fabrics++))
        fi
    done

    clear; echo ""
    local border="────────────────────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${B}╭${border}╮${NC}"
    printf "  ${B}│${NC} ${W}%-22s${NC} ${B}│${NC} ${DIM}Local:${NC} ${W}%-15s${NC} ${B}│${NC} ${DIM}Active Fabrics:${NC} ${M}%-3s${NC} ${DIM}(Max 3 Shown)${NC}      ${B}│${NC}\n" \
        "MXLAN Layer-2 Core v${MODULE_VERSION}" "$s_ip" "$active_fabrics"
    echo -e "  ${B}├${border}┤${NC}"

    local shown=0
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; REMOTE_PUB=""; VX_NAME=""; BR_NAME=""; CORE_SUBNET=""; VNI_ID=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; source "$conf" 2>/dev/null
        [ -z "$VX_NAME" ] && continue
        ((shown++))
        [ "$shown" -gt 3 ] && break

        local pure_name=$(get_pure_vx_name "$VX_NAME")
        [ ${#pure_name} -gt 4 ] && pure_name="${pure_name:0:4}"

        local vip_stat="OFF"; local vip_col="${DIM}"
        if [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null; then
            vip_stat="+${MAX_IPS}"
            vip_col="${G}"
        fi

        local live_ping="---" live_loss="---"
        if [ -f "$SECURE_TMP/.mxlan_stats_cache" ]; then
            local cached_entry=$(grep "^${VX_NAME}|" "$SECURE_TMP/.mxlan_stats_cache" 2>/dev/null | head -n1)
            if [ -n "$cached_entry" ]; then
                live_ping=$(echo "$cached_entry" | cut -d'|' -f2)
                live_loss=$(echo "$cached_entry" | cut -d'|' -f3)
            fi
        fi

        local loss_disp="---"; local loss_col="${DIM}"
        if [ "$live_loss" != "---" ] && [ -n "$live_loss" ]; then
            loss_disp="${live_loss}%"
            if [ "$live_loss" -eq 0 ] 2>/dev/null; then loss_col="${G}"
            elif [ "$live_loss" -lt 30 ] 2>/dev/null; then loss_col="${Y}"
            else loss_col="${R}"; fi
        fi

        local fwd_str="OFF"
        if [ "$TYPE" == "1" ]; then
            if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
            elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:4}"
            elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:4}"
            fi
        else
            fwd_str="GW"
        fi

        local if_uptime=$(get_iface_uptime "$VX_NAME")
        local stat_icon="●"; local stat_col="${G}"
        if [ "$if_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi

        local fwd_col="${DIM}"; [ "$fwd_str" != "OFF" ] && fwd_col="${C}"

        printf "  ${B}│${NC} %b%s%b ${W}%-4s${NC} ${DIM}➔${NC} ${Y}%-15s${NC} ${DIM}vIP:%b%-4s%b ${B}│${NC} ${DIM}P:${NC}${Y}%-6s${NC} ${DIM}L:${NC}%b%-4s%b ${B}│${NC} ${DIM}Up:${NC}${W}%-6s${NC} ${B}│${NC} ${DIM}FWD:${NC}%b%-4s%b ${B}│${NC}\n" \
            "$stat_col" "$stat_icon" "$NC" "$pure_name" "$REMOTE_PUB" "$vip_col" "$vip_stat" "$NC" "$live_ping" "$loss_col" "$loss_disp" "$NC" "$if_uptime" "$fwd_col" "$fwd_str" "$NC"
    done

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}%-88s${NC}  ${B}│${NC}\n" "● No active fabrics configured on this host."
    fi
    echo -e "  ${B}╰${border}╯${NC}"
}

show_fabric_details() {
    clear
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No fabrics configured yet!${NC}"; sleep 1.5; return; fi

    echo -e "\n  ${M}● Deployed Fabrics Registry:${NC}"
    for conf in "${configs[@]}"; do
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; VNI_ID=""; BR_NAME=""; VX_NAME=""; source "$conf" 2>/dev/null
        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC} ${M}▼ Fabric: ${VX_NAME}${NC} (Bridge: ${BR_NAME})"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        echo -e "  ${B}│${NC} ${DIM}Public IPs   :${NC} ${W}${LOCAL_PUB}${NC} ${DIM}->${NC} ${W}${REMOTE_PUB}${NC}"
        echo -e "  ${B}│${NC} ${DIM}Network VNI  :${NC} ${C}${VNI_ID}${NC}"
        echo -e "  ${B}│${NC} ${DIM}Virtual IPs  :${NC} ${Y}${MAX_IPS}${NC} vIPs active"
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

show_mxlan_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    local conf TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY CORE_SUBNET VNI_ID BR_NAME VX_NAME FWD_TCP FWD_UDP LB_MODE
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; CORE_SUBNET=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf" 2>/dev/null
        local v_ips; mapfile -t v_ips < <(ip -4 addr show dev "$BR_NAME" label "${BR_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

        local title_txt="${VX_NAME}/${BR_NAME}"
        local raw_l1=" ▼ ${title_txt} | PUB: ${LOCAL_PUB} -> ${REMOTE_PUB}"
        local pad1=$(( 92 - ${#raw_l1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        local eval_l1=$(printf " %b▼ %s%b ${DIM}| PUB: ${W}%s ${DIM}→${W} %s${NC}" "${M}" "${title_txt}" "${NC}" "${LOCAL_PUB}" "${REMOTE_PUB}")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC}${eval_l1}${sp1}${B}│${NC}"

        if [ "$TYPE" == "1" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then
            local disp_tcp="${FWD_TCP:-0}"; [ ${#disp_tcp} -gt 30 ] && disp_tcp="${disp_tcp:0:27}..."
            local disp_udp="${FWD_UDP:-0}"; [ ${#disp_udp} -gt 30 ] && disp_udp="${disp_udp:0:27}..."
            local raw_l2="   ↳ NAT: T:[${disp_tcp}] U:[${disp_udp}] LB:[$([ "$LB_MODE" == "1" ] && echo ON || echo OFF)]"
            local pad2=$(( 92 - ${#raw_l2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
            local lb_stat=$([ "$LB_MODE" == "1" ] && echo "${G}ON${NC}" || echo "${DIM}OFF${NC}")
            local eval_l2="   ${DIM}↳ NAT:${NC} ${Y}T:[${disp_tcp}]${NC} ${C}U:[${disp_udp}]${NC} ${DIM}LB:[${lb_stat}${DIM}]${NC}"
            echo -e "  ${B}│${NC}${eval_l2}${sp2}${B}│${NC}"
        fi

        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        local main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local main_lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")

        local ping_res=$(timeout 2 ping -c 1 -W 1 "$main_tip" 2>/dev/null)
        local lat lat_raw lat_color stat_icon stat_text stat_color
        if echo "$ping_res" | grep -q "time="; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
            lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi

        local m_icon="├─"; [ ${#v_ips[@]} -eq 0 ] && m_icon="└─"
        printf "  ${B}│${NC} ${W}%s %-15s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%s %-10s%b ${B}│${NC}\n" "${m_icon}" "Bridge IP" "$main_lip" "$main_tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"

        local total_v=${#v_ips[@]}
        for ((idx=0; idx<total_v; idx++)); do
            local lip="${v_ips[$idx]}"; local base_ip=$(echo "$lip" | cut -d'.' -f1-3); local last=$(echo "$lip" | cut -d'.' -f4); local tip="$base_ip.$([ "$last" == "1" ] && echo "2" || echo "1")"
            ping_res=$(timeout 2 ping -c 1 -W 1 "$tip" 2>/dev/null)
            if echo "$ping_res" | grep -q "time="; then
                lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
                lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
            else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
            local v_icon="│  ├─"; [ $idx -eq $((total_v - 1)) ] && v_icon="│  └─"
            printf "  ${B}│${NC} ${DIM}%s %-12s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%s %-10s%b ${B}│${NC}\n" "${v_icon}" "vIP" "$lip" "$tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        done
        echo -e "  ${B}╰────────────────────┴────────────────────┴────────────────────┴──────────────┴──────────────╯${NC}\n"
    done
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

render_mxlan_menu() {
    draw_mxlan_header
    echo -e "\n  ${DIM}┌─[ PROVISION & MANAGE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${M}Setup New VXLAN Fabric (VNI Mesh)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Delete Fabrics (Specific / ALL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Virtual IP Manager (Add/Purge vIPs)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ FLAT CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Edit Public IPs (Local / Remote)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Edit VNI Network ID${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${Y}Override Core Subnet Base${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${G}Manage Port Forwarding & Load Balancer${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${W}Rename Fabric Interface${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & SYSTEM ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${M}View Fabric Config Registry${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${G}Instant OTA Update Module${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}

[ ! -f "$SERVICE_FILE" ] && setup_service

while true; do
    render_mxlan_menu
    read_with_refresh "  ${M}MXLAN ❯❯ ${NC}" opt render_mxlan_menu
    case $opt in
        1)
           echo -e "\n  ${DIM}┌─[ VXLAN DEPLOYMENT ]${NC}"
           echo -ne "  ${C}● Server Mode [1:IR | 2:KH]: ${NC}"; read s_type
           echo -ne "  ${C}● Fabric Suffix Name (e.g. ir): ${NC}"; read suffix
           vx_name="vx_${suffix}"; br_name="br_${suffix}"
           local_ip=$(get_local_ip)
           echo -ne "  ${C}● Remote Public IP: ${NC}"; read r_ip
           echo -ne "  ${C}● VNI Network ID (1-16777215): ${NC}"; read vni_id
           core_sub="10.88.$(( vni_id % 200 + 1 ))"
           conf_path="$CONF_DIR/${vx_name}.conf"
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=\nVX_NAME=$vx_name\nBR_NAME=$br_name\nVNI_ID=$vni_id\nCORE_SUBNET=$core_sub\nFWD_TCP=\nFWD_UDP=\nLB_MODE=0" > "$conf_path"
           apply_fabric "$conf_path"
           echo -e "  ${G}● Fabric deployed successfully!${NC}"; sleep 1.5 ;;
        2)
           select_fabric_interactive && {
               source "$SELECTED_CONF" 2>/dev/null
               clean_fwd_rules "$VX_NAME"
               ip link del "$VX_NAME" >/dev/null 2>&1
               ip link del "$BR_NAME" >/dev/null 2>&1
               rm -f "$SELECTED_CONF"
               echo -e "  ${G}● Fabric removed.${NC}"; sleep 1.5
           } ;;
        3)
           select_fabric_interactive && {
               echo -ne "  ${C}● vIP Count (0 to disable): ${NC}"; read n_vip
               sed -i "s/^MAX_IPS=.*/MAX_IPS=$n_vip/" "$SELECTED_CONF"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● Virtual IPs updated.${NC}"; sleep 1.5
           } ;;
        4)
           select_fabric_interactive && {
               echo -ne "  ${C}● New Remote Public IP: ${NC}"; read new_rip
               [ -n "$new_rip" ] && sed -i "s/^REMOTE_PUB=.*/REMOTE_PUB=$new_rip/" "$SELECTED_CONF"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● Remote IP updated.${NC}"; sleep 1.5
           } ;;
        5)
           select_fabric_interactive || continue
           VNI_ID=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}● New VNI ID (1-16777215) [Current: ${Y}${VNI_ID}${C}, Enter to Skip]: ${NC}"; read new_vni
           new_vni=$(echo "$new_vni" | tr -dc '0-9')
           if [ -n "$new_vni" ]; then
               if grep -q "VNI_ID=$new_vni$" "$CONF_DIR"/*.conf 2>/dev/null; then
                   echo -e "  ${R}✖ VNI [${new_vni}] is already in use!${NC}"; sleep 1.5; continue
               fi
               class_selector=$(( new_vni % 3 ))
               hash_c=$(echo -n "vni_${new_vni}" | sha256sum)
               if [ "$class_selector" == "1" ]; then c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
               elif [ "$class_selector" == "2" ]; then c1="172"; c2=$(( (0x${hash_c:2:2} % 16) + 16 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
               else c1="192"; c2="168"; c3=$(( (0x${hash_c:4:2} % 254) + 1 )); fi
               new_core_sub="${c1}.${c2}.${c3}"
               sed -i "s/^VNI_ID=.*/VNI_ID=$new_vni/" "$SELECTED_CONF"
               sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_core_sub/" "$SELECTED_CONF"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● VNI updated. Subnet automatically changed to ${new_core_sub}.x${NC}"; sleep 1.8
           fi ;;
        6)
           select_fabric_interactive || continue
           CORE_SUBNET=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}● New Core Subnet Base (e.g. 10.88.5) [Current: ${Y}${CORE_SUBNET}${C}, Enter to Skip]: ${NC}"; read new_sub
           new_sub=$(echo "$new_sub" | tr -dc '0-9.')
           if [ -n "$new_sub" ]; then
               sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_sub/" "$SELECTED_CONF"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● Subnet base updated to ${new_sub}.x${NC}"; sleep 1.5
           fi ;;
        7)
           select_fabric_interactive || continue
           while true; do
               TYPE=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; VX_NAME=""; source "$SELECTED_CONF" 2>/dev/null
               if [ "$TYPE" != "1" ]; then
                   echo -e "  ${Y}● Port Forwarding is only configurable on the IRAN-role fabric.${NC}"; sleep 1.8; break
               fi
               echo -e "\n  ${DIM}┌─[ PORT FORWARDING MANAGER: ${W}${VX_NAME}${DIM} ]${NC}"
               echo -e "  ${DIM}│${NC} ${DIM}Current TCP:${NC} ${Y}${FWD_TCP:-None}${NC}"
               echo -e "  ${DIM}│${NC} ${DIM}Current UDP:${NC} ${C}${FWD_UDP:-None}${NC}"
               echo -e "  ${DIM}│${NC} ${DIM}Load Balancer:${NC} $([ "$LB_MODE" == "1" ] && echo "${G}ON${NC}" || echo "${DIM}OFF${NC}")"
               echo -e "  ${DIM}│${NC}"
               echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add New Ports (Keep Existing)${NC}"
               echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Remove Specific Ports${NC}"
               echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Replace All Ports (Overwrite)${NC}"
               echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Toggle Load Balancer${NC}"
               echo -e "  ${DIM}│${NC}"
               echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back${NC}\n"
               echo -ne "  ${C}Select ❯❯ ${NC}"; read pf_opt
               case $pf_opt in
                   1)
                       echo -ne "  ${C}●${NC} ${W}Add TCP Ports (e.g. 8080,9090) [Enter to skip]: ${NC}"; read add_tcp
                       echo -ne "  ${C}●${NC} ${W}Add UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read add_udp
                       add_tcp=$(echo "$add_tcp" | tr -dc '0-9,'); add_udp=$(echo "$add_udp" | tr -dc '0-9,')
                       m_tcp=$(merge_ports "$FWD_TCP" "$add_tcp"); m_udp=$(merge_ports "$FWD_UDP" "$add_udp")
                       grep -v "^FWD_TCP=" "$SELECTED_CONF" | grep -v "^FWD_UDP=" > "${SELECTED_CONF}.tmp"
                       echo "FWD_TCP=$m_tcp" >> "${SELECTED_CONF}.tmp"; echo "FWD_UDP=$m_udp" >> "${SELECTED_CONF}.tmp"
                       mv "${SELECTED_CONF}.tmp" "$SELECTED_CONF"
                       apply_fabric "$SELECTED_CONF"
                       echo -e "  ${G}● Ports added. TCP: ${m_tcp:-None} | UDP: ${m_udp:-None}${NC}"; sleep 1.8 ;;
                   2)
                       echo -ne "  ${C}●${NC} ${W}Remove TCP Ports (e.g. 8080,9090) [Enter to skip]: ${NC}"; read rm_tcp
                       echo -ne "  ${C}●${NC} ${W}Remove UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read rm_udp
                       rm_tcp=$(echo "$rm_tcp" | tr -dc '0-9,'); rm_udp=$(echo "$rm_udp" | tr -dc '0-9,')
                       m_tcp=$(remove_ports "$FWD_TCP" "$rm_tcp"); m_udp=$(remove_ports "$FWD_UDP" "$rm_udp")
                       grep -v "^FWD_TCP=" "$SELECTED_CONF" | grep -v "^FWD_UDP=" > "${SELECTED_CONF}.tmp"
                       echo "FWD_TCP=$m_tcp" >> "${SELECTED_CONF}.tmp"; echo "FWD_UDP=$m_udp" >> "${SELECTED_CONF}.tmp"
                       mv "${SELECTED_CONF}.tmp" "$SELECTED_CONF"
                       apply_fabric "$SELECTED_CONF"
                       echo -e "  ${G}● Ports removed. TCP: ${m_tcp:-None} | UDP: ${m_udp:-None}${NC}"; sleep 1.8 ;;
                   3)
                       echo -ne "  ${C}●${NC} ${W}New TCP Ports (Current: ${Y}${FWD_TCP:-None}${W}): ${NC}"; read new_tcp
                       echo -ne "  ${C}●${NC} ${W}New UDP Ports (Current: ${C}${FWD_UDP:-None}${W}): ${NC}"; read new_udp
                       new_tcp=$(echo "$new_tcp" | tr -dc '0-9,'); new_udp=$(echo "$new_udp" | tr -dc '0-9,')
                       grep -v "^FWD_TCP=" "$SELECTED_CONF" | grep -v "^FWD_UDP=" > "${SELECTED_CONF}.tmp"
                       echo "FWD_TCP=$new_tcp" >> "${SELECTED_CONF}.tmp"; echo "FWD_UDP=$new_udp" >> "${SELECTED_CONF}.tmp"
                       mv "${SELECTED_CONF}.tmp" "$SELECTED_CONF"
                       apply_fabric "$SELECTED_CONF"
                       echo -e "  ${G}● Ports replaced. TCP: ${new_tcp:-None} | UDP: ${new_udp:-None}${NC}"; sleep 1.8 ;;
                   4)
                       new_lb="1"; [ "$LB_MODE" == "1" ] && new_lb="0"
                       sed -i "s/^LB_MODE=.*/LB_MODE=$new_lb/" "$SELECTED_CONF"
                       apply_fabric "$SELECTED_CONF"
                       echo -e "  ${G}● Load Balancer set to $([ "$new_lb" == "1" ] && echo ON || echo OFF).${NC}"; sleep 1.5 ;;
                   0) break ;;
               esac
           done ;;
        8)
           select_fabric_interactive || continue
           VX_NAME=""; BR_NAME=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Fabric Suffix (Current: ${Y}$(get_pure_vx_name "$VX_NAME")${W}, Max 4-5 chars): ${NC}"; read new_suffix
           new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
           if [ -n "$new_suffix" ]; then
               new_vx_name="vx_${new_suffix}"; new_br_name="br_${new_suffix}"
               if [ -f "$CONF_DIR/${new_vx_name}.conf" ]; then
                   echo -e "  ${R}● Error: Fabric [${new_vx_name}] already exists!${NC}"; sleep 1.5; continue
               fi
               clean_fwd_rules "$VX_NAME"
               ip link del "$VX_NAME" >/dev/null 2>&1
               ip link del "$BR_NAME" >/dev/null 2>&1
               sed -i "s/^VX_NAME=.*/VX_NAME=$new_vx_name/" "$SELECTED_CONF"
               sed -i "s/^BR_NAME=.*/BR_NAME=$new_br_name/" "$SELECTED_CONF"
               mv "$SELECTED_CONF" "$CONF_DIR/${new_vx_name}.conf"
               apply_fabric "$CONF_DIR/${new_vx_name}.conf"
               echo -e "  ${G}● Fabric successfully renamed to: ${new_vx_name}${NC}"; sleep 1.5
           fi ;;
        9) show_fabric_details ;;
        10)
           while true; do
               draw_mxlan_header
               show_mxlan_monitor
               read -t 2 -n 1 -s b_opt
               [[ "$b_opt" == "q" || "$b_opt" == "Q" ]] && break
           done ;;
        11) self_update_module ;;
        0) break ;;
    esac
done
