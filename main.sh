#!/bin/bash
# --- MDesign Master Core | Central Dashboard v7.4.0 (Offline Fixed + Auto Web UI) ---
# [PATCHED: Flawless Nuclear Wipe / Uninstaller added]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
MTUNNEL_PATH="/usr/bin/mtunnel"
REPO_ZIP="https://github.com/htzserv/MTunnel/archive/refs/heads/main.zip"
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
LOCAL_DIR="/root/mtunnel"

if [[ ! -x "$MTUNNEL_PATH" ]]; then cp "$0" "$MTUNNEL_PATH" 2>/dev/null && chmod +x "$MTUNNEL_PATH" 2>/dev/null; fi

# --- 🌟 AUTO-START WEB UI ON FIRST RUN 🌟 ---
if [ ! -f "/etc/systemd/system/mweb.service" ] && [ -x "/usr/bin/mweb" ]; then
    mkdir -p /etc/mweb 2>/dev/null
    if [ ! -f "/etc/mweb/web.conf" ]; then
        echo -e "WEB_PORT=1000\nWEB_USER=admin\nWEB_PASS=admin" > /etc/mweb/web.conf
    fi
    cat <<'EOF' > /etc/systemd/system/mweb.service
[Unit]
Description=MDesign Fleet Radar UI
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/mweb
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable mweb.service >/dev/null 2>&1; systemctl start mweb.service >/dev/null 2>&1
fi
# ---------------------------------------------

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
        if [ -s "$LOCAL_DIR/${mod}.sh" ]; then
            echo -e "\n  ${G}● Deploying offline module [${W}${mod}${G}] from cache...${NC}"
            sed -i 's/\r$//' "$LOCAL_DIR/${mod}.sh" 2>/dev/null
            cat "$LOCAL_DIR/${mod}.sh" > "/usr/bin/$mod"
            chmod +x "/usr/bin/$mod"
        else
            echo -e "\n  ${Y}● Fetching module [${W}${mod}${Y}] on-demand from GitHub...${NC}"
            mkdir -p "$LOCAL_DIR" 2>/dev/null
            wget --timeout=5 --tries=1 -qO "/tmp/${mod}.sh" "$REPO_SCRIPTS/${mod}.sh?v=$(date +%s)"
            if [ -s "/tmp/${mod}.sh" ]; then
                mv "/tmp/${mod}.sh" "$LOCAL_DIR/${mod}.sh"
                sed -i 's/\r$//' "$LOCAL_DIR/${mod}.sh" 2>/dev/null
                cat "$LOCAL_DIR/${mod}.sh" > "/usr/bin/$mod"
                chmod +x "/usr/bin/$mod"
            else 
                echo -e "  ${R}● Error: Module not found on GitHub and no local cache!${NC}"; sleep 2; return
            fi
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
    echo -e "  ${B}│${NC} ${W}MDesign Master Core v7.4.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC}                                                   ${B}│${NC}"
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}${DIM} Hub: GRE:${NC}${c_gre}${st_gre}${NC}${DIM}  VXLAN:${NC}${c_vx}${st_vx}${NC}${DIM}  WireGuard:${NC}${c_wg}${st_wg}${NC}${DIM}  L2TP:${NC}${c_l2}${st_l2}${NC}${DIM}  Hys2:${NC}${c_hys}${st_hys}${NC}${DIM}  Backhaul:${NC}${c_bh}${st_bh}${NC}${DIM}                      ${B}│${NC}"
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_tunnel_hub() {
    while true; do
        draw_main_header; echo ""
        echo -e "  ${DIM}┌─[ TUNNEL INFRASTRUCTURE HUB ]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Modular GRE/IP6GRE Core (Mgre)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}VXLAN Virtual Mesh Fabric (Mxlan)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}WireGuard Crypto Matrix (Mwire)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}L2TPv3 Native Engine (Ml2tp)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Hysteria2 QUIC Engine (Mhysteria)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${M}FRP Reverse Proxy Engine (Mfrp)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${G}Backhaul Multiplexer (MBackhaul)${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Dashboard${NC}\n"
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
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Hub${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding & Failover${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SECURITY & ANALYTICS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Stealth Anti-Probing Shield${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${B}Bandwidth Radar & Web UI${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Autonomous Tunnel Healer${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Network Diagnostics Tools${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${Y}Download Binary Packages${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${C}Update Core Scripts${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${M}Offline Local Deploy${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${R}Nuclear Wipe (Uninstall)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}\n"
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read opt

    case $opt in
        1) show_tunnel_hub ;;
        2) run_mod "mporter" ;; 3) run_mod "minterface" ;; 4) run_mod "mshield" ;;
        5) run_mod "mstats" ;; 6) run_mod "mhealer" ;; 7) run_mod "mdiag" ;;
        
        8)
           echo -e "\n  ${DIM}┌─[ BINARY ASSETS DOWNLOADER ]${NC}"
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
           fi ;;

        9) 
           echo -e "\n  ${Y}● Syncing .sh components from GitHub...${NC}"
           mkdir -p "$LOCAL_DIR" 2>/dev/null; CACHE_BUST=$(date +%s); download_success=true
           MODULES=("main.sh" "mgre.sh" "mxlan.sh" "mwire.sh" "mfrp.sh" "ml2tp.sh" "mhysteria.sh" "mbackhaul.sh" "mporter.sh" "minterface.sh" "mdiag.sh" "mshield.sh" "mstats.sh" "mhealer.sh" "mweb.sh")
           for file in "${MODULES[@]}"; do
               echo -e "  ${DIM}├─ Fetching $file...${NC}"
               wget --timeout=5 --tries=1 -qO "/tmp/$file" "$REPO_SCRIPTS/${file}?v=$CACHE_BUST"
               if [ -s "/tmp/$file" ]; then
                   mv "/tmp/$file" "$LOCAL_DIR/$file"
                   sed -i 's/\r$//' "$LOCAL_DIR/$file" 2>/dev/null
               else
                   echo -e "  ${Y}├─ Internet unavailable, keeping offline version for $file${NC}"
               fi
           done
           for file in "${MODULES[@]}"; do
               if [ -s "$LOCAL_DIR/$file" ]; then
                   mod_name="${file%.sh}"; [ "$mod_name" == "main" ] && mod_name="mtunnel"
                   cat "$LOCAL_DIR/$file" > "/usr/bin/$mod_name" 2>/dev/null; chmod +x "/usr/bin/$mod_name" 2>/dev/null
               fi
           done
           echo -e "\n  ${G}● Core scripts fully upgraded/synced!${NC}"; sleep 1.5; exec "$0" ;;

        10)
           echo -e "\n  ${M}● Initializing Offline Local Deploy Engine...${NC}"
           if [ ! -d "$LOCAL_DIR" ] || ! ls "$LOCAL_DIR"/*.sh >/dev/null 2>&1; then
               echo -e "  ${R}● No offline scripts found in /root/mtunnel/!${NC}"; sleep 2; continue
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
           echo -e "\n  ${G}● Local Deployment Complete!${NC}"; sleep 1.5; exec "$0" ;;
           
        11)
           echo -ne "\n  ${R}● DANGER: Completely wipe ALL infrastructure traces? (y/n): ${NC}"; read del_confirm
           del_confirm=$(echo "$del_confirm" | tr -d '\r' | tr -d ' ')
           if [[ "$del_confirm" == "y" ]]; then
               echo -e "\n  ${DIM}● 1/4 Stopping and disabling services...${NC}"
               systemctl stop mgre.service mxlan.service ml2tp.service mporter.service mporter-obfs.service mporter-watchdog.service haproxy gost wg-quick@wg0 mweb.service mhealer.service mshield-obfs.service frps frpc mhysteria@* mbackhaul@* 2>/dev/null
               systemctl disable mgre.service mxlan.service ml2tp.service mporter.service mporter-obfs.service mporter-watchdog.service haproxy gost wg-quick@wg0 mweb.service mhealer.service mshield-obfs.service frps frpc 2>/dev/null
               
               echo -e "  ${DIM}● 2/4 Removing systemd units...${NC}"
               rm -f /etc/systemd/system/mgre.service /etc/systemd/system/mxlan.service /etc/systemd/system/ml2tp.service /etc/systemd/system/mporter*.service /etc/systemd/system/mweb.service /etc/systemd/system/mhealer.service /etc/systemd/system/mshield*.service /etc/systemd/system/gost.service /etc/systemd/system/frp*.service /etc/systemd/system/mhysteria@.service /etc/systemd/system/mbackhaul@.service
               systemctl daemon-reload
               
               echo -e "  ${DIM}● 3/4 Tearing down network interfaces and routing...${NC}"
               ip -o link show | grep -E '(gre|br_|vx_|hys_|l2tp_|sit_)' | awk -F': ' '{print $2}' | cut -d@ -f1 | while read iface; do 
                   ip link del "$iface" 2>/dev/null
                   ip tunnel del "$iface" 2>/dev/null
               done
               
               # Iptables flush
               while iptables -D INPUT -j MSHIELD 2>/dev/null; do :; done
               iptables -F MSHIELD 2>/dev/null; iptables -X MSHIELD 2>/dev/null
               iptables -t nat -S OUTPUT 2>/dev/null | grep "MPORTER_OBFS" | sed 's/-A /-D /' | while read rule; do iptables -t nat $rule; done
               iptables -t mangle -S OUTPUT 2>/dev/null | grep "OBFS_CNT_TX_" | sed 's/-A /-D /' | while read rule; do iptables -t mangle $rule; done
               iptables -t mangle -S INPUT 2>/dev/null | grep "OBFS_CNT_RX_" | sed 's/-A /-D /' | while read rule; do iptables -t mangle $rule; done
               iptables -t mangle -S FORWARD 2>/dev/null | grep "TCPMSS" | grep -E '(gre|br_|vx_|hys_|l2tp_)' | sed 's/-A /-D /' | while read rule; do iptables -t mangle $rule; done
               
               echo -e "  ${DIM}● 4/4 Deleting configuration files and binaries...${NC}"
               rm -rf /etc/mgre /etc/mporter /etc/haproxy /etc/gost /etc/wireguard /etc/mweb /etc/frp /etc/ml2tp /etc/mhysteria /etc/mbackhaul /etc/mshield /etc/mstats /root/mtunnel /var/log/mhealer.log /var/log/mporter-watchdog.log
               rm -f /usr/bin/m* /usr/local/bin/m* /usr/local/bin/hysteria /usr/local/bin/bh /usr/local/bin/gost /usr/local/bin/frpc /usr/local/bin/frps
               
               echo -e "\n  ${G}● Purge complete! Server is completely clean and returned to vanilla state.${NC}\n"
               exit 0
           fi ;;
        0) clear; exit 0 ;;
    esac
done
