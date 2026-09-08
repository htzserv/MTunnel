#!/bin/bash
# --- MPaqet Modular Core (mpaqet.sh) | Raw Packet Tunnel Engine v7.5.0 ---
# [Features: Enterprise Security | Command Injection Proof | Strict Validation | No Leak]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/paqet"
SERVICE_DIR="/etc/systemd/system"
LOCAL_DIR="/root/mtunnel"

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" 2>/dev/null

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

format_speed() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B/s"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B/s"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB/s"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB/s\", $bytes/1048576}"
    else awk "BEGIN {printf \"%.2f GB/s\", $bytes/1073741824}"; fi
}

format_total() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -lt 1099511627776 ]; then awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    else awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"; fi
}

menu_install_core() {
    echo -e "\n  ${DIM}┌─[ INSTALL / UPDATE PAQET CORE ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/paqet)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r\n ')

    [[ "$src_choice" == "q" ]] && return

    echo -e "  ${R}● Purging old MPaqet binaries and processes...${NC}"
    systemctl stop mpaqet@* 2>/dev/null
    killall -9 paqet 2>/dev/null
    rm -f /usr/local/bin/paqet /usr/bin/paqet /tmp/paqet_dl /tmp/paqet*

    apt-get update -y -q >/dev/null 2>&1 || echo -e "  ${Y}⚠ Warning: apt-get update failed. Continuing...${NC}"
    apt-get install -y -q libpcap-dev wget curl xxd >/dev/null 2>&1 || { echo -e "  ${R}✖ Critical dependencies failed to install!${NC}"; return; }

    if [[ "$src_choice" == "1" ]]; then
        echo -e "  ${DIM}● Fetching latest release from GitHub API...${NC}"
        local arch=$(uname -m)
        local target="amd64"
        [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="arm64"
        
        local dl_url=$(curl -s https://api.github.com/repos/hanselime/paqet/releases/latest | grep "browser_download_url.*linux-${target}" | cut -d '"' -f 4 | head -1)
        
        if [ -n "$dl_url" ]; then
            wget -qO /tmp/paqet.tar.gz "$dl_url" || { echo -e "  ${R}✖ Download failed!${NC}"; return; }
            if gzip -t /tmp/paqet.tar.gz 2>/dev/null; then
                tar -xzf /tmp/paqet.tar.gz -C /tmp/ >/dev/null 2>&1 || { echo -e "  ${R}✖ Extraction failed!${NC}"; return; }
                local bin_found=$(find /tmp -type f -name "*paqet*" -executable | head -1)
                
                if [ -n "$bin_found" ]; then
                    mv "$bin_found" /usr/local/bin/paqet
                    chmod +x /usr/local/bin/paqet
                    echo -e "  ${G}✔ MPaqet Core installed successfully.${NC}"
                else
                    echo -e "  ${R}✖ Binary not found in archive!${NC}"
                fi
                rm -rf /tmp/paqet*
            else
                echo -e "  ${R}✖ Downloaded file is corrupted or not a valid archive!${NC}"
            fi
        else
            echo -e "  ${R}✖ Failed to fetch release URL from GitHub!${NC}"
        fi

    elif [[ "$src_choice" == "2" ]]; then
        echo -ne "  ${C}● Enter Direct Link: ${NC}"; read custom_url
        custom_url=$(echo "$custom_url" | tr -d '\r')
        if [ -n "$custom_url" ]; then
            echo -e "  ${DIM}● Downloading from Custom Link...${NC}"
            wget -qO /tmp/paqet_dl "$custom_url" || { echo -e "  ${R}✖ Download failed! Check the link.${NC}"; return; }
            
            if gzip -t /tmp/paqet_dl 2>/dev/null; then
                tar -xzf /tmp/paqet_dl -C /tmp/ >/dev/null 2>&1
                local bin_found=$(find /tmp -type f -name "*paqet*" -executable | head -1)
                if [ -n "$bin_found" ]; then 
                    mv "$bin_found" /usr/local/bin/paqet
                else 
                    mv /tmp/paqet_dl /usr/local/bin/paqet
                fi
            else
                mv /tmp/paqet_dl /usr/local/bin/paqet
            fi
            chmod +x /usr/local/bin/paqet
            echo -e "  ${G}✔ MPaqet Core installed from custom link.${NC}"
        fi

    elif [[ "$src_choice" == "3" ]]; then
        if [ -s "$LOCAL_DIR/packages/paqet" ]; then
            cp "$LOCAL_DIR/packages/paqet" /usr/local/bin/paqet
            chmod +x /usr/local/bin/paqet
            echo -e "  ${G}✔ MPaqet Core restored from Local Directory.${NC}"
        else
            echo -e "  ${R}✖ File not found in $LOCAL_DIR/packages/paqet!${NC}"
        fi
    fi

    [ -f "/usr/local/bin/paqet" ] && ln -sf /usr/local/bin/paqet /usr/bin/paqet 2>/dev/null
    
    echo -e "  ${DIM}● Restarting active tunnels...${NC}"
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            t_name=$(basename "$conf" .meta)
            systemctl start "mpaqet@${t_name}" 2>/dev/null
        fi
    done
    sleep 2
}

install_paqet_silent() {
    if ! command -v paqet >/dev/null 2>&1 && [ ! -f "/usr/local/bin/paqet" ]; then
        apt-get update -y -q >/dev/null 2>&1
        apt-get install -y -q libpcap-dev wget curl xxd >/dev/null 2>&1
        local arch=$(uname -m)
        local target="amd64"
        [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="arm64"
        local dl_url=$(curl -s https://api.github.com/repos/hanselime/paqet/releases/latest | grep "browser_download_url.*linux-${target}" | cut -d '"' -f 4 | head -1)
        if [ -n "$dl_url" ]; then
            wget -qO /tmp/paqet.tar.gz "$dl_url" >/dev/null 2>&1
            if gzip -t /tmp/paqet.tar.gz 2>/dev/null; then
                tar -xzf /tmp/paqet.tar.gz -C /tmp/ >/dev/null 2>&1
                local bin_found=$(find /tmp -type f -name "*paqet*" -executable | head -1)
                if [ -n "$bin_found" ]; then
                    mv "$bin_found" /usr/local/bin/paqet
                    chmod +x /usr/local/bin/paqet
                fi
                rm -rf /tmp/paqet*
            fi
        fi
    fi
    [ -f "/usr/local/bin/paqet" ] && ln -sf /usr/local/bin/paqet /usr/bin/paqet 2>/dev/null
}

setup_paqet_counters() {
    local name="$1"; local l_port="$2"
    iptables -t mangle -C INPUT -p tcp --dport "$l_port" -m comment --comment "MPAQET_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -p tcp --dport "$l_port" -m comment --comment "MPAQET_RX_${name}" 2>/dev/null
    iptables -t mangle -C OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_TX_${name}" 2>/dev/null
    
    iptables -t raw -C PREROUTING -p tcp --dport "$l_port" -m comment --comment "MPAQET_RAW_${name}" >/dev/null 2>&1 || iptables -t raw -A PREROUTING -p tcp --dport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" 2>/dev/null
    iptables -t raw -C OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_RAW_${name}" >/dev/null 2>&1 || iptables -t raw -A OUTPUT -p tcp --sport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" 2>/dev/null
    
    iptables -t mangle -C OUTPUT -p tcp --sport "$l_port" --tcp-flags RST RST -m comment --comment "MPAQET_RST_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -p tcp --sport "$l_port" --tcp-flags RST RST -j DROP -m comment --comment "MPAQET_RST_${name}" 2>/dev/null
}

clean_paqet_counters() {
    local name="$1"
    iptables -t mangle -S 2>/dev/null | grep -E "MPAQET_(RX|TX|RST)_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t mangle $r 2>/dev/null; done
    iptables -t raw -S 2>/dev/null | grep "MPAQET_RAW_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t raw $r 2>/dev/null; done
}

get_paqet_rx() {
    local rx=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep "MPAQET_RX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${rx:-0}"
}

get_paqet_tx() {
    local tx=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null | grep "MPAQET_TX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${tx:-0}"
}

check_paqet_connection() {
    local t_name="$1"
    local meta="$CONF_DIR/${t_name}.meta"
    [ ! -f "$meta" ] && { echo "OFFLINE"; return; }
    
    if ! systemctl is-active --quiet "mpaqet@${t_name}" 2>/dev/null; then echo "OFFLINE"; return; fi

    local ROLE=$(grep -m1 "^ROLE=" "$meta" | cut -d'=' -f2 | tr -d '"')
    local TUN_PORT=$(grep -m1 "^TUN_PORT=" "$meta" | cut -d'=' -f2 | tr -d '"')
    
    if [ "$ROLE" == "1" ]; then
        if ss -tHn sport = ":$TUN_PORT" 2>/dev/null | grep -q "ESTAB"; then echo "ONLINE"; else echo "WAITING"; fi
    else
        if ss -tHn dport = ":$TUN_PORT" 2>/dev/null | grep -q "ESTAB"; then echo "ONLINE"; else echo "CONNECTING"; fi
    fi
}

draw_header() {
    local s_ip=$(get_local_ip); local total_tunnels=0; local online_tunnels=0; local active_t=0
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            ((total_tunnels++))
            local t_name=$(basename "$conf" .meta)
            if systemctl is-active --quiet "mpaqet@${t_name}" 2>/dev/null; then
                ((active_t++))
                local st=$(check_paqet_connection "$t_name")
                [ "$st" == "ONLINE" ] && ((online_tunnels++))
            fi
        fi
    done
    
    local core_color="${R}"; local core_raw="Not Installed"
    if command -v paqet >/dev/null 2>&1 || [ -f "/usr/local/bin/paqet" ]; then
        core_color="${G}"; core_raw="Installed"
    fi

    local act_color="${DIM}"; local act_text="0/0"
    if [ "$total_tunnels" -gt 0 ]; then
        act_text="${active_t}/${total_tunnels}"
        if [ "$active_t" -eq "$total_tunnels" ]; then act_color="${G}"
        elif [ "$active_t" -gt 0 ]; then act_color="${Y}"
        else act_color="${R}"; fi
    fi

    local stat_color="${R}"; local stat_icon="○"; local stat_text="STOPPED  "
    local stat_raw="STOPPED"
    if [ "$active_t" -gt 0 ]; then
        if [ "$online_tunnels" -eq "$active_t" ]; then 
            stat_color="${G}"; stat_icon="●"; stat_text="CONNECTED"; stat_raw="CONNECTED"
        elif [ "$online_tunnels" -gt 0 ]; then 
            stat_color="${Y}"; stat_icon="◐"; stat_text="PARTIAL  "; stat_raw="PARTIAL"
        else 
            stat_color="${Y}"; stat_icon="◎"; stat_text="WAITING  "; stat_raw="WAITING"
        fi
    fi

    local title=" MPaqet Engine v7.5.0 "
    local ip_lbl=" IP: "
    local core_lbl=" Core: "
    local act_lbl=" ACTIVE: "
    local stat_lbl=" STATUS: "
    
    local raw_len=$(( ${#title} + 1 + ${#ip_lbl} + ${#s_ip} + 1 + 1 + ${#core_lbl} + ${#core_raw} + 1 + 1 + ${#act_lbl} + ${#act_text} + 1 + 1 + ${#stat_lbl} + 2 + ${#stat_raw} ))
    local pad_len=$(( 106 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    clear; echo -e "\n  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${title}${NC}${B}│${NC}${DIM}${ip_lbl}${NC}${W}${s_ip} ${NC}${B}│${NC}${DIM}${core_lbl}${NC}${core_color}${core_raw} ${NC}${B}│${NC}${DIM}${act_lbl}${NC}${act_color}${act_text} ${NC}${B}│${NC}${DIM}${stat_lbl}${NC}${stat_color}${stat_icon} ${stat_text}${padding}${B}│${NC}"
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

setup_systemd_service() {
    cat <<'EOF' > /etc/systemd/system/mpaqet@.service
[Unit]
Description=MPaqet Raw Packet Tunnel (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/paqet run -c /etc/paqet/%i.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

show_live_radar() {
    tput civis; clear
    declare -A rx_old tx_old

    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        rx_old[$t_name]=$(get_paqet_rx "$t_name")
        tx_old[$t_name]=$(get_paqet_tx "$t_name")
    done

    while true; do
        printf "\033[H"; draw_header
        echo -e "\n  ${DIM}┌─[ PAQET TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL RX" "∑ TOTAL TX"
        echo -e "  ${B}├──────────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤${NC}"

        local count=0
        for conf in "$CONF_DIR"/*.meta; do
            [ ! -f "$conf" ] && continue
            local t_name=$(basename "$conf" .meta)
            local st=$(check_paqet_connection "$t_name")
            local st_color="${R}"; local st_text="OFFLINE"
            if [ "$st" == "ONLINE" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING"; fi

            local r_new=$(get_paqet_rx "$t_name"); local t_new=$(get_paqet_tx "$t_name")
            local r_prev=${rx_old[$t_name]:-$r_new}; local t_prev=${tx_old[$t_name]:-$t_new}
            local rx_s=$((r_new - r_prev)); local tx_s=$((t_new - t_prev))
            [ "$rx_s" -lt 0 ] && rx_s=0; [ "$tx_s" -lt 0 ] && tx_s=0
            rx_old[$t_name]=$r_new; tx_old[$t_name]=$t_new

            local c_rx="${DIM}"; [ "$rx_s" -gt 0 ] && c_rx="${G}"
            local c_tx="${DIM}"; [ "$tx_s" -gt 0 ] && c_tx="${Y}"

            printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} %b%-10s%b ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "$t_name" "$st_color" "$st_text" "$NC" "$c_rx" "$(format_speed $rx_s)" "$NC" "$c_tx" "$(format_speed $tx_s)" "$NC" "$(format_total $r_new)" "$(format_total $t_new)"
            ((count++))
        done

        if [ "$count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" "  No active Paqet tunnels configured."
        fi
        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\e' ]]; then break; fi
    done
    tput cnorm
}

edit_paqet_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.yaml 2>/dev/null))
    [ ${#configs[@]} -eq 0 ] && { echo -e "\n  ${R}● No tunnels configured!${NC}"; sleep 1.5; return; }

    echo -e "\n  ${B}╭────────────────── Select Tunnel to Edit ───────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .yaml)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}● Select Index: ${NC}"; read t_idx
    t_idx=$(echo "$t_idx" | tr -dc '0-9')
    [[ -z "$t_idx" || -z "${configs[$t_idx]}" ]] && return

    local sel_cfg="${configs[$t_idx]}"
    local old_tname=$(basename "$sel_cfg" .yaml)

    echo -e "\n  ${DIM}┌─[ EDIT PAQET TUNNEL: ${W}${old_tname}${DIM} ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Edit KCP Mode (normal, fast, fast2, fast3)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Edit MTU Size (1000-1500)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Edit Connection Count (conn: 1-32)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Edit Encryption (aes-128-gcm, aes-256, none)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read e_opt
    e_opt=$(echo "$e_opt" | tr -dc '0-9')

    case $e_opt in
        1)
           echo -ne "  ${C}● New KCP Mode [normal|fast|fast2|fast3]: ${NC}"; read n_m
           n_m=$(echo "$n_m" | tr -dc 'a-zA-Z0-9')
           if [[ "$n_m" =~ ^(normal|fast|fast2|fast3)$ ]]; then
               sed -i "s|mode:.*|mode: \"$n_m\"|" "$sel_cfg"
           else
               echo -e "  ${R}✖ Invalid Mode!${NC}"; sleep 1.5; return
           fi
           ;;
        2)
           echo -ne "  ${C}● New MTU Size [1000-1500]: ${NC}"; read n_mtu
           n_mtu=$(echo "$n_mtu" | tr -dc '0-9')
           if [[ ! "$n_mtu" =~ ^[0-9]+$ ]] || [ "$n_mtu" -lt 1000 ] || [ "$n_mtu" -gt 1500 ]; then 
               echo -e "  ${R}✖ MTU must be between 1000 and 1500!${NC}"; sleep 1.5; return
           fi
           sed -i "s|mtu:.*|mtu: $n_mtu|" "$sel_cfg"
           ;;
        3)
           echo -ne "  ${C}● New Connections Count [1-32]: ${NC}"; read n_c
           n_c=$(echo "$n_c" | tr -dc '0-9')
           if [[ ! "$n_c" =~ ^[0-9]+$ ]] || [ "$n_c" -lt 1 ] || [ "$n_c" -gt 32 ]; then 
               echo -e "  ${R}✖ Connections must be between 1 and 32!${NC}"; sleep 1.5; return
           fi
           sed -i "s|conn:.*|conn: $n_c|" "$sel_cfg"
           ;;
        4)
           echo -ne "  ${C}● New Encryption Block [aes-128-gcm|aes-256|none]: ${NC}"; read n_b
           n_b=$(echo "$n_b" | tr -dc 'a-zA-Z0-9-')
           if [[ "$n_b" =~ ^(aes-128-gcm|aes-256|none)$ ]]; then
               sed -i "s|block:.*|block: \"$n_b\"|" "$sel_cfg"
           else
               echo -e "  ${R}✖ Invalid Encryption!${NC}"; sleep 1.5; return
           fi
           ;;
        *) return ;;
    esac

    systemctl restart "mpaqet@${old_tname}" 2>/dev/null
    sleep 1.5
    if systemctl is-active --quiet "mpaqet@${old_tname}"; then
        echo -e "\n  ${G}● Tunnel [${old_tname}] updated and restarted successfully!${NC}"; sleep 2
    else
        echo -e "\n  ${R}✖ Failed to start! Checking logs...${NC}"
        journalctl -u "mpaqet@${old_tname}" -n 5 --no-pager
        echo -ne "  ${DIM}Press Enter...${NC}"; read dummy
    fi
}

install_paqet_silent
setup_systemd_service

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ PAQET ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup Server Tunnel (Kharej Raw Listener)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Setup Client Tunnel (Iran Port Forward)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Advanced Edit Tunnel (Mode/MTU/Conn/Crypto)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Live Traffic & Bandwidth Radar${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${M}Install / Update MPaqet Core${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}PAQET ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -dc '0-9')
    
    case $opt in
        1)
           echo -ne "\n  ${C}● Tunnel Suffix Name (e.g. srv1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
           if [ -z "$suffix" ]; then echo -e "  ${R}✖ Invalid Name!${NC}"; sleep 1.5; continue; fi
           
           t_name="pq_${suffix}"
           
           if [ -f "$CONF_DIR/${t_name}.yaml" ]; then
               echo -e "  ${R}✖ Tunnel '${t_name}' already exists! Delete it first or use another name.${NC}"; sleep 2; continue
           fi
           
           iface=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
           [ -z "$iface" ] && iface=$(ip link show | grep -v "lo:" | awk -F': ' '{print $2}' | head -1)
           [ -z "$iface" ] && iface="eth0"
           
           l_ip=$(get_local_ip)
           
           gw_mac=$(ip neigh show dev "$iface" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
           [ -z "$gw_mac" ] && gw_mac=$(ip neigh show 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
           [ -z "$gw_mac" ] && gw_mac="00:00:00:00:00:00"
           
           if [ "$gw_mac" == "00:00:00:00:00:00" ]; then
               echo -e "  ${Y}⚠ Warning: MAC address could not be resolved. Raw packets may fail to route properly!${NC}"
               sleep 2
           fi
           
           while true; do
               echo -ne "  ${C}● Tunnel Listen Port [8888]: ${NC}"; read t_port
               t_port=$(echo "$t_port" | tr -dc '0-9')
               t_port=${t_port:-8888}
               if [ -n "$t_port" ] && [ "$t_port" -le 65535 ]; then break; else echo -e "  ${R}✖ Invalid port!${NC}"; fi
           done
           
           s_key=$(head -c 16 /dev/urandom | xxd -p 2>/dev/null)
           [ -z "$s_key" ] && s_key=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)
           echo -ne "  ${C}● Secret Key [Default ${s_key}]: ${NC}"; read u_key
           u_key=$(echo "$u_key" | tr -dc 'a-zA-Z0-9_=-')
           key=${u_key:-$s_key}
           
           > "$CONF_DIR/${t_name}.yaml.tmp"
           cat <<'EOF' > "$CONF_DIR/${t_name}.yaml.tmp"
role: "server"
log:
  level: "info"
listen:
  addr: ":%PORT%"
network:
  interface: "%IFACE%"
  ipv4:
    addr: "%LIP%:%PORT%"
    router_mac: "%MAC%"
  tcp:
    local_flag: ["PA"]
transport:
  protocol: "kcp"
  conn: 4
  kcp:
    key: "%KEY%"
    mode: "fast"
    block: "aes-128-gcm"
    mtu: 1350
EOF
           sed -e "s|%PORT%|${t_port}|g" \
               -e "s|%IFACE%|${iface}|g" \
               -e "s|%LIP%|${l_ip}|g" \
               -e "s|%MAC%|${gw_mac}|g" \
               -e "s|%KEY%|${key}|g" \
               "$CONF_DIR/${t_name}.yaml.tmp" > "$CONF_DIR/${t_name}.yaml"
           rm -f "$CONF_DIR/${t_name}.yaml.tmp"
           
           echo -e "ROLE=1\nTUN_PORT=$t_port\nREMOTE_IP=0.0.0.0" > "$CONF_DIR/${t_name}.meta"
           
           setup_paqet_counters "$t_name" "$t_port"
           systemctl enable "mpaqet@${t_name}" >/dev/null 2>&1
           systemctl restart "mpaqet@${t_name}"
           
           sleep 1.5
           if systemctl is-active --quiet "mpaqet@${t_name}"; then
               echo -e "\n  ${G}● Paqet Server Tunnel Deployed! Key: ${key}${NC}"; sleep 2
           else
               echo -e "\n  ${R}✖ Failed to start! Checking logs...${NC}"
               journalctl -u "mpaqet@${t_name}" -n 5 --no-pager
               echo -ne "  ${DIM}Press Enter...${NC}"; read dummy
           fi
           ;;
           
        2)
           echo -ne "\n  ${C}● Tunnel Suffix Name (e.g. cl1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
           if [ -z "$suffix" ]; then echo -e "  ${R}✖ Invalid Name!${NC}"; sleep 1.5; continue; fi
           
           t_name="pq_${suffix}"
           
           if [ -f "$CONF_DIR/${t_name}.yaml" ]; then
               echo -e "  ${R}✖ Tunnel '${t_name}' already exists! Delete it first or use another name.${NC}"; sleep 2; continue
           fi
           
           iface=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
           [ -z "$iface" ] && iface=$(ip link show | grep -v "lo:" | awk -F': ' '{print $2}' | head -1)
           [ -z "$iface" ] && iface="eth0"
           
           l_ip=$(get_local_ip)
           
           gw_mac=$(ip neigh show dev "$iface" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
           [ -z "$gw_mac" ] && gw_mac=$(ip neigh show 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
           [ -z "$gw_mac" ] && gw_mac="00:00:00:00:00:00"
           
           if [ "$gw_mac" == "00:00:00:00:00:00" ]; then
               echo -e "  ${Y}⚠ Warning: MAC address could not be resolved. Raw packets may fail to route properly!${NC}"
               sleep 2
           fi
           
           while true; do
               echo -ne "  ${C}● Remote Kharej Server IP: ${NC}"; read r_ip
               r_ip=$(echo "$r_ip" | tr -dc '0-9.')
               if [[ "$r_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then break; else echo -e "  ${R}✖ Invalid IPv4 format!${NC}"; fi
           done
           
           while true; do
               echo -ne "  ${C}● Remote Listen Port [8888]: ${NC}"; read r_port
               r_port=$(echo "$r_port" | tr -dc '0-9')
               r_port=${r_port:-8888}
               if [ -n "$r_port" ] && [ "$r_port" -le 65535 ]; then break; else echo -e "  ${R}✖ Invalid port!${NC}"; fi
           done
           
           echo -ne "  ${C}● Secret Key (from Server): ${NC}"; read key
           key=$(echo "$key" | tr -dc 'a-zA-Z0-9_=-')
           
           fwd_ports=""
           while true; do
               echo -ne "  ${C}● Forward Ports (e.g. 443,8080): ${NC}"; read fwd_ports
               fwd_ports=$(echo "$fwd_ports" | tr -dc '0-9,')
               if [ -z "$fwd_ports" ]; then
                   echo -e "  ${R}Error: MUST specify at least one forwarded port!${NC}"
               else
                   break
               fi
           done
           
           if echo ",$fwd_ports," | grep -q ",$r_port,"; then
               echo -e "  ${R}✖ Loop Error: Forward port cannot match Tunnel port ($r_port)!${NC}"; sleep 2; continue
           fi
           
           > "$CONF_DIR/${t_name}.yaml.tmp"
           cat <<'EOF' > "$CONF_DIR/${t_name}.yaml.tmp"
role: "client"
log:
  level: "info"
forward:
EOF
           IFS=',' read -ra P_ARR <<< "$fwd_ports"
           for p_raw in "${P_ARR[@]}"; do
               p_clean=$(echo "$p_raw" | tr -dc '0-9')
               if [ -n "$p_clean" ] && [ "$p_clean" -le 65535 ]; then
                   echo "  - listen: \"0.0.0.0:$p_clean\"" >> "$CONF_DIR/${t_name}.yaml.tmp"
                   echo "    target: \"127.0.0.1:$p_clean\"" >> "$CONF_DIR/${t_name}.yaml.tmp"
                   echo "    protocol: \"tcp\"" >> "$CONF_DIR/${t_name}.yaml.tmp"
                   setup_paqet_counters "$t_name" "$p_clean"
               fi
           done
           
           cat <<'EOF' >> "$CONF_DIR/${t_name}.yaml.tmp"
network:
  interface: "%IFACE%"
  ipv4:
    addr: "%LIP%:0"
    router_mac: "%MAC%"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
server:
  addr: "%RIP%:%RPORT%"
transport:
  protocol: "kcp"
  conn: 4
  kcp:
    key: "%KEY%"
    mode: "fast"
    block: "aes-128-gcm"
    mtu: 1350
EOF
           sed -e "s|%IFACE%|${iface}|g" \
               -e "s|%LIP%|${l_ip}|g" \
               -e "s|%MAC%|${gw_mac}|g" \
               -e "s|%RIP%|${r_ip}|g" \
               -e "s|%RPORT%|${r_port}|g" \
               -e "s|%KEY%|${key}|g" \
               "$CONF_DIR/${t_name}.yaml.tmp" > "$CONF_DIR/${t_name}.yaml"
           rm -f "$CONF_DIR/${t_name}.yaml.tmp"

           echo -e "ROLE=2\nTUN_PORT=$r_port\nREMOTE_IP=$r_ip" > "$CONF_DIR/${t_name}.meta"

           systemctl enable "mpaqet@${t_name}" >/dev/null 2>&1
           systemctl restart "mpaqet@${t_name}"
           
           sleep 1.5
           if systemctl is-active --quiet "mpaqet@${t_name}"; then
               echo -e "\n  ${G}● Paqet Client Tunnel Deployed!${NC}"; sleep 2
           else
               echo -e "\n  ${R}✖ Failed to start! Checking logs...${NC}"
               journalctl -u "mpaqet@${t_name}" -n 5 --no-pager
               echo -ne "  ${DIM}Press Enter...${NC}"; read dummy
           fi
           ;;
           
        3) edit_paqet_tunnel ;;
        4) show_live_radar ;;
        5)
           configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"; done
           echo -ne "  ${C}● Enter Index or 'all': ${NC}"; read del_idx
           del_idx=$(echo "$del_idx" | tr -dc '0-9a-zA-Z')
           
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do
                   t_name=$(basename "$conf" .meta)
                   systemctl stop "mpaqet@${t_name}" 2>/dev/null; systemctl disable "mpaqet@${t_name}" 2>/dev/null
                   clean_paqet_counters "$t_name"
                   rm -f "$conf" "$CONF_DIR/${t_name}.yaml"
               done
               echo -e "  ${G}● All Tunnels Purged!${NC}"; sleep 1.5
           elif [[ "$del_idx" =~ ^[0-9]+$ ]] && [[ -n "${configs[$del_idx]}" ]]; then
               t_name=$(basename "${configs[$del_idx]}" .meta)
               systemctl stop "mpaqet@${t_name}" 2>/dev/null; systemctl disable "mpaqet@${t_name}" 2>/dev/null
               clean_paqet_counters "$t_name"
               rm -f "${configs[$del_idx]}" "$CONF_DIR/${t_name}.yaml"
               echo -e "  ${G}● Purged!${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Invalid Selection!${NC}"; sleep 1.5
           fi ;;
        6) menu_install_core ;;
        0) break ;;
    esac
done
