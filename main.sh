#!/bin/bash
# --- MDesign Master Core | Central Dashboard v7.6.1 (Force Download Fix) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
MTUNNEL_PATH="/usr/bin/mtunnel"
REPO_ZIP="https://github.com/htzserv/MTunnel/archive/refs/heads/main.zip"
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
LOCAL_DIR="/root/mtunnel"
BOOTSTRAP_MODULES=("main.sh" "mgre.sh" "mporter.sh" "mxlan.sh" "mrathole.sh" "mbbr.sh" "mweb.sh" "mstats.sh")
ALL_MODULES=("main.sh" "mgre.sh" "mxlan.sh" "mrathole.sh" "mgostun.sh" "mfrp.sh" "mwire.sh" "ml2tp.sh" "mhysteria.sh" "mbackhaul.sh" "mporter.sh" "minterface.sh" "mdiag.sh" "mshield.sh" "mstats.sh" "mhealer.sh" "mbbr.sh" "mweb.sh")

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
    local pid=$1 text=$2 width=36 progress=0 filled empty bar rest
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        ((progress++)); ((progress > 95)) && progress=95
        filled=$((progress*width/100)); empty=$((width-filled))
        bar="$(printf '%*s' "$filled" '' | tr ' ' '-')"
        rest="$(printf '%*s' "$empty" '' | tr ' ' '-')"
        printf '\r  %b→%b %-26s %b%s%b%s %3d%%' "$C" "$NC" "$text" "$G" "$bar" "$NC" "$rest" "$progress"
        sleep 0.2
    done
    bar="$(printf '%*s' "$width" '' | tr ' ' '-')"
    printf '\r  %b✓%b %-26s %b%s%b %3d%%\n' "$G" "$NC" "$text" "$G" "$bar" "$NC" 100
    tput cnorm 2>/dev/null || true
}

same_file() {
    local a="$1" b="$2"
    [ -f "$a" ] && [ -f "$b" ] && [ "$(readlink -f "$a" 2>/dev/null)" = "$(readlink -f "$b" 2>/dev/null)" ]
}

download_file_to_cache() {
    local file="$1" tmp="$LOCAL_DIR/.${file}.$$"
    mkdir -p "$LOCAL_DIR" || return 1
    rm -f "$tmp"
    echo -e "  ${C}→${NC} Downloading ${W}${file}${NC} to local cache..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 8 --max-time 120 -o "$tmp" "$REPO_SCRIPTS/$file" || { rm -f "$tmp"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=8 --tries=2 -O "$tmp" "$REPO_SCRIPTS/$file" || { rm -f "$tmp"; return 1; }
    else
        return 1
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    sed -i 's/\r$//' "$tmp" 2>/dev/null || true
    chmod 0755 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$LOCAL_DIR/$file"
}

deploy_cached_module() {
    local mod="$1" file="${mod}.sh"
    [ -s "$LOCAL_DIR/$file" ] || return 1
    sed -i 's/\r$//' "$LOCAL_DIR/$file" 2>/dev/null || true
    if ! same_file "$LOCAL_DIR/$file" "/usr/bin/$mod"; then
        install -m 0755 "$LOCAL_DIR/$file" "/usr/bin/$mod" || return 1
    else
        chmod 0755 "/usr/bin/$mod" 2>/dev/null || true
    fi
    if [ "$mod" = "mtunnel" ]; then
        if ! same_file "$LOCAL_DIR/$file" "/usr/local/bin/mtunnel"; then
            install -m 0755 "$LOCAL_DIR/$file" /usr/local/bin/mtunnel 2>/dev/null || true
        fi
    fi
    if [ "$mod" = "mstats" ]; then
        install -m 0755 "$LOCAL_DIR/$file" /usr/bin/mstats 2>/dev/null || true
        ln -sfn /usr/bin/mstats /usr/bin/mstat 2>/dev/null || true
    fi
}

ensure_module() {
    local mod="$1" file="${mod}.sh"
    local script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"

    if [ -s "$LOCAL_DIR/$file" ]; then
        deploy_cached_module "$mod" && return 0
    fi
    if [ -s "$script_dir/$file" ]; then
        cp -f "$script_dir/$file" "$LOCAL_DIR/$file" 2>/dev/null || true
        chmod 0755 "$LOCAL_DIR/$file" 2>/dev/null || true
        deploy_cached_module "$mod" && return 0
    fi
    if [ -s "/usr/bin/$mod" ]; then
        cp -f "/usr/bin/$mod" "$LOCAL_DIR/$file" 2>/dev/null || true
        chmod 0755 "$LOCAL_DIR/$file" 2>/dev/null || true
        deploy_cached_module "$mod" && return 0
    fi
    if download_file_to_cache "$file"; then
        deploy_cached_module "$mod" && return 0
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
    
    local st_gre="○"; local c_gre="${DIM}"; [ -n "$(ls -A /etc/mgre/tunnels/*.conf 2>/dev/null)" ] && { st_gre="●"; c_gre="${G}"; }
    local st_vx="○"; local c_vx="${DIM}"; [ -n "$(ls -A /etc/mgre/vxlan/*.conf 2>/dev/null)" ] && { st_vx="●"; c_vx="${G}"; }
    local st_rh="○"; local c_rh="${DIM}"; [ -n "$(ls -A /etc/mrathole/tunnels/*.toml 2>/dev/null)" ] && { st_rh="●"; c_rh="${G}"; }
    local st_gs="○"; local c_gst="${DIM}"; [ -n "$(ls -A /etc/mgostun/tunnels/*.json 2>/dev/null)" ] && { st_gs="●"; c_gs="${G}"; }
    local st_wg="○"; local c_wg="${DIM}"; ([ -f "/etc/wireguard/wg0.conf" ] || ip link show wg0 >/dev/null 2>&1) && { st_wg="●"; c_wg="${G}"; }

    local bbr_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local bbr_stat="${DIM}○ OFF${NC}"
    local raw_bbr="○ OFF"
    if [ "$bbr_cc" == "bbr" ]; then
        bbr_stat="${G}● ON${NC}"
        raw_bbr="● ON"
    fi

    local web_stat="${DIM}○ OFFLINE${NC}"
    local raw_web="○ OFFLINE"
    if systemctl is-active --quiet mweb.service 2>/dev/null; then
        local w_port="1000"
        [ -f "/etc/mweb/web.conf" ] && w_port=$(grep "WEB_PORT" /etc/mweb/web.conf | cut -d= -f2 | tr -d ' ' | tr -d '\r')
        web_stat="${G}● PORT ${w_port}${NC}"
        raw_web="● PORT ${w_port}"
    fi

    local raw_top=" MDesign Master Core v7.6.1 │ IP: ${s_ip} │ Web: ${raw_web} │ BBR: ${raw_bbr} "
    local pad_top=$(( 94 - ${#raw_top} )); [ "$pad_top" -lt 0 ] && pad_top=0
    local padding_top=$(printf '%*s' "$pad_top" "")

    local raw_bot=" Hub: GRE:${st_gre}  VXLAN:${st_vx}  RatHole:${st_rh}  GostTun:${st_gs}  FRP:○  Extra:${st_wg} "
    local pad_bot=$(( 94 - ${#raw_bot} )); [ "$pad_bot" -lt 0 ] && pad_bot=0
    local padding_bot=$(printf '%*s' "$pad_bot" "")

    clear; echo ""
    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MDesign Master Core v7.6.1${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}Web:${NC} ${web_stat} ${B}│${NC} ${DIM}BBR:${NC} ${bbr_stat}${padding_top}${B}│${NC}"
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
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Rathole Reverse Tunnel (Mrathole)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Gost Encapsulation Engine (Mgostun)${NC}"
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
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding & Failover (Mporter)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SECURITY & ANALYTICS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Stealth Anti-Probing Shield${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${B}Bandwidth Radar & Web UI${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Autonomous Tunnel Healer${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Network Diagnostics Tools${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}iPerf3 Network Speedtest${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${G}TCP BBR Accelerator (Mbbr)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${Y}Download Binary Packages${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${M}Offline Local Deploy (Packages & Modules)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${R}Force Download & Install Core${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC}${DIM}❯${NC} ${R}Nuclear Wipe (Uninstall)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}\n"
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read opt

    case $opt in
        1) show_tunnel_hub ;;
        2) run_mod "mporter" ;; 3) run_mod "minterface" ;; 4) run_mod "mshield" ;;
        5) run_mod "mstats" ;; 6) run_mod "mhealer" ;; 7) run_mod "mdiag" ;; 8) run_iperf3 ;;
        9) run_mod "mbbr" ;;
        
        10)
           echo -e "\n  ${DIM}┌─[ BINARY ASSETS DOWNLOADER ]${NC}"
           mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
           tmp_zip="$(mktemp /tmp/mtunnel-packages.XXXXXX.zip 2>/dev/null || echo /tmp/mtunnel-packages.zip)"
           rm -f "$tmp_zip"
           if command -v curl >/dev/null 2>&1; then
               curl -fsSL --retry 2 --connect-timeout 8 --max-time 180 -o "$tmp_zip" "$REPO_ZIP" &
               pid=$!; draw_progress_bar "$pid" "Fetching package archive"; wait "$pid"; rc=$?
           elif command -v wget >/dev/null 2>&1; then
               wget -q --timeout=8 --tries=2 -O "$tmp_zip" "$REPO_ZIP" &
               pid=$!; draw_progress_bar "$pid" "Fetching package archive"; wait "$pid"; rc=$?
           else
               rc=1
           fi
           if [ "${rc:-1}" -eq 0 ] && command -v unzip >/dev/null 2>&1 && unzip -t "$tmp_zip" >/dev/null 2>&1; then
               tmp_dir="$(mktemp -d /tmp/mtunnel-packages.XXXXXX)"
               unzip -q -o "$tmp_zip" -d "$tmp_dir" 2>/dev/null
               pkg_root="$(find "$tmp_dir" -maxdepth 2 -type d -name packages -print -quit 2>/dev/null)"
               if [ -n "$pkg_root" ] && [ -d "$pkg_root" ]; then
                   cp -f "$pkg_root"/* "$LOCAL_DIR/packages/" 2>/dev/null || true
                   chmod +x "$LOCAL_DIR/packages/"* 2>/dev/null || true
                   for bin in bh gost frps frpc rathole haproxy; do
                       if [ -f "$LOCAL_DIR/packages/$bin" ] && [ ! -f "/usr/local/bin/$bin" ]; then
                           install -m 0755 "$LOCAL_DIR/packages/$bin" "/usr/local/bin/$bin" 2>/dev/null || true
                           echo -e "  ${G}✓${NC} Installed $bin"
                       fi
                   done
                   echo -e "  ${G}● Binary package cache updated. Existing active binaries were preserved.${NC}"
               else
                   echo -e "  ${R}● Package directory was not found in the archive.${NC}"
               fi
               rm -rf "$tmp_dir"
           else
               echo -e "  ${R}● Error downloading or reading the GitHub package archive.${NC}"
           fi
           rm -f "$tmp_zip"
           sleep 1.5 ;;

        11)
           echo -e "\n  ${M}● Offline Local Deploy Engine (Scripts & Packages)${NC}"
           
           # ۱. استقرار تمام ماژول‌های اسکریپتی
           failed_local=()
           for file in "${ALL_MODULES[@]}"; do
               mod_name="${file%.sh}"
               [ "$mod_name" = "main" ] && mod_name="mtunnel"
               if [ -s "$LOCAL_DIR/$file" ]; then
                   if deploy_cached_module "$mod_name"; then
                       echo -e "  ${G}✓${NC} Module: $mod_name"
                   else
                       failed_local+=("$mod_name")
                   fi
               fi
           done

           # ۲. استقرار باینری‌های لوکال موجود در پوشه packages
           local_pkg_dir="$LOCAL_DIR/packages"
           [ ! -d "$local_pkg_dir" ] && [ -d "./packages" ] && local_pkg_dir="./packages"

           if [ -d "$local_pkg_dir" ]; then
               mkdir -p /usr/local/bin /usr/sbin /etc/haproxy /var/lib/haproxy 2>/dev/null
               
               # هپروکسی لوکال
               if [ -f "$local_pkg_dir/haproxy" ]; then
                   cp -f "$local_pkg_dir/haproxy" /usr/sbin/haproxy 2>/dev/null || cp -f "$local_pkg_dir/haproxy" /usr/local/sbin/haproxy
                   chmod +x /usr/sbin/haproxy /usr/local/sbin/haproxy 2>/dev/null
                   touch /var/lib/haproxy/stats 2>/dev/null
                   echo -e "  ${G}✓${NC} Binary: haproxy (Local)"
               fi

               # باینری‌های تانل
               for b in gost bh backhaul frpc frps rathole hysteria; do
                   if [ -f "$local_pkg_dir/$b" ]; then
                       cp -f "$local_pkg_dir/$b" /usr/local/bin/$b
                       chmod +x "/usr/local/bin/$b"
                       echo -e "  ${G}✓${NC} Binary: $b (Local)"
                   fi
               done

               # فایل‌های deb
               if ls "$local_pkg_dir"/*.deb >/dev/null 2>&1; then
                   dpkg -i "$local_pkg_dir"/*.deb >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1
                   echo -e "  ${G}✓${NC} Installed local .deb packages"
               fi
           fi

           if [ "${#failed_local[@]}" -gt 0 ]; then
               echo -e "  ${Y}● Offline deploy incomplete for some modules:${NC} ${failed_local[*]}"
           else
               echo -e "  ${G}● Local deployment and binary sync completed successfully.${NC}"
           fi
           sleep 2 ;;

        12)
           echo -e "\n  ${R}● Force Download & Install Core${NC}"
           mkdir -p "$LOCAL_DIR" 2>/dev/null
           echo -e "  ${C}→ Fetching fresh install.sh from GitHub...${NC}"
           
           # همیشه نسخه جدید install.sh دانلود و اوررایت می‌شود
           if command -v curl >/dev/null 2>&1; then
               curl -fsSL --connect-timeout 8 -o "$LOCAL_DIR/install.sh" "$REPO_SCRIPTS/install.sh" 2>/dev/null
           elif command -v wget >/dev/null 2>&1; then
               wget -q --timeout=8 -O "$LOCAL_DIR/install.sh" "$REPO_SCRIPTS/install.sh" 2>/dev/null
           fi

           if [ -s "$LOCAL_DIR/install.sh" ]; then
               chmod +x "$LOCAL_DIR/install.sh"
               # اجرای صریح و مستقیم اینستالر با سوئیچ --force
               bash "$LOCAL_DIR/install.sh" --force
           else
               echo -e "  ${R}✗ Failed to fetch installer from GitHub.${NC}"
               sleep 1.5
           fi
           ;;

        13)
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
                rm -f /usr/bin/mtunnel /usr/bin/mgre /usr/bin/mxlan /usr/bin/mwire /usr/bin/mfrp /usr/bin/ml2tp /usr/bin/mhysteria /usr/bin/mbackhaul /usr/bin/mporter /usr/bin/minterface /usr/bin/mdiag /usr/bin/mshield /usr/bin/mstats /usr/bin/mstat /usr/bin/mhealer /usr/bin/mweb /usr/bin/mrathole /usr/bin/mgostun /usr/bin/mbbr
                rm -f /usr/local/bin/mtunnel /usr/local/bin/mporter-obfs.sh /usr/local/bin/mporter-watchdog.sh /usr/local/bin/mshield-runner.sh /usr/local/bin/mhealer_daemon.sh /usr/local/bin/hysteria /usr/local/bin/mrathole-runner /usr/local/bin/mgostun-runner
                echo -e "\n  ${G}✓ MTunnel wipe completed. Shared configs were preserved.${NC}\n"
                exit 0
            else echo -e "  ${G}Cancelled. Nothing was removed.${NC}"; fi ;;
        0) clear; exit 0 ;;
    esac
done
