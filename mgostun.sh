#!/bin/bash
# --- MGostun Modular Core (mgostun.sh) | Gost Encapsulation Engine v1.0.1 (Offline Cache) ---
# [Developed for MDesign Ecosystem]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mgostun/tunnels"
SERVICE_TPL="/etc/systemd/system/mgostun@.service"
RUNNER_BIN="/usr/local/bin/mgostun-runner"
LOCAL_DIR="/root/mtunnel"

mkdir -p "$CONF_DIR"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

install_gost() {
    if [ ! -f "/usr/local/bin/gost" ]; then
        echo -e "\n  ${DIM}● Checking for Gost Engine...${NC}"
        mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
        
        if [ -f "$LOCAL_DIR/packages/gost" ]; then
            echo -e "  ${G}● Found in local cache! Installing offline...${NC}"
            cp "$LOCAL_DIR/packages/gost" /usr/local/bin/gost
            chmod +x /usr/local/bin/gost
        else
            echo -e "  ${Y}● Downloading from GitHub...${NC}"
            wget -qO /tmp/gost.gz "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz" >/dev/null 2>&1
            gzip -d /tmp/gost.gz
            mv /tmp/gost /usr/local/bin/gost
            chmod +x /usr/local/bin/gost
            cp /usr/local/bin/gost "$LOCAL_DIR/packages/gost" 2>/dev/null
        fi
    fi
}

setup_service() {
    cat <<'EOF' > "$RUNNER_BIN"
#!/bin/bash
NAME="$1"
source "/etc/mgostun/tunnels/${NAME}/meta.conf"
if [ "$TYPE" == "2" ]; then
    exec /usr/local/bin/gost -L "${PROTOCOL}://:${STEALTH_PORT}"
else
    ARGS=()
    IFS=',' read -ra P_ARR <<< "$PORTS"
    for p in "${P_ARR[@]}"; do
        ARGS+=( "-L=tcp://:${p}/127.0.0.1:${p}" "-L=udp://:${p}/127.0.0.1:${p}" )
    done
    exec /usr/local/bin/gost "${ARGS[@]}" -F "${PROTOCOL}://${REMOTE_IP}:${STEALTH_PORT}"
fi
EOF
    chmod +x "$RUNNER_BIN"

    cat <<EOF > "$SERVICE_TPL"
[Unit]
Description=Gost Encapsulation Tunnel (%i)
After=network.target

[Service]
Type=simple
ExecStart=$RUNNER_BIN %i
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
            if systemctl is-active --quiet mgostun@$t_name; then ((active_tunnels++)); fi
        fi
    done
    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MGost Encapsulation Engine v1.0.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}TUNNELS:${NC} ${G}${active_tunnels}${NC} ${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    for d in "$CONF_DIR"/*; do
        [ ! -d "$d" ] && continue
        local t_name=$(basename "$d")
        TYPE=""; T_NAME=""; PROTOCOL=""; STEALTH_PORT=""; REMOTE_IP=""; PORTS=""; source "$d/meta.conf"
        
        local role_text=$([ "$TYPE" == "1" ] && echo "IRAN (Client)" || echo "KHAREJ (Server)")
        local peer_text=$([ "$TYPE" == "1" ] && echo "${REMOTE_IP}:${STEALTH_PORT}" || echo "Waiting for Iran")
        local st_text="OFFLINE"; local st_color="${R}"
        if systemctl is-active --quiet mgostun@$t_name; then st_text="ONLINE "; st_color="${G}"; fi
        
        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} %b▼ Tunnel: %-35s%b ${DIM}Role:%b %-40s ${B}│${NC}\n" "${C}" "${t_name}" "${NC}" "${NC}" "${role_text}"
        echo -e "  ${B}├────────────────────────┬───────────────────────┬───────────────────────┬───────────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-22s${NC} ${B}│${NC} ${DIM}%-21s${NC} ${B}│${NC} ${DIM}%-21s${NC} ${B}│${NC} ${DIM}%-17s${NC} ${B}│${NC}\n" "PROTOCOL" "STEALTH ENDPOINT" "ENCAPSULATED PORTS" "STATUS"
        echo -e "  ${B}├────────────────────────┼───────────────────────┼───────────────────────┼───────────────────┤${NC}"
        local p_fmt="${PORTS:0:18}"; [ ${#PORTS} -gt 18 ] && p_fmt="${p_fmt}..."
        printf "  ${B}│${NC} ${M}%-22s${NC} ${B}│${NC} ${W}%-21s${NC} ${B}│${NC} ${Y}%-21s${NC} ${B}│${NC} %b%-17s%b ${B}│${NC}\n" "${PROTOCOL}" "${peer_text}" "${p_fmt:-None (Listening)}" "${st_color}" "${st_text}" "${NC}"
        echo -e "  ${B}╰────────────────────────┴───────────────────────┴───────────────────────┴───────────────────╯${NC}\n"
    done
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup New Gost Encapsulation Tunnel${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Delete Tunnels${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    echo -ne "  ${C}MGOSTUN ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1) 
           install_gost; setup_service
           echo -e "\n  ${DIM}┌─[ ENCAPSULATION DEPLOYMENT ]${NC}"
           echo -e "  ${DIM}│${NC} ${W}Info:${NC} Here ${G}IRAN${NC} connects to ${M}KHAREJ${NC} and encapsulates traffic securely."
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IRAN (Client) | 2:KHAREJ (Server) | q:Back]: ${NC}"; read s_type; s_type=$(echo "$s_type" | tr -d '\r'); [[ "$s_type" =~ ^[12q]$ ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do echo -ne "  ${C}●${NC} ${W}Tunnel Suffix Name (e.g. gs1): ${NC}"; read suffix; suffix=$(echo "$suffix" | tr -d '\r'); t_name="gost_$suffix"; break; done
           
           local r_ip="0.0.0.0"
           if [ "$s_type" == "1" ]; then
               echo -ne "  ${C}●${NC} ${W}Remote (KHAREJ) Public IP: ${NC}"; read r_ip; r_ip=$(echo "$r_ip" | tr -d '\r')
           fi
           
           echo -ne "  ${C}●${NC} ${W}Stealth Port (e.g. 443, 8443): ${NC}"; read t_port; t_port=$(echo "$t_port" | tr -d '\r')
           
           echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} relay+tls ${DIM}(Standard HTTPS Obfuscation)${NC}"
           echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} relay+ws  ${DIM}(Websocket Obfuscation)${NC}"
           echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} relay+wss ${DIM}(Secure Websocket)${NC}"
           echo -ne "  ${C}●${NC} ${W}Select Protocol: ${NC}"; read p_opt; p_opt=$(echo "$p_opt" | tr -d '\r')
           local proto="relay+tls"; [ "$p_opt" == "2" ] && proto="relay+ws"; [ "$p_opt" == "3" ] && proto="relay+wss"
           
           local t_ports=""
           if [ "$s_type" == "1" ]; then
               echo -ne "  ${C}●${NC} ${W}Target Ports to Encapsulate (Comma separated, e.g. 80,443): ${NC}"; read t_ports; t_ports=$(echo "$t_ports" | tr -d '\r')
           fi
           
           mkdir -p "$CONF_DIR/$t_name"
           echo -e "TYPE=$s_type\nT_NAME=$t_name\nPROTOCOL=$proto\nSTEALTH_PORT=$t_port\nREMOTE_IP=$r_ip\nPORTS=$t_ports" > "$CONF_DIR/$t_name/meta.conf"
           
           systemctl enable mgostun@$t_name >/dev/null 2>&1
           systemctl restart mgostun@$t_name
           
           echo -e "  ${G}● Gost Encapsulation Tunnel Deployed Successfully!${NC}"; sleep 1.5 ;;
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
                   systemctl stop mgostun@$t_name 2>/dev/null; systemctl disable mgostun@$t_name 2>/dev/null; rm -rf "$d"
               done
           elif [[ -n "${tunnels[$del_idx]}" ]]; then
               t_name=$(basename "${tunnels[$del_idx]}")
               systemctl stop mgostun@$t_name 2>/dev/null; systemctl disable mgostun@$t_name 2>/dev/null; rm -rf "${tunnels[$del_idx]}"
           fi; echo -e "  ${G}Purged!${NC}"; sleep 1 ;;
        0) break ;;
    esac
done
