#!/bin/bash
# --- MDesign Master Core | Central Dashboard v7.5.1 (Rathole & Gost Tunnels Integrated) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
MTUNNEL_PATH="/usr/bin/mtunnel"
REPO_ZIP="https://github.com/htzserv/MTunnel/archive/refs/heads/main.zip"
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
LOCAL_DIR="/root/mtunnel"
BOOTSTRAP_MODULES=("main.sh" "mgre.sh" "mporter.sh" "mxlan.sh" "mrathole.sh" "mweb.sh" "mstats.sh")
ALL_MODULES=("main.sh" "mgre.sh" "mxlan.sh" "mrathole.sh" "mgostun.sh" "mfrp.sh" "mwire.sh" "ml2tp.sh" "mhysteria.sh" "mbackhaul.sh" "mporter.sh" "minterface.sh" "mdiag.sh" "mshield.sh" "mstats.sh" "mhealer.sh" "mweb.sh")

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
    local pid=$1 text=$2 width=36 progress=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        ((progress++)); ((progress > 95)) && progress=95
        local filled=$((progress*width/100)) empty=$((width-filled))
        local bar="$(printf '%*s' "$filled" '' | tr ' ' '-')" rest="$(printf '%*s' "$empty" '' | tr ' ' '-')"
        printf "
  %b→%b %-26s %b%s%b%b%s%b %3d%%" "$C" "$NC" "$text" "$G" "$bar" "$DIM" "$rest" "$NC" "$progress"
        sleep 0.2
    done
    local bar="$(printf '%*s' "$width" '' | tr ' ' '-')"
    printf "
  %b✓%b %-26s %b%s%b %3d%%
" "$G" "$NC" "$text" "$G" "$bar" "$NC" 100
    tput cnorm 2>/dev/null || true
}

download_file_to_cache() {
    local file="$1" tmp="$LOCAL_DIR/.${file}.$$"
    mkdir -p "$LOCAL_DIR" || return 1
    rm -f "$tmp"

    echo -e "  ${C}→${NC} Downloading ${W}${file}${NC} to local cache..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 --connect-timeout 8 --max-time 120 --progress-bar \
            -o "$tmp" "$REPO_SCRIPTS/${file}?v=$(date +%s)" || { rm -f "$tmp"; return 1; }
    else
        wget --timeout=8 --tries=2 -O "$tmp" "$REPO_SCRIPTS/${file}?v=$(date +%s)" || { rm -f "$tmp"; return 1; }
    fi

    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    sed -i 's/\r$//' "$tmp" 2>/dev/null || true
    chmod 0755 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$LOCAL_DIR/${file}"
}

download_module_to_cache() {
    local mod="$1"
    download_file_to_cache "${mod}.sh"
}

cache_installed_module() {
    local mod="$1" file="${mod}.sh"
    [ -s "$LOCAL_DIR/$file" ] && return 0
    [ -s "/usr/bin/$mod" ] || return 1
    mkdir -p "$LOCAL_DIR" || return 1
    cp -f "/usr/bin/$mod" "$LOCAL_DIR/$file" || return 1
    chmod 0755 "$LOCAL_DIR/$file" 2>/dev/null || true
}

deploy_cached_module() {
    local mod="$1" file="${mod}.sh"
    [ -s "$LOCAL_DIR/$file" ] || return 1
    sed -i 's/\r$//' "$LOCAL_DIR/$file" 2>/dev/null || true
    install -m 0755 "$LOCAL_DIR/$file" "/usr/bin/$mod" || return 1
    if [ "$mod" = "mtunnel" ]; then
        install -m 0755 "$LOCAL_DIR/$file" /usr/local/bin/mtunnel 2>/dev/null || true
    fi
}

ensure_module() {
    local mod="$1" file="${mod}.sh"

    # 1) Local cache always wins. This is the offline-first path.
    if [ -s "$LOCAL_DIR/$file" ]; then
        deploy_cached_module "$mod"
        return $?
    fi

    # 2) If the module is already installed but not cached, backfill the cache.
    if cache_installed_module "$mod"; then
        deploy_cached_module "$mod"
        return $?
    fi

    # 3) Only now touch GitHub. A successful download is stored permanently.
    if download_module_to_cache "$mod"; then
        deploy_cached_module "$mod"
        return $?
    fi

    echo -e "  ${R}✗ ${W}${mod}${R} is not available locally and GitHub download failed.${NC}"
    return 1
}

run_mod() {
    local mod="$1"
    ensure_module "$mod" || return 1
    "$mod"
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
    
    # 🌟 Tun Status 🌟
    local st_gre="○"; local c_gre="${DIM}"; [ -n "$(ls -A /etc/mgre/tunnels/*.conf 2>/dev/null)" ] && { st_gre="●"; c_gre="${G}"; }
    local st_vx="○"; local c_vx="${DIM}"; [ -n "$(ls -A /etc/mgre/vxlan/*.conf 2>/dev/null)" ] && { st_vx="●"; c_vx="${G}"; }
    local st_rh="○"; local c_rh="${DIM}"; [ -n "$(ls -A /etc/mrathole/tunnels/*.toml 2>/dev/null)" ] && { st_rh="●"; c_rh="${G}"; }
    local st_gs="○"; local c_gst="${DIM}"; [ -n "$(ls -A /etc/mgostun/tunnels/*.json 2>/dev/null)" ] && { st_gs="●"; c_gst="${G}"; }
    local st_wg="○"; local c_wg="${DIM}"; ([ -f "/etc/wireguard/wg0.conf" ] || ip link show wg0 >/dev/null 2>&1) && { st_wg="●"; c_wg="${G}"; }
    local st_l2="○"; local c_l2="${DIM}"; [ -n "$(ls -A /etc/ml2tp/tunnels/*.conf 2>/dev/null)" ] && { st_l2="●"; c_l2="${G}"; }
    local st_hys="○"; local c_hys="${DIM}"; [ -n "$(ls -A /etc/mhysteria/tunnels/*.conf 2>/dev/null)" ] && { st_hys="●"; c_hys="${G}"; }
    local st_bh="○"; local c_bh="${DIM}"; [ -n "$(ls -A /etc/mbackhaul/tunnels/*.toml 2>/dev/null)" ] && { st_bh="●"; c_bh="${G}"; }

    # 🌟 Web UI Status 🌟
    local web_stat="${DIM}○ OFFLINE${NC}"
    local raw_web="○ OFFLINE"
    if systemctl is-active --quiet mweb.service 2>/dev/null; then
        local w_port="1000"
        [ -f "/etc/mweb/web.conf" ] && w_port=$(grep "WEB_PORT" /etc/mweb/web.conf | cut -d= -f2 | tr -d ' ' | tr -d '\r')
        web_stat="${G}● PORT ${w_port}${NC}"
        raw_web="● PORT ${w_port}"
    fi

    # 🌟 Dynamic Padding Calculations (Width: 94) 🌟
    local raw_top=" MDesign Master Core v7.5.1 │ IP: ${s_ip} │ Web: ${raw_web} "
    local pad_top=$(( 94 - ${#raw_top} )); [ "$pad_top" -lt 0 ] && pad_top=0
    local padding_top=$(printf '%*s' "$pad_top" "")

    # Keeping the bottom bar short so it fits nicely
    local raw_bot=" Hub: GRE:${st_gre}  VXLAN:${st_vx}  RatHole:${st_rh}  GostTun:${st_gs}  FRP:○  Extra:${st_wg} "
    local pad_bot=$(( 94 - ${#raw_bot} )); [ "$pad_bot" -lt 0 ] && pad_bot=0
    local padding_bot=$(printf '%*s' "$pad_bot" "")

    clear; echo ""
    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MDesign Master Core v7.5.1${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}Web:${NC} ${web_stat}${padding_top}${B}│${NC}"
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}${DIM} Hub: GRE:${NC}${c_gre}${st_gre}${NC}${DIM}  VXLAN:${NC}${c_vx}${st_vx}${NC}${DIM}  RatHole:${NC}${c_rh}${st_rh}${NC}${DIM}  GostTun:${NC}${c_gst}${st_gs}${NC}${DIM}  FRP:${DIM}○${NC}${DIM}  Extra:${NC}${c_wg}${st_wg}${NC}${padding_bot}${B}│${NC}"
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
           echo -e "\n  ${Y}● Syncing bootstrap modules from GitHub into local cache...${NC}"
           mkdir -p "$LOCAL_DIR" 2>/dev/null
           update_failed=()
           for file in "${BOOTSTRAP_MODULES[@]}"; do
               mod_name="${file%.sh}"
               [ "$mod_name" = "main" ] && mod_name="mtunnel"
               echo -e "  ${DIM}├─ Updating $file...${NC}"
               if download_file_to_cache "$file"; then
                   deploy_cached_module "$mod_name" || update_failed+=("$file")
               else
                   echo -e "  ${Y}├─ Download failed; keeping cached version of $file${NC}"
                   [ -s "$LOCAL_DIR/$file" ] || update_failed+=("$file")
               fi
           done
           if [ "${#update_failed[@]}" -gt 0 ]; then
               echo -e "\n  ${Y}● Core update incomplete:${NC} ${update_failed[*]}"
           else
               echo -e "\n  ${G}● Bootstrap modules updated and cached locally.${NC}"
           fi
           sleep 1.5; exec "$0" ;;
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
           
        12)
            clear
            echo -e "\n  ${R}╭────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${R}│${NC} ${W}MTunnel Nuclear Wipe${NC}                                      ${R}│${NC}"
            echo -e "  ${R}╰────────────────────────────────────────────────────────────╯${NC}"
            echo -e "  ${Y}Removes MTunnel-owned services, configs, cache and binaries.${NC}"
            echo -e "  ${Y}Does NOT flush the whole firewall or delete arbitrary interfaces.${NC}"
            echo -e "  ${DIM}Shared /etc/haproxy and /etc/wireguard are preserved.${NC}\n"
            echo -ne "  ${R}Type WIPE-MTUNNEL to continue: ${NC}"; read del_confirm
            del_confirm="${del_confirm//[$' \r\n']/}"
            if [[ "$del_confirm" == "WIPE-MTUNNEL" ]]; then
                echo -e "\n  ${C}[1/4]${NC} Stopping MTunnel services..."
                systemctl stop mgre.service mxlan.service ml2tp.service mporter.service mporter-obfs.service mporter-watchdog.service mweb.service mhealer.service mshield-obfs.service frps frpc 2>/dev/null || true
                systemctl disable mgre.service mxlan.service ml2tp.service mporter.service mporter-obfs.service mporter-watchdog.service mweb.service mhealer.service mshield-obfs.service frps frpc 2>/dev/null || true
                echo -e "  ${C}[2/4]${NC} Removing MTunnel systemd units..."
                rm -f /etc/systemd/system/mgre.service /etc/systemd/system/mxlan.service /etc/systemd/system/ml2tp.service /etc/systemd/system/mporter*.service /etc/systemd/system/mweb.service /etc/systemd/system/mhealer.service /etc/systemd/system/mshield*.service /etc/systemd/system/gost.service /etc/systemd/system/frp*.service /etc/systemd/system/mhysteria@.service /etc/systemd/system/mbackhaul@.service /etc/systemd/system/mrathole@.service /etc/systemd/system/mgostun@.service
                systemctl daemon-reload
                echo -e "  ${C}[3/4]${NC} Removing only known MTunnel interfaces..."
                ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(gre|br_|vx_|hys_|l2tp_)' | while read -r iface; do [ -n "$iface" ]||continue; ip link del "$iface" 2>/dev/null||true; ip tunnel del "$iface" 2>/dev/null||true; done
                while iptables -D INPUT -j MSHIELD 2>/dev/null; do :; done
                iptables -F MSHIELD 2>/dev/null||true; iptables -X MSHIELD 2>/dev/null||true
                for table in nat mangle; do
                    iptables -t "$table" -S 2>/dev/null | grep -E 'MPORTER_OBFS|OBFS_CNT_(TX|RX)_' | sed 's/^-A /-D /' | while read -r rule; do [ -n "$rule" ]&&iptables -t "$table" $rule 2>/dev/null||true; done
                done
                echo -e "  ${C}[4/4]${NC} Removing MTunnel-owned files..."
                rm -rf /etc/mgre /etc/mporter /etc/mweb /etc/frp /etc/ml2tp /etc/mhysteria /etc/mbackhaul /etc/mshield /etc/mstats /etc/mrathole /etc/mgostun /root/mtunnel
                rm -f /var/log/mhealer.log /var/log/mporter-watchdog.log
                rm -f /usr/bin/mtunnel /usr/bin/mgre /usr/bin/mxlan /usr/bin/mwire /usr/bin/mfrp /usr/bin/ml2tp /usr/bin/mhysteria /usr/bin/mbackhaul /usr/bin/mporter /usr/bin/minterface /usr/bin/mdiag /usr/bin/mshield /usr/bin/mstats /usr/bin/mstat /usr/bin/mhealer /usr/bin/mweb /usr/bin/mrathole /usr/bin/mgostun
                rm -f /usr/local/bin/mtunnel /usr/local/bin/mporter-obfs.sh /usr/local/bin/mporter-watchdog.sh /usr/local/bin/mshield-runner.sh /usr/local/bin/mhealer_daemon.sh /usr/local/bin/hysteria /usr/local/bin/mrathole-runner /usr/local/bin/mgostun-runner
                echo -e "\n  ${G}✓ MTunnel wipe completed. Shared configs were preserved.${NC}\n"
                exit 0
            else echo -e "  ${G}Cancelled. Nothing was removed.${NC}"; fi ;;
        0) clear; exit 0 ;;
    esac
done
