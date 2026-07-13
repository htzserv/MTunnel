#!/bin/bash
# --- MDesign Modular Core (mbackhaul.sh) | Backhaul Multiplexer Engine v2.0.0 (Multi-Protocol) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mbackhaul/tunnels"
SERVICE_TPL="/etc/systemd/system/mbackhaul@.service"
LOCAL_DIR="/root/mtunnel/packages"

REPO_PKGS="https://raw.githubusercontent.com/htzserv/MTunnel/main/packages"

mkdir -p "$CONF_DIR" "$LOCAL_DIR" 2>/dev/null

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

check_binary() {
    if ! command -v bh >/dev/null 2>&1; then
        if [ -f "/usr/local/bin/bh" ]; then chmod +x /usr/local/bin/bh; return; fi
        
        echo -e "\n  ${Y}● Fetching 'bh' (Backhaul Engine) from GitHub packages folder...${NC}"
        wget -qO "$LOCAL_DIR/bh" "$REPO_PKGS/bh"
        
        if [ -s "$LOCAL_DIR/bh" ]; then
            cp "$LOCAL_DIR/bh" /usr/local/bin/bh
            chmod +x /usr/local/bin/bh
            echo -e "  ${G}● Engine installed successfully!${NC}"
        else
            echo -e "  ${R}● FATAL ERROR: Failed to download 'bh'! Make sure it's in the 'packages' folder on GitHub.${NC}"
            sleep 3; exit 1
        fi
    fi
}

apply_service() {
    cat <<EOF > "$SERVICE_TPL"
[Unit]
Description=MBackhaul Multiplexer (%i)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/bh -c $CONF_DIR/%i.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

draw_header() {
    local s_ip=$(get_local_ip); local active=0
    for conf in "$CONF_DIR"/*.toml; do [ -f "$conf" ] && ((active++)); done
    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MBackhaul Multiplexer Engine v2.0.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}NODES:${NC} ${G}${active}${NC} ${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
}

list_nodes() {
    echo -e "\n  ${Y}● Active Backhaul Nodes:${NC}"
    local count=0
    for conf in "$CONF_DIR"/*.toml; do
        [ ! -f "$conf" ] && continue
        ((count++))
        local name=$(basename "$conf" .toml)
        local status="${R}OFFLINE${NC}"; systemctl is-active --quiet "mbackhaul@$name" && status="${G}ONLINE${NC}"
        
        local mode="Unknown"; local port=""; local remote=""; local proto="tcp"
        if grep -q "\[server\]" "$conf"; then 
            mode="${M}KHAREJ (Server)${NC}"
            port=$(grep 'bind =' "$conf" | grep -oP ':[0-9]+' | head -1 | tr -d ':')
            proto=$(grep 'bind =' "$conf" | grep -oP '"\K[a-zA-Z]+(?=://)')
        elif grep -q "\[client\]" "$conf"; then 
            mode="${C}IRAN (Client)${NC}"
            remote=$(grep 'remote =' "$conf" | grep -oP '"\K[^"]+')
            proto=$(grep 'remote =' "$conf" | grep -oP '"\K[a-zA-Z]+(?=://)')
        fi
        
        [ -z "$proto" ] && proto="tcp"

        echo -e "  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC} ${DIM}Node Name :${NC} ${W}$name${NC}  ${DIM}Status:${NC} $status"
        echo -e "  ${B}│${NC} ${DIM}Mode      :${NC} $mode"
        echo -e "  ${B}│${NC} ${DIM}Protocol  :${NC} ${Y}${proto^^}${NC}"
        [ -n "$port" ] && echo -e "  ${B}│${NC} ${DIM}Bind Port :${NC} ${Y}$port${NC}"
        [ -n "$remote" ] && echo -e "  ${B}│${NC} ${DIM}Target IP :${NC} ${Y}$remote${NC}"
        
        if grep -q "\[\[client.ports\]\]" "$conf"; then
            local ports=$(grep 'local =' "$conf" | grep -oP ':\K[0-9]+' | tr -d '"' | paste -sd "," -)
            echo -e "  ${B}│${NC} ${DIM}Fwd Ports :${NC} ${G}$ports${NC}"
        fi
        echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    done
    [ "$count" -eq 0 ] && echo -e "  ${DIM}No Backhaul nodes configured yet.${NC}"
}

select_protocol() {
    echo -e "\n  ${DIM}┌─[ BACKHAUL TRANSPORT PROTOCOL ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}TCP${NC}    ${DIM}(Standard Raw TCP)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}TCPMUX${NC} ${DIM}(Multiplexed TCP, Excellent for Iran)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}WS${NC}     ${DIM}(WebSocket, CDN & HTTP friendly)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}WSS${NC}    ${DIM}(Secure WS, Encrypted)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}5${NC} ${DIM}❯${NC} ${R}GRPC${NC}   ${DIM}(gRPC Transport)${NC}"
    echo -ne "  ${C}Select Protocol [Default 1] ❯❯ ${NC}"; read p_opt
    
    case $p_opt in
        2) scheme="tcpmux"; s_suffix=""; c_suffix="" ;;
        3) scheme="ws"; s_suffix="/?path=/mdesign"; c_suffix="/?path=/mdesign" ;;
        4) scheme="wss"; s_suffix="/?path=/mdesign"; c_suffix="/?path=/mdesign&insecure=true" ;;
        5) scheme="grpc"; s_suffix=""; c_suffix="?insecure=true" ;;
        *) scheme="tcp"; s_suffix=""; c_suffix="" ;;
    esac
}

while true; do
    draw_header; list_nodes
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${M}Setup KHAREJ Node${NC} ${DIM}(Server Mode)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Setup IRAN Node${NC}   ${DIM}(Client Mode + Port Forwarding)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Delete Node${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MBACKHAUL ❯❯ ${NC}"; read opt

    case $opt in
        1)
           check_binary
           echo -ne "\n  ${C}●${NC} ${W}Node Name (e.g. bh_kharej): ${NC}"; read b_name
           echo -ne "  ${C}●${NC} ${W}Listen Port for Backhaul Tunnel (e.g. 7000): ${NC}"; read b_port
           echo -ne "  ${C}●${NC} ${W}Secret Token (Password): ${NC}"; read b_token
           select_protocol
           
           bind_url="${scheme}://0.0.0.0:${b_port}${s_suffix}"
           conf_path="$CONF_DIR/${b_name}.toml"
           
           cat <<EOF > "$conf_path"
[server]
bind = "$bind_url"
token = "$b_token"
channel_size = 4096
EOF
           apply_service; systemctl enable "mbackhaul@$b_name" >/dev/null 2>&1; systemctl restart "mbackhaul@$b_name"
           echo -e "\n  ${G}● Kharej Server Node Deployed successfully using [${scheme^^}]!${NC}"; sleep 1.5 ;;
           
        2)
           check_binary
           echo -ne "\n  ${C}●${NC} ${W}Node Name (e.g. bh_iran): ${NC}"; read b_name
           echo -ne "  ${C}●${NC} ${W}Kharej Server Public IP: ${NC}"; read r_ip
           echo -ne "  ${C}●${NC} ${W}Kharej Backhaul Port (e.g. 7000): ${NC}"; read r_port
           echo -ne "  ${C}●${NC} ${W}Secret Token (Must match Kharej): ${NC}"; read b_token
           echo -ne "  ${C}●${NC} ${W}Multiplex Connections [Default: 8]: ${NC}"; read b_conn; b_conn=${b_conn:-8}
           echo -ne "  ${C}●${NC} ${W}Ports to forward (e.g. 80,443,2053): ${NC}"; read raw_ports
           select_protocol
           
           remote_url="${scheme}://${r_ip}:${r_port}${c_suffix}"
           conf_path="$CONF_DIR/${b_name}.toml"
           
           cat <<EOF > "$conf_path"
[client]
remote = "$remote_url"
token = "$b_token"
connections = $b_conn
EOF
           clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
           for p in $clean_ports; do
               cat <<EOF >> "$conf_path"

[[client.ports]]
local = ":$p"
remote = "127.0.0.1:$p"
EOF
           done
           
           apply_service; systemctl enable "mbackhaul@$b_name" >/dev/null 2>&1; systemctl restart "mbackhaul@$b_name"
           echo -e "\n  ${G}● Iran Client Node Deployed and Ports Mapped using [${scheme^^}]!${NC}"; sleep 1.5 ;;
           
        3)
           configs=($(ls "$CONF_DIR"/*.toml 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Node to Delete ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .toml)"; done
           echo -e "  ${B}╰───────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Index (or 'all'): ${NC}"; read del_idx
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do
                   name=$(basename "$conf" .toml)
                   systemctl stop "mbackhaul@$name" 2>/dev/null; systemctl disable "mbackhaul@$name" 2>/dev/null
                   rm -f "$conf"
               done
           elif [[ -n "${configs[$del_idx]}" ]]; then
               name=$(basename "${configs[$del_idx]}" .toml)
               systemctl stop "mbackhaul@$name" 2>/dev/null; systemctl disable "mbackhaul@$name" 2>/dev/null
               rm -f "${configs[$del_idx]}"
           fi
           echo -e "  ${G}● Purged!${NC}"; sleep 1 ;;
        0) break ;;
    esac
done
