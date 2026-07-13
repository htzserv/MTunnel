#!/bin/bash
# --- MDesign Modular Core (mhealer.sh) | Autonomous Healer v2.3.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
SVC_FILE="/etc/systemd/system/mhealer.service"
CONF_FILE="/etc/mhealer.conf"
LOG_FILE="/var/log/mhealer.log"

[ -f "$CONF_FILE" ] && source "$CONF_FILE"
HEAL_INTERVAL=${HEAL_INTERVAL:-30}

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
    local str1=" MHealer Autonomous Bot 2.3.0 "
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
    source "$conf"
    
    if [ "$type" == "gre" ]; then
        iface="$T_NAME"
        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
    elif [ "$type" == "l2tp" ]; then
        iface="$T_NAME"
        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
    elif [ "$type" == "vxlan" ]; then
        iface="$BR_NAME"
        local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
    fi

    if ! ping -c 2 -W 2 "$tip" >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | HEAL TRIGGERED | $iface ($tip) is DOWN." >> /var/log/mhealer.log
        if [ "$type" == "gre" ]; then /usr/bin/mgre --apply
        elif [ "$type" == "l2tp" ]; then systemctl restart ml2tp.service
        elif [ "$type" == "vxlan" ]; then systemctl restart mxlan.service
        fi
        sleep 5
    fi
}

while true; do
    for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && check_and_heal "$conf" "gre"; done
    for conf in /etc/ml2tp/tunnels/*.conf; do [ -f "$conf" ] && check_and_heal "$conf" "l2tp"; done
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
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ HEALER ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Activate Healer Bot${NC} ${DIM}(Auto-detect & fix drops)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Deactivate Healer Bot${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}View Drop/Heal Logs${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back to Main Menu${NC}\n"
    echo -ne "  ${C}MHEALER ❯❯ ${NC}"; read opt

    case $opt in
        1) start_bot ;; 2) stop_bot ;; 3) view_logs ;; 0) break ;;
    esac
done
