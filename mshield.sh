#!/bin/bash
# --- MDesign Modular Core (mshield.sh) | Zero-Trust Firewall & Universal Receiver v3.0.0 (Full Edition) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'

OBFS_DIR="/etc/mshield/obfs"
SVC_FILE="/etc/systemd/system/mshield-obfs.service"
mkdir -p "$OBFS_DIR" 2>/dev/null

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    
    local fw_stat="${DIM}OFFLINE${NC}"
    if iptables -C INPUT -j MSHIELD >/dev/null 2>&1; then fw_stat="${G}ACTIVE${NC}"; fi
    
    local obfs_stat="${DIM}OFFLINE${NC}"
    if systemctl is-active --quiet mshield-obfs.service 2>/dev/null; then obfs_stat="${C}RCVR ACTIVE${NC}"; fi

    clear; echo ""
    local str1=" MShield Zero-Trust Warden 3.0.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 39 ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} Firewall:${NC} ${fw_stat} ${DIM}│ Kharej:${NC} ${obfs_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

activate_firewall() {
    echo -e "\n  ${DIM}● Scanning MDesign ecosystem for active configurations...${NC}"
    
    iptables -D INPUT -j MSHIELD >/dev/null 2>&1
    iptables -F MSHIELD >/dev/null 2>&1; iptables -X MSHIELD >/dev/null 2>&1
    iptables -N MSHIELD

    # Allow Local & Established
    iptables -A MSHIELD -i lo -j ACCEPT
    iptables -A MSHIELD -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Allow SSH
    local ssh_port=$(ss -tlnp 2>/dev/null | grep -i sshd | awk '{print $4}' | rev | cut -d: -f1 | rev | head -n 1)
    [ -z "$ssh_port" ] && ssh_port=22
    iptables -A MSHIELD -p tcp --dport "$ssh_port" -j ACCEPT
    echo -e "  ${G}✔${NC} Secured SSH Management Port (${ssh_port})"

    # Whitelist Peer IPs (GRE, VXLAN, L2TP, Hysteria)
    local peer_ips=""
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf /etc/ml2tp/tunnels/*.conf /etc/mhysteria/tunnels/*.conf; do 
        if [ -f "$conf" ]; then
            local r_ip=$(grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$conf" | grep -vE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.)' | head -n 1)
            [ -n "$r_ip" ] && peer_ips="$peer_ips $r_ip\n"
        fi
    done
    if [ -n "$peer_ips" ]; then
        local unique_peers=$(echo -e "$peer_ips" | sort -u | grep -v '^$')
        for pip in $unique_peers; do
            iptables -A MSHIELD -s "$pip" -j ACCEPT
            echo -e "  ${G}✔${NC} Whitelisted Core Peer IP: ${C}$pip${NC}"
        done
    fi

    # Protect Active Ports (MPorter + Local OBFS)
    local fw_ports=""
    [ -f "/etc/haproxy/haproxy.cfg" ] && fw_ports+=$(awk '/frontend ft_/ {print $2}' /etc/haproxy/haproxy.cfg | sed 's/ft_//')"\n"
    [ -f "/etc/gost/config.json" ] && command -v jq >/dev/null 2>&1 && fw_ports+=$(jq -r '.ServeNodes[]?' /etc/gost/config.json 2>/dev/null | sed -E 's/tcp:\/\/:([0-9]+)\/.*/\1/g')"\n"
    
    # استخراج هوشمند پورت‌های بومی L2TP و هیستریا برای باز شدن در فایروال
    for conf in /etc/ml2tp/tunnels/*.conf /etc/mhysteria/tunnels/*.conf; do
        if [ -f "$conf" ]; then
            source "$conf"
            [ -n "$TUN_PORT" ] && fw_ports+="${TUN_PORT}\n"
        fi
    done

    # Read Server Receiver Port (If this is Kharej)
    if [ -f "$OBFS_DIR/server_main.conf" ]; then
        local obfs_p=$(grep -oP '://:\K[0-9]+' "$OBFS_DIR/server_main.conf" | head -n 1)
        [ -n "$obfs_p" ] && fw_ports+="${obfs_p}\n"
    fi

    if [ -n "$fw_ports" ]; then
        local unique_ports=$(echo -e "$fw_ports" | sort -n -u | grep -v '^$')
        for port in $unique_ports; do
            iptables -A MSHIELD -p tcp --dport "$port" --syn -m limit --limit 25/s --limit-burst 100 -j ACCEPT
            iptables -A MSHIELD -p udp --dport "$port" -j ACCEPT
            iptables -A MSHIELD -p tcp --dport "$port" --syn -j DROP
            iptables -A MSHIELD -p tcp --dport "$port" -j ACCEPT
        done
        echo -e "  ${G}✔${NC} Secured Active Ports with Anti-Flood & UDP Access."
    fi

    # Absolute Stealth Rules (Drop scanners, pings, unknown protocol scans)
    iptables -A MSHIELD -p gre -j DROP
    iptables -A MSHIELD -p udp --dport 4789 -j DROP
    iptables -A MSHIELD -p tcp -m tcp --dport 1:65535 --tcp-flags SYN,RST,ACK SYN -m recent --name M_SCANNER --set -j ACCEPT
    iptables -A MSHIELD -m recent --name M_SCANNER --rcheck --seconds 3600 --hitcount 8 -j DROP
    iptables -A MSHIELD -p icmp --icmp-type echo-request -j DROP

    # Blackhole TCP Probing (Silent Drop for all unhandled SYN requests)
    iptables -A MSHIELD -p tcp --syn -j DROP

    iptables -I INPUT 1 -j MSHIELD
    echo -e "\n  ${G}● Zero-Trust Shield Activated Successfully!${NC}"; sleep 2
}

disable_firewall() {
    echo -e "\n  ${Y}● Disarming network defense lines...${NC}"
    while iptables -D INPUT -j MSHIELD >/dev/null 2>&1; do :; done
    iptables -F MSHIELD 2>/dev/null; iptables -X MSHIELD 2>/dev/null
    echo -e "  ${G}● Firewall deactivated. Standard WAN probing allowed.${NC planetary}"; sleep 1.5
}

install_gost_if_needed() {
    if ! command -v gost >/dev/null 2>&1; then
        echo -e "  ${Y}● Gost Engine not found. Installing OBFS core...${NC}"
        wget -qO gost.gz https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz >/dev/null 2>&1
        gzip -d gost.gz; chmod +x gost; mv gost /usr/local/bin/gost
    fi
}

deploy_receiver() {
    install_gost_if_needed
    echo -e "\n  ${DIM}┌─[ UNIVERSAL OBFS RECEIVER (KHAREJ SERVER) ]${NC}"
    echo -e "  ${DIM}│${NC} ${M}This module should ONLY be used on your Exit Node (Kharej).${NC}"
    echo -e "  ${DIM}│${NC} ${W}Iran servers deploy their OBFS automatically via MPorter.${NC}"
    echo -e "  ${DIM}│${NC}"
    
    echo -ne "  ${C}●${NC} ${W}Select Protocol [1: TLS | 2: Websocket (WS) | 3: WSS | q: Cancel]: ${NC}"; read t_proto
    [[ "$t_proto" == "q" || -z "$t_proto" ]] && return
    
    local method="relay+tls"
    [ "$t_proto" == "2" ] && method="relay+ws"
    [ "$t_proto" == "3" ] && method="relay+wss"

    echo -ne "  ${C}●${NC} ${W}Enter Stealth Port to listen on (e.g. 8443): ${NC}"; read s_port
    [ -z "$s_port" ] && return
    
    local cmd="/usr/local/bin/gost -L $method://:$s_port"
    echo "$cmd" > "$OBFS_DIR/server_main.conf"
    
    cat <<EOF > /usr/local/bin/mshield-runner.sh
#!/bin/bash
while true; do
\$cmd &
wait
done
EOF
    chmod +x /usr/local/bin/mshield-runner.sh
    
    cat <<EOF > "$SVC_FILE"
[Unit]
Description=MShield OBFS Stealth Receiver
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mshield-runner.sh
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable mshield-obfs >/dev/null 2>&1; systemctl restart mshield-obfs
    echo -e "\n  ${G}● Server OBFS Universal Receiver created! Listening on :${s_port}${NC}"
    
    if iptables -C INPUT -j MSHIELD >/dev/null 2>&1; then activate_firewall >/dev/null; fi
    sleep 3
}

list_obfs() {
    echo -e "\n  ${B}╭────────────────── Active Receiver Status ──────────────────╮${NC}"
    local has_rules=false
    
    if [ -f "$OBFS_DIR/server_main.conf" ]; then
        has_rules=true
        local s_port=$(grep -oP '://:\K[0-9]+' "$OBFS_DIR/server_main.conf" | head -n 1)
        printf "  ${B}│${NC}  ${Y}S1 ${NC} ${C}❯${NC} ${C}SERVER RCVR${NC} ${DIM}Listening on Stealth Port:${NC} ${W}%-12s${NC} ${B}│${NC}\n" "$s_port"
    fi
    
    if [ "$has_rules" = false ]; then echo -e "  ${B}│${NC}  ${DIM}No OBFS Receiver configured on this server.                 ${B}│${NC}"; fi
    echo -e "  ${B}├────────────────────────────────────────────────────────────┤${NC}"
    printf "  ${B}│${NC}  ${R}%-3s${NC} ${C}❯${NC} ${R}%-53s${NC} ${B}│${NC}\n" "rm" "Purge Receiver & Daemon"
    printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${DIM}%-53s${NC} ${B}│${NC}\n" "q" "Go Back"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select 'rm' or 'q': ${NC}"; read l_opt

    if [[ "$l_opt" == "rm" ]]; then
        systemctl stop mshield-obfs 2>/dev/null
        systemctl disable mshield-obfs 2>/dev/null
        rm -rf "$OBFS_DIR"
        if iptables -C INPUT -j MSHIELD >/dev/null 2>&1; then activate_firewall >/dev/null; fi
        echo -e "  ${G}● Universal Receiver completely wiped.${NC}"; sleep 1.5
    fi
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ FIREWALL & STEALTH ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Activate Zero-Trust Firewall${NC}  ${DIM}(Auto-Protect Open Ports)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Disable Firewall${NC}              ${DIM}(Revert to open WAN)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Deploy OBFS Universal Rcvr${NC}    ${DIM}(ONLY FOR KHAREJ SERVER)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Manage Receiver Status${NC}        ${DIM}(View/Delete)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MShield ❯❯ ${NC}"; read opt
    case $opt in
        1) activate_firewall ;;
        2) disable_firewall ;;
        3) deploy_receiver ;;
        4) list_obfs ;;
        0) exit 0 ;;
    esac
done
