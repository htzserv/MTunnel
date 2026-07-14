#!/bin/bash
# --- MDesign Modular Core (mbackhaul.sh) | Backhaul Engine v6.1.5 (Phantom Edition) ---

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
            cp "$LOCAL_DIR/bh" /usr/local/bin/bh; chmod +x /usr/local/bin/bh
            echo -e "  ${G}● Engine installed successfully!${NC}"
        else
            echo -e "  ${R}● FATAL ERROR: Failed to download 'bh'!${NC}"; sleep 3; exit 1
        fi
    fi
}

apply_service() {
    cat <<EOF > "$SERVICE_TPL"
[Unit]
Description=MBackhaul Multiplexer (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/bh -c $CONF_DIR/%i.toml
Restart=always
RestartSec=3
StartLimitIntervalSec=0
LimitNOFILE=1048576
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

draw_header() {
    local s_ip=$(get_local_ip); local active=0; local total=0
    for conf in "$CONF_DIR"/*.toml; do 
        [ -f "$conf" ] || continue
        ((total++))
        local name=$(basename "$conf" .toml)
        systemctl is-active --quiet "mbackhaul@$name" && ((active++))
    done
    local c_stat="${DIM}0 / 0${NC}"
    [ "$total" -gt 0 ] && [ "$active" -eq "$total" ] && c_stat="${G}$active / $total (STABLE)${NC}"
    [ "$total" -gt 0 ] && [ "$active" -lt "$total" ] && c_stat="${R}$active / $total (ISSUES)${NC}"

    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MBackhaul Multiplexer v6.1.5${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}NODES:${NC} ${c_stat} ${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
}

list_nodes() {
    echo -e "\n  ${Y}● Active Tunnels Matrix:${NC}"
    local count=0
    for conf in "$CONF_DIR"/*.toml; do
        [ ! -f "$conf" ] && continue
        ((count++)); local name=$(basename "$conf" .toml)
        local sys_stat="${DIM}○ STOPPED${NC}"; local net_stat=""
        
        systemctl is-active --quiet "mbackhaul@$name" && sys_stat="${G}● RUNNING${NC}"

        local mode="Unknown"; local port=""; local remote=""; local proto="tcp"
        if grep -q "\[server\]" "$conf"; then 
            mode="${M}KHAREJ (Server)${NC}"
            port=$(grep 'bind =' "$conf" | grep -oP ':[0-9]+' | head -1 | tr -d ':')
            proto=$(grep 'bind =' "$conf" | grep -oP '"\K[a-zA-Z0-9]+(?=://)')
            grep -q "nodelay=true" "$conf" && proto="${proto}_nodelay"
            
            if [[ "$sys_stat" == *RUNNING* ]]; then
                if ss -tuln 2>/dev/null | grep -q ":$port "; then net_stat="${G}[Listening]${NC}"
                else net_stat="${R}[Port Error/Blocked]${NC}"; sys_stat="${R}● ERROR${NC}"; fi
            fi
        elif grep -q "\[client\]" "$conf"; then 
            mode="${C}IRAN (Client)${NC}"
            
            # --- REGEX FIX: Stripping protocol prefix safely ---
            local raw_remote=$(grep 'remote =' "$conf" | grep -oP '"\K[^"]+' | cut -d'?' -f1 | sed -E 's/^[a-zA-Z0-9_]+:\/\///')
            remote=$(grep 'remote =' "$conf" | grep -oP '"\K[^"]+' | cut -d'?' -f1)
            proto=$(grep 'remote =' "$conf" | grep -oP '"\K[a-zA-Z0-9]+(?=://)')
            grep -q "nodelay=true" "$conf" && proto="${proto}_nodelay"
            
            local r_ip=$(echo "$raw_remote" | cut -d: -f1); local r_port=$(echo "$raw_remote" | cut -d: -f2)
            if [[ "$sys_stat" == *RUNNING* ]]; then
                if timeout 1 bash -c "</dev/tcp/$r_ip/$r_port" 2>/dev/null; then net_stat="${G}[Connected]${NC}"
                else net_stat="${R}[Unreachable/Blocked]${NC}"; sys_stat="${Y}● RECONNECTING${NC}"; fi
            fi
        fi
        
        [ -z "$proto" ] && proto="tcp"
        
        local spoof_badge=""
        if grep -q 'profile = "ipip"' "$conf"; then spoof_badge="${M}[IPIP SPOOFED]${NC}"; fi

        echo -e "  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC} ${DIM}Node Name :${NC} ${W}$name${NC}  ${DIM}Status:${NC} $sys_stat $net_stat"
        echo -e "  ${B}│${NC} ${DIM}Mode      :${NC} $mode"
        echo -e "  ${B}│${NC} ${DIM}Protocol  :${NC} ${Y}${proto^^}${NC} $spoof_badge"
        [ -n "$port" ] && echo -e "  ${B}│${NC} ${DIM}Bind Port :${NC} ${Y}$port${NC}"
        [ -n "$remote" ] && echo -e "  ${B}│${NC} ${DIM}Target IP :${NC} ${Y}$remote${NC}"
        if grep -q "\[\[client.ports\]\]" "$conf"; then
            local ports=$(grep 'local =' "$conf" | grep -oP ':\K[0-9]+' | tr -d '"' | paste -sd "," -)
            local clean_p=$(echo "$ports" | cut -c 1-35); [ ${#ports} -gt 35 ] && clean_p="${clean_p}..."
            echo -e "  ${B}│${NC} ${DIM}Fwd Ports :${NC} ${G}$clean_p${NC}"
        fi
        echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    done
    [ "$count" -eq 0 ] && echo -e "  ${DIM}No Backhaul nodes configured yet.${NC}"
}

select_protocol() {
    echo -e "\n  ${DIM}┌─[ BACKHAUL TRANSPORT PROTOCOLS (FULL ARSENAL) ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC}  ${DIM}❯${NC} ${C}tcp${NC}             ${DIM}7${NC}  ${DIM}❯${NC} ${M}wss${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC}  ${DIM}❯${NC} ${C}tcp_nodelay${NC}     ${DIM}8${NC}  ${DIM}❯${NC} ${M}mwss${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC}  ${DIM}❯${NC} ${Y}tcpmux${NC}          ${DIM}9${NC}  ${DIM}❯${NC} ${B}h2c${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC}  ${DIM}❯${NC} ${Y}tcpmux_nodelay${NC}  ${DIM}10${NC} ${DIM}❯${NC} ${R}grpc${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC}  ${DIM}❯${NC} ${G}ws${NC}              ${DIM}11${NC} ${DIM}❯${NC} ${G}quic${NC}"
    echo -e "  ${DIM}└─${NC} ${W}6${NC}  ${DIM}❯${NC} ${G}mws${NC}             ${DIM}12${NC} ${DIM}❯${NC} ${M}webtransport${NC}"
    echo -ne "\n  ${C}Select Protocol [Default 3] ❯❯ ${NC}"; read p_opt
    p_opt=$(echo "$p_opt" | tr -d '\r' | tr -d ' ')
    
    case $p_opt in
        1) scheme="tcp"; s_suffix=""; c_suffix="" ;;
        2) scheme="tcp"; s_suffix="?nodelay=true"; c_suffix="?nodelay=true" ;;
        3) scheme="tcpmux"; s_suffix=""; c_suffix="" ;;
        4) scheme="tcpmux"; s_suffix="?nodelay=true"; c_suffix="?nodelay=true" ;;
        5) scheme="ws"; s_suffix="/?path=/mdesign"; c_suffix="/?path=/mdesign" ;;
        6) scheme="mws"; s_suffix="/?path=/mdesign"; c_suffix="/?path=/mdesign" ;;
        7) scheme="wss"; s_suffix="/?path=/mdesign"; c_suffix="/?path=/mdesign&insecure=true" ;;
        8) scheme="mwss"; s_suffix="/?path=/mdesign"; c_suffix="/?path=/mdesign&insecure=true" ;;
        9) scheme="h2c"; s_suffix=""; c_suffix="" ;;
        10) scheme="grpc"; s_suffix=""; c_suffix="?insecure=true" ;;
        11) scheme="quic"; s_suffix=""; c_suffix="?insecure=true" ;;
        12) scheme="webtransport"; s_suffix=""; c_suffix="?insecure=true" ;;
        *) scheme="tcpmux"; s_suffix=""; c_suffix="" ;;
    esac
}

configure_spoofing() {
    echo -ne "\n  ${C}●${NC} ${M}Enable L3 IP Spoofing (IPIP Fake Traffic)? (y/n) [n]: ${NC}"; read use_spoof
    use_spoof=$(echo "$use_spoof" | tr -d '\r' | tr -d ' ')
    if [[ "$use_spoof" == "y" ]]; then
        echo -e "  ${DIM}Tip: Destination IP should be a whitelisted domestic IP (e.g. Bank, Aparat)${NC}"
        echo -ne "  ${C}●${NC} ${W}Spoof Destination IP (e.g. 185.166.104.6): ${NC}"; read sp_dst
        echo -ne "  ${C}●${NC} ${W}Spoof Source IP (e.g. 185.143.234.120): ${NC}"; read sp_src
        sp_dst=$(echo "$sp_dst" | tr -d '\r' | tr -d ' ')
        sp_src=$(echo "$sp_src" | tr -d '\r' | tr -d ' ')
        
        # --- TOML SYNTAX FIX ---
        spoof_conf="
profile = \"ipip\"
spoof_dst_ip = \"$sp_dst\"
spoof_src_ip = \"$sp_src\""
    else
        spoof_conf=""
    fi
}

view_logs() {
    configs=($(ls "$CONF_DIR"/*.toml 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No nodes found!${NC}"; sleep 2; return; fi
    
    echo -e "\n  ${B}╭────────────────── Select Node to Diagnose ────────────────╮${NC}"
    for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .toml)"; done
    echo -e "  ${B}╰───────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Index: ${NC}"; read d_idx
    d_idx=$(echo "$d_idx" | tr -d '\r' | tr -d ' ')
    
    if [[ -n "${configs[$d_idx]}" ]]; then
        local name=$(basename "${configs[$d_idx]}" .toml); local conf="${configs[$d_idx]}"
        clear; echo -e "\n  ${M}┌─[ LIVE DIAGNOSTICS: $name ]──────────────────────────────${NC}"
        
        if systemctl is-active --quiet "mbackhaul@$name"; then echo -e "  ${DIM}├─ Engine Core:${NC} ${G}ACTIVE (Running without crashing)${NC}"
        else echo -e "  ${DIM}├─ Engine Core:${NC} ${R}CRASHED (Systemd failed to start engine)${NC}"; fi
        
        if grep -q "\[server\]" "$conf"; then
            local port=$(grep 'bind =' "$conf" | grep -oP ':[0-9]+' | head -1 | tr -d ':')
            if ss -tuln 2>/dev/null | grep -q ":$port "; then echo -e "  ${DIM}├─ Network I/O:${NC} ${G}Port $port is successfully opened and listening.${NC}"
            else echo -e "  ${DIM}├─ Network I/O:${NC} ${R}PORT ERROR! Port $port is in use or blocked.${NC}"; fi
        elif grep -q "\[client\]" "$conf"; then
            local raw_remote=$(grep 'remote =' "$conf" | grep -oP '"\K[^"]+' | cut -d'?' -f1 | sed -E 's/^[a-zA-Z0-9_]+:\/\///')
            local r_ip=$(echo "$raw_remote" | cut -d: -f1); local r_port=$(echo "$raw_remote" | cut -d: -f2)
            if timeout 1 bash -c "</dev/tcp/$r_ip/$r_port" 2>/dev/null; then echo -e "  ${DIM}├─ Remote Link:${NC} ${G}Handshake with $r_ip:$r_port SUCCESSFUL.${NC}"
            else echo -e "  ${DIM}├─ Remote Link:${NC} ${R}BLOCKED! Cannot reach Kharej Server IP/Port.${NC}"; fi
        fi
        
        echo -e "  ${M}├─[ LIVE SYSTEM LOGS (Last 20 Lines) ]──────────────────────${NC}"
        journalctl -u "mbackhaul@$name" -n 20 --no-pager | sed 's/^/  │ /'
        echo -e "  ${M}└───────────────────────────────────────────────────────────${NC}"
        echo -e "  ${DIM}Tip: Press 'q' to exit if log stuck. If blocked, try WSS or TCPMUX.${NC}"
        echo -ne "\n  ${C}Press Enter to return to menu...${NC}"; read dummy
    fi
}

while true; do
    draw_header; list_nodes
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${M}Setup KHAREJ Node${NC} ${DIM}(Server Mode)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Setup IRAN Node${NC}   ${DIM}(Client Mode + Port Forwarding)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Delete Node${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Diagnose & View Logs${NC} ${DIM}(Live Troubleshooting)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MBACKHAUL ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r' | tr -d ' ')

    case $opt in
        1)
           check_binary
           echo -ne "\n  ${C}●${NC} ${W}Node Name (e.g. bh_kharej): ${NC}"; read b_name
           echo -ne "  ${C}●${NC} ${W}Listen Port for Backhaul Tunnel (e.g. 7000): ${NC}"; read b_port
           echo -ne "  ${C}●${NC} ${W}Secret Token (Password): ${NC}"; read b_token
           b_name=$(echo "$b_name" | tr -d '\r' | tr -d ' ')
           b_port=$(echo "$b_port" | tr -d '\r' | tr -d ' ')
           b_token=$(echo "$b_token" | tr -d '\r')
           
           select_protocol
           configure_spoofing
           
           bind_url="${scheme}://0.0.0.0:${b_port}${s_suffix}"
           conf_path="$CONF_DIR/${b_name}.toml"
           
           cat <<EOF > "$conf_path"
[server]
bind = "$bind_url"
token = "$b_token"
channel_size = 4096${spoof_conf}
EOF
           apply_service; systemctl enable "mbackhaul@$b_name" >/dev/null 2>&1; systemctl restart "mbackhaul@$b_name"
           echo -e "\n  ${G}● Kharej Server Node Deployed successfully!${NC}"; sleep 1.5 ;;
           
        2)
           check_binary
           echo -ne "\n  ${C}●${NC} ${W}Node Name (e.g. bh_iran): ${NC}"; read b_name
           echo -ne "  ${C}●${NC} ${W}Kharej Server Public IP: ${NC}"; read r_ip
           echo -ne "  ${C}●${NC} ${W}Kharej Backhaul Port (e.g. 7000): ${NC}"; read r_port
           echo -ne "  ${C}●${NC} ${W}Secret Token (Must match Kharej): ${NC}"; read b_token
           echo -ne "  ${C}●${NC} ${W}Multiplex Connections [Default: 8]: ${NC}"; read b_conn
           echo -ne "  ${C}●${NC} ${W}Ports to forward (e.g. 80,443,2053): ${NC}"; read raw_ports
           
           b_name=$(echo "$b_name" | tr -d '\r' | tr -d ' ')
           r_ip=$(echo "$r_ip" | tr -d '\r' | tr -d ' ')
           r_port=$(echo "$r_port" | tr -d '\r' | tr -d ' ')
           b_token=$(echo "$b_token" | tr -d '\r')
           b_conn=$(echo "$b_conn" | tr -d '\r' | tr -d ' '); b_conn=${b_conn:-8}
           raw_ports=$(echo "$raw_ports" | tr -d '\r')
           
           select_protocol
           configure_spoofing
           
           remote_url="${scheme}://${r_ip}:${r_port}${c_suffix}"
           conf_path="$CONF_DIR/${b_name}.toml"
           
           cat <<EOF > "$conf_path"
[client]
remote = "$remote_url"
token = "$b_token"
connections = $b_conn${spoof_conf}
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
           echo -e "\n  ${G}● Iran Client Node Deployed and Ports Mapped!${NC}"; sleep 1.5 ;;
           
        3)
           configs=($(ls "$CONF_DIR"/*.toml 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Node to Delete ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .toml)"; done
           echo -e "  ${B}╰───────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Index (or 'all'): ${NC}"; read del_idx
           del_idx=$(echo "$del_idx" | tr -d '\r' | tr -d ' ')
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
        4) view_logs ;;
        0) break ;;
    esac
done
