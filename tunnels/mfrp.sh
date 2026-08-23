#!/bin/bash
# --- MFRP Reverse Proxy Matrix (mfrp.sh) | MDesign Core v2.5.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
FRP_DIR="/etc/frp"
FRP_S_CONF="${FRP_DIR}/frps.toml"
FRP_C_CONF="${FRP_DIR}/frpc.toml"
LOCAL_DIR="/root/mtunnel"

if [ ! -d "$FRP_DIR" ]; then mkdir -p "$FRP_DIR" 2>/dev/null; fi

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

check_frp_binaries() {
    if [ ! -f "/usr/local/bin/frps" ] || [ ! -f "/usr/local/bin/frpc" ]; then
        mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
        if [ -s "$LOCAL_DIR/packages/frps" ] && [ -s "$LOCAL_DIR/packages/frpc" ]; then
            cp "$LOCAL_DIR/packages/frps" /usr/local/bin/frps
            cp "$LOCAL_DIR/packages/frpc" /usr/local/bin/frpc
            chmod +x /usr/local/bin/frps /usr/local/bin/frpc
        else
            wget -qO "/tmp/frp.tar.gz" "https://github.com/fatedier/frp/releases/download/v0.58.0/frp_0.58.0_linux_amd64.tar.gz" >/dev/null 2>&1
            if [ -s "/tmp/frp.tar.gz" ]; then
                tar -xzf "/tmp/frp.tar.gz" -C "/tmp/"
                cp /tmp/frp_*_linux_amd64/frps "$LOCAL_DIR/packages/"
                cp /tmp/frp_*_linux_amd64/frpc "$LOCAL_DIR/packages/"
                rm -rf "/tmp/frp.tar.gz" /tmp/frp_*_linux_amd64
                cp "$LOCAL_DIR/packages/frps" /usr/local/bin/frps
                cp "$LOCAL_DIR/packages/frpc" /usr/local/bin/frpc
                chmod +x /usr/local/bin/frps /usr/local/bin/frpc
            fi
        fi
    fi
}

draw_mfrp_header() {
    local s_ip=$(get_local_ip)
    local active_role="${DIM}Standby${NC}"
    local link_status="${DIM}OFFLINE${NC}"
    local raw_role="Standby"
    local raw_link="OFFLINE"

    if systemctl is-active --quiet frps 2>/dev/null; then
        active_role="${G}Server (Iran)${NC}"
        raw_role="Server (Iran)"
        local b_port=$(awk -F'=' '/^bindPort/ {print $2}' "$FRP_S_CONF" 2>/dev/null | tr -d ' ')
        if [ -n "$b_port" ] && ss -tn state established 2>/dev/null | grep -q ":${b_port}\b"; then
            link_status="${G}● CONNECTED${NC}"; raw_link="● CONNECTED"
        else
            link_status="${Y}○ WAITING FOR KHAREJ${NC}"; raw_link="○ WAITING FOR KHAREJ"
        fi
    elif systemctl is-active --quiet frpc 2>/dev/null; then
        active_role="${M}Client (Kharej)${NC}"
        raw_role="Client (Kharej)"
        local s_port=$(awk -F'=' '/^serverPort/ {print $2}' "$FRP_C_CONF" 2>/dev/null | tr -d ' ')
        if [ -n "$s_port" ] && ss -tn state established 2>/dev/null | grep -q ":${s_port}\b"; then
            link_status="${G}● ESTABLISHED${NC}"; raw_link="● ESTABLISHED"
        else
            link_status="${R}○ CONNECTING TO IRAN...${NC}"; raw_link="○ CONNECTING TO IRAN..."
        fi
    fi

    clear; echo ""
    local raw_text=" MFRP 2.5.0 │ IP: $s_ip │ Role: $raw_role │ Link: $raw_link "
    local pad_len=$(( 90 - ${#raw_text} )); if (( pad_len < 0 )); then pad_len=0; fi
    local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MFRP 2.5.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}Role:${NC} ${active_role} ${B}│${NC} ${DIM}Link:${NC} ${link_status}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

deploy_frp_server() {
    check_frp_binaries
    if [ ! -d "$FRP_DIR" ]; then mkdir -p "$FRP_DIR" 2>/dev/null; fi
    
    echo -e "\n  ${DIM}┌─[ DEPLOY IRAN NODE (FRP Server) ]${NC}"
    echo -ne "  ${C}●${NC} ${W}FRP Bind Port (e.g. 7000): ${NC}"; read b_port
    b_port=$(echo "$b_port" | tr -d '\r' | tr -d ' '); [ -z "$b_port" ] && b_port=7000
    
    echo -ne "  ${C}●${NC} ${W}Secret Authentication Token: ${NC}"; read auth_token
    auth_token=$(echo "$auth_token" | tr -d '\r' | tr -d ' '); [ -z "$auth_token" ] && auth_token="MDesignSecure123"

    echo -ne "  ${C}●${NC} ${W}Ports to open in IRAN Firewall for users (e.g. 4001,4002): ${NC}"; read u_ports
    u_ports=$(echo "$u_ports" | tr -d '\r')

    timedatectl set-ntp true >/dev/null 2>&1
    iptables -I INPUT -p tcp --dport "$b_port" -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport "$b_port" -j ACCEPT 2>/dev/null

    if [ -n "$u_ports" ]; then
        local clean_u=$(echo "$u_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
        for p in $clean_u; do
            iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
            iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null
        done
    fi

    cat <<EOF > "$FRP_S_CONF"
bindPort = $b_port
auth.method = "token"
auth.token = "$auth_token"
EOF

    cat <<EOF > /etc/systemd/system/frps.service
[Unit]
Description=FRP Server (MDesign Iran Node)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c $FRP_S_CONF
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload; systemctl enable frps >/dev/null 2>&1; systemctl restart frps
    echo -e "\n  ${G}● FRPS Server deployed successfully on IRAN!${NC}"
    sleep 3
}

deploy_frp_client() {
    check_frp_binaries
    if [ ! -d "$FRP_DIR" ]; then mkdir -p "$FRP_DIR" 2>/dev/null; fi

    echo -e "\n  ${DIM}┌─[ DEPLOY KHAREJ NODE (FRP Client) ]${NC}"
    echo -ne "  ${C}●${NC} ${W}Iran Server IP: ${NC}"; read server_ip
    server_ip=$(echo "$server_ip" | tr -d '\r' | tr -d ' '); [ -z "$server_ip" ] && return
    
    echo -ne "  ${C}●${NC} ${W}Iran Bind Port (e.g. 7000): ${NC}"; read server_port
    server_port=$(echo "$server_port" | tr -d '\r' | tr -d ' '); [ -z "$server_port" ] && server_port=7000
    
    echo -ne "  ${C}●${NC} ${W}Secret Authentication Token: ${NC}"; read auth_token
    auth_token=$(echo "$auth_token" | tr -d '\r' | tr -d ' '); [ -z "$auth_token" ] && auth_token="MDesignSecure123"

    echo -ne "  ${C}●${NC} ${W}Local Forwarding Target IP [127.0.0.1]: ${NC}"; read fwd_ip
    fwd_ip=$(echo "$fwd_ip" | tr -d '\r' | tr -d ' '); [ -z "$fwd_ip" ] && fwd_ip="127.0.0.1"

    cat <<EOF > "$FRP_C_CONF"
serverAddr = "$server_ip"
serverPort = $server_port
auth.method = "token"
auth.token = "$auth_token"
EOF

    echo -ne "\n  ${C}●${NC} ${W}Enter ports to push to IRAN (e.g. 4001,4002): ${NC}"; read ports
    ports=$(echo "$ports" | tr -d '\r')
    local clean_ports=$(echo "$ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)

    for p in $clean_ports; do
        cat <<EOF >> "$FRP_C_CONF"

[[proxies]]
name = "mdesign_tcp_$p"
type = "tcp"
localIP = "$fwd_ip"
localPort = $p
remotePort = $p

[[proxies]]
name = "mdesign_udp_$p"
type = "udp"
localIP = "$fwd_ip"
localPort = $p
remotePort = $p
EOF
    done

    cat <<EOF > /etc/systemd/system/frpc.service
[Unit]
Description=FRP Client (MDesign Kharej Node)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c $FRP_C_CONF
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload; systemctl enable frpc >/dev/null 2>&1; systemctl restart frpc
    echo -e "\n  ${G}● KHAREJ Node (FRPC) configured and connection initiated!${NC}"; sleep 2
}

while true; do
    draw_mfrp_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Configure as IRAN NODE (FRP Server)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Configure as KHAREJ NODE (FRP Client)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Uninstall / Stop FRP Services${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    echo -ne "  ${C}MFRP ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1) deploy_frp_server ;; 2) deploy_frp_client ;;
        3) 
           systemctl stop frps frpc 2>/dev/null; systemctl disable frps frpc 2>/dev/null
           rm -rf /etc/frp /etc/systemd/system/frps.service /etc/systemd/system/frpc.service
           systemctl daemon-reload; echo -e "  ${G}● FRP Services wiped.${NC}"; sleep 1.5 ;;
        0) break ;;
    esac
done
