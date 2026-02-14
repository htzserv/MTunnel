#!/bin/bash

# --- MGRE v3.0.1 | MDesign Tunneling Suite (Full Auto) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[1;36m'; W='\033[1;37m'; NC='\033[0m'

# Paths

INSTALL_PATH="/usr/bin/mgre"

CONF_FILE="/etc/mahan_tunnel.conf"

SERVICE_FILE="/etc/systemd/system/mgre.service"

# --- 1. CORE LOGIC ---

get_local_ip() {

    local ip=$(hostname -I | awk '{print $1}')

    echo "${ip:-Unknown}"

}

apply_tunnel() {

    [ ! -f "$CONF_FILE" ] && return

    source "$CONF_FILE"

    

    local t_name=$([ "$TYPE" == "1" ] && echo "greir" || echo "grekh")

    local local_tun=$([ "$TYPE" == "1" ] && echo "10.76.76.1" || echo "10.76.76.2")

    local mtu_val=$([ "$TYPE" == "1" ] && echo "1436" || echo "1476")

    

    # Clean up old interfaces

    ip tunnel del greir >/dev/null 2>&1; ip tunnel del grekh >/dev/null 2>&1

    

    # Establish Tunnel

    ip tunnel add "$t_name" mode gre remote "$REMOTE_PUB" local "$LOCAL_PUB" ttl 255

    ip link set "$t_name" up

    ip addr add "$local_tun"/30 dev "$t_name"

    ip link set dev "$t_name" mtu "$mtu_val"

    

    # MSS Clamping (Prevention of fragmentation)

    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$t_name" -j TCPMSS --set-mss $((mtu_val - 40)) >/dev/null 2>&1

    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$t_name" -j TCPMSS --set-mss $((mtu_val - 40))

}

# --- 2. AUTO-INSTALL SERVICE ---

install_service() {

    if [[ ! -f "$SERVICE_FILE" ]]; then

        cat <<EOF > "$SERVICE_FILE"

[Unit]

Description=MGRE MDesign Persistence

After=network.target

[Service]

ExecStart=$INSTALL_PATH --apply

Type=oneshot

RemainAfterExit=yes

[Install]

WantedBy=multi-user.target

EOF

        systemctl daemon-reload

        systemctl enable mgre.service >/dev/null 2>&1

    fi

}

# Daemon Trigger for Boot

if [[ "$1" == "--apply" ]]; then

    apply_tunnel

    exit 0

fi

# --- 3. UI LOGIC ---

draw_header() {

    [ -f "$CONF_FILE" ] && source "$CONF_FILE"

    local s_ip=$(get_local_ip)

    local active_if="None"; local remote_pub="N/A"; local status="${R}Offline${NC}"

    

    if ip link show greir >/dev/null 2>&1; then 

        active_if="greir"; remote_pub=$(ip tunnel show greir | awk '{print $4}'); status="${G}Online${NC}"

    elif ip link show grekh >/dev/null 2>&1; then 

        active_if="grekh"; remote_pub=$(ip tunnel show grekh | awk '{print $4}'); status="${G}Online${NC}"

    fi

    clear

    echo -e "${B}┌────────────────────────────────────────────────────────────────────────────────────────┐${NC}"

    echo -e "${B}│${NC} ${G}LOCAL IP:${NC} ${Y}${s_ip}${NC} | ${G}REMOTE:${NC} ${Y}${remote_pub}${NC} | ${G}IF:${NC} ${Y}${active_if}${NC} | ${G}STATUS:${NC} ${status} ${B}│${NC}"

    echo -e "${B}└────────────────────────────────────────────────────────────────────────────────────────┘${NC}"

}

# Start Service Engine

install_service

while true; do

    draw_header

    printf "  ${Y}[1]${NC} ${W}%-35s${NC}\n" "Establish/Update Tunnel"

    printf "  ${Y}[2]${NC} ${W}%-35s${NC}\n" "Detailed Latency Check"

    printf "  ${Y}[3]${NC} ${W}%-35s${NC}\n" "System Status & Uptime"

    printf "  ${Y}[4]${NC} ${W}%-35s${NC}\n" "Factory Reset & Delete"

    printf "  ${Y}[5]${NC} ${W}%-35s${NC}\n" "Exit"

    echo -ne "\n${B}Command >> ${NC}"

    read -t 30 opt

    [ $? -gt 128 ] && exit 0

    case $opt in

        1)

            echo -ne "${G}Mode [1:Iran | 2:Abroad]: ${NC}"; read s_type

            local_ip=$(get_local_ip)

            echo -ne "${G}Remote Public IP: ${NC}"; read remote_ip

            echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$remote_ip" > "$CONF_FILE"

            apply_tunnel

            systemctl start mgre.service 2>/dev/null

            echo -e "${G}Tunnel deployed successfully!${NC}"; sleep 1 ;;

        2)

            active_if=$([ -d /sys/class/net/greir ] && echo "greir" || echo "grekh")

            target_ip=$([[ "$active_if" == "greir" ]] && echo "10.76.76.2" || echo "10.76.76.1")

            echo -e "\n${C}Testing Latency to Peer ($target_ip)...${NC}"

            ping -c 4 "$target_ip" || echo -e "${R}Peer Unreachable!${NC}"

            read -p "Press Enter to return..." ;;

        3)

            echo -e "\n${C}System Info:${NC}"

            echo -e "${W}Uptime: ${Y}$(uptime -p)${NC}"

            echo -e "${W}Load:   ${Y}$(awk '{print $1, $2, $3}' /proc/loadavg)${NC}"

            read -p "Press Enter to return..." ;;

        4)

            echo -ne "${R}Are you sure you want to wipe everything? (y/n): ${NC}"; read confirm

            if [[ "$confirm" == "y" ]]; then

                ip tunnel del greir >/dev/null 2>&1; ip tunnel del grekh >/dev/null 2>&1

                iptables -t mangle -F FORWARD >/dev/null 2>&1

                rm -f "$CONF_FILE"

                systemctl disable mgre.service >/dev/null 2>&1; rm -f "$SERVICE_FILE"

                systemctl daemon-reload

                echo -e "${R}All wiped.${NC}"; sleep 1

            fi ;;

        5) exit 0 ;;

    esac

done
