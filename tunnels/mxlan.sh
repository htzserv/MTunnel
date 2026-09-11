#!/bin/bash
# --- MXLAN Layer-2 Fabric (mxlan.sh) | MDesign Core v1.5.6 ---
# [Features: Refined Spacing | Async Background Checker | Minimal Badges]

MODULE_VERSION="1.5.6"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mxlan"
CONF_DIR="/etc/mgre/vxlan"
SERVICE_FILE="/etc/systemd/system/mxlan.service"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

# 1. Block Path Conflicts Automatically
[ -f "/usr/local/bin/mxlan" ] && rm -f "/usr/local/bin/mxlan" 2>/dev/null

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

is_valid_host() {
    local host=$1
    if [[ "$host" =~ ^([a-zA-Z0-9.-]+)$ ]]; then return 0; fi
    return 1
}

# --- ASYNC BACKGROUND UPDATE CHECKER ---
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
check_update_bg &
# ---------------------------------------

self_update_module() {
    local rel_path="tunnels/mxlan.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mxlan_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mxlan_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
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
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_opt
    
    local tmp_file="$SECURE_TMP/.mxlan_update.$$"
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

clean_fwd_rules() {
    local t="$1"
    iptables -t nat -S PREROUTING 2>/dev/null | grep "MXLAN_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t nat $r 2>/dev/null; done
    iptables -t nat -S POSTROUTING 2>/dev/null | grep "MXLAN_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t nat $r 2>/dev/null; done
    iptables -t filter -S FORWARD 2>/dev/null | grep "MXLAN_FWD_${t}\"" | sed 's/^-A /-D /' | while read r; do iptables -t filter $r 2>/dev/null; done
}

apply_fabric() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf"
    
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

draw_mxlan_header() {
    local s_ip=$(get_local_ip); local active_fabrics=0; local total_vips=0
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; LB_MODE="0"; source "$conf" 2>/dev/null
        if ip link show "$VX_NAME" >/dev/null 2>&1 && [ "$(cat /sys/class/net/$VX_NAME/operstate 2>/dev/null)" != "down" ]; then ((active_fabrics++)); fi
        total_vips=$((total_vips + MAX_IPS))
    done
    
    local ip_fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    local fwd_val=$([ "$ip_fwd" == "1" ] && echo "ON" || echo "OFF")
    local fwd_color="${R}"; [ "$ip_fwd" == "1" ] && fwd_color="${G}"
    
    clear; echo ""
    local str1=" MXLAN Layer-2 Edge v${MODULE_VERSION} "
    local str2=" IP: $s_ip "
    local str3=" FABRICS: $active_fabrics "
    local str4=" V-IPS: $total_vips "
    local str5=" FWD: $fwd_val "
    
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} + 1 + ${#str4} + 1 + ${#str5} ))
    local pad_len=$(( 92 - raw_len )); [ "$pad_len" -lt 0 ] && pad_len=0; local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} FABRICS:${NC}${M} ${active_fabrics} ${NC}${B}│${NC}${DIM} V-IPS:${NC}${Y} ${total_vips} ${NC}${B}│${NC}${DIM} FWD:${NC}${fwd_color} ${fwd_val} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_mxlan_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf" 2>/dev/null
        mapfile -t v_ips < <(ip -4 addr show dev "$BR_NAME" label "${BR_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

        local title_txt="${VX_NAME}/${BR_NAME}"
        local raw_l1=" ▼ ${title_txt} | PUB: ${LOCAL_PUB} -> ${REMOTE_PUB}"
        local pad1=$(( 92 - ${#raw_l1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        local eval_l1=$(printf " %b▼ %s%b ${DIM}| PUB: ${W}%s ${DIM}→${W} %s${NC}" "${M}" "${title_txt}" "${NC}" "${LOCAL_PUB}" "${REMOTE_PUB}")

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

        local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        local main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local main_lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        
        local ping_res=$(ping -c 1 -W 1 "$main_tip" 2>/dev/null)
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
            ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
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

show_fabric_details() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No fabrics configured yet!${NC}"; sleep 1.5; return; fi

    echo -e "\n  ${M}● Deployed Fabrics Registry:${NC}"
    for conf in "${configs[@]}"; do
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf" 2>/dev/null
        local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        local t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access)" || echo "KHAREJ (Gateway)")
        local s_key="${SYNC_KEY:-[ NOT SET ]}"
        
        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Fabric: $VX_NAME"; local right_p="Role: $t_role"
        local pad=$(( 89 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${M}${left_p}${NC}${sp} ${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="Network VNI  : ${VNI_ID}"; local r1="Protocol: Layer-2 VXLAN"
        local pad1=$(( 89 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${C}Network VNI  :${NC} ${W}${VNI_ID}${NC}${sp1} ${DIM}Protocol:${NC} ${W}Layer-2 VXLAN${NC} ${B}│${NC}"
        
        local l2="Public IPs   : ${LOCAL_PUB} -> ${REMOTE_PUB}"
        local pad2=$(( 90 - ${#l2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${DIM}Public IPs   :${NC} ${W}${LOCAL_PUB}${NC} ${DIM}->${NC} ${W}${REMOTE_PUB}${NC}${sp2} ${B}│${NC}"
        
        if [ "$TYPE" == "1" ]; then
            local lb_txt=$([ "$LB_MODE" == "1" ] && echo "Active (All vIPs)" || echo "Direct (Core IP)")
            local l3="NAT FWD TCP  : ${FWD_TCP:-None}"; local r3="Load Balancer: ${lb_txt}"
            local pad3=$(( 89 - ${#l3} - ${#r3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
            echo -e "  ${B}│${NC} ${Y}NAT FWD TCP  :${NC} ${W}${FWD_TCP:-None}${NC}${sp3} ${C}Load Balancer:${NC} ${W}${lb_txt}${NC} ${B}│${NC}"
        fi
        
        local ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
        local lat lat_raw lat_color stat_icon stat_text stat_color
        if echo "$ping_res" | grep -q "time="; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
            lat_raw="${lat}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
        
        local l4="Bridge IPs   : ${lip} -> ${tip}"; local r4_raw="Link: * ${stat_text} (${lat_raw})"
        local pad4=$(( 89 - ${#l4} - ${#r4_raw} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Bridge IPs   :${NC} ${G}${lip}${NC} ${DIM}->${NC} ${Y}${tip}${NC}${sp4} ${DIM}Link:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${lat_color}(${lat_raw})${NC} ${B}│${NC}"
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
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
        local sel_conf="${configs[$t_idx]}"; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$sel_conf" 2>/dev/null
        
        echo -e "\n  ${DIM}┌─[ ADVANCED EDIT: ${W}${VX_NAME}${DIM} ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Edit Public IPs (Local / Remote)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Edit VNI Network ID (Current: ${VNI_ID})${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Edit Core Subnet (Current: ${CORE_SUBNET}.x)${NC}"
        if [ "$TYPE" == "1" ]; then
            echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Edit Port Forwarding & Load Balancer${NC}"
        fi
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Rename Fabric Interface (Current: ${VX_NAME})${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"; read e_opt

        case $e_opt in
            1)
                echo -ne "  ${C}●${NC} ${W}New Local Public IP [${Y}${LOCAL_PUB}${W}] (Enter to Skip): ${NC}"; read new_local
                echo -ne "  ${C}●${NC} ${W}New Remote Public IP [${Y}${REMOTE_PUB}${W}] (Enter to Skip): ${NC}"; read new_remote
                
                new_local=$(echo "$new_local" | tr -dc '0-9.')
                new_remote=$(echo "$new_remote" | tr -dc '0-9.')
                
                [ -n "$new_local" ] && sed -i "s/^LOCAL_PUB=.*/LOCAL_PUB=$new_local/" "$sel_conf"
                [ -n "$new_remote" ] && sed -i "s/^REMOTE_PUB=.*/REMOTE_PUB=$new_remote/" "$sel_conf"
                ;;
            2)
                echo -ne "  ${C}●${NC} ${W}New VNI ID (1-16777215) [Enter to Skip]: ${NC}"; read new_vni
                new_vni=$(echo "$new_vni" | tr -dc '0-9')
                if [ -n "$new_vni" ]; then
                    if grep -q "VNI_ID=$new_vni$" "$CONF_DIR"/*.conf 2>/dev/null; then
                        echo -e "  ${R}✖ VNI [${new_vni}] is already in use!${NC}"; sleep 1.5; return
                    fi
                    
                    local hash_c=$(echo -n "vni_${new_vni}" | sha256sum)
                    local class_selector=$(( new_vni % 3 ))
                    
                    if [ "$class_selector" == "1" ]; then local c1="10"; local c2=$(( (0x${hash_c:2:2} % 254) + 1 )); local c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
                    elif [ "$class_selector" == "2" ]; then local c1="172"; local c2=$(( (0x${hash_c:2:2} % 16) + 16 )); local c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
                    else local c1="192"; local c2="168"; local c3=$(( (0x${hash_c:4:2} % 254) + 1 )); fi
                    
                    local new_core_sub="${c1}.${c2}.${c3}"
                    
                    sed -i "s/^VNI_ID=.*/VNI_ID=$new_vni/" "$sel_conf"
                    sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_core_sub/" "$sel_conf"
                    echo -e "  ${G}● VNI updated. Subnet automatically changed to ${new_core_sub}.x${NC}"
                fi
                ;;
            3)
                echo -ne "  ${C}●${NC} ${W}New Core Subnet Base (e.g. 10.88.5) [Enter to Skip]: ${NC}"; read new_sub
                new_sub=$(echo "$new_sub" | tr -dc '0-9.')
                if [ -n "$new_sub" ]; then
                    sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_sub/" "$sel_conf"
                fi
                ;;
            4)
                if [ "$TYPE" != "1" ]; then return; fi
                echo -ne "  ${C}●${NC} ${W}New TCP Ports (e.g. 80,443) [Current: ${Y}${FWD_TCP:-None}${W}]: ${NC}"; read new_tcp
                echo -ne "  ${C}●${NC} ${W}New UDP Ports (e.g. 53,7000) [Current: ${C}${FWD_UDP:-None}${W}]: ${NC}"; read new_udp
                new_tcp=$(echo "$new_tcp" | tr -dc '0-9,')
                new_udp=$(echo "$new_udp" | tr -dc '0-9,')
                
                local new_lb="0"
                if [ -n "$new_tcp" ] || [ -n "$new_udp" ]; then
                    echo -ne "  ${C}●${NC} ${W}Load Balance (Distribute) traffic across all Virtual IPs? (y/n): ${NC}"; read ask_lb
                    ask_lb=$(echo "$ask_lb" | tr -d '\r' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
                    if [[ "$ask_lb" == "y" || "$ask_lb" == "yes" ]]; then new_lb="1"; fi
                fi
                
                grep -v "^FWD_TCP=" "$sel_conf" | grep -v "^FWD_UDP=" | grep -v "^LB_MODE=" > "${sel_conf}.tmp"
                echo "FWD_TCP=$new_tcp" >> "${sel_conf}.tmp"
                echo "FWD_UDP=$new_udp" >> "${sel_conf}.tmp"
                echo "LB_MODE=$new_lb" >> "${sel_conf}.tmp"
                mv "${sel_conf}.tmp" "$sel_conf"
                ;;
            5)
                echo -ne "  ${C}●${NC} ${W}New Fabric Suffix (Current: ${Y}${VX_NAME#vx_}${W}, Max 4-5 chars): ${NC}"; read new_suffix
                new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
                if [ -n "$new_suffix" ]; then
                    local new_vx_name="vx_${new_suffix}"
                    local new_br_name="br_${new_suffix}"
                    
                    if [ -f "$CONF_DIR/${new_vx_name}.conf" ]; then echo -e "  ${R}● Error: Fabric [${new_vx_name}] already exists!${NC}"; sleep 1.5; return; fi
                    
                    clean_fwd_rules "$VX_NAME"
                    ip link del "$VX_NAME" >/dev/null 2>&1
                    ip link del "$BR_NAME" >/dev/null 2>&1
                    
                    sed -i "s/^VX_NAME=.*/VX_NAME=$new_vx_name/" "$sel_conf"
                    sed -i "s/^BR_NAME=.*/BR_NAME=$new_br_name/" "$sel_conf"
                    mv "$sel_conf" "$CONF_DIR/${new_vx_name}.conf"
                    sel_conf="$CONF_DIR/${new_vx_name}.conf"
                    VX_NAME="$new_vx_name"
                    BR_NAME="$new_br_name"
                    echo -e "  ${G}● Fabric successfully renamed to: ${new_vx_name}${NC}"
                fi
                ;;
            *) return ;;
        esac

        apply_fabric "$sel_conf"
        echo -e "  ${G}● Fabric [${VX_NAME}] updated and applied successfully!${NC}"; sleep 1.5
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
    badge=""
    if [ -f "$SECURE_TMP/.mxlan_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.mxlan_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_mxlan_header
    echo -e "\n  ${DIM}┌─[ DEPLOYMENT & DESTRUCTION ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${M}Setup New VXLAN Fabric (VNI Mesh)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Delete Fabrics (Specific / ALL)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Virtual IP Manager (Add/Purge vIPs)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Advanced Edit Fabric (IPs / VNI / NAT / Rename)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & DETAILS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${M}View Fabric Configurations & Details${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${G}Instant OTA Update (Sync Module)${NC}${badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    
    echo -ne "  ${M}MXLAN ❯❯ ${NC}"; read opt
    case $opt in
        1) 
           echo -e "\n  ${DIM}┌─[ VXLAN DEPLOYMENT ]${NC}"
           while true; do
               echo -ne "  ${C}●${NC} ${W}Server Mode [1:IR | 2:KH | q:Back]: ${NC}"; read s_type
               [[ "$s_type" == "q" || "$s_type" == "1" || "$s_type" == "2" ]] && break
           done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Fabric Suffix Name (e.g. ir, kh): ${NC}"; read suffix
               suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
               [[ "$suffix" == "q" ]] && break
               [[ -z "$suffix" ]] && continue
               
               vx_name="vx_${suffix}"; br_name="br_${suffix}"
               if [ -f "$CONF_DIR/${vx_name}.conf" ] || ip link show "$vx_name" >/dev/null 2>&1; then
                   echo -e "  ${R}● Error: Interface [${vx_name}] already exists!${NC}"; continue
               fi
               break
           done
           [[ "$suffix" == "q" ]] && continue
           
           local_ip=$(get_local_ip)
           while true; do
               echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}] (Enter for default): ${NC}"; read custom_ip
               [[ "$custom_ip" == "q" ]] && break
               custom_ip=$(echo "$custom_ip" | tr -dc '0-9.')
               [ -n "$custom_ip" ] && local_ip=$custom_ip
               break
           done
           [[ "$custom_ip" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IP: ${NC}"; read r_ip
               [[ "$r_ip" == "q" ]] && break
               r_ip=$(echo "$r_ip" | tr -dc '0-9.')
               [[ -n "$r_ip" ]] && break
           done
           [[ "$r_ip" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Tunnel Network ID / VNI (1-16777215): ${NC}"; read vni_id
               [[ "$vni_id" == "q" ]] && break
               vni_id=$(echo "$vni_id" | tr -dc '0-9')
               [[ -z "$vni_id" ]] && continue
               if grep -q "VNI_ID=$vni_id$" "$CONF_DIR"/*.conf 2>/dev/null; then echo -e "  ${R}● Error: VNI assigned!${NC}"; continue; fi
               break
           done
           [[ "$vni_id" == "q" ]] && continue
           
           hash_c=$(echo -n "vni_${vni_id}" | sha256sum)
           c1="10"; c2=$(( (0x${hash_c:2:2} % 254) + 1 )); c3=$(( (0x${hash_c:4:2} % 254) + 1 ))
           core_sub="${c1}.${c2}.${c3}"
           conf_path="$CONF_DIR/${vx_name}.conf"
           
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=\nVX_NAME=$vx_name\nBR_NAME=$br_name\nVNI_ID=$vni_id\nCORE_SUBNET=$core_sub\nFWD_TCP=\nFWD_UDP=\nLB_MODE=0" > "$conf_path"
           chmod 600 "$conf_path"
           
           apply_fabric "$conf_path"
           if ip link show "$vx_name" >/dev/null 2>&1; then
               setup_service
               echo -e "  ${G}● Fabric [${vx_name}] deployed (Subnet: ${core_sub}.x)${NC}"
               
               remote_tip=$([ "$s_type" == "1" ] && echo "${core_sub}.2" || echo "${core_sub}.1")
               
               echo -ne "\n  ${C}●${NC} ${W}Run initial ping test to peer now? (y/n): ${NC}"; read run_initial_ping
               run_initial_ping=$(echo "$run_initial_ping" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
               if [[ "$run_initial_ping" == "y" || "$run_initial_ping" == "yes" ]]; then
                   echo -e "  ${DIM}┌─[ INITIAL PING TEST TO PEER ]${NC}"
                   echo -e "  ${DIM}│${NC} Pinging ${remote_tip} (4 Packets)..."
                   ping_res=$(ping -c 4 -W 1 "$remote_tip" 2>&1)
                   if echo "$ping_res" | grep -q "time="; then
                       lat=$(echo "$ping_res" | grep -oP 'min/avg/max/mdev = \K[^/]+/[^/]+' | cut -d/ -f2)
                       echo -e "  ${DIM}└─${NC} ${G}SUCCESS!${NC} Latency: ${Y}${lat}ms${NC}"
                   else
                       echo -e "  ${DIM}└─${NC} ${R}FAILED!${NC} Host Unreachable."
                   fi
               fi
               
               echo -ne "\n  ${C}●${NC} ${W}Setup Virtual IPs now? (y/n): ${NC}"; read setup_vip
               setup_vip=$(echo "$setup_vip" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
               if [[ "$setup_vip" == "y" || "$setup_vip" == "yes" ]]; then
                   while true; do echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read n; [[ "$n" == "q" ]] && break; [[ -n "$n" ]] && break; done
                   if [[ "$n" != "q" ]]; then
                       while true; do 
                           echo -ne "  ${C}●${NC} ${W}Sync Key: ${NC}"; read k; [[ "$k" == "q" ]] && break
                           k=$(echo "$k" | tr -dc 'a-zA-Z0-9_-'); [[ -n "$k" ]] && break
                       done
                       if [[ "$k" != "q" ]]; then
                           sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$conf_path"
                           sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$conf_path"
                           apply_fabric "$conf_path"
                           echo -e "  ${G}● Virtual IPs applied.${NC}"
                       fi
                   fi
               fi

               if [ "$s_type" == "1" ]; then
                   echo -ne "\n  ${C}●${NC} ${W}Setup Port Forwarding? (y/n): ${NC}"; read setup_pf
                   setup_pf=$(echo "$setup_pf" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
                   if [[ "$setup_pf" == "y" || "$setup_pf" == "yes" ]]; then
                       echo -ne "  ${C}●${NC} ${Y}NAT TCP Ports: ${NC}"; read fwd_tcp
                       echo -ne "  ${C}●${NC} ${C}NAT UDP Ports: ${NC}"; read fwd_udp
                       fwd_tcp=$(echo "$fwd_tcp" | tr -dc '0-9,')
                       fwd_udp=$(echo "$fwd_udp" | tr -dc '0-9,')
                       
                       local run_lb="0"
                       if [ -n "$fwd_tcp" ] || [ -n "$fwd_udp" ]; then
                           echo -ne "  ${C}●${NC} ${W}Load Balance across all Virtual IPs? (y/n): ${NC}"; read ask_lb
                           ask_lb=$(echo "$ask_lb" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
                           [[ "$ask_lb" == "y" || "$ask_lb" == "yes" ]] && run_lb="1"
                       fi
                       
                       grep -v "^FWD_TCP=" "$conf_path" | grep -v "^FWD_UDP=" | grep -v "^LB_MODE=" > "${conf_path}.tmp"
                       echo "FWD_TCP=$fwd_tcp" >> "${conf_path}.tmp"
                       echo "FWD_UDP=$fwd_udp" >> "${conf_path}.tmp"
                       echo "LB_MODE=$run_lb" >> "${conf_path}.tmp"
                       mv "${conf_path}.tmp" "$conf_path"
                       
                       apply_fabric "$conf_path"
                       echo -e "  ${G}● Port Forwarding applied.${NC}"
                   fi
               fi
               
               sleep 2
           else
               echo -e "\n  ${R}● FATAL ERROR: Creation rejected!${NC}"; rm -f "$conf_path"; sleep 3.5
           fi ;;
        2)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && echo -e "\n  ${R}● No fabrics to remove!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Fabric to Erase ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter Index, 'all', or 'q': ${NC}"; read del_idx
           [[ "$del_idx" == "q" || -z "$del_idx" ]] && continue
           
           if [[ "$del_idx" == "all" ]]; then
               echo -ne "  ${R}● Delete ALL VXLAN fabrics? (y/n): ${NC}"; read confirm_all
               if [[ "$confirm_all" == "y" ]]; then
                   for conf in "${configs[@]}"; do
                       source "$conf" 2>/dev/null
                       clean_fwd_rules "$VX_NAME"
                       ip link del "$VX_NAME" >/dev/null 2>&1
                       ip link del "$BR_NAME" >/dev/null 2>&1
                       rm -f "$conf"
                   done
                   [ -x "/usr/bin/mporter" ] && /usr/bin/mporter --cleanup-orphans >/dev/null 2>&1 &
                   echo -e "  ${G}● All fabrics purged.${NC}"; sleep 1.5
               fi; continue
           fi
           if [[ -n "${configs[$del_idx]}" ]]; then
               source "${configs[$del_idx]}" 2>/dev/null
               clean_fwd_rules "$VX_NAME"
               ip link del "$VX_NAME" >/dev/null 2>&1
               ip link del "$BR_NAME" >/dev/null 2>&1
               rm -f "${configs[$del_idx]}"
               [ -x "/usr/bin/mporter" ] && /usr/bin/mporter --cleanup-orphans >/dev/null 2>&1 &
               echo -e "  ${G}● Fabric [${VX_NAME}] destroyed.${NC}"; sleep 1.5
           fi ;;
        3)
           configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && echo -e "\n  ${R}● No fabrics configured yet!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Fabric for vIPs ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           
           while true; do echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx; [[ "$t_idx" == "q" ]] && break 2; [[ -n "$t_idx" ]] && break; done
           
           if [[ -n "${configs[$t_idx]}" ]]; then
               sel_conf="${configs[$t_idx]}"; source "$sel_conf" 2>/dev/null
               echo -e "\n  ${DIM}┌─[ vIP ACTIONS for ${VX_NAME} ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup / Update Virtual IPs${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Purge All Virtual IPs${NC}\n  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
               while true; do echo -ne "  ${C}●${NC} ${W}Select Action: ${NC}"; read vip_action; [[ "$vip_action" =~ ^[12q]$ ]] && break; done
               [[ "$vip_action" == "q" ]] && continue
               
               if [[ "$vip_action" == "1" ]]; then
                   while true; do echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read n; [[ -n "$n" ]] && break; done
                   [[ "$n" == "q" ]] && continue
                   while true; do 
                       echo -ne "  ${C}●${NC} ${W}Sync Key: ${NC}"; read k; k=$(echo "$k" | tr -dc 'a-zA-Z0-9_-'); [[ -n "$k" ]] && break
                   done
                   [[ "$k" == "q" ]] && continue
                   sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$sel_conf"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$sel_conf"; apply_fabric "$sel_conf"; echo -e "  ${G}● IPs synchronized.${NC}"; sleep 1.5
               elif [[ "$vip_action" == "2" ]]; then
                   if [[ "$MAX_IPS" == "0" || -z "$MAX_IPS" ]]; then echo -e "  ${Y}● No Virtual IPs found!${NC}"; sleep 1.5; continue; fi
                   echo -ne "  ${R}● Delete all ${MAX_IPS} vIPs from [${VX_NAME}]? (y/n): ${NC}"; read confirm_vip
                   if [[ "$confirm_vip" == "y" ]]; then sed -i "s/^MAX_IPS=.*/MAX_IPS=0/" "$sel_conf"; sed -i "s/^SYNC_KEY=.*/SYNC_KEY=/" "$sel_conf"; apply_fabric "$sel_conf"; echo -e "  ${G}● Virtual IPs purged.${NC}"; sleep 1.5; fi
               fi
           fi ;;
        4) edit_fabric ;; 
        5) while true; do draw_mxlan_header; show_mxlan_monitor; read -t 2 -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        6) show_fabric_details ;; 
        7) self_update_module ;; 
        0) break ;;
    esac
done
