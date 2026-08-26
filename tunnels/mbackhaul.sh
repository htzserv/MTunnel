#!/bin/bash
# --- MBackhaul Modular Core (mbackhaul.sh) | MDesign Ecosystem v1.4.0 ---
# [Supports: TCP | TCPMUX | WSMUX | WSSMUX | Real-Time Radar | Full Advanced Edit]

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

install_backhaul() {
    if ! command -v bh >/dev/null 2>&1 && [ ! -f "/usr/local/bin/bh" ]; then
        if [ -s "$LOCAL_DIR/packages/bh" ]; then
            cp "$LOCAL_DIR/packages/bh" /usr/local/bin/bh
            chmod +x /usr/local/bin/bh
        else
            local arch=$(uname -m)
            local target="backhaul_linux_amd64.tar.gz"
            [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="backhaul_linux_arm64.tar.gz"
            wget -qO /tmp/bh.tar.gz "https://github.com/Musixal/Backhaul/releases/latest/download/${target}" >/dev/null 2>&1
            if [ -s /tmp/bh.tar.gz ]; then
                tar -xzf /tmp/bh.tar.gz -C /tmp/ >/dev/null 2>&1
                mv /tmp/backhaul /usr/local/bin/bh
                chmod +x /usr/local/bin/bh
                cp /usr/local/bin/bh "$LOCAL_DIR/packages/bh" 2>/dev/null
                rm -rf /tmp/bh.tar.gz /tmp/backhaul
            fi
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
    local toml="$CONF_DIR/${t_name}.toml"
    local meta="$CONF_DIR/${t_name}.meta"
    [ ! -f "$meta" ] && { echo "OFFLINE"; return; }
    
    source "$meta"
    if ! systemctl is-active --quiet "mbackhaul@${t_name}" 2>/dev/null; then echo "OFFLINE"; return; fi

    if [ "$ROLE" == "1" ]; then
        if ss -tHn sport = ":$TUN_PORT" 2>/dev/null | grep -q "ESTAB"; then echo "ONLINE"; else echo "WAITING"; fi
    else
        if ss -tHn dport = ":$TUN_PORT" 2>/dev/null | grep -q "ESTAB"; then echo "ONLINE"; else echo "CONNECTING"; fi
    fi
}

get_peer_ping() {
    local target_ip="$1"
    if [ -z "$target_ip" ] || [ "$target_ip" == "0.0.0.0" ]; then echo "N/A"; return; fi
    local ping_val=$(ping -c 1 -W 1 "$target_ip" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')
    if [ -n "$ping_val" ]; then echo "${ping_val}ms"; else echo "Timeout"; fi
}

write_bh_config() {
    local name="$1"; local role="$2"; local transport="$3"; local port="$4"; local r_ip="$5"; local token="$6"; local ports_str="$7"
    local toml="$CONF_DIR/${name}.toml"
    local meta="$CONF_DIR/${name}.meta"

    echo -e "ROLE=$role\nTRANSPORT=$transport\nTUN_PORT=$port\nREMOTE_IP=$r_ip\nTOKEN=$token\nPORTS='$ports_str'" > "$meta"

    if [ "$role" == "1" ]; then
        {
            echo "[server]"
            echo "bind_addr = \"0.0.0.0:${port}\""
            echo "transport = \"${transport}\""
            [ "$transport" == "tcp" ] && echo "accept_udp = false"
            echo "token = \"${token}\""
            echo "keepalive_period = 75"
            echo "nodelay = true"
            echo "heartbeat = 40"
            echo "channel_size = 4096"
            if [ "$transport" != "tcp" ]; then
                echo "mux_con = 8"
                echo "mux_version = 1"
                echo "mux_framesize = 32768"
                echo "mux_recievebuffer = 4194304"
                echo "mux_streambuffer = 65536"
            fi
            if [ "$transport" == "wssmux" ]; then
                generate_ssl_cert
                echo "tls_cert = \"${CERT_DIR}/wssmux.crt\""
                echo "tls_key = \"${CERT_DIR}/wssmux.key\""
            fi
            echo "sniffer = false"
            echo "web_port = 0"
            echo "log_level = \"info\""
            echo "ports = ["
            IFS=',' read -ra P_ARR <<< "$ports_str"
            local total=${#P_ARR[@]}
            for ((i=0; i<total; i++)); do
                local p=$(echo "${P_ARR[$i]}" | tr -d ' ')
                if [[ "$p" =~ ^[0-9]+$ ]]; then p="${p}=127.0.0.1:${p}"; fi
                [ $i -lt $((total - 1)) ] && echo "  \"${p}\", " || echo "  \"${p}\""
            done
            echo "]"
        } > "$toml"
    else
        {
            echo "[client]"
            echo "remote_addr = \"${r_ip}:${port}\""
            [ "$transport" == "wsmux" ] || [ "$transport" == "wssmux" ] && echo "edge_ip = \"\""
            echo "transport = \"${transport}\""
            echo "token = \"${token}\""
            echo "connection_pool = 8"
            echo "aggressive_pool = false"
            echo "keepalive_period = 75"
            echo "nodelay = true"
            echo "retry_interval = 3"
            echo "dial_timeout = 10"
            if [ "$transport" != "tcp" ]; then
                echo "mux_version = 1"
                echo "mux_framesize = 32768"
                echo "mux_recievebuffer = 4194304"
                echo "mux_streambuffer = 65536"
            fi
            echo "sniffer = false"
            echo "web_port = 0"
            echo "log_level = \"info\""
        } > "$toml"
    fi

    setup_bh_counters "$name" "$port" "$r_ip" "$role"
}

setup_systemd_service() {
    cat <<'EOF' > /etc/systemd/system/mbackhaul@.service
[Unit]
Description=MBackhaul Multi-Multiplexer (%i)
After=network-online.target
Wants=network-online.target

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
    local s_ip=$(get_local_ip); local total_tunnels=0; local online_tunnels=0
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            ((total_tunnels++))
            local t_name=$(basename "$conf" .meta)
            local st=$(check_bh_connection "$t_name")
            [ "$st" == "ONLINE" ] && ((online_tunnels++))
        fi
    done
    
    local status_badge="${R}○ STOPPED${NC}"
    if [ "$total_tunnels" -gt 0 ]; then
        if [ "$online_tunnels" -eq "$total_tunnels" ]; then status_badge="${G}● CONNECTED (${online_tunnels}/${total_tunnels})${NC}"
        elif [ "$online_tunnels" -gt 0 ]; then status_badge="${Y}◐ PARTIAL (${online_tunnels}/${total_tunnels})${NC}"
        else status_badge="${Y}◎ WAITING (${online_tunnels}/${total_tunnels})${NC}"; fi
    fi

    clear; echo ""
    local str1=" MBackhaul Tunnel Core v1.4.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Status:${NC} ${status_badge} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_live_radar() {
    tput civis; clear
    declare -A rx_old tx_old

    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        source "$conf"
        setup_bh_counters "$t_name" "$TUN_PORT" "$REMOTE_IP" "$ROLE"
        rx_old[$t_name]=$(get_bh_rx "$t_name")
        tx_old[$t_name]=$(get_bh_tx "$t_name")
    done

    while true; do
        printf "\033[H"; draw_header
        echo -e "\n  ${DIM}┌─[ BACKHAUL TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL RX" "∑ TOTAL TX"
        echo -e "  ${B}├──────────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤${NC}"

        local count=0
        for conf in "$CONF_DIR"/*.meta; do
            [ ! -f "$conf" ] && continue
            local t_name=$(basename "$conf" .meta)
            local st=$(check_bh_connection "$t_name")
            local st_color="${R}"; local st_text="OFFLINE"
            if [ "$st" == "ONLINE" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING"; fi

            local r_new=$(get_bh_rx "$t_name"); local t_new=$(get_bh_tx "$t_name")
            local r_prev=${rx_old[$t_name]:-$r_new}; local t_prev=${tx_old[$t_name]:-$t_new}
            local rx_s=$((r_new - r_prev)); local tx_s=$((t_new - t_prev))
            [ "$rx_s" -lt 0 ] && rx_s=0; [ "$tx_s" -lt 0 ] && tx_s=0
            rx_old[$t_name]=$r_new; tx_old[$t_name]=$t_new

            local c_rx="${DIM}"; [ "$rx_s" -gt 0 ] && c_rx="${G}"
            local c_tx="${DIM}"; [ "$tx_s" -gt 0 ] && c_tx="${Y}"

            printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} %b%-10s%b ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "$t_name" "$st_color" "$st_text" "$NC" "$c_rx" "$(format_speed $rx_s)" "$NC" "$c_tx" "$(format_speed $tx_s)" "$NC" "$(format_total $r_new)" "$(format_total $t_new)"
            ((count++))
        done

        if [ "$count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" "  No active Backhaul tunnels configured."
        fi
        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\e' ]]; then break; fi
    done
    tput cnorm
}

show_tunnel_registry() {
    draw_header
    echo -e "\n  ${Y}● Deployed Backhaul Tunnels Registry:${NC}"
    local count=0
    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""
        source "$conf"
        
        local role_text=$([ "$ROLE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local peer_text=$([ "$ROLE" == "1" ] && echo "Listening on :${TUN_PORT}" || echo "${REMOTE_IP}:${TUN_PORT}")
        local ping_val=$(get_peer_ping "$REMOTE_IP")
        local st=$(check_bh_connection "$t_name")
        local stat_icon="○"; local stat_text="OFFLINE"; local stat_color="${R}"
        if [ "$st" == "ONLINE" ]; then stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}";
        elif [ "$st" == "WAITING" ]; then stat_icon="◎"; stat_text="WAITING CLIENT"; stat_color="${Y}";
        elif [ "$st" == "CONNECTING" ]; then stat_icon="◎"; stat_text="CONNECTING..."; stat_color="${Y}"; fi

        local rx=$(get_bh_rx "$t_name"); local tx=$(get_bh_tx "$t_name")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $t_name"; local right_p="Role: $role_text [${TRANSPORT^^}]"
        local pad=$(( 89 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp} ${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="Link Port    : ${TUN_PORT}"; local r1="Latency: ${ping_val}"
        local pad1=$(( 89 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Link Port    :${NC} ${W}${TUN_PORT}${NC}${sp1} ${DIM}Latency:${NC} ${Y}${ping_val}${NC} ${B}│${NC}"
        
        local l2="Peer Target  : ${peer_text}"; local r2="Link State: ${stat_text}"
        local pad2=$(( 89 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}Peer Target  :${NC} ${W}${peer_text}${NC}${sp2} ${DIM}Link State:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${B}│${NC}"

        local l_tok="Auth Token   : ${TOKEN}"
        local pad_tok=$(( 90 - ${#l_tok} )); [ "$pad_tok" -lt 0 ] && pad_tok=0; local sp_tok=$(printf '%*s' "$pad_tok" "")
        echo -e "  ${B}│${NC} ${Y}Auth Token   :${NC} ${W}${TOKEN}${NC}${sp_tok} ${B}│${NC}"

        if [ "$ROLE" == "1" ] && [ -n "$PORTS" ]; then
            local l_fwd="Ports Forward: ${PORTS}"
            local pad_fwd=$(( 90 - ${#l_fwd} )); [ "$pad_fwd" -lt 0 ] && pad_fwd=0; local sp_fwd=$(printf '%*s' "$pad_fwd" "")
            echo -e "  ${B}│${NC} ${G}Ports Forward:${NC} ${W}${PORTS}${NC}${sp_fwd} ${B}│${NC}"
        fi

        local l3="Traffic Usage: RX $(format_total $rx) / TX $(format_total $tx)"
        local pad3=$(( 90 - ${#l3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${DIM}Traffic Usage:${NC} ${G}RX $(format_total $rx)${NC} ${DIM}/${NC} ${Y}TX $(format_total $tx)${NC}${sp3} ${B}│${NC}"
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯\n"
        ((count++))
    done
    if [ "$count" -eq 0 ]; then echo -e "  ${R}● No tunnels configured yet!${NC}\n"; fi
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

edit_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
    [ ${#configs[@]} -eq 0 ] && { echo -e "\n  ${R}● No tunnels configured!${NC}"; sleep 1.5; return; }

    echo -e "\n  ${B}╭────────────────── Select Tunnel to Edit ───────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}● Select Index: ${NC}"; read t_idx
    [[ -z "${configs[$t_idx]}" ]] && return

    local sel_meta="${configs[$t_idx]}"
    local old_tname=$(basename "$sel_meta" .meta)
    ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""
    source "$sel_meta"

    echo -e "\n  ${DIM}┌─[ ADVANCED EDIT: ${W}${old_tname}${DIM} ] (Press Enter to keep current value)${NC}"
    
    echo -ne "  ${C}●${NC} ${W}Server Mode [Current: ${Y}${ROLE}${W}] (1:IR Server | 2:KH Client): ${NC}"; read n_role
    n_role=$(echo "$n_role" | tr -d '\r' | tr -d ' '); [ -n "$n_role" ] && ROLE="$n_role"

    echo -ne "  ${C}●${NC} ${W}Transport [Current: ${Y}${TRANSPORT}${W}] (1:tcp | 2:tcpmux | 3:wsmux | 4:wssmux): ${NC}"; read n_tr
    n_tr=$(echo "$n_tr" | tr -d '\r' | tr -d ' ')
    case $n_tr in
        1) TRANSPORT="tcp" ;; 2) TRANSPORT="tcpmux" ;; 3) TRANSPORT="wsmux" ;; 4) TRANSPORT="wssmux" ;;
    esac

    echo -ne "  ${C}●${NC} ${W}Tunnel Name [Current: ${Y}${old_tname}${W}]: ${NC}"; read n_name
    n_name=$(echo "$n_name" | tr -d '\r' | tr -d ' '); [ -z "$n_name" ] && n_name="$old_tname"

    echo -ne "  ${C}●${NC} ${W}Tunnel Port [Current: ${Y}${TUN_PORT}${W}]: ${NC}"; read n_port
    n_port=$(echo "$n_port" | tr -d '\r' | tr -d ' '); [ -n "$n_port" ] && TUN_PORT="$n_port"

    if [ "$ROLE" == "2" ]; then
        echo -ne "  ${C}●${NC} ${W}Remote (IRAN) IP [Current: ${Y}${REMOTE_IP}${W}]: ${NC}"; read n_rip
        n_rip=$(echo "$n_rip" | tr -d '\r' | tr -d ' '); [ -n "$n_rip" ] && REMOTE_IP="$n_rip"
    else
        REMOTE_IP="0.0.0.0"
    fi

    echo -ne "  ${C}●${NC} ${W}Secret Token [Current: ${Y}${TOKEN}${W}]: ${NC}"; read n_tok
    n_tok=$(echo "$n_tok" | tr -d '\r' | tr -d ' '); [ -n "$n_tok" ] && TOKEN="$n_tok"

    if [ "$ROLE" == "1" ]; then
        echo -ne "  ${C}●${NC} ${W}Forward Ports [Current: ${Y}${PORTS}${W}]: ${NC}"; read n_ports
        n_ports=$(echo "$n_ports" | tr -d '\r'); [ -n "$n_ports" ] && PORTS="$n_ports"
    fi

    systemctl stop "mbackhaul@${old_tname}" 2>/dev/null
    systemctl disable "mbackhaul@${old_tname}" 2>/dev/null
    clean_bh_counters "$old_tname"

    [ "$old_tname" != "$n_name" ] && rm -f "$CONF_DIR/${old_tname}.toml" "$CONF_DIR/${old_tname}.meta"

    write_bh_config "$n_name" "$ROLE" "$TRANSPORT" "$TUN_PORT" "$REMOTE_IP" "$TOKEN" "$PORTS"
    systemctl enable "mbackhaul@${n_name}" >/dev/null 2>&1
    systemctl restart "mbackhaul@${n_name}"

    echo -e "\n  ${G}● Backhaul Tunnel [${n_name}] updated and restarted!${NC}"; sleep 2
}

setup_new_tunnel() {
    install_backhaul
    setup_systemd_service
    apply_bbr_optimization

    local s_type=""
    while true; do 
        echo -ne "  ${C}●${NC} ${W}Server Mode [1:IRAN (Server) | 2:KHAREJ (Client) | q:Back]: ${NC}"
        read s_type
        [[ "$s_type" =~ ^[12q]$ ]] && break
    done
    [[ "$s_type" == "q" ]] && return

    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}TCP${NC} | ${W}2${NC} ${DIM}❯${NC} ${C}TCPMUX${NC} | ${W}3${NC} ${DIM}❯${NC} ${M}WSMUX${NC} | ${W}4${NC} ${DIM}❯${NC} ${G}WSSMUX (TLS)${NC}"
    echo -ne "  ${C}● Transport Protocol [1-4]: ${NC}"; read tr_choice
    local tr_val="tcp"
    case $tr_choice in 1) tr_val="tcp" ;; 2) tr_val="tcpmux" ;; 3) tr_val="wsmux" ;; 4) tr_val="wssmux" ;; esac

    echo -ne "  ${C}● Tunnel Suffix Name (e.g. bh1): ${NC}"; read suffix
    suffix=$(echo "$suffix" | tr -d '\r' | tr -d ' ')
    [ -z "$suffix" ] && suffix="default"
    local t_name="bh_${suffix}"

    local def_p=8443
    [ "$tr_val" == "tcpmux" ] && def_p=9443
    [ "$tr_val" == "wssmux" ] && def_p=9743
    echo -ne "  ${C}● Tunnel Listen/Connect Port [Default ${def_p}]: ${NC}"; read t_port
    t_port=${t_port:-$def_p}
    t_port=$(echo "$t_port" | tr -d '\r' | tr -d ' ')

    local r_ip="0.0.0.0"
    if [ "$s_type" == "2" ]; then
        echo -ne "  ${C}● Iran Server Public IP: ${NC}"; read r_ip
        r_ip=$(echo "$r_ip" | tr -d '\r' | tr -d ' ')
    fi

    local gen_tok=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo -ne "  ${C}● Auth Token [Default ${gen_tok}]: ${NC}"; read u_tok
    u_tok=$(echo "$u_tok" | tr -d '\r' | tr -d ' ')
    local tok=${u_tok:-$gen_tok}

    local fwd_ports=""
    if [ "$s_type" == "1" ]; then
        echo -ne "  ${C}● Forward Ports (e.g. 443,8080=127.0.0.1:8080): ${NC}"; read fwd_ports
        fwd_ports=$(echo "$fwd_ports" | tr -d '\r')
    fi

    write_bh_config "$t_name" "$s_type" "$tr_val" "$t_port" "$r_ip" "$tok" "$fwd_ports"
    systemctl enable "mbackhaul@${t_name}" >/dev/null 2>&1
    systemctl restart "mbackhaul@${t_name}"
    echo -e "  ${G}● Backhaul Tunnel Deployed Successfully!${NC}"; sleep 2
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup New Backhaul Tunnel${NC} ${DIM}(TCP / MUX / WSS)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Advanced Edit Tunnel (All Parameters)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Live Traffic & Bandwidth Radar${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}View Tunnels Registry${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Restart Service${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}BACKHAUL ❯❯ ${NC}"; read opt
    case $opt in
        1) setup_new_tunnel ;;
        2) edit_tunnel ;;
        3) show_live_radar ;;
        4) show_tunnel_registry ;;
        5)
           configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"; done
           echo -ne "  ${C}● Select to Restart: ${NC}"; read r_idx
           if [[ -n "${configs[$r_idx]}" ]]; then
               t_name=$(basename "${configs[$r_idx]}" .meta)
               systemctl restart "mbackhaul@${t_name}"
               echo -e "  ${G}● Restarted!${NC}"; sleep 1
           fi ;;
        6)
           configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"; done
           echo -ne "  ${C}● Enter Index or 'all': ${NC}"; read del_idx
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do
                   t_name=$(basename "$conf" .meta)
                   systemctl stop "mbackhaul@${t_name}" 2>/dev/null; systemctl disable "mbackhaul@${t_name}" 2>/dev/null
                   clean_bh_counters "$t_name"; rm -f "$conf" "$CONF_DIR/${t_name}.toml"
               done
           elif [[ -n "${configs[$del_idx]}" ]]; then
               t_name=$(basename "${configs[$del_idx]}" .meta)
               systemctl stop "mbackhaul@${t_name}" 2>/dev/null; systemctl disable "mbackhaul@${t_name}" 2>/dev/null
               clean_bh_counters "$t_name"; rm -f "${configs[$del_idx]}" "$CONF_DIR/${t_name}.toml"
           fi; echo -e "  ${G}● Purged!${NC}"; sleep 1 ;;
        0) break ;;
    esac
done
