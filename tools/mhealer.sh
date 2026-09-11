#!/bin/bash
# --- MDesign Modular Core (mhealer.sh) | Autonomous Healer v2.3.1 ---
# [Features: Refined Spacing | Async Background Checker | Minimal OTA Badges]

MODULE_VERSION="2.3.1"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mhealer"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
SVC_FILE="/etc/systemd/system/mhealer.service"
CONF_FILE="/etc/mhealer.conf"
LOG_FILE="/var/log/mhealer.log"

mkdir -p "$LOCAL_DIR/packages" "$LOCAL_DIR/tools" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

[ -f "$CONF_FILE" ] && source "$CONF_FILE"
HEAL_INTERVAL=${HEAL_INTERVAL:-30}

# --- ASYNC BACKGROUND UPDATE CHECKER ---
check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tools/mhealer.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tools/mhealer.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mhealer_remote_ver"
}
check_update_bg &
# ---------------------------------------

self_update_module() {
    local rel_path="tools/mhealer.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mhealer_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mhealer_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (MHealer Bot) ]${NC}"
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
    
    local tmp_file="$SECURE_TMP/.mhealer_update.$$"
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

draw_header() {
    local s_ip=$(get_local_ip)
    local h_stat="${DIM}OFFLINE${NC}"
    if systemctl is-active --quiet mhealer.service 2>/dev/null; then h_stat="${G}ACTIVE${NC} ${DIM}(${HEAL_INTERVAL}s)${NC}"; fi
    clear; echo ""
    local str1=" MHealer Autonomous Bot v${MODULE_VERSION} "
    local raw_len=$(( ${#str1} + 4 + ${#s_ip} + 12 ))
    local pad=$(( 92 - raw_len - 15 )); [ "$pad" -lt 0 ] && pad=0; local padding=$(printf '%*s' "$pad" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Bot:${NC} ${h_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

generate_daemon() {
    cat <<'EOF' > /usr/local/bin/mhealer_daemon.sh
#!/bin/bash
source /etc/mhealer.conf

check_and_heal() {
    local conf="$1"; local type="$2"; local iface=""; local tip=""
    unset TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET T_NAME TUN_ID CORE_SUBNET TUN_PROTO LOCAL_IP6 REMOTE_IP6 VNI_ID BR_NAME
    source "$conf"
    
    if [ "$type" == "gre" ]; then
        iface="$T_NAME"
        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
    elif [ "$type" == "vxlan" ]; then
        iface="$BR_NAME"
        local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
    fi

    local FAIL_FILE="/tmp/mhealer_${iface}.fail"
    if ! ping -c 2 -W 2 "$tip" >/dev/null 2>&1; then
        local fails=$(cat "$FAIL_FILE" 2>/dev/null || echo "0")
        fails=$((fails + 1))
        echo "$fails" > "$FAIL_FILE"
        
        if [ "$fails" -ge 3 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') | HEAL TRIGGERED | $iface ($tip) is DOWN for $fails checks." >> /var/log/mhealer.log
            echo "0" > "$FAIL_FILE"
            if [ "$type" == "gre" ]; then /usr/bin/mgre --apply
            elif [ "$type" == "vxlan" ]; then systemctl restart mxlan.service
            fi
            sleep 5
        fi
    else
        echo "0" > "$FAIL_FILE"
    fi
}

while true; do
    for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && check_and_heal "$conf" "gre"; done
    for conf in /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && check_and_heal "$conf" "vxlan"; done
    sleep "$HEAL_INTERVAL"
done
EOF
    chmod +x /usr/local/bin/mhealer_daemon.sh

    cat <<EOF > "$SVC_FILE"
[Unit]
Description=MHealer Autonomous Tunnel Bot
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mhealer_daemon.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

start_bot() {
    echo -ne "\n  ${C}●${NC} ${W}Check interval in seconds (Default 30): ${NC}"; read custom_int
    HEAL_INTERVAL=${custom_int:-30}
    echo "HEAL_INTERVAL=$HEAL_INTERVAL" > "$CONF_FILE"
    generate_daemon
    systemctl enable mhealer.service >/dev/null 2>&1
    systemctl restart mhealer.service
    echo -e "  ${G}● Healer Bot deployed and scanning every ${HEAL_INTERVAL}s.${NC}"; sleep 1.5
}

stop_bot() {
    systemctl stop mhealer.service 2>/dev/null
    systemctl disable mhealer.service 2>/dev/null
    echo -e "\n  ${Y}● Healer Bot deactivated.${NC}"; sleep 1.5
}

view_logs() {
    draw_header
    echo -e "\n  ${DIM}┌─[ HEALER LOGS ]${NC}"
    if [ ! -s "$LOG_FILE" ]; then echo -e "  ${G}● No drops detected yet. System is stable.${NC}"
    else tail -n 15 "$LOG_FILE" | sed 's/^/  │ /'; fi
    echo -e "  ${DIM}└────────────────────────────────────────────────────────${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

while true; do
    badge=""
    if [ -f "$SECURE_TMP/.mhealer_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.mhealer_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_header
    echo -e "\n  ${DIM}┌─[ HEALER BOT ACTIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Activate Healer Bot${NC} ${DIM}(Auto-detect & fix drops)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Deactivate Healer Bot${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}View Drop/Heal Logs${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Instant OTA Update (Sync Module)${NC}${badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"

    echo -ne "  ${C}MHEALER ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r ')

    case $opt in
        1) start_bot ;;
        2) stop_bot ;;
        3) view_logs ;;
        4) self_update_module ;;
        0) break ;;
        *) echo -e "  ${R}● Invalid option!${NC}"; sleep 1 ;;
    esac
done
