#!/bin/bash
# --- MBackhaul Modular Core (mbackhaul.sh) | MDesign Ecosystem v1.7.2 ---
# [Fixes: Native App-Level RTT Log Parsing | IPv4-Mapped Socket Extraction]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mbackhaul/tunnels"
CERT_DIR="/etc/mbackhaul/certs"
LOCAL_DIR="/root/mtunnel"

mkdir -p "$CONF_DIR" "$CERT_DIR" "$LOCAL_DIR/packages" 2>/dev/null

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

format_total() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -lt 1099511627776 ]; then awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    else awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"; fi
}

apply_bbr_optimization() {
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
}

generate_ssl_cert() {
    if [[ ! -f "$CERT_DIR/wssmux.crt" ]] || [[ ! -f "$CERT_DIR/wssmux.key" ]]; then
        openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/wssmux.key" \
            -out "$CERT_DIR/wssmux.crt" -days 3650 -nodes \
            -subj "/CN=mdesign-backhaul" >/dev/null 2>&1
    fi
}

menu_install_core() {
    echo -e "\n  ${DIM}┌─[ INSTALL / UPDATE BACKHAUL CORE ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/bh)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r')

    [[ "$src_choice" == "q" ]] && return

    echo -e "  ${R}● Purging old Backhaul binaries and processes...${NC}"
    systemctl stop mbackhaul@* 2>/dev/null
    killall -9 bh 2>/dev/null
    rm -f /usr/local/bin/bh /usr/bin/bh /tmp/bh_dl /tmp/backhaul

    if [[ "$src_choice" == "1" ]]; then
        echo -e "  ${DIM}● Downloading latest from GitHub...${NC}"
        local arch=$(uname -m)
        local target="backhaul_linux_amd64.tar.gz"
        [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="backhaul_linux_arm64.tar.gz"
        wget -qO /tmp/bh_dl "https://github.com/Musixal/Backhaul/releases/latest/download/${target}"
        if [ -s /tmp/bh_dl ]; then
            tar -xzf /tmp/bh_dl -C /tmp/ >/dev/null 2>&1
            mv /tmp/backhaul /usr/local/bin/bh 2>/dev/null
            chmod +x /usr/local/bin/bh
            echo -e "  ${G}✔ Backhaul Core installed successfully.${NC}"
        else
            echo -e "  ${R}✖ Download failed!${NC}"
        fi

    elif [[ "$src_choice" == "2" ]]; then
        echo -ne "  ${C}● Enter Direct Link: ${NC}"; read custom_url
        custom_url=$(echo "$custom_url" | tr -d '\r')
        if [ -n "$custom_url" ]; then
            echo -e "  ${DIM}● Downloading from Custom Link...${NC}"
            wget -qO /tmp/bh_dl "$custom_url"
            if [ -s /tmp/bh_dl ]; then
                if gzip -t /tmp/bh_dl 2>/dev/null; then
                    tar -xzf /tmp/bh_dl -C /tmp/ >/dev/null 2>&1
                    mv /tmp/backhaul /usr/local/bin/bh 2>/dev/null || mv /tmp/bh /usr/local/bin/bh 2>/dev/null
                else
                    mv /tmp/bh_dl /usr/local/bin/bh
                fi
                chmod +x /usr/local/bin/bh
                echo -e "  ${G}✔ Backhaul Core installed from custom link.${NC}"
            else
                echo -e "  ${R}✖ Download failed! Check the link.${NC}"
            fi
        fi

    elif [[ "$src_choice" == "3" ]]; then
        if [ -s "$LOCAL_DIR/packages/bh" ]; then
            cp "$LOCAL_DIR/packages/bh" /usr/local/bin/bh
            chmod +x /usr/local/bin/bh
            echo -e "  ${G}✔ Backhaul Core restored from Local Directory.${NC}"
        else
            echo -e "  ${R}✖ File not found in $LOCAL_DIR/packages/bh!${NC}"
        fi
    fi

    [ -f "/usr/local/bin/bh" ] && ln -sf /usr/local/bin/bh /usr/bin/bh 2>/dev/null
    systemctl start mbackhaul@* 2>/dev/null
    sleep 2
}

install_backhaul_silent() {
    if ! command -v bh >/dev/null 2>&1 && [ ! -f "/usr/local/bin/bh" ]; then
        local arch=$(uname -m)
        local target="backhaul_linux_amd64.tar.gz"
        [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="backhaul_linux_arm64.tar.gz"
        wget -qO /tmp/bh.tar.gz "https://github.com/Musixal/Backhaul/releases/latest/download/${target}" >/dev/null 2>&1
        if [ -s /tmp/bh.tar.gz ]; then
            tar -xzf /tmp/bh.tar.gz -C /tmp/ >/dev/null 2>&1
            mv /tmp/backhaul /usr/local/bin/bh
            chmod +x /usr/local/bin/bh
        fi
    fi
    [ -f "/usr/local/bin/bh" ] && ln -sf /usr/local/bin/bh /usr/bin/bh 2>/dev/null
}

setup_bh_counters() {
    local name="$1"; local l_port="$2"; local r_ip="$3"; local role="$4"
    if [ "$role" == "1" ]; then
        iptables -t mangle -C INPUT -p tcp --dport "$l_port" -m comment --comment "MBH_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -p tcp --dport "$l_port" -m comment --comment "MBH_RX_${name}" 2>/dev/null
        iptables -t mangle -C OUTPUT -p tcp --sport "$l_port" -m comment --comment "MBH_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -p tcp --sport "$l_port" -m comment --comment "MBH_TX_${name}" 2>/dev/null
    else
        if [ -n "$r_ip" ] && [ "$r_ip" != "0.0.0.0" ]; then
            iptables -t mangle -C INPUT -s "$r_ip" -p tcp --sport "$l_port" -m comment --comment "MBH_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -s "$r_ip" -p tcp --sport "$l_port" -m comment --comment "MBH_RX_${name}" 2>/dev/null
            iptables -t mangle -C OUTPUT -d "$r_ip" -p tcp --dport "$l_port" -m comment --comment "MBH_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -d "$r_ip" -p tcp --dport "$l_port" -m comment --comment "MBH_TX_${name}" 2>/dev/null
        fi
    fi
}

clean_bh_counters() {
    local name="$1"
    iptables -t mangle -S INPUT 2>/dev/null | grep "MBH_RX_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t mangle $r 2>/dev/null; done
    iptables -t mangle -S OUTPUT 2>/dev/null | grep "MBH_TX_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t mangle $r 2>/dev/null; done
}

get_bh_rx() {
    local rx=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep "MBH_RX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${rx:-0}"
}

get_bh_tx() {
    local tx=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null | grep "MBH_TX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${tx:-0}"
}

check_bh_connection() {
    local t_name="$1"
    local meta="$CONF_DIR/${t_name}.meta"
    [ ! -f "$meta" ] && { echo "OFFLINE"; return; }
    
    ROLE=""; TUN_PORT=""; REMOTE_IP=""; source "$meta" 2>/dev/null
    if ! systemctl is-active --quiet "mbackhaul@${t_name}" 2>/dev/null; then echo "OFFLINE"; return; fi

    if [ "$ROLE" == "1" ]; then
        if ss -nt state established 2>/dev/null | grep -qE ":$TUN_PORT\b"; then echo "ONLINE"; else echo "WAITING"; fi
    else
        if ss -nt state established 2>/dev/null | grep -qE ":$TUN_PORT\b"; then echo "ONLINE"; else echo "CONNECTING"; fi
    fi
}

get_tunnel_rtt() {
    local t_name="$1"
    local target_ip="$2"
    
    # 1. Native App-Level RTT Parsing
    local app_rtt=$(journalctl -u "mbackhaul@${t_name}" -n 200 --no-pager 2>/dev/null | sed -n 's/.*Round Trip Time (RTT): \([0-9]\+\) ms.*/\1/p' | tail -n 1)
    if [ -n "$app_rtt" ]; then
        echo "$app_rtt"
        return
    fi
    
    # 2. ICMP Fallback
    if [ -n "$target_ip" ] && [ "$target_ip" != "0.0.0.0" ]; then
        local ping_val=$(ping -c 1 -W 1 "$target_ip" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}' | cut -d. -f1)
        if [ -n "$ping_val" ]; then
            echo "$ping_val"
            return
        fi
    fi
    echo "N/A"
}

write_bh_config() {
    local name="$(echo "$1" | tr -d '\r\n')"
    local role="$(echo "$2" | tr -d '\r\n')"
    local transport="$(echo "$3" | tr -d '\r\n')"
    local port="$(echo "$4" | tr -d '\r\n')"
    local r_ip="$(echo "$5" | tr -d '\r\n')"
    local token="$(echo "$6" | tr -d '\r\n' | sed 's/"/\\"/g')"
    local ports_str="$(echo "$7" | tr -d '\r\n')"

    local toml="$CONF_DIR/${name}.toml"
    local meta="$CONF_DIR/${name}.meta"

    echo "ROLE=$role" > "$meta"
    echo "TRANSPORT=$transport" >> "$meta"
    echo "TUN_PORT=$port" >> "$meta"
    echo "REMOTE_IP=$r_ip" >> "$meta"
    echo "TOKEN=$token" >> "$meta"
    echo "PORTS=$ports_str" >> "$meta"

    [ -z "$role" ] && role="1"
    [ -z "$transport" ] && transport="tcp"
    [ -z "$port" ] && port="8443"
    [ -z "$token" ] && token="mdesign_token"

    > "$toml"

    if [ "$role" == "1" ]; then
        echo "[server]" >> "$toml"
        echo "bind_addr = \"0.0.0.0:${port}\"" >> "$toml"
        echo "transport = \"${transport}\"" >> "$toml"
        [ "$transport" == "tcp" ] && echo "accept_udp = false" >> "$toml"
        echo "token = \"${token}\"" >> "$toml"
        echo "keepalive_period = 75" >> "$toml"
        echo "nodelay = true" >> "$toml"
        echo "heartbeat = 40" >> "$toml"
        echo "channel_size = 4096" >> "$toml"
        
        if [ "$transport" != "tcp" ]; then
            echo "mux_con = 8" >> "$toml"
            echo "mux_version = 1" >> "$toml"
            echo "mux_framesize = 32768" >> "$toml"
            echo "mux_recievebuffer = 4194304" >> "$toml"
            echo "mux_streambuffer = 65536" >> "$toml"
        fi
        
        if [ "$transport" == "tcp" ] || [ "$transport" == "tcpmux" ]; then
            echo "mss = 1360" >> "$toml"
            echo "so_rcvbuf = 4194304" >> "$toml"
            echo "so_sndbuf = 4194304" >> "$toml"
        fi
        
        if [ "$transport" == "wssmux" ]; then
            generate_ssl_cert
            echo "tls_cert = \"${CERT_DIR}/wssmux.crt\"" >> "$toml"
            echo "tls_key = \"${CERT_DIR}/wssmux.key\"" >> "$toml"
        fi
        
        echo "sniffer = false" >> "$toml"
        echo "web_port = 0" >> "$toml"
        echo "log_level = \"info\"" >> "$toml"
        
        local port_lines=""
        if [ -n "$ports_str" ]; then
            IFS=',' read -ra P_ARR <<< "$ports_str"
            for p_raw in "${P_ARR[@]}"; do
                local p_clean=$(echo "$p_raw" | tr -d ' ' | tr -d '\r' | tr -d '\n')
                if [ -n "$p_clean" ]; then
                    if [[ "$p_clean" =~ ^[0-9]+$ ]]; then p_clean="${p_clean}=127.0.0.1:${p_clean}"; fi
                    if [ -z "$port_lines" ]; then
                        port_lines="\"${p_clean}\""
                    else
                        port_lines="${port_lines}, \"${p_clean}\""
                    fi
                fi
            done
        fi
        [ -z "$port_lines" ] && port_lines="\"65535=127.0.0.1:65535\""
        
        echo "ports = [ ${port_lines} ]" >> "$toml"

    else
        echo "[client]" >> "$toml"
        echo "remote_addr = \"${r_ip}:${port}\"" >> "$toml"
        if [ "$transport" == "wsmux" ] || [ "$transport" == "wssmux" ]; then
            echo "edge_ip = \"\"" >> "$toml"
        fi
        echo "transport = \"${transport}\"" >> "$toml"
        echo "token = \"${token}\"" >> "$toml"
        echo "connection_pool = 8" >> "$toml"
        echo "aggressive_pool = false" >> "$toml"
        echo "keepalive_period = 75" >> "$toml"
        echo "nodelay = true" >> "$toml"
        echo "retry_interval = 3" >> "$toml"
        echo "dial_timeout = 10" >> "$toml"
        
        if [ "$transport" != "tcp" ]; then
            echo "mux_version = 1" >> "$toml"
            echo "mux_framesize = 32768" >> "$toml"
            echo "mux_recievebuffer = 4194304" >> "$toml"
            echo "mux_streambuffer = 65536" >> "$toml"
        fi
        
        if [ "$transport" == "tcp" ] || [ "$transport" == "tcpmux" ]; then
            echo "mss = 1360" >> "$toml"
            echo "so_rcvbuf = 4194304" >> "$toml"
            echo "so_sndbuf = 4194304" >> "$toml"
        fi
        
        echo "sniffer = false" >> "$toml"
        echo "web_port = 0" >> "$toml"
        echo "log_level = \"info\"" >> "$toml"
    fi

    setup_bh_counters "$name" "$port" "$r_ip" "$role"
}

setup_systemd_service() {
    cat <<'EOF' > /etc/systemd/system/mbackhaul@.service
[Unit]
Description=MBackhaul Multi-Multiplexer (%i)
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/bh -c /etc/mbackhaul/tunnels/%i.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

draw_header() {
    local s_ip=$(get_local_ip); local total_t=0; local active_t=0; local online_t=0
    local active_tname=""
    
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            ((total_t++))
            local t_name=$(basename "$conf" .meta)
            if systemctl is-active --quiet "mbackhaul@${t_name}" 2>/dev/null; then
                ((active_t++))
                local st=$(check_bh_connection "$t_name")
                if [ "$st" == "ONLINE" ]; then 
                    ((online_t++))
                    [ -z "$active_tname" ] && active_tname="$t_name"
                fi
            fi
        fi
    done

    local core_color="${R}"; local core_raw="Not Installed"
    if command -v bh >/dev/null 2>&1 || [ -f "/usr/local/bin/bh" ]; then
        core_color="${G}"; core_raw="Installed"
    fi
    
    local act_color="${DIM}"; local act_text="0/0"
    if [ "$total_t" -gt 0 ]; then
        act_text="${active_t}/${total_t}"
        if [ "$active_t" -eq "$total_t" ]; then act_color="${G}"
        elif [ "$active_t" -gt 0 ]; then act_color="${Y}"
        else act_color="${R}"; fi
    fi

    local stat_color="${R}"; local stat_icon="○"; local stat_text="STOPPED  "
    local stat_raw="STOPPED"
    if [ "$active_t" -gt 0 ]; then
        if [ "$online_t" -eq "$active_t" ]; then 
            stat_color="${G}"; stat_icon="●"; stat_text="CONNECTED"; stat_raw="CONNECTED"
        elif [ "$online_t" -gt 0 ]; then 
            stat_color="${Y}"; stat_icon="◐"; stat_text="PARTIAL  "; stat_raw="PARTIAL"
        else 
            stat_color="${Y}"; stat_icon="◎"; stat_text="WAITING  "; stat_raw="WAITING"
        fi
    fi

    local peer_ip=""
    if [ -n "$active_tname" ]; then
        local tmp_role=$(grep "^ROLE=" "$CONF_DIR/${active_tname}.meta" | cut -d'=' -f2)
        local tmp_remote=$(grep "^REMOTE_IP=" "$CONF_DIR/${active_tname}.meta" | cut -d'=' -f2)
        local tmp_port=$(grep "^TUN_PORT=" "$CONF_DIR/${active_tname}.meta" | cut -d'=' -f2)
        
        if [ -n "$tmp_remote" ] && [ "$tmp_remote" != "0.0.0.0" ]; then
            peer_ip="$tmp_remote"
        elif [ "$tmp_role" == "1" ]; then
            local conn=$(ss -nt state established 2>/dev/null | awk -v p=":$tmp_port" '$4 ~ p"$" {print $5}' | head -n 1)
            if [ -n "$conn" ]; then
                peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]' | sed 's/::ffff://')
            fi
        fi
    fi

    local g_color="${DIM}"; local g_text="Waiting"
    if [ -n "$active_tname" ]; then
        local rtt_val=$(get_tunnel_rtt "$active_tname" "$peer_ip")
        if [ "$rtt_val" != "N/A" ] && [[ "$rtt_val" =~ ^[0-9]+$ ]]; then
            if [ "$rtt_val" -lt 90 ]; then g_color="${G}"
            elif [ "$rtt_val" -lt 160 ]; then g_color="${Y}"
            else g_color="${R}"; fi
            g_text="${rtt_val} ms"
        elif [ -n "$peer_ip" ]; then
            g_color="${R}"; g_text="Timeout"
        fi
    fi

    local title=" MBackhaul Engine v1.7.2 "
    local ip_lbl=" IP: "
    local core_lbl=" Core: "
    local ping_lbl=" Peer Ping: "
    local act_lbl=" ACTIVE: "
    local stat_lbl=" STATUS: "
    
    local raw_len=$(( ${#title} + 1 + ${#ip_lbl} + ${#s_ip} + 1 + 1 + ${#core_lbl} + ${#core_raw} + 1 + 1 + ${#ping_lbl} + ${#g_text} + 1 + 1 + ${#act_lbl} + ${#act_text} + 1 + 1 + ${#stat_lbl} + 2 + ${#stat_raw} ))
    local pad_len=$(( 126 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${title}${NC}${B}│${NC}${DIM}${ip_lbl}${NC}${W}${s_ip} ${NC}${B}│${NC}${DIM}${core_lbl}${NC}${core_color}${core_raw} ${NC}${B}│${NC}${DIM}${ping_lbl}${NC}${g_color}${g_text} ${NC}${B}│${NC}${DIM}${act_lbl}${NC}${act_color}${act_text} ${NC}${B}│${NC}${DIM}${stat_lbl}${NC}${stat_color}${stat_icon} ${stat_text}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_tunnel_registry() {
    draw_header
    echo -e "\n  ${Y}● Deployed Backhaul Tunnels Registry:${NC}"
    local count=0
    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""
        source "$conf" 2>/dev/null
        
        local role_text=$([ "$ROLE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local peer_text=$([ "$ROLE" == "1" ] && echo "Listening on :${TUN_PORT}" || echo "${REMOTE_IP}:${TUN_PORT}")
        
        local peer_ip="$REMOTE_IP"
        if [ "$ROLE" == "1" ]; then
            local conn=$(ss -nt state established 2>/dev/null | awk -v p=":$TUN_PORT" '$4 ~ p"$" {print $5}' | head -n 1)
            if [ -n "$conn" ]; then
                peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]' | sed 's/::ffff://')
            else
                peer_ip=""
            fi
        fi

        local ping_val="Waiting"
        local rtt_raw=$(get_tunnel_rtt "$t_name" "$peer_ip")
        if [ "$rtt_raw" != "N/A" ] && [[ "$rtt_raw" =~ ^[0-9]+$ ]]; then
            ping_val="${rtt_raw} ms"
        elif [ -n "$peer_ip" ] && [ "$peer_ip" != "0.0.0.0" ]; then
            ping_val="Timeout"
        fi

        local st=$(check_bh_connection "$t_name")
        local stat_icon="○"; local stat_text="OFFLINE"; local stat_color="${R}"
        if [ "$st" == "ONLINE" ]; then stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}";
        elif [ "$st" == "WAITING" ]; then stat_icon="◎"; stat_text="WAITING CLIENT"; stat_color="${Y}";
        elif [ "$st" == "CONNECTING" ]; then stat_icon="◎"; stat_text="CONNECTING..."; stat_color="${Y}"; fi

        local rx=$(get_bh_rx "$t_name"); local tx=$(get_bh_tx "$t_name")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $t_name"; local right_p="Role: $role_text"
        local pad=$(( 122 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="Link Port    : ${TUN_PORT}"; local r1="Latency: ${ping_val}"
        local pad1=$(( 122 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Link Port    :${NC} ${W}${TUN_PORT}${NC}${sp1}${DIM}Latency:${NC} ${Y}${ping_val}${NC} ${B}│${NC}"
        
        local l2="Peer Target  : ${peer_text}"; local r2="Link State: ${stat_text}"
        local pad2=$(( 122 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}Peer Target  :${NC} ${W}${peer_text}${NC}${sp2}${DIM}Link State:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${B}│${NC}"

        local l3="Auth Token   : ${TOKEN}"; local r3="Protocol: ${TRANSPORT^^}"
        local pad3=$(( 122 - ${#l3} - ${#r3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${Y}Auth Token   :${NC} ${W}${TOKEN}${NC}${sp3}${DIM}Protocol:${NC} ${C}${TRANSPORT^^}${NC} ${B}│${NC}"

        local l4="Traffic Usage: RX $(format_total $rx) / TX $(format_total $tx)"
        local pad4=$(( 122 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Traffic Usage:${NC} ${G}RX $(format_total $rx)${NC} ${DIM}/${NC} ${Y}TX $(format_total $tx)${NC}${sp4} ${B}│${NC}"
        
        if [ "$ROLE" == "1" ]; then
            local p_str="${PORTS:0:100}"
            [ ${#PORTS} -gt 100 ] && p_str="${p_str}..."
            local l5="Port Mappings: ${p_str}"
            local pad5=$(( 122 - ${#l5} )); [ "$pad5" -lt 0 ] && pad5=0; local sp5=$(printf '%*s' "$pad5" "")
            echo -e "  ${B}│${NC} ${DIM}Port Mappings:${NC} ${Y}${p_str}${NC}${sp5} ${B}│${NC}"
        fi
        
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯\n"
        ((count++))
    done
    if [ "$count" -eq 0 ]; then echo -e "  ${R}● No tunnels configured yet!${NC}\n"; fi
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

show_live_radar() {
    tput civis; clear
    declare -A rx_old tx_old

    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        source "$conf" 2>/dev/null
        setup_bh_counters "$t_name" "$TUN_PORT" "$REMOTE_IP" "$ROLE"
        rx_old[$t_name]=$(get_bh_rx "$t_name")
        tx_old[$t_name]=$(get_bh_tx "$t_name")
    done

    while true; do
        printf "\033[H"; draw_header
        echo -e "\n  ${DIM}┌─[ BACKHAUL TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────────┬────────────────┬──────────────────┬──────────────────┬────────────────────┬────────────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} ${W}%-14s${NC} ${B}│${NC} ${C}%-16s${NC} ${B}│${NC} ${M}%-16s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL RX" "∑ TOTAL TX"
        echo -e "  ${B}├──────────────────────┼────────────────┼──────────────────┼──────────────────┼────────────────────┼────────────────────┤${NC}"

        local count=0
        for conf in "$CONF_DIR"/*.meta; do
            [ ! -f "$conf" ] && continue
            local t_name=$(basename "$conf" .meta)
            local st=$(check_bh_connection "$t_name")
            local st_color="${R}"; local st_text="OFFLINE  "
            if [ "$st" == "ONLINE" ]; then st_color="${G}"; st_text="ONLINE   ";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING  ";
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING"; fi

            local r_new=$(get_bh_rx "$t_name"); local t_new=$(get_bh_tx "$t_name")
            local r_prev=${rx_old[$t_name]:-$r_new}; local t_prev=${tx_old[$t_name]:-$t_new}
            local rx_s=$((r_new - r_prev)); local tx_s=$((t_new - t_prev))
            [ "$rx_s" -lt 0 ] && rx_s=0; [ "$tx_s" -lt 0 ] && tx_s=0
            rx_old[$t_name]=$r_new; tx_old[$t_name]=$t_new

            local c_rx="${DIM}"; [ "$rx_s" -gt 0 ] && c_rx="${G}"
            local c_tx="${DIM}"; [ "$tx_s" -gt 0 ] && c_tx="${Y}"

            printf "  ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} %b%-14s%b ${B}│${NC} %b%-16s%b ${B}│${NC} %b%-16s%b ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC}\n" "$t_name" "$st_color" "$st_text" "$NC" "$c_rx" "$(format_speed $rx_s)" "$NC" "$c_tx" "$(format_speed $tx_s)" "$NC" "$(format_total $r_new)" "$(format_total $t_new)"
            ((count++))
        done

        if [ "$count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-120s${NC} ${B}│${NC}\n" "  No active Backhaul tunnels configured."
        fi
        echo -e "  ${B}╰──────────────────────┴────────────────┴──────────────────┴──────────────────┴────────────────────┴────────────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\e' ]]; then break; fi
    done
    tput cnorm
}

manage_cron() {
    local t_name="$1"
    local cron_script="$CONF_DIR/${t_name}_restart.sh"
    
    echo -e "\n  ${DIM}┌─[ ANTI-FREEZE CRONJOB MANAGER ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add/Update Auto-Restart Cronjob${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Remove Auto-Restart Cronjob${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read cr_opt

    if [[ "$cr_opt" == "1" ]]; then
        echo -ne "  ${C}●${NC} ${W}Restart interval in hours (e.g. 2, 4, 6): ${NC}"; read interval
        interval=$(echo "$interval" | tr -d '\r')
        [[ ! "$interval" =~ ^[0-9]+$ ]] && echo -e "  ${R}Invalid interval!${NC}" && sleep 1.5 && return
        
        echo "#!/bin/bash" > "$cron_script"
        echo "systemctl kill -s SIGKILL mbackhaul@${t_name}" >> "$cron_script"
        echo "systemctl restart mbackhaul@${t_name}" >> "$cron_script"
        chmod +x "$cron_script"
        
        crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > /tmp/crontab.tmp
        echo "0 */${interval} * * * $cron_script #mbackhaul@${t_name}" >> /tmp/crontab.tmp
        crontab /tmp/crontab.tmp; rm -f /tmp/crontab.tmp
        echo -e "  ${G}✔ Cronjob added: Tunnel will restart every ${interval} hours.${NC}"; sleep 2
    elif [[ "$cr_opt" == "2" ]]; then
        crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > /tmp/crontab.tmp
        crontab /tmp/crontab.tmp; rm -f /tmp/crontab.tmp
        rm -f "$cron_script"
        echo -e "  ${G}✔ Cronjob removed.${NC}"; sleep 1.5
    fi
}

select_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; fi
    
    echo -e "\n  ${B}╭────────────────── Select Tunnel to Manage ─────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r')
    if [[ "$t_idx" == "q" || -z "$t_idx" || -z "${configs[$t_idx]}" ]]; then return 1; fi
    
    SELECTED_TUN="${configs[$t_idx]}"
    return 0
}

install_backhaul_silent() {
    if ! command -v bh >/dev/null 2>&1 && [ ! -f "/usr/local/bin/bh" ]; then
        local arch=$(uname -m)
        local target="backhaul_linux_amd64.tar.gz"
        [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="backhaul_linux_arm64.tar.gz"
        wget -qO /tmp/bh.tar.gz "https://github.com/Musixal/Backhaul/releases/latest/download/${target}" >/dev/null 2>&1
        if [ -s /tmp/bh.tar.gz ]; then
            tar -xzf /tmp/bh.tar.gz -C /tmp/ >/dev/null 2>&1
            mv /tmp/backhaul /usr/local/bin/bh
            chmod +x /usr/local/bin/bh
        fi
    fi
    [ -f "/usr/local/bin/bh" ] && ln -sf /usr/local/bin/bh /usr/bin/bh 2>/dev/null
}

install_backhaul_silent
setup_systemd_service
apply_bbr_optimization

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC}  ${DIM}❯${NC} ${G}Deploy New Backhaul Tunnel${NC} ${DIM}(TCP / MUX / WSS)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC}  ${DIM}❯${NC} ${C}Live Traffic & Bandwidth Radar${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC}  ${DIM}❯${NC} ${W}View Tunnels Registry & Settings${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC}  ${DIM}❯${NC} ${C}Edit Remote IP Address${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC}  ${DIM}❯${NC} ${G}Edit Port Mappings (Iran Server)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC}  ${DIM}❯${NC} ${M}Change Transport Protocol (Hot-Swap)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC}  ${DIM}❯${NC} ${Y}Anti-Freeze Cronjob Manager${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC}  ${DIM}❯${NC} ${W}View Live Service Logs${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC}  ${DIM}❯${NC} ${G}Restart Service${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC} ${DIM}❯${NC} ${M}Install / Update Backhaul Core${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC}  ${DIM}❯${NC} ${DIM}Exit${NC}\n"
    echo -ne "  ${C}MBACKHAUL ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r')
    
    case $opt in
        1) 
           echo -e "\n  ${DIM}┌─[ DEPLOY NEW TUNNEL ]${NC}"
           while true; do 
               echo -ne "  ${C}●${NC} ${W}Role [1: IRAN (Server) | 2: KHAREJ (Client) | q: Back]: ${NC}"; read s_type
               s_type=$(echo "$s_type" | tr -d '\r')
               [[ "$s_type" =~ ^[12q]$ ]] && break
           done
           [[ "$s_type" == "q" ]] && continue
           
           echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}TCP${NC} | ${W}2${NC} ${DIM}❯${NC} ${C}TCPMUX${NC} | ${W}3${NC} ${DIM}❯${NC} ${M}WSMUX${NC} | ${W}4${NC} ${DIM}❯${NC} ${G}WSSMUX (TLS)${NC}"
           echo -ne "  ${C}● Transport Protocol [1-4]: ${NC}"; read tr_choice
           tr_choice=$(echo "$tr_choice" | tr -d '\r')
           
           tr_val="tcp"
           case $tr_choice in 1) tr_val="tcp" ;; 2) tr_val="tcpmux" ;; 3) tr_val="wsmux" ;; 4) tr_val="wssmux" ;; esac
           
           echo -ne "  ${C}● Tunnel Suffix Name (e.g. bh1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -d '\r')
           t_name="bh_${suffix}"
           
           def_p=8443; [ "$tr_val" == "tcpmux" ] && def_p=9443; [ "$tr_val" == "wssmux" ] && def_p=9743
           echo -ne "  ${C}● Tunnel Link Port [Default ${def_p}]: ${NC}"; read t_port
           t_port=$(echo "$t_port" | tr -d '\r')
           t_port=${t_port:-$def_p}
           
           r_ip="0.0.0.0"
           if [ "$s_type" == "2" ]; then
               echo -ne "  ${C}● Iran Server Public IP: ${NC}"; read r_ip
               r_ip=$(echo "$r_ip" | tr -d '\r')
           fi
           
           gen_tok=$(head -c 8 /dev/urandom | xxd -p)
           echo -ne "  ${C}● Auth Token [Default ${gen_tok}]: ${NC}"; read u_tok
           u_tok=$(echo "$u_tok" | tr -d '\r')
           tok=${u_tok:-$gen_tok}
           
           fwd_ports=""
           if [ "$s_type" == "1" ]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Forward Ports (e.g. 443=127.0.0.1:443): ${NC}"; read fwd_ports
                   fwd_ports=$(echo "$fwd_ports" | tr -d '\r')
                   if [ -z "$fwd_ports" ]; then
                       echo -e "  ${R}Error: IRAN Server MUST have at least one forwarded port!${NC}"
                   else
                       break
                   fi
               done
           fi
           
           write_bh_config "$t_name" "$s_type" "$tr_val" "$t_port" "$r_ip" "$tok" "$fwd_ports"
           systemctl enable "mbackhaul@${t_name}" >/dev/null 2>&1
           systemctl restart "mbackhaul@${t_name}"
           echo -e "  ${G}● Backhaul Tunnel Deployed Successfully!${NC}"; sleep 2 ;;
           
        2) show_live_radar ;;
        3) show_tunnel_registry ;;
        
        4|5|6|7|8|9)
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN" .meta)
           ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; source "$SELECTED_TUN" 2>/dev/null
           
           if [[ "$opt" == "4" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Remote IP (Current: ${REMOTE_IP}): ${NC}"; read n_ip
               n_ip=$(echo "$n_ip" | tr -d '\r')
               [ -n "$n_ip" ] && {
                   clean_bh_counters "$t_name"
                   REMOTE_IP="$n_ip"
               }
               
           elif [[ "$opt" == "5" ]]; then
               if [ "$ROLE" == "1" ]; then
                   echo -ne "  ${C}●${NC} ${W}New Port Mappings (e.g. 443=127.0.0.1:443) [Current: ${PORTS:-None}]: ${NC}"; read n_ports
                   n_ports=$(echo "$n_ports" | tr -d '\r')
                   [ -n "$n_ports" ] && PORTS="$n_ports"
               else
                   echo -e "  ${Y}● Client role doesn't use port mappings.${NC}"; sleep 1.5; continue
               fi
               
           elif [[ "$opt" == "6" ]]; then
               echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}TCP${NC} | ${W}2${NC} ${DIM}❯${NC} ${C}TCPMUX${NC} | ${W}3${NC} ${DIM}❯${NC} ${M}WSMUX${NC} | ${W}4${NC} ${DIM}❯${NC} ${G}WSSMUX (TLS)${NC}"
               echo -ne "  ${C}● Select New Transport [1-4]: ${NC}"; read tr_choice
               tr_choice=$(echo "$tr_choice" | tr -d '\r')
               case $tr_choice in 
                   1) TRANSPORT="tcp" ;; 2) TRANSPORT="tcpmux" ;; 3) TRANSPORT="wsmux" ;; 4) TRANSPORT="wssmux" ;; 
                   *) continue ;; 
               esac
               clean_bh_counters "$t_name"
               
           elif [[ "$opt" == "7" ]]; then
               manage_cron "$t_name"; continue
               
           elif [[ "$opt" == "8" ]]; then
               journalctl -u mbackhaul@$t_name -n 50 -f; continue
               
           elif [[ "$opt" == "9" ]]; then
               true # Proceed to write and restart
           fi
           
           write_bh_config "$t_name" "$ROLE" "$TRANSPORT" "$TUN_PORT" "$REMOTE_IP" "$TOKEN" "$PORTS"
           systemctl restart mbackhaul@$t_name
           echo -e "  ${G}✔ Tunnel updated and applied.${NC}"; sleep 1.5
           ;;
           
        10)
           configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Delete ─────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}Index (or 'all' / 'q'): ${NC}"; read del_idx
           del_idx=$(echo "$del_idx" | tr -d '\r')
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do
                   t_name=$(basename "$conf" .meta)
                   systemctl stop mbackhaul@$t_name 2>/dev/null; systemctl disable mbackhaul@$t_name 2>/dev/null
                   clean_bh_counters "$t_name"
                   crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" | crontab -
                   rm -f "$conf" "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${t_name}_restart.sh"
               done
               echo -e "  ${G}All Tunnels Purged!${NC}"; sleep 1.5
           elif [[ -n "${configs[$del_idx]}" ]]; then
               t_name=$(basename "${configs[$del_idx]}" .meta)
               systemctl stop mbackhaul@$t_name 2>/dev/null; systemctl disable mbackhaul@$t_name 2>/dev/null
               clean_bh_counters "$t_name"
               crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" | crontab -
               rm -f "${configs[$del_idx]}" "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${t_name}_restart.sh"
               echo -e "  ${G}Tunnel Purged!${NC}"; sleep 1.5
           fi ;;
           
        11) menu_install_core ;;
        0) break ;;
    esac
done
