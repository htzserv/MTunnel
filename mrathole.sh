#!/bin/bash
# --- MRathole Modular Core (mrathole.sh) | Rathole Reverse Tunnel v1.0.1 (Offline Cache) ---
# [Developed for MDesign Ecosystem]

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

install_rathole() {
    if [ ! -f "/usr/local/bin/rathole" ]; then
        echo -e "\n  ${DIM}● Checking for Rathole Engine...${NC}"
        mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
        
        if [ -f "$LOCAL_DIR/packages/rathole" ]; then
            echo -e "  ${G}● Found in local cache! Installing offline...${NC}"
            cp "$LOCAL_DIR/packages/rathole" /usr/local/bin/rathole
            chmod +x /usr/local/bin/rathole
        else
            echo -e "  ${Y}● Downloading from GitHub...${NC}"
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
            echo "" >> "$toml"
            echo "[server.services.p${p}_tcp]" >> "$toml"
            echo "type = \"tcp\"" >> "$toml"
            echo "bind_addr = \"0.0.0.0:${p}\"" >> "$toml"
            
            echo "" >> "$toml"
            echo "[server.services.p${p}_udp]" >> "$toml"
            echo "type = \"udp\"" >> "$toml"
            echo "bind_addr = \"0.0.0.0:${p}\"" >> "$toml"
        done
    else
        echo "[client]" >> "$toml"
        echo "remote_addr = \"${REMOTE_IP}:${LINK_PORT}\"" >> "$toml"
        echo "default_token = \"${TOKEN}\"" >> "$toml"
        
        IFS=',' read -ra P_ARR <<< "$PORTS"
        for p in "${P_ARR[@]}"; do
            echo "" >> "$toml"
            echo "[client.services.p${p}_tcp]" >> "$toml"
            echo "type = \"tcp\"" >> "$toml"
            echo "local_addr = \"127.0.0.1:${p}\"" >> "$toml"
            
            echo "" >> "$toml"
            echo "[client.services.p${p}_udp]" >> "$toml"
            echo "type = \"udp\"" >> "$toml"
            echo "local_addr = \"127.0.0.1:${p}\"" >> "$toml"
        done
    fi
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
    local s_ip=$(get_local_ip); local active_tunnels=0
    for d in "$CONF_DIR"/*; do
        if [ -d "$d" ]; then
            local t_name=$(basename "$d")
            if systemctl is-active --quiet mrathole@$t_name; then ((active_tunnels++)); fi
        fi
    done
    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MRathole Reverse Engine v1.0.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}TUNNELS:${NC} ${G}${active_tunnels}${NC} ${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    for d in "$CONF_DIR"/*; do
        [ ! -d "$d" ] && continue
        local t_name=$(basename "$d")
        TYPE=""; T_NAME=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; source "$d/meta.conf"
        
        local role_text=$([ "$TYPE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local peer_text=$([ "$TYPE" == "1" ] && echo "Waiting for Kharej" || echo "${REMOTE_IP}:${LINK_PORT}")
        local st_text="OFFLINE"; local st_color="${R}"
        if systemctl is-active --quiet mrathole@$t_name; then st_text="ONLINE "; st_color="${G}"; fi
        
        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} %b▼ Tunnel: %-35s%b ${DIM}Role:%b %-40s ${B}│${NC}\n" "${R}" "${t_name}" "${NC}" "${NC}" "${role_text}"
        echo -e "  ${B}├────────────────────────┬───────────────────────┬───────────────────────┬───────────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-22s${NC} ${B}│${NC} ${DIM}%-21s${NC} ${B}│${NC} ${DIM}%-21s${NC} ${B}│${NC} ${DIM}%-17s${NC} ${B}│${NC}\n" "LINK PORT" "PEER ENDPOINT" "FORWARDED PORTS" "STATUS"
        echo -e "  ${B}├────────────────────────┼───────────────────────┼───────────────────────┼───────────────────┤${NC}"
        local p_fmt="${PORTS:0:18}"; [ ${#PORTS} -gt 18 ] && p_fmt="${p_fmt}..."
        printf "  ${B}│${NC} ${C}%-22s${NC} ${B}│${NC} ${W}%-21s${NC} ${B}│${NC} ${Y}%-21s${NC} ${B}│${NC} %b%-17s%b ${B}│${NC}\n" "${LINK_PORT}" "${peer_text}" "${p_fmt:-None}" "${st_color}" "${st_text}" "${NC}"
        echo -e "  ${B}╰────────────────────────┴───────────────────────┴───────────────────────┴───────────────────╯${NC}\n"
    done
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${R}Setup New Reverse Tunnel (Rathole)${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Delete Tunnels${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    echo -ne "  ${C}MRATHOLE ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1) 
           install_rathole; setup_service
           echo -e "\n  ${DIM}┌─[ REVERSE DEPLOYMENT ]${NC}"
           echo -e "  ${DIM}│${NC} ${W}Info:${NC} In Reverse tunneling, ${G}IRAN${NC} acts as the Server (Entry), and ${M}KHAREJ${NC} dials in as Client (Exit)."
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IRAN (Server) | 2:KHAREJ (Client) | q:Back]: ${NC}"; read s_type; s_type=$(echo "$s_type" | tr -d '\r'); [[ "$s_type" =~ ^[12q]$ ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do echo -ne "  ${C}●${NC} ${W}Tunnel Suffix Name (e.g. rt1): ${NC}"; read suffix; suffix=$(echo "$suffix" | tr -d '\r'); t_name="rat_$suffix"; break; done
           
           local r_ip="0.0.0.0"
           if [ "$s_type" == "2" ]; then
               echo -ne "  ${C}●${NC} ${W}Remote (IRAN) Public IP: ${NC}"; read r_ip; r_ip=$(echo "$r_ip" | tr -d '\r')
           fi
           
           echo -ne "  ${C}●${NC} ${W}Tunnel Link Port (e.g. 5000): ${NC}"; read t_port; t_port=$(echo "$t_port" | tr -d '\r')
           
           local t_token=$(head -c 8 /dev/urandom | xxd -p)
           echo -ne "  ${C}●${NC} ${W}Secret Token [${Y}${t_token}${W}]: ${NC}"; read u_token; u_token=$(echo "$u_token" | tr -d '\r')
           [ -n "$u_token" ] && t_token="$u_token"
           
           echo -ne "  ${C}●${NC} ${W}Target Ports to Forward (Comma separated, e.g. 80,443): ${NC}"; read t_ports; t_ports=$(echo "$t_ports" | tr -d '\r')
           
           mkdir -p "$CONF_DIR/$t_name"
           echo -e "TYPE=$s_type\nT_NAME=$t_name\nLINK_PORT=$t_port\nREMOTE_IP=$r_ip\nTOKEN=$t_token\nPORTS=$t_ports" > "$CONF_DIR/$t_name/meta.conf"
           
           generate_toml "$t_name"
           systemctl enable mrathole@$t_name >/dev/null 2>&1
           systemctl restart mrathole@$t_name
           
           echo -e "  ${G}● Reverse Tunnel Deployed Successfully!${NC}"; sleep 1.5 ;;
        2) while true; do draw_header; show_monitor; read -t 2 -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        3)
           tunnels=($(ls -d "$CONF_DIR"/* 2>/dev/null))
           [ ${#tunnels[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Delete ─────────────────╮${NC}"
           for i in "${!tunnels[@]}"; do echo "  $i ❯ $(basename "${tunnels[$i]}")"; done
           echo -ne "  ${C}Index (or 'all'): ${NC}"; read del_idx; del_idx=$(echo "$del_idx" | tr -d '\r')
           if [[ "$del_idx" == "all" ]]; then
               for d in "${tunnels[@]}"; do
                   t_name=$(basename "$d")
                   systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null; rm -rf "$d"
               done
           elif [[ -n "${tunnels[$del_idx]}" ]]; then
               t_name=$(basename "${tunnels[$del_idx]}")
               systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null; rm -rf "${tunnels[$del_idx]}"
           fi; echo -e "  ${G}Purged!${NC}"; sleep 1 ;;
        0) break ;;
    esac
done
