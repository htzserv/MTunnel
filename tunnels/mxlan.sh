#!/bin/bash
# --- MXLAN Layer-2 Fabric (mxlan.sh) | MDesign Core v1.8.5 ---
# [Features: Pure Suffix | Dynamic Multi-IP | Master Token Mesh | Integer Ping | MPorter Launcher | Advanced OTA]

MODULE_VERSION="1.8.5"

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
    local conf TYPE VX_NAME CORE_SUBNET VNI_ID c_sub tip res loss avg
    > "$SECURE_TMP/.mxlan_stats_cache.tmp"
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; VX_NAME=""; CORE_SUBNET=""; VNI_ID=""; source "$conf" 2>/dev/null
        [ -z "$VX_NAME" ] && continue
        
        ((count++))
        [ "$count" -gt 3 ] && break

        c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        res=$(timeout 2 ping -c 3 -i 0.2 -W 1 "$tip" 2>/dev/null)
        loss=$(echo "$res" | grep -oP '[0-9]+(?=% packet loss)')
        [ -z "$loss" ] && loss="100"
        
        avg="---"
        if echo "$res" | grep -q "min/avg/max"; then
            avg=$(echo "$res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
            if [ -n "$avg" ]; then
                avg=$(awk -v v="$avg" 'BEGIN {printf "%.0f", v}')
                avg="${avg}ms"
            fi
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
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mxlan_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mxlan_remote_ver" 2>/dev/null | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ]; then
        if [ "$remote_v" != "$MODULE_VERSION" ]; then
            gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
        else
            gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
        fi
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (MXLAN Fabric) ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ AUTOMATIC MIRRORS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${gh_text}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MANUAL OVERRIDES ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Offline Editor)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r src_opt
    
    local tmp_file="$SECURE_TMP/.mxlan_update.$$"
    > "$tmp_file"

    if [[ "$src_opt" == "4" ]]; then
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
            sleep 2; nano "$tmp_file"
        elif command -v vi >/dev/null 2>&1; then
            vi "$tmp_file"
        else
            echo -e "  ${R}✖ No text editor (nano/vi) found!${NC}"; rm -f "$tmp_file"; sleep 2; return
        fi
    elif [[ "$src_opt" =~ ^[123]$ ]]; then
        local dl_url=""
        case $src_opt in
            1) dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path$cb" ;;
            2) dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path$cb" ;;
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read -r custom_url; dl_url=$(echo "$custom_url" | tr -d '\r ') ;;
        esac
        [ -z "$dl_url" ] && rm -f "$tmp_file" && return
        
        echo -e "\n  ${C}⟳${NC} ${W}Downloading Update...${NC}"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp_file" "$dl_url" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 -O "$tmp_file" "$dl_url" 2>/dev/null
        fi
    else
        rm -f "$tmp_file"
        return
    fi

    if [ -s "$tmp_file" ] && grep -q "#!/bin/bash" "$tmp_file"; then
        local new_ver
        new_ver=$(grep -m1 '^MODULE_VERSION=' "$tmp_file" | cut -d'"' -f2)
        [ -z "$new_ver" ] && new_ver="Unknown"
        
        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read -r confirm
        
        if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
            sed -i 's/\r$//' "$tmp_file" 2>/dev/null
            chmod +x "$tmp_file"
            
            cat "$tmp_file" > "$INSTALL_PATH" 2>/dev/null || true
            [ -f "$0" ] && cat "$tmp_file" > "$0" 2>/dev/null || true
            cp -f "$tmp_file" "$LOCAL_DIR/$rel_path" 2>/dev/null
            
            rm -f "$tmp_file"
            echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
            sleep 1.5
            
            kill "$WATCHER_PID" "$PING_WATCHER_PID" 2>/dev/null
            exec "$INSTALL_PATH" "$@"
        else
            echo -e "  ${Y}● Update cancelled.${NC}"
            rm -f "$tmp_file"; sleep 1.5
        fi
    else
        echo -e "  ${R}✖ Update failed. Invalid format or network error.${NC}"
        rm -f "$tmp_file"; sleep 2
    fi
}

get_local_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

get_pure_vx_name() {
    local pure="${1#vx_}"
    echo "${pure:-$1}"
}

get_iface_uptime() {
    local iface="$1"
    if [ ! -d "/sys/class/net/$iface" ] || [ "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" == "down" ]; then
        echo "DOWN"
        return
    fi
    local sys_uptime if_sec delta d h m
    sys_uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    if_sec=$(ip -s -d link show "$iface" 2>/dev/null | grep -oP 'trans_start \K[0-9]+')
    delta=0
    if [ -n "$if_sec" ] && [ "$if_sec" -gt 0 ]; then
        delta=$(( (sys_uptime * 100 - if_sec) / 100 ))
        [ "$delta" -lt 0 ] && delta=0
    else
        local created now
        created=$(stat -c %Y "/sys/class/net/$iface" 2>/dev/null)
        now=$(date +%s)
        delta=$(( now - created ))
        [ "$delta" -lt 0 ] && delta=0
    fi
    d=$(( delta / 86400 )); h=$(( (delta % 86400) / 3600 )); m=$(( (delta % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
    else printf "%dm" "$m"; fi
}

clean_fwd_rules() {
    local t="$1"
    local r
    iptables -t nat -S PREROUTING 2>/dev/null | grep "MXLAN_FWD_${t}\"" | sed 's/^-A /-D /' | while read -r r; do [ -n "$r" ] && iptables -t nat $r 2>/dev/null; done
    iptables -t nat -S POSTROUTING 2>/dev/null | grep "MXLAN_FWD_${t}\"" | sed 's/^-A /-D /' | while read -r r; do [ -n "$r" ] && iptables -t nat $r 2>/dev/null; done
    iptables -t filter -S FORWARD 2>/dev/null | grep "MXLAN_FWD_${t}\"" | sed 's/^-A /-D /' | while read -r r; do [ -n "$r" ] && iptables -t filter $r 2>/dev/null; done
}

merge_ports() {
    local current="$1"; local add="$2"
    local -a result=(); local IFS=','
    local -a cur_arr=($current); local -a add_arr=($add)
    local p e found out=""
    for p in "${cur_arr[@]}"; do [ -n "$p" ] && result+=("$p"); done
    for p in "${add_arr[@]}"; do
        [ -z "$p" ] && continue
        found=0
        for e in "${result[@]}"; do [ "$e" == "$p" ] && found=1 && break; done
        [ "$found" -eq 0 ] && result+=("$p")
    done
    for p in "${result[@]}"; do out+="${p},"; done
    echo "${out%,}"
}

remove_ports() {
    local current="$1"; local rem="$2"
    [ -z "$rem" ] && { echo "$current"; return; }
    local IFS=','
    local -a cur_arr=($current); local -a rem_arr=($rem)
    local out="" p r skip
    for p in "${cur_arr[@]}"; do
        [ -z "$p" ] && continue
        skip=0
        for r in "${rem_arr[@]}"; do [ "$p" == "$r" ] && skip=1 && break; done
        [ "$skip" -eq 0 ] && out+="${p},"
    done
    echo "${out%,}"
}

apply_fabric() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    local TYPE="" LOCAL_PUB="" REMOTE_PUB="" MAX_IPS="0" SYNC_KEY="" TUN_SECRET="" T_NAME="" TUN_ID="" CORE_SUBNET="" TUN_PROTO="ipv4" VNI_ID="" BR_NAME="" VX_NAME="" FWD_TCP="" FWD_UDP="" LB_MODE="0"
    source "$conf" 2>/dev/null
    
    local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
    local local_br_ip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
    local remote_br_ip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
    
    clean_fwd_rules "$VX_NAME"

    # Multi-IP dynamic interface lookup
    local eth_iface=""
    if [ -n "$LOCAL_PUB" ]; then
        eth_iface=$(ip -o -4 addr show 2>/dev/null | awk -v target="$LOCAL_PUB" '$4 ~ "^"target"(/|$)" {print $2; exit}')
    fi
    [ -z "$eth_iface" ] && eth_iface=$(ip route get "$REMOTE_PUB" 2>/dev/null | awk '{print $5}' | head -n 1)
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
        local i hash range_selector o1 o2 o3 last_local last_remote nip tip
        for ((i=0; i<MAX_IPS; i++)); do
            hash=$(echo "${SYNC_KEY}_${i}" | sha256sum)
            range_selector=$(( 0x${hash:0:2} % 3 ))
            if [[ "$range_selector" == "0" ]]; then o1="10"; o2=$(( (0x${hash:2:2} % 254) + 1 ))
            elif [[ "$range_selector" == "1" ]]; then o1="172"; o2=$(( (0x${hash:2:2} % 16) + 16 ))
            else o1="192"; o2="168"; fi
            o3=$(( (0x${hash:4:2} % 254) + 1 ))
            
            last_local=$([ "$TYPE" == "1" ] && echo "1" || echo "2")
            last_remote=$([ "$TYPE" == "1" ] && echo "2" || echo "1")
            nip="$o1.$o2.$o3.$last_local"
            tip="$o1.$o2.$o3.$last_remote"
            all_targets+=("$tip")
            if ! ip route show 2>/dev/null | grep -q "$nip"; then
                ip addr add "$nip/30" dev "$BR_NAME" label "${BR_NAME}:m" 2>/dev/null
            fi
        done
    fi

    if [[ "$TYPE" == "1" ]]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        local t_count=${#all_targets[@]}
        local p idx dst_ip remaining

        if [ -n "$FWD_TCP" ]; then
            IFS=',' read -ra TCP_ARR <<< "$FWD_TCP"
            for p in "${TCP_ARR[@]}"; do
                p=$(echo "$p" | tr -dc '0-9')
                [ -z "$p" ] && continue
                if [[ "$LB_MODE" == "1" && "$t_count" -gt 1 ]]; then
                    for ((idx=0; idx<t_count; idx++)); do
                        dst_ip="${all_targets[$idx]}"
                        remaining=$((t_count - idx))
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
                        dst_ip="${all_targets[$idx]}"
                        remaining=$((t_count - idx))
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

apply_all_fabrics() {
    local conf
    for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && apply_fabric "$conf"; done
}

select_fabric_interactive() {
    local configs=("$CONF_DIR"/*.conf)
    [ ! -e "${configs[0]}" ] && { echo -e "\n  ${R}● No fabrics configured yet!${NC}"; sleep 1.5; return 1; }
    echo -e "\n  ${B}╭────────────────── Select Target Fabric ───────────────────╮${NC}"
    local i
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Fabric Index or 'q': ${NC}"; read -r t_idx
    [[ "$t_idx" == "q" || -z "$t_idx" || -z "${configs[$t_idx]}" ]] && return 1
    SELECTED_CONF="${configs[$t_idx]}"
    return 0
}

draw_mxlan_header() {
    local s_ip active_fabrics=0 conf
    s_ip=$(get_local_ip)
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue
        VX_NAME=""; source "$conf" 2>/dev/null
        if ip link show "$VX_NAME" >/dev/null 2>&1 && [ "$(cat "/sys/class/net/$VX_NAME/operstate" 2>/dev/null)" != "down" ]; then
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
    local TYPE REMOTE_PUB VX_NAME BR_NAME CORE_SUBNET VNI_ID FWD_TCP FWD_UDP MAX_IPS pure_name vip_stat vip_col
    local live_ping live_loss cached_entry loss_disp loss_col fwd_str if_uptime stat_icon stat_col fwd_col
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; REMOTE_PUB=""; VX_NAME=""; BR_NAME=""; CORE_SUBNET=""; VNI_ID=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; source "$conf" 2>/dev/null
        [ -z "$VX_NAME" ] && continue
        ((shown++))
        [ "$shown" -gt 3 ] && break

        pure_name=$(get_pure_vx_name "$VX_NAME")
        [ ${#pure_name} -gt 4 ] && pure_name="${pure_name:0:4}"

        vip_stat="OFF"; vip_col="${DIM}"
        if [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null; then
            vip_stat="+${MAX_IPS}"
            vip_col="${G}"
        fi

        live_ping="---"; live_loss="---"
        if [ -f "$SECURE_TMP/.mxlan_stats_cache" ]; then
            cached_entry=$(grep "^${VX_NAME}|" "$SECURE_TMP/.mxlan_stats_cache" 2>/dev/null | head -n1)
            if [ -n "$cached_entry" ]; then
                live_ping=$(echo "$cached_entry" | cut -d'|' -f2)
                live_loss=$(echo "$cached_entry" | cut -d'|' -f3)
            fi
        fi

        loss_disp="---"; loss_col="${DIM}"
        if [ "$live_loss" != "---" ] && [ -n "$live_loss" ]; then
            loss_disp="${live_loss}%"
            if [ "$live_loss" -eq 0 ] 2>/dev/null; then loss_col="${G}"
            elif [ "$live_loss" -lt 30 ] 2>/dev/null; then loss_col="${Y}"
            else loss_col="${R}"; fi
        fi

        fwd_str="OFF"
        if [ "$TYPE" == "1" ]; then
            if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
            elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:4}"
            elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:4}"
            fi
        else
            fwd_str="GW"
        fi

        if_uptime=$(get_iface_uptime "$VX_NAME")
        stat_icon="●"; stat_col="${G}"
        if [ "$if_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi

        fwd_col="${DIM}"; [ "$fwd_str" != "OFF" ] && fwd_col="${C}"

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
    local configs=("$CONF_DIR"/*.conf)
    [ ! -e "${configs[0]}" ] && { echo -e "\n  ${R}● No fabrics configured yet!${NC}"; sleep 1.5; return; }

    echo -e "\n  ${Y}● Deployed Fabrics Registry:${NC}"
    local conf TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET VNI_ID BR_NAME VX_NAME CORE_SUBNET
    local c_sub lip tip t_role t_sec left_p right_p pad sp l1 r1 pad1 sp1 l2 r2 pad2 sp2 l3 pad3 sp3 l4 pad4 sp4
    for conf in "${configs[@]}"; do
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; CORE_SUBNET=""; source "$conf" 2>/dev/null
        c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access)" || echo "KHAREJ (Gateway)")
        t_sec="${TUN_SECRET:-[ NOT SET ]}"

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        left_p="▼ Fabric: ${VX_NAME} (${BR_NAME})"; right_p="Role: $t_role"
        pad=$(( 90 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"

        l1="Master Token : ${t_sec}"; r1="Network VNI : ${VNI_ID}"
        pad1=$(( 90 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Master Token :${NC} ${W}${t_sec}${NC}${sp1}${DIM}Network VNI :${NC} ${Y}${VNI_ID}${NC} ${B}│${NC}"

        l2="vIP Sync Key : ${SYNC_KEY:-Same As Token}"; r2="Virtual IPs : ${MAX_IPS} active"
        pad2=$(( 90 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}vIP Sync Key :${NC} ${W}${SYNC_KEY:-Same As Token}${NC}${sp2}${DIM}Virtual IPs :${NC} ${G}${MAX_IPS} active${NC} ${B}│${NC}"

        l3="Public IPs   : ${LOCAL_PUB} -> ${REMOTE_PUB}"
        pad3=$(( 90 - ${#l3} )); [ "$pad3" -lt 0 ] && pad3=0; sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${DIM}Public IPs   :${NC} ${W}${LOCAL_PUB}${NC} ${DIM}->${NC} ${W}${REMOTE_PUB}${NC}${sp3} ${B}│${NC}"

        l4="Core Subnet  : ${c_sub}.x (${lip} -> ${tip})"
        pad4=$(( 90 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Core Subnet  :${NC} ${G}${c_sub}.x${NC} ${DIM}(${lip} -> ${tip})${NC}${sp4} ${B}│${NC}"

        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r dummy
}

show_mxlan_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    local conf TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY CORE_SUBNET VNI_ID BR_NAME VX_NAME FWD_TCP FWD_UDP LB_MODE
    local v_ips title_txt raw_l1 pad1 sp1 eval_l1 disp_tcp disp_udp lb_txt raw_l2 pad2 sp2 lb_stat eval_l2
    local c_sub main_tip main_lip ping_res lat lat_raw lat_color stat_icon stat_text stat_color m_icon total_v idx lip base_ip last tip v_icon

    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; CORE_SUBNET=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf" 2>/dev/null
        mapfile -t v_ips < <(ip -4 addr show dev "$BR_NAME" label "${BR_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

        title_txt="${VX_NAME}/${BR_NAME}"
        raw_l1=" ▼ ${title_txt} | PUB: ${LOCAL_PUB} -> ${REMOTE_PUB}"
        pad1=$(( 92 - ${#raw_l1} )); [ "$pad1" -lt 0 ] && pad1=0; sp1=$(printf '%*s' "$pad1" "")
        eval_l1=$(printf " %b▼ %s%b ${DIM}| PUB: ${W}%s ${DIM}→${W} %s${NC}" "${M}" "${title_txt}" "${NC}" "${LOCAL_PUB}" "${REMOTE_PUB}")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC}${eval_l1}${sp1}${B}│${NC}"

        if [ "$TYPE" == "1" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then
            disp_tcp="${FWD_TCP:-0}"; [ ${#disp_tcp} -gt 30 ] && disp_tcp="${disp_tcp:0:27}..."
            disp_udp="${FWD_UDP:-0}"; [ ${#disp_udp} -gt 30 ] && disp_udp="${disp_udp:0:27}..."
            lb_txt="OFF"; [ "$LB_MODE" == "1" ] && lb_txt="ON"
            raw_l2="   ↳ NAT: T:[${disp_tcp}] U:[${disp_udp}] LB:[${lb_txt}]"
            pad2=$(( 92 - ${#raw_l2} )); [ "$pad2" -lt 0 ] && pad2=0; sp2=$(printf '%*s' "$pad2" "")
            lb_stat=$([ "$LB_MODE" == "1" ] && echo -e "${G}ON${NC}" || echo -e "${DIM}OFF${NC}")
            eval_l2="   ${DIM}↳ NAT:${NC} ${Y}T:[${disp_tcp}]${NC} ${C}U:[${disp_udp}]${NC} ${DIM}LB:[${lb_stat}${DIM}]${NC}"
            echo -e "  ${B}│${NC}${eval_l2}${sp2}${B}│${NC}"
        fi

        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        main_lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")

        ping_res=$(timeout 2 ping -c 1 -W 1 "$main_tip" 2>/dev/null)
        if echo "$ping_res" | grep -q "time="; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
            lat_int=$(awk -v v="$lat" 'BEGIN {printf "%.0f", v}')
            lat_raw="${lat_int}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi

        m_icon="├─"; [ ${#v_ips[@]} -eq 0 ] && m_icon="└─"
        printf "  ${B}│${NC} ${W}%s %-15s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%s %-10s%b ${B}│${NC}\n" "${m_icon}" "Bridge IP" "$main_lip" "$main_tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"

        total_v=${#v_ips[@]}
        for ((idx=0; idx<total_v; idx++)); do
            lip="${v_ips[$idx]}"; base_ip=$(echo "$lip" | cut -d'.' -f1-3); last=$(echo "$lip" | cut -d'.' -f4); tip="$base_ip.$([ "$last" == "1" ] && echo "2" || echo "1")"
            ping_res=$(timeout 2 ping -c 1 -W 1 "$tip" 2>/dev/null)
            if echo "$ping_res" | grep -q "time="; then
                lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
                lat_int=$(awk -v v="$lat" 'BEGIN {printf "%.0f", v}')
                lat_raw="${lat_int}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
            else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
            v_icon="│  ├─"; [ $idx -eq $((total_v - 1)) ] && v_icon="│  └─"
            printf "  ${B}│${NC} ${DIM}%s %-12s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%s %-10s%b ${B}│${NC}\n" "${v_icon}" "vIP" "$lip" "$tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        done
        echo -e "  ${B}╰────────────────────┴────────────────────┴────────────────────┴──────────────┴──────────────╯${NC}\n"
    done
}

uninstall_mxlan() {
    clear
    echo -e "\n  ${R}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${R}│${NC}   ${R}⚠ WARNING: COMPLETE PURGE & UNINSTALLATION OF MXLAN${NC}                     ${R}│${NC}"
    echo -e "  ${R}│${NC}   This will permanently stop and delete:                                   ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All active VXLAN interfaces and Bridge attachments                    ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All configurations & metadata in /etc/mgre/vxlan                       ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All iptables NAT, FORWARD, and Load Balancer rules                     ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● MXLAN systemd service & executable wrapper                             ${R}│${NC}"
    echo -e "  ${R}╰────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    
    local confirm conf VX_NAME BR_NAME
    echo -ne "  ${Y}Are you sure you want to proceed? Type '${R}yes${Y}' to confirm: ${NC}"; read -r confirm
    confirm=$(echo "$confirm" | tr -d '\r ')
    
    if [ "$confirm" != "yes" ]; then
        echo -e "  ${G}● Uninstallation cancelled.${NC}"; sleep 1.5; return
    fi

    echo -e "\n  ${DIM}● [1/4] Stopping services and removing VXLAN interfaces...${NC}"
    systemctl stop mxlan.service 2>/dev/null
    systemctl disable mxlan.service 2>/dev/null

    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        VX_NAME=""; BR_NAME=""; source "$conf" 2>/dev/null
        clean_fwd_rules "$VX_NAME"
        ip link del "$VX_NAME" >/dev/null 2>&1
        ip link del "$BR_NAME" >/dev/null 2>&1
    done

    echo -e "  ${DIM}● [2/4] Removing systemd unit files...${NC}"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null

    echo -e "  ${DIM}● [3/4] Deleting configurations & temporary files...${NC}"
    rm -rf "$CONF_DIR" "$SECURE_TMP/.mxlan"*

    echo -e "  ${DIM}● [4/4] Removing mxlan executable script...${NC}"
    rm -f "$INSTALL_PATH" 2>/dev/null
    [ -f "$0" ] && rm -f "$0" 2>/dev/null

    echo -e "\n  ${G}✔ MXLAN ecosystem has been completely eradicated.${NC}\n"
    exit 0
}

setup_service() {
    local tmp_srv="$SECURE_TMP/mxlan_tpl.service"
    cat <<EOF > "$tmp_srv"
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
    if ! cmp -s "$tmp_srv" "$SERVICE_FILE" 2>/dev/null; then
        mv -f "$tmp_srv" "$SERVICE_FILE"
        systemctl daemon-reload && systemctl enable mxlan.service >/dev/null 2>&1
    else
        rm -f "$tmp_srv"
    fi
}

if [[ "$1" == "--apply" ]]; then apply_all_fabrics; exit 0; fi

[ ! -f "$SERVICE_FILE" ] && setup_service

render_mxlan_menu() {
    draw_mxlan_header
    echo -e "\n  ${DIM}┌─[ PROVISION & MANAGE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${M}Setup New VXLAN Fabric (Token Mesh)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Delete Fabrics (Specific / ALL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Virtual IP Manager (Add/Purge vIPs)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}MPorter Port Forwarder / Manager${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ FLAT CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Edit Public IPs (Local / Remote)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${M}Edit Master Token (Regenerates VNI & Subnet)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${Y}Override Core Subnet Base${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${G}Manage Port Forwarding & Load Balancer${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${W}Rename Fabric Interface${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & SYSTEM ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${M}View Fabric Config Registry${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh Radar)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${G}Instant OTA Update Module${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC}${DIM}❯${NC} ${R}Uninstall MXLAN${NC} ${DIM}(Purge All)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}

while true; do
    render_mxlan_menu
    read_with_refresh "  ${M}MXLAN ❯❯ ${NC}" opt render_mxlan_menu
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1)
           clear
           echo -e "\n  ${DIM}┌─[ VXLAN DEPLOYMENT ]${NC}"
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IR | 2:KH | q:Back]: ${NC}"; read -r s_type; [[ "$s_type" == "q" ]] && break; [[ "$s_type" == "1" || "$s_type" == "2" ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Fabric Suffix Name (e.g. ir, kh): ${NC}"; read -r suffix
               suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
               [[ "$suffix" == "q" ]] && break; [[ -n "$suffix" ]] && break
           done
           [[ "$suffix" == "q" ]] && continue
           vx_name="vx_${suffix}"; br_name="br_${suffix}"
           
           if [ -f "$CONF_DIR/${vx_name}.conf" ]; then
               echo -e "\n  ${R}● Error: Fabric name [${vx_name}] already exists!${NC}"; sleep 2; continue
           fi

           auto_lip=$(get_local_ip)
           while true; do
               echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${auto_lip}${W}]: ${NC}"; read -r custom_ip
               [[ "$custom_ip" == "q" ]] && break
               custom_ip=$(echo "$custom_ip" | tr -dc '0-9.'); [ -n "$custom_ip" ] && auto_lip=$custom_ip
               break
           done
           [[ "$custom_ip" == "q" ]] && continue
           local_ip="$auto_lip"

           while true; do
               echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IP: ${NC}"; read -r r_ip
               [[ "$r_ip" == "q" ]] && break
               r_ip=$(echo "$r_ip" | tr -dc '0-9.'); [[ -n "$r_ip" ]] && break
           done
           [[ "$r_ip" == "q" ]] && continue

           s_key=$(head -c 16 /dev/urandom | xxd -p 2>/dev/null)
           [ -z "$s_key" ] && s_key=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)
           echo -ne "  ${C}●${NC} ${M}Master Secret Token [Default ${s_key}]: ${NC}"; read -r u_key
           [[ "$u_key" == "q" ]] && continue
           u_key=$(echo "$u_key" | tr -dc 'a-zA-Z0-9_=-')
           tun_secret=${u_key:-$s_key}

           hash_c=$(echo -n "core_${tun_secret}" | sha256sum)
           vni_id=$(( 16#${hash_c:0:6} ))
           [ "$vni_id" -eq 0 ] && vni_id=1

           class_selector=$(( 16#${hash_c:6:2} % 3 ))
           c1=""; c2=""; c3=""
           if [ "$class_selector" == "0" ]; then c1="10"; c2=$(( (16#${hash_c:8:2} % 254) + 1 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
           elif [ "$class_selector" == "1" ]; then c1="172"; c2=$(( (16#${hash_c:8:2} % 16) + 16 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
           else c1="192"; c2="168"; c3=$(( (16#${hash_c:10:2} % 254) + 1 )); fi
           core_sub="${c1}.${c2}.${c3}"

           if grep -q "VNI_ID=$vni_id$" "$CONF_DIR"/*.conf 2>/dev/null || grep -q "CORE_SUBNET=$core_sub$" "$CONF_DIR"/*.conf 2>/dev/null; then
               echo -e "  ${R}● Collision detected with an existing fabric! Please choose a different Token.${NC}"; sleep 2; continue
           fi

           conf_path="$CONF_DIR/${vx_name}.conf"
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=$tun_secret\nTUN_SECRET=$tun_secret\nVX_NAME=$vx_name\nBR_NAME=$br_name\nVNI_ID=$vni_id\nCORE_SUBNET=$core_sub\nFWD_TCP=\nFWD_UDP=\nLB_MODE=0" > "$conf_path"
           chmod 600 "$conf_path"
           apply_fabric "$conf_path"

           if ip link show "$vx_name" >/dev/null 2>&1; then
               setup_service
               echo -e "  ${G}● Fabric [${vx_name}] deployed (VNI: ${vni_id} | Subnet: ${core_sub}.x)${NC}"
               remote_tip=$([ "$s_type" == "1" ] && echo "${core_sub}.2" || echo "${core_sub}.1")

               echo -ne "\n  ${C}●${NC} ${W}Run initial ping test to peer now? (y/n): ${NC}"; read -r run_initial_ping
               run_initial_ping=$(echo "$run_initial_ping" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
               if [[ "$run_initial_ping" == "y" || "$run_initial_ping" == "yes" ]]; then
                   echo -e "  ${DIM}┌─[ INITIAL PING TEST TO PEER ]${NC}"
                   echo -e "  ${DIM}│${NC} Pinging ${remote_tip} (4 Packets)..."
                   ping_res=$(ping -c 4 -W 1 "$remote_tip" 2>&1)
                   if echo "$ping_res" | grep -q "time="; then
                       lat=$(echo "$ping_res" | grep -oP 'min/avg/max/mdev = \K[^/]+/[^/]+' | cut -d/ -f2)
                       lat_int=$(awk -v v="$lat" 'BEGIN {printf "%.0f", v}')
                       echo -e "  ${DIM}└─${NC} ${G}SUCCESS!${NC} Average Latency: ${Y}${lat_int}ms${NC}"
                   else
                       echo -e "  ${DIM}└─${NC} ${R}FAILED!${NC} Destination Host Unreachable."
                   fi
               fi

               echo -ne "\n  ${C}●${NC} ${W}Do you want to setup Virtual IPs now? (y/n): ${NC}"; read -r setup_vip
               setup_vip=$(echo "$setup_vip" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
               if [[ "$setup_vip" == "y" || "$setup_vip" == "yes" ]]; then
                   while true; do echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read -r n; [[ "$n" == "q" ]] && break; [[ -n "$n" ]] && break; done
                   if [[ "$n" != "q" ]]; then
                       echo -e "  ${DIM}● Sync Key automatically linked to Master Token.${NC}"
                       sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$conf_path"
                       sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$tun_secret/" "$conf_path"
                       apply_fabric "$conf_path"
                       echo -e "  ${G}● Virtual IPs applied successfully.${NC}"
                   fi
               fi

               if [ "$s_type" == "1" ]; then
                   echo -ne "\n  ${C}●${NC} ${W}Do you want to setup Port Forwarding? (y/n): ${NC}"; read -r setup_pf
                   setup_pf=$(echo "$setup_pf" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
                   if [[ "$setup_pf" == "y" || "$setup_pf" == "yes" ]]; then
                       echo -ne "  ${C}●${NC} ${Y}NAT Forward TCP Ports (e.g. 80,443)  [Enter to skip]: ${NC}"; read -r fwd_tcp
                       echo -ne "  ${C}●${NC} ${C}NAT Forward UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read -r fwd_udp
                       fwd_tcp=$(echo "$fwd_tcp" | tr -dc '0-9,')
                       fwd_udp=$(echo "$fwd_udp" | tr -dc '0-9,')
                       
                       run_lb="0"
                       if [ -n "$fwd_tcp" ] || [ -n "$fwd_udp" ]; then
                           echo -ne "  ${C}●${NC} ${W}Load Balance across all Virtual IPs? (y/n): ${NC}"; read -r ask_lb
                           ask_lb=$(echo "$ask_lb" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
                           if [[ "$ask_lb" == "y" || "$ask_lb" == "yes" ]]; then run_lb="1"; fi
                       fi
                       
                       grep -v "^FWD_TCP=" "$conf_path" | grep -v "^FWD_UDP=" | grep -v "^LB_MODE=" > "${conf_path}.tmp"
                       echo "FWD_TCP=$fwd_tcp" >> "${conf_path}.tmp"
                       echo "FWD_UDP=$fwd_udp" >> "${conf_path}.tmp"
                       echo "LB_MODE=$run_lb" >> "${conf_path}.tmp"
                       mv "${conf_path}.tmp" "$conf_path"
                       
                       apply_fabric "$conf_path"
                       echo -e "  ${G}● Port Forwarding applied successfully.${NC}"
                   fi
               fi
               sleep 1.8
           else
               echo -e "\n  ${R}● FATAL ERROR: Kernel rejected fabric creation!${NC}"; rm -f "$conf_path"; sleep 3
           fi ;;

        2)
           configs=("$CONF_DIR"/*.conf)
           [ ! -e "${configs[0]}" ] && echo -e "\n  ${R}● No active fabrics to remove!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Fabric to Erase ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter Index, 'all', or 'q': ${NC}"; read -r del_idx
           [[ "$del_idx" == "q" || -z "$del_idx" ]] && continue
           if [[ "$del_idx" == "all" ]]; then
               echo -ne "  ${R}● DANGER: Delete ALL fabrics? (y/n): ${NC}"; read -r confirm_all
               if [[ "$confirm_all" == "y" ]]; then
                   for conf in "${configs[@]}"; do
                       VX_NAME=""; BR_NAME=""; source "$conf" 2>/dev/null
                       clean_fwd_rules "$VX_NAME"; ip link del "$VX_NAME" >/dev/null 2>&1; ip link del "$BR_NAME" >/dev/null 2>&1; rm -f "$conf"
                   done
                   echo -e "  ${G}● All fabrics safely purged.${NC}"; sleep 1.5
               fi; continue
           fi
           if [[ -n "${configs[$del_idx]}" ]]; then
               VX_NAME=""; BR_NAME=""; source "${configs[$del_idx]}" 2>/dev/null
               clean_fwd_rules "$VX_NAME"; ip link del "$VX_NAME" >/dev/null 2>&1; ip link del "$BR_NAME" >/dev/null 2>&1; rm -f "${configs[$del_idx]}"
               echo -e "  ${G}● Fabric [${VX_NAME}] destroyed.${NC}"; sleep 1.5
           fi ;;

        3)
           select_fabric_interactive || continue
           VX_NAME=""; MAX_IPS="0"; TUN_SECRET=""; VNI_ID=""; source "$SELECTED_CONF" 2>/dev/null
           echo -e "\n  ${DIM}┌─[ vIP ACTIONS for ${VX_NAME} ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup / Update Virtual IPs${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Purge All Virtual IPs${NC}\n  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
           while true; do echo -ne "  ${C}Select Action ❯❯ ${NC}"; read -r vip_action; [[ "$vip_action" =~ ^[12q]$ ]] && break; done
           [[ "$vip_action" == "q" ]] && continue
           if [[ "$vip_action" == "1" ]]; then
               while true; do echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read -r n; [[ "$n" == "q" ]] && break; [[ -n "$n" ]] && break; done
               [[ "$n" == "q" ]] && continue
               
               k="${TUN_SECRET:-key_${VNI_ID}}"
               echo -e "  ${DIM}● Sync Key automatically linked to Master Token.${NC}"
               sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$SELECTED_CONF"
               sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$SELECTED_CONF"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● Virtual IPs synchronized successfully.${NC}"; sleep 1.5
           elif [[ "$vip_action" == "2" ]]; then
               if [[ "$MAX_IPS" == "0" || -z "$MAX_IPS" ]]; then echo -e "  ${Y}● No Virtual IPs found!${NC}"; sleep 1.5; continue; fi
               echo -ne "  ${R}● Delete all ${MAX_IPS} vIPs from [${VX_NAME}]? (y/n): ${NC}"; read -r confirm_vip
               if [[ "$confirm_vip" == "y" ]]; then 
                   sed -i "s/^MAX_IPS=.*/MAX_IPS=0/" "$SELECTED_CONF"
                   apply_fabric "$SELECTED_CONF"
                   echo -e "  ${G}● Virtual IPs purged.${NC}"; sleep 1.5
               fi
           fi ;;

        4)
           if command -v mporter >/dev/null 2>&1; then
               mporter
           elif [ -x "/usr/bin/mporter" ]; then
               /usr/bin/mporter
           elif [ -f "/root/mtunnel/mporter.sh" ]; then
               bash /root/mtunnel/mporter.sh
           else
               echo -e "\n  ${R}✖ MPorter script not found on system!${NC}"; sleep 1.5
           fi ;;

        5)
           select_fabric_interactive || continue
           LOCAL_PUB=""; REMOTE_PUB=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Local Public IP [Current: ${Y}${LOCAL_PUB}${W}, Enter to skip]: ${NC}"; read -r new_lip
           echo -ne "  ${C}●${NC} ${W}New Remote Public IP [Current: ${Y}${REMOTE_PUB}${W}, Enter to skip]: ${NC}"; read -r new_rip
           new_lip=$(echo "$new_lip" | tr -dc '0-9.')
           new_rip=$(echo "$new_rip" | tr -dc '0-9.')
           [ -n "$new_lip" ] && sed -i "s/^LOCAL_PUB=.*/LOCAL_PUB=$new_lip/" "$SELECTED_CONF"
           [ -n "$new_rip" ] && sed -i "s/^REMOTE_PUB=.*/REMOTE_PUB=$new_rip/" "$SELECTED_CONF"
           apply_fabric "$SELECTED_CONF"
           echo -e "  ${G}● Public IPs updated and applied.${NC}"; sleep 1.5 ;;

        6)
           select_fabric_interactive || continue
           TUN_SECRET=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Master Secret Token (Regenerates VNI & Subnet): ${NC}"; read -r new_tok
           new_tok=$(echo "$new_tok" | tr -dc 'a-zA-Z0-9_=-')
           if [ -n "$new_tok" ]; then
               hash_c=$(echo -n "core_${new_tok}" | sha256sum)
               new_vni=$(( 16#${hash_c:0:6} ))
               [ "$new_vni" -eq 0 ] && new_vni=1

               class_selector=$(( 16#${hash_c:6:2} % 3 ))
               c1=""; c2=""; c3=""
               if [ "$class_selector" == "0" ]; then c1="10"; c2=$(( (16#${hash_c:8:2} % 254) + 1 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
               elif [ "$class_selector" == "1" ]; then c1="172"; c2=$(( (16#${hash_c:8:2} % 16) + 16 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
               else c1="192"; c2="168"; c3=$(( (16#${hash_c:10:2} % 254) + 1 )); fi
               new_core_sub="${c1}.${c2}.${c3}"
               
               if grep -q "VNI_ID=$new_vni$" "$CONF_DIR"/*.conf 2>/dev/null || grep -q "CORE_SUBNET=$new_core_sub$" "$CONF_DIR"/*.conf 2>/dev/null; then
                   echo -e "  ${R}● Collision detected with an existing fabric! Please use a different Token.${NC}"; sleep 2; continue
               fi
               
               sed -i "s/^TUN_SECRET=.*/TUN_SECRET=$new_tok/" "$SELECTED_CONF"
               sed -i "s/^VNI_ID=.*/VNI_ID=$new_vni/" "$SELECTED_CONF"
               sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_core_sub/" "$SELECTED_CONF"
               sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$new_tok/" "$SELECTED_CONF"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● Token updated. VNI: ${new_vni}, Subnet: ${new_core_sub}.x${NC}"; sleep 1.8
           fi ;;

        7)
           select_fabric_interactive || continue
           CORE_SUBNET=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Core Subnet Base (e.g. 10.88.5) [Current: ${Y}${CORE_SUBNET}${W}, Enter to skip]: ${NC}"; read -r new_sub
           new_sub=$(echo "$new_sub" | tr -dc '0-9.')
           if [ -n "$new_sub" ]; then
               sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_sub/" "$SELECTED_CONF"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● Subnet base updated to ${new_sub}.x${NC}"; sleep 1.5
           fi ;;

        8)
           select_fabric_interactive || continue
           while true; do
               TYPE=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; VX_NAME=""; source "$SELECTED_CONF" 2>/dev/null
               if [ "$TYPE" != "1" ]; then
                   echo -e "\n  ${Y}● Port Forwarding & Load Balancer is only available on IRAN role!${NC}"; sleep 2; break
               fi
               echo -e "\n  ${DIM}┌─[ PORT FORWARDING MANAGER: ${W}${VX_NAME}${DIM} ]${NC}"
               echo -e "  ${DIM}│${NC} ${DIM}Current TCP:${NC} ${Y}${FWD_TCP:-None}${NC}"
               echo -e "  ${DIM}│${NC} ${DIM}Current UDP:${NC} ${C}${FWD_UDP:-None}${NC}"
               echo -e "  ${DIM}│${NC} ${DIM}Load Balancer:${NC} $([ "$LB_MODE" == "1" ] && echo -e "${G}ON${NC}" || echo -e "${DIM}OFF${NC}")"
               echo -e "  ${DIM}│${NC}"
               echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add New Ports (Keep Existing)${NC}"
               echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Remove Specific Ports${NC}"
               echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Replace All Ports (Overwrite)${NC}"
               echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Toggle Load Balancer (Distribute across vIPs)${NC}"
               echo -e "  ${DIM}│${NC}"
               echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back${NC}\n"
               echo -ne "  ${C}Select ❯❯ ${NC}"; read -r pf_opt
               case $pf_opt in
                   1)
                       echo -ne "  ${C}●${NC} ${W}Add TCP Ports (e.g. 8080,9090) [Enter to skip]: ${NC}"; read -r add_tcp
                       echo -ne "  ${C}●${NC} ${W}Add UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read -r add_udp
                       add_tcp=$(echo "$add_tcp" | tr -dc '0-9,'); add_udp=$(echo "$add_udp" | tr -dc '0-9,')
                       m_tcp=$(merge_ports "$FWD_TCP" "$add_tcp"); m_udp=$(merge_ports "$FWD_UDP" "$add_udp")
                       grep -v "^FWD_TCP=" "$SELECTED_CONF" | grep -v "^FWD_UDP=" > "${SELECTED_CONF}.tmp"
                       echo "FWD_TCP=$m_tcp" >> "${SELECTED_CONF}.tmp"; echo "FWD_UDP=$m_udp" >> "${SELECTED_CONF}.tmp"
                       mv "${SELECTED_CONF}.tmp" "$SELECTED_CONF"
                       apply_fabric "$SELECTED_CONF"
                       echo -e "  ${G}● Ports added. TCP: ${m_tcp:-None} | UDP: ${m_udp:-None}${NC}"; sleep 1.8 ;;
                   2)
                       echo -ne "  ${C}●${NC} ${W}Remove TCP Ports (e.g. 8080,9090) [Enter to skip]: ${NC}"; read -r rm_tcp
                       echo -ne "  ${C}●${NC} ${W}Remove UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read -r rm_udp
                       rm_tcp=$(echo "$rm_tcp" | tr -dc '0-9,'); rm_udp=$(echo "$rm_udp" | tr -dc '0-9,')
                       m_tcp=$(remove_ports "$FWD_TCP" "$rm_tcp"); m_udp=$(remove_ports "$FWD_UDP" "$rm_udp")
                       grep -v "^FWD_TCP=" "$SELECTED_CONF" | grep -v "^FWD_UDP=" > "${SELECTED_CONF}.tmp"
                       echo "FWD_TCP=$m_tcp" >> "${SELECTED_CONF}.tmp"; echo "FWD_UDP=$m_udp" >> "${SELECTED_CONF}.tmp"
                       mv "${SELECTED_CONF}.tmp" "$SELECTED_CONF"
                       apply_fabric "$SELECTED_CONF"
                       echo -e "  ${G}● Ports removed. TCP: ${m_tcp:-None} | UDP: ${m_udp:-None}${NC}"; sleep 1.8 ;;
                   3)
                       echo -ne "  ${C}●${NC} ${W}New TCP Ports (Current: ${Y}${FWD_TCP:-None}${W}): ${NC}"; read -r new_tcp
                       echo -ne "  ${C}●${NC} ${W}New UDP Ports (Current: ${C}${FWD_UDP:-None}${W}): ${NC}"; read -r new_udp
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

        9)
           select_fabric_interactive || continue
           VX_NAME=""; BR_NAME=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Fabric Suffix (Current: ${Y}$(get_pure_vx_name "$VX_NAME")${W}, Max 4-5 chars): ${NC}"; read -r new_suffix
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
               SELECTED_CONF="$CONF_DIR/${new_vx_name}.conf"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● Fabric successfully renamed to: ${new_vx_name}${NC}"; sleep 1.5
           fi ;;

        10) show_fabric_details ;;
        11)
           while true; do
               draw_mxlan_header
               show_mxlan_monitor
               read -t 2 -n 1 -s b_opt
               [[ "$b_opt" == "q" || "$b_opt" == "Q" ]] && break
           done ;;
        12) self_update_module ;;
        13) uninstall_mxlan ;;
        0) break ;;
    esac
done
