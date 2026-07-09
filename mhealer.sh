#!/bin/bash
# --- MDesign Modular Core (mhealer.sh) | MHealer Web-Radar Hub v1.2.2 (Restart Option Patch) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
LOG_FILE="/var/log/mhealer.log"
CONF_FILE="/etc/mhealer/mhealer.conf"
SVC_FILE="/etc/systemd/system/mhealer.service"
WEB_SVC_FILE="/etc/systemd/system/mhealer-web.service"

mkdir -p /etc/mhealer 2>/dev/null
[ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"

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

format_speed() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B/s"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B/s"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB/s"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB/s\", $bytes/1048576}"
    else awk "BEGIN {printf \"%.2f GB/s\", $bytes/1073741824}"; fi
}

draw_mhealer_header() {
    local s_ip=$(get_local_ip)
    local d_stat="${R}OFFLINE${NC}"
    if systemctl is-active --quiet mhealer.service 2>/dev/null; then d_stat="${G}ACTIVE & WATCHING${NC}"; fi
    
    local w_stat="${DIM}DISABLED${NC}"
    if systemctl is-active --quiet mhealer-web.service 2>/dev/null; then w_stat="${C}PORT ${WEB_PORT}${NC}"; fi

    clear; echo ""
    local str1=" MHealer Web-Radar Hub 1.2.2 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} Core:${NC} ${d_stat}  ${DIM}Web:${NC} ${w_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

# ---------------------------------------------------------
# 1. CORE BACKGROUND DAEMON
# ---------------------------------------------------------
if [[ "$1" == "--daemon" ]]; then
    log_msg() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
    log_msg "🤖 MHealer Core Activated. Watchdog Interval: ${CHECK_INTERVAL}s"
    
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
                        log_msg "⚠️  Tunnel [$tun] is DEAD. Initiating Auto-Repair..."
                        ip link set "$tun" down; sleep 1; ip link set "$tun" up; sleep 2
                        if ping -c 1 -W 2 -I "$tun" "$PING_TARGET" >/dev/null 2>&1; then
                            log_msg "✅ Tunnel [$tun] successfully revived via Link Reset."
                        else
                            log_msg "🚨 CPR failed for [$tun]. Requires manual core sync."
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
# 2. WEB UI BACKGROUND DAEMON
# ---------------------------------------------------------
if [[ "$1" == "--web-daemon" ]]; then
    PORT=$2
    WEB_DIR="/tmp/mhealer_web"
    mkdir -p "$WEB_DIR"; cd "$WEB_DIR"

    python3 -m http.server "$PORT" >/dev/null 2>&1 &
    PY_PID=$!
    trap "kill $PY_PID; rm -rf $WEB_DIR; exit" SIGINT SIGTERM

    declare -A rx_old tx_old

    generate_html() {
        TUNNEL_HTML=""
        
        # Parse GRE Tunnels
        for conf in /etc/mgre/tunnels/*.conf; do
            if [ -f "$conf" ]; then
                source "$conf"
                local r_new=$(cat /sys/class/net/$T_NAME/statistics/rx_bytes 2>/dev/null || echo 0)
                local t_new=$(cat /sys/class/net/$T_NAME/statistics/tx_bytes 2>/dev/null || echo 0)
                local r_old=${rx_old[$T_NAME]:-$r_new}
                local t_old=${tx_old[$T_NAME]:-$t_new}
                
                local rx_s=$(((r_new - r_old) / 3)); [ "$rx_s" -lt 0 ] && rx_s=0
                local tx_s=$(((t_new - t_old) / 3)); [ "$tx_s" -lt 0 ] && tx_s=0
                rx_old[$T_NAME]=$r_new; tx_old[$T_NAME]=$t_new

                local f_rx=$(format_speed $rx_s); local f_tx=$(format_speed $tx_s)
                local state=$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)
                local st_badge="<span class='badge-off'>OFFLINE</span>"
                [[ "$state" == "up" || "$state" == "unknown" ]] && st_badge="<span class='badge-on'>ONLINE</span>"
                
                local rip=${T_REMOTE:-${REMOTE_IP:-"Unknown"}}

                TUNNEL_HTML+="<tr><td>$T_NAME</td><td>GRE / L3</td><td class='ip-font'>$rip</td><td>$st_badge</td><td class='down'>$f_rx</td><td class='up'>$f_tx</td></tr>"
            fi
        done

        # Parse VXLAN Tunnels
        for conf in /etc/mgre/vxlan/*.conf; do
            if [ -f "$conf" ]; then
                source "$conf"
                local r_new=$(cat /sys/class/net/$BR_NAME/statistics/rx_bytes 2>/dev/null || echo 0)
                local t_new=$(cat /sys/class/net/$BR_NAME/statistics/tx_bytes 2>/dev/null || echo 0)
                local r_old=${rx_old[$BR_NAME]:-$r_new}
                local t_old=${tx_old[$BR_NAME]:-$t_new}
                
                local rx_s=$(((r_new - r_old) / 3)); [ "$rx_s" -lt 0 ] && rx_s=0
                local tx_s=$(((t_new - t_old) / 3)); [ "$tx_s" -lt 0 ] && tx_s=0
                rx_old[$BR_NAME]=$r_new; tx_old[$BR_NAME]=$t_new

                local f_rx=$(format_speed $rx_s); local f_tx=$(format_speed $tx_s)
                local state=$(cat /sys/class/net/$BR_NAME/operstate 2>/dev/null)
                local st_badge="<span class='badge-off'>OFFLINE</span>"
                [[ "$state" == "up" || "$state" == "unknown" ]] && st_badge="<span class='badge-on'>ONLINE</span>"

                local rip=${VX_REMOTE:-${REMOTE_IP:-"Unknown"}}

                TUNNEL_HTML+="<tr><td>$BR_NAME</td><td>VXLAN / L2</td><td class='ip-font'>$rip</td><td>$st_badge</td><td class='down'>$f_rx</td><td class='up'>$f_tx</td></tr>"
            fi
        done

        if [ -z "$TUNNEL_HTML" ]; then
            TUNNEL_HTML="<tr><td colspan='6' style='text-align:center; color:#64748b; padding:20px;'>No active MDesign tunnels detected.</td></tr>"
        fi

        # Parse Logs
        LOG_HTML=$(tail -n 12 "$LOG_FILE" 2>/dev/null | awk '{
            if ($0 ~ /✅/) print "<span class=\"success\">" $0 "</span><br>"
            else if ($0 ~ /⚠️/) print "<span class=\"warning\">" $0 "</span><br>"
            else if ($0 ~ /🚨/) print "<span class=\"danger\">" $0 "</span><br>"
            else if ($0 ~ /🤖/) print "<span class=\"info\">" $0 "</span><br>"
            else print $0 "<br>"
        }')

        cat <<EOF > index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="3">
    <title>MDesign Web Radar</title>
    <style>
        body { margin: 0; background-color: #0b0f19; color: #f8fafc; font-family: 'Segoe UI', sans-serif; display: flex; justify-content: center; align-items: flex-start; min-height: 100vh; padding: 40px 20px; box-sizing: border-box; }
        .glass-panel { background: rgba(255, 255, 255, 0.02); backdrop-filter: blur(15px); border: 1px solid rgba(255, 255, 255, 0.05); border-radius: 16px; padding: 30px; width: 100%; max-width: 1000px; box-shadow: 0 30px 60px rgba(0, 0, 0, 0.4); }
        .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 15px; margin-bottom: 25px; }
        h1 { font-size: 20px; font-weight: 600; margin: 0; letter-spacing: 1px; color: #f1f5f9; }
        .badge { background: rgba(56, 189, 248, 0.1); color: #38bdf8; padding: 4px 12px; border-radius: 20px; font-size: 12px; font-weight: bold; border: 1px solid rgba(56, 189, 248, 0.2); }
        .section-title { font-size: 13px; color: #94a3b8; letter-spacing: 2px; text-transform: uppercase; margin-bottom: 15px; font-weight: bold; display: flex; align-items: center; }
        .section-title::before { content: ''; display: inline-block; width: 6px; height: 14px; background: #38bdf8; margin-right: 10px; border-radius: 4px; }
        
        table { width: 100%; border-collapse: collapse; margin-bottom: 35px; background: rgba(0,0,0,0.2); border-radius: 12px; overflow: hidden; }
        th { text-align: left; padding: 14px 16px; font-size: 12px; color: #cbd5e1; border-bottom: 1px solid rgba(255,255,255,0.05); text-transform: uppercase; letter-spacing: 1px; }
        td { padding: 14px 16px; font-size: 14px; border-bottom: 1px solid rgba(255,255,255,0.03); color: #f8fafc; }
        tr:last-child td { border-bottom: none; }
        tr:hover { background: rgba(255,255,255,0.02); }
        
        .ip-font { font-family: 'Courier New', Courier, monospace; color: #e2e8f0; }
        .down { color: #38bdf8; font-weight: 600; }
        .up { color: #f472b6; font-weight: 600; }
        .badge-on { background: rgba(74, 222, 128, 0.15); color: #4ade80; padding: 4px 10px; border-radius: 6px; font-size: 11px; font-weight: bold; border: 1px solid rgba(74, 222, 128, 0.3); display: inline-block;}
        .badge-off { background: rgba(248, 113, 113, 0.15); color: #f87171; padding: 4px 10px; border-radius: 6px; font-size: 11px; font-weight: bold; border: 1px solid rgba(248, 113, 113, 0.3); display: inline-block;}
        
        .terminal { background: #050505; border-radius: 12px; padding: 20px; font-family: 'Courier New', Courier, monospace; font-size: 13px; line-height: 1.7; color: #94a3b8; height: 260px; overflow-y: auto; border: 1px solid rgba(255,255,255,0.05); }
        .success { color: #4ade80; }
        .warning { color: #facc15; }
        .danger { color: #f87171; }
        .info { color: #38bdf8; }
        
        ::-webkit-scrollbar { width: 6px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.1); border-radius: 10px; }
        ::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,0.2); }
    </style>
</head>
<body>
    <div class="glass-panel">
        <div class="header">
            <h1>MDESIGN WEB RADAR & HEALER</h1>
            <span class="badge">LIVE METRICS</span>
        </div>

        <div class="section-title">Active Tunnel Matrix</div>
        <table>
            <thead>
                <tr>
                    <th>Interface</th>
                    <th>Protocol</th>
                    <th>Endpoint IP</th>
                    <th>Status</th>
                    <th>▼ Download</th>
                    <th>▲ Upload</th>
                </tr>
            </thead>
            <tbody>
                $TUNNEL_HTML
            </tbody>
        </table>

        <div class="section-title">Autonomous AI Logs</div>
        <div class="terminal">
$LOG_HTML
        </div>
    </div>
</body>
</html>
EOF
    }

    while true; do
        generate_html
        sleep 3
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

restart_daemon() {
    echo -e "\n  ${DIM}● Restarting MHealer Core Engine...${NC}"
    if systemctl is-active --quiet mhealer.service 2>/dev/null; then
        systemctl restart mhealer.service
        echo -e "  ${G}● MHealer AI has been successfully restarted.${NC}"
    else
        echo -e "  ${R}● Service is not running. Please Enable it first (Option 1).${NC}"
    fi
    sleep 2
}

stop_daemon() {
    echo -e "\n  ${Y}● Putting MHealer Core to sleep...${NC}"
    systemctl stop mhealer.service; systemctl disable mhealer.service >/dev/null 2>&1
    echo -e "  ${R}● Core is now OFFLINE.${NC}"; sleep 2
}

manage_web_ui() {
    while true; do
        draw_mhealer_header
        
        local s_ip=$(get_local_ip)
        local w_stat_text="${R}OFFLINE${NC}"
        if systemctl is-active --quiet mhealer-web.service 2>/dev/null; then 
            w_stat_text="${G}ONLINE${NC} ${DIM}❯${NC} ${C}http://${s_ip}:${WEB_PORT}${NC}"
        fi

        echo -e "\n  ${DIM}┌─[ WEB DASHBOARD MANAGER ]${NC}"
        echo -e "  ${DIM}│${NC} ${W}Status:${NC} ${w_stat_text}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Start / Restart Web Dashboard${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Stop Web Dashboard${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back to Main Menu${NC}\n"
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
                systemctl daemon-reload; systemctl enable mhealer-web.service >/dev/null 2>&1; systemctl restart mhealer-web.service
                echo -e "\n  ${G}● Web Radar is LIVE!${NC}"
                sleep 2; break ;;
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
    
    local w_menu_stat="${DIM}(OFFLINE)${NC}"
    if systemctl is-active --quiet mhealer-web.service 2>/dev/null; then w_menu_stat="${G}(ONLINE)${NC}"; fi

    echo -e "\n  ${DIM}┌─[ ROBOTIC CONTROL CENTER ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Awaken & Enable Core${NC} ${DIM}(Install/Start Monitor)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Restart MHealer Core${NC} ${DIM}(Reboot AI Service)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Put Core to Sleep${NC}   ${DIM}(Disable Monitoring)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}View Live Healing Logs${NC} ${DIM}(CLI Terminal)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Web Dashboard Manager${NC}  ${w_menu_stat}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${W}Calibrate AI Config${NC}    ${DIM}(Interval & Ping targets)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MHEALER ❯❯ ${NC}"; read opt
    case $opt in
        1) install_daemon ;;
        2) restart_daemon ;;
        3) stop_daemon ;;
        4) view_logs ;;
        5) manage_web_ui ;;
        6) edit_config ;;
        0) break ;;
    esac
done
