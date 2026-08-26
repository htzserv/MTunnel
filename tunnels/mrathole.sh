#!/bin/bash
# --- MDesign Modular Core (mrathole.sh) | The Ultimate Rathole Engine V2.8 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mrathole/tunnels"
SERVICE_TPL="/etc/systemd/system/mrathole@.service"

mkdir -p "$CONF_DIR"

install_rathole() {
    if ! command -v rathole &> /dev/null; then
        echo -e "\n  ${DIM}● Downloading and installing Rathole Core...${NC}"
        apt-get update -y -q >/dev/null 2>&1
        apt-get install -y -q unzip >/dev/null 2>&1
        local arch=$(uname -m)
        local target="x86_64-unknown-linux-gnu"
        [ "$arch" == "aarch64" ] && target="aarch64-unknown-linux-gnu"
        wget -qO /tmp/rathole.zip "https://github.com/rapiz1/rathole/releases/download/v0.5.0/rathole-${target}.zip" >/dev/null 2>&1
        unzip -q -o /tmp/rathole.zip -d /tmp/ >/dev/null 2>&1
        mv /tmp/rathole /usr/local/bin/rathole
        chmod +x /usr/local/bin/rathole
        rm -f /tmp/rathole.zip
        echo -e "  ${G}✔ Rathole Core installed successfully.${NC}"
    fi
}

setup_systemd() {
    echo "[Unit]" > "$SERVICE_TPL"
    echo "Description=MRathole Reverse Engine (%i)" >> "$SERVICE_TPL"
    echo "After=network.target" >> "$SERVICE_TPL"
    echo "" >> "$SERVICE_TPL"
    echo "[Service]" >> "$SERVICE_TPL"
    echo "Type=simple" >> "$SERVICE_TPL"
    echo "ExecStart=/usr/local/bin/rathole /etc/mrathole/tunnels/%i/config.toml" >> "$SERVICE_TPL"
    echo "Restart=always" >> "$SERVICE_TPL"
    echo "RestartSec=3" >> "$SERVICE_TPL"
    echo "LimitNOFILE=1048576" >> "$SERVICE_TPL"
    echo "" >> "$SERVICE_TPL"
    echo "[Install]" >> "$SERVICE_TPL"
    echo "WantedBy=multi-user.target" >> "$SERVICE_TPL"
    systemctl daemon-reload
}

generate_toml() {
    local name="$1"
    local dir="$CONF_DIR/$name"
    local meta="$dir/meta.conf"
    local toml="$dir/config.toml"
    
    TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; TCP_PORTS=""; UDP_PORTS=""; source "$meta"
    
    > "$toml"
    if [ "$TYPE" == "1" ]; then
        echo "[server]" >> "$toml"
        echo "bind_addr = \"0.0.0.0:${LINK_PORT}\"" >> "$toml"
        echo "default_token = \"${TOKEN}\"" >> "$toml"
        echo "heartbeat_interval = 30" >> "$toml"
        echo "" >> "$toml"
        echo "[server.transport]" >> "$toml"
        echo "type = \"tcp\"" >> "$toml"
        echo "[server.transport.tcp]" >> "$toml"
        echo "nodelay = true" >> "$toml"

        IFS=',' read -ra TCP_ARR <<< "$TCP_PORTS"
        for p in "${TCP_ARR[@]}"; do
            p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
            echo "" >> "$toml"
            echo "[server.services.tcp_${p}]" >> "$toml"
            echo "type = \"tcp\"" >> "$toml"
            echo "bind_addr = \"0.0.0.0:${p}\"" >> "$toml"
        done

        IFS=',' read -ra UDP_ARR <<< "$UDP_PORTS"
        for p in "${UDP_ARR[@]}"; do
            p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
            echo "" >> "$toml"
            echo "[server.services.udp_${p}]" >> "$toml"
            echo "type = \"udp\"" >> "$toml"
            echo "bind_addr = \"0.0.0.0:${p}\"" >> "$toml"
        done
    else
        echo "[client]" >> "$toml"
        echo "remote_addr = \"${REMOTE_IP}:${LINK_PORT}\"" >> "$toml"
        echo "default_token = \"${TOKEN}\"" >> "$toml"
        echo "heartbeat_timeout = 40" >> "$toml"
        echo "retry_interval = 1" >> "$toml"
        echo "" >> "$toml"
        echo "[client.transport]" >> "$toml"
        echo "type = \"tcp\"" >> "$toml"
        echo "[client.transport.tcp]" >> "$toml"
        echo "nodelay = true" >> "$toml"

        IFS=',' read -ra TCP_ARR <<< "$TCP_PORTS"
        for p in "${TCP_ARR[@]}"; do
            p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
            echo "" >> "$toml"
            echo "[client.services.tcp_${p}]" >> "$toml"
            echo "type = \"tcp\"" >> "$toml"
            echo "local_addr = \"127.0.0.1:${p}\"" >> "$toml"
        done

        IFS=',' read -ra UDP_ARR <<< "$UDP_PORTS"
        for p in "${UDP_ARR[@]}"; do
            p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
            echo "" >> "$toml"
            echo "[client.services.udp_${p}]" >> "$toml"
            echo "type = \"udp\"" >> "$toml"
            echo "local_addr = \"127.0.0.1:${p}\"" >> "$toml"
        done
    fi
}

get_tunnel_status() {
    local t_name="$1"
    local meta="$CONF_DIR/$t_name/meta.conf"
    TYPE=""; LINK_PORT=""; source "$meta" 2>/dev/null
    
    if ! systemctl is-active --quiet mrathole@$t_name; then
        echo "OFFLINE"
        return
    fi
    
    if ss -nt state established 2>/dev/null | grep -qE ":$LINK_PORT\b"; then
        echo "CONNECTED"
    else
        if [ "$TYPE" == "1" ]; then echo "WAITING"
        else echo "RECONNECTING"
        fi
    fi
}

draw_header() {
    local total_t=0; local active_t=0; local online_t=0
    for d in "$CONF_DIR"/*; do
        if [ -d "$d" ]; then
            ((total_t++))
            local t_name=$(basename "$d")
            if systemctl is-active --quiet mrathole@$t_name; then
                ((active_t++))
                local st=$(get_tunnel_status "$t_name")
                [ "$st" == "CONNECTED" ] && ((online_t++))
            fi
        fi
    done
    
    local act_color="${DIM}"; local act_text="0/0"
    if [ "$total_t" -gt 0 ]; then
        act_text="${active_t}/${total_t}"
        if [ "$active_t" -eq "$total_t" ]; then act_color="${G}"
        elif [ "$active_t" -gt 0 ]; then act_color="${Y}"
        else act_color="${R}"; fi
    fi

    local stat_color="${R}"; local stat_icon="○"; local stat_text="STOPPED  "
    if [ "$active_t" -gt 0 ]; then
        if [ "$online_t" -eq "$active_t" ]; then stat_color="${G}"; stat_icon="●"; stat_text="CONNECTED"
        elif [ "$online_t" -gt 0 ]; then stat_color="${Y}"; stat_icon="◐"; stat_text="PARTIAL  "
        else stat_color="${Y}"; stat_icon="◎"; stat_text="WAITING  "
        fi
    fi

    # --- Dynamic Peer Ping Logic (3 Colors) ---
    local peer_ip=""
    for d in "$CONF_DIR"/*; do
        if [ -d "$d" ] && [ -f "$d/meta.conf" ]; then
            local tmp_type=$(grep "^TYPE=" "$d/meta.conf" | cut -d'=' -f2)
            local tmp_remote=$(grep "^REMOTE_IP=" "$d/meta.conf" | cut -d'=' -f2)
            local tmp_port=$(grep "^LINK_PORT=" "$d/meta.conf" | cut -d'=' -f2)
            
            if [ -n "$tmp_remote" ] && [ "$tmp_remote" != "0.0.0.0" ]; then
                peer_ip="$tmp_remote"
                break
            elif [ "$tmp_type" == "1" ]; then
                local conn=$(ss -n -t state established sport = ":$tmp_port" 2>/dev/null | awk 'NR>1 {print $5}' | head -n 1)
                if [ -n "$conn" ]; then
                    peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                    break
                fi
            fi
        fi
    done

    local g_color="${DIM}"; local g_text="N/A"
    if [ -n "$peer_ip" ]; then
        local gp=$(ping -c 1 -W 1 "$peer_ip" 2>/dev/null | awk -F'/' 'END {print $5}')
        if [ -n "$gp" ]; then
            local p_int=${gp%.*}
            if [ "$p_int" -lt 90 ]; then g_color="${G}"
            elif [ "$p_int" -lt 160 ]; then g_color="${Y}"
            else g_color="${R}"
            fi
            g_text="${gp} ms"
        else
            g_color="${R}"; g_text="Timeout"
        fi
    else
        g_color="${DIM}"; g_text="Waiting"
    fi

    local title=" MRathole v2.8 "
    local ping_lbl=" Ping: "
    local act_lbl=" ACTIVE: "
    local stat_lbl=" STATUS: "
    
    local raw_len=$(( ${#title} + 1 + ${#ping_lbl} + ${#g_text} + 1 + 1 + ${#act_lbl} + ${#act_text} + 1 + 1 + ${#stat_lbl} + 2 + ${#stat_text} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${title}${NC}${B}│${NC}${DIM}${ping_lbl}${NC}${g_color}${g_text} ${NC}${B}│${NC}${DIM}${act_lbl}${NC}${act_color}${act_text} ${NC}${B}│${NC}${DIM}${stat_lbl}${NC}${stat_color}${stat_icon} ${stat_text}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    for d in "$CONF_DIR"/*; do
        [ ! -d "$d" ] && continue
        local t_name=$(basename "$d")
        TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; TCP_PORTS=""; UDP_PORTS=""; source "$d/meta.conf"
        
        local role=$([ "$TYPE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local peer=$([ "$TYPE" == "1" ] && echo "Waiting for Client" || echo "${REMOTE_IP}:${LINK_PORT}")
        
        local st=$(get_tunnel_status "$t_name")
        local st_text="OFFLINE  "; local st_color="${R}"
        if [ "$st" == "CONNECTED" ]; then st_text="CONNECTED"; st_color="${G}"
        elif [ "$st" == "WAITING" ]; then st_text="WAITING  "; st_color="${Y}"
        elif [ "$st" == "RECONNECTING" ]; then st_text="RETRYING "; st_color="${Y}"
        fi
        
        local current_ping="N/A"
        local ping_color="${DIM}"
        local peer_ip=""
        
        if [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "0.0.0.0" ]; then
            peer_ip="$REMOTE_IP"
        elif [ "$TYPE" == "1" ]; then
            local conn=$(ss -n -t state established sport = ":$LINK_PORT" 2>/dev/null | awk 'NR>1 {print $5}' | head -n 1)
            if [ -n "$conn" ]; then
                peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
            fi
        fi

        if [ -n "$peer_ip" ]; then
            local p_val=$(ping -c 1 -W 1 "$peer_ip" 2>/dev/null | awk -F'/' 'END {print $5}')
            if [ -n "$p_val" ]; then
                local p_int=${p_val%.*}
                if [ "$p_int" -lt 90 ]; then ping_color="${G}"
                elif [ "$p_int" -lt 160 ]; then ping_color="${Y}"
                else ping_color="${R}"
                fi
                current_ping="${p_val} ms"
            else
                current_ping="Timeout"
                ping_color="${R}"
            fi
        else
            current_ping="Waiting"
            ping_color="${DIM}"
        fi

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} %b▼ Tunnel: %-30s%b ${DIM}Role:%b %-20s ${DIM}Ping:%b %-10s ${B}│${NC}\n" "${C}" "${t_name}" "${NC}" "${NC}" "${role}" "${ping_color}" "${current_ping}"
        echo -e "  ${B}├────────────────────────┬───────────────────────┬───────────────────────┬───────────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-22s${NC} ${B}│${NC} ${DIM}%-21s${NC} ${B}│${NC} ${DIM}%-21s${NC} ${B}│${NC} ${DIM}%-17s${NC} ${B}│${NC}\n" "LINK PORT" "PEER ENDPOINT" "TCP/UDP PORTS" "STATUS"
        echo -e "  ${B}├────────────────────────┼───────────────────────┼───────────────────────┼───────────────────┤${NC}"
        local p_fmt="T:${TCP_PORTS:0:7} U:${UDP_PORTS:0:7}"; [ ${#p_fmt} -gt 18 ] && p_fmt="${p_fmt:0:16}.."
        printf "  ${B}│${NC} ${C}%-22s${NC} ${B}│${NC} ${W}%-21s${NC} ${B}│${NC} ${Y}%-21s${NC} ${B}│${NC} %b%-17s%b ${B}│${NC}\n" "${LINK_PORT}" "${peer}" "${p_fmt}" "${st_color}" "${st_text}" "${NC}"
        echo -e "  ${B}╰────────────────────────┴───────────────────────┴───────────────────────┴───────────────────╯${NC}\n"
    done
}

manage_cron() {
    local t_name="$1"
    local cron_script="$CONF_DIR/$t_name/restart.sh"
    
    echo -e "\n  ${DIM}┌─[ ANTI-FREEZE CRONJOB MANAGER ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add/Update Auto-Restart Cronjob${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Remove Auto-Restart Cronjob${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read cr_opt

    if [[ "$cr_opt" == "1" ]]; then
        echo -ne "  ${C}●${NC} ${W}Restart interval in hours (e.g. 2, 4, 6): ${NC}"; read interval
        [[ ! "$interval" =~ ^[0-9]+$ ]] && echo -e "  ${R}Invalid interval!${NC}" && sleep 1.5 && return
        
        echo "#!/bin/bash" > "$cron_script"
        echo "systemctl kill -s SIGKILL mrathole@${t_name}" >> "$cron_script"
        echo "systemctl restart mrathole@${t_name}" >> "$cron_script"
        chmod +x "$cron_script"
        
        crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > /tmp/crontab.tmp
        echo "0 */${interval} * * * $cron_script #mrathole@${t_name}" >> /tmp/crontab.tmp
        crontab /tmp/crontab.tmp; rm -f /tmp/crontab.tmp
        echo -e "  ${G}✔ Cronjob added: Tunnel will restart every ${interval} hours.${NC}"; sleep 2
    elif [[ "$cr_opt" == "2" ]]; then
        crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > /tmp/crontab.tmp
        crontab /tmp/crontab.tmp; rm -f /tmp/crontab.tmp
        rm -f "$cron_script"
        echo -e "  ${G}✔ Cronjob removed.${NC}"; sleep 1.5
    fi
}

select_tunnel() {
    local configs=($(ls -d "$CONF_DIR"/* 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; fi
    
    echo -e "\n  ${B}╭────────────────── Select Tunnel to Manage ─────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}")"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx
    if [[ "$t_idx" == "q" || -z "$t_idx" || -z "${configs[$t_idx]}" ]]; then return 1; fi
    
    SELECTED_TUN="${configs[$t_idx]}"
    return 0
}

install_rathole
setup_systemd

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC}  ${DIM}❯${NC} ${G}Deploy New Reverse Tunnel (Rathole)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC}  ${DIM}❯${NC} ${C}Live Monitoring (Auto-Refresh)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC}  ${DIM}❯${NC} ${C}Edit Remote IP Address${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC}  ${DIM}❯${NC} ${G}ADD New TCP Ports${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC}  ${DIM}❯${NC} ${G}ADD New UDP Ports${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC}  ${DIM}❯${NC} ${M}Anti-Freeze Cronjob Manager${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC}  ${DIM}❯${NC} ${W}View Live Service Logs${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC}  ${DIM}❯${NC} ${Y}Restart Service${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC}  ${DIM}❯${NC} ${R}Delete Tunnels${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC}  ${DIM}❯${NC} ${DIM}Exit${NC}\n"
    echo -ne "  ${C}MRATHOLE ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r')
    
    case $opt in
        1) 
           echo -e "\n  ${DIM}┌─[ DEPLOY NEW TUNNEL ]${NC}"
           while true; do echo -ne "  ${C}●${NC} ${W}Role [1: IRAN (Server) | 2: KHAREJ (Client) | q: Back]: ${NC}"; read s_type; [[ "$s_type" =~ ^[12q]$ ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do echo -ne "  ${C}●${NC} ${W}Tunnel Name (e.g. rt1): ${NC}"; read t_name; [[ -n "$t_name" ]] && break; done
           
           r_ip="0.0.0.0"
           if [ "$s_type" == "2" ]; then
               echo -ne "  ${C}●${NC} ${W}Target IRAN Public IP: ${NC}"; read r_ip
           fi
           
           echo -ne "  ${C}●${NC} ${W}Tunnel Link Port (e.g. 5050): ${NC}"; read t_port
           
           echo -ne "  ${C}●${NC} ${W}Custom Token (Leave blank to generate auto): ${NC}"; read t_token
           [ -z "$t_token" ] && t_token=$(head -c 8 /dev/urandom | xxd -p)
           
           echo -ne "  ${C}●${NC} ${W}TCP Ports to Forward (e.g. 80,443) [Leave blank if none]: ${NC}"; read tcp_p
           echo -ne "  ${C}●${NC} ${W}UDP Ports to Forward (e.g. 53) [Leave blank if none]: ${NC}"; read udp_p
           
           mkdir -p "$CONF_DIR/$t_name"
           echo -e "TYPE=$s_type\nLINK_PORT=$t_port\nREMOTE_IP=$r_ip\nTOKEN=$t_token\nTCP_PORTS=$tcp_p\nUDP_PORTS=$udp_p" > "$CONF_DIR/$t_name/meta.conf"
           
           generate_toml "$t_name"
           systemctl enable mrathole@$t_name >/dev/null 2>&1
           systemctl restart mrathole@$t_name
           echo -e "  ${G}● Tunnel Deployed with Anti-Flap Optimizations!${NC}"; sleep 1.5 ;;
           
        2) while true; do draw_header; show_monitor; read -t 2 -n 1 -s b_opt; [[ "$b_opt" == "q" ]] && break; done ;;
        
        3|4|5|6|7|8)
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN")
           TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; TCP_PORTS=""; UDP_PORTS=""; source "$SELECTED_TUN/meta.conf"
           
           if [[ "$opt" == "3" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Remote IP (Current: ${REMOTE_IP}): ${NC}"; read n_ip
               [ -n "$n_ip" ] && sed -i "s/^REMOTE_IP=.*/REMOTE_IP=$n_ip/" "$SELECTED_TUN/meta.conf"
               
           elif [[ "$opt" == "4" ]]; then
               echo -ne "  ${C}●${NC} ${W}Enter TCP Ports to ADD (Current: ${TCP_PORTS:-None}): ${NC}"; read add_tcp
               [ -n "$add_tcp" ] && {
                   local new_tcp=$(echo "${TCP_PORTS},${add_tcp}" | sed 's/^,*//;s/,,*/,/g;s/,$//')
                   sed -i "s/^TCP_PORTS=.*/TCP_PORTS=$new_tcp/" "$SELECTED_TUN/meta.conf"
               }
               
           elif [[ "$opt" == "5" ]]; then
               echo -ne "  ${C}●${NC} ${W}Enter UDP Ports to ADD (Current: ${UDP_PORTS:-None}): ${NC}"; read add_udp
               [ -n "$add_udp" ] && {
                   local new_udp=$(echo "${UDP_PORTS},${add_udp}" | sed 's/^,*//;s/,,*/,/g;s/,$//')
                   sed -i "s/^UDP_PORTS=.*/UDP_PORTS=$new_udp/" "$SELECTED_TUN/meta.conf"
               }
               
           elif [[ "$opt" == "6" ]]; then
               manage_cron "$t_name"; continue
               
           elif [[ "$opt" == "7" ]]; then
               journalctl -u mrathole@$t_name -n 50 -f; continue
               
           elif [[ "$opt" == "8" ]]; then
               true # Proceed to generation and restart
           fi
           
           generate_toml "$t_name"
           systemctl restart mrathole@$t_name
           echo -e "  ${G}✔ Tunnel updated and applied.${NC}"; sleep 1.5
           ;;
           
        9)
           tunnels=($(ls -d "$CONF_DIR"/* 2>/dev/null))
           [ ${#tunnels[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Delete ─────────────────╮${NC}"
           for i in "${!tunnels[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${tunnels[$i]}")"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}Index (or 'all' / 'q'): ${NC}"; read del_idx
           if [[ "$del_idx" == "all" ]]; then
               for d in "${tunnels[@]}"; do
                   t_name=$(basename "$d")
                   systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null
                   crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" | crontab -
                   rm -rf "$d"
               done
               echo -e "  ${G}All Tunnels Purged!${NC}"; sleep 1.5
           elif [[ -n "${tunnels[$del_idx]}" ]]; then
               t_name=$(basename "${tunnels[$del_idx]}")
               systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null
               crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" | crontab -
               rm -rf "${tunnels[$del_idx]}"
               echo -e "  ${G}Tunnel Purged!${NC}"; sleep 1.5
           fi ;;
           
        0) break ;;
    esac
done
