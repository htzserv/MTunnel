#!/bin/bash
# --- MGostun Modular Core (mgostun.sh) | Gost Encapsulation v1.2.0 (MDesign Ecosystem) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mgostun/tunnels"
SERVICE_TPL="/etc/systemd/system/mgostun@.service"
LOCAL_DIR="/root/mtunnel"

mkdir -p "$CONF_DIR"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

apply_bbr_optimization() {
    echo -e "  ${DIM}● Applying BBR network acceleration for maximum speed...${NC}"
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1
}

check_gost_connection() {
    local t_name="$1"
    local t_dir="$CONF_DIR/$t_name"
    [ ! -f "$t_dir/meta.conf" ] && { echo "OFFLINE"; return; }
    
    TYPE=""; LINK_PORT=""; source "$t_dir/meta.conf"
    
    if ! systemctl is-active --quiet mgostun@$t_name; then
        echo "OFFLINE"
        return
    fi

    if [ "$TYPE" == "1" ]; then
        # ایران (Client): بررسی برقراری ارتباط با پورت ریموت خارج
        if systemctl is-active --quiet mgostun@$t_name; then
            echo "ONLINE"
        else
            echo "OFFLINE"
        fi
    else
        # خارج (Server): بررسی نشستن کانکشن روی پورت گوش‌دهنده
        if ss -tn sport = ":$LINK_PORT" | grep -q "ESTAB"; then
            echo "ONLINE"
        else
            echo "WAITING"
        fi
    fi
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
            echo -e "  ${Y}● Downloading Gost from GitHub...${NC}"
            apt-get update -y -q >/dev/null 2>&1
            apt-get install -y -q wget unzip >/dev/null 2>&1
            local arch=$(uname -m)
            local target="linux-amd64"
            [ "$arch" == "aarch64" ] && target="linux-arm64"
            wget -qO /tmp/gost.gz "https://github.com/go-gost/gost/releases/download/v3.0.0-nightly.20230711/gost_3.0.0-nightly.20230711_${target}.tar.gz" >/dev/null 2>&1
            tar -xzf /tmp/gost.gz -C /tmp/ >/dev/null 2>&1
            mv /tmp/gost /usr/local/bin/gost
            chmod +x /usr/local/bin/gost
            cp /usr/local/bin/gost "$LOCAL_DIR/packages/gost" 2>/dev/null
            rm -f /tmp/gost.gz /tmp/LICENSE /tmp/README.md
        fi
    fi
}

generate_gost_command() {
    local name="$1"
    local dir="$CONF_DIR/$name"
    local meta="$dir/meta.conf"
    local cmd_file="$dir/run.sh"
    
    TYPE=""; LINK_PORT=""; REMOTE_IP=""; FWD_PORT=""; source "$meta"
    
    > "$cmd_file"
    if [ "$TYPE" == "1" ]; then
        # ایران (Client): اتصال به خارج و انتقال پورت
        echo "#!/bin/bash" >> "$cmd_file"
        echo "/usr/local/bin/gost -L tcp://:${FWD_PORT}/127.0.0.1:${FWD_PORT} -F relay+tls://${REMOTE_IP}:${LINK_PORT}" >> "$cmd_file"
    else
        # خارج (Server): دریافت تانل و باز کردن پورت
        echo "#!/bin/bash" >> "$cmd_file"
        echo "/usr/local/bin/gost -L relay+tls://:${LINK_PORT}" >> "$cmd_file"
    fi
    chmod +x "$cmd_file"
}

setup_service() {
    local name="$1"
    cat <<EOF > "$SERVICE_TPL"
[Unit]
Description=MGost Encapsulation Tunnel (%i)
After=network.target

[Service]
Type=simple
ExecStart=/etc/mgostun/tunnels/%i/run.sh
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

draw_header() {
    local s_ip=$(get_local_ip); local total_tunnels=0; local online_tunnels=0
    for d in "$CONF_DIR"/*; do
        if [ -d "$d" ]; then
            ((total_tunnels++))
            local t_name=$(basename "$d")
            local st=$(check_gost_connection "$t_name")
            if [ "$st" == "ONLINE" ]; then
                ((online_tunnels++))
            fi
        fi
    done
    
    local status_badge="${R}○ STOPPED${NC}"
    if [ "$total_tunnels" -gt 0 ]; then
        if [ "$online_tunnels" -eq "$total_tunnels" ]; then
            status_badge="${G}● CONNECTED (${online_tunnels}/${total_tunnels})${NC}"
        elif [ "$online_tunnels" -gt 0 ]; then
            status_badge="${Y}◐ PARTIAL (${online_tunnels}/${total_tunnels})${NC}"
        else
            status_badge="${Y}◎ WAITING (${online_tunnels}/${total_tunnels})${NC}"
        fi
    fi

    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MGost Encapsulation Engine v1.2.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}STATUS:${NC} ${status_badge} ${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    for d in "$CONF_DIR"/*; do
        [ ! -d "$d" ] && continue
        local t_name=$(basename "$d")
        TYPE=""; LINK_PORT=""; REMOTE_IP=""; FWD_PORT=""; source "$d/meta.conf"
        
        local role_text=$([ "$TYPE" == "1" ] && echo "IRAN (Client)" || echo "KHAREJ (Server)")
        local peer_text=$([ "$TYPE" == "1" ] && echo "${REMOTE_IP}:${LINK_PORT}" || echo "Listening on :${LINK_PORT}")
        
        local st=$(check_gost_connection "$t_name")
        local st_text="OFFLINE"; local st_color="${R}"
        if [ "$st" == "ONLINE" ]; then st_text="ONLINE "; st_color="${G}";
        elif [ "$st" == "WAITING" ]; then st_text="WAITING"; st_color="${Y}"; fi
        
        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} %b▼ Tunnel: %-35s%b ${DIM}Role:%b %-40s ${B}│${NC}\n" "${R}" "${t_name}" "${NC}" "${NC}" "${role_text}"
        echo -e "  ${B}├────────────────────────┬───────────────────────┬───────────────────────┬───────────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-22s${NC} ${B}│${NC} ${DIM}%-21s${NC} ${B}│${NC} ${DIM}%-21s${NC} ${B}│${NC} ${DIM}%-17s${NC} ${B}│${NC}\n" "LINK PORT" "PEER ENDPOINT" "FORWARDED PORT" "STATUS"
        echo -e "  ${B}├────────────────────────┼───────────────────────┼───────────────────────┼───────────────────┤${NC}"
        printf "  ${B}│${NC} ${C}%-22s${NC} ${B}│${NC} ${W}%-21s${NC} ${B}│${NC} ${Y}%-21s${NC} ${B}│${NC} %b%-17s%b ${B}│${NC}\n" "${LINK_PORT}" "${peer_text}" "${FWD_PORT:-None}" "${st_color}" "${st_text}" "${NC}"
        echo -e "  ${B}╰────────────────────────┴───────────────────────┴───────────────────────┴───────────────────╯${NC}\n"
    done
}

show_tunnel_details() {
    local configs=($(ls -d "$CONF_DIR"/* 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return; fi

    echo -e "\n  ${Y}● Deployed MGost Tunnels Registry:${NC}"
    for d in "${configs[@]}"; do
        TYPE=""; LINK_PORT=""; REMOTE_IP=""; FWD_PORT=""; source "$d/meta.conf"
        local t_name=$(basename "$d")
        local t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Client / Entry)" || echo "KHAREJ (Server / Exit)")
        local l_port="${LINK_PORT:-[ NOT SET ]}"
        local r_ip="${REMOTE_IP:-0.0.0.0}"
        local f_port="${FWD_PORT:-None}"

        local st=$(check_gost_connection "$t_name")
        local stat_icon="○"; local stat_text="OFFLINE"; local stat_color="${R}"
        if [ "$st" == "ONLINE" ]; then
            stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}"
        elif [ "$st" == "WAITING" ]; then
            stat_icon="◎"; stat_text="WAITING LINK"; stat_color="${Y}"
        fi

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $t_name"
        local right_p="Role: $t_role"
        local pad=$(( 89 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp} ${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="Link Port    : ${l_port}"; local r1="Remote IP: ${r_ip}"
        local pad1=$(( 89 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Link Port    :${NC} ${W}${l_port}${NC}${sp1} ${DIM}Remote IP:${NC} ${W}${r_ip}${NC} ${B}│${NC}"
        
        local l2="Forward Port : ${f_port}"; local r2="Link State: ${stat_text}"
        local pad2=$(( 89 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}Forward Port :${NC} ${W}${f_port}${NC}${sp2} ${DIM}Link State:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${B}│${NC}"
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read
}

uninstall_mgost() {
    echo -ne "\n  ${R}● UNINSTALL: Stop all tunnels and remove services? (y/n): ${NC}"
    read un_conf; un_conf=$(echo "$un_conf" | tr -d '\r' | tr -d ' ')
    if [[ "$un_conf" == "y" ]]; then
        for d in "$CONF_DIR"/*; do
            [ ! -d "$d" ] && continue
            local t_name=$(basename "$d")
            systemctl stop mgostun@$t_name 2>/dev/null
            systemctl disable mgostun@$t_name 2>/dev/null
        done
        rm -f "/etc/systemd/system/mgostun@.service"
        systemctl daemon-reload
        rm -rf "$CONF_DIR"
        echo -e "  ${G}● MGostun module uninstalled successfully!${NC}"
        sleep 2
    fi
}

wipe_mgost() {
    echo -ne "\n  ${R}● NUCLEAR WIPE: Completely delete binaries and configs? (y/n): ${NC}"
    read wp_conf; wp_conf=$(echo "$wp_conf" | tr -d '\r' | tr -d ' ')
    if [[ "$wp_conf" == "y" ]]; then
        for d in "$CONF_DIR"/*; do
            [ ! -d "$d" ] && continue
            local t_name=$(basename "$d")
            systemctl stop mgostun@$t_name 2>/dev/null
            systemctl disable mgostun@$t_name 2>/dev/null
        done
        rm -f "/etc/systemd/system/mgostun@.service"
        systemctl daemon-reload
        rm -rf "/etc/mgostun"
        rm -f "/usr/local/bin/gost"
        rm -f "/usr/bin/mgostun"
        echo -e "  ${G}● MGostun completely wiped from system!${NC}"
        sleep 2
        exit 0
    fi
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${R}Setup New Gost Encapsulation Tunnel${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}View Tunnel Configurations & Secrets${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Delete Tunnels${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Uninstall Module${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Nuclear Wipe (Erase Core & Binaries)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    echo -ne "  ${C}MGOSTUN ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1) 
           install_gost
           apply_bbr_optimization
           
           echo -e "\n  ${DIM}┌─[ ENCAPSULATION DEPLOYMENT ]${NC}"
           echo -e "  ${DIM}│${NC} ${W}Info:${NC} Here IRAN connects to KHAREJ and encapsulates traffic securely."
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IRAN (Client) | 2:KHAREJ (Server) | q:Back]: ${NC}"; read s_type; s_type=$(echo "$s_type" | tr -d '\r'); [[ "$s_type" =~ ^[12q]$ ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do echo -ne "  ${C}●${NC} ${W}Tunnel Suffix Name (e.g. gs1): ${NC}"; read suffix; suffix=$(echo "$suffix" | tr -d '\r'); t_name="gost_$suffix"; break; done
           
           r_ip="0.0.0.0"
           if [ "$s_type" == "1" ]; then
               echo -ne "  ${C}●${NC} ${W}Remote (KHAREJ) Public IP: ${NC}"; read r_ip; r_ip=$(echo "$r_ip" | tr -d '\r')
           fi
           
           echo -ne "  ${C}●${NC} ${W}Tunnel Link Port (e.g. 8443): ${NC}"; read t_port; t_port=$(echo "$t_port" | tr -d '\r')
           
           f_port=""
           if [ "$s_type" == "1" ]; then
               echo -ne "  ${C}●${NC} ${W}Port to Forward / Encapsulate: ${NC}"; read f_port; f_port=$(echo "$f_port" | tr -d '\r')
           fi
           
           mkdir -p "$CONF_DIR/$t_name"
           echo -e "TYPE=$s_type\nT_NAME=$t_name\nLINK_PORT=$t_port\nREMOTE_IP=$r_ip\nFWD_PORT=$f_port" > "$CONF_DIR/$t_name/meta.conf"
           
           generate_gost_command "$t_name"
           setup_service "$t_name"
           systemctl enable mgostun@$t_name >/dev/null 2>&1
           systemctl restart mgostun@$t_name
           
           echo -e "  ${G}● Gost Encapsulation Tunnel Deployed Successfully!${NC}"; sleep 1.5 ;;
        2) show_tunnel_details ;;
        3) while true; do draw_header; show_monitor; read -t 2 -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        4)
           tunnels=($(ls -d "$CONF_DIR"/* 2>/dev/null))
           [ ${#tunnels[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Delete ─────────────────╮${NC}"
           for i in "${!tunnels[@]}"; do echo "  $i ❯ $(basename "${tunnels[$i]}")"; done
           echo -ne "  ${C}Index (or 'all'): ${NC}"; read del_idx; del_idx=$(echo "$del_idx" | tr -d '\r')
           if [[ "$del_idx" == "all" ]]; then
               for d in "${tunnels[@]}"; do
                   t_name=$(basename "$d")
                   systemctl stop mgostun@$t_name 2>/dev/null; systemctl disable mgostun@$t_name 2>/dev/null
                   rm -rf "$d"
               done
           elif [[ -n "${tunnels[$del_idx]}" ]]; then
               t_name=$(basename "${tunnels[$del_idx]}")
               systemctl stop mgostun@$t_name 2>/dev/null; systemctl disable mgostun@$t_name 2>/dev/null
               rm -rf "${tunnels[$del_idx]}"
           fi; echo -e "  ${G}Purged!${NC}"; sleep 1 ;;
        5) uninstall_mgost ;;
        6) wipe_mgost ;;
        0) break ;;
    esac
done
