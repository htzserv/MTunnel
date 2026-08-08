#!/bin/bash
# --- MDesign Master Core | Central Dashboard v7.5.1 (Rathole & Gost Tunnels Integrated) ---

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
    local pid=$1
    local text=$2
    local width=${3:-32}
    local progress=0
    local filled empty bar rest
    tput civis 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        progress=$((progress + 2))
        [ "$progress" -gt 95 ] && progress=95
        filled=$(( progress * width / 100 ))
        empty=$(( width - filled ))
        bar=$(printf "%${filled}s" "" | tr ' ' '-')
        rest=$(printf "%${empty}s" "" | tr ' ' '-')
        printf "\r  ${C}→${NC} ${W}%-25s${NC} ${G}%s${DIM}%s${NC} ${C}%3d%%${NC}" \
            "$text" "$bar" "$rest" "$progress"
        sleep 0.12
    done

    bar=$(printf "%${width}s" "" | tr ' ' '-')
    printf "\r  ${G}✓${NC} ${W}%-25s${NC} ${G}%s${NC} ${G}100%%${NC}\n" \
        "$text" "$bar"
    tput cnorm 2>/dev/null || true
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
            if command -v curl >/dev/null 2>&1; then
                ( curl -fLsS --retry 2 --connect-timeout 8 --max-time 120                     -o "/tmp/${mod}.sh" "$REPO_SCRIPTS/${mod}.sh?v=$(date +%s)" ) >/dev/null 2>&1 &
            else
                ( wget --timeout=8 --tries=2 -qO "/tmp/${mod}.sh"                     "$REPO_SCRIPTS/${mod}.sh?v=$(date +%s)" ) >/dev/null 2>&1 &
            fi
            draw_progress_bar $! "Downloading $mod"
            if [ -s "/tmp/${mod}.sh" ]; then
                mv "/tmp/${mod}.sh" "$LOCAL_DIR/${mod}.sh"
                sed -i 's/\r$//' "$LOCAL_DIR/${mod}.sh" 2>/dev/null
                cat "$LOCAL_DIR/${mod}.sh" > "/usr/bin/$mod"
                chmod +x "/usr/bin/$mod"
            else
                rm -f "/tmp/${mod}.sh"
                echo -e "  ${R}● Error: Module not found on GitHub and no local cache!${NC}"; sleep 2; return
            fi
        fi
    fi
    $mod
}

run_iperf3() {
    clear; echo -e "\n  ${DIM}┌─[ iPerf3 Network Speedtest ]${NC}"
    if ! command -v iperf3 >/dev/null 2>&1; then
        echo -e "  ${Y}● Installing iPerf3...${NC}"
        apt-get update -y -q >/dev/null 2>&1
        apt-get install -y -q iperf3 >/dev/null 2>&1
    fi
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run as Server (Listener)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run as Client (Sender)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read i_opt
    i_opt=$(echo "$i_opt" | tr -d '\r')
    echo ""
    case $i_opt in
        1) echo -e "  ${G}● iPerf3 Server listening on default port (5201). Press Ctrl+C to stop.${NC}"; iperf3 -s ;;
        2) echo -ne "  ${C}●${NC} ${W}Target Server IP: ${NC}"; read t_ip
           t_ip=$(echo "$t_ip" | tr -d '\r')
           echo -e "  ${Y}● Testing speed to $t_ip...${NC}"
           iperf3 -c "$t_ip" ;;
        *) return ;;
    esac
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

draw_main_header() {
    local s_ip=$(get_local_ip)

    # Tunnel status indicators
    local st_gre="○"; local c_gre="${DIM}"; [ -n "$(ls -A /etc/mgre/tunnels/*.conf 2>/dev/null)" ] && { st_gre="●"; c_gre="${G}"; }
    local st_vx="○"; local c_vx="${DIM}"; [ -n "$(ls -A /etc/mgre/vxlan/*.conf 2>/dev/null)" ] && { st_vx="●"; c_vx="${G}"; }
    local st_rh="○"; local c_rh="${DIM}"; [ -n "$(ls -A /etc/mrathole/tunnels/*.toml 2>/dev/null)" ] && { st_rh="●"; c_rh="${G}"; }
    local st_gs="○"; local c_gst="${DIM}"; [ -n "$(ls -A /etc/mgostun/tunnels/*.json 2>/dev/null)" ] && { st_gs="●"; c_gst="${G}"; }
    local st_wg="○"; local c_wg="${DIM}"; ([ -f "/etc/wireguard/wg0.conf" ] || ip link show wg0 >/dev/null 2>&1) && { st_wg="●"; c_wg="${G}"; }
    local st_l2="○"; local c_l2="${DIM}"; [ -n "$(ls -A /etc/ml2tp/tunnels/*.conf 2>/dev/null)" ] && { st_l2="●"; c_l2="${G}"; }
    local st_hys="○"; local c_hys="${DIM}"; [ -n "$(ls -A /etc/mhysteria/tunnels/*.conf 2>/dev/null)" ] && { st_hys="●"; c_hys="${G}"; }
    local st_bh="○"; local c_bh="${DIM}"; [ -n "$(ls -A /etc/mbackhaul/tunnels/*.toml 2>/dev/null)" ] && { st_bh="●"; c_bh="${G}"; }

    local web_stat="${DIM}○ OFFLINE${NC}"
    local raw_web="○ OFFLINE"
    if systemctl is-active --quiet mweb.service 2>/dev/null; then
        local w_port="1000"
        [ -f "/etc/mweb/web.conf" ] && w_port=$(grep "WEB_PORT" /etc/mweb/web.conf | cut -d= -f2 | tr -d ' ' | tr -d '\r')
        web_stat="${G}● PORT ${w_port}${NC}"
        raw_web="● PORT ${w_port}"
    fi

    local raw_top=" MTunnel • MDesign Master Core v7.5.1 │ IP: ${s_ip} │ Web: ${raw_web} "
    local pad_top=$(( 94 - ${#raw_top} )); [ "$pad_top" -lt 0 ] && pad_top=0
    local padding_top=$(printf '%*s' "$pad_top" "")

    local raw_bot=" GRE:${st_gre}  VXLAN:${st_vx}  RatHole:${st_rh}  Gost:${st_gs}  WG:${st_wg}  L2TP:${st_l2}  Hys:${st_hys} "
    local pad_bot=$(( 94 - ${#raw_bot} )); [ "$pad_bot" -lt 0 ] && pad_bot=0
    local padding_bot=$(printf '%*s' "$pad_bot" "")

    clear; echo ""
    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MTunnel${NC} ${DIM}• MDesign Master Core v7.5.1${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}Web:${NC} ${web_stat}${padding_top}${B}│${NC}"
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC} ${DIM}STATUS${NC} ${c_gre}${st_gre}${NC} ${DIM}GRE${NC}  ${c_vx}${st_vx}${NC} ${DIM}VXLAN${NC}  ${c_rh}${st_rh}${NC} ${DIM}RATHOLE${NC}  ${c_gst}${st_gs}${NC} ${DIM}GOST${NC}  ${c_wg}${st_wg}${NC} ${DIM}WG${NC}  ${c_l2}${st_l2}${NC} ${DIM}L2TP${NC}  ${c_hys}${st_hys}${NC} ${DIM}HYS${NC}${padding_bot}${B}│${NC}"
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}


show_additional_tunnels() {
    while true; do
        draw_main_header; echo ""
        echo -e "  ${DIM}┌─[ ADDITIONAL TUNNELS ]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}WireGuard Crypto Matrix (Mwire)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}L2TPv3 Native Engine (Ml2tp)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Hysteria2 QUIC Engine (Mhysteria)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Backhaul Multiplexer (MBackhaul)${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Hub${NC}\n"
        echo -ne "  ${C}EXTRA ❯❯ ${NC}"; read a_opt
        case $a_opt in
            1) run_mod "mwire" ;; 2) run_mod "ml2tp" ;; 3) run_mod "mhysteria" ;; 4) run_mod "mbackhaul" ;; 0) break ;;
        esac
    done
}

show_tunnel_hub() {
    while true; do
        draw_main_header; echo ""
        echo -e "  ${DIM}┌─[ PRIMARY INFRASTRUCTURE HUB ]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Modular GRE/IP6GRE Core (Mgre)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}VXLAN Virtual Mesh Fabric (Mxlan)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Rathole Reverse Tunnel (Mrathole)${NC} ${DIM}[NEW]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Gost Encapsulation Engine (Mgostun)${NC} ${DIM}[NEW]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}FRP Reverse Proxy Engine (Mfrp)${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${DIM}Additional Tunnels (WG, L2TP, Hys2, BH)${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Dashboard${NC}\n"
        echo -ne "  ${C}TUNNEL ❯❯ ${NC}"; read t_opt
        case $t_opt in
            1) run_mod "mgre" ;; 2) run_mod "mxlan" ;; 3) run_mod "mrathole" ;; 4) run_mod "mgostun" ;; 5) run_mod "mfrp" ;; 6) show_additional_tunnels ;; 0) break ;;
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
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Network Diagnostics Tools${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}iPerf3 Network Speedtest${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${Y}Download Binary Packages${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${C}Update Core Scripts${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${M}Offline Local Deploy${NC}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${R}Nuclear Wipe (Uninstall)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}\n"
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read opt

    case $opt in
        1) show_tunnel_hub ;;
        2) run_mod "mporter" ;; 3) run_mod "minterface" ;; 4) run_mod "mshield" ;;
        5) run_mod "mstats" ;; 6) run_mod "mhealer" ;; 7) run_mod "mdiag" ;; 8) run_iperf3 ;;
        
        9)
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
                   
                   # Safe Skip logic implemented!
                   [ -f "$LOCAL_DIR/packages/bh" ] && [ ! -f "/usr/local/bin/bh" ] && { cp "$LOCAL_DIR/packages/bh" /usr/local/bin/bh; chmod +x /usr/local/bin/bh; }
                   [ -f "$LOCAL_DIR/packages/gost" ] && [ ! -f "/usr/local/bin/gost" ] && { cp "$LOCAL_DIR/packages/gost" /usr/local/bin/gost; chmod +x /usr/local/bin/gost; }
                   [ -f "$LOCAL_DIR/packages/frps" ] && [ ! -f "/usr/local/bin/frps" ] && { cp "$LOCAL_DIR/packages/frps" /usr/local/bin/frps; chmod +x /usr/local/bin/frps; }
                   [ -f "$LOCAL_DIR/packages/frpc" ] && [ ! -f "/usr/local/bin/frpc" ] && { cp "$LOCAL_DIR/packages/frpc" /usr/local/bin/frpc; chmod +x /usr/local/bin/frpc; }
                   [ -f "$LOCAL_DIR/packages/rathole" ] && [ ! -f "/usr/local/bin/rathole" ] && { cp "$LOCAL_DIR/packages/rathole" /usr/local/bin/rathole; chmod +x /usr/local/bin/rathole; }
                   
                   rm -rf /tmp/MTunnel-main /tmp/repo.zip
               ) &
               draw_progress_bar $! "Extracting & Installing"
               echo -e "\n  ${G}● Binary Files downloaded (Existing active files skipped safely)!${NC}"; sleep 2
           else
               echo -e "\n  ${R}● Error downloading zip archive from GitHub!${NC}"; sleep 2
           fi ;;

        10)
           echo -e "\n  ${Y}● Syncing .sh components from GitHub...${NC}"
           mkdir -p "$LOCAL_DIR" 2>/dev/null
           CACHE_BUST=$(date +%s)
           MODULES=("main.sh" "mgre.sh" "mxlan.sh" "mrathole.sh" "mgostun.sh" "mwire.sh" "mfrp.sh" "ml2tp.sh" "mhysteria.sh" "mbackhaul.sh" "mporter.sh" "minterface.sh" "mdiag.sh" "mshield.sh" "mstats.sh" "mhealer.sh" "mweb.sh")
           total_mods=${#MODULES[@]}; done_mods=0; failed_mods=0
           for file in "${MODULES[@]}"; do
               mod_name="${file%.sh}"
               echo -e "  ${DIM}Fetching ${file}...${NC}"
               if command -v curl >/dev/null 2>&1; then
                   ( curl -fLsS --retry 2 --connect-timeout 8 --max-time 120 -o "/tmp/$file" \
                     "$REPO_SCRIPTS/${file}?v=$CACHE_BUST" ) >/dev/null 2>&1 &
               else
                   ( wget --timeout=8 --tries=2 -qO "/tmp/$file" \
                     "$REPO_SCRIPTS/${file}?v=$CACHE_BUST" ) >/dev/null 2>&1 &
               fi
               draw_progress_bar $! "Updating $mod_name"
               if [ -s "/tmp/$file" ]; then
                   mv "/tmp/$file" "$LOCAL_DIR/$file"
                   sed -i 's/\r$//' "$LOCAL_DIR/$file" 2>/dev/null
               else
                   rm -f "/tmp/$file"
                   failed_mods=$((failed_mods + 1))
                   echo -e "  ${Y}↳ Keeping local version for ${file}${NC}"
               fi
               done_mods=$((done_mods + 1))
               local_fill=$((done_mods * 32 / total_mods))
               local_rest=$((32 - local_fill))
               printf "  ${C}Overall${NC} ${G}%s${DIM}%s${NC} ${C}%3d%%${NC}\n" \
                   "$(printf "%${local_fill}s" "" | tr ' ' '-')" \
                   "$(printf "%${local_rest}s" "" | tr ' ' '-')" \
                   $((done_mods * 100 / total_mods))
           done
           for file in "${MODULES[@]}"; do
               if [ -s "$LOCAL_DIR/$file" ]; then
                   mod_name="${file%.sh}"
                   [ "$mod_name" == "main" ] && mod_name="mtunnel"
                   cat "$LOCAL_DIR/$file" > "/usr/bin/$mod_name" 2>/dev/null
                   chmod +x "/usr/bin/$mod_name" 2>/dev/null
               fi
           done
           if [ "$failed_mods" -eq 0 ]; then
               echo -e "\n  ${G}● Core scripts fully upgraded/synced!${NC}"
           else
               echo -e "\n  ${Y}● Update completed with $failed_mods cached module(s) kept.${NC}"
           fi
           sleep 1.5
           exec "$0" ;;

        11)
           echo -e "\n  ${M}● Initializing Offline Local Deploy Engine...${NC}"
           if [ ! -d "$LOCAL_DIR" ] || ! ls "$LOCAL_DIR"/*.sh >/dev/null 2>&1; then
               echo -e "  ${R}● No offline scripts found in /root/mtunnel/!${NC}"; sleep 2; continue
           fi
           for file in "$LOCAL_DIR"/*.sh; do
               mod_name=$(basename "$file" .sh)
               [ "$mod_name" == "main" ] && mod_name="mtunnel"
               
               if [ -f "/usr/bin/$mod_name" ] && [ "$mod_name" != "mtunnel" ]; then
                   echo -e "  ${DIM}├─ Skipping script $mod_name (Already deployed)${NC}"
               else
                   sed -i 's/\r$//' "$file" 2>/dev/null
                   cat "$file" > "/usr/bin/$mod_name" 2>/dev/null
                   chmod +x "/usr/bin/$mod_name" 2>/dev/null
               fi
           done
           
           for bin in bh gost frps frpc rathole; do
               if [ -f "$LOCAL_DIR/packages/$bin" ]; then
                   if [ -f "/usr/local/bin/$bin" ]; then
                       echo -e "  ${DIM}├─ Skipping binary $bin (Already installed)${NC}"
                   else
                       cp "$LOCAL_DIR/packages/$bin" "/usr/local/bin/$bin" 2>/dev/null
                       chmod +x "/usr/local/bin/$bin" 2>/dev/null
                       echo -e "  ${G}├─ Installed $bin${NC}"
                   fi
               fi
           done
           echo -e "\n  ${G}● Local Deployment Complete (Active files skipped safely)!${NC}"; sleep 1.5; exec "$0" ;;
           
11)
           echo -e "\n  ${M}● Initializing Offline Local Deploy Engine...${NC}"
           if [ ! -d "$LOCAL_DIR" ] || ! ls "$LOCAL_DIR"/*.sh >/dev/null 2>&1; then
               echo -e "  ${R}● No offline scripts found in /root/mtunnel/!${NC}"; sleep 2; continue
           fi

           LOCAL_FILES=("$LOCAL_DIR"/*.sh)
           total_local=${#LOCAL_FILES[@]}; done_local=0
           for file in "${LOCAL_FILES[@]}"; do
               mod_name=$(basename "$file" .sh)
               [ "$mod_name" == "main" ] && mod_name="mtunnel"
               if [ -f "/usr/bin/$mod_name" ] && [ "$mod_name" != "mtunnel" ]; then
                   echo -e "  ${DIM}↳ Skipping ${mod_name} (already deployed)${NC}"
               else
                   sed -i 's/\r$//' "$file" 2>/dev/null
                   cat "$file" > "/usr/bin/$mod_name" 2>/dev/null
                   chmod +x "/usr/bin/$mod_name" 2>/dev/null
                   echo -e "  ${G}✓${NC} Deployed ${mod_name}"
               fi
               done_local=$((done_local + 1))
               p=$((done_local * 100 / total_local))
               fill=$((done_local * 32 / total_local)); rest=$((32 - fill))
               printf "  ${C}Scripts${NC} ${G}%s${DIM}%s${NC} ${C}%3d%%${NC}\n" \
                   "$(printf "%${fill}s" "" | tr ' ' '-')" \
                   "$(printf "%${rest}s" "" | tr ' ' '-')" "$p"
           done

           BINS=(bh gost frps frpc rathole)
           total_bins=${#BINS[@]}; done_bins=0
           for bin in "${BINS[@]}"; do
               if [ -f "$LOCAL_DIR/packages/$bin" ]; then
                   if [ -f "/usr/local/bin/$bin" ]; then
                       echo -e "  ${DIM}↳ Skipping binary $bin (already installed)${NC}"
                   else
                       cp "$LOCAL_DIR/packages/$bin" "/usr/local/bin/$bin" 2>/dev/null
                       chmod +x "/usr/local/bin/$bin" 2>/dev/null
                       echo -e "  ${G}✓${NC} Installed $bin"
                   fi
               fi
               done_bins=$((done_bins + 1))
               fill=$((done_bins * 32 / total_bins)); rest=$((32 - fill))
               printf "  ${C}Binaries${NC} ${G}%s${DIM}%s${NC} ${C}%3d%%${NC}\n" \
                   "$(printf "%${fill}s" "" | tr ' ' '-')" \
                   "$(printf "%${rest}s" "" | tr ' ' '-')" \
                   $((done_bins * 100 / total_bins))
           done
           echo -e "\n  ${G}● Local Deployment Complete (Active files skipped safely)!${NC}"
           sleep 1.5
           exec "$0" ;;

        12)
           echo -ne "\n  ${R}● DANGER: Completely wipe ALL infrastructure traces? (y/n): ${NC}"; read del_confirm
           del_confirm=$(echo "$del_confirm" | tr -d '\r' | tr -d ' ')
           if [[ "$del_confirm" == "y" ]]; then
               echo -e "\n  ${DIM}● 1/4 Stopping and disabling services...${NC}"
               systemctl stop mgre.service mxlan.service ml2tp.service mporter.service mporter-obfs.service mporter-watchdog.service haproxy gost wg-quick@wg0 mweb.service mhealer.service mshield-obfs.service frps frpc mhysteria@* mbackhaul@* mrathole@* mgostun@* 2>/dev/null
               systemctl disable mgre.service mxlan.service ml2tp.service mporter.service mporter-obfs.service mporter-watchdog.service haproxy gost wg-quick@wg0 mweb.service mhealer.service mshield-obfs.service frps frpc mrathole@* mgostun@* 2>/dev/null
               
               echo -e "  ${DIM}● 2/4 Removing systemd units...${NC}"
               rm -f /etc/systemd/system/mgre.service /etc/systemd/system/mxlan.service /etc/systemd/system/ml2tp.service /etc/systemd/system/mporter*.service /etc/systemd/system/mweb.service /etc/systemd/system/mhealer.service /etc/systemd/system/mshield*.service /etc/systemd/system/gost.service /etc/systemd/system/frp*.service /etc/systemd/system/mhysteria@.service /etc/systemd/system/mbackhaul@.service /etc/systemd/system/mrathole@.service /etc/systemd/system/mgostun@.service
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
               rm -rf /etc/mgre /etc/mporter /etc/haproxy /etc/gost /etc/wireguard /etc/mweb /etc/frp /etc/ml2tp /etc/mhysteria /etc/mbackhaul /etc/mshield /etc/mstats /etc/mrathole /etc/mgostun /root/mtunnel /var/log/mhealer.log /var/log/mporter-watchdog.log
               
               rm -f /usr/bin/mtunnel /usr/bin/mgre /usr/bin/mxlan /usr/bin/mwire /usr/bin/mfrp /usr/bin/ml2tp /usr/bin/mhysteria /usr/bin/mbackhaul /usr/bin/mporter /usr/bin/minterface /usr/bin/mdiag /usr/bin/mshield /usr/bin/mstats /usr/bin/mhealer /usr/bin/mweb /usr/bin/mrathole /usr/bin/mgostun
               rm -f /usr/local/bin/mtunnel /usr/local/bin/mporter-obfs.sh /usr/local/bin/mporter-watchdog.sh /usr/local/bin/mshield-runner.sh /usr/local/bin/mhealer_daemon.sh /usr/local/bin/hysteria /usr/local/bin/bh /usr/local/bin/gost /usr/local/bin/frpc /usr/local/bin/frps /usr/local/bin/rathole /usr/local/bin/mrathole-runner /usr/local/bin/mgostun-runner
               
               echo -e "\n  ${G}● Purge complete! Server is completely clean and returned to vanilla state.${NC}\n"
               exit 0
           fi ;;
        0) clear; exit 0 ;;
    esac
done

