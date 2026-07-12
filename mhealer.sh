#!/bin/bash
# --- MDesign Modular Core (mhealer.sh) | MHealer Autonomous CPR v1.4.0 (Pure Healer) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
LOG_FILE="/var/log/mhealer.log"
CONF_FILE="/etc/mhealer/mhealer.conf"
SVC_FILE="/etc/systemd/system/mhealer.service"

mkdir -p /etc/mhealer 2>/dev/null
[ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"

if [ ! -f "$CONF_FILE" ]; then
    echo "CHECK_INTERVAL=15" > "$CONF_FILE"
    echo "PING_TARGET=1.1.1.1" >> "$CONF_FILE"
fi
source "$CONF_FILE"
CHECK_INTERVAL=${CHECK_INTERVAL:-15}
PING_TARGET=${PING_TARGET:-1.1.1.1}

draw_mhealer_header() {
    local d_stat="${R}OFFLINE${NC}"
    if systemctl is-active --quiet mhealer.service 2>/dev/null; then d_stat="${G}ACTIVE & WATCHING${NC}"; fi
    clear; echo ""
    local str1=" MHealer Autonomous CPR 1.4.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 22 ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} Core AI:${NC} ${d_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

# --- 1. CORE BACKGROUND DAEMON ---
if [[ "$1" == "--daemon" ]]; then
    log_msg() { 
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
        local lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$lines" -gt 3000 ]; then
            tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    }
    
    log_msg "🤖 MHealer AI Activated. Pure Healer Mode. Interval: ${CHECK_INTERVAL}s"
    
    while true; do
        local gre_ifs=""
        for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && source "$conf" && gre_ifs="$gre_ifs $T_NAME"; done
        local vx_ifs=""
        for conf in /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && source "$conf" && vx_ifs="$vx_ifs $VX_NAME"; done
        
        local all_tuns="$gre_ifs $vx_ifs"
        
        for tun in $all_tuns; do
            if [ -d "/sys/class/net/$tun" ]; then
                local state=$(cat /sys/class/net/$tun/operstate 2>/dev/null)
                if [[ "$state" == "down" || "$state" == "unknown" ]]; then
                    log_msg "⚠️  Tunnel [$tun] Link is DOWN. Initiating Auto-Repair CPR..."
                    ip link set "$tun" down; sleep 1; ip link set "$tun" up; sleep 2
                    local check_state=$(cat /sys/class/net/$tun/operstate 2>/dev/null)
                    if [[ "$check_state" == "up" || "$check_state" == "unknown" ]]; then
                        log_msg "✅ Tunnel [$tun] successfully revived via Link Reset."
                    else
                        log_msg "🚨 CPR failed for [$tun]. Link remains offline."
                    fi
                fi
            fi
        done
        sleep "$CHECK_INTERVAL"
    done
    exit 0
fi

# --- 2. CLI CONTROL PANEL ---
install_daemon() {
    echo -e "\n  ${DIM}● Configuring SystemD Service for MHealer Core...${NC}"
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
    systemctl daemon-reload; systemctl enable mhealer.service >/dev/null 2>&1; systemctl start mhealer.service
    echo -e "  ${G}● MHealer AI is now successfully running in the background.${NC}"; sleep 2
}

restart_daemon() {
    echo -e "\n  ${DIM}● Restarting MHealer Core...${NC}"
    if systemctl is-active --quiet mhealer.service 2>/dev/null; then
        systemctl restart mhealer.service
        echo -e "  ${G}● Core AI Engine successfully restarted.${NC}"
    else
        echo -e "  ${Y}● Core is not running. Start it first.${NC}"
    fi
    sleep 2
}

stop_daemon() {
    echo -e "\n  ${Y}● Putting MHealer Core to sleep...${NC}"
    systemctl stop mhealer.service 2>/dev/null; systemctl disable mhealer.service >/dev/null 2>&1
    echo -e "  ${R}● Core is now OFFLINE.${NC}"; sleep 2
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
        echo -e "  ${DIM}No logs generated yet. MHealer needs to run first.${NC}"; read
    fi
}

edit_config() {
    draw_mhealer_header
    echo -e "\n  ${DIM}┌─[ HEALER AI SENSITIVITY ]${NC}\n"
    echo -ne "  ${C}●${NC} ${W}Check Interval in seconds (Current: ${CHECK_INTERVAL}): ${NC}"; read n_int
    echo -ne "  ${C}●${NC} ${W}Ping Target for health check (Current: ${PING_TARGET}): ${NC}"; read n_pt
    n_int=${n_int:-$CHECK_INTERVAL}; n_pt=${n_pt:-$PING_TARGET}
    sed -i "s/^CHECK_INTERVAL=.*/CHECK_INTERVAL=$n_int/" "$CONF_FILE"
    sed -i "s/^PING_TARGET=.*/PING_TARGET=$n_pt/" "$CONF_FILE"
    echo -e "\n  ${G}● Memory updated. Restarting AI...${NC}"
    systemctl restart mhealer.service 2>/dev/null
    sleep 2
}

while true; do
    draw_mhealer_header
    echo -e "\n  ${DIM}┌─[ ROBOTIC CONTROL CENTER ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Awaken & Enable Core${NC} ${DIM}(Install/Start Monitor)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Restart Ecosystem${NC}  ${DIM}(Apply Configs)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Put Core to Sleep${NC}  ${DIM}(Disable Monitoring)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}View Live Logs${NC}     ${DIM}(CLI Terminal)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${W}Calibrate AI${NC}       ${DIM}(Interval & Targets)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MHEALER ❯❯ ${NC}"; read opt
    case $opt in
        1) install_daemon ;;
        2) restart_daemon ;;
        3) stop_daemon ;;
        4) view_logs ;;
        5) edit_config ;;
        0) break ;;
    esac
done
