#!/bin/bash
# --- MGRE Modular Core (mgre.sh) | MDesign Core v5.7.0 ---
# [Features: Flat Action Menu | Dynamic Tri-Tunnel Header Dashboard]

MODULE_VERSION="5.7.0"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mgre"
CONF_DIR="/etc/mgre/tunnels"
SERVICE_FILE="/etc/systemd/system/mgre.service"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mgre" ] && rm -f "/usr/local/bin/mgre" 2>/dev/null

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
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tunnels/mgre.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tunnels/mgre.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mgre_remote_ver"
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

# --- LIVE PING PER TUNNEL (Async Header Engine) ---
PING_CHECK_INTERVAL=5
check_ping_bg() {
    local count=0
    > "$SECURE_TMP/.mgre_stats_cache.tmp"
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; CORE_SUBNET=""; source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        
        ((count++))
        [ "$count" -gt 3 ] && break

        local tip=$([ "$TYPE" == "1" ] && echo "${CORE_SUBNET}.2" || echo "${CORE_SUBNET}.1")
        local res=$(timeout 2 ping -c 3 -i 0.2 -W 1 "$tip" 2>/dev/null)
        local loss=$(echo "$res" | grep -oP '[0-9]+(?=% packet loss)')
        [ -z "$loss" ] && loss="100"
        
        local avg="---"
        if echo "$res" | grep -q "min/avg/max"; then
            avg=$(echo "$res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
            [ -n "$avg" ] && avg="${avg}ms"
        fi
        echo "${T_NAME}|${avg}|${loss}" >> "$SECURE_TMP/.mgre_stats_cache.tmp"
    done
    mv -f "$SECURE_TMP/.mgre_stats_cache.tmp" "$SECURE_TMP/.mgre_stats_cache" 2>/dev/null
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
    local rel_path="tunnels/mgre.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mgre_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mgre_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (MGRE Engine) ]${NC}"
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
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_opt
    
    local tmp_file="$SECURE_TMP/.mgre_update.$$"
    > "$tmp_file"

    if [[ "$src_opt" == "4" ]]; then
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste your code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
            sleep 2; nano "$tmp_file"
        elif command -v vi >/dev/null 2>&1; then
            vi "$tmp_file"
        else
            echo -e "  ${R}✖ No text editor (nano/vi) found on this system!${NC}"; rm -f "$tmp_file"; sleep 2; return
        fi
    elif [[ "$src_opt" =~ ^[123]$ ]]; then
        local dl_url=""
        case $src_opt in
            1) dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path$cb" ;;
            2) dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path$cb" ;;
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read custom_url; dl_url=$(echo "$custom_url" | tr -d '\r ') ;;
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
        local new_ver=$(grep -m1 '^MODULE_VERSION=' "$tmp_file" | cut -d'"' -f2)
        [ -z "$new_ver" ] && new_ver="Unknown"
        
        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read confirm
        
        if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
            sed -i 's/\r$//' "$tmp_file" 2>/dev/null
            chmod +x "$tmp_file"
            
            cat "$tmp_file" > "$INSTALL_PATH" 2>/dev/null || true
            [ -f "$0" ] && cat "$tmp_file" > "$0" 2>/dev/null || true
            cp -f "$tmp_file" "$LOCAL_DIR/$rel_path" 2>/dev/null
            
            rm -f "$tmp_file"
            echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
            sleep 1.5
            exec "$INSTALL_PATH" "$@"
        else
            echo -e "  ${Y}● Update cancelled by user.${NC}"
            rm -f "$tmp_file"; sleep 1.5
        fi
    else
        echo -e "  ${R}✖ Update failed. Invalid format or network timeout.${NC}"
        rm -f "$tmp_file"
        sleep 2
    fi
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

get_iface_uptime() {
    local iface="$1"
    if [ ! -d "/sys/class/net/$iface" ] || [ "$(cat /sys/class/net/$iface/operstate 2>/dev/null)" == "down" ]; then
        echo "DOWN"
        return
    fi
    local sys_uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    local if_sec=$(ip -s -d link show "$iface" 2>/dev/null | grep -oP 'trans_start \K[0-9]+')
    if [ -n "$if_sec" ] && [ "$if_sec" -gt 0 ]; then
        local delta=$(( (sys_uptime * 100 - if_sec) / 100 ))
        [ "$delta" -lt 0 ] && delta=0
    else
        local created=$(stat -c %Y "/sys/class/net/$iface" 2>/dev/null)
        local now=$(date +%s)
        local delta=$(( now - created ))
        [ "$delta" -lt 0 ] && delta=0
    fi
    local d=$(( delta / 86400 ))
    local h=$(( (delta % 86400) / 3600 ))
    local m=$(( (delta % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
    else printf "%dm" "$m"; fi
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

clean_fwd_rules() {
    local t="$1"
    iptables -t nat -S PREROUTING 2>/dev/null | grep "MGRE_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t nat $r 2>/dev/null; done
    iptables -t nat -S POSTROUTING 2>/dev/null | grep "MGRE_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t nat $r 2>/dev/null; done
    iptables -t filter -S FORWARD 2>/dev/null | grep "MGRE_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t filter $r 2>/dev/null; done
}

apply_tunnel() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf"
    
    local c_sub="${CORE_SUBNET}"
    local local_tun=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
    local remote_tun=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
    
    iptables -t mangle -S FORWARD 2>/dev/null | grep "MGRE_MSS_${T_NAME}\"" | sed 's/^-A /-D /' | while read r; do iptables -t mangle $r 2>/dev/null; done
    clean_fwd_rules "$T_NAME"
    
    ip tunnel del "$T_NAME" >/dev/null 2>&1; ip tunnel del "sit_$T_NAME" >/dev/null 2>&1

    if [[ "$TUN_PROTO" == "6to4" ]]; then
        ip tunnel add "sit_$T_NAME" mode sit remote "$REMOTE_PUB" local "$LOCAL_PUB" 2>/dev/null
        ip link set dev "sit_$T_NAME" mtu 1480 2>/dev/null; ip link set "sit_$T_NAME" up 2>/dev/null
        ip -6 addr add "$LOCAL_IP6/64" dev "sit_$T_NAME" 2>/dev/null
        ip -6 tunnel add "$T_NAME" mode ip6gre remote "$REMOTE_IP6" local "$LOCAL_IP6" key "$TUN_ID" 2>/dev/null
        ip link set dev "$T_NAME" mtu 1436 2>/dev/null; ip link set "$T_NAME" up 2>/dev/null
        ip addr add "$local_tun"/30 dev "$T_NAME" 2>/dev/null
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1396 -m comment --comment "MGRE_MSS_$T_NAME" 2>/dev/null
    else
        local mtu_val=$([ "$TYPE" == "1" ] && echo "1436" || echo "1476")
        ip tunnel add "$T_NAME" mode gre remote "$REMOTE_PUB" local "$LOCAL_PUB" ttl 255 key "$TUN_ID" 2>/dev/null
        ip link set "$T_NAME" up 2>/dev/null; ip addr add "$local_tun"/30 dev "$T_NAME" 2>/dev/null
        ip link set dev "$T_NAME" mtu "$mtu_val" 2>/dev/null
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss $((mtu_val - 40)) -m comment --comment "MGRE_MSS_$T_NAME" 2>/dev/null
    fi

    local all_targets=("$remote_tun")
    
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
            if ! ip route show | grep -q "$nip"; then ip addr add "$nip/30" dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null; fi
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
                            iptables -t nat -A PREROUTING -p tcp -m tcp --dport "$p" -m statistic --mode nth --every "$remaining" --packet 0 -j DNAT --to-destination "$dst_ip" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        else
                            iptables -t nat -A PREROUTING -p tcp -m tcp --dport "$p" -j DNAT --to-destination "$dst_ip" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        fi
                        iptables -t nat -A POSTROUTING -p tcp -m tcp -d "$dst_ip" --dport "$p" -j MASQUERADE -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        iptables -t filter -A FORWARD -p tcp -d "$dst_ip" --dport "$p" -j ACCEPT -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    done
                else
                    iptables -t nat -A PREROUTING -p tcp -m tcp --dport "$p" -j DNAT --to-destination "$remote_tun" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    iptables -t nat -A POSTROUTING -p tcp -m tcp -d "$remote_tun" --dport "$p" -j MASQUERADE -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    iptables -t filter -A FORWARD -p tcp -d "$remote_tun" --dport "$p" -j ACCEPT -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
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
                            iptables -t nat -A PREROUTING -p udp -m udp --dport "$p" -m statistic --mode nth --every "$remaining" --packet 0 -j DNAT --to-destination "$dst_ip" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        else
                            iptables -t nat -A PREROUTING -p udp -m udp --dport "$p" -j DNAT --to-destination "$dst_ip" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        fi
                        iptables -t nat -A POSTROUTING -p udp -m udp -d "$dst_ip" --dport "$p" -j MASQUERADE -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                        iptables -t filter -A FORWARD -p udp -d "$dst_ip" --dport "$p" -j ACCEPT -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    done
                else
                    iptables -t nat -A PREROUTING -p udp -m udp --dport "$p" -j DNAT --to-destination "$remote_tun" -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    iptables -t nat -A POSTROUTING -p udp -m udp -d "$remote_tun" --dport "$p" -j MASQUERADE -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                    iptables -t filter -A FORWARD -p udp -d "$remote_tun" --dport "$p" -j ACCEPT -m comment --comment "MGRE_FWD_$T_NAME" 2>/dev/null
                fi
            done
        fi
    fi
}

apply_all_tunnels() {
    for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && apply_tunnel "$conf"; done
}

select_tunnel_interactive() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; fi
    echo -e "\n  ${B}╭────────────────── Select Target Tunnel ───────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        local conf_name=$(basename "${configs[$i]}" .conf)
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$conf_name"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Tunnel Index or 'q': ${NC}"; read t_idx
    [[ "$t_idx" == "q" || -z "$t_idx" || -z "${configs[$t_idx]}" ]] && return 1
    SELECTED_CONF="${configs[$t_idx]}"
    return 0
}

# --- DIRECT ACTIONS EXTRACTED TO MAIN ---
action_edit_public_ips() {
    select_tunnel_interactive || return
    source "$SELECTED_CONF" 2>/dev/null
    echo -e "\n  ${DIM}┌─[ EDIT PUBLIC IPs: ${W}${T_NAME}${DIM} ]${NC}"
    echo -ne "  ${C}●${NC} ${W}New Local Public IP [${Y}${LOCAL_PUB}${W}]: ${NC}"; read new_local
    echo -ne "  ${C}●${NC} ${W}New Remote Public IP [${Y}${REMOTE_PUB}${W}]: ${NC}"; read new_remote
    new_local=$(echo "$new_local" | tr -dc '0-9.')
    new_remote=$(echo "$new_remote" | tr -dc '0-9.')
    [ -n "$new_local" ] && sed -i "s/^LOCAL_PUB=.*/LOCAL_PUB=$new_local/" "$SELECTED_CONF"
    [ -n "$new_remote" ] && sed -i "s/^REMOTE_PUB=.*/REMOTE_PUB=$new_remote/" "$SELECTED_CONF"
    apply_tunnel "$SELECTED_CONF"
    echo -e "  ${G}● Public IPs updated and applied.${NC}"; sleep 1.5
}

action_edit_token() {
    select_tunnel_interactive || return
    source "$SELECTED_CONF" 2>/dev/null
    echo -e "\n  ${DIM}┌─[ EDIT MASTER TOKEN: ${W}${T_NAME}${DIM} ]${NC}"
    echo -ne "  ${C}●${NC} ${W}New Tunnel Secret Token (Regenerates Network): ${NC}"; read new_tok
    new_tok=$(echo "$new_tok" | tr -dc 'a-zA-Z0-9_=-')
    if [ -n "$new_tok" ]; then
        local hash_c=$(echo -n "core_${new_tok}" | sha256sum)
        local new_tun_id=$(( 16#${hash_c:0:6} ))
        local class_selector=$(( 16#${hash_c:6:2} % 3 ))
        local c1=""; local c2=""; local c3=""
        if [ "$class_selector" == "0" ]; then c1="10"; c2=$(( (16#${hash_c:8:2} % 254) + 1 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
        elif [ "$class_selector" == "1" ]; then c1="172"; c2=$(( (16#${hash_c:8:2} % 16) + 16 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
        else c1="192"; c2="168"; c3=$(( (16#${hash_c:10:2} % 254) + 1 )); fi
        local new_core_sub="${c1}.${c2}.${c3}"
        
        if grep -q "TUN_ID=$new_tun_id$" "$CONF_DIR"/*.conf 2>/dev/null || grep -q "CORE_SUBNET=$new_core_sub$" "$CONF_DIR"/*.conf 2>/dev/null; then
            echo -e "  ${R}● Collision detected with an existing tunnel!${NC}"; sleep 2; return
        fi
        
        sed -i "s/^TUN_SECRET=.*/TUN_SECRET=$new_tok/" "$SELECTED_CONF"
        sed -i "s/^TUN_ID=.*/TUN_ID=$new_tun_id/" "$SELECTED_CONF"
        sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_core_sub/" "$SELECTED_CONF"
        sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$new_tok/" "$SELECTED_CONF"
        apply_tunnel "$SELECTED_CONF"
        echo -e "  ${G}● Token updated. Key: ${new_tun_id}, Subnet: ${new_core_sub}.x${NC}"; sleep 1.5
    fi
}

action_edit_core_subnet() {
    select_tunnel_interactive || return
    source "$SELECTED_CONF" 2>/dev/null
    echo -e "\n  ${DIM}┌─[ EDIT CORE SUBNET: ${W}${T_NAME}${DIM} ]${NC}"
    echo -ne "  ${C}●${NC} ${W}New Core Subnet Base [${Y}${CORE_SUBNET}${W}] (e.g. 10.76.5): ${NC}"; read new_sub
    new_sub=$(echo "$new_sub" | tr -dc '0-9.')
    if [ -n "$new_sub" ]; then
        sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_sub/" "$SELECTED_CONF"
        apply_tunnel "$SELECTED_CONF"
        echo -e "  ${G}● Core subnet updated.${NC}"; sleep 1.5
    fi
}

action_edit_port_forward() {
    select_tunnel_interactive || return
    source "$SELECTED_CONF" 2>/dev/null
    if [ "$TYPE" != "1" ]; then echo -e "  ${Y}● Port forwarding is only available on IRAN nodes.${NC}"; sleep 1.5; return; fi
    
    while true; do
        echo -e "\n  ${DIM}┌─[ PORT FORWARDING & LOAD BALANCER: ${W}${T_NAME}${DIM} ]${NC}"
        echo -e "  ${DIM}│${NC} ${DIM}Current TCP:${NC} ${Y}${FWD_TCP:-None}${NC}"
        echo -e "  ${DIM}│${NC} ${DIM}Current UDP:${NC} ${C}${FWD_UDP:-None}${NC}"
        echo -e "  ${DIM}│${NC} ${DIM}Load Balancer:${NC} $([ "$LB_MODE" == "1" ] && echo "${G}ON${NC}" || echo "${DIM}OFF${NC}")"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add New Ports (Keep Existing)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Remove Specific Ports${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Replace All Ports (Overwrite)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Toggle Load Balancer${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back to Main Menu${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"; read pf_opt

        case $pf_opt in
            1)
                echo -ne "  ${C}●${NC} ${W}Add TCP Ports: ${NC}"; read add_tcp
                echo -ne "  ${C}●${NC} ${W}Add UDP Ports: ${NC}"; read add_udp
                add_tcp=$(echo "$add_tcp" | tr -dc '0-9,'); add_udp=$(echo "$add_udp" | tr -dc '0-9,')
                local m_tcp=$(merge_ports "$FWD_TCP" "$add_tcp"); local m_udp=$(merge_ports "$FWD_UDP" "$add_udp")
                grep -v "^FWD_TCP=" "$SELECTED_CONF" | grep -v "^FWD_UDP=" > "${SELECTED_CONF}.tmp"
                echo "FWD_TCP=$m_tcp" >> "${SELECTED_CONF}.tmp"; echo "FWD_UDP=$m_udp" >> "${SELECTED_CONF}.tmp"
                mv "${SELECTED_CONF}.tmp" "$SELECTED_CONF"; FWD_TCP="$m_tcp"; FWD_UDP="$m_udp"
                apply_tunnel "$SELECTED_CONF"; echo -e "  ${G}● Ports added.${NC}"; sleep 1.5 ;;
            2)
                echo -ne "  ${C}●${NC} ${W}Remove TCP Ports: ${NC}"; read rm_tcp
                echo -ne "  ${C}●${NC} ${W}Remove UDP Ports: ${NC}"; read rm_udp
                rm_tcp=$(echo "$rm_tcp" | tr -dc '0-9,'); rm_udp=$(echo "$rm_udp" | tr -dc '0-9,')
                local m_tcp=$(remove_ports "$FWD_TCP" "$rm_tcp"); local m_udp=$(remove_ports "$FWD_UDP" "$rm_udp")
                grep -v "^FWD_TCP=" "$SELECTED_CONF" | grep -v "^FWD_UDP=" > "${SELECTED_CONF}.tmp"
                echo "FWD_TCP=$m_tcp" >> "${SELECTED_CONF}.tmp"; echo "FWD_UDP=$m_udp" >> "${SELECTED_CONF}.tmp"
                mv "${SELECTED_CONF}.tmp" "$SELECTED_CONF"; FWD_TCP="$m_tcp"; FWD_UDP="$m_udp"
                apply_tunnel "$SELECTED_CONF"; echo -e "  ${G}● Ports removed.${NC}"; sleep 1.5 ;;
            3)
                echo -ne "  ${C}●${NC} ${W}New TCP Ports: ${NC}"; read new_tcp
                echo -ne "  ${C}●${NC} ${W}New UDP Ports: ${NC}"; read new_udp
                new_tcp=$(echo "$new_tcp" | tr -dc '0-9,'); new_udp=$(echo "$new_udp" | tr -dc '0-9,')
                grep -v "^FWD_TCP=" "$SELECTED_CONF" | grep -v "^FWD_UDP=" > "${SELECTED_CONF}.tmp"
                echo "FWD_TCP=$new_tcp" >> "${SELECTED_CONF}.tmp"; echo "FWD_UDP=$new_udp" >> "${SELECTED_CONF}.tmp"
                mv "${SELECTED_CONF}.tmp" "$SELECTED_CONF"; FWD_TCP="$new_tcp"; FWD_UDP="$new_udp"
                apply_tunnel "$SELECTED_CONF"; echo -e "  ${G}● Ports replaced.${NC}"; sleep 1.5 ;;
            4)
                local new_lb="1"; [ "$LB_MODE" == "1" ] && new_lb="0"
                sed -i "s/^LB_MODE=.*/LB_MODE=$new_lb/" "$SELECTED_CONF"; LB_MODE="$new_lb"
                apply_tunnel "$SELECTED_CONF"; echo -e "  ${G}● Load Balancer toggled.${NC}"; sleep 1.5 ;;
            0) break ;;
        esac
    done
}

action_rename_interface() {
    select_tunnel_interactive || return
    source "$SELECTED_CONF" 2>/dev/null
    echo -e "\n  ${DIM}┌─[ RENAME TUNNEL: ${W}${T_NAME}${DIM} ]${NC}"
    echo -ne "  ${C}●${NC} ${W}New Interface Suffix (Current: ${Y}${T_NAME#gre*}${W}): ${NC}"; read new_suffix
    new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
    if [ -n "$new_suffix" ]; then
        local pfx=$([ "$TUN_PROTO" == "6to4" ] && echo "$([ "$TYPE" == "1" ] && echo "gre6ir" || echo "gre6kh")" || echo "$([ "$TYPE" == "1" ] && echo "greir" || echo "grekh")")
        local new_t_name="${pfx}${new_suffix}"
        local check_len=${#new_t_name}; [ "$TUN_PROTO" == "6to4" ] && check_len=$((check_len + 4))
        if [ "$check_len" -gt 15 ]; then echo -e "  ${R}● Error: Name exceeds 15 chars limit!${NC}"; sleep 1.5; return; fi
        if [ -f "$CONF_DIR/${new_t_name}.conf" ]; then echo -e "  ${R}● Error: Interface already exists!${NC}"; sleep 1.5; return; fi
        
        iptables -t mangle -S FORWARD 2>/dev/null | grep "MGRE_MSS_${T_NAME}\"" | sed 's/^-A /-D /' | while read r; do iptables -t mangle $r 2>/dev/null; done
        clean_fwd_rules "$T_NAME"
        ip tunnel del "$T_NAME" >/dev/null 2>&1; ip tunnel del "sit_$T_NAME" >/dev/null 2>&1
        
        sed -i "s/^T_NAME=.*/T_NAME=$new_t_name/" "$SELECTED_CONF"
        mv "$SELECTED_CONF" "$CONF_DIR/${new_t_name}.conf"
        apply_tunnel "$CONF_DIR/${new_t_name}.conf"
        echo -e "  ${G}● Tunnel renamed to: ${new_t_name}${NC}"; sleep 1.5
    fi
}

draw_mgre_header() {
    local s_ip=$(get_local_ip)
    local active_tunnels=0
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue
        T_NAME=""; source "$conf" 2>/dev/null
        if ip link show "$T_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" != "down" ]; then
            ((active_tunnels++))
        fi
    done

    clear; echo ""
    local border="────────────────────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${B}╭${border}╮${NC}"
    printf "  ${B}│${NC} ${W}MGRE Modular Core v%-7s${NC} ${B}│${NC} ${DIM}Local:${NC} ${W}%-15s${NC} ${B}│${NC} ${DIM}Active Tunnels:${NC} ${G}%-3s${NC} ${DIM}(Max 3 Shown)${NC}      ${B}│${NC}\n" "$MODULE_VERSION" "$s_ip" "$active_tunnels"
    echo -e "  ${B}├${border}┤${NC}"

    local shown=0
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; REMOTE_PUB=""; T_NAME=""; FWD_TCP=""; FWD_UDP=""; source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        ((shown++))
        [ "$shown" -gt 3 ] && break

        local live_ping="---" live_loss="---"
        if [ -f "$SECURE_TMP/.mgre_stats_cache" ]; then
            local cached_entry=$(grep "^${T_NAME}|" "$SECURE_TMP/.mgre_stats_cache" 2>/dev/null | head -n1)
            if [ -n "$cached_entry" ]; then
                live_ping=$(echo "$cached_entry" | cut -d'|' -f2)
                live_loss="$(echo "$cached_entry" | cut -d'|' -f3)%"
            fi
        fi

        local fwd_str="OFF"
        if [ "$TYPE" == "1" ]; then
            if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
            elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:6}"
            elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:6}"
            fi
        else
            fwd_str="GATEWAY"
        fi

        local tun_uptime=$(get_iface_uptime "$T_NAME")
        local stat_icon="●"; local stat_col="${G}"
        if [ "$tun_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi

        local fwd_col="${DIM}"; [ "$fwd_str" != "OFF" ] && fwd_col="${C}"
        local loss_col="${G}"; [[ "$live_loss" != "0%" && "$live_loss" != "---" ]] && loss_col="${R}"

        printf "  ${B}│${NC} %b%s%b ${W}%-8s${NC} ${DIM}➔${NC} ${Y}%-15s${NC} ${B}│${NC} ${DIM}Ping:${NC} ${Y}%-7s${NC} ${loss_col}%-4s${NC} ${B}│${NC} ${DIM}Up:${NC} ${W}%-8s${NC} ${B}│${NC} ${DIM}FWD:${NC} %b%-7s%b ${B}│${NC}\n" \
            "$stat_col" "$stat_icon" "$NC" "$T_NAME" "$REMOTE_PUB" "$live_ping" "$live_loss" "$tun_uptime" "$fwd_col" "$fwd_str" "$NC"
    done

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}%-88s${NC}  ${B}│${NC}\n" "● No active tunnels configured on this host."
    fi
    echo -e "  ${B}╰${border}╯${NC}"
}

show_mgre_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf" 2>/dev/null
        mapfile -t v_ips < <(ip -4 addr show dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
        local title_color="${C}"; local proto_lbl="IPv4"
        [[ "$TUN_PROTO" == "6to4" ]] && { title_color="${M}"; proto_lbl="IP6GRE"; }

        local title_txt="${T_NAME} [${proto_lbl}]"
        local raw_l1=" ▼ ${title_txt} | PUB: ${LOCAL_PUB} -> ${REMOTE_PUB}"
        local pad1=$(( 92 - ${#raw_l1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        local eval_l1=$(printf " %b▼ %s%b ${DIM}| PUB: ${W}%s ${DIM}→${W} %s${NC}" "${title_color}" "${title_txt}" "${NC}" "${LOCAL_PUB}" "${REMOTE_PUB}")
        
        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC}${eval_l1}${sp1}${B}│${NC}"
        
        if [ "$TYPE" == "1" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then
            local disp_tcp="${FWD_TCP:-0}"; [ ${#disp_tcp} -gt 30 ] && disp_tcp="${disp_tcp:0:27}..."
            local disp_udp="${FWD_UDP:-0}"; [ ${#disp_udp} -gt 30 ] && disp_udp="${disp_udp:0:27}..."
            local lb_txt="OFF"; [ "$LB_MODE" == "1" ] && lb_txt="ON"
            local raw_l2="   ↳ NAT: T:[${disp_tcp}] U:[${disp_udp}] LB:[${lb_txt}]"
            local pad2=$(( 92 - ${#raw_l2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
            local lb_stat=$([ "$LB_MODE" == "1" ] && echo "${G}ON${NC}" || echo "${DIM}OFF${NC}")
            local eval_l2="   ${DIM}↳ NAT:${NC} ${Y}T:[${disp_tcp}]${NC} ${C}U:[${disp_udp}]${NC} ${DIM}LB:[${lb_stat}${DIM}]${NC}"
            echo -e "  ${B}│${NC}${eval_l2}${sp2}${B}│${NC}"
        fi

        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        local c_sub="${CORE_SUBNET}"
        local main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local main_lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        
        local ping_res=$(timeout 2 ping -c 1 -W 1 "$main_tip" 2>/dev/null)
        local lat lat_raw lat_color stat_icon stat_text stat_color
        if echo "$ping_res" | grep -q "time="; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
            lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
        
        local m_icon="├─"; [ ${#v_ips[@]} -eq 0 ] && m_icon="└─"
        printf "  ${B}│${NC} ${W}%s %-15s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} ${W}%-18s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%s %-10s%b ${B}│${NC}\n" "${m_icon}" "Core IP" "$main_lip" "$main_tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        
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

show_tunnel_details() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return; fi

    echo -e "\n  ${Y}● Deployed Tunnels Registry:${NC}"
    for conf in "${configs[@]}"; do
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf" 2>/dev/null
        local c_sub="${CORE_SUBNET}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access)" || echo "KHAREJ (Gateway)")
        local t_sec="${TUN_SECRET:-[ NOT SET ]}"
        local t_id="${TUN_ID:-[ NOT SET ]}"

        local proto_lbl="IPv4 GRE"; [[ "$TUN_PROTO" == "6to4" ]] && proto_lbl="6to4 IP6GRE"

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $T_NAME"; local right_p="Role: $t_role"
        local pad=$(( 89 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp} ${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="Master Token : ${t_sec}"; local r1="Protocol: ${proto_lbl}"
        local pad1=$(( 89 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Master Token :${NC} ${W}${t_sec}${NC}${sp1} ${DIM}Protocol:${NC} ${W}${proto_lbl}${NC} ${B}│${NC}"
        
        local l2="vIP Sync Key : ${SYNC_KEY}"; local r2="Generated Network Key: ${t_id}"
        local pad2=$(( 89 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}vIP Sync Key :${NC} ${W}${SYNC_KEY}${NC}${sp2} ${DIM}Generated Network Key:${NC} ${Y}${t_id}${NC} ${B}│${NC}"
        
        local l3="Public IPs   : ${LOCAL_PUB} -> ${REMOTE_PUB}"
        local pad3=$(( 90 - ${#l3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${DIM}Public IPs   :${NC} ${W}${LOCAL_PUB}${NC} ${DIM}->${NC} ${W}${REMOTE_PUB}${NC}${sp3} ${B}│${NC}"
        
        if [ "$TYPE" == "1" ]; then
            local lb_txt=$([ "$LB_MODE" == "1" ] && echo "Active (All vIPs)" || echo "Direct (Core IP)")
            local l5="NAT FWD TCP  : ${FWD_TCP:-None}"; local r5="Load Balancer: ${lb_txt}"
            local pad5=$(( 89 - ${#l5} - ${#r5} )); [ "$pad5" -lt 0 ] && pad5=0; local sp5=$(printf '%*s' "$pad5" "")
            echo -e "  ${B}│${NC} ${Y}NAT FWD TCP  :${NC} ${W}${FWD_TCP:-None}${NC}${sp5} ${C}Load Balancer:${NC} ${W}${lb_txt}${NC} ${B}│${NC}"
        fi
        
        local ping_res=$(timeout 2 ping -c 1 -W 1 "$tip" 2>/dev/null)
        local lat lat_raw lat_color stat_icon stat_text stat_color
        if echo "$ping_res" | grep -q "time="; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
            lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
        
        local l4="Core IPs     : ${lip} -> ${tip}"; local r4_raw="Link: * ${stat_text} (${lat_raw})"
        local pad4=$(( 89 - ${#l4} - ${#r4_raw} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Core IPs     :${NC} ${G}${lip}${NC} ${DIM}->${NC} ${Y}${tip}${NC}${sp4} ${DIM}Link:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${lat_color}(${lat_raw})${NC} ${B}│${NC}"
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

setup_service() {
    local tmp_srv="$SECURE_TMP/mgre_tpl.service"
    cat <<EOF > "$tmp_srv"
[Unit]
Description=MGRE Native Edge Service
After=network.target
[Service]
ExecStart=/usr/bin/mgre --apply
Type=oneshot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    if ! cmp -s "$tmp_srv" "$SERVICE_FILE" 2>/dev/null; then
        mv -f "$tmp_srv" "$SERVICE_FILE"
        systemctl daemon-reload && systemctl enable mgre.service >/dev/null 2>&1
    else
        rm -f "$tmp_srv"
    fi
}

if [[ "$1" == "--apply" ]]; then apply_all_tunnels; exit 0; fi

render_mgre_menu() {
    badge=""
    if [ -f "$SECURE_TMP/.mgre_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.mgre_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_mgre_header
    echo -e "\n  ${DIM}┌─[ PROVISION & MANAGE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Setup New Tunnel (IPv4 / IP6GRE)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Delete Tunnels (Specific / ALL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Virtual IP Manager (Add/Purge vIPs)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ FLAT CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Edit Public IPs (Local / Remote)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Edit Master Token & Secret Key${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${Y}Override Core Subnet Base${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${G}Manage Port Forwarding & Load Balancer${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${W}Rename Tunnel Interface${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & SYSTEM ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${W}Live Detailed Monitor (Full Screen)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${M}View Tunnel Config Registry${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${G}Instant OTA Update Module${NC}${badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}

[ ! -f "$SERVICE_FILE" ] && setup_service

while true; do
    render_mgre_menu
    read_with_refresh "  ${C}MGRE ❯❯ ${NC}" opt render_mgre_menu
    case $opt in
        1) 
           echo -e "\n  ${DIM}┌─[ TUNNEL PROTOCOL ]${NC}"
           echo -e "  ${DIM}│${NC}"
           echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Standard IPv4 GRE${NC}"
           echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}6to4 IP6GRE Encapsulation${NC}"
           echo -e "  ${DIM}│${NC}"
           echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel and Go Back${NC}\n"
           while true; do echo -ne "  ${C}Select Protocol ❯❯ ${NC}"; read proto_choice; [[ "$proto_choice" == "q" ]] && break; [[ "$proto_choice" == "1" || "$proto_choice" == "2" ]] && break; done
           [[ "$proto_choice" == "q" ]] && continue
           tun_proto="ipv4"; [ "$proto_choice" == "2" ] && tun_proto="6to4"
           
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IR | 2:KH | q:Back]: ${NC}"; read s_type; [[ "$s_type" == "q" ]] && break; [[ "$s_type" == "1" || "$s_type" == "2" ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Interface Suffix Name (Max 4-5 chars): ${NC}"; read suffix
               suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
               [[ "$suffix" == "q" ]] && break; [[ -z "$suffix" ]] && continue
               pfx=$([ "$tun_proto" == "6to4" ] && echo "$([ "$s_type" == "1" ] && echo "gre6ir" || echo "gre6kh")" || echo "$([ "$s_type" == "1" ] && echo "greir" || echo "grekh")")
               t_name="${pfx}${suffix}"
               check_len=${#t_name}; [ "$tun_proto" == "6to4" ] && check_len=$((check_len + 4))
               if [ "$check_len" -gt 15 ]; then echo -e "  ${R}● Error: Name too long! Kernel limit is 15 chars.${NC}"; else break; fi
           done
           [[ "$suffix" == "q" ]] && continue
           
           if [ -f "$CONF_DIR/${t_name}.conf" ]; then echo -e "\n  ${R}● Error: Interface name [${t_name}] already exists!${NC}"; sleep 2; continue; fi
           
           local_ip=$(get_local_ip)
           while true; do
               echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}]: ${NC}"; read custom_ip
               [[ "$custom_ip" == "q" ]] && break
               custom_ip=$(echo "$custom_ip" | tr -dc '0-9.'); [ -n "$custom_ip" ] && local_ip=$custom_ip
               break
           done
           [[ "$custom_ip" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IP: ${NC}"; read r_ip
               [[ "$r_ip" == "q" ]] && break
               r_ip=$(echo "$r_ip" | tr -dc '0-9.'); [[ -n "$r_ip" ]] && break
           done
           [[ "$r_ip" == "q" ]] && continue

           s_key=$(head -c 16 /dev/urandom | xxd -p 2>/dev/null)
           [ -z "$s_key" ] && s_key=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)
           echo -ne "  ${C}●${NC} ${M}Master Secret Token [Default ${s_key}]: ${NC}"; read u_key
           [[ "$u_key" == "q" ]] && continue
           u_key=$(echo "$u_key" | tr -dc 'a-zA-Z0-9_=-')
           tun_secret=${u_key:-$s_key}

           local_ip6=""; remote_ip6=""
           if [[ "$tun_proto" == "6to4" ]]; then
               hash_str=$(echo -n "${tun_secret}_MHDesign" | sha256sum)
               pfx_v6="fd${hash_str:0:2}:${hash_str:2:4}:${hash_str:6:4}:${hash_str:10:4}"
               if [[ "$s_type" == "1" ]]; then local_ip6="${pfx_v6}::1"; remote_ip6="${pfx_v6}::2"; else local_ip6="${pfx_v6}::2"; remote_ip6="${pfx_v6}::1"; fi
           fi
           
           hash_c=$(echo -n "core_${tun_secret}" | sha256sum)
           tun_id=$(( 16#${hash_c:0:6} ))
           
           class_selector=$(( 16#${hash_c:6:2} % 3 ))
           c1=""; c2=""; c3=""
           if [ "$class_selector" == "0" ]; then c1="10"; c2=$(( (16#${hash_c:8:2} % 254) + 1 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
           elif [ "$class_selector" == "1" ]; then c1="172"; c2=$(( (16#${hash_c:8:2} % 16) + 16 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
           else c1="192"; c2="168"; c3=$(( (16#${hash_c:10:2} % 254) + 1 )); fi
           
           core_sub="${c1}.${c2}.${c3}"
           
           if grep -q "TUN_ID=$tun_id$" "$CONF_DIR"/*.conf 2>/dev/null || grep -q "CORE_SUBNET=$core_sub$" "$CONF_DIR"/*.conf 2>/dev/null; then
               echo -e "  ${R}● Collision detected with an existing tunnel!${NC}"; sleep 2; continue
           fi
           
           conf_path="$CONF_DIR/${t_name}.conf"
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=\nTUN_SECRET=$tun_secret\nT_NAME=$t_name\nTUN_ID=$tun_id\nCORE_SUBNET=$core_sub\nTUN_PROTO=$tun_proto\nLOCAL_IP6=$local_ip6\nREMOTE_IP6=$remote_ip6\nFWD_TCP=\nFWD_UDP=\nLB_MODE=0" > "$conf_path"
           chmod 600 "$conf_path"
           apply_tunnel "$conf_path"
           
           if ip link show "$t_name" >/dev/null 2>&1; then
               setup_service
               echo -e "  ${G}● Tunnel [${t_name}] deployed (Subnet: ${core_sub}.x)${NC}"
               sleep 1.5
           fi ;;
        2)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && echo -e "\n  ${R}● No tunnels to remove!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Erase ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter Index, 'all', or 'q': ${NC}"; read del_idx
           [[ "$del_idx" == "q" || -z "$del_idx" ]] && continue
           if [[ "$del_idx" == "all" ]]; then
               echo -ne "  ${R}● Delete ALL tunnels? (y/n): ${NC}"; read confirm_all
               if [[ "$confirm_all" == "y" ]]; then
                   for conf in "${configs[@]}"; do
                       source "$conf" 2>/dev/null
                       clean_fwd_rules "$T_NAME"; ip tunnel del "$T_NAME" >/dev/null 2>&1; ip tunnel del "sit_$T_NAME" >/dev/null 2>&1; rm -f "$conf"
                   done
                   [ -x "/usr/bin/mporter" ] && /usr/bin/mporter --cleanup-orphans >/dev/null 2>&1 &
                   echo -e "  ${G}● All tunnels purged.${NC}"; sleep 1.5
               fi; continue
           fi
           if [[ -n "${configs[$del_idx]}" ]]; then
               source "${configs[$del_idx]}" 2>/dev/null
               clean_fwd_rules "$T_NAME"; ip tunnel del "$T_NAME" >/dev/null 2>&1; ip tunnel del "sit_$T_NAME" >/dev/null 2>&1; rm -f "${configs[$del_idx]}"
               [ -x "/usr/bin/mporter" ] && /usr/bin/mporter --cleanup-orphans >/dev/null 2>&1 &
               echo -e "  ${G}● Tunnel [${T_NAME}] destroyed.${NC}"; sleep 1.5
           fi ;;
        3)
           select_tunnel_interactive || continue
           source "$SELECTED_CONF" 2>/dev/null
           echo -e "\n  ${DIM}┌─[ vIP ACTIONS for ${T_NAME} ]${NC}"
           echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup / Update Virtual IPs${NC}"
           echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Purge All Virtual IPs${NC}"
           echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
           while true; do echo -ne "  ${C}●${NC} ${W}Select Action: ${NC}"; read vip_action; [[ "$vip_action" =~ ^[12q]$ ]] && break; done
           [[ "$vip_action" == "q" ]] && continue
           if [[ "$vip_action" == "1" ]]; then
               while true; do echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read n; [[ -n "$n" ]] && break; done
               [[ "$n" == "q" ]] && continue
               k=$TUN_SECRET
               sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$SELECTED_CONF"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$SELECTED_CONF"
               apply_tunnel "$SELECTED_CONF"; echo -e "  ${G}● IPs synchronized.${NC}"; sleep 1.5
           elif [[ "$vip_action" == "2" ]]; then
               sed -i "s/^MAX_IPS=.*/MAX_IPS=0/" "$SELECTED_CONF"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=/" "$SELECTED_CONF"
               apply_tunnel "$SELECTED_CONF"; echo -e "  ${G}● Virtual IPs purged.${NC}"; sleep 1.5
           fi ;;
        4) action_edit_public_ips ;;
        5) action_edit_token ;;
        6) action_edit_core_subnet ;;
        7) action_edit_port_forward ;;
        8) action_rename_interface ;;
        9) while true; do draw_mgre_header; show_mgre_monitor; read -t 2 -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        10) show_tunnel_details ;; 
        11) self_update_module ;; 
        0) break ;;
    esac
done
