#!/bin/bash
# --- MDesign Modular Core (mweb.sh) | Global Enterprise UI v4.5.1 (Regex Fix) ---

CONF_FILE="/etc/mweb/web.conf"
mkdir -p /etc/mweb /etc/mstats/uptimes /tmp/mweb_daemon 2>/dev/null
[ ! -f "$CONF_FILE" ] && echo "WEB_PORT=1000" > "$CONF_FILE"
source "$CONF_FILE"
PORT=${WEB_PORT:-1000}
cd /tmp/mweb_daemon

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

init_frp_counters() {
    if [ -f "/etc/frp/frpc.toml" ] && systemctl is-active --quiet frpc 2>/dev/null; then
        local s_addr=$(awk -F'=' '/^serverAddr/ {print $2}' /etc/frp/frpc.toml 2>/dev/null | tr -d ' "')
        local s_port=$(awk -F'=' '/^serverPort/ {print $2}' /etc/frp/frpc.toml 2>/dev/null | tr -d ' ')
        if [ -n "$s_addr" ] && [ -n "$s_port" ]; then
            iptables -t mangle -C OUTPUT -d "$s_addr" -p tcp --dport "$s_port" -m comment --comment "FRP_CNT_TX" >/dev/null 2>&1 || \
            iptables -t mangle -A OUTPUT -d "$s_addr" -p tcp --dport "$s_port" -m comment --comment "FRP_CNT_TX" 2>/dev/null
            iptables -t mangle -C INPUT -s "$s_addr" -p tcp --sport "$s_port" -m comment --comment "FRP_CNT_RX" >/dev/null 2>&1 || \
            iptables -t mangle -A INPUT -s "$s_addr" -p tcp --sport "$s_port" -m comment --comment "FRP_CNT_RX" 2>/dev/null
        fi
    fi
    if [ -f "/etc/frp/frps.toml" ] && systemctl is-active --quiet frps 2>/dev/null; then
        local b_port=$(awk -F'=' '/^bindPort/ {print $2}' /etc/frp/frps.toml 2>/dev/null | tr -d ' ')
        if [ -n "$b_port" ]; then
            iptables -t mangle -C OUTPUT -p tcp --sport "$b_port" -m comment --comment "FRP_CNT_TX" >/dev/null 2>&1 || \
            iptables -t mangle -A OUTPUT -p tcp --sport "$b_port" -m comment --comment "FRP_CNT_TX" 2>/dev/null
            iptables -t mangle -C INPUT -p tcp --dport "$b_port" -m comment --comment "FRP_CNT_RX" >/dev/null 2>&1 || \
            iptables -t mangle -A INPUT -p tcp --dport "$b_port" -m comment --comment "FRP_CNT_RX" 2>/dev/null
        fi
    fi
}

get_frp_rx() {
    local rx=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep "FRP_CNT_RX" | awk '{sum+=$2} END {print sum}')
    echo "${rx:-0}"
}

get_frp_tx() {
    local tx=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null | grep "FRP_CNT_TX" | awk '{sum+=$2} END {print sum}')
    echo "${tx:-0}"
}

init_bh_counters() {
    for conf in /etc/mbackhaul/tunnels/*.toml; do
        [ ! -f "$conf" ] && continue
        local name=$(basename "$conf" .toml)
        if grep -q "\[server\]" "$conf"; then
            local port=$(awk -F'=' '/^bind/ {print $2}' "$conf" | grep -oP ':[0-9]+' | head -1 | tr -d ':')
            if [ -n "$port" ]; then
                iptables -t mangle -C INPUT -p tcp --dport "$port" -m comment --comment "MBH_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -p tcp --dport "$port" -m comment --comment "MBH_RX_${name}" 2>/dev/null
                iptables -t mangle -C OUTPUT -p tcp --sport "$port" -m comment --comment "MBH_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -p tcp --sport "$port" -m comment --comment "MBH_TX_${name}" 2>/dev/null
            fi
        elif grep -q "\[client\]" "$conf"; then
            # 🌟 باگ کشنده Regex در رادار فایروال اینجا حل شد 🌟
            local raw_remote=$(awk -F'=' '/^remote/ {print $2}' "$conf" | grep -oP '"\K[^"]+' | cut -d'?' -f1 | sed -E 's/^[a-zA-Z0-9_]+:\/\///')
            local r_ip=$(echo "$raw_remote" | cut -d: -f1); local r_port=$(echo "$raw_remote" | cut -d: -f2)
            if [ -n "$r_ip" ] && [ -n "$r_port" ]; then
                iptables -t mangle -C INPUT -s "$r_ip" -p tcp --sport "$r_port" -m comment --comment "MBH_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -s "$r_ip" -p tcp --sport "$r_port" -m comment --comment "MBH_RX_${name}" 2>/dev/null
                iptables -t mangle -C OUTPUT -d "$r_ip" -p tcp --dport "$r_port" -m comment --comment "MBH_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -d "$r_ip" -p tcp --dport "$r_port" -m comment --comment "MBH_TX_${name}" 2>/dev/null
            fi
        fi
    done
}

get_bh_rx() {
    local rx=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep "MBH_RX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${rx:-0}"
}

get_bh_tx() {
    local tx=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null | grep "MBH_TX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${tx:-0}"
}

get_uptime() {
    local iface=$1
    if ! ip link show "$iface" >/dev/null 2>&1 || [ "$(cat /sys/class/net/$iface/operstate 2>/dev/null)" == "down" ]; then echo "---"; return; fi
    local created=""
    if [ -f "/etc/mstats/uptimes/$iface" ]; then created=$(cat "/etc/mstats/uptimes/$iface" 2>/dev/null); fi
    if ! [[ "$created" =~ ^[0-9]+$ ]]; then
        created=$(stat -c %Y "/sys/class/net/$iface" 2>/dev/null)
        [[ "$created" =~ ^[0-9]+$ ]] && echo "$created" > "/etc/mstats/uptimes/$iface"
    fi
    if [[ "$created" =~ ^[0-9]+$ ]]; then
        local now=$(date +%s); local diff=$((now - created)); [ "$diff" -lt 0 ] && diff=0
        local d=$((diff / 86400)); local h=$(( (diff % 86400) / 3600 )); local m=$(( (diff % 3600) / 60 ))
        local s_uptime=""
        [ "$d" -gt 0 ] && s_uptime="${d}d "; [ "$h" -gt 0 ] && s_uptime="${s_uptime}${h}h "; s_uptime="${s_uptime}${m}m"
        [ "$s_uptime" == "0m" ] && s_uptime="Just now"
        echo "$s_uptime"
    else echo "---"; fi
}

get_frp_uptime() {
    local svc=$1
    local ts=$(systemctl show -p ActiveEnterTimestamp "$svc" 2>/dev/null | awk -F= '{print $2}')
    if [ -n "$ts" ]; then
        local created=$(date -d "$ts" +%s 2>/dev/null)
        if [[ "$created" =~ ^[0-9]+$ ]]; then
            local now=$(date +%s); local diff=$((now - created)); [ "$diff" -lt 0 ] && diff=0
            local d=$((diff / 86400)); local h=$(( (diff % 86400) / 3600 )); local m=$(( (diff % 3600) / 60 ))
            local s_uptime=""
            [ "$d" -gt 0 ] && s_uptime="${d}d "; [ "$h" -gt 0 ] && s_uptime="${s_uptime}${h}h "; s_uptime="${s_uptime}${m}m"
            [ "$s_uptime" == "0m" ] && s_uptime="Just now"
            echo "$s_uptime"; return
        fi
    fi
    echo "Active"
}

get_tunnel_ip() {
    local dev=$1
    local rip=$(ip -d link show "$dev" 2>/dev/null | grep -oP 'remote \K[0-9a-fA-F\.:]+' | head -n 1)
    [ -z "$rip" ] && rip=$(ip tunnel show "$dev" 2>/dev/null | grep -oP 'remote \K[0-9a-fA-F\.:]+' | head -n 1)
    if [ -z "$rip" ] && [[ "$dev" == br_* ]]; then
        local vx_dev="${dev/br_/vx_}"
        rip=$(ip -d link show "$vx_dev" 2>/dev/null | grep -oP 'remote \K[0-9a-fA-F\.:]+' | head -n 1)
    fi
    if [ -z "$rip" ] && [[ "$dev" == l2tp_* ]]; then
        local tun_id=$(ip l2tp show session | grep -B1 "name $dev" | grep "tunnel" | grep -oP 'tunnel \K[0-9]+' | head -n 1)
        if [ -n "$tun_id" ]; then rip=$(ip l2tp show tunnel tunnel_id "$tun_id" 2>/dev/null | grep -oP 'peer \K[0-9\.]+'); fi
    fi
    echo "$rip"
}

cat << 'PY_EOF' > server.py
import http.server
import socketserver
import subprocess
import urllib.parse
import sys
import os

PORT = int(sys.argv[1])

class APIHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        super().end_headers()

    def do_GET(self):
        if self.path.startswith('/restart?iface='):
            query = urllib.parse.urlparse(self.path).query
            params = urllib.parse.parse_qs(query)
            if 'iface' in params:
                iface = params['iface'][0]
                if iface == 'FRP Engine':
                    os.system("systemctl restart frps 2>/dev/null; systemctl restart frpc 2>/dev/null")
                    os.system("date +%s > /etc/mstats/uptimes/frp_engine 2>/dev/null")
                elif os.path.exists(f"/etc/mbackhaul/tunnels/{iface}.toml"):
                    os.system(f"systemctl restart mbackhaul@{iface} 2>/dev/null")
                elif iface.startswith('l2tp_'):
                    os.system("systemctl restart ml2tp.service 2>/dev/null")
                    os.system(f"date +%s > /etc/mstats/uptimes/{iface} 2>/dev/null")
                elif iface.startswith('hys_'):
                    os.system(f"systemctl restart mhysteria@{iface} 2>/dev/null")
                    os.system(f"date +%s > /etc/mstats/uptimes/{iface} 2>/dev/null")
                elif iface.replace('_', '').replace('-', '').isalnum():
                    subprocess.run(['ip', 'link', 'set', iface, 'down'], capture_output=True)
                    subprocess.run(['sleep', '1'])
                    subprocess.run(['ip', 'link', 'set', iface, 'up'], capture_output=True)
                    os.system(f"date +%s > /etc/mstats/uptimes/{iface} 2>/dev/null")
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b"OK")
        else:
            super().do_GET()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", PORT), APIHandler) as httpd:
    httpd.serve_forever()
PY_EOF

python3 server.py "$PORT" >/dev/null 2>&1 &
PY_PID=$!
trap "kill $PY_PID; rm -rf /tmp/mweb_daemon; exit" SIGINT SIGTERM

cat <<'EOF' > index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>MDesign Web UI</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;700&family=Vazirmatn:wght@400;500;700&display=swap');
        
        :root { 
            --bg-base: #030712; --card-bg: rgba(15, 23, 42, 0.6); --border: rgba(51, 65, 85, 0.5); 
            --row-bg: rgba(255,255,255,0.015); --row-border: rgba(255,255,255,0.03);
            --text-main: #f8fafc; --text-muted: #94a3b8; --text-slate: #cbd5e1;
            --sky: #38bdf8; --pink: #f472b6; --green: #34d399; --red: #f87171; --yellow: #fbbf24; --purple: #c084fc; 
            --glow: rgba(56, 189, 248, 0.1); --shadow: rgba(0,0,0,0.3);
        }
        
        body.light-mode {
            --bg-base: #f1f5f9; --card-bg: rgba(255, 255, 255, 0.8); --border: rgba(203, 213, 225, 0.8); 
            --row-bg: rgba(248, 250, 252, 0.5); --row-border: rgba(226, 232, 240, 0.8);
            --text-main: #0f172a; --text-muted: #64748b; --text-slate: #334155;
            --sky: #0ea5e9; --pink: #db2777; --green: #059669; --red: #dc2626; --yellow: #d97706; --purple: #9333ea; 
            --glow: rgba(14, 165, 233, 0.05); --shadow: rgba(0,0,0,0.05);
        }

        * { box-sizing: border-box; margin: 0; padding: 0; transition: background-color 0.3s, color 0.3s, border-color 0.3s; }
        body { background-color: var(--bg-base); background-image: radial-gradient(circle at 50% 0%, var(--glow) 0%, transparent 40%); color: var(--text-main); font-family: 'Inter', sans-serif; }
        body[dir="rtl"] { font-family: 'Vazirmatn', sans-serif; }
        
        .wrapper { display: flex; min-height: 100vh; padding: 40px 15px; max-width: 1400px; margin: 0 auto; gap: 40px; }
        .container { flex-grow: 1; display: flex; flex-direction: column; gap: 40px; }

        .sidebar {
            position: fixed; left: 20px; top: 50%; transform: translateY(-50%);
            display: flex; flex-direction: column; gap: 28px; z-index: 1000;
            background: var(--card-bg); padding: 30px 18px; border-radius: 24px;
            border: 1px solid var(--border); backdrop-filter: blur(15px); -webkit-backdrop-filter: blur(15px);
            box-shadow: 0 10px 30px var(--shadow);
        }
        body[dir="rtl"] .sidebar { left: auto; right: 20px; }

        .side-btn {
            width: 52px; height: 52px; border-radius: 14px; display: flex; align-items: center; justify-content: center;
            cursor: pointer; border: 2px solid transparent; transition: 0.3s;
            background: rgba(255,255,255,0.05); color: var(--text-main); position: relative;
        }
        .side-btn:hover { transform: scale(1.05); }
        .side-btn.active { border-color: var(--sky); background: rgba(56, 189, 248, 0.15); box-shadow: 0 0 15px rgba(56, 189, 248, 0.4); }
        body.light-mode .side-btn.active { background: rgba(14, 165, 233, 0.15); }
        .side-btn svg.icon-sys { width: 26px; height: 26px; }
        .side-btn svg.icon-flag { width: 32px; height: auto; border-radius: 4px;}

        .section-title { font-size: 1.1rem; font-weight: 700; color: var(--text-main); display: flex; align-items: center; gap: 10px; margin-bottom: 20px; letter-spacing: 0.5px;}
        .status-dot { width: 8px; height: 8px; border-radius: 50%; box-shadow: 0 0 8px currentColor; flex-shrink: 0;}
        .dot-green { background: var(--green); color: var(--green); } .dot-red { background: var(--red); color: var(--red); } .dot-sky { background: var(--sky); color: var(--sky); }
        
        .fleet-grid, .tunnels-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(400px, 1fr)); gap: 20px; }
        .glass-card { background: var(--card-bg); border: 1px solid var(--border); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); border-radius: 12px; padding: 25px; margin-bottom: 15px; box-shadow: 0 10px 30px var(--shadow);}
        .hw-border { border-top: 3px solid var(--sky); } .tun-border { border-top: 3px solid var(--purple); }

        .hw-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; flex-wrap: wrap; gap: 10px;}
        .hw-title { font-size: 1rem; font-weight: 700; display: flex; align-items: center; gap: 8px; color: var(--text-main); }
        .hw-ip { background: rgba(56, 189, 248, 0.1); border: 1px solid rgba(56, 189, 248, 0.2); color: var(--sky); padding: 4px 10px; border-radius: 6px; font-family: 'JetBrains Mono', monospace; font-size: 0.75rem; direction: ltr; }

        .t-row { display: flex; justify-content: space-between; align-items: center; padding: 14px 16px; background: var(--row-bg); border: 1px solid var(--row-border); border-radius: 8px; margin-bottom: 10px; }
        .t-row.split { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; background: transparent; border: none; padding: 0; }
        .t-row.split > div { display: flex; justify-content: space-between; align-items: center; background: var(--row-bg); border: 1px solid var(--row-border); border-radius: 8px; padding: 14px 16px; }
        
        .t-lbl { font-size: 0.7rem; font-weight: 700; color: var(--text-muted); text-transform: uppercase; letter-spacing: 1px; }
        .t-val { font-family: 'JetBrains Mono', monospace; font-size: 0.9rem; font-weight: 600; display: flex; align-items: center; gap: 8px; direction: ltr;}

        .tun-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 25px; border-bottom: 1px solid var(--border); padding-bottom: 15px;}
        .tun-title { font-size: 1.1rem; font-weight: 700; display: flex; align-items: center; gap: 8px; font-family: 'JetBrains Mono', monospace; color: var(--text-main); }
        .tun-badges { display: flex; gap: 10px; flex-wrap: wrap;}
        .badge { padding: 4px 10px; border-radius: 6px; font-size: 0.65rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px;}
        
        .b-purple { background: rgba(192, 132, 252, 0.1); color: var(--purple); border: 1px solid rgba(192, 132, 252, 0.2); }
        .b-blue { background: rgba(56, 189, 248, 0.1); color: var(--sky); border: 1px solid rgba(56, 189, 248, 0.2); }
        .b-green { background: rgba(52, 211, 153, 0.1); color: var(--green); border: 1px solid rgba(52, 211, 153, 0.2); }
        .b-red { background: rgba(248, 113, 113, 0.1); color: var(--red); border: 1px solid rgba(248, 113, 113, 0.2); }
        .b-yellow { background: rgba(251, 191, 36, 0.1); color: var(--yellow); border: 1px solid rgba(251, 191, 36, 0.2); }

        .btn-restart { display: inline-flex; align-items: center; justify-content: center; background: rgba(56, 189, 248, 0.1); border: 1px solid rgba(56, 189, 248, 0.3); color: var(--sky); padding: 8px 16px; border-radius: 6px; font-size: 0.75rem; font-weight: 600; cursor: pointer; transition: 0.2s; margin-top: 15px; }
        body[dir="ltr"] .btn-restart { float: right; }
        body[dir="rtl"] .btn-restart { float: left; font-family: 'Vazirmatn';}
        .btn-restart:hover { background: rgba(56, 189, 248, 0.2); }
        .clear { clear: both; }

        .divider { height: 1px; background: var(--border); width: 100%; margin: 25px 0; }
        .sub-title { margin-bottom: 12px; font-size: 0.75rem; font-weight: 700; color: var(--text-muted); letter-spacing: 1px; display: flex; align-items: center; gap: 8px; }

        .text-main { color: var(--text-main); } .text-slate { color: var(--text-slate); }
        .text-sky { color: var(--sky); } .text-pink { color: var(--pink); } 
        .text-green { color: var(--green); } .text-muted { color: var(--text-muted); } .text-yellow { color: var(--yellow); }
        
        @media (max-width: 950px) { 
            .wrapper { padding-left: 15px; padding-right: 15px; padding-bottom: 120px;}
            .sidebar {
                top: auto; bottom: 20px; left: 50%; transform: translateX(-50%);
                flex-direction: row; padding: 15px 30px; gap: 30px; border-radius: 24px;
                width: max-content; margin: 0 auto;
            }
            body[dir="rtl"] .sidebar { right: 50%; transform: translateX(50%); }
            
            .fleet-grid, .tunnels-grid { grid-template-columns: 1fr; }
            .t-row.split { grid-template-columns: 1fr; gap: 10px; } 
            .t-row.split > div, .t-row { flex-direction: column; align-items: flex-start; gap: 8px; padding: 12px; }
            .t-val { align-self: flex-start; }
            body[dir="rtl"] .t-row.split > div, body[dir="rtl"] .t-row { align-items: flex-start; }
            body[dir="rtl"] .t-val { align-self: flex-end; }
            .glass-card { padding: 15px; }
            .tun-header { flex-direction: column; align-items: flex-start; gap: 15px; }
            body[dir="ltr"] .btn-restart, body[dir="rtl"] .btn-restart { width: 100%; text-align: center; float: none; }
        }
        @media (min-width: 951px) {
            .wrapper { padding-left: 110px; }
            body[dir="rtl"] .wrapper { padding-left: 15px; padding-right: 110px; }
        }
    </style>
</head>
<body>
    <div class="sidebar">
        <div class="side-btn" id="btn-theme" onclick="toggleTheme()" title="Toggle Theme">
            <svg class="icon-sys" id="theme-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor"></svg>
        </div>
        <div class="side-btn" id="btn-en" onclick="setLang('en')" title="English">
            <svg class="icon-flag" viewBox="0 0 60 40"><rect width="60" height="40" fill="#fff"/><rect width="60" height="4" y="4" fill="#d21034"/><rect width="60" height="4" y="12" fill="#d21034"/><rect width="60" height="4" y="20" fill="#d21034"/><rect width="60" height="4" y="28" fill="#d21034"/><rect width="60" height="4" y="36" fill="#d21034"/><rect width="30" height="22" fill="#002664"/></svg>
        </div>
        <div class="side-btn" id="btn-fa" onclick="setLang('fa')" title="فارسی">
            <svg class="icon-flag" viewBox="0 0 60 40"><rect width="60" height="40" fill="#fff"/><rect width="60" height="13.3" fill="#239f40"/><rect width="60" height="13.3" y="26.6" fill="#da0000"/><circle cx="30" cy="20" r="4" fill="#da0000"/></svg>
        </div>
    </div>

    <div class="wrapper">
        <div class="container">
            <div>
                <div class="section-title"><div class="status-dot dot-green"></div> <span id="lbl-hw-title">FLEET HARDWARE RADAR</span></div>
                <div class="fleet-grid" id="hw-container">
                    <div class="glass-card hw-border"><div style="text-align:center;" class="text-muted" id="lbl-loading">Loading...</div></div>
                </div>
            </div>
            <div>
                <div class="section-title"><div class="status-dot dot-green" id="sync-dot"></div> <span id="lbl-tun-title">ACTIVE TUNNEL MATRIX</span></div>
                <div class="tunnels-grid" id="tun-container">
                    <div class="glass-card tun-border"><div style="text-align:center;" class="text-muted" id="lbl-fetching">Fetching Tunnels...</div></div>
                </div>
            </div>
        </div>
    </div>

    <script>
        const i18n = {
            en: {
                hw_title: "FLEET HARDWARE RADAR", tun_title: "ACTIVE TUNNEL MATRIX",
                loading: "Loading Hardware...", fetching: "Fetching Tunnels...",
                loc_node: "Local Node (Iran)", live_cpu: "LIVE CPU", mem_ram: "MEMORY (RAM)", sys_up: "SYSTEM UPTIME",
                end_ip: "ENDPOINT IP", latency: "LATENCY", tun_up: "TUNNEL UPTIME",
                live_dn: "LIVE DOWNLOAD", live_up: "LIVE UPLOAD",
                tot_dn: "TOTAL DOWNLOAD", tot_up: "TOTAL UPLOAD",
                tot_spd: "TOTAL LIVE SPEED", tot_traf: "TOTAL USED TRAFFIC",
                hw_sync: "REMOTE HARDWARE (KHAREJ)", kh_cpu: "REMOTE CPU", kh_ram: "REMOTE RAM",
                btn_res: "Restart Tunnel", wait: "⏳ WAIT", done: "✅ DONE",
                offline: "OFFLINE", timeout: "TIMEOUT", no_tun: "No active tunnels found."
            },
            fa: {
                hw_title: "رادار سخت‌افزار ناوگان", tun_title: "ماتریس تونل‌های فعال",
                loading: "در حال دریافت اطلاعات...", fetching: "در حال پردازش تونل‌ها...",
                loc_node: "سرور محلی (ایران)", live_cpu: "پردازنده زنده", mem_ram: "حافظه (رم)", sys_up: "زمان روشنی سیستم",
                end_ip: "آی‌پی مقصد", latency: "میزان تاخیر", tun_up: "زمان روشنی تونل",
                live_dn: "دانلود زنده", live_up: "آپلود زنده",
                tot_dn: "کل دانلود", tot_up: "کل آپلود",
                tot_spd: "مجموع سرعت زنده", tot_traf: "مجموع ترافیک مصرفی",
                hw_sync: "سخت‌افزار سرور خارج", kh_cpu: "پردازنده خارج", kh_ram: "رم خارج",
                btn_res: "راه‌اندازی مجدد", wait: "⏳ صبر کنید", done: "✅ انجام شد",
                offline: "قطع ارتباط", timeout: "تایم‌اوت", no_tun: "تونل فعالی یافت نشد."
            }
        };

        let currentLang = localStorage.getItem('mdesign_lang') || 'en';
        function t(key) { return i18n[currentLang][key]; }

        function setLang(l) {
            currentLang = l; localStorage.setItem('mdesign_lang', l);
            document.body.dir = l === 'fa' ? 'rtl' : 'ltr';
            document.getElementById('btn-en').classList.toggle('active', l === 'en');
            document.getElementById('btn-fa').classList.toggle('active', l === 'fa');
            document.getElementById('lbl-hw-title').innerText = t('hw_title');
            document.getElementById('lbl-tun-title').innerText = t('tun_title');
            fetchRoutine();
        }

        const iconSun = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z" />';
        const iconMoon = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" />';

        function toggleTheme() {
            document.body.classList.toggle('light-mode');
            const isLight = document.body.classList.contains('light-mode');
            localStorage.setItem('mdesign_theme', isLight ? 'light' : 'dark');
            document.getElementById('theme-icon').innerHTML = isLight ? iconMoon : iconSun;
        }

        setLang(currentLang);
        if (localStorage.getItem('mdesign_theme') === 'light') { document.body.classList.add('light-mode'); document.getElementById('theme-icon').innerHTML = iconMoon; } 
        else { document.getElementById('theme-icon').innerHTML = iconSun; }

        let isRestarting = false;
        let hwData = {};

        function restartTunnel(iface, btn) {
            isRestarting = true;
            btn.innerHTML = t('wait'); btn.style.opacity = "0.5"; btn.style.pointerEvents = "none";
            fetch('/restart?iface=' + iface).then(r => {
                if(r.ok) { btn.innerHTML = t('done'); btn.style.color = "var(--green)"; btn.style.borderColor = "var(--green)"; }
                setTimeout(() => { isRestarting = false; }, 1500);
            }).catch(() => { isRestarting = false; });
        }

        async function fetchRoutine() {
            if (isRestarting) return;
            try {
                let r = await fetch('/api_data.json?t=' + Date.now());
                if (!r.ok) throw new Error('API down');
                let data = await r.json();
                document.getElementById('sync-dot').className = 'status-dot dot-green';

                let hwHtml = `
                <div class="glass-card hw-border">
                    <div class="hw-header">
                        <div class="hw-title"><div class="status-dot dot-green"></div> ${t('loc_node')}</div>
                        <div class="hw-ip">${data.local.ip}</div>
                    </div>
                    <div class="t-row"><span class="t-lbl">${t('live_cpu')}</span><span class="t-val text-sky" dir="ltr">${data.local.cpu}</span></div>
                    <div class="t-row"><span class="t-lbl">${t('mem_ram')}</span><span class="t-val text-pink" dir="ltr">${data.local.ram}</span></div>
                    <div class="t-row"><span class="t-lbl">${t('sys_up')}</span><span class="t-val text-green" dir="ltr" style="font-family:'Inter', sans-serif;">${data.local.uptime}</span></div>
                </div>`;
                document.getElementById('hw-container').innerHTML = hwHtml;

                let uniqueEndpoints = [...new Set(data.remotes)];
                let fetchPromises = uniqueEndpoints.map(async (ip) => {
                    try {
                        let res = await fetch(`http://${ip}:1000/api_data.json?t=${Date.now()}`, { signal: AbortSignal.timeout(2000) });
                        hwData[ip] = await res.json();
                    } catch(e) { hwData[ip] = null; }
                });
                await Promise.all(fetchPromises);

                let tunHtml = "";
                if(data.tunnels.length === 0) {
                    tunHtml = `<div class='glass-card tun-border'><div style='text-align:center;' class='text-muted'>${t('no_tun')}</div></div>`;
                } else {
                    for(let tObj of data.tunnels) {
                        let stBadge = tObj.state === "ONLINE" ? "<span class='badge b-green'>ONLINE</span>" : "<span class='badge b-red'>OFFLINE</span>";
                        
                        let typeBadge = "";
                        if (tObj.type.includes("VXLAN")) typeBadge = "<span class='badge b-purple'>VXLAN/L2</span>";
                        else if (tObj.type.includes("L2TPv3")) typeBadge = "<span class='badge' style='background:rgba(20, 184, 166, 0.1); color:#14b8a6; border:1px solid rgba(20, 184, 166, 0.2);'>L2TPv3/L3</span>";
                        else if (tObj.type.includes("Hys2")) typeBadge = "<span class='badge b-green'>Hysteria2/L3</span>";
                        else if (tObj.type.includes("Proxy")) typeBadge = "<span class='badge b-yellow'>FRP/L4</span>";
                        else if (tObj.type.includes("Backhaul")) typeBadge = "<span class='badge b-red'>MBACKHAUL/L4</span>";
                        else typeBadge = "<span class='badge b-blue'>GRE/L3</span>";
                        
                        let pingHtml = "<span class='text-slate'>---</span>";
                        if(tObj.state === "ONLINE") {
                            pingHtml = tObj.ping && tObj.ping !== "---" ? `<div class="status-dot dot-green"></div><span class="text-green" dir="ltr">${tObj.ping} ms</span>` : `<div class="status-dot dot-red"></div><span style="color:var(--red);">${t('timeout')}</span>`;
                        }

                        let rCpu = "--%", rRam = "--%";
                        let rData = hwData[tObj.endpoint];
                        if (rData && rData.local) {
                            rCpu = rData.local.cpu; rRam = rData.local.ram;
                        } else {
                            rCpu = `<span style='color:var(--red); font-family:Inter;'>${t('offline')}</span>`;
                            rRam = `<span style='color:var(--red); font-family:Inter;'>${t('offline')}</span>`;
                        }

                        tunHtml += `
                        <div class="glass-card tun-border">
                            <div class="tun-header">
                                <div class="tun-title"><div class="status-dot ${tObj.state === 'ONLINE' ? 'dot-green' : 'dot-red'}"></div> ${tObj.iface}</div>
                                <div class="tun-badges" dir="ltr">${typeBadge} ${stBadge}</div>
                            </div>
                            
                            <div class="t-row"><span class="t-lbl">${t('end_ip')}</span><span class="t-val text-slate" dir="ltr">${tObj.endpoint}</span></div>
                            
                            <div class="t-row split">
                                <div><span class="t-lbl">${t('latency')}</span><span class="t-val">${pingHtml}</span></div>
                                <div><span class="t-lbl">${t('tun_up')}</span><span class="t-val text-slate" dir="ltr" style="font-family:'Inter', sans-serif;">${tObj.uptime}</span></div>
                            </div>

                            <div class="t-row split">
                                <div><span class="t-lbl">${t('live_dn')}</span><span class="t-val text-sky" dir="ltr">${tObj.rx_spd}</span></div>
                                <div><span class="t-lbl">${t('tot_dn')}</span><span class="t-val text-muted" dir="ltr">${tObj.rx_tot}</span></div>
                            </div>
                            
                            <div class="t-row split">
                                <div><span class="t-lbl">${t('live_up')}</span><span class="t-val text-pink" dir="ltr">${tObj.tx_spd}</span></div>
                                <div><span class="t-lbl">${t('tot_up')}</span><span class="t-val text-muted" dir="ltr">${tObj.tx_tot}</span></div>
                            </div>

                            <div class="t-row split">
                                <div><span class="t-lbl">${t('tot_spd')}</span><span class="t-val text-green" dir="ltr">${tObj.comb_spd}</span></div>
                                <div><span class="t-lbl">${t('tot_traf')}</span><span class="t-val text-yellow" dir="ltr">${tObj.comb_tot}</span></div>
                            </div>
                            
                            <div class="divider"></div>
                            <div class="sub-title"><div class="status-dot dot-sky"></div> ${t('hw_sync')}</div>

                            <div class="t-row split">
                                <div><span class="t-lbl">${t('kh_cpu')}</span><span class="t-val text-sky" dir="ltr">${rCpu}</span></div>
                                <div><span class="t-lbl">${t('kh_ram')}</span><span class="t-val text-pink" dir="ltr">${rRam}</span></div>
                            </div>
                            
                            <button onclick="restartTunnel('${tObj.iface}', this)" class="btn-restart">${t('btn_res')}</button>
                            <div class="clear"></div>
                        </div>`;
                    }
                }
                if(!isRestarting) document.getElementById('tun-container').innerHTML = tunHtml;

            } catch(e) { document.getElementById('sync-dot').className = 'status-dot dot-red'; }
        }
        setInterval(fetchRoutine, 1500);
        fetchRoutine();
    </script>
</body>
</html>
EOF

declare -A rx_old tx_old
prev_total=""
prev_idle=""

while true; do
    read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    curr_idle=$((idle + iowait)); curr_total=$((user + nice + system + irq + softirq + steal + curr_idle))
    
    cpu_load="0.0"
    if [ -n "$prev_total" ] && [ "$curr_total" -ne "$prev_total" ]; then
        total_diff=$((curr_total - prev_total)); idle_diff=$((curr_idle - prev_idle))
        if [ "$total_diff" -gt 0 ]; then cpu_load=$(awk "BEGIN {printf \"%.1f\", 100 * ($total_diff - $idle_diff) / $total_diff}"); fi
    fi
    prev_total=$curr_total; prev_idle=$curr_idle
    ram_usage=$(free -m | awk '/Mem:/ {printf "%.1f", $3/$2 * 100}')
    sys_uptime=$(uptime -p | sed 's/up //')

    TUNNELS_JSON="["
    remote_list=()
    first_tun=true
    
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf /etc/ml2tp/tunnels/*.conf /etc/mhysteria/tunnels/*.conf; do
        if [ -f "$conf" ]; then
            source "$conf"
            is_vx=false; name="$T_NAME"
            if [ -n "$BR_NAME" ]; then is_vx=true; name="$BR_NAME"; fi
            
            r_new=$(get_iface_rx "$name"); t_new=$(get_iface_tx "$name")
            r_old=${rx_old[$name]:-$r_new}; t_old=${tx_old[$name]:-$t_new}
            rx_s=$((r_new - r_old)); [ "$rx_s" -lt 0 ] && rx_s=0
            tx_s=$((t_new - t_old)); [ "$tx_s" -lt 0 ] && tx_s=0
            rx_old[$name]=$r_new; tx_old[$name]=$t_new

            comb_spd=$((rx_s + tx_s)); comb_tot=$((r_new + t_new))

            st_badge="OFFLINE"
            if ip link show "$name" 2>/dev/null | grep -q "UP"; then st_badge="ONLINE"; fi
            state=$(cat /sys/class/net/$name/operstate 2>/dev/null)
            if [[ "$state" == "up" || "$state" == "unknown" ]]; then st_badge="ONLINE"; fi
            
            rip=$(get_tunnel_ip "$name" 2>/dev/null); [ -z "$rip" ] && rip=${T_REMOTE:-${REMOTE_IP:-${REMOTE_PUB:-"Unknown"}}}
            remote_list+=("$REMOTE_PUB")
            
            ping_res=""
            if [[ "$st_badge" == "ONLINE" ]]; then ping_res=$(ping -c 1 -W 1 "$rip" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}'); fi
            t_uptime=$(get_uptime "$name")
            
            type_txt="GRE"
            [ "$is_vx" = true ] && type_txt="VXLAN"
            [[ "$conf" == *"/ml2tp/"* ]] && type_txt="L2TPv3"
            [[ "$conf" == *"/mhysteria/"* ]] && type_txt="Hys2"
            
            if [ "$first_tun" = true ]; then first_tun=false; else TUNNELS_JSON+=","; fi
            TUNNELS_JSON+="{\"iface\":\"$name\", \"type\":\"$type_txt\", \"endpoint\":\"$rip\", \"state\":\"$st_badge\", \"ping\":\"$ping_res\", \"uptime\":\"$t_uptime\", \"rx_spd\":\"$(format_speed $rx_s)\", \"tx_spd\":\"$(format_speed $tx_s)\", \"rx_tot\":\"$(format_total $r_new)\", \"tx_tot\":\"$(format_total $t_new)\", \"comb_spd\":\"$(format_speed $comb_spd)\", \"comb_tot\":\"$(format_total $comb_tot)\"}"
        fi
    done

    init_frp_counters
    if systemctl is-active --quiet frps 2>/dev/null || systemctl is-active --quiet frpc 2>/dev/null; then
        frp_name="FRP Engine"; frp_type="Proxy"; frp_state="ONLINE"; frp_rip="Listening..."; frp_ping="---"; frp_uptime="Active"
        
        if systemctl is-active --quiet frps 2>/dev/null; then
            frp_uptime=$(get_frp_uptime "frps")
            b_port=$(awk -F'=' '/^bindPort/ {print $2}' /etc/frp/frps.toml 2>/dev/null | tr -d ' ')
            if [ -n "$b_port" ]; then
                active_client=$(ss -tnH state established 2>/dev/null | awk -v p=":${b_port}$" '$(NF-1) ~ p {print $NF; exit}' | rev | cut -d: -f2- | rev | tr -d '[]' | sed 's/^::ffff://' | grep -Ev '^(127\.0\.0\.1|0\.0\.0\.0|\*|)$')
                if [ -n "$active_client" ]; then frp_rip="$active_client"; remote_list+=("$active_client"); frp_ping=$(ping -c 1 -W 1 "$active_client" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}'); fi
            fi
        elif systemctl is-active --quiet frpc 2>/dev/null; then
            frp_uptime=$(get_frp_uptime "frpc")
            s_addr=$(awk -F'=' '/^serverAddr/ {print $2}' /etc/frp/frpc.toml 2>/dev/null | tr -d ' "')
            if [ -n "$s_addr" ]; then frp_rip="$s_addr"; remote_list+=("$s_addr"); frp_ping=$(ping -c 1 -W 1 "$s_addr" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}'); fi
        fi

        r_new_f=$(get_frp_rx); t_new_f=$(get_frp_tx)
        r_old_f=${rx_old["FRP_TUNNEL"]:-$r_new_f}; t_old_f=${tx_old["FRP_TUNNEL"]:-$t_new_f}
        rx_s_f=$((r_new_f - r_old_f)); [ "$rx_s_f" -lt 0 ] && rx_s_f=0
        tx_s_f=$((t_new_f - t_old_f)); [ "$tx_s_f" -lt 0 ] && tx_s_f=0
        rx_old["FRP_TUNNEL"]=$r_new_f; tx_old["FRP_TUNNEL"]=$t_new_f

        comb_spd_f=$((rx_s_f + tx_s_f)); comb_tot_f=$((r_new_f + t_new_f))

        if [ "$first_tun" = true ]; then first_tun=false; else TUNNELS_JSON+=","; fi
        TUNNELS_JSON+="{\"iface\":\"$frp_name\", \"type\":\"$frp_type\", \"endpoint\":\"$frp_rip\", \"state\":\"$frp_state\", \"ping\":\"$frp_ping\", \"uptime\":\"$frp_uptime\", \"rx_spd\":\"$(format_speed $rx_s_f)\", \"tx_spd\":\"$(format_speed $tx_s_f)\", \"rx_tot\":\"$(format_total $r_new_f)\", \"tx_tot\":\"$(format_total $t_new_f)\", \"comb_spd\":\"$(format_speed $comb_spd_f)\", \"comb_tot\":\"$(format_total $comb_tot_f)\"}"
    fi

    # --- NEW: BACKHAUL DATA COLLECTION ---
    init_bh_counters
    for conf in /etc/mbackhaul/tunnels/*.toml; do
        [ ! -f "$conf" ] && continue
        bh_name=$(basename "$conf" .toml)
        bh_type="Backhaul"
        bh_state="OFFLINE"
        systemctl is-active --quiet "mbackhaul@$bh_name" 2>/dev/null && bh_state="ONLINE"
        
        bh_rip="Unknown"
        if grep -q "\[server\]" "$conf"; then
            bh_type="Backhaul (Server)"
            bh_rip="Listening..."
        elif grep -q "\[client\]" "$conf"; then
            bh_type="Backhaul (Client)"
            # 🌟 باگ کشنده Regex در کالکتور وب اینجا حل شد 🌟
            local raw_remote=$(awk -F'=' '/^remote/ {print $2}' "$conf" | grep -oP '"\K[^"]+' | cut -d'?' -f1 | sed -E 's/^[a-zA-Z0-9_]+:\/\///')
            bh_rip=$(echo "$raw_remote" | cut -d: -f1)
            [ -n "$bh_rip" ] && remote_list+=("$bh_rip")
        fi
        
        bh_ping="---"
        if [ "$bh_state" == "ONLINE" ] && grep -q "\[client\]" "$conf" && [ -n "$bh_rip" ]; then
            bh_ping=$(ping -c 1 -W 1 "$bh_rip" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')
        fi
        
        bh_uptime="Active"
        [ "$bh_state" == "ONLINE" ] && bh_uptime=$(get_frp_uptime "mbackhaul@$bh_name")

        r_new_b=$(get_bh_rx "$bh_name"); t_new_b=$(get_bh_tx "$bh_name")
        r_old_b=${rx_old["BH_$bh_name"]:-$r_new_b}; t_old_b=${tx_old["BH_$bh_name"]:-$t_new_b}
        rx_s_b=$((r_new_b - r_old_b)); [ "$rx_s_b" -lt 0 ] && rx_s_b=0
        tx_s_b=$((t_new_b - t_old_b)); [ "$tx_s_b" -lt 0 ] && tx_s_b=0
        rx_old["BH_$bh_name"]=$r_new_b; tx_old["BH_$bh_name"]=$t_new_b

        comb_spd_b=$((rx_s_b + tx_s_b)); comb_tot_b=$((r_new_b + t_new_b))

        if [ "$first_tun" = true ]; then first_tun=false; else TUNNELS_JSON+=","; fi
        TUNNELS_JSON+="{\"iface\":\"$bh_name\", \"type\":\"$bh_type\", \"endpoint\":\"$bh_rip\", \"state\":\"$bh_state\", \"ping\":\"$bh_ping\", \"uptime\":\"$bh_uptime\", \"rx_spd\":\"$(format_speed $rx_s_b)\", \"tx_spd\":\"$(format_speed $tx_s_b)\", \"rx_tot\":\"$(format_total $r_new_b)\", \"tx_tot\":\"$(format_total $t_new_b)\", \"comb_spd\":\"$(format_speed $comb_spd_b)\", \"comb_tot\":\"$(format_total $comb_tot_b)\"}"
    done
    # ----------------------------------------

    TUNNELS_JSON+="]"

    unique_remotes=($(echo "${remote_list[@]}" | tr ' ' '\n' | sort -u | grep -v '^$'))
    remotes_json="["
    total_r=${#unique_remotes[@]}
    for ((i=0; i<total_r; i++)); do remotes_json+="\"${unique_remotes[$i]}\""; [ $i -lt $((total_r - 1)) ] && remotes_json+=","; done
    remotes_json+="]"

    cat <<EOF > api_data.json
{
    "local": {"ip": "${MY_PUB_IP}", "cpu": "${cpu_load}%", "ram": "${ram_usage}%", "uptime": "${sys_uptime}"},
    "remotes": ${remotes_json},
    "tunnels": ${TUNNELS_JSON}
}
EOF
    sleep 1.2
done
