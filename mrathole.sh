#!/bin/bash
# --- MRathole Modular Core (mrathole.sh) | Rathole Reverse Tunnel v1.2.1 (Full Fix) ---
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
            [ -z "$p" ] && continue
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
            [ -z "$p" ] && continue
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
    local s_ip=$(get_local_ip); local total_tunnels=0; local active_tunnels=0
    for d in "$CONF_DIR"/*; do
        if [ -d "$d" ]; then
            ((total_tunnels++))
            local t_name=$(basename "$d")
            if systemctl is-active --quiet mrathole@$t_name; then 
                ((active_tunnels++))
            fi
        fi
    done
    
    local status_badge="${R}○ STOPPED${NC}"
    if [ "$total_tunnels" -gt 0 ]; then
        if [ "$active_tunnels" -eq "$total_tunnels" ]; then
            status_badge="${G}● ALL ONLINE (${active_tunnels}/${total_tunnels})${NC}"
        elif [ "$active_tunnels" -gt 0 ]; then
            status_badge="${Y}◐ PARTIAL (${active_tunnels}/${total_tunnels})${NC}"
        else
            status_badge="${R}● OFFLINE (0/${total_tunnels})${NC}"
        fi
    fi

    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MRathole Reverse Engine v1.2.1${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}STATUS:${NC} ${status_badge} ${B}│${NC}"
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

manage_tunnel() {
    local tunnels=($(ls -d "$CONF_DIR"/* 2>/dev/null))
    [ ${#tunnels[@]} -eq 0 ] && { echo -e "\n  ${Y}● No tunnels found!${NC}"; sleep 1; return; }
    
    echo -e "\n  ${B}╭────────────────── Select Tunnel to Manage ─────────────────╮${NC}"
    for i in "${!tunnels[@]}"; do
        local t_name=$(basename "${tunnels[$i]}")
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$t_name"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}● Select Index: ${NC}"; read m_idx
    m_idx=$(echo "$m_idx" | tr -d '\r')
    
    [[ -z "${tunnels[$m_idx]}" ]] && return
    local t_dir="${tunnels[$m_idx]}"
    local t_name=$(basename "$t_dir")
    
    while true; do
        TYPE=""; T_NAME=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; source "$t_dir/meta.conf"
        clear; echo -e "\n  ${DIM}┌─[ MANAGING TUNNEL: ${W}${t_name}${DIM} ]${NC}"
        echo -e "  ⚙️ Role: $([ "$TYPE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)") | Link Port: ${LINK_PORT} | IP: ${REMOTE_IP}"
        echo -e "  🔌 Ports: ${PORTS}"
        echo -e "  ------------------------------------------------------------"
        echo -e "  ${W}1${NC} ❯ Manual Restart Service"
        echo -e "  ${W}2${NC} ❯ Setup Auto-Restart Cronjob (Timer)"
        echo -e "  ${W}3${NC} ❯ Change Peer/Remote IP (Kharej IP)"
        echo -e "  ${W}4${NC} ❯ Add Ports"
        echo -e "  ${W}5${NC} ❯ Remove Ports"
        echo -e "  ${W}0${NC} ❯ Back to Menu\n"
        echo -ne "  ${C}ACTION ❯❯ ${NC}"; read act
        act=$(echo "$act" | tr -d '\r')
        
        case $act in
            1)
                systemctl restart mrathole@$t_name
                echo -e "  ${G}● Service restarted successfully!${NC}"; sleep 1.5
                ;;
            2)
                echo -ne "  ${C}●${NC} Enter interval in minutes for auto-restart (e.g. 30, or 0 to disable): "
                read c_min; c_min=$(echo "$c_min" | tr -d '\r')
                crontab -l 2>/dev/null | grep -v "mrathole@$t_name" | crontab - 2>/dev/null
                if [[ "$c_min" =~ ^[0-9]+$ ]] && [ "$c_min" -gt 0 ]; then
                    (crontab -l 2>/dev/null; echo "*/$c_min * * * * systemctl restart mrathole@$t_name") | crontab -
                    echo -e "  ${G}● Cronjob set! Service will restart every ${c_min} minutes.${NC}"
                else
                    echo -e "  ${Y}● Auto-restart cronjob disabled for this tunnel.${NC}"
                fi
                sleep 2
                ;;
            3)
                echo -ne "  ${C}●${NC} Enter new Remote/Kharej IP [Current: ${REMOTE_IP}]: "
                read n_ip; n_ip=$(echo "$n_ip" | tr -d '\r')
                if [ -n "$n_ip" ]; then
                    sed -i "s/^REMOTE_IP=.*/REMOTE_IP=$n_ip/" "$t_dir/meta.conf"
                    generate_toml "$t_name"
                    systemctl restart mrathole@$t_name
                    echo -e "  ${G}● Remote IP updated and service restarted!${NC}"
                fi
                sleep 1.5
                ;;
            4)
                echo -ne "  ${C}●${NC} Enter port(s) to add (Comma separated, e.g. 8080,9090): "
                read add_p; add_p=$(echo "$add_p" | tr -d '\r')
                if [ -n "$add_p" ]; then
                    [ -z "$PORTS" ] && NEW_PORTS="$add_p" || NEW_PORTS="$PORTS,$add_p"
                    sed -i "s/^PORTS=.*/PORTS=$NEW_PORTS/" "$t_dir/meta.conf"
                    generate_toml "$t_name"
                    systemctl restart mrathole@$t_name
                    echo -e "  ${G}● Ports added successfully!${NC}"
                fi
                sleep 1.5
                ;;
            5)
                echo -e "  Current Ports: ${PORTS}"
                echo -ne "  ${C}●${NC} Enter port to remove: "
                read rem_p; rem_p=$(echo "$rem_p" | tr -d '\r')
                if [ -n "$rem_p" ]; then
                    NEW_PORTS=$(echo "$PORTS" | tr ',' '\n' | grep -v "^${rem_p}$" | paste -sd, -)
                    sed -i "s/^PORTS=.*/PORTS=$NEW_PORTS/" "$t_dir/meta.conf"
                    generate_toml "$t_name"
                    systemctl restart mrathole@$t_name
                    echo -e "  ${G}● Port removed successfully!${NC}"
                fi
                sleep 1.5
                ;;
            0)
                break
                ;;
        esac
    done
}

uninstall_rathole() {
    echo -ne "\n  ${R}● UNINSTALL: Stop all tunnels, remove services and cronjobs? (y/n): ${NC}"
    read un_conf; un_conf=$(echo "$un_conf" | tr -d '\r' | tr -d ' ')
    if [[ "$un_conf" == "y" ]]; then
        for d in "$CONF_DIR"/*; do
            [ ! -d "$d" ] && continue
            local t_name=$(basename "$d")
            systemctl stop mrathole@$t_name 2>/dev/null
            systemctl disable mrathole@$t_name 2>/dev/null
            crontab -l 2>/dev/null | grep -v "mrathole@$t_name" | crontab - 2>/dev/null
        done
        rm -f "$SERVICE_TPL"
        systemctl daemon-reload
        rm -rf "$CONF_DIR"
        echo -e "  ${G}● MRathole module uninstalled successfully!${NC}"
        sleep 2
    fi
}

wipe_rathole() {
    echo -ne "\n  ${R}● NUCLEAR WIPE: Completely delete binaries, configs, and logs? (y/n): ${NC}"
    read wp_conf; wp_conf=$(echo "$wp_conf" | tr -d '\r' | tr -d ' ')
    if [[ "$wp_conf" == "y" ]]; then
        for d in "$CONF_DIR"/*; do
            [ ! -d "$d" ] && continue
            local t_name=$(basename "$d")
            systemctl stop mrathole@$t_name 2>/dev/null
            systemctl disable mrathole@$t_name 2>/dev/null
            crontab -l 2>/dev/null | grep -v "mrathole@$t_name" | crontab - 2>/dev/null
        done
        rm -f "$SERVICE_TPL"
        systemctl daemon-reload
        rm -rf "/etc/mrathole"
        rm -f "/usr/local/bin/rathole"
        rm -f "/usr/bin/mrathole"
        echo -e "  ${G}● MRathole completely wiped from system!${NC}"
        sleep 2
        exit 0
    fi
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${R}Setup New Reverse Tunnel (Rathole)${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Manage Tunnels (Restart, Cronjob, IP, Ports)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Delete Tunnels${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Uninstall Module${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Nuclear Wipe (Erase Core & Binaries)${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
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
           
           r_ip="0.0.0.0"
           if [ "$s_type" == "2" ]; then
               echo -ne "  ${C}●${NC} ${W}Remote (IRAN) Public IP: ${NC}"; read r_ip; r_ip=$(echo "$r_ip" | tr -d '\r')
           fi
           
           echo -ne "  ${C}●${NC} ${W}Tunnel Link Port (e.g. 5000): ${NC}"; read t_port; t_port=$(echo "$t_port" | tr -d '\r')
           
           t_token=$(head -c 8 /dev/urandom | xxd -p)
           echo -ne "  ${C}●${NC} ${W}Secret Token [${Y}${t_token}${W}]: ${NC}"; read u_token; u_token=$(echo "$u_token" | tr -d '\r')
           [ -n "$u_token" ] && t_token="$u_token"
           
           echo -ne "  ${C}●${NC} ${W}Target Ports to Forward (Comma separated, e.g. 80,443): ${NC}"; read t_ports; t_ports=$(echo "$t_ports" | tr -d '\r')
           
           mkdir -p "$CONF_DIR/$t_name"
           echo -e "TYPE=$s_type\nT_NAME=$t_name\nLINK_PORT=$t_port\nREMOTE_IP=$r_ip\nTOKEN=$t_token\nPORTS=$t_ports" > "$CONF_DIR/$t_name/meta.conf"
           
           generate_toml "$t_name"
           systemctl enable mrathole@$t_name >/dev/null 2>&1
           systemctl restart mrathole@$t_name
           
           echo -e "  ${G}● Reverse Tunnel Deployed Successfully!${NC}"; sleep 1.5 ;;
        2) manage_tunnel ;;
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
                   systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null
                   crontab -l 2>/dev/null | grep -v "mrathole@$t_name" | crontab - 2>/dev/null
                   rm -rf "$d"
               done
           elif [[ -n "${tunnels[$del_idx]}" ]]; then
               t_name=$(basename "${tunnels[$del_idx]}")
               systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null
               crontab -l 2>/dev/null | grep -v "mrathole@$t_name" | crontab - 2>/dev/null
               rm -rf "${tunnels[$del_idx]}"
           fi; echo -e "  ${G}Purged!${NC}"; sleep 1 ;;
        5) uninstall_rathole ;;
        6) wipe_rathole ;;
        0) break ;;
    esac
done
