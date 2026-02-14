#!/bin/bash

# --- MGRE & MapRoxy v5.1.0 | MDesign Ultimate (Wget Edition) ---

# Colors
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[1;36m'; W='\033[1;37m'; NC='\033[0m'

# Paths
INSTALL_PATH="/usr/bin/mgre"
CONF_FILE="/etc/mahan_tunnel.conf"
SERVICE_FILE="/etc/systemd/system/mgre.service"
STATE_FILE="/etc/mlocalip.state"
H_CONF="/etc/haproxy/haproxy.cfg"
# لینک گیت‌هاب خود را اینجا قرار دهید
REPO_URL="https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/mgre.sh"

# --- FAST-BOOT & AUTO-INSTALL ---
if [[ "$1" != "--apply" ]]; then
    # بررسی سریع نصب در سیستم بدون ایجاد تاخیر
    if [[ ! -x "$INSTALL_PATH" ]]; then
        cp "$0" "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH" 2>/dev/null
    fi
fi

# --- CORE FUNCTIONS ---
get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

apply_tunnel() {
    [ ! -s "$CONF_FILE" ] && return
    source "$CONF_FILE"
    local t_name=$([ "$TYPE" == "1" ] && echo "greir" || echo "grekh")
    local local_tun=$([ "$TYPE" == "1" ] && echo "10.76.76.1" || echo "10.76.76.2")
    local mtu_val=$([ "$TYPE" == "1" ] && echo "1436" || echo "1476")
    
    ip tunnel del greir >/dev/null 2>&1; ip tunnel del grekh >/dev/null 2>&1
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o greir -j TCPMSS --set-mss 1396 >/dev/null 2>&1
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o grekh -j TCPMSS --set-mss 1436 >/dev/null 2>&1

    ip tunnel add "$t_name" mode gre remote "$REMOTE_PUB" local "$LOCAL_PUB" ttl 255
    ip link set "$t_name" up
    ip addr add "$local_tun"/30 dev "$t_name"
    ip link set dev "$t_name" mtu "$mtu_val"
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$t_name" -j TCPMSS --set-mss $((mtu_val - 40))

    if [[ "$MAX_IPS" -gt 0 ]]; then
        echo "0" > "$STATE_FILE"
        for ((i=1; i<=MAX_IPS; i++)); do
            idx=$(cat "$STATE_FILE")
            hash=$(echo "${SYNC_KEY}_${idx}" | sha256sum)
            o2=$(( (0x${hash:0:2} % 254) + 1 )); o3=$(( (0x${hash:2:2} % 254) + 1 ))
            last_octet=$([ "$TYPE" == "1" ] && echo "1" || echo "2")
            nip="10.$o2.$o3.$last_octet"
            ip addr add "$nip/30" dev "$t_name" label "$t_name:m" 2>/dev/null
            echo $((idx + 1)) > "$STATE_FILE"
        done
    fi
}

draw_mgre_header() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
    local s_ip=$(get_local_ip)
    local active_if="None"; local status="${R}Offline${NC}"
    local s_key="${Y}${SYNC_KEY:-"N/A"}${NC}"
    if ip link show greir >/dev/null 2>&1; then active_if="greir"; status="${G}Online${NC}";
    elif ip link show grekh >/dev/null 2>&1; then active_if="grekh"; status="${G}Online${NC}"; fi
    clear
    echo -e "${B}┌────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${B}│${NC} ${G}IP:${NC} ${Y}${s_ip}${NC} | ${G}IF:${NC} ${Y}${active_if}${NC} | ${G}KEY:${NC} ${s_key} | ${G}V-IPS:${NC} ${Y}${MAX_IPS:-0}${NC} | ${G}STATUS:${NC} ${status} ${B}│${NC}"
    echo -e "${B}└────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
}

show_mgre_monitor() {
    source "$CONF_FILE"
    local t_name=$([ "$TYPE" == "1" ] && echo "greir" || echo "grekh")
    echo -e "\n${C}MDesign Live Monitoring (CTRL+C to Stop)${NC}"
    echo -e "${B}┌──────┬──────────────────────┬──────────────────────┬──────────────┬──────────────┐${NC}"
    echo -e "${B}│${NC}${W}  ID  ${NC}${B}│${NC}${W}      LOCAL IP        ${NC}${B}│${NC}${W}      TARGET IP       ${NC}${B}│${NC}${W}     LAT      ${NC}${B}│${NC}${W}    STATUS    ${NC}${B}│${NC}"
    echo -e "${B}├──────┼──────────────────────┼──────────────────────┼──────────────┼──────────────┤${NC}"
    mapfile -t v_ips < <(ip -4 addr show dev "$t_name" label "$t_name:m" | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    for ((idx=0; idx<${#v_ips[@]}; idx++)); do
        lip="${v_ips[$idx]}"
        base_ip=$(echo "$lip" | cut -d'.' -f1-3)
        last=$(echo "$lip" | cut -d'.' -f4)
        tip="$base_ip.$([ "$last" == "1" ] && echo "2" || echo "1")"
        ping_res=$(ping -c 1 -W 1 "$tip" 2>/dev/null)
        if [ $? -eq 0 ]; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K\S+')
            p_lat="${Y}${lat}ms${NC}"; p_stat="${G}ONLINE${NC}"
        else
            p_lat="${R}---${NC}"; p_stat="${R}OFFLINE${NC}"
        fi
        printf "${B}│${NC} %-4s ${B}│${NC} %-20s ${B}│${NC} %-20s ${B}│${NC} %-23b ${B}│${NC} %-22b ${B}│${NC}\n" "$((idx+1))" "$lip" "$tip" "$p_lat" "$p_stat"
    done
    echo -e "${B}└──────┴──────────────────────┴──────────────────────┴──────────────┴──────────────┘${NC}"
}

# --- MAPROXY FUNCTIONS ---
mproxy_fix_install() {
    echo -e "${Y}[*] Installing HAProxy via apt...${NC}"
    apt-get update && apt-get install -y haproxy socat
    mproxy_base_conf
    systemctl enable haproxy && systemctl restart haproxy
    echo -e "${G}[✓] MapRoxy Core Ready.${NC}"; sleep 2
}

mproxy_base_conf() {
    mkdir -p /etc/haproxy
    echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
}

mproxy_smart_map() {
    local map_ips=($(ip -o -4 addr show greir 2>/dev/null | awk '{print $4}' | cut -d/ -f1))
    if [ ${#map_ips[@]} -eq 0 ]; then
        echo -e "${R}No active IPs found!${NC}"; return
    fi
    echo -ne "${G}Enter Local Ports (e.g. 80,443): ${NC}"; read raw_ports
    for p in $(echo "$raw_ports" | tr ',' ' '); do
        target_ip=$(echo ${map_ips[$((RANDOM % ${#map_ips[@]}))]} | cut -d'.' -f1-3).2
        echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check" >> "$H_CONF"
    done
    systemctl restart haproxy && echo -e "${G}Mapped.${NC}"; sleep 1
}

mproxy_main_menu() {
    while true; do
        clear
        echo -e "${C}MapRoxy v6.0 Management${NC}"
        printf "  ${Y}[1]${NC} Install Core  |  ${Y}[2]${NC} Add Mapping  |  ${Y}[0]${NC} Back\n"
        read -p ">> " mo
        case $mo in
            1) mproxy_fix_install ;;
            2) mproxy_smart_map ;;
            0) break ;;
        esac
    done
}

# --- UPDATE LOGIC (WGET) ---
update_script() {
    echo -e "${Y}[*] Fetching update from GitHub via wget...${NC}"
    wget -qO /tmp/mgre_new "$REPO_URL"
    if [ $? -eq 0 ]; then
        mv /tmp/mgre_new "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo -e "${G}[✓] Update applied successfully!${NC}"
        sleep 1
        exec mgre
    else
        echo -e "${R}[!] Update failed. Check URL/Connection.${NC}"
        sleep 2
    fi
}

# --- MAIN DASHBOARD ---
if [[ "$1" == "--apply" ]]; then apply_tunnel; exit 0; fi

while true; do
    draw_mgre_header
    printf "  ${Y}[1]${NC} ${W}%-35s${NC}\n" "Configure Standard Tunnel"
    printf "  ${Y}[2]${NC} ${W}%-35s${NC}\n" "Generate Sync Virtual IPs"
    printf "  ${Y}[3]${NC} ${C}%-35s${NC} ${G}(MapRoxy)${NC}\n" "Manage Port Mappings"
    printf "  ${Y}[4]${NC} ${W}%-35s${NC}\n" "Live Advanced Monitoring"
    printf "  ${Y}[5]${NC} ${B}%-35s${NC} ${Y}(Update)${NC}\n" "Update Script (Wget)"
    printf "  ${Y}[6]${NC} ${R}%-35s${NC}\n" "HARD UNINSTALL (Nuclear)"
    printf "  ${Y}[0]${NC} ${W}%-35s${NC}\n" "Exit"
    echo -ne "\n${B}Command >> ${NC}"
    read opt
    case $opt in
        1) echo -ne "${G}Mode [1:IR | 2:KH]: ${NC}"; read s_type
           echo -ne "${G}Remote IP: ${NC}"; read r_ip
           echo -e "TYPE=$s_type\nLOCAL_PUB=$(get_local_ip)\nREMOTE_PUB=$r_ip\nMAX_IPS=0" > "$CONF_FILE"
           apply_tunnel
           cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=MGRE MDesign Service
After=network.target
[Service]
ExecStart=$INSTALL_PATH --apply
Type=oneshot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
           systemctl daemon-reload && systemctl enable mgre.service >/dev/null 2>&1
           echo -e "${G}Tunnel Established.${NC}"; sleep 1 ;;
        2) source "$CONF_FILE"
           echo -ne "${G}IP Count: ${NC}"; read n; echo -ne "${G}Sync Key: ${NC}"; read k
           echo -e "TYPE=$TYPE\nLOCAL_PUB=$LOCAL_PUB\nREMOTE_PUB=$REMOTE_PUB\nMAX_IPS=$n\nSYNC_KEY=$k" > "$CONF_FILE"
           apply_tunnel; echo -e "${G}$n Sync IPs Generated.${NC}"; sleep 1 ;;
        3) mproxy_main_menu ;;
        4) while true; do draw_mgre_header; show_mgre_monitor; echo -e "${Y}Refreshing... CTRL+C to back.${NC}"; sleep 5; done ;;
        5) update_script ;;
        6) echo -ne "${R}Nuclear Wipe? (y/n): ${NC}"; read confirm
           if [[ "$confirm" == "y" ]]; then
               systemctl stop mgre.service >/dev/null 2>&1; systemctl disable mgre.service >/dev/null 2>&1
               ip tunnel del greir >/dev/null 2>&1; ip tunnel del grekh >/dev/null 2>&1
               rm -f "$SERVICE_FILE" "$CONF_FILE" "$STATE_FILE" "$INSTALL_PATH"
               echo -e "${G}System Purged.${NC}"; exit 0
           fi ;;
        0) exit 0 ;;
    esac
done
