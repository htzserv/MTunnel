#!/bin/bash
# --- MDesign Modular Core (mdiag.sh) | MDiag Omni-Scanner v4.0.1 (Full Edition) ---
# [Features: Refined Spacing | Async Background Checker | Minimal OTA Badges]

MODULE_VERSION="4.0.3"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mdiag"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

GRE_DIR="/etc/mgre/tunnels"
VX_DIR="/etc/mgre/vxlan"

mkdir -p "$LOCAL_DIR/packages" "$LOCAL_DIR/tools" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

# --- ASYNC BACKGROUND UPDATE CHECKER ---
check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tools/mdiag.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tools/mdiag.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mdiag_remote_ver"
}
check_update_bg &
# ---------------------------------------

self_update_module() {
    local rel_path="tools/mdiag.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mdiag_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mdiag_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (MDiag Scanner) ]${NC}"
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
    
    local tmp_file="$SECURE_TMP/.mdiag_update.$$"
    > "$tmp_file"

    if [[ "$src_opt" == "4" ]]; then
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste your code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
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
        rm -f "$tmp_file"; return
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
        rm -f "$tmp_file"; sleep 2
    fi
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_progress_bar() {
    local pid=$1; local text=$2; local width=25; local progress=0
    tput civis
    while kill -0 "$pid" 2>/dev/null; do
        progress=$((progress + 1)); [ "$progress" -gt 95 ] && progress=95
        local filled=$(( progress * width / 100 )); local empty=$(( width - filled ))
        local bar=$(printf "%${filled}s" | tr ' ' '#'); local empty_bar=$(printf "%${empty}s" | tr ' ' '-')
        printf "\r  ${C}⟳${NC} ${W}%-22s${NC} ${M}[${bar}${DIM}${empty_bar}${M}]${NC} ${C}%3d%%${NC}" "$text" "$progress"
        sleep 0.15
    done
    local bar=$(printf "%${width}s" | tr ' ' '#')
    printf "\r  ${G}✔${NC} ${W}%-22s${NC} ${G}[${bar}]${NC} ${G}100%%${NC} \n" "$text"
    tput cnorm
}

draw_mdiag_header() {
    local s_ip=$(get_local_ip)
    local gre_c=$(ls -1 "$GRE_DIR"/*.conf 2>/dev/null | wc -l)
    local vx_c=$(ls -1 "$VX_DIR"/*.conf 2>/dev/null | wc -l)
    local total_nodes=$((gre_c + vx_c))

    clear; echo ""
    local str1=" MDiag Omni-Scanner v${MODULE_VERSION} "
    local str2=" IP: $s_ip "
    local str3=" NODES DETECTED: $total_nodes "
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} NODES DETECTED:${NC}${C} ${total_nodes} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

run_full_infrastructure_scan() {
    echo -e "\n  ${DIM}┌─[ OMNI-SCAN MATRIX ]${NC}"
    echo -e "  ${B}╭───────────────┬────────────┬──────────────────────┬──────────────┬──────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-13s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC}\n" "INTERFACE" "PROTOCOL" "PUBLIC PEER IP" "STATE" "LATENCY"
    echo -e "  ${B}├───────────────┼────────────┼──────────────────────┼──────────────┼──────────────┤${NC}"

    local has_any=false

    for conf in "$GRE_DIR"/*.conf "$VX_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; has_any=true; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; source "$conf"
        
        local proto_lbl="GRE L3"; local iface="$T_NAME"
        if [ -n "$BR_NAME" ]; then proto_lbl="VXLAN L2"; iface="$BR_NAME"; fi
        [[ "$TUN_PROTO" == "6to4" ]] && proto_lbl="IP6GRE"

        local state_color="${R}"; local state_text="DOWN"; local lat_color="${DIM}"; local lat_text="---"
        if ip link show "$iface" >/dev/null 2>&1; then
            if [ "$(cat /sys/class/net/$iface/operstate 2>/dev/null)" != "down" ]; then state_color="${G}"; state_text="UP"; fi
            local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
            [ -n "$VNI_ID" ] && c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
            local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
            ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
            if [ $? -eq 0 ]; then
                local ms=$(echo "$ping_res" | grep -oP 'time=\K\S+'); lat_text="${ms}ms"; lat_color="${Y}"; state_text="ONLINE"; state_color="${G}"
            else state_text="OFFLINE"; state_color="${R}"; fi
        fi
        printf "  ${B}│${NC} ${C}%-13s${NC} ${B}│${NC} ${DIM}%-10s${NC} ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC}\n" "$iface" "$proto_lbl" "$REMOTE_PUB" "$state_color" "$state_text" "$NC" "$lat_color" "$lat_text" "$NC"
    done

    if [ "$has_any" = false ]; then printf "  ${B}│${NC} ${DIM}%-76s${NC} ${B}│${NC}\n" "No tunnel interfaces detected in the system."; fi
    echo -e "  ${B}╰───────────────┴────────────┴──────────────────────┴──────────────┴──────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

deep_ping_analysis() {
    echo -e "\n  ${DIM}┌─[ DEEP PING & PACKET LOSS TEST ]${NC}"
    local all_ips=()
    for conf in "$GRE_DIR"/*.conf "$VX_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue; TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; source "$conf"
        local tip=""
        if [ -n "$TUN_ID" ]; then
            local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
            tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        elif [ -n "$VNI_ID" ]; then
            local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
            tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        fi
        [ -n "$tip" ] && all_ips+=("$tip")
    done

    if [ ${#all_ips[@]} -eq 0 ]; then echo -e "  ${R}● No testable endpoints found.${NC}"; sleep 2; return; fi

    for target in "${all_ips[@]}"; do
        echo -e "\n  ${C}● Testing Core IP: ${W}${target}${NC}"
        local tmp_file=$(mktemp)
        (ping -c 10 -i 0.2 -W 1 "$target" > "$tmp_file" 2>&1) &
        draw_progress_bar $! "Sending 10 Packets"
        local loss=$(grep -oP '\d+(?=% packet loss)' "$tmp_file")
        local avg_lat=$(grep -oP 'min/avg/max/mdev = \K[^/]+/[^/]+' "$tmp_file" | cut -d/ -f2)
        if [ -z "$loss" ]; then loss="100"; fi
        local c_loss="${G}"; [ "$loss" -gt 0 ] && c_loss="${Y}"; [ "$loss" -gt 50 ] && c_loss="${R}"
        local c_lat="${G}"; [ "${avg_lat%.*}" -gt 150 ] 2>/dev/null && c_lat="${Y}"; [ -z "$avg_lat" ] && c_lat="${R}"
        echo -e "  ${DIM}├─ Packet Loss :${NC} ${c_loss}${loss}%${NC}"
        echo -e "  ${DIM}└─ Avg Latency :${NC} ${c_lat}${avg_lat:-N/A} ms${NC}"
        rm -f "$tmp_file"
    done
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

check_mtu_routing() {
    echo -e "\n  ${DIM}┌─[ MTU & ROUTING MATRIX ]${NC}"
    echo -e "  ${B}╭───────────────┬──────┬──────────────────────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-13s${NC} ${B}│${NC} ${W}%-4s${NC} ${B}│${NC} ${W}%-56s${NC} ${B}│${NC}\n" "INTERFACE" "MTU" "TCPMSS / ROUTING STATUS"
    echo -e "  ${B}├───────────────┼──────┼──────────────────────────────────────────────────────────┤${NC}"

    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(gre|br_|vx_)'); do
        local mtu=$(ip -o link show "$iface" | grep -oP 'mtu \K\d+')
        local mss_rule=$(iptables -t mangle -S FORWARD 2>/dev/null | grep -w "$iface" | grep TCPMSS | head -n 1)
        local stat_color="${DIM}"; local stat_text="Standard L2/L3 Routing"
        if [ -n "$mss_rule" ]; then
            local clamp=$(echo "$mss_rule" | grep -oP '--set-mss \K\d+')
            stat_color="${G}"; stat_text="TCPMSS Clamped to ${clamp}"
        fi
        printf "  ${B}│${NC} ${C}%-13s${NC} ${B}│${NC} ${Y}%-4s${NC} ${B}│${NC} %b%-56s%b ${B}│${NC}\n" "$iface" "$mtu" "$stat_color" "$stat_text" "$NC"
    done
    echo -e "  ${B}╰───────────────┴──────┴──────────────────────────────────────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

while true; do
    badge=""
    if [ -f "$SECURE_TMP/.mdiag_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.mdiag_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_mdiag_header
    echo -e "\n  ${DIM}┌─[ DIAGNOSTIC ACTIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Omni-Scan Infrastructure${NC} ${DIM}(GRE, VXLAN)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Deep Ping & Packet Loss Test${NC} ${DIM}(Quality Check)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}MTU & TCPMSS Routing Matrix${NC} ${DIM}(Fragmentation Check)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Instant OTA Update (Sync Module)${NC}${badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"

    echo -ne "  ${C}MDIAG ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r ')
    case $opt in
        1) run_full_infrastructure_scan ;;
        2) deep_ping_analysis ;;
        3) check_mtu_routing ;;
        4) self_update_module ;;
        0) break ;;
    esac
done
