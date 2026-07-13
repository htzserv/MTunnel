#!/bin/bash
# --- MDesign Master Core | Central Dashboard v7.2.0 (Stable & Local Deploy) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
MTUNNEL_PATH="/usr/bin/mtunnel"

REPO_ZIP="https://github.com/htzserv/MTunnel/archive/refs/heads/main.zip"
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main/main"
LOCAL_DIR="/root/mtunnel"

if [[ ! -x "$MTUNNEL_PATH" ]]; then cp "$0" "$MTUNNEL_PATH" 2>/dev/null && chmod +x "$MTUNNEL_PATH" 2>/dev/null; fi

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_progress_bar() {
    local pid=$1; local text=$2; local width=25; local progress=0
    tput civis
    while kill -0 $pid 2>/dev/null; do
        ((progress++)); if (( progress > 95 )); then progress=95; fi
        local filled=$(( progress * width / 100 )); local empty=$(( width - filled ))
        local bar=$(printf "%${filled}s" "" | tr ' ' '#'); local empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')
        printf "\r  %b⟳%b %b%-22s%b %b[%b%b%b%b]%b %b%3d%%%%%b" "$C" "$NC" "$W" "$text" "$NC" "$M" "$bar" "$DIM" "$empty_bar" "$M" "$NC" "$C" "$progress" "$NC"
        sleep 0.2
    done
    local bar=$(printf "%${width}s" "" | tr ' ' '#')
    printf "\r  %b✔%b %b%-22s%b %b[%b]%b %b100%%%%%b \n" "$G" "$NC" "$W" "$text" "$NC" "$G" "$bar" "$NC" "$G" "$NC"
    tput cnorm
}

run_mod() {
    local mod=$1
    if [ ! -x "/usr/bin/$mod" ]; then
        echo -e "\n  ${Y}● Fetching module [${W}${mod}${Y}] on-demand from GitHub...${NC}"
        mkdir -p "$LOCAL_DIR" 2>/dev/null
        wget --timeout=10 --tries=2 -qO "$LOCAL_DIR/${mod}.sh" "$REPO_SCRIPTS/${mod}.sh?v=$(date +%s)"
        if [ -s "$LOCAL_DIR/${mod}.sh" ]; then
            sed -i 's/\r$//' "$LOCAL_DIR/${mod}.sh" 2>/dev/null
            cat "$LOCAL_DIR/${mod}.sh" > "/usr/bin/$mod"
            chmod +x "/usr/bin/$mod"
        else 
            echo -e "  ${R}● Error: Module not found in 'main' folder!${NC}"; sleep 2; return
        fi
    fi
    $mod
}

draw_main_header() {
    local s_ip=$(get_local_ip)
    local st_gre="○"; local c_gre="${DIM}"; [ -n "$(ls -A /etc/mgre/tunnels/*.conf 2>/dev/null)" ] && { st_gre="●"; c_gre="${G}"; }
    local st_vx="○"; local c_vx="${DIM}"; [ -n "$(ls -A /etc/mgre/vxlan/*.conf 2>/dev/null)" ] && { st_vx="●"; c_vx="${G}"; }
    local st_wg="○"; local c_wg="${DIM}"; ([ -f "/etc/wireguard/wg0.conf" ] || ip link show wg0 >/dev/null 2>&1) && { st_wg="●"; c_wg="${G}"; }
    local st_l2="○"; local c_l2="${DIM}"; [ -n "$(ls -A /etc/ml2tp/tunnels/*.conf 2>/dev/null)" ] && { st_l2="●"; c_l2="${G}"; }
    local st_hys="○"; local c_hys="${DIM}"; [ -n "$(ls -A /etc/mhysteria/tunnels/*.conf 2>/dev/null)" ] && { st_hys="●"; c_hys="${G}"; }
    local st_bh="○"; local c_bh="${DIM}"; [ -n "$(ls -A /etc/mbackhaul/tunnels/*.toml 2>/dev/null)" ] && { st_bh="●"; c_bh="${G}"; }

    clear; echo ""
    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MDesign Master Core v7.2.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC}                                                   ${B}│${NC}"
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}${DIM} Hub: GRE:${NC}${c_gre}${st_gre}${NC}${DIM}  VXLAN:${NC}${c_vx}${st_vx}${NC}${DIM}  WireGuard:${NC}${c_wg}${st_wg}${NC}${DIM}  L2TP:${NC}${c_l2}${st_l2}${NC}${DIM}  Hys2:${NC}${c_hys}${st_hys}${NC}${DIM}  Backhaul:${NC}${c_bh}${st_bh}${NC}${DIM}                      ${B}│${NC}"
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_tunnel_hub() {
    while true; do
        draw_main_header; echo ""
        echo -e "  ${DIM}┌─[ TUNNEL INFRASTRUCTURE HUB ]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Modular GRE/IP6GRE Core (Mgre)${NC}      ${DIM}[Layer 3 Routing]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}VXLAN Virtual Mesh Fabric (Mxlan)${NC}    ${DIM}[Layer 2 Bridge]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}WireGuard Crypto Matrix (Mwire)${NC}      ${DIM}[High-Speed VPN]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}L2TPv3 Native Engine (Ml2tp)${NC}         ${DIM}[Kernel UDP Tunnel]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Hysteria2 QUIC Engine (Mhysteria)${NC}    ${DIM}[Anti-Censorship L3]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${M}FRP Reverse Proxy Engine (Mfrp)${NC}      ${DIM}[NAT Bypass Tunnel]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${G}Backhaul Multiplexer (MBackhaul)${NC}     ${DIM}[TCP/UDP Port Forwarder]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core Dashboard${NC}\n"
        echo -ne "  ${C}TUNNEL ❯❯ ${NC}"; read t_opt
        case $t_opt in
            1) run_mod "mgre" ;; 2) run_mod "mxlan" ;; 3) run_mod "mwire" ;; 4) run_mod "ml2tp" ;; 
            5) run_mod "mhysteria" ;; 6) run_mod "mfrp" ;; 7) run_mod "mbackhaul" ;; 0) break ;;
        esac
    done
}

while true; do
    draw_main_header; echo ""
    echo -e "  ${DIM}┌─[ CORE NETWORK & ROUTING ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Hub${NC} ${DIM}(GRE / L2TP / HYS2 / B-HAUL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding & Failover${NC} ${DIM}(Mporter)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC} ${DIM}(Minterface)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SECURITY & ANALYTICS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Stealth Anti-Probing Shield${NC} ${DIM}(Mshield)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${B}Bandwidth Radar & Web UI${NC} ${DIM}(Mstats & Mweb)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Autonomous Tunnel Healer${NC} ${DIM}(Mhealer)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Network Diagnostics Tools${NC} ${DIM}(Mdiag)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${Y}Download Binary Packages${NC}   ${DIM}(Fetch Backhaul, Gost, FRP from GitHub)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${C}Update Core Scripts${NC}        ${DIM}(Sync .sh files from GitHub)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${M}Offline Local Deploy${NC}       ${DIM}(Install from /root/mtunnel/)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${R}Nuclear Wipe${NC}               ${DIM}(Delete ALL Tunnels & Traces)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}\n"
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read opt

    case $opt in
        1) show_tunnel_hub ;;
        2) run_mod "mporter" ;; 
        3) run_mod "minterface" ;; 
        4) run_mod "mshield" ;;
        5) run_mod "mstats" ;; 
        6) run_mod "mhealer" ;; 
        7) run_mod "mdiag" ;;
        
        8)
           echo -e "\n  ${DIM}┌─[ BINARY ASSETS DOWNLOADER ]${NC}"
           echo -e "  ${C}●${NC} ${W}Downloading required packages from GitHub repository...${NC}"
           mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
           apt-get install -y -q unzip >/dev/null 2>&1
           
           ( wget -qO /tmp/repo.zip "$REPO_ZIP" ) &
           draw_progress_bar $! "Fetching Zip Archive"
           
           if unzip -t /tmp/repo.zip >/dev/null 2>&1; then
               (
                   unzip -q -o /tmp/repo.zip -d /tmp/ 2>/dev/null
                   cp -rf /tmp/MTunnel-main/packages/* "$LOCAL_DIR/packages/" 2>/dev/null
                   chmod +x "$LOCAL_DIR/packages/"* 2>/dev/null
                   
                   [ -f "$LOCAL_DIR/packages/bh" ] && { cp "$LOCAL_DIR/packages/bh" /usr/local/bin/bh; chmod +x /usr/local/bin/bh; }
                   [ -f "$LOCAL_DIR/packages/gost" ] && { cp "$LOCAL_DIR/packages/gost" /usr/local/bin/gost; chmod +x /usr/local/bin/gost; }
                   [ -f "$LOCAL_DIR/packages/frps" ] && { cp "$LOCAL_DIR/packages/frps" /usr/local/bin/frps; chmod +x /usr/local/bin/frps; }
                   [ -f "$LOCAL_DIR/packages/frpc" ] && { cp "$LOCAL_DIR/packages/frpc" /usr/local/bin/frpc; chmod +x /usr/local/bin/frpc; }
                   
                   rm -rf /tmp/MTunnel-main /tmp/repo.zip
               ) &
               draw_progress_bar $! "Extracting & Installing"
               echo -e "\n  ${G}● All Binary Files successfully downloaded and installed!${NC}"; sleep 2
           else
               echo -e "\n  ${R}● Error downloading zip archive from GitHub!${NC}"; sleep 2
           fi
           ;;

        9) 
           echo -e "\n  ${Y}● Syncing .sh components from GitHub...${NC}"
           mkdir -p "$LOCAL_DIR" 2>/dev/null; CACHE_BUST=$(date +%s); download_success=true
           MODULES=("main.sh" "mgre.sh" "mxlan.sh" "mwire.sh" "mfrp.sh" "ml2tp.sh" "mhysteria.sh" "mbackhaul.sh" "mporter.sh" "minterface.sh" "mdiag.sh" "mshield.sh" "mstats.sh" "mhealer.sh" "mweb.sh")
           for file in "${MODULES[@]}"; do
               echo -e "  ${DIM}├─ Fetching $file...${NC}"
               wget --timeout=10 --tries=2 -qO "$LOCAL_DIR/$file" "$REPO_SCRIPTS/${file}?v=$CACHE_BUST"
               if [ ! -s "$LOCAL_DIR/$file" ]; then download_success=false; break; fi
               sed -i 's/\r$//' "$LOCAL_DIR/$file" 2>/dev/null
           done
           if [ "$download_success" = true ]; then
               for file in "${MODULES[@]}"; do
                   mod_name="${file%.sh}"; [ "$mod_name" == "main" ] && mod_name="mtunnel"
                   cat "$LOCAL_DIR/$file" > "/usr/bin/$mod_name" 2>/dev/null; chmod +x "/usr/bin/$mod_name" 2>/dev/null
               done
               echo -e "\n  ${G}● Core scripts fully upgraded!${NC}"; sleep 1.5; exec "$0"
           else 
               echo -e "\n  ${R}● Update aborted due to network errors.${NC}"; sleep 2
           fi
           ;;

        10)
           echo -e "\n  ${M}● Initializing Offline Local Deploy Engine...${NC}"
           if [ ! -d "$LOCAL_DIR" ] || ! ls "$LOCAL_DIR"/*.sh >/dev/null 2>&1; then
               echo -e "  ${R}● No offline files found in /root/mtunnel/!${NC}"; sleep 2; continue
           fi
           
           for file in "$LOCAL_DIR"/*.sh; do
               mod_name=$(basename "$file" .sh)
               [ "$mod_name" == "main" ] && mod_name="mtunnel"
               sed -i 's/\r$//' "$file" 2>/dev/null
               cat "$file" > "/usr/bin/$mod_name" 2>/dev/null
               chmod +x "/usr/bin/$mod_name" 2>/dev/null
           done
           
           [ -f "$LOCAL_DIR/packages/bh" ] && { cp "$LOCAL_DIR/packages/bh" /usr/local/bin/bh 2>/dev/null; chmod +x /usr/local/bin/bh 2>/dev/null; }
           [ -f "$LOCAL_DIR/packages/gost" ] && { cp "$LOCAL_DIR/packages/gost" /usr/local/bin/gost 2>/dev/null; chmod +x /usr/local/bin/gost 2>/dev/null; }
           [ -f "$LOCAL_DIR/packages/frps" ] && { cp "$LOCAL_DIR/packages/frps" /usr/local/bin/frps 2>/dev/null; chmod +x /usr/local/bin/frps 2>/dev/null; }
           [ -f "$LOCAL_DIR/packages/frpc" ] && { cp "$LOCAL_DIR/packages/frpc" /usr/local/bin/frpc 2>/dev/null; chmod +x /usr/local/bin/frpc 2>/dev/null; }
           
           echo -e "\n  ${G}● Local Deployment Complete!${NC}"; sleep 1.5; exec "$0"
           ;;
           
        11)
           echo -ne "\n  ${R}● DANGER: Completely wipe ALL infrastructure traces? (y/n): ${NC}"; read del_confirm
           if [[ "$del_confirm" == "y" ]]; then
               systemctl stop mgre.service ml2tp.service mporter.service haproxy gost wg-quick@wg0 mxlan.service mweb.service mstats-web.service frps frpc mhysteria@* mbackhaul@* 2>/dev/null
               rm -rf /etc/mgre /etc/mporter /etc/haproxy /etc/gost /etc/wireguard /etc/mweb /etc/frp /etc/ml2tp /etc/mhysteria /etc/mbackhaul /usr/bin/m* /usr/local/bin/hysteria /usr/local/bin/bh /usr/local/bin/gost /usr/local/bin/frp* /root/mtunnel
               echo -e "  ${G}● Purge complete. System is vanilla.${NC}\n"; exit 0
           fi
           ;;
           
        0) 
           clear; exit 0 
           ;;
    esac
done
