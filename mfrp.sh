cat << 'EOF_MFRP' > /usr/bin/mfrp
#!/bin/bash
# --- MFRP Reverse Proxy Matrix (mfrp.sh) | MDesign Core v1.1.1 (UI Bugfix) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
FRP_DIR="/etc/frp"
FRP_S_CONF="${FRP_DIR}/frps.toml"
FRP_C_CONF="${FRP_DIR}/frpc.toml"
LOCAL_DIR="/root/mtunnel"

mkdir -p "$FRP_DIR" 2>/dev/null

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_percentage() {
    local pid=$1; local text=$2; local progress=0
    tput civis
    while kill -0 $pid 2>/dev/null; do
        ((progress++))
        if (( progress > 95 )); then progress=95; fi
        printf "\r  %b⟳%b %b%-25s%b %b%3d%%%%%b" "$C" "$NC" "$W" "$text" "$NC" "$C" "$progress" "$NC"
        sleep 0.2
    done
    printf "\r  %b✔%b %b%-25s%b %b100%%%%%b \n" "$G" "$NC" "$W" "$text" "$NC" "$G" "$NC"
    tput cnorm
}

check_frp_binaries() {
    if [ ! -f "/usr/local/bin/frps" ] || [ ! -f "/usr/local/bin/frpc" ]; then
        echo -e ""
        (
            mkdir -p "$LOCAL_DIR" 2>/dev/null
            if [ ! -f "$LOCAL_DIR/frps" ] || [ ! -f "$LOCAL_DIR/frpc" ]; then
                wget -qO "/tmp/frp.tar.gz" "https://github.com/fatedier/frp/releases/download/v0.58.0/frp_0.58.0_linux_amd64.tar.gz" >/dev/null 2>&1
                tar -xzf "/tmp/frp.tar.gz" -C "/tmp/"
                cp /tmp/frp_*_linux_amd64/frps "$LOCAL_DIR/"
                cp /tmp/frp_*_linux_amd64/frpc "$LOCAL_DIR/"
                rm -rf "/tmp/frp.tar.gz" /tmp/frp_*_linux_amd64
            fi
            cp "$LOCAL_DIR/frps" /usr/local/bin/frps
            cp "$LOCAL_DIR/frpc" /usr/local/bin/frpc
            chmod +x /usr/local/bin/frps /usr/local/bin/frpc
        ) >/dev/null 2>&1 &
        draw_percentage $! "Deploying FRP Binaries"
        sleep 1
    fi
}

draw_mfrp_header() {
    local s_ip=$(get_local_ip)
    local frps_stat="${DIM}OFFLINE${NC}"; local raw_frps="OFFLINE"
    if systemctl is-active --quiet frps 2>/dev/null; then frps_stat="${G}ONLINE${NC}"; raw_frps="ONLINE"; fi
    
    local frpc_stat="${DIM}OFFLINE${NC}"; local raw_frpc="OFFLINE"
    if systemctl is-active --quiet frpc 2>/dev/null; then frpc_stat="${G}ONLINE${NC}"; raw_frpc="ONLINE"; fi

    clear; echo ""
    local str1=" MFRP Core 1.1.1 "
    local str2=" IP: $s_ip "
    local str3=" Srv (Kharej): $raw_frps "
    local str4=" Cli (Iran): $raw_frpc "
    
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} + 1 + ${#str4} ))
    local pad_len=$(( 92 - raw_len ))
    if (( pad_len < 0 )); then pad_len=0; fi
    local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} Srv (Kharej):${NC} ${frps_stat} ${B}│${NC}${DIM} Cli (Iran):${NC} ${frpc_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

deploy_frp_server() {
    check_frp_binaries
    echo -e "\n  ${DIM}┌─[ DEPLOY FRP SERVER (KHAREJ) ]${NC}"
    echo -ne "  ${C}●${NC} ${W}FRP Bind Port (e.g. 7000): ${NC}"; read b_port
    [ -z "$b_port" ] && b_port=7000
    
    echo -ne "  ${C}●${NC} ${W}Secret Authentication Token: ${NC}"; read auth_token
    [ -z "$auth_token" ] && auth_token="MDesignSecure123"

    cat <<EOF > "$FRP_S_CONF"
bindPort = $b_port

[auth]
method = "token"
token = "$auth_token"
EOF

    echo -ne "  ${C}●${NC} ${W}Enable FRP Built-in Web Dashboard? (y/n) [y]: ${NC}"; read en_dash
    if [[ "$en_dash" != "n" ]]; then
        echo -ne "  ${C}  ├─${NC} ${W}Dashboard Port (e.g. 7500): ${NC}"; read d_port
        [ -z "$d_port" ] && d_port=7500
        echo -ne "  ${C}  ├─${NC} ${W}Username [admin]: ${NC}"; read d_user
        [ -z "$d_user" ] && d_user="admin"
        echo -ne "  ${C}  └─${NC} ${W}Password [admin]: ${NC}"; read d_pass
        [ -z "$d_pass" ] && d_pass="admin"
        
        cat <<EOF >> "$FRP_S_CONF"

webServer.addr = "0.0.0.0"
webServer.port = $d_port
webServer.user = "$d_user"
webServer.password = "$d_pass"
EOF
        dash_msg="  ${DIM}├─ Web Dashboard: ${C}http://$(get_local_ip):${d_port}${NC} ${DIM}(u: ${d_user} | p: ${d_pass})${NC}"
    fi

    cat <<EOF > /etc/systemd/system/frps.service
[Unit]
Description=FRP Server (MDesign Kharej Node)
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
    echo -e "\n  ${G}● FRPS Server deployed successfully!${NC}"
    echo -e "  ${DIM}├─ Server IP: ${W}$(get_local_ip)${NC}"
    echo -e "  ${DIM}├─ Bind Port: ${Y}${b_port}${NC}"
    echo -e "  ${DIM}├─ Token: ${M}${auth_token}${NC}"
    [ -n "$dash_msg" ] && echo -e "$dash_msg"
    sleep 3.5
}

deploy_frp_client() {
    check_frp_binaries
    echo -e "\n  ${DIM}┌─[ DEPLOY FRP CLIENT (IRAN) & MAP PORTS ]${NC}"
    echo -ne "  ${C}●${NC} ${W}Kharej Server IP: ${NC}"; read server_ip
    [ -z "$server_ip" ] && return
    
    echo -ne "  ${C}●${NC} ${W}Kharej Bind Port (e.g. 7000): ${NC}"; read server_port
    [ -z "$server_port" ] && server_port=7000
    
    echo -ne "  ${C}●${NC} ${W}Secret Authentication Token: ${NC}"; read auth_token
    [ -z "$auth_token" ] && auth_token="MDesignSecure123"

    cat <<EOF > "$FRP_C_CONF"
serverAddr = "$server_ip"
serverPort = $server_port

[auth]
method = "token"
token = "$auth_token"
EOF

    echo -ne "\n  ${C}●${NC} ${W}Enter local ports to forward (comma separated, e.g. 80,443): ${NC}"; read ports
    local clean_ports=$(echo "$ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)

    for p in $clean_ports; do
        cat <<EOF >> "$FRP_C_CONF"

[[proxies]]
name = "mdesign_tcp_$p"
type = "tcp"
localIP = "127.0.0.1"
localPort = $p
remotePort = $p

[[proxies]]
name = "mdesign_udp_$p"
type = "udp"
localIP = "127.0.0.1"
localPort = $p
remotePort = $p
EOF
    done

    cat <<EOF > /etc/systemd/system/frpc.service
[Unit]
Description=FRP Client (MDesign Iran Node)
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
    echo -e "\n  ${G}● FRPC Client configured and mapping injected!${NC}"
    echo -e "  ${DIM}└─ Ports Forwarded: ${Y}${clean_ports}${NC}"
    sleep 3
}

view_frp_config() {
    draw_mfrp_header
    echo -e "\n  ${DIM}┌─[ KHAREJ NODE (Server Config) ]${NC}"
    if [ -f "$FRP_S_CONF" ]; then cat "$FRP_S_CONF" | awk '{print "  " $0}'; else echo -e "  ${DIM}No configuration found.${NC}"; fi
    echo -e "\n  ${DIM}┌─[ IRAN NODE (Client Config) ]${NC}"
    if [ -f "$FRP_C_CONF" ]; then cat "$FRP_C_CONF" | awk '{print "  " $0}'; else echo -e "  ${DIM}No configuration found.${NC}"; fi
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

while true; do
    draw_mfrp_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Deploy as KHAREJ Node (Run FRP Server)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Deploy as IRAN Node & Map Ports (Run FRP Client)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}View Current FRP Configurations${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${R}Uninstall / Stop FRP Services${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    echo -ne "  ${C}MFRP ❯❯ ${NC}"; read opt

    case $opt in
        1) deploy_frp_server ;;
        2) deploy_frp_client ;;
        3) view_frp_config ;;
        4) 
           echo -ne "  ${R}● Stop and Remove all FRP settings? (y/n): ${NC}"; read confirm
           if [[ "$confirm" == "y" ]]; then
               systemctl stop frps frpc 2>/dev/null
               systemctl disable frps frpc 2>/dev/null
               rm -rf /etc/frp /etc/systemd/system/frps.service /etc/systemd/system/frpc.service
               systemctl daemon-reload
               echo -e "  ${G}● FRP Services completely wiped.${NC}"; sleep 1.5
           fi ;;
        0) break ;;
    esac
done
EOF_MFRP
chmod +x /usr/bin/mfrp
