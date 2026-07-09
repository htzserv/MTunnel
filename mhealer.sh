#!/bin/bash
# --- MDesign Modular Core (mhealer.sh) | MHealer Autonomous AI v1.0.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
LOG_FILE="/var/log/mhealer.log"
CONF_FILE="/etc/mhealer/mhealer.conf"
SVC_FILE="/etc/systemd/system/mhealer.service"

mkdir -p /etc/mhealer 2>/dev/null
[ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"

# Default Configuration
if [ ! -f "$CONF_FILE" ]; then
    echo "CHECK_INTERVAL=15" > "$CONF_FILE"
    echo "MAX_FAILURES=3" >> "$CONF_FILE"
    echo "PING_TARGET=1.1.1.1" >> "$CONF_FILE"
    echo "ENABLE_TELEGRAM=false" >> "$CONF_FILE"
    echo "BOT_TOKEN=" >> "$CONF_FILE"
    echo "CHAT_ID=" >> "$CONF_FILE"
fi
source "$CONF_FILE"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_mhealer_header() {
    local s_ip=$(get_local_ip)
    local d_stat="${R}OFFLINE${NC}"
    if systemctl is-active --quiet mhealer.service 2>/dev/null; then d_stat="${G}ACTIVE & WATCHING${NC}"; fi
    
    clear; echo ""
    local str1=" MHealer Autonomous AI 1.0.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 25 ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} Status:${NC} ${d_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

# ---------------------------------------------------------
# BACKGROUND DAEMON LOGIC (The actual AI)
# ---------------------------------------------------------
if [[ "$1" == "--daemon" ]]; then
    log_msg() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
    
    log_msg "🤖 MHealer Engine Started. Watchdog Interval: ${CHECK_INTERVAL}s"
    
    while true; do
        # Extract active tunnels
        local gre_ifs=""
        for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && source "$conf" && gre_ifs="$gre_ifs $T_NAME"; done
        local vx_ifs=""
        for conf in /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && source "$conf" && vx_ifs="$vx_ifs $VX_NAME"; done
        
        local all_tuns="$gre_ifs $vx_ifs"
        
        for tun in $all_tuns; do
            if [ -d "/sys/class/net/$tun" ]; then
                # Check if interface is UP but has no route to internet (we test by pinging the target via this interface)
                # Actually, simplest check: is the interface state UP?
                local state=$(cat /sys/class/net/$tun/operstate 2>/dev/null)
                if [[ "$state" == "down" || "$state" == "unknown" ]]; then
                    # Double check with ping if it's supposed to route
                    if ! ping -c 1 -W 2 -I "$tun" "$PING_TARGET" >/dev/null 2>&1; then
                        log_msg "⚠️  Tunnel [$tun] seems DEAD. Attempting CPR..."
                        ip link set "$tun" down
                        sleep 1
                        ip link set "$tun" up
                        sleep 2
                        if ping -c 1 -W 2 -I "$tun" "$PING_TARGET" >/dev/null 2>&1; then
                            log_msg "✅ Tunnel [$tun] successfully revived via Link Reset."
                        else
                            log_msg "🚨 CPR failed for [$tun]. Requires full Master Core sync."
                        fi
                    fi
                fi
            fi
        done
        sleep "$CHECK_INTERVAL"
    done
    exit 0
fi

# ---------------------------------------------------------
# CLI DASHBOARD LOGIC
# ---------------------------------------------------------
install_daemon() {
    echo -e "\n  ${DIM}● Configuring SystemD Service for MHealer...${NC}"
    cat <<EOF > "$SVC_FILE"
[Unit]
Description=MDesign Autonomous Healer AI
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/mhealer --daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mhealer.service >/dev/null 2>&1
    systemctl start mhealer.service
    echo -e "  ${G}● MHealer AI is now successfully running in the background.${NC}"
    sleep 2
}

stop_daemon() {
    echo -e "\n  ${Y}● Putting MHealer AI to sleep...${NC}"
    systemctl stop mhealer.service
    systemctl disable mhealer.service >/dev/null 2>&1
    echo -e "  ${R}● MHealer is now OFFLINE.${NC}"
    sleep 2
}

view_logs() {
    draw_mhealer_header
    echo -e "\n  ${DIM}┌─[ AI DIAGNOSTIC LOGS ]${NC} ${C}(Press Ctrl+C to exit)${NC}\n"
    if [ -f "$LOG_FILE" ]; then
        tail -n 20 -f "$LOG_FILE" | while read line; do
            if [[ "$line" == *"✅"* ]]; then echo -e "  ${G}${line}${NC}"
            elif [[ "$line" == *"⚠️"* ]]; then echo -e "  ${Y}${line}${NC}"
            elif [[ "$line" == *"🚨"* ]]; then echo -e "  ${R}${line}${NC}"
            elif [[ "$line" == *"🤖"* ]]; then echo -e "  ${C}${line}${NC}"
            else echo -e "  ${DIM}${line}${NC}"; fi
        done
    else
        echo -e "  ${DIM}No logs generated yet. MHealer needs to run first.${NC}"
        read
    fi
}

edit_config() {
    draw_mhealer_header
    echo -e "\n  ${DIM}┌─[ HEALER AI SENSITIVITY ]${NC}\n"
    echo -ne "  ${C}●${NC} ${W}Check Interval in seconds (Current: ${CHECK_INTERVAL}): ${NC}"; read n_int
    echo -ne "  ${C}●${NC} ${W}Ping Target for health check (Current: ${PING_TARGET}): ${NC}"; read n_pt
    
    n_int=${n_int:-$CHECK_INTERVAL}
    n_pt=${n_pt:-$PING_TARGET}

    echo "CHECK_INTERVAL=$n_int" > "$CONF_FILE"
    echo "MAX_FAILURES=3" >> "$CONF_FILE"
    echo "PING_TARGET=$n_pt" >> "$CONF_FILE"
    echo "ENABLE_TELEGRAM=false" >> "$CONF_FILE"
    
    source "$CONF_FILE"
    echo -e "\n  ${G}● Memory updated. Restarting AI to apply new neural paths...${NC}"
    systemctl restart mhealer.service 2>/dev/null
    sleep 2
}

while true; do
    draw_mhealer_header
    echo -e "\n  ${DIM}┌─[ ROBOTIC CONTROL CENTER ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Awaken & Enable MHealer AI${NC} ${DIM}(Background Monitor)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Put MHealer to Sleep${NC} ${DIM}(Disable Monitoring)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}View Live Healing Logs${NC} ${DIM}(Real-time action feed)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${W}Calibrate AI Sensitivity${NC} ${DIM}(Interval & Ping targets)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Telegram Bot Notifications${NC} ${DIM}[Coming Soon]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MHEALER ❯❯ ${NC}"; read opt
    case $opt in
        1) install_daemon ;;
        2) stop_daemon ;;
        3) view_logs ;;
        4) edit_config ;;
        0) break ;;
    esac
done
