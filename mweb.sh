#!/bin/bash
# --- MDesign Modular Core (mweb.sh) | Interactive Enterprise UI v5.0.0 (Auth & API Ready) ---

CONF_FILE="/etc/mweb/web.conf"
mkdir -p /etc/mweb /etc/mstats/uptimes /tmp/mweb_daemon 2>/dev/null

if [ ! -f "$CONF_FILE" ]; then
    echo -e "WEB_PORT=1000\nWEB_USER=admin\nWEB_PASS=admin" > "$CONF_FILE"
fi
source "$CONF_FILE"

PORT=${WEB_PORT:-1000}
W_USER=${WEB_USER:-admin}
W_PASS=${WEB_PASS:-admin}

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

get_uptime() {
    local iface=$1
    if ! ip link show "$iface" >/dev/null 2>&1 || [ "$(cat /sys/class/net/$iface/operstate 2>/dev/null)" == "down" ]; then echo "---"; return; fi
    local created=""
    [ -f "/etc/mstats/uptimes/$iface" ] && created=$(cat "/etc/mstats/uptimes/$iface" 2>/dev/null)
    if ! [[ "$created" =~ ^[0-9]+$ ]]; then
        created=$(stat -c %Y "/sys/class/net/$iface" 2>/dev/null)
        [[ "$created" =~ ^[0-9]+$ ]] && echo "$created" > "/etc/mstats/uptimes/$iface"
    fi
    if [[ "$created" =~ ^[0-9]+$ ]]; then
        local now=$(date +%s); local diff=$((now - created)); [ "$diff" -lt 0 ] && diff=0
        local d=$((diff / 86400)); local h=$(( (diff % 86400) / 3600 )); local m=$(( (diff % 3600) / 60 ))
        local s_uptime=""
        [ "$d" -gt 0 ] && s_uptime="${d}d "; [ "$h" -gt 0 ] && s_uptime="${s_uptime}${h}h "; s_uptime="${s_uptime}${m}m"
        [ "$s_uptime" == "0m" ] && s_uptime="Just now"; echo "$s_uptime"
    else echo "---"; fi
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
        [ -n "$tun_id" ] && rip=$(ip l2tp show tunnel tunnel_id "$tun_id" 2>/dev/null | grep -oP 'peer \K[0-9\.]+'); fi
    echo "$rip"
}

# 🐍 PYTHON API SERVER (INTERACTIVE BACKEND) 🐍
cat << 'PY_EOF' > server.py
import http.server, socketserver, json, subprocess, os, sys, hashlib

PORT = int(sys.argv[1])
USER = sys.argv[2]
PASS = sys.argv[3]
SECRET_TOKEN = hashlib.sha256(f"{USER}:{PASS}:MDesignSecure".encode()).hexdigest()

class APIHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        super().end_headers()

    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)
        try:
            data = json.loads(post_data.decode('utf-8'))
        except:
            data = {}

        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()

        if self.path == '/api/login':
            if data.get('username') == USER and data.get('password') == PASS:
                self.wfile.write(json.dumps({"status": "success", "token": SECRET_TOKEN}).encode())
            else:
                self.wfile.write(json.dumps({"status": "error", "message": "Invalid Credentials"}).encode())
            return

        # Token Verification for sensitive actions
        if data.get('token') != SECRET_TOKEN:
            self.wfile.write(json.dumps({"status": "unauthorized"}).encode())
            return

        if self.path == '/api/action':
            action = data.get('action')
            target = data.get('target')
            
            if action == 'restart_tunnel':
                if os.path.exists(f"/etc/mbackhaul/tunnels/{target}.toml"):
                    os.system(f"systemctl restart mbackhaul@{target} 2>/dev/null")
                elif target.startswith('l2tp_'):
                    os.system("systemctl restart ml2tp.service 2>/dev/null")
                elif target.startswith('hys_'):
                    os.system(f"systemctl restart mhysteria@{target} 2>/dev/null")
                else:
                    subprocess.run(['ip', 'link', 'set', target, 'down'], capture_output=True)
                    subprocess.run(['sleep', '1'])
                    subprocess.run(['ip', 'link', 'set', target, 'up'], capture_output=True)
                os.system(f"date +%s > /etc/mstats/uptimes/{target} 2>/dev/null")
                self.wfile.write(json.dumps({"status": "success", "message": f"{target} Restarted"}).encode())
                
            elif action == 'add_port':
                port = data.get('port')
                dst_ip = data.get('dst_ip')
                engine = data.get('engine')
                if engine == 'haproxy':
                    cmd = f"echo '\\nfrontend ft_{port}\\n    bind *:{port}\\n    default_backend bk_{port}\\nbackend bk_{port}\\n    server srv_{port} {dst_ip}:{port} check inter 5000' >> /etc/haproxy/haproxy.cfg && systemctl restart haproxy"
                    os.system(cmd)
                elif engine == 'gost':
                    if os.path.exists('/usr/bin/jq'):
                        cmd = f"jq '.ServeNodes += [\"tcp://:{port}/{dst_ip}:{port}\"]' /etc/gost/config.json > /tmp/g.json && mv /tmp/g.json /etc/gost/config.json && systemctl restart gost"
                        os.system(cmd)
                self.wfile.write(json.dumps({"status": "success", "message": f"Port {port} Mapped to {dst_ip}"}).encode())
            else:
                self.wfile.write(json.dumps({"status": "error", "message": "Unknown Action"}).encode())
            return

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", PORT), APIHandler) as httpd:
    httpd.serve_forever()
PY_EOF

python3 server.py "$PORT" "$W_USER" "$W_PASS" >/dev/null 2>&1 &
PY_PID=$!
trap "kill $PY_PID; rm -rf /tmp/mweb_daemon; exit" SIGINT SIGTERM

# 🌐 HTML FRONTEND (INTERACTIVE GUI) 🌐
cat <<'EOF' > index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>MDesign Enterprise UI</title>
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
        }

        * { box-sizing: border-box; margin: 0; padding: 0; font-family: 'Inter', sans-serif; transition: 0.3s; }
        body { background-color: var(--bg-base); background-image: radial-gradient(circle at 50% 0%, var(--glow) 0%, transparent 40%); color: var(--text-main); overflow-x: hidden; }
        body[dir="rtl"] * { font-family: 'Vazirmatn', sans-serif; }

        /* Login Screen */
        #login-screen { position: fixed; inset: 0; background: var(--bg-base); z-index: 9999; display: flex; align-items: center; justify-content: center; backdrop-filter: blur(20px); }
        .login-box { background: var(--card-bg); border: 1px solid var(--border); padding: 40px; border-radius: 20px; box-shadow: 0 20px 40px var(--shadow); width: 100%; max-width: 400px; text-align: center; }
        .login-box h2 { margin-bottom: 25px; color: var(--sky); font-weight: 700; letter-spacing: 1px;}
        .input-group { margin-bottom: 15px; text-align: left; }
        body[dir="rtl"] .input-group { text-align: right; }
        .input-group input, .input-group select { width: 100%; padding: 12px 15px; background: rgba(0,0,0,0.2); border: 1px solid var(--border); border-radius: 10px; color: var(--text-main); font-size: 1rem; outline: none; }
        body.light-mode .input-group input, body.light-mode .input-group select { background: rgba(255,255,255,0.5); }
        .input-group input:focus { border-color: var(--sky); box-shadow: 0 0 10px rgba(56, 189, 248, 0.2); }
        .btn-primary { width: 100%; padding: 12px; background: var(--sky); color: #fff; border: none; border-radius: 10px; font-weight: 600; font-size: 1rem; cursor: pointer; margin-top: 10px; }
        .btn-primary:hover { background: #0284c7; box-shadow: 0 5px 15px rgba(56, 189, 248, 0.4); }

        /* Main App */
        #app-core { display: none; opacity: 0; }
        .wrapper { display: flex; min-height: 100vh; padding: 40px 15px; max-width: 1400px; margin: 0 auto; gap: 40px; }
        .container { flex-grow: 1; display: flex; flex-direction: column; gap: 40px; }

        /* Sidebar & Cards (Same as before) */
        .sidebar { position: fixed; left: 20px; top: 50%; transform: translateY(-50%); display: flex; flex-direction: column; gap: 28px; z-index: 1000; background: var(--card-bg); padding: 30px 18px; border-radius: 24px; border: 1px solid var(--border); backdrop-filter: blur(15px); }
        body[dir="rtl"] .sidebar { left: auto; right: 20px; }
        .side-btn { width: 52px; height: 52px; border-radius: 14px; display: flex; align-items: center; justify-content: center; cursor: pointer; border: 2px solid transparent; background: rgba(255,255,255,0.05); color: var(--text-main); }
        .side-btn.active { border-color: var(--sky); background: rgba(56, 189, 248, 0.15); box-shadow: 0 0 15px rgba(56, 189, 248, 0.4); }
        .side-btn svg { width: 26px; height: 26px; }

        .section-title { font-size: 1.1rem; font-weight: 700; color: var(--text-main); display: flex; align-items: center; gap: 10px; margin-bottom: 20px; }
        .status-dot { width: 8px; height: 8px; border-radius: 50%; box-shadow: 0 0 8px currentColor; flex-shrink: 0;}
        .dot-green { background: var(--green); color: var(--green); } .dot-red { background: var(--red); color: var(--red); }
        
        .grid-layout { display: grid; grid-template-columns: repeat(auto-fit, minmax(400px, 1fr)); gap: 20px; }
        .glass-card { background: var(--card-bg); border: 1px solid var(--border); backdrop-filter: blur(20px); border-radius: 12px; padding: 25px; box-shadow: 0 10px 30px var(--shadow);}
        .hw-border { border-top: 3px solid var(--sky); } .tun-border { border-top: 3px solid var(--purple); }

        .t-row { display: flex; justify-content: space-between; align-items: center; padding: 14px 16px; background: var(--row-bg); border: 1px solid var(--row-border); border-radius: 8px; margin-bottom: 10px; }
        .t-row.split { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; background: transparent; border: none; padding: 0; }
        .t-row.split > div { display: flex; justify-content: space-between; align-items: center; background: var(--row-bg); border: 1px solid var(--row-border); border-radius: 8px; padding: 14px 16px; }
        .t-lbl { font-size: 0.7rem; font-weight: 700; color: var(--text-muted); text-transform: uppercase; letter-spacing: 1px; }
        .t-val { font-family: 'JetBrains Mono', monospace; font-size: 0.9rem; font-weight: 600; direction: ltr;}

        .btn-action { display: inline-flex; align-items: center; justify-content: center; background: rgba(56, 189, 248, 0.1); border: 1px solid rgba(56, 189, 248, 0.3); color: var(--sky); padding: 8px 16px; border-radius: 6px; font-size: 0.75rem; font-weight: 600; cursor: pointer; margin-top: 15px; }
        .btn-action:hover { background: rgba(56, 189, 248, 0.2); }

        /* FAB Button */
        .fab { position: fixed; bottom: 30px; right: 30px; width: 60px; height: 60px; background: var(--sky); border-radius: 50%; display: flex; align-items: center; justify-content: center; color: #fff; font-size: 30px; cursor: pointer; box-shadow: 0 10px 25px rgba(56, 189, 248, 0.5); z-index: 1001; border: none; }
        body[dir="rtl"] .fab { right: auto; left: 30px; }
        .fab:hover { transform: scale(1.1) rotate(90deg); }

        /* Modals */
        .modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.6); backdrop-filter: blur(5px); z-index: 2000; display: none; align-items: center; justify-content: center; opacity: 0; }
        .modal-content { background: var(--card-bg); border: 1px solid var(--border); padding: 30px; border-radius: 16px; width: 100%; max-width: 450px; transform: scale(0.9); transition: 0.3s; }
        .modal-overlay.active { display: flex; opacity: 1; }
        .modal-overlay.active .modal-content { transform: scale(1); }
        .modal-close { float: right; cursor: pointer; color: var(--text-muted); font-size: 20px; }
        body[dir="rtl"] .modal-close { float: left; }

        /* Toast Notifications */
        #toast-container { position: fixed; top: 20px; right: 20px; z-index: 9999; display: flex; flex-direction: column; gap: 10px; }
        body[dir="rtl"] #toast-container { right: auto; left: 20px; }
        .toast { background: var(--card-bg); border-left: 4px solid var(--green); color: var(--text-main); padding: 15px 20px; border-radius: 8px; box-shadow: 0 5px 15px var(--shadow); transform: translateX(120%); animation: slideIn 0.3s forwards, fadeOut 0.5s 3s forwards; }
        @keyframes slideIn { to { transform: translateX(0); } }
        @keyframes fadeOut { to { opacity: 0; transform: translateY(-20px); } }

        @media (max-width: 950px) { 
            .wrapper { padding-left: 15px; padding-right: 15px; padding-bottom: 120px;}
            .sidebar { top: auto; bottom: 20px; left: 50%; transform: translateX(-50%); flex-direction: row; width: max-content; }
            body[dir="rtl"] .sidebar { right: 50%; transform: translateX(50%); }
            .grid-layout { grid-template-columns: 1fr; }
            .t-row.split { grid-template-columns: 1fr; gap: 10px; } 
            .fab { bottom: 100px; }
        }
        @media (min-width: 951px) { .wrapper { padding-left: 110px; } body[dir="rtl"] .wrapper { padding-left: 15px; padding-right: 110px; } }
    </style>
</head>
<body>

    <div id="toast-container"></div>

    <div id="login-screen">
        <div class="login-box">
            <h2>MDesign Master Node</h2>
            <div class="input-group">
                <input type="text" id="l_user" placeholder="Username" autocomplete="off">
            </div>
            <div class="input-group">
                <input type="password" id="l_pass" placeholder="Password">
            </div>
            <button class="btn-primary" onclick="doLogin()">Secure Login</button>
        </div>
    </div>

    <div class="modal-overlay" id="action-modal">
        <div class="modal-content">
            <span class="modal-close" onclick="closeModal()">✖</span>
            <h3 style="margin-bottom: 20px; color: var(--sky);" id="lbl-modal-title">Forward New Port</h3>
            <div class="input-group">
                <label class="t-lbl" style="display:block; margin-bottom:5px;" id="lbl-mod-port">Local Port</label>
                <input type="number" id="m_port" placeholder="e.g. 443">
            </div>
            <div class="input-group">
                <label class="t-lbl" style="display:block; margin-bottom:5px;" id="lbl-mod-ip">Target Core IP</label>
                <input type="text" id="m_ip" placeholder="e.g. 10.76.1.2" dir="ltr">
            </div>
            <div class="input-group">
                <label class="t-lbl" style="display:block; margin-bottom:5px;" id="lbl-mod-eng">Engine</label>
                <select id="m_engine">
                    <option value="haproxy">HAProxy (Standard)</option>
                    <option value="gost">Gost (Advanced)</option>
                </select>
            </div>
            <button class="btn-primary" onclick="submitAction()" id="lbl-mod-btn">Deploy Mapping</button>
        </div>
    </div>

    <div id="app-core">
        <div class="sidebar">
            <div class="side-btn" id="btn-theme" onclick="toggleTheme()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" /></svg></div>
            <div class="side-btn" id="btn-en" onclick="setLang('en')"><b style="font-size:18px;">EN</b></div>
            <div class="side-btn" id="btn-fa" onclick="setLang('fa')"><b style="font-size:18px; font-family:'Vazirmatn';">فا</b></div>
            <div class="side-btn" onclick="logout()" style="color:var(--red);"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1" /></svg></div>
        </div>

        <div class="wrapper">
            <div class="container">
                <div>
                    <div class="section-title"><div class="status-dot dot-green"></div> <span id="lbl-hw-title">FLEET HARDWARE RADAR</span></div>
                    <div class="grid-layout" id="hw-container"></div>
                </div>
                <div>
                    <div class="section-title"><div class="status-dot dot-green" id="sync-dot"></div> <span id="lbl-tun-title">ACTIVE TUNNEL MATRIX</span></div>
                    <div class="grid-layout" id="tun-container"></div>
                </div>
            </div>
        </div>

        <button class="fab" onclick="openModal()">+</button>
    </div>

    <script>
        let token = localStorage.getItem('md_token');
        let currentLang = localStorage.getItem('md_lang') || 'en';
        
        // I18N
        const txt = {
            en: { hw: "FLEET HARDWARE", tun: "ACTIVE TUNNELS", m_title: "Forward New Port", m_port: "Local Port", m_ip: "Target Core IP", m_btn: "Deploy Mapping", btn_res: "Restart Tunnel", loc: "Local Node", cpu: "LIVE CPU", ram: "MEMORY (RAM)", up: "UPTIME", l_dn: "LIVE DOWN", l_up: "LIVE UP", out: "Logged out." },
            fa: { hw: "رادار سخت‌افزار", tun: "ماتریس تونل‌ها", m_title: "فوروارد پورت جدید", m_port: "پورت مبدا", m_ip: "آی‌پی مقصد (سرور خارج)", m_btn: "اعمال تنظیمات", btn_res: "ری‌استارت تونل", loc: "سرور محلی", cpu: "پردازنده", ram: "حافظه موقت", up: "زمان روشنی", l_dn: "دانلود زنده", l_up: "آپلود زنده", out: "خارج شدید." }
        };

        function setLang(l) {
            currentLang = l; localStorage.setItem('md_lang', l);
            document.body.dir = l === 'fa' ? 'rtl' : 'ltr';
            document.getElementById('lbl-hw-title').innerText = txt[l].hw;
            document.getElementById('lbl-tun-title').innerText = txt[l].tun;
            document.getElementById('lbl-mod-title').innerText = txt[l].m_title;
            document.getElementById('lbl-mod-port').innerText = txt[l].m_port;
            document.getElementById('lbl-mod-ip').innerText = txt[l].m_ip;
            document.getElementById('lbl-mod-btn').innerText = txt[l].m_btn;
            fetchRoutine();
        }

        function showToast(msg, isErr=false) {
            let t = document.createElement('div');
            t.className = 'toast';
            if(isErr) t.style.borderLeftColor = 'var(--red)';
            t.innerText = msg;
            document.getElementById('toast-container').appendChild(t);
            setTimeout(() => t.remove(), 3500);
        }

        async function doLogin() {
            let u = document.getElementById('l_user').value;
            let p = document.getElementById('l_pass').value;
            try {
                let r = await fetch('/api/login', { method: 'POST', body: JSON.stringify({username: u, password: p}) });
                let res = await r.json();
                if(res.status === 'success') {
                    token = res.token; localStorage.setItem('md_token', token);
                    document.getElementById('login-screen').style.display = 'none';
                    document.getElementById('app-core').style.display = 'block';
                    setTimeout(()=>document.getElementById('app-core').style.opacity = '1', 50);
                    showToast("Access Granted. Welcome.");
                    fetchRoutine();
                } else { showToast(res.message, true); }
            } catch(e) { showToast("Connection Error", true); }
        }

        function logout() {
            localStorage.removeItem('md_token'); token = null;
            document.getElementById('app-core').style.opacity = '0';
            setTimeout(()=> { document.getElementById('app-core').style.display = 'none'; document.getElementById('login-screen').style.display = 'flex'; }, 300);
            showToast(txt[currentLang].out);
        }

        function openModal() { document.getElementById('action-modal').classList.add('active'); }
        function closeModal() { document.getElementById('action-modal').classList.remove('active'); }

        async function apiPost(action, payload) {
            payload.token = token; payload.action = action;
            try {
                let r = await fetch('/api/action', { method: 'POST', body: JSON.stringify(payload) });
                let res = await r.json();
                if(res.status === 'unauthorized') { logout(); return; }
                if(res.status === 'success') showToast(res.message);
                else showToast(res.message, true);
            } catch(e) { showToast("API Error", true); }
        }

        function submitAction() {
            let p = document.getElementById('m_port').value;
            let i = document.getElementById('m_ip').value;
            let e = document.getElementById('m_engine').value;
            if(!p || !i) { showToast("Fill all fields", true); return; }
            apiPost('add_port', {port: p, dst_ip: i, engine: e});
            closeModal();
            document.getElementById('m_port').value = '';
        }

        function restartTunnel(iface, btn) {
            btn.style.opacity = "0.5"; btn.style.pointerEvents = "none";
            apiPost('restart_tunnel', {target: iface}).then(() => {
                btn.style.opacity = "1"; btn.style.pointerEvents = "auto";
            });
        }

        function toggleTheme() { document.body.classList.toggle('light-mode'); }

        // Boot Init
        if(token) {
            document.getElementById('login-screen').style.display = 'none';
            document.getElementById('app-core').style.display = 'block';
            setTimeout(()=>document.getElementById('app-core').style.opacity = '1', 50);
            setLang(currentLang);
        }

        let isFetching = false;
        async function fetchRoutine() {
            if(!token || isFetching) return;
            isFetching = true;
            try {
                let r = await fetch('/api_data.json?t=' + Date.now());
                if(r.ok) {
                    let d = await r.json();
                    document.getElementById('sync-dot').className = 'status-dot dot-green';
                    
                    document.getElementById('hw-container').innerHTML = `
                    <div class="glass-card hw-border">
                        <div style="display:flex; justify-content:space-between; margin-bottom:15px;"><b>${txt[currentLang].loc}</b> <span style="color:var(--sky)">${d.local.ip}</span></div>
                        <div class="t-row"><span class="t-lbl">${txt[currentLang].cpu}</span><span class="t-val text-sky">${d.local.cpu}</span></div>
                        <div class="t-row"><span class="t-lbl">${txt[currentLang].ram}</span><span class="t-val text-pink">${d.local.ram}</span></div>
                        <div class="t-row"><span class="t-lbl">${txt[currentLang].up}</span><span class="t-val text-green">${d.local.uptime}</span></div>
                    </div>`;

                    let tHtml = "";
                    for(let t of d.tunnels) {
                        tHtml += `
                        <div class="glass-card tun-border">
                            <div style="display:flex; justify-content:space-between; margin-bottom:15px; border-bottom:1px solid var(--border); padding-bottom:10px;">
                                <b><div class="status-dot ${t.state === 'ONLINE' ? 'dot-green' : 'dot-red'}" style="display:inline-block"></div> ${t.iface}</b>
                                <span style="font-size:0.7rem; background:rgba(255,255,255,0.1); padding:3px 8px; border-radius:4px;">${t.type}</span>
                            </div>
                            <div class="t-row split">
                                <div><span class="t-lbl">${txt[currentLang].l_dn}</span><span class="t-val text-sky">${t.rx_spd}</span></div>
                                <div><span class="t-lbl">${txt[currentLang].l_up}</span><span class="t-val text-pink">${t.tx_spd}</span></div>
                            </div>
                            <button onclick="restartTunnel('${t.iface}', this)" class="btn-action">${txt[currentLang].btn_res}</button>
                        </div>`;
                    }
                    document.getElementById('tun-container').innerHTML = tHtml;
                }
            } catch(e) { document.getElementById('sync-dot').className = 'status-dot dot-red'; }
            isFetching = false;
        }
        setInterval(fetchRoutine, 2000);
    </script>
</body>
</html>
EOF

# --- BASH RADAR ENGINE (Runs in Background) ---
declare -A rx_old tx_old
prev_total=""; prev_idle=""

while true; do
    read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    curr_idle=$((idle + iowait)); curr_total=$((user + nice + system + irq + softirq + steal + curr_idle))
    cpu_load="0.0"
    if [ -n "$prev_total" ] && [ "$curr_total" -ne "$prev_total" ]; then
        total_diff=$((curr_total - prev_total)); idle_diff=$((curr_idle - prev_idle))
        [ "$total_diff" -gt 0 ] && cpu_load=$(awk "BEGIN {printf \"%.1f\", 100 * ($total_diff - $idle_diff) / $total_diff}")
    fi
    prev_total=$curr_total; prev_idle=$curr_idle
    ram_usage=$(free -m | awk '/Mem:/ {printf "%.1f", $3/$2 * 100}')
    sys_uptime=$(uptime -p | sed 's/up //')

    TUNNELS_JSON="["
    first_tun=true
    
    # 1. Gather L3 Tunnels
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf /etc/ml2tp/tunnels/*.conf /etc/mhysteria/tunnels/*.conf; do
        [ -f "$conf" ] || continue
        source "$conf"
        name="$T_NAME"; [ -n "$BR_NAME" ] && name="$BR_NAME"
        
        r_new=$(get_iface_rx "$name"); t_new=$(get_iface_tx "$name")
        r_old=${rx_old[$name]:-$r_new}; t_old=${tx_old[$name]:-$t_new}
        rx_s=$((r_new - r_old)); [ "$rx_s" -lt 0 ] && rx_s=0
        tx_s=$((t_new - t_old)); [ "$tx_s" -lt 0 ] && tx_s=0
        rx_old[$name]=$r_new; tx_old[$name]=$t_new

        st_badge="OFFLINE"
        ip link show "$name" 2>/dev/null | grep -q "UP" && st_badge="ONLINE"
        
        type_txt="GRE"
        [ -n "$BR_NAME" ] && type_txt="VXLAN"
        [[ "$conf" == *"/ml2tp/"* ]] && type_txt="L2TPv3"
        [[ "$conf" == *"/mhysteria/"* ]] && type_txt="Hys2"

        if [ "$first_tun" = true ]; then first_tun=false; else TUNNELS_JSON+=","; fi
        TUNNELS_JSON+="{\"iface\":\"$name\", \"type\":\"$type_txt\", \"state\":\"$st_badge\", \"rx_spd\":\"$(format_speed $rx_s)\", \"tx_spd\":\"$(format_speed $tx_s)\"}"
    done

    # 2. Gather MBackhaul Nodes
    for conf in /etc/mbackhaul/tunnels/*.toml; do
        [ -f "$conf" ] || continue
        bh_name=$(basename "$conf" .toml)
        bh_type="Backhaul (SRV)"; grep -q "\[client\]" "$conf" && bh_type="Backhaul (CLI)"
        bh_state="OFFLINE"
        systemctl is-active --quiet "mbackhaul@$bh_name" 2>/dev/null && bh_state="ONLINE"
        
        r_new_b=$(get_iface_rx "$bh_name"); t_new_b=$(get_iface_tx "$bh_name")
        r_old_b=${rx_old["BH_$bh_name"]:-$r_new_b}; t_old_b=${tx_old["BH_$bh_name"]:-$t_new_b}
        rx_s_b=$((r_new_b - r_old_b)); [ "$rx_s_b" -lt 0 ] && rx_s_b=0
        tx_s_b=$((t_new_b - t_old_b)); [ "$tx_s_b" -lt 0 ] && tx_s_b=0
        rx_old["BH_$bh_name"]=$r_new_b; tx_old["BH_$bh_name"]=$t_new_b

        if [ "$first_tun" = true ]; then first_tun=false; else TUNNELS_JSON+=","; fi
        TUNNELS_JSON+="{\"iface\":\"$bh_name\", \"type\":\"$bh_type\", \"state\":\"$bh_state\", \"rx_spd\":\"$(format_speed $rx_s_b)\", \"tx_spd\":\"$(format_speed $tx_s_b)\"}"
    done
    TUNNELS_JSON+="]"

    cat <<EOF > api_data.json
{
    "local": {"ip": "${MY_PUB_IP}", "cpu": "${cpu_load}%", "ram": "${ram_usage}%", "uptime": "${sys_uptime}"},
    "tunnels": ${TUNNELS_JSON}
}
EOF
    sleep 1.2
done
