#!/bin/bash
# --- MDesign Modular Core (mhealer.sh) | MHealer Autonomous AI v1.1.0 (Web UI Patch) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
LOG_FILE="/var/log/mhealer.log"
CONF_FILE="/etc/mhealer/mhealer.conf"
SVC_FILE="/etc/systemd/system/mhealer.service"
WEB_SVC_FILE="/etc/systemd/system/mhealer-web.service"

mkdir -p /etc/mhealer 2>/dev/null
[ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"

# Default Configuration
if [ ! -f "$CONF_FILE" ]; then
    echo "CHECK_INTERVAL=15" > "$CONF_FILE"
    echo "MAX_FAILURES=3" >> "$CONF_FILE"
    echo "PING_TARGET=1.1.1.1" >> "$CONF_FILE"
    echo "WEB_PORT=8888" >> "$CONF_FILE"
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
    
    local w_stat="${DIM}DISABLED${NC}"
    if systemctl is-active --quiet mhealer-web.service 2>/dev/null; then w_stat="${C}PORT ${WEB_PORT}${NC}"; fi

    clear; echo ""
    local str1=" MHealer Autonomous AI 1.1.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} Core:${NC} ${d_stat}  ${DIM}Web:${NC} ${w_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

# ---------------------------------------------------------
# 1. CORE BACKGROUND DAEMON (The AI)
# ---------------------------------------------------------
if [[ "$1" == "--daemon" ]]; then
    log_msg() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
    log_msg "🤖 MHealer Engine Started. Watchdog Interval: ${CHECK_INTERVAL}s"
    
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
                    if ! ping -c 1 -W 2 -I "$tun" "$PING_TARGET" >/dev/null 2>&1; then
                        log_msg "⚠️  Tunnel [$tun] seems DEAD. Attempting CPR..."
                        ip link set "$tun" down; sleep 1; ip link set "$tun" up; sleep 2
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
# 2. WEB UI BACKGROUND DAEMON (Glassmorphic HTML Generator)
# ---------------------------------------------------------
if [[ "$1" == "--web-daemon" ]]; then
    PORT=$2
    WEB_DIR="/tmp/mhealer_web"
    mkdir -p "$WEB_DIR"
    cd "$WEB_DIR"

    # اجرای پایتون وب‌سرور در بک‌گراند
    python3 -m http.server "$PORT" >/dev/null 2>&1 &
    PY_PID=$!
    trap "kill $PY_PID; rm -rf $WEB_DIR; exit" SIGINT SIGTERM

    while true; do
        # خوندن ۲۵ خط آخر لاگ و تزریق رنگ‌های CSS به جای ایموجی‌ها
        LOG_HTML=$(tail -n 25 "$LOG_FILE" 2>/dev/null | awk '{
            if ($0 ~ /✅/) print "<span class=\"success\">" $0 "</span><br>"
            else if ($0 ~ /⚠️/) print "<span class=\"warning\">" $0 "</span><br>"
            else if ($0 ~ /🚨/) print "<span class=\"danger\">" $0 "</span><br>"
            else if ($0 ~ /🤖/) print "<span class=\"info\">" $0 "</span><br>"
            else print $0 "<br>"
        }')

        # رندرینگ کدهای خالص HTML MDesign
        cat <<EOF > index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="3">
    <title>MDesign Autonomous Core</title>
    <style>
        body { margin: 0; background-color: #0f172a; color: #f8fafc; font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; padding: 20px; box-sizing: border-box; }
        .glass-panel { background: rgba(255, 255, 255, 0.03); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); border: 1px solid rgba(255, 255, 255, 0.05); border-radius: 20px; padding: 30px; width: 100%; max-width: 900px; box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5); }
        .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid rgba(255,255,255,0.1); padding-bottom: 20px; margin-bottom: 20px; }
        h1 { font-size: 22px; font-weight: 600; margin: 0; letter-spacing: 1px; color: #e2e8f0; }
        .badge { background: rgba(56, 189, 248, 0.15); color: #38bdf8; padding: 5px 12px; border-radius: 20px; font-size: 13px; font-weight: bold; border: 1px solid rgba(56, 189, 248, 0.3); }
        .terminal { background: #000000; border-radius: 12px; padding: 20px; font-family: 'Courier New', Courier, monospace; font-size: 14px; line-height: 1.6; color: #94a3b8; height: 450px; overflow-y: auto; border: 1px solid rgba(255,255,255,0.05); box-shadow: inset 0 0 10px rgba(0,0,0,0.5); }
        .success { color: #4ade80; text-shadow: 0 0 5px rgba(74, 222, 128, 0.4); }
        .warning { color: #facc15; }
        .danger { color: #f87171; text-shadow: 0 0 5px rgba(248, 113, 113, 0.4); }
        .info { color: #38bdf8; }
        ::-webkit-scrollbar { width: 8px; }
        ::-webkit-scrollbar-track { background: #000; border-radius: 10px; }
        ::-webkit-scrollbar-thumb { background: #334155; border-radius: 10px; }
        ::-webkit-scrollbar-thumb:hover { background: #475569; }
    </style>
</head>
<body>
    <div class="glass-panel">
        <div class="header">
            <h1>MDESIGN AI DIAGNOSTICS</h1>
            <span class="badge">LIVE FEED</span>
        </div>
        <div class="terminal">
$LOG_HTML
        </div>
    </div>
</body>
</html>
EOF
        sleep 2
    done
    exit 0
fi

# ---------------------------------------------------------
# 3. CLI CONTROL PANEL
# ---------------------------------------------------------
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

stop_daemon() {
    echo -e "\n  ${Y}● Putting MHealer Core to sleep...${NC}"
    systemctl stop mhealer.service; systemctl disable mhealer.service >/dev/null 2>&1
    echo -e "  ${R}● Core is now OFFLINE.${NC}"; sleep 2
}

manage_web_ui() {
    while true; do
        draw_mhealer_header
        echo -e "\n  ${DIM}┌─[ WEB DASHBOARD MANAGER ]${NC}"
        echo -e "  ${C}●${NC} ${W}Host a beautiful, Glassmorphic HTML page to monitor logs remotely.${NC}\n"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Start Web Dashboard${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Stop Web Dashboard${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back to MHealer${NC}\n"
        echo -ne "  ${C}WEB-UI ❯❯ ${NC}"; read w_opt
        
        case $w_opt in
            1)
                echo -ne "\n  ${C}●${NC} ${W}Enter port for Web Dashboard (Default: 8888): ${NC}"; read custom_port
                WEB_PORT=${custom_port:-8888}
                sed -i "s/^WEB_PORT=.*/WEB_PORT=$WEB_PORT/" "$CONF_FILE"
                
                cat <<EOF > "$WEB_SVC_FILE"
[Unit]
Description=MDesign Healer Web UI
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/mhealer --web-daemon $WEB_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload; systemctl enable mhealer-web.service >/dev/null 2>&1; systemctl start mhealer-web.service
                local s_ip=$(get_local_ip)
                echo -e "\n  ${G}● Web UI is LIVE!${NC}"
                echo -e "  ${Y}● Open in your browser: ${W}http://${s_ip}:${WEB_PORT}${NC}"
                sleep 4; break ;;
            2)
                systemctl stop mhealer-web.service; systemctl disable mhealer-web.service >/dev/null 2>&1
                rm -rf /tmp/mhealer_web
                echo -e "\n  ${R}● Web UI has been safely shut down.${NC}"; sleep 2; break ;;
            0) break ;;
        esac
    done
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
    
    n_int=${n_int:-$CHECK_INTERVAL}
    n_pt=${n_pt:-$PING_TARGET}

    sed -i "s/^CHECK_INTERVAL=.*/CHECK_INTERVAL=$n_int/" "$CONF_FILE"
    sed -i "s/^PING_TARGET=.*/PING_TARGET=$n_pt/" "$CONF_FILE"
    
    source "$CONF_FILE"
    echo -e "\n  ${G}● Memory updated. Restarting AI to apply new neural paths...${NC}"
    systemctl restart mhealer.service 2>/dev/null
    sleep 2
}

while true; do
    draw_mhealer_header
    echo -e "\n  ${DIM}┌─[ ROBOTIC CONTROL CENTER ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Awaken & Enable MHealer AI${NC} ${DIM}(Background Monitor)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Put MHealer to Sleep${NC} ${DIM}(Disable Monitoring)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}View Live Healing Logs${NC} ${DIM}(CLI Terminal)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Web Dashboard Manager${NC} ${DIM}(Launch Glassmorphic UI)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${W}Calibrate AI Sensitivity${NC} ${DIM}(Interval & Ping targets)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MHEALER ❯❯ ${NC}"; read opt
    case $opt in
        1) install_daemon ;;
        2) stop_daemon ;;
        3) view_logs ;;
        4) manage_web_ui ;;
        5) edit_config ;;
        0) break ;;
    esac
done
