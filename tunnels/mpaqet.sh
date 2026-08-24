#!/bin/bash
# --- MPaqet Modular Core (mpaqet.sh) | Raw Packet Tunnel Engine v7.0.0 ---
# [Supports: KCP Modes | Raw Packet Anti-RST | Multi-Port Forwarding | SOCKS5 Proxy | Live Radar]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/paqet"
SERVICE_DIR="/etc/systemd/system"
LOCAL_DIR="/root/mtunnel"

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" 2>/dev/null

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
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf "%.1f MB/s", $bytes/1048576}"
    else awk "BEGIN {printf "%.2f GB/s", $bytes/1073741824}"; fi
}

format_total() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf "%.1f MB", $bytes/1048576}"
    elif [ "$bytes" -lt 1099511627776 ]; then awk "BEGIN {printf "%.2f GB", $bytes/1073741824}"
    else awk "BEGIN {printf "%.2f TB", $bytes/1099511627776}"; fi
}

install_paqet() {
    if ! command -v paqet >/dev/null 2>&1 && [ ! -f "/usr/local/bin/paqet" ]; then
        if [ -s "$LOCAL_DIR/packages/paqet" ]; then
            cp "$LOCAL_DIR/packages/paqet" /usr/local/bin/paqet
            chmod +x /usr/local/bin/paqet
        else
            apt-get update -y -q >/dev/null 2>&1
            apt-get install -y -q libpcap-dev >/dev/null 2>&1
            local arch=$(uname -m)
            local target="amd64"
            [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="arm64"
            wget -qO /tmp/paqet.tar.gz "https://github.com/hanselime/paqet/releases/latest/download/paqet-linux-${target}-v1.0.0-alpha.16.tar.gz" >/dev/null 2>&1
            if [ -s /tmp/paqet.tar.gz ]; then
                tar -xzf /tmp/paqet.tar.gz -C /tmp/ >/dev/null 2>&1
                local bin_found=$(find /tmp -type f -name "*paqet*" -executable | head -1)
                [ -n "$bin_found" ] && mv "$bin_found" /usr/local/bin/paqet && chmod +x /usr/local/bin/paqet
                rm -rf /tmp/paqet*
            fi
        fi
    fi
    [ -f "/usr/local/bin/paqet" ] && ln -sf /usr/local/bin/paqet /usr/bin/paqet 2>/dev/null
}

setup_paqet_counters() {
    local name="$1"; local l_port="$2"
    iptables -t mangle -C INPUT -p tcp --dport "$l_port" -m comment --comment "MPAQET_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -p tcp --dport "$l_port" -m comment --comment "MPAQET_RX_${name}" 2>/dev/null
    iptables -t mangle -C OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_TX_${name}" 2>/dev/null
    
    # Anti-RST Protection Rules
    iptables -t raw -C PREROUTING -p tcp --dport "$l_port" -j NOTRACK 2>/dev/null || iptables -t raw -A PREROUTING -p tcp --dport "$l_port" -j NOTRACK 2>/dev/null
    iptables -t raw -C OUTPUT -p tcp --sport "$l_port" -j NOTRACK 2>/dev/null || iptables -t raw -A OUTPUT -p tcp --sport "$l_port" -j NOTRACK 2>/dev/null
    iptables -t mangle -C OUTPUT -p tcp --sport "$l_port" --tcp-flags RST RST -j DROP 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp --sport "$l_port" --tcp-flags RST RST -j DROP 2>/dev/null
}

clean_paqet_counters() {
    local name="$1"
    iptables -t mangle -S INPUT 2>/dev/null | grep "MPAQET_RX_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t mangle $r 2>/dev/null; done
    iptables -t mangle -S OUTPUT 2>/dev/null | grep "MPAQET_TX_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t mangle $r 2>/dev/null; done
}

get_paqet_rx() {
    local rx=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep "MPAQET_RX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${rx:-0}"
}

get_paqet_tx() {
    local tx=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null | grep "MPAQET_TX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${tx:-0}"
}

check_paqet_connection() {
    local t_name="$1"
    local yaml="$CONF_DIR/${t_name}.yaml"
    [ ! -f "$yaml" ] && { echo "OFFLINE"; return; }
    
    if ! systemctl is-active --quiet "mpaqet@${t_name}" 2>/dev/null; then echo "OFFLINE"; return; fi

    local role=$(grep "^role:" "$yaml" 2>/dev/null | awk '{print $2}' | tr -d '"')
    if [ "$role" == "server" ]; then
        local port=$(grep -A5 "listen:" "$yaml" 2>/dev/null | grep "addr:" | sed -n 's/.*:\([0-9]*\)".*//p' | head -1)
        if ss -tHn sport = ":$port" 2>/dev/null | grep -q "ESTAB"; then echo "ONLINE"; else echo "WAITING"; fi
    else
        local s_addr=$(grep -A2 "server:" "$yaml" 2>/dev/null | grep "addr:" | awk '{print $2}' | tr -d '"')
        local s_port="${s_addr##*:}"
        if ss -tHn dport = ":$s_port" 2>/dev/null | grep -q "ESTAB"; then echo "ONLINE"; else echo "CONNECTING"; fi
    fi
}

draw_header() {
    local s_ip=$(get_local_ip); local total_tunnels=0; local online_tunnels=0
    for conf in "$CONF_DIR"/*.yaml; do
        if [ -f "$conf" ]; then
            ((total_tunnels++))
            local t_name=$(basename "$conf" .yaml)
            local st=$(check_paqet_connection "$t_name")
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
    local str1=" MPaqet Raw Packet Engine v7.0.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Status:${NC} ${status_badge} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

setup_systemd_service() {
    cat <<'EOF' > /etc/systemd/system/mpaqet@.service
[Unit]
Description=MPaqet Raw Packet Tunnel (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/paqet run -c /etc/paqet/%i.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

show_live_radar() {
    tput civis; clear
    declare -A rx_old tx_old

    for conf in "$CONF_DIR"/*.yaml; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .yaml)
        rx_old[$t_name]=$(get_paqet_rx "$t_name")
        tx_old[$t_name]=$(get_paqet_tx "$t_name")
    done

    while true; do
        printf "\033[H"; draw_header
        echo -e "\n  ${DIM}┌─[ PAQET TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL RX" "∑ TOTAL TX"
        echo -e "  ${B}├──────────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤${NC}"

        local count=0
        for conf in "$CONF_DIR"/*.yaml; do
            [ ! -f "$conf" ] && continue
            local t_name=$(basename "$conf" .yaml)
            local st=$(check_paqet_connection "$t_name")
            local st_color="${R}"; local st_text="OFFLINE"
            if [ "$st" == "ONLINE" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING"; fi

            local r_new=$(get_paqet_rx "$t_name"); local t_new=$(get_paqet_tx "$t_name")
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
            printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" "  No active Paqet tunnels configured."
        fi
        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\e' ]]; then break; fi
    done
    tput cnorm
}

edit_paqet_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.yaml 2>/dev/null))
    [ ${#configs[@]} -eq 0 ] && { echo -e "\n  ${R}● No tunnels configured!${NC}"; sleep 1.5; return; }

    echo -e "\n  ${B}╭────────────────── Select Tunnel to Edit ───────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .yaml)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}● Select Index: ${NC}"; read t_idx
    [[ -z "${configs[$t_idx]}" ]] && return

    local sel_cfg="${configs[$t_idx]}"
    local old_tname=$(basename "$sel_cfg" .yaml)

    echo -e "\n  ${DIM}┌─[ EDIT PAQET TUNNEL: ${W}${old_tname}${DIM} ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Edit KCP Mode (normal, fast, fast2, fast3)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Edit MTU Size (1000-1500)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Edit Connection Count (conn: 1-32)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Edit Encryption (aes-128-gcm, aes-256, none)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read e_opt

    case $e_opt in
        1)
           echo -ne "  ${C}● New KCP Mode [normal|fast|fast2|fast3]: ${NC}"; read n_m
           [ -n "$n_m" ] && sed -i "s/mode:.*/mode: \"$n_m\"/" "$sel_cfg"
           ;;
        2)
           echo -ne "  ${C}● New MTU Size [e.g. 1350]: ${NC}"; read n_mtu
           [ -n "$n_mtu" ] && sed -i "s/mtu:.*/mtu: $n_mtu/" "$sel_cfg"
           ;;
        3)
           echo -ne "  ${C}● New Connections Count [1-32]: ${NC}"; read n_c
           [ -n "$n_c" ] && sed -i "s/conn:.*/conn: $n_c/" "$sel_cfg"
           ;;
        4)
           echo -ne "  ${C}● New Encryption Block [aes-128-gcm|aes-256|none]: ${NC}"; read n_b
           [ -n "$n_b" ] && sed -i "s/block:.*/block: \"$n_b\"/" "$sel_cfg"
           ;;
        *) return ;;
    esac

    systemctl restart "mpaqet@${old_tname}" 2>/dev/null
    echo -e "\n  ${G}● Tunnel [${old_tname}] updated and restarted successfully!${NC}"; sleep 2
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ PAQET ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup Server Tunnel (Kharej Raw Listener)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Setup Client Tunnel (Iran Port Forward / SOCKS5)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Advanced Edit Tunnel (Mode/MTU/Conn/Crypto)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Live Traffic & Bandwidth Radar${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}PAQET ❯❯ ${NC}"; read opt
    case $opt in
        1)
           install_paqet; setup_systemd_service
           echo -ne "\n  ${C}● Tunnel Suffix Name (e.g. srv1): ${NC}"; read suffix
           local t_name="pq_${suffix}"
           local iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -1)
           local l_ip=$(get_local_ip)
           local gw_mac=$(ip neigh show 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
           echo -ne "  ${C}● Tunnel Listen Port [8888]: ${NC}"; read t_port
           t_port=${t_port:-8888}
           local s_key=$(head -c 16 /dev/urandom | xxd -p)
           echo -ne "  ${C}● Secret Key [Default ${s_key}]: ${NC}"; read u_key
           local key=${u_key:-$s_key}
           
           cat > "$CONF_DIR/${t_name}.yaml" <<EOF
role: "server"
log:
  level: "info"
listen:
  addr: ":$t_port"
network:
  interface: "${iface:-eth0}"
  ipv4:
    addr: "${l_ip}:$t_port"
    router_mac: "${gw_mac}"
  tcp:
    local_flag: ["PA"]
transport:
  protocol: "kcp"
  conn: 4
  kcp:
    key: "$key"
    mode: "fast"
    block: "aes-128-gcm"
    mtu: 1350
EOF
           setup_paqet_counters "$t_name" "$t_port"
           systemctl enable "mpaqet@${t_name}" >/dev/null 2>&1
           systemctl restart "mpaqet@${t_name}"
           echo -e "\n  ${G}● Paqet Server Tunnel Deployed! Key: ${key}${NC}"; sleep 2 ;;
        2)
           install_paqet; setup_systemd_service
           echo -ne "\n  ${C}● Tunnel Suffix Name (e.g. cl1): ${NC}"; read suffix
           local t_name="pq_${suffix}"
           local iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -1)
           local l_ip=$(get_local_ip)
           local gw_mac=$(ip neigh show 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
           echo -ne "  ${C}● Remote Kharej Server IP: ${NC}"; read r_ip
           echo -ne "  ${C}● Remote Listen Port [8888]: ${NC}"; read r_port
           r_port=${r_port:-8888}
           echo -ne "  ${C}● Secret Key (from Server): ${NC}"; read key
           echo -ne "  ${C}● Forward Ports (e.g. 443,8080): ${NC}"; read fwd_ports
           
           # Loop Prevention
           if echo ",$fwd_ports," | grep -q ",$r_port,"; then
               echo -e "  ${R}✖ Loop Error: Forward port cannot match Tunnel port ($r_port)!${NC}"; sleep 2; continue
           fi
           
           cat > "$CONF_DIR/${t_name}.yaml" <<EOF
role: "client"
log:
  level: "info"
forward:
EOF
           IFS=',' read -ra P_ARR <<< "$fwd_ports"
           for p in "${P_ARR[@]}"; do
               p=$(echo "$p" | tr -d ' ')
               echo -e "  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"" >> "$CONF_DIR/${t_name}.yaml"
           done
           cat >> "$CONF_DIR/${t_name}.yaml" <<EOF
network:
  interface: "${iface:-eth0}"
  ipv4:
    addr: "${l_ip}:0"
    router_mac: "${gw_mac}"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
server:
  addr: "${r_ip}:${r_port}"
transport:
  protocol: "kcp"
  conn: 4
  kcp:
    key: "$key"
    mode: "fast"
    block: "aes-128-gcm"
    mtu: 1350
EOF
           for p in "${P_ARR[@]}"; do setup_paqet_counters "$t_name" "$p"; done
           systemctl enable "mpaqet@${t_name}" >/dev/null 2>&1
           systemctl restart "mpaqet@${t_name}"
           echo -e "\n  ${G}● Paqet Client Tunnel Deployed!${NC}"; sleep 2 ;;
        3) edit_paqet_tunnel ;;
        4) show_live_radar ;;
        5)
           configs=($(ls "$CONF_DIR"/*.yaml 2>/dev/null))
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .yaml)"; done
           echo -ne "  ${C}● Enter Index or 'all': ${NC}"; read del_idx
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do
                   t_name=$(basename "$conf" .yaml)
                   systemctl stop "mpaqet@${t_name}" 2>/dev/null; systemctl disable "mpaqet@${t_name}" 2>/dev/null
                   clean_paqet_counters "$t_name"; rm -f "$conf"
               done
           elif [[ -n "${configs[$del_idx]}" ]]; then
               t_name=$(basename "${configs[$del_idx]}" .yaml)
               systemctl stop "mpaqet@${t_name}" 2>/dev/null; systemctl disable "mpaqet@${t_name}" 2>/dev/null
               clean_paqet_counters "$t_name"; rm -f "${configs[$del_idx]}"
           fi; echo -e "  ${G}● Purged!${NC}"; sleep 1 ;;
        0) break ;;
    esac
done
