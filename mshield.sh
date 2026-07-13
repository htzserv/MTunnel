#!/bin/bash
# --- MDesign Modular Core (mshield.sh) | Zero-Trust Firewall & L2TP Aware v2.4.0 ---

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
    if systemctl is-active --quiet mshield-obfs.service 2>/dev/null; then obfs_stat="${C}LISTENING${NC}"; fi

    clear; echo ""
    local str1=" MShield Zero-Trust Firewall 2.4.0 "
    local raw_len=$(( ${#str1} + 4 + ${#s_ip} ))
    local pad=$(( 92 - raw_len - 38 ))
    [ "$pad" -lt 0 ] && pad=0
    local padding=$(printf '%*s' "$pad" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ FW:${NC} ${fw_stat} ${DIM}│ OBFS Rx:${NC} ${obfs_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

activate_firewall() {
    iptables -F MSHIELD 2>/dev/null; iptables -X MSHIELD 2>/dev/null
    iptables -D INPUT -j MSHIELD 2>/dev/null
    
    iptables -N MSHIELD
    iptables -A MSHIELD -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A MSHIELD -i lo -j ACCEPT
    iptables -A MSHIELD -p icmp -j ACCEPT
    iptables -A MSHIELD -p tcp --dport 22 -j ACCEPT
    
    # 🌟 استثنا کردن پورت‌های L2TP 🌟
    for conf in /etc/ml2tp/tunnels/*.conf; do
        [ -f "$conf" ] && source "$conf"
        [ -n "$TUN_PORT" ] && iptables -A MSHIELD -p udp --dport "$TUN_PORT" -m comment --comment "MSHIELD_L2TP" -j ACCEPT
    done

    # استثنا کردن آی‌پی‌های GRE و VXLAN
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf; do
        [ -f "$conf" ] && source "$conf"
        [ -n "$REMOTE_PUB" ] && iptables -A MSHIELD -s "$REMOTE_PUB" -j ACCEPT
        [ -n "$T_REMOTE" ] && iptables -A MSHIELD -s "$T_REMOTE" -j ACCEPT
    done
    
    [ -f "/etc/wireguard/wg0.conf" ] && iptables -A MSHIELD -p udp --dport 51820 -j ACCEPT
    
    if [ -f "/etc/mweb/web.conf" ]; then
        source "/etc/mweb/web.conf" 2>/dev/null
        [ -n "$WEB_PORT" ] && iptables -A MSHIELD -p tcp --dport "$WEB_PORT" -j ACCEPT
    fi
    
    iptables -A MSHIELD -j DROP
    iptables -I INPUT 1 -j MSHIELD
    
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
}

disable_firewall() {
    iptables -D INPUT -j MSHIELD 2>/dev/null
    iptables -F MSHIELD 2>/dev/null
    iptables -X MSHIELD 2>/dev/null
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
}

# --- (بخش‌های مخفی‌ساز MShield-OBFS دقیقاً مشابه قبل) ---
build_obfs_rx() {
    cat <<'EOF' > /usr/local/bin/mshield-obfs.sh
#!/bin/bash
iptables -t nat -S PREROUTING 2>/dev/null | grep "MSHIELD_OBFS" | sed 's/-A /-D /' | while read rule; do iptables -t nat $rule; done
[ -f /etc/mshield/obfs/nat.sh ] && source /etc/mshield/obfs/nat.sh 2>/dev/null
[ -f /etc/mshield/obfs/gost.sh ] && source /etc/mshield/obfs/gost.sh 2>/dev/null
wait
EOF
    chmod +x /usr/local/bin/mshield-obfs.sh
    cat <<'EOF' > "$SVC_FILE"
[Unit]
Description=MShield Universal OBFS Receiver
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mshield-obfs.sh
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable mshield-obfs >/dev/null 2>&1; systemctl restart mshield-obfs >/dev/null 2>&1
}

configure_receiver() {
    draw_header
    echo -e "\n  ${DIM}┌─[ KHAREJ UNIVERSAL RECEIVER (OBFS) ]${NC}"
    echo -e "  ${C}●${NC} ${W}Receive stealth traffic from Iran and unwrap it back to local ports.${NC}\n"
    
    if [ ! -f /usr/local/bin/gost ]; then
        echo -e "  ${DIM}● Deploying Gost Engine...${NC}"
        wget -qO /tmp/g.gz https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
        gzip -d /tmp/g.gz; mv /tmp/g /usr/local/bin/gost; chmod +x /usr/local/bin/gost
    fi

    echo -ne "  ${C}●${NC} ${W}Listening Stealth Port (e.g. 443): ${NC}"; read stealth_port
    echo -ne "  ${C}●${NC} ${W}Select Protocol [1: TLS | 2: WS | 3: WSS] (Default 1): ${NC}"; read proto
    local method="tls"; [ "$proto" == "2" ] && method="ws"; [ "$proto" == "3" ] && method="wss"
    
    echo -ne "  ${C}●${NC} ${W}Target Local Ports to unwrap to (e.g. 80,443): ${NC}"; read target_ports
    
    echo "/usr/local/bin/gost -L $method://:$stealth_port &" >> "$OBFS_DIR/gost.sh"
    iptables -A MSHIELD -p tcp --dport "$stealth_port" -j ACCEPT 2>/dev/null
    
    for p in $(echo "$target_ports" | tr ',' ' '); do
        local rand_port=$((30000 + p)); [ "$rand_port" -gt 65535 ] && rand_port=$(( p + 10000 ))
        echo "iptables -t nat -A PREROUTING -p tcp --dport $rand_port -m comment --comment \"MSHIELD_OBFS\" -j REDIRECT --to-ports $p" >> "$OBFS_DIR/nat.sh"
    done
    
    build_obfs_rx
    if iptables -C INPUT -j MSHIELD >/dev/null 2>&1; then activate_firewall >/dev/null; fi
    echo -e "\n  ${G}● Receiver configured and listening on port $stealth_port!${NC}"; sleep 1.5
}

remove_receiver() {
    draw_header
    echo -e "\n  ${DIM}┌─[ REMOVE RECEIVER ]${NC}"
    echo -ne "  ${C}●${NC} ${W}Type 'rm' to confirm deletion: ${NC}"; read l_opt
    if [[ "$l_opt" == "rm" ]]; then
        systemctl stop mshield-obfs 2>/dev/null; systemctl disable mshield-obfs 2>/dev/null
        rm -rf "$OBFS_DIR"
        if iptables -C INPUT -j MSHIELD >/dev/null 2>&1; then activate_firewall >/dev/null; fi
        echo -e "  ${G}● Receiver wiped.${NC}"; sleep 1.5
    fi
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ FIREWALL & STEALTH ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Activate Zero-Trust Firewall${NC}  ${DIM}(Auto-Protect Open Ports)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Disable Firewall${NC}              ${DIM}(Revert to open WAN)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Setup Kharej OBFS Receiver${NC}    ${DIM}(Listen for Iran tunnels)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${R}Remove OBFS Receiver${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back to Main Menu${NC}\n"
    echo -ne "  ${C}MSHIELD ❯❯ ${NC}"; read opt

    case $opt in
        1) activate_firewall; echo -e "\n  ${G}● Firewall ENABLED. Server is now locked down!${NC}"; sleep 1.5 ;;
        2) disable_firewall; echo -e "\n  ${Y}● Firewall DISABLED. Server is open.${NC}"; sleep 1.5 ;;
        3) configure_receiver ;;
        4) remove_receiver ;;
        0) break ;;
    esac
done
