#!/bin/bash
# --- MDesign Modular Core (minterface.sh) | Interface Mapper v4.0.1 ---
# [Features: Refined Spacing | Async Background Checker | Minimal OTA Badges]

MODULE_VERSION="4.0.1"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/minterface"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

mkdir -p "$LOCAL_DIR/packages" "$LOCAL_DIR/tools" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

# --- ASYNC BACKGROUND UPDATE CHECKER ---
check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tools/minterface.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tools/minterface.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.minterface_remote_ver"
}
check_update_bg &
# ---------------------------------------

self_update_module() {
    local rel_path="tools/minterface.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.minterface_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.minterface_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (MInterface Module) ]${NC}"
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
    
    local tmp_file="$SECURE_TMP/.minterface_update.$$"
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

get_configs() { ls /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf 2>/dev/null; }

detect_server_role() {
    local configs=($(get_configs))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "${DIM}Unknown (No Tunnels)${NC}"; return; fi
    TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; source "${configs[0]}"
    [ "$TYPE" == "1" ] && echo -e "${G}IRAN (Access Node)${NC}" || echo -e "${M}KHAREJ (Gateway Node)${NC}"
}

draw_header() {
    local s_ip=$(get_local_ip); local role=$(detect_server_role)
    clear; echo ""
    local str1=" MDesign Interface Matrix v${MODULE_VERSION} "
    local str2=" IP: $s_ip "
    local configs=($(get_configs)); local raw_role="Unknown (No Tunnels)"
    if [ ${#configs[@]} -gt 0 ]; then
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; source "${configs[0]}"
        raw_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access Node)" || echo "KHAREJ (Gateway Node)")
    fi
    local str3=" ROLE: $raw_role "
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} ))
    local pad_len=$(( 96 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} ROLE:${NC} ${role}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

print_row_2col() {
    local l_raw="$1"; local l_col="$2"; local r_raw="$3"; local r_col="$4"
    local l_spaces=$(printf '%*s' "$(( 28 - ${#l_raw} ))" "")
    local r_spaces=$(printf '%*s' "$(( 63 - ${#r_raw} ))" "")
    echo -e "  ${B}│${NC} ${l_col}${l_spaces} ${B}│${NC} ${r_col}${r_spaces} ${B}│${NC}"
}

render_matrix() {
    local configs=($(get_configs))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No network blueprints configured.${NC}"; sleep 2; return; fi

    echo -e "\n  ${Y}● Active Network Interface Blueprint:${NC}"
    for conf in "${configs[@]}"; do
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; source "$conf"
        local is_vx=false; local t_name="$T_NAME"
        
        if [ -n "$BR_NAME" ]; then is_vx=true; t_name="$BR_NAME"; fi

        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        [ -n "$VNI_ID" ] && c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        
        local proto_lbl="IPv4 GRE Engine"; local title_color="${C}"
        [[ "$TUN_PROTO" == "6to4" ]] && { proto_lbl="6to4 IP6GRE Engine"; title_color="${M}"; }
        [[ "$is_vx" == true ]] && { proto_lbl="VXLAN L2 Bridge"; title_color="${M}"; }

        local stat_raw="● DOWN"; local stat_color="${R}"; local sys_uptime="Offline"
        local state=$(cat /sys/class/net/$t_name/operstate 2>/dev/null)
        if ip link show "$t_name" >/dev/null 2>&1 && [[ "$state" == "up" || "$state" == "unknown" ]]; then
            stat_raw="● UP  "; stat_color="${G}"
            local created=$(stat -c %Y "/sys/class/net/$t_name" 2>/dev/null)
            if [ -n "$created" ]; then
                local diff=$(($(date +%s) - created))
                local d=$((diff / 86400)); local h=$(( (diff % 86400) / 3600 )); local m=$(( (diff % 3600) / 60 ))
                sys_uptime=""; [ "$d" -gt 0 ] && sys_uptime="${d}d "; [ "$h" -gt 0 ] && sys_uptime="${sys_uptime}${h}h "; sys_uptime="${sys_uptime}${m}m"
            fi
        fi

        local link_raw="○ OFFLINE"; local link_color="${R}"
        ping -c 1 -W 1 "$tip" >/dev/null 2>&1 && { link_raw="● ONLINE "; link_color="${G}"; }

        local h_ports=""; local subnets=("$c_sub")
        for v_lip in $(ip -4 addr show dev "$t_name" label "${t_name}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1); do
            subnets+=("$(echo "$v_lip" | cut -d'.' -f1-3)")
        done
        
        if [ -f "/etc/haproxy/haproxy.cfg" ]; then
            local h_tmp=""
            for sub in "${subnets[@]}"; do
                local p=$(grep "server srv_" /etc/haproxy/haproxy.cfg | grep "${sub}\." | awk '{print $2}' | cut -d'_' -f2)
                [ -n "$p" ] && h_tmp="$h_tmp\n$p"
            done
            h_ports=$(echo -e "$h_tmp" | grep -v '^$' | sort -un | paste -sd "," -)
        fi
        
        [ -z "$h_ports" ] && h_ports="None"
        [ ${#h_ports} -gt 50 ] && h_ports="${h_ports:0:47}..."

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_part="▼ Interface: $t_name"
        local right_part="State: $stat_raw   Link: $link_raw   Uptime: $sys_uptime"
        local spaces=$(printf '%*s' "$(( 94 - ${#left_part} - ${#right_part} ))" "")
        echo -e "  ${B}│${NC} ${title_color}▼ Interface: ${W}$t_name${NC}${spaces}${DIM}State: ${stat_color}${stat_raw}${NC}   ${DIM}Link: ${link_color}${link_raw}${NC}   ${DIM}Uptime: ${W}${sys_uptime}${NC} ${B}│${NC}"
        echo -e "  ${B}├──────────────────────────────┬─────────────────────────────────────────────────────────────────┤${NC}"
        print_row_2col "Tunnel Infrastructure" "${C}Tunnel Infrastructure${NC}" "$proto_lbl" "${W}$proto_lbl${NC}"
        
        local l_pub=${LOCAL_PUB:-Unknown}; local r_pub=${REMOTE_PUB:-Unknown}
        print_row_2col "Public Endpoint IPs" "${DIM}Public Endpoint IPs${NC}" "Local: $l_pub   Remote: $r_pub" "${DIM}Local:${NC} ${W}$l_pub${NC}   ${DIM}Remote:${NC} ${W}$r_pub${NC}"
        echo -e "  ${B}├──────────────────────────────┼─────────────────────────────────────────────────────────────────┤${NC}"
        print_row_2col "Core IPv4 Network" "${DIM}Core IPv4 Network${NC}" "Local: $lip   Remote: $tip" "${DIM}Local:${NC} ${G}$lip${NC}   ${DIM}Remote:${NC} ${Y}$tip${NC}"
        print_row_2col "Active Port Mappings" "${Y}Active Port Mappings${NC}" "HAProxy: $h_ports" "${C}HAProxy:${NC} ${W}$h_ports${NC}"
        
        if [[ "$TUN_PROTO" == "6to4" ]]; then
            echo -e "  ${B}├──────────────────────────────┼─────────────────────────────────────────────────────────────────┤${NC}"
            print_row_2col "Native IPv6 Allocation" "${DIM}Native IPv6 Allocation${NC}" "Local IPv6 : $LOCAL_IP6" "${DIM}Local IPv6 :${NC} $LOCAL_IP6"
            print_row_2col "" "" "Remote IPv6: $REMOTE_IP6" "${DIM}Remote IPv6:${NC} $REMOTE_IP6"
        fi
        echo -e "  ${B}╰──────────────────────────────┴─────────────────────────────────────────────────────────────────╯${NC}\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

while true; do
    badge=""
    if [ -f "$SECURE_TMP/.minterface_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.minterface_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_header
    echo -e "\n  ${DIM}┌─[ INTERFACE MATRIX ACTIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Render Active Network Blueprint${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Instant OTA Update (Sync Module)${NC}${badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"

    echo -ne "  ${C}MINTERFACE ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r ')

    case $opt in
        1) render_matrix ;;
        2) self_update_module ;;
        0) break ;;
        *) echo -e "  ${R}● Invalid option!${NC}"; sleep 1 ;;
    esac
done
