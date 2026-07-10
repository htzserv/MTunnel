cat << 'EOF_MSTATS' > /usr/bin/mstats
#!/bin/bash
# --- MDesign Modular Core (mstats.sh) | MStats Omni-Radar & Web UI v1.5.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_FILE="/etc/mstats/web.conf"
WEB_SVC_FILE="/etc/systemd/system/mstats-web.service"
HEALER_LOG="/var/log/mhealer.log"

mkdir -p /etc/mstats 2>/dev/null
if [ ! -f "$CONF_FILE" ]; then echo "WEB_PORT=8888" > "$CONF_FILE"; fi
source "$CONF_FILE"
WEB_PORT=${WEB_PORT:-8888}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

MY_PUB_IP=$(get_local_ip)

format_speed() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B/s"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B/s"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB/s"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB/s\", $bytes/1048576}"
    else awk "BEGIN {printf \"%.2f GB/s\", $bytes/1073741824}"; fi
}

format_total() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -lt 1099511627776 ]; then awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    else awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"; fi
}

get_iface_rx() {
    local r_base=$(cat /sys/class/net/$1/statistics/rx_bytes 2>/dev/null || echo 0)
    local obfs_rx=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep "OBFS_CNT_RX_$1" | awk '{sum+=$2} END {print sum}')
    [ -n "$obfs_rx" ] && r_base=$((r_base + obfs_rx))
    echo "$r_base"
}

get_iface_tx() {
    local t_base=$(cat /sys/class/net/$1/statistics/tx_bytes 2>/dev/null || echo 0)
    local obfs_tx=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null | grep "OBFS_CNT_TX_$1" | awk '{sum+=$2} END {print sum}')
    [ -n "$obfs_tx" ] && t_base=$((t_base + obfs_tx))
    echo "$t_base"
}

# ---------------------------------------------------------
# WEB UI BACKGROUND DAEMON
# ---------------------------------------------------------
if [[ "$1" == "--web-daemon" ]]; then
    PORT=$2
    WEB_DIR="/tmp/mstats_web"
    mkdir -p "$WEB_DIR"; cd "$WEB_DIR"

    python3 -m http.server "$PORT" >/dev/null 2>&1 &
    PY_PID=$!
    trap "kill $PY_PID; rm -rf $WEB_DIR; exit" SIGINT SIGTERM

    declare -A rx_old tx_old

    get_tunnel_ip() {
        local dev=$1
        local rip=$(ip -d link show "$dev" 2>/dev/null | grep -oP 'remote \K[0-9a-fA-F\.:]+' | head -n 1)
        [ -z "$rip" ] && rip=$(ip tunnel show "$dev" 2>/dev/null | grep -oP 'remote \K[0-9a-fA-F\.:]+' | head -n 1)
        if [ -z "$rip" ] && [[ "$dev" == br_* ]]; then
            local vx_dev="${dev/br_/vx_}"
            rip=$(ip -d link show "$vx_dev" 2>/dev/null | grep -oP 'remote \K[0-9a-fA-F\.:]+' | head -n 1)
        fi
        echo "$rip"
    }

    generate_html() {
        TUNNEL_HTML=""
        
        for conf in /etc/mgre/tunnels/*.conf; do
            if [ -f "$conf" ]; then
                source "$conf"
                local r_new=$(get_iface_rx "$T_NAME"); local t_new=$(get_iface_tx "$T_NAME")
                local r_old=${rx_old[$T_NAME]:-$r_new}; local t_old=${tx_old[$T_NAME]:-$t_new}
                local rx_s=$(((r_new - r_old) / 3)); [ "$rx_s" -lt 0 ] && rx_s=0
                local tx_s=$(((t_new - t_old) / 3)); [ "$tx_s" -lt 0 ] && tx_s=0
                rx_old[$T_NAME]=$r_new; tx_old[$T_NAME]=$t_new

                local state=$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)
                local st_badge="<span class='badge-off'>OFFLINE</span>"
                [[ "$state" == "up" || "$state" == "unknown" ]] && st_badge="<span class='badge-on'>ONLINE</span>"
                local rip=$(get_tunnel_ip "$T_NAME"); [ -z "$rip" ] && rip=${T_REMOTE:-${REMOTE_IP:-"Unknown"}}
                TUNNEL_HTML+="<tr><td>$T_NAME</td><td>GRE / L3</td><td class='ip-font'>$rip</td><td>$st_badge</td><td class='down'>$(format_speed $rx_s)</td><td class='up'>$(format_speed $tx_s)</td><td class='tot-down'>$(format_total $r_new)</td><td class='tot-up'>$(format_total $t_new)</td></tr>"
            fi
        done

        for conf in /etc/mgre/vxlan/*.conf; do
            if [ -f "$conf" ]; then
                source "$conf"
                local r_new=$(get_iface_rx "$BR_NAME"); local t_new=$(get_iface_tx "$BR_NAME")
                local r_old=${rx_old[$BR_NAME]:-$r_new}; local t_old=${tx_old[$BR_NAME]:-$t_new}
                local rx_s=$(((r_new - r_old) / 3)); [ "$rx_s" -lt 0 ] && rx_s=0
                local tx_s=$(((t_new - t_old) / 3)); [ "$tx_s" -lt 0 ] && tx_s=0
                rx_old[$BR_NAME]=$r_new; tx_old[$BR_NAME]=$t_new

                local state=$(cat /sys/class/net/$BR_NAME/operstate 2>/dev/null)
                local st_badge="<span class='badge-off'>OFFLINE</span>"
                [[ "$state" == "up" || "$state" == "unknown" ]] && st_badge="<span class='badge-on'>ONLINE</span>"
                local rip=$(get_tunnel_ip "$BR_NAME"); [ -z "$rip" ] && rip=${VX_REMOTE:-${REMOTE_IP:-"Unknown"}}
                TUNNEL_HTML+="<tr><td>$BR_NAME</td><td>VXLAN / L2</td><td class='ip-font'>$rip</td><td>$st_badge</td><td class='down'>$(format_speed $rx_s)</td><td class='up'>$(format_speed $tx_s)</td><td class='tot-down'>$(format_total $r_new)</td><td class='tot-up'>$(format_total $t_new)</td></tr>"
            fi
        done

        if [ -z "$TUNNEL_HTML" ]; then TUNNEL_HTML="<tr><td colspan='8' style='text-align:center; color:#64748b; padding:20px;'>No active MDesign tunnels detected.</td></tr>"; fi

        CONN_IPS_HTML=""
        CONN_PORTS_HTML=""
        local core_ports=$(ss -tulpn 2>/dev/null | grep -iE 'gost|haproxy' | awk '{print $5}' | rev | cut -d: -f1 | rev | grep -E '^[0-9]+$' | sort -u | tr '\n' '|' | sed 's/|$//')

        if [ -n "$core_ports" ]; then
            local top_ips=$(ss -tun state established 2>/dev/null | awk -v cp="^(${core_ports})$" '{
                n = split($4, a, ":"); port = a[n];
                if(port ~ cp) print $5;
            }' | rev | cut -d: -f2- | rev | tr -d '[]' | sed 's/^::ffff://' | grep -Ev '^(127\.0\.0\.1|0\.0\.0\.0|\*)$' | sort | uniq -c | sort -nr | head -n 6)
            
            if [ -n "$top_ips" ]; then
                while read -r count ip; do
                    CONN_IPS_HTML+="<tr><td class='ip-font'>$ip</td><td><span class='badge-p'>$count Active</span></td></tr>"
                done <<< "$top_ips"
            else
                CONN_IPS_HTML+="<tr><td colspan='2' style='text-align:center; color:#64748b; padding:20px;'>No external clients connected.</td></tr>"
            fi

            local top_ports=$(ss -tun state established 2>/dev/null | awk 'NR>1 {print $4}' | rev | cut -d: -f1 | rev | grep -E "^($core_ports)$" | sort | uniq -c | sort -nr | head -n 6)
            if [ -n "$top_ports" ]; then
                while read -r count port; do
                    local app_name=$(ss -tulpn 2>/dev/null | grep ":$port " | grep -iE -o '(gost|haproxy)' | head -n 1)
                    [ -z "$app_name" ] && app_name="Unknown"
                    app_name=${app_name^^}
                    local eng_color="badge"
                    [ "$app_name" == "GOST" ] && eng_color="badge-m"
                    [ "$app_name" == "HAPROXY" ] && eng_color="badge-c"
                    CONN_PORTS_HTML+="<tr><td class='ip-font'>:$port</td><td><span class='$eng_color'>$app_name</span></td><td><span class='badge'>$count</span></td></tr>"
                done <<< "$top_ports"
            else
                CONN_PORTS_HTML+="<tr><td colspan='3' style='text-align:center; color:#64748b; padding:20px;'>No active traffic on ports.</td></tr>"
            fi
        else
            CONN_IPS_HTML+="<tr><td colspan='2' style='text-align:center; color:#64748b; padding:20px;'>Core engines (MPorter) offline.</td></tr>"
            CONN_PORTS_HTML+="<tr><td colspan='3' style='text-align:center; color:#64748b; padding:20px;'>Core engines (MPorter) offline.</td></tr>"
        fi

        LOG_HTML="<span class='info'>No logs available. (MHealer AI not running or file empty)</span>"
        if [ -f "$HEALER_LOG" ]; then
            LOG_HTML=$(tail -n 12 "$HEALER_LOG" 2>/dev/null | awk '{
                if ($0 ~ /✅/) print "<span class=\"success\">" $0 "</span><br>"
                else if ($0 ~ /⚠️/) print "<span class=\"warning\">" $0 "</span><br>"
                else if ($0 ~ /🚨/) print "<span class=\"danger\">" $0 "</span><br>"
                else if ($0 ~ /🤖/) print "<span class=\"info\">" $0 "</span><br>"
                else print $0 "<br>"
            }')
        fi

        cat <<EOF > index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MStats Web Radar</title>
    <style>
        body { margin: 0; background-color: #0b0f19; color: #f8fafc; font-family: 'Segoe UI', sans-serif; display: flex; justify-content: center; align-items: flex-start; min-height: 100vh; padding: 40px 20px; box-sizing: border-box; }
        .glass-panel { background: rgba(255, 255, 255, 0.02); backdrop-filter: blur(15px); border: 1px solid rgba(255, 255, 255, 0.05); border-radius: 16px; padding: 30px; width: 100%; max-width: 1200px; box-shadow: 0 30px 60px rgba(0, 0, 0, 0.4); }
        .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 15px; margin-bottom: 25px; }
        h1 { font-size: 20px; font-weight: 600; margin: 0; letter-spacing: 1px; color: #f1f5f9; }
        .badge { background: rgba(56, 189, 248, 0.1); color: #38bdf8; padding: 4px 12px; border-radius: 20px; font-size: 12px; font-weight: bold; border: 1px solid rgba(56, 189, 248, 0.2); }
        .badge-p { background: rgba(192, 132, 252, 0.15); color: #c084fc; padding: 4px 10px; border-radius: 6px; font-size: 11px; font-weight: bold; border: 1px solid rgba(192, 132, 252, 0.3); display: inline-block;}
        .badge-m { background: rgba(244, 114, 182, 0.15); color: #f472b6; padding: 4px 10px; border-radius: 6px; font-size: 11px; font-weight: bold; border: 1px solid rgba(244, 114, 182, 0.3); display: inline-block;}
        .badge-c { background: rgba(56, 189, 248, 0.15); color: #38bdf8; padding: 4px 10px; border-radius: 6px; font-size: 11px; font-weight: bold; border: 1px solid rgba(56, 189, 248, 0.3); display: inline-block;}
        .section-title { font-size: 13px; color: #94a3b8; letter-spacing: 2px; text-transform: uppercase; margin-bottom: 15px; font-weight: bold; display: flex; align-items: center; }
        .section-title::before { content: ''; display: inline-block; width: 6px; height: 14px; background: #38bdf8; margin-right: 10px; border-radius: 4px; }
        table { width: 100%; border-collapse: collapse; margin-bottom: 30px; background: rgba(0,0,0,0.2); border-radius: 12px; overflow: hidden; }
        th { text-align: left; padding: 14px 16px; font-size: 12px; color: #cbd5e1; border-bottom: 1px solid rgba(255,255,255,0.05); text-transform: uppercase; letter-spacing: 1px; }
        td { padding: 14px 16px; font-size: 14px; border-bottom: 1px solid rgba(255,255,255,0.03); color: #f8fafc; vertical-align: middle; }
        tr:last-child td { border-bottom: none; }
        tr:hover { background: rgba(255,255,255,0.02); }
        .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
        @media (max-width: 800px) { .grid-2 { grid-template-columns: 1fr; } }
        .ip-font { font-family: 'Courier New', Courier, monospace; color: #e2e8f0; line-height: 1.4; font-weight: 600; }
        .down { color: #38bdf8; font-weight: 600; }
        .up { color: #f472b6; font-weight: 600; }
        .tot-down, .tot-up { color: #94a3b8; font-size: 13px; font-weight: 500; }
        .badge-on { background: rgba(74, 222, 128, 0.15); color: #4ade80; padding: 4px 10px; border-radius: 6px; font-size: 11px; font-weight: bold; border: 1px solid rgba(74, 222, 128, 0.3); display: inline-block;}
        .badge-off { background: rgba(248, 113, 113, 0.15); color: #f87171; padding: 4px 10px; border-radius: 6px; font-size: 11px; font-weight: bold; border: 1px solid rgba(248, 113, 113, 0.3); display: inline-block;}
        .terminal { background: #050505; border-radius: 12px; padding: 20px; font-family: 'Courier New', Courier, monospace; font-size: 13px; line-height: 1.7; color: #94a3b8; height: 260px; overflow-y: auto; border: 1px solid rgba(255,255,255,0.05); }
        .success { color: #4ade80; } .warning { color: #facc15; } .danger { color: #f87171; } .info { color: #38bdf8; }
        ::-webkit-scrollbar { width: 6px; } ::-webkit-scrollbar-track { background: transparent; } ::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.1); border-radius: 10px; } ::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,0.2); }
    </style>
</head>
<body>
    <div class="glass-panel">
        <div class="header"><h1>MDESIGN MSTATS WEB RADAR</h1><span class="badge">LIVE METRICS</span></div>
        <table>
            <thead><tr><th>Interface</th><th>Protocol</th><th>Endpoint IP</th><th>Status</th><th>▼ Live Down</th><th>▲ Live Up</th><th>∑ Total Down</th><th>∑ Total Up</th></tr></thead>
            <tbody>$TUNNEL_HTML</tbody>
        </table>
        <div class="grid-2">
            <div>
                <div class="section-title">Active Client IPs (Peers)</div>
                <table><thead><tr><th>Client IP</th><th>Connections</th></tr></thead><tbody>$CONN_IPS_HTML</tbody></table>
            </div>
            <div>
                <div class="section-title">Top Forwarded Ports</div>
                <table><thead><tr><th>Port</th><th>Engine</th><th>Connections</th></tr></thead><tbody>$CONN_PORTS_HTML</tbody></table>
            </div>
        </div>
        <div class="section-title">Autonomous AI Logs</div>
        <div class="terminal">$LOG_HTML</div>
    </div>
    <script>setTimeout(function() { window.location.replace(window.location.pathname + "?t=" + new Date().getTime()); }, 3000);</script>
</body>
</html>
EOF
    }

    while true; do generate_html; sleep 3; done
    exit 0
fi

# ---------------------------------------------------------
# CLI & MENU
# ---------------------------------------------------------
draw_mstats_header() {
    local s_ip=$(get_local_ip)
    local w_stat="${DIM}DISABLED${NC}"
    if systemctl is-active --quiet mstats-web.service 2>/dev/null; then w_stat="${C}PORT ${WEB_PORT}${NC}"; fi
    clear; echo ""
    local str1=" MStats Omni-Radar & Web UI 1.5.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Web:${NC} ${w_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_live_radar() {
    tput civis; clear; declare -A rx_old tx_old
    while true; do
        printf "\033[H"
        draw_mstats_header
        echo -e "\n  ${DIM}┌─[ UNIFIED TRAFFIC RADAR ]${NC} ${C}(Real-time 1s Auto-Refresh | Press 'q' to stop)${NC}\n"
        echo -e "  ${B}╭──────────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "INTERFACE" "CATEGORY" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL DOWN" "∑ TOTAL UP"
        echo -e "  ${B}├──────────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤${NC}"

        local phys_ifs=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(eth|ens|eno|enp)' | xargs)
        local gre_ifs=""
        for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && source "$conf" && gre_ifs="$gre_ifs $T_NAME"; done
        local vx_ifs=""
        for conf in /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && source "$conf" && vx_ifs="$vx_ifs $BR_NAME"; done
        local wg_ifs=""; [ -f "/etc/wireguard/wg0.conf" ] && wg_ifs="wg0"

        local all_ifs="$phys_ifs $gre_ifs $vx_ifs $wg_ifs"
        for iface in $all_ifs; do
            if [ -z "${rx_old[$iface]}" ] && [ -d "/sys/class/net/$iface" ]; then
                rx_old[$iface]=$(get_iface_rx "$iface"); tx_old[$iface]=$(get_iface_tx "$iface")
            fi
        done

        declare -A rx_new tx_new
        for iface in $all_ifs; do
            [ ! -d "/sys/class/net/$iface" ] && continue
            rx_new[$iface]=$(get_iface_rx "$iface"); tx_new[$iface]=$(get_iface_tx "$iface")
        done

        local active_count=0
        render_category() {
            local cat_name=$1; local cat_color=$2; local if_list=$3
            for iface in $if_list; do
                [ ! -d "/sys/class/net/$iface" ] && continue
                local r_old=${rx_old[$iface]:-0}; local t_old=${tx_old[$iface]:-0}
                local r_new=${rx_new[$iface]:-0}; local t_new=${tx_new[$iface]:-0}
                local rx_sec=$((r_new - r_old)); local tx_sec=$((t_new - t_old))
                
                active_count=$((active_count + 1))
                local c_rx="${DIM}"; [ "$rx_sec" -gt 0 ] && c_rx="${G}"
                local c_tx="${DIM}"; [ "$tx_sec" -gt 0 ] && c_tx="${Y}"
                
                printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} %b%-10s%b ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "$iface" "$cat_color" "$cat_name" "$NC" "$c_rx" "$(format_speed $rx_sec)" "$NC" "$c_tx" "$(format_speed $tx_sec)" "$NC" "$(format_total $r_new)" "$(format_total $t_new)"
                rx_old[$iface]=$r_new; tx_old[$iface]=$t_new
            done
        }

        [ -n "$phys_ifs" ] && render_category "WAN / PHYS" "${W}" "$phys_ifs"
        [ -n "$gre_ifs" ] && render_category "GRE / L3" "${C}" "$gre_ifs"
        [ -n "$vx_ifs" ] && render_category "VXLAN / L2" "${M}" "$vx_ifs"
        [ -n "$wg_ifs" ] && render_category "WG CRYPTO" "${G}" "$wg_ifs"

        if [ "$active_count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-83s${NC} ${B}│${NC}\n" "  Standby... No active MDesign tunnels or physical traffic detected right now."
        fi
        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ $key == "q" || $key == "Q" ]]; then break; fi
    done
    tput cnorm
}

show_total_usage() {
    clear; draw_mstats_header
    echo -e "\n  ${DIM}┌─[ HISTORICAL TRAFFIC USAGE ]${NC}"
    echo -e "  ${C}●${NC} ${W}Data accumulated since system boot or interface creation.${NC}\n"
    
    local phys_ifs=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(eth|ens|eno|enp)' | xargs)
    local all_tuns=""
    for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && source "$conf" && all_tuns="$all_tuns $T_NAME"; done
    for conf in /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && source "$conf" && all_tuns="$all_tuns $BR_NAME"; done
    [ -f "/etc/wireguard/wg0.conf" ] && all_tuns="$all_tuns wg0"
    
    echo -e "  ${B}╭──────────────────┬───────────────────────┬───────────────────────┬────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${C}%-21s${NC} ${B}│${NC} ${M}%-21s${NC} ${B}│${NC} ${G}%-22s${NC} ${B}│${NC}\n" "INTERFACE" "▼ TOTAL DOWNLOAD" "▲ TOTAL UPLOAD" "∑ COMBINED TRAFFIC"
    echo -e "  ${B}├──────────────────┴───────────────────────┴───────────────────────┴────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" " PHYSICAL / WAN UPLINKS"
    echo -e "  ${B}├──────────────────┬───────────────────────┬───────────────────────┬────────────────────────┤${NC}"
    
    for iface in $phys_ifs; do
        [ ! -d "/sys/class/net/$iface" ] && continue
        local rx=$(get_iface_rx "$iface"); local tx=$(get_iface_tx "$iface"); local total=$((rx + tx))
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${C}%-21s${NC} ${B}│${NC} ${M}%-21s${NC} ${B}│${NC} ${G}%-22s${NC} ${B}│${NC}\n" "$iface" "$(format_total $rx)" "$(format_total $tx)" "$(format_total $total)"
    done

    if [ -n "$all_tuns" ]; then
        echo -e "  ${B}├──────────────────┴───────────────────────┴───────────────────────┴────────────────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" " VIRTUAL FABRICS (GRE, VXLAN, WG)"
        echo -e "  ${B}├──────────────────┬───────────────────────┬───────────────────────┬────────────────────────┤${NC}"
        for iface in $all_tuns; do
            [ ! -d "/sys/class/net/$iface" ] && continue
            local rx=$(get_iface_rx "$iface"); local tx=$(get_iface_tx "$iface"); local total=$((rx + tx))
            printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${C}%-21s${NC} ${B}│${NC} ${M}%-21s${NC} ${B}│${NC} ${G}%-22s${NC} ${B}│${NC}\n" "$iface" "$(format_total $rx)" "$(format_total $tx)" "$(format_total $total)"
        done
    fi
    echo -e "  ${B}╰──────────────────┴───────────────────────┴───────────────────────┴────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

show_connection_tracker() {
    clear; draw_mstats_header
    echo -e "\n  ${DIM}┌─[ MDESIGN CONNECTION TRACKER ]${NC}"
    echo -e "  ${C}●${NC} ${W}Exclusive Core Engine Filter (HAProxy & Gost)...${NC}\n"

    local core_ports=$(ss -tulpn 2>/dev/null | grep -iE 'gost|haproxy' | awk '{print $5}' | rev | cut -d: -f1 | rev | grep -E '^[0-9]+$' | sort -u | tr '\n' '|' | sed 's/|$//')

    echo -e "  ${B}╭─────────┬───────────────┬─────────────────┬─────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${C}%-13s${NC} ${B}│${NC} ${M}%-15s${NC} ${B}│${NC} ${G}%-11s${NC} ${B}│${NC}\n" "RANK" "LOCAL PORT" "CORE ENGINE" "CONNECTIONS"
    echo -e "  ${B}├─────────┼───────────────┼─────────────────┼─────────────┤${NC}"
    
    if [ -z "$core_ports" ]; then
        printf "  ${B}│${NC} ${DIM}%-51s${NC} ${B}│${NC}\n" "  No active Gost or HAProxy services running."
    else
        local top_ports=$(ss -tun state established 2>/dev/null | awk 'NR>1 {print $4}' | rev | cut -d: -f1 | rev | grep -E "^($core_ports)$" | sort | uniq -c | sort -nr | head -n 5)
        
        local rank=1
        if [ -z "$top_ports" ]; then
            printf "  ${B}│${NC} ${DIM}%-51s${NC} ${B}│${NC}\n" "  No active external connections to Core Engines."
        else
            while read -r count port; do
                local app_name=$(ss -tulpn 2>/dev/null | grep ":$port " | grep -iE -o '(gost|haproxy)' | head -n 1)
                [ -z "$app_name" ] && app_name="Unknown"; app_name=${app_name^^}
                printf "  ${B}│${NC} ${DIM}#%-6s${NC} ${B}│${NC} ${W}Port %-8s${NC} ${B}│${NC} ${Y}%-15s${NC} ${B}│${NC} ${G}%-11s${NC} ${B}│${NC}\n" "$rank" "$port" "$app_name" "$count"
                ((rank++))
            done <<< "$top_ports"
        fi
    fi
    echo -e "  ${B}╰─────────┴───────────────┴─────────────────┴─────────────╯${NC}\n"

    echo -e "  ${B}╭─────────┬──────────────────────────┬─────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${Y}%-24s${NC} ${B}│${NC} ${M}%-11s${NC} ${B}│${NC}\n" "RANK" "TOP CLIENT IPs (PEERS)" "CONNECTIONS"
    echo -e "  ${B}├─────────┼──────────────────────────┼─────────────┤${NC}"
    
    if [ -z "$core_ports" ]; then
        printf "  ${B}│${NC} ${DIM}%-46s${NC} ${B}│${NC}\n" "  No active external clients."
    else
        local top_ips=$(ss -tun state established 2>/dev/null | awk -v cp="^(${core_ports})$" '{
            n = split($4, a, ":"); port = a[n];
            if(port ~ cp) print $5;
        }' | rev | cut -d: -f2- | rev | tr -d '[]' | sed 's/^::ffff://' | grep -Ev '^(127\.0\.0\.1|0\.0\.0\.0|\*)$' | sort | uniq -c | sort -nr | head -n 5)
        
        local rank2=1
        if [ -z "$top_ips" ]; then
            printf "  ${B}│${NC} ${DIM}%-46s${NC} ${B}│${NC}\n" "  No active external clients connected to Cores."
        else
            while read -r count ip; do
                printf "  ${B}│${NC} ${DIM}#%-6s${NC} ${B}│${NC} ${W}%-24s${NC} ${B}│${NC} ${G}%-11s${NC} ${B}│${NC}\n" "$rank2" "$ip" "$count"
                ((rank2++))
            done <<< "$top_ips"
        fi
    fi
    echo -e "  ${B}╰─────────┴──────────────────────────┴─────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

qos_manager() {
    clear; draw_mstats_header
    echo -e "\n  ${DIM}┌─[ QoS & TRAFFIC SHAPING MANAGER ]${NC}"
    echo -e "  ${C}●${NC} ${W}Limit bandwidth on specific Virtual Fabrics to prevent saturation.${NC}\n"
    
    local gre_ifs=""
    for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && source "$conf" && gre_ifs="$gre_ifs $T_NAME"; done
    local vx_ifs=""
    for conf in /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && source "$conf" && vx_ifs="$vx_ifs $BR_NAME"; done
    local wg_ifs=""; [ -f "/etc/wireguard/wg0.conf" ] && wg_ifs="wg0"
    local all_tuns="$gre_ifs $vx_ifs $wg_ifs"
    
    echo -e "  ${B}╭─────┬──────────────────┬──────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-3s${NC} ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "IDX" "INTERFACE" "CURRENT BANDWIDTH LIMIT"
    echo -e "  ${B}├─────┼──────────────────┼──────────────────────────────┤${NC}"
    
    local iface_arr=(); local idx=0; local found_any=false
    
    for iface in $all_tuns; do
        if [ -d "/sys/class/net/$iface" ]; then
            found_any=true; iface_arr+=("$iface")
            local limit=$(tc qdisc show dev "$iface" 2>/dev/null | grep -oP 'rate \K\S+')
            local stat_color="${G}"; local stat_text="UNLIMITED (Native Speed)"
            if [ -n "$limit" ]; then stat_color="${Y}"; stat_text="${limit} (Capped)"; fi
            printf "  ${B}│${NC} ${C}%-3s${NC} ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} %b%-28s%b ${B}│${NC}\n" "$idx" "$iface" "$stat_color" "$stat_text" "$NC"
            ((idx++))
        fi
    done
    
    if [ "$found_any" = false ]; then printf "  ${B}│${NC} ${DIM}%-49s${NC} ${B}│${NC}\n" "  No active virtual tunnels found."; fi
    echo -e "  ${B}╰─────┴──────────────────┴──────────────────────────────╯${NC}\n"
    
    [ "$found_any" = false ] && { echo -ne "  ${DIM}Press Enter to return...${NC}"; read; return; }
    
    echo -ne "  ${C}●${NC} ${W}Select Tunnel Index (or 'q' to cancel): ${NC}"; read sel_idx
    [[ "$sel_idx" == "q" || -z "$sel_idx" ]] && return
    
    local target_if="${iface_arr[$sel_idx]}"
    if [ -z "$target_if" ]; then echo -e "  ${R}● Invalid selection!${NC}"; sleep 1.5; return; fi
    
    echo -ne "  ${C}●${NC} ${W}Enter New Limit in Mbit/s (e.g. 50) or '0' to UNLIMITED: ${NC}"; read speed_val
    if ! [[ "$speed_val" =~ ^[0-9]+$ ]]; then echo -e "  ${R}● Invalid number!${NC}"; sleep 1.5; return; fi
    
    tc qdisc del dev "$target_if" root 2>/dev/null
    
    if [ "$speed_val" -gt 0 ]; then
        tc qdisc add dev "$target_if" root tbf rate ${speed_val}mbit burst 1mbit latency 400ms 2>/dev/null
        echo -e "\n  ${G}● Speed limit of ${speed_val} Mbps successfully applied to ${target_if}.${NC}"
    else
        echo -e "\n  ${G}● Speed limit removed. ${target_if} is now UNLIMITED.${NC}"
    fi
    sleep 2
}

manage_web_ui() {
    # Clean up old mhealer web service if it exists to prevent conflicts
    if systemctl is-active --quiet mhealer-web.service 2>/dev/null; then
        systemctl stop mhealer-web.service 2>/dev/null
        systemctl disable mhealer-web.service 2>/dev/null
        rm -f /etc/systemd/system/mhealer-web.service
        systemctl daemon-reload
    fi

    while true; do
        draw_mstats_header
        local s_ip=$(get_local_ip)
        w_stat_text="${R}OFFLINE${NC}"
        if systemctl is-active --quiet mstats-web.service 2>/dev/null; then 
            w_stat_text="${G}ONLINE${NC} ${DIM}❯${NC} ${C}http://${s_ip}:${WEB_PORT}${NC}"
        fi

        echo -e "\n  ${DIM}┌─[ WEB DASHBOARD MANAGER ]${NC}"
        echo -e "  ${DIM}│${NC} ${W}Status:${NC} ${w_stat_text}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Start Web Dashboard${NC} ${DIM}(Initialize UI Server)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Restart Web Dashboard${NC} ${DIM}(Apply new UI changes)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Stop Web Dashboard${NC} ${DIM}(Shut down UI Server)${NC}"
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
Description=MStats Web Radar UI
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/mstats --web-daemon $WEB_PORT
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload; systemctl enable mstats-web.service >/dev/null 2>&1; systemctl start mstats-web.service
                echo -e "\n  ${G}● Web Radar is LIVE!${NC}"; sleep 2; break ;;
            2)
                echo -e "\n  ${DIM}● Restarting Web Dashboard...${NC}"
                if systemctl is-active --quiet mstats-web.service 2>/dev/null; then
                    systemctl restart mstats-web.service; echo -e "  ${G}● Web Radar successfully restarted!${NC}"
                else
                    echo -e "  ${R}● Service is not running. Please Start it first (Option 1).${NC}"
                fi
                sleep 2; break ;;
            3)
                systemctl stop mstats-web.service 2>/dev/null; systemctl disable mstats-web.service >/dev/null 2>&1
                rm -rf /tmp/mstats_web
                echo -e "\n  ${R}● Web UI has been safely shut down.${NC}"; sleep 2; break ;;
            0) break ;;
        esac
    done
}

while true; do
    clear; draw_mstats_header
    echo -e "\n  ${DIM}┌─[ TRAFFIC & BANDWIDTH ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Live Omni-Radar${NC} ${DIM}(CLI Real-Time Monitor)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Total Historical Usage${NC} ${DIM}(CLI Static Snapshot)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}TCP/UDP Connection Tracker${NC} ${DIM}(Active Clients)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Fabric QoS & Speed Limiter${NC} ${DIM}(Traffic Shaping)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${W}Active Bandwidth Benchmark${NC} ${DIM}(iPerf3 Tools)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${C}Web Dashboard Manager${NC} ${DIM}(Start/Stop Web Radar)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MSTATS ❯❯ ${NC}"; read opt
    case $opt in
        1) show_live_radar ;;
        2) show_total_usage ;;
        3) show_connection_tracker ;;
        4) qos_manager ;;
        5) iperf_benchmark ;;
        6) manage_web_ui ;;
        0) break ;;
    esac
done
EOF_MSTATS
chmod +x /usr/bin/mstats
