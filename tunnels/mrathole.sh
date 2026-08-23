#!/bin/bash
# --- MRathole Modular Core (mrathole.sh) | Rathole Reverse Tunnel v1.7.0 ---
# [Features: Real-time Traffic Radar + Bandwidth Counters + Socket-level State Detection + Advanced Edit]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mrathole/tunnels"
SERVICE_TPL="/etc/systemd/system/mrathole@.service"
LOCAL_DIR="/root/mtunnel"

mkdir -p "$CONF_DIR"

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

# --- راه‌اندازی کانترهای ترافیک iptables برای پایش دقیق حجم و سرعت ---
setup_rathole_counters() {
    local name="$1"; local l_port="$2"; local r_ip="$3"; local role="$4"
    if [ "$role" == "1" ]; then
        # سرور ایران
        iptables -t mangle -C INPUT -p tcp --dport "$l_port" -m comment --comment "RAT_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -p tcp --dport "$l_port" -m comment --comment "RAT_RX_${name}" 2>/dev/null
        iptables -t mangle -C OUTPUT -p tcp --sport "$l_port" -m comment --comment "RAT_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -p tcp --sport "$l_port" -m comment --comment "RAT_TX_${name}" 2>/dev/null
    else
        # کلاینت خارج
        if [ -n "$r_ip" ] && [ "$r_ip" != "0.0.0.0" ]; then
            iptables -t mangle -C INPUT -s "$r_ip" -p tcp --sport "$l_port" -m comment --comment "RAT_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -s "$r_ip" -p tcp --sport "$l_port" -m comment --comment "RAT_RX_${name}" 2>/dev/null
            iptables -t mangle -C OUTPUT -d "$r_ip" -p tcp --dport "$l_port" -m comment --comment "RAT_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -d "$r_ip" -p tcp --dport "$l_port" -m comment --comment "RAT_TX_${name}" 2>/dev/null
        fi
    fi
}

clean_rathole_counters() {
    local name="$1"
    iptables -t mangle -S INPUT 2>/dev/null | grep "RAT_RX_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t mangle $r 2>/dev/null; done
    iptables -t mangle -S OUTPUT 2>/dev/null | grep "RAT_TX_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t mangle $r 2>/dev/null; done
}

get_rat_rx() {
    local rx=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep "RAT_RX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${rx:-0}"
}

get_rat_tx() {
    local tx=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null | grep "RAT_TX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${tx:-0}"
}

check_tunnel_connection() {
    local t_name="$1"
    local t_dir="$CONF_DIR/$t_name"
    [ ! -f "$t_dir/meta.conf" ] && { echo "OFFLINE"; return; }
    
    TYPE=""; LINK_PORT=""; REMOTE_IP=""; source "$t_dir/meta.conf"
    if ! systemctl is-active --quiet mrathole@$t_name 2>/dev/null; then echo "OFFLINE"; return; fi

    if [ "$TYPE" == "1" ]; then
        if ss -tHn sport = ":$LINK_PORT" 2>/dev/null | grep -q "ESTAB"; then echo "ONLINE"; else echo "WAITING"; fi
    else
        if ss -tHn dport = ":$LINK_PORT" 2>/dev/null | grep -q "ESTAB"; then echo "ONLINE"; else echo "CONNECTING"; fi
    fi
}

get_peer_ping() {
    local target_ip="$1"
    if [ -z "$target_ip" ] || [ "$target_ip" == "0.0.0.0" ]; then echo "N/A"; return; fi
    local ping_val=$(ping -c 1 -W 1 "$target_ip" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')
    if [ -n "$ping_val" ]; then echo "${ping_val}ms"; else echo "Timeout"; fi
}

install_rathole() {
    if [ ! -f "/usr/local/bin/rathole" ]; then
        mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
        if [ -f "$LOCAL_DIR/packages/rathole" ]; then
            cp "$LOCAL_DIR/packages/rathole" /usr/local/bin/rathole
            chmod +x /usr/local/bin/rathole
        else
            apt-get update -y -q >/dev/null 2>&1
            apt-get install -y -q unzip >/dev/null 2>&1
            local arch=$(uname -m)
            local target="x86_64-unknown-linux-gnu"
            [ "$arch" == "aarch64" ] && target="aarch64-unknown-linux-gnu"
            wget -qO /tmp/rathole.zip "https://github.com/rapiz1/rathole/releases/download/v0.5.0/rathole-${target}.zip" >/dev/null 2>&1
            unzip -q -o /tmp/rathole.zip -d /tmp/ >/dev/null 2>&1
            mv /tmp/rathole /usr/local/bin/rathole
            chmod +x /usr/local/bin/rathole
            cp /usr/local/bin/rathole "$LOCAL_DIR/packages/rathole" 2>/dev/null
            rm -f /tmp/rathole.zip
        fi
    fi
}

generate_toml() {
    local name="$1"
    local dir="$CONF_DIR/$name"
    local meta="$dir/meta.conf"
    local toml="$dir/config.toml"
    
    TYPE=""; T_NAME=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; source "$meta"
    
    > "$toml"
    if [ "$TYPE" == "1" ]; then
        echo "[server]" >> "$toml"
        echo "bind_addr = \"0.0.0.0:${LINK_PORT}\"" >> "$toml"
        echo "default_token = \"${TOKEN}\"" >> "$toml"
        IFS=',' read -ra P_ARR <<< "$PORTS"
        for p in "${P_ARR[@]}"; do
            p=$(echo "$p" | tr -d ' ')
            [ -z "$p" ] && continue
            echo -e "\n[server.services.p${p}_tcp]\ntype = \"tcp\"\nbind_addr = \"0.0.0.0:${p}\"" >> "$toml"
            echo -e "\n[server.services.p${p}_udp]\ntype = \"udp\"\nbind_addr = \"0.0.0.0:${p}\"" >> "$toml"
        done
    else
        echo "[client]" >> "$toml"
        echo "remote_addr = \"${REMOTE_IP}:${LINK_PORT}\"" >> "$toml"
        echo "default_token = \"${TOKEN}\"" >> "$toml"
        IFS=',' read -ra P_ARR <<< "$PORTS"
        for p in "${P_ARR[@]}"; do
            p=$(echo "$p" | tr -d ' ')
            [ -z "$p" ] && continue
            echo -e "\n[client.services.p${p}_tcp]\ntype = \"tcp\"\nlocal_addr = \"127.0.0.1:${p}\"" >> "$toml"
            echo -e "\n[client.services.p${p}_udp]\ntype = \"udp\"\nlocal_addr = \"127.0.0.1:${p}\"" >> "$toml"
        done
    fi
    setup_rathole_counters "$name" "$LINK_PORT" "$REMOTE_IP" "$TYPE"
}

setup_service() {
    cat <<EOF > "$SERVICE_TPL"
[Unit]
Description=Rathole Reverse Tunnel (%i)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rathole /etc/mrathole/tunnels/%i/config.toml
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
    for d in "$CONF_DIR"/*; do
        if [ -d "$d" ]; then
            ((total_tunnels++))
            local t_name=$(basename "$d")
            local st=$(check_tunnel_connection "$t_name")
            [ "$st" == "ONLINE" ] && ((online_tunnels++))
        fi
    done
    
    local status_badge="${R}○ STOPPED${NC}"
    if [ "$total_tunnels" -gt 0 ]; then
        if [ "$online_tunnels" -eq "$total_tunnels" ]; then status_badge="${G}● CONNECTED (${online_tunnels}/${total_tunnels})${NC}"
        elif [ "$online_tunnels" -gt 0 ]; then status_badge="${Y}◐ PARTIAL (${online_tunnels}/${total_tunnels})${NC}"
        else status_badge="${Y}◎ WAITING / NO LINK (0/${total_tunnels})${NC}"; fi
    fi

    clear; echo ""
    local str1=" MRathole Reverse Engine v1.7.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Link:${NC} ${status_badge} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

# --- مانیتورینگ زنده ترافیک، پینگ و سرعت اختصاصی رتهول ---
show_live_traffic_radar() {
    tput civis; clear
    declare -A rx_old tx_old
    
    for d in "$CONF_DIR"/*; do
        [ ! -d "$d" ] && continue
        local t_name=$(basename "$d")
        TYPE=""; LINK_PORT=""; REMOTE_IP=""; source "$d/meta.conf"
        setup_rathole_counters "$t_name" "$LINK_PORT" "$REMOTE_IP" "$TYPE"
        rx_old[$t_name]=$(get_rat_rx "$t_name")
        tx_old[$t_name]=$(get_rat_tx "$t_name")
    done

    while true; do
        printf "\033[H"; draw_header
        echo -e "\n  ${DIM}┌─[ RATHOLE TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL RX" "∑ TOTAL TX"
        echo -e "  ${B}├──────────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤${NC}"

        local count=0
        for d in "$CONF_DIR"/*; do
            [ ! -d "$d" ] && continue
            local t_name=$(basename "$d")
            local st=$(check_tunnel_connection "$t_name")
            local st_color="${R}"; local st_text="OFFLINE"
            if [ "$st" == "ONLINE" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING"; fi

            local r_new=$(get_rat_rx "$t_name"); local t_new=$(get_rat_tx "$t_name")
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
            printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" "  No active Rathole tunnels configured."
        fi
        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\e' ]]; then break; fi
    done
    tput cnorm
}

show_tunnel_registry() {
    draw_header
    echo -e "\n  ${Y}● Deployed Rathole Tunnels Detailed Registry:${NC}"
    local count=0
    for d in "$CONF_DIR"/*; do
        [ ! -d "$d" ] && continue
        local t_name=$(basename "$d")
        TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; source "$d/meta.conf"
        
        local role_text=$([ "$TYPE" == "1" ] && echo "IRAN (Server / Entry)" || echo "KHAREJ (Client / Exit)")
        local peer_text=$([ "$TYPE" == "1" ] && echo "Listening on :${LINK_PORT}" || echo "${REMOTE_IP}:${LINK_PORT}")
        local ping_val=$(get_peer_ping "$REMOTE_IP")

        local st=$(check_tunnel_connection "$t_name")
        local stat_icon="○"; local stat_text="OFFLINE"; local stat_color="${R}"
        if [ "$st" == "ONLINE" ]; then stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}";
        elif [ "$st" == "WAITING" ]; then stat_icon="◎"; stat_text="WAITING CLIENT"; stat_color="${Y}";
        elif [ "$st" == "CONNECTING" ]; then stat_icon="◎"; stat_text="CONNECTING..."; stat_color="${Y}"; fi

        local rx=$(get_rat_rx "$t_name"); local tx=$(get_rat_tx "$t_name")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $t_name"; local right_p="Role: $role_text"
        local pad=$(( 89 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp} ${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="Link Port    : ${LINK_PORT}"; local r1="Latency: ${ping_val}"
        local pad1=$(( 89 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Link Port    :${NC} ${W}${LINK_PORT}${NC}${sp1} ${DIM}Latency:${NC} ${Y}${ping_val}${NC} ${B}│${NC}"
        
        local l2="Peer Target  : ${peer_text}"; local r2="Link State: ${stat_text}"
        local pad2=$(( 89 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}Peer Target  :${NC} ${W}${peer_text}${NC}${sp2} ${DIM}Link State:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${B}│${NC}"

        local l3="Traffic Usage: RX $(format_total $rx) / TX $(format_total $tx)"
        local pad3=$(( 90 - ${#l3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${DIM}Traffic Usage:${NC} ${G}RX $(format_total $rx)${NC} ${DIM}/${NC} ${Y}TX $(format_total $tx)${NC}${sp3} ${B}│${NC}"

        local l4="Ports Pushed : ${PORTS:-None}"
        local pad4=$(( 90 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Ports Pushed :${NC} ${W}${PORTS:-None}${NC}${sp4} ${B}│${NC}"
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯\n"
        ((count++))
    done

    if [ "$count" -eq 0 ]; then echo -e "  ${R}● No tunnels configured yet!${NC}\n"; fi
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

edit_rathole_tunnel() {
    local tunnels=($(ls -d "$CONF_DIR"/* 2>/dev/null))
    [ ${#tunnels[@]} -eq 0 ] && { echo -e "\n  ${R}● No tunnels configured!${NC}"; sleep 1.5; return; }

    echo -e "\n  ${B}╭────────────────── Select Tunnel to Edit ───────────────────╮${NC}"
    for i in "${!tunnels[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${tunnels[$i]}")"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}● Select Index: ${NC}"; read t_idx
    [[ -z "${tunnels[$t_idx]}" ]] && return

    local t_dir="${tunnels[$t_idx]}"
    local old_tname=$(basename "$t_dir")
    TYPE=""; T_NAME=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; source "$t_dir/meta.conf"

    echo -e "\n  ${DIM}┌─[ ADVANCED EDIT: ${W}${old_tname}${DIM} ] (Press Enter to keep current value)${NC}"
    
    echo -ne "  ${C}●${NC} ${W}Server Mode [Current: ${Y}${TYPE}${W}] (1:IR Server | 2:KH Client): ${NC}"; read n_type
    n_type=$(echo "$n_type" | tr -d '\r' | tr -d ' '); [ -n "$n_type" ] && TYPE="$n_type"

    echo -ne "  ${C}●${NC} ${W}Tunnel Name [Current: ${Y}${T_NAME}${W}]: ${NC}"; read n_name
    n_name=$(echo "$n_name" | tr -d '\r' | tr -d ' '); [ -n "$n_name" ] && T_NAME="$n_name"

    echo -ne "  ${C}●${NC} ${W}Tunnel Link Port [Current: ${Y}${LINK_PORT}${W}]: ${NC}"; read n_port
    n_port=$(echo "$n_port" | tr -d '\r' | tr -d ' '); [ -n "$n_port" ] && LINK_PORT="$n_port"

    if [ "$TYPE" == "2" ]; then
        echo -ne "  ${C}●${NC} ${W}Remote (IRAN) IP [Current: ${Y}${REMOTE_IP}${W}]: ${NC}"; read n_rip
        n_rip=$(echo "$n_rip" | tr -d '\r' | tr -d ' '); [ -n "$n_rip" ] && REMOTE_IP="$n_rip"
    else
        REMOTE_IP="0.0.0.0"
    fi

    echo -ne "  ${C}●${NC} ${W}Secret Token [Current: ${Y}${TOKEN}${W}]: ${NC}"; read n_tok
    n_tok=$(echo "$n_tok" | tr -d '\r' | tr -d ' '); [ -n "$n_tok" ] && TOKEN="$n_tok"

    echo -ne "  ${C}●${NC} ${W}Forwarded Ports [Current: ${Y}${PORTS}${W}]: ${NC}"; read n_ports
    n_ports=$(echo "$n_ports" | tr -d '\r' | tr -d ' '); [ -n "$n_ports" ] && PORTS="$n_ports"

    systemctl stop mrathole@$old_tname 2>/dev/null
    systemctl disable mrathole@$old_tname 2>/dev/null
    clean_rathole_counters "$old_tname"

    [ "$old_tname" != "$T_NAME" ] && rm -rf "$t_dir"

    mkdir -p "$CONF_DIR/$T_NAME"
    echo -e "TYPE=$TYPE\nT_NAME=$T_NAME\nLINK_PORT=$LINK_PORT\nREMOTE_IP=$REMOTE_IP\nTOKEN=$TOKEN\nPORTS=$PORTS" > "$CONF_DIR/$T_NAME/meta.conf"

    generate_toml "$T_NAME"
    systemctl enable mrathole@$T_NAME >/dev/null 2>&1
    systemctl restart mrathole@$T_NAME

    echo -e "\n  ${G}● Reverse Tunnel [${T_NAME}] completely updated and restarted!${NC}"; sleep 2
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${R}Setup New Reverse Tunnel (Rathole)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Advanced Edit Tunnel (All Parameters)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Live Traffic & Bandwidth Radar${NC} ${DIM}(Real-time Speed)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}View Tunnels Detailed Registry${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Delete Tunnels${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    echo -ne "  ${C}MRATHOLE ❯❯ ${NC}"; read opt
    case $opt in
        1) 
           install_rathole; setup_service
           apply_bbr_optimization
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IRAN | 2:KHAREJ | q:Back]: ${NC}"; read s_type; [[ "$s_type" =~ ^[12q]$ ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           while true; do echo -ne "  ${C}●${NC} ${W}Tunnel Suffix (e.g. rt1): ${NC}"; read suffix; t_name="rat_$suffix"; break; done
           r_ip="0.0.0.0"
           [ "$s_type" == "2" ] && { echo -ne "  ${C}●${NC} ${W}Remote (IRAN) IP: ${NC}"; read r_ip; }
           echo -ne "  ${C}●${NC} ${W}Link Port: ${NC}"; read t_port
           t_token=$(head -c 8 /dev/urandom | xxd -p)
           echo -ne "  ${C}●${NC} ${W}Forward Ports (e.g. 80,443): ${NC}"; read t_ports
           
           mkdir -p "$CONF_DIR/$t_name"
           echo -e "TYPE=$s_type\nT_NAME=$t_name\nLINK_PORT=$t_port\nREMOTE_IP=$r_ip\nTOKEN=$t_token\nPORTS=$t_ports" > "$CONF_DIR/$t_name/meta.conf"
           generate_toml "$t_name"
           systemctl enable mrathole@$t_name >/dev/null 2>&1
           systemctl restart mrathole@$t_name
           echo -e "  ${G}● Deployed!${NC}"; sleep 1.5 ;;
        2) edit_rathole_tunnel ;;
        3) show_live_traffic_radar ;;
        4) show_tunnel_registry ;;
        5)
           tunnels=($(ls -d "$CONF_DIR"/* 2>/dev/null))
           for i in "${!tunnels[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${tunnels[$i]}")"; done
           echo -ne "  ${C}● Enter Index or 'all': ${NC}"; read del_idx
           if [[ "$del_idx" == "all" ]]; then
               for d in "${tunnels[@]}"; do t_name=$(basename "$d"); systemctl stop mrathole@$t_name 2>/dev/null; clean_rathole_counters "$t_name"; rm -rf "$d"; done
           elif [[ -n "${tunnels[$del_idx]}" ]]; then
               t_name=$(basename "${tunnels[$del_idx]}"); systemctl stop mrathole@$t_name 2>/dev/null; clean_rathole_counters "$t_name"; rm -rf "${tunnels[$del_idx]}"
           fi; echo -e "  ${G}● Purged!${NC}"; sleep 1 ;;
        0) break ;;
    esac
done
