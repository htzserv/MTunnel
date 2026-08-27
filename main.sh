#!/bin/bash
# --- MDesign Master Core | Central Dashboard v8.1.0 ---
# [Features: Custom ZIP Deployment for Restricted Networks]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
MTUNNEL_PATH="/usr/bin/mtunnel"
REPO_ZIP="https://github.com/htzserv/MTunnel/archive/refs/heads/main.zip"
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
LOCAL_DIR="/root/mtunnel"

declare -A MOD_MAP=(
    ["main"]="main.sh"
    ["mporter"]="mporter.sh"
    ["mgre"]="tunnels/mgre.sh"
    ["mxlan"]="tunnels/mxlan.sh"
    ["mrathole"]="tunnels/mrathole.sh"
    ["mbackhaul"]="tunnels/mbackhaul.sh"
    ["mpaqet"]="tunnels/mpaqet.sh"
    ["mweb"]="tools/mweb.sh"
    ["mstats"]="tools/mstats.sh"
    ["mhealer"]="tools/mhealer.sh"
    ["minterface"]="tools/minterface.sh"
    ["mbbr"]="tools/mbbr.sh"
    ["mdiag"]="tools/mdiag.sh"
    ["mshield"]="tools/mshield.sh"
    ["linktest"]="tools/linktest.sh"
)

ALL_MODULES=("main" "mporter" "mgre" "mxlan" "mrathole" "mbackhaul" "mpaqet" "mweb" "mstats" "mhealer" "minterface" "mbbr" "mdiag" "mshield" "linktest")

if [[ ! -x "$MTUNNEL_PATH" ]]; then cp "$0" "$MTUNNEL_PATH" 2>/dev/null && chmod +x "$MTUNNEL_PATH" 2>/dev/null; fi

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

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_progress_bar() {
    local pid=$1 text=$2 width=30 progress=0 filled empty bar rest
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        progress=$(( (progress + 3) % 96 ))
        [ "$progress" -lt 5 ] && progress=5
        filled=$(( progress * width / 100 ))
        empty=$(( width - filled ))
        bar="$(printf '%*s' "$filled" '' | tr ' ' '#')"
        rest="$(printf '%*s' "$empty" '' | tr ' ' '-')"
        printf "\r  %b→%b %-26s %b[%s%b%s%b] %3d%%" "$C" "$NC" "$text" "$W" "$bar" "$DIM" "$rest" "$NC" "$progress"
        sleep 0.15
    done
    bar="$(printf '%*s' "$width" '' | tr ' ' '#')"
    printf "\r  %b✔%b %-26s %b[%b%s%b] %3d%%\n" "$G" "$NC" "$text" "$W" "$G" "$bar" "$W" 100
    tput cnorm 2>/dev/null || true
}

same_file() {
    local a="$1" b="$2"
    [ -f "$a" ] && [ -f "$b" ] && [ "$(readlink -f "$a" 2>/dev/null)" = "$(readlink -f "$b" 2>/dev/null)" ]
}

download_file_to_cache() {
    local mod="$1"
    local rel_path="${MOD_MAP[$mod]}"
    [ -z "$rel_path" ] && rel_path="${mod}.sh"
    local file_name="$(basename "$rel_path")"
    local tmp="$LOCAL_DIR/.${file_name}.$$"
    
    mkdir -p "$LOCAL_DIR" || return 1
    rm -f "$tmp"
    echo -e "  ${C}→${NC} Downloading ${W}${mod} (${rel_path})${NC}..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 8 --max-time 120 -o "$tmp" "$REPO_SCRIPTS/$rel_path" || { rm -f "$tmp"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=8 --tries=2 -O "$tmp" "$REPO_SCRIPTS/$rel_path" || { rm -f "$tmp"; return 1; }
    else
        return 1
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    sed -i 's/\r$//' "$tmp" 2>/dev/null || true
    chmod 0755 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$LOCAL_DIR/$file_name"
}

deploy_cached_module() {
    local mod="$1"
    local rel_path="${MOD_MAP[$mod]}"
    [ -z "$rel_path" ] && rel_path="${mod}.sh"
    local file_name="$(basename "$rel_path")"

    [ -s "$LOCAL_DIR/$file_name" ] || return 1
    sed -i 's/\r$//' "$LOCAL_DIR/$file_name" 2>/dev/null || true
    if ! same_file "$LOCAL_DIR/$file_name" "/usr/bin/$mod"; then
        install -m 0755 "$LOCAL_DIR/$file_name" "/usr/bin/$mod" || return 1
    else
        chmod 0755 "/usr/bin/$mod" 2>/dev/null || true
    fi
    if [ "$mod" = "main" ] || [ "$mod" = "mtunnel" ]; then
        if ! same_file "$LOCAL_DIR/$file_name" "/usr/local/bin/mtunnel"; then
            install -m 0755 "$LOCAL_DIR/$file_name" /usr/local/bin/mtunnel 2>/dev/null || true
        fi
    fi
    if [ "$mod" = "mstats" ]; then
        install -m 0755 "$LOCAL_DIR/$file_name" /usr/bin/mstats 2>/dev/null || true
        ln -sfn /usr/bin/mstats /usr/bin/mstat 2>/dev/null || true
    fi
}

ensure_module() {
    local mod="$1"
    local rel_path="${MOD_MAP[$mod]}"
    [ -z "$rel_path" ] && rel_path="${mod}.sh"
    local file_name="$(basename "$rel_path")"
    local script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"

    if [ -s "$LOCAL_DIR/$file_name" ]; then deploy_cached_module "$mod" && return 0; fi
    if [ -s "$script_dir/$rel_path" ]; then
        cp -f "$script_dir/$rel_path" "$LOCAL_DIR/$file_name" 2>/dev/null || true
        chmod 0755 "$LOCAL_DIR/$file_name" 2>/dev/null || true
        deploy_cached_module "$mod" && return 0
    fi
    if [ -s "$script_dir/$file_name" ]; then
        cp -f "$script_dir/$file_name" "$LOCAL_DIR/$file_name" 2>/dev/null || true
        chmod 0755 "$LOCAL_DIR/$file_name" 2>/dev/null || true
        deploy_cached_module "$mod" && return 0
    fi
    if [ -s "/usr/bin/$mod" ]; then
        cp -f "/usr/bin/$mod" "$LOCAL_DIR/$file_name" 2>/dev/null || true
        chmod 0755 "$LOCAL_DIR/$file_name" 2>/dev/null || true
        deploy_cached_module "$mod" && return 0
    fi
    if download_file_to_cache "$mod"; then deploy_cached_module "$mod" && return 0; fi
    echo -e "  ${R}✗ ${W}${mod}${R} is not available locally and GitHub download failed.${NC}"
    return 1
}

run_mod() { local mod="$1"; ensure_module "$mod" || return 1; "$mod"; }

run_iperf3() {
    clear
    if ! command -v iperf3 >/dev/null 2>&1; then
        echo -e "\n  ${DIM}┌─[ IPERF3 PACKAGE INSTALLER ]${NC}"
        
        killall -9 apt-get apt dpkg 2>/dev/null || true
        rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock 2>/dev/null || true
        dpkg --configure -a >/dev/null 2>&1 || true

        (
            DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::ForceIPv4=true -y -q >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -o Acquire::ForceIPv4=true -y -q iperf3 >/dev/null 2>&1
        ) &
        local pid=$!
        draw_progress_bar "$pid" "Installing iPerf3 Benchmark"
        wait "$pid" 2>/dev/null
        
        if command -v iperf3 >/dev/null 2>&1; then
            echo -e "\n  ${G}✔ iPerf3 installed successfully.${NC}"
        else
            echo -e "\n  ${R}✘ apt-get background timed out, attempting direct install...${NC}"
            apt-get install -y iperf3 >/dev/null 2>&1
        fi
        sleep 1
    fi

    while true; do
        clear; echo ""
        local s_ip=$(get_local_ip)
        local str1=" iPerf3 Network Bandwidth Benchmark "
        local raw_len=$(( ${#str1} ))
        local pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
        local padding=$(printf '%*s' "$pad_len" "")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Port:${NC} ${C}5201 TCP/UDP${NC} ${padding}${B}│${NC}"
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"

        echo -e "\n  ${DIM}┌─[ BENCHMARK MODE ]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run as Server (Listener Mode)${NC} ${DIM}(Wait for peer connections)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run as Client (Sender Mode)${NC}   ${DIM}(Push bandwidth stream to server)${NC}"
        echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
        echo -ne "  ${C}iPerf3 ❯❯ ${NC}"; read i_opt
        i_opt=$(echo "$i_opt" | tr -d '\r' | tr -d ' ')

        case $i_opt in
            1) 
                echo -e "\n  ${G}● iPerf3 Server listening on port 5201 (Press Ctrl+C to stop)...${NC}\n"
                iperf3 -s -p 5201
                echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy ;;
            2) 
                echo -ne "\n  ${C}●${NC} ${W}Enter Target Server IP / Tunnel IP: ${NC}"; read t_ip
                t_ip=$(echo "$t_ip" | tr -d '\r' | tr -d ' ')
                [ -z "$t_ip" ] && continue
                echo -ne "  ${C}●${NC} ${W}Test Duration in Seconds [Default 10]: ${NC}"; read t_sec
                t_sec=${t_sec:-10}
                echo -e "\n  ${Y}● Running Benchmark against $t_ip (10s)...${NC}\n"
                iperf3 -c "$t_ip" -p 5201 -t "$t_sec"
                echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy ;;
            0) break ;;
        esac
    done
}

draw_main_header() {
    local s_ip=$(get_local_ip)
    local st_gre="○"; local c_gre="${DIM}"; [ -n "$(ls -A /etc/mgre/tunnels/*.conf 2>/dev/null)" ] && { st_gre="●"; c_gre="${G}"; }
    local st_vx="○"; local c_vx="${DIM}"; [ -n "$(ls -A /etc/mgre/vxlan/*.conf 2>/dev/null)" ] && { st_vx="●"; c_vx="${G}"; }
    local st_rh="○"; local c_rh="${DIM}"; [ -n "$(ls -A /etc/mrathole/tunnels/*.toml 2>/dev/null)" ] && { st_rh="●"; c_rh="${G}"; }
    local st_bh="○"; local c_bh="${DIM}"; [ -n "$(ls -A /etc/mbackhaul/tunnels/*.meta 2>/dev/null)" ] && { st_bh="●"; c_bh="${G}"; }
    local st_pq="○"; local c_pq="${DIM}"; [ -n "$(ls -A /etc/paqet/*.yaml 2>/dev/null)" ] && { st_pq="●"; c_pq="${G}"; }

    local bbr_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local bbr_stat="${DIM}○ OFF${NC}"
    local raw_bbr="○ OFF"
    if [ "$bbr_cc" == "bbr" ]; then bbr_stat="${G}● ON${NC}"; raw_bbr="● ON"; fi

    local web_stat="${DIM}○ OFFLINE${NC}"
    local raw_web="○ OFFLINE"
    if systemctl is-active --quiet mweb.service 2>/dev/null; then
        local w_port="1000"
        [ -f "/etc/mweb/web.conf" ] && w_port=$(grep "WEB_PORT" /etc/mweb/web.conf | cut -d= -f2 | tr -d ' ' | tr -d '\r')
        web_stat="${G}● PORT ${w_port}${NC}"
        raw_web="● PORT ${w_port}"
    fi

    local raw_top=" MDesign Master Core v8.1.0 │ IP: ${s_ip} │ Web: ${raw_web} │ BBR: ${raw_bbr} "
    local pad_top=$(( 94 - ${#raw_top} )); [ "$pad_top" -lt 0 ] && pad_top=0
    local padding_top=$(printf '%*s' "$pad_top" "")

    local raw_bot=" Hub: GRE:${st_gre}  VXLAN:${st_vx}  RatHole:${st_rh}  Backhaul:${st_bh}  Paqet:${st_pq} "
    local pad_bot=$(( 94 - ${#raw_bot} )); [ "$pad_bot" -lt 0 ] && pad_bot=0
    local padding_bot=$(printf '%*s' "$pad_bot" "")

    clear; echo ""
    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MDesign Master Core v8.1.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}Web:${NC} ${web_stat} ${B}│${NC} ${DIM}BBR:${NC} ${bbr_stat}${padding_top}${B}│${NC}"
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}${DIM} Hub: GRE:${NC}${c_gre}${st_gre}${NC}${DIM}  VXLAN:${NC}${c_vx}${st_vx}${NC}${DIM}  RatHole:${NC}${c_rh}${st_rh}${NC}${DIM}  Backhaul:${NC}${c_bh}${st_bh}${NC}${DIM}  Paqet:${NC}${c_pq}${st_pq}${NC}${padding_bot}${B}│${NC}"
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_tunnel_hub() {
    while true; do
        draw_main_header; echo ""
        echo -e "  ${DIM}┌─[ PRIMARY INFRASTRUCTURE HUB ]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Modular GRE/IP6GRE Core (Mgre)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}VXLAN Virtual Mesh Fabric (Mxlan)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Rathole Reverse Tunnel (Mrathole)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Backhaul Free Multiplexer (MBackhaul)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Paqet Raw Packet KCP Tunnel (MPaqet)${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Dashboard${NC}\n"
        echo -ne "  ${C}TUNNEL ❯❯ ${NC}"; read t_opt
        case $t_opt in
            1) run_mod "mgre" ;; 2) run_mod "mxlan" ;; 3) run_mod "mrathole" ;; 4) run_mod "mbackhaul" ;; 5) run_mod "mpaqet" ;; 0) break ;;
        esac
    done
}

while true; do
    draw_main_header; echo ""
    echo -e "  ${DIM}┌─[ CORE NETWORK & ROUTING ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Hub (GRE / VXLAN / Rat / BH / Paqet)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding Matrix (Mporter)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SECURITY, DIAGNOSTICS & BENCHMARK ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Stealth Anti-Probing & Anti-RST Shield${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${B}Bandwidth Radar & Web UI${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Autonomous Tunnel Healer${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Network Diagnostics & Tests${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Two-Way Link & Port Filter Scanner (LinkTest)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${C}iPerf3 Bandwidth Benchmark${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${G}TCP BBR Accelerator (Mbbr)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${Y}Download Binary Packages from GitHub${NC}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${M}Offline Local Deploy (Packages & Modules)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC}${DIM}❯${NC} ${R}Force Download & Install Core (From GitHub)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}14${NC}${DIM}❯${NC} ${R}Nuclear Wipe (Uninstall)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}15${NC}${DIM}❯${NC} ${Y}Install from Custom ZIP Link (Bypass Filter)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}\n"
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read opt

    case $opt in
        1) show_tunnel_hub ;; 2) run_mod "mporter" ;; 3) run_mod "minterface" ;; 4) run_mod "mshield" ;;
        5) run_mod "mstats" ;; 6) run_mod "mhealer" ;; 7) run_mod "mdiag" ;; 8) run_mod "linktest" ;; 9) run_iperf3 ;;
        10) run_mod "mbbr" ;;
        11)
           echo -e "\n  ${DIM}┌─[ GITHUB ASSETS DOWNLOADER ]${NC}"
           mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
           tmp_zip="$(mktemp /tmp/mtunnel-packages.XXXXXX.zip 2>/dev/null || echo /tmp/mtunnel-packages.zip)"
           rm -f "$tmp_zip"
           if command -v curl >/dev/null 2>&1; then
               curl -fsSL --retry 2 --connect-timeout 8 --max-time 180 -o "$tmp_zip" "$REPO_ZIP" &
               pid=$!; draw_progress_bar "$pid" "Fetching package archive"; wait "$pid"; rc=$?
           elif command -v wget >/dev/null 2>&1; then
               wget -q --timeout=8 --tries=2 -O "$tmp_zip" "$REPO_ZIP" &
               pid=$!; draw_progress_bar "$pid" "Fetching package archive"; wait "$pid"; rc=$?
           else rc=1; fi
           if [ "${rc:-1}" -eq 0 ] && command -v unzip >/dev/null 2>&1 && unzip -t "$tmp_zip" >/dev/null 2>&1; then
               tmp_dir="$(mktemp -d /tmp/mtunnel-packages.XXXXXX)"
               unzip -q -o "$tmp_zip" -d "$tmp_dir" 2>/dev/null
               pkg_root="$(find "$tmp_dir" -maxdepth 2 -type d -name packages -print -quit 2>/dev/null)"
               if [ -n "$pkg_root" ] && [ -d "$pkg_root" ]; then
                   cp -f "$pkg_root"/* "$LOCAL_DIR/packages/" 2>/dev/null || true
                   chmod +x "$LOCAL_DIR/packages/"* 2>/dev/null || true
                   for bin in bh rathole paqet haproxy; do
                       if [ -f "$LOCAL_DIR/packages/$bin" ] && [ ! -f "/usr/local/bin/$bin" ]; then
                           install -m 0755 "$LOCAL_DIR/packages/$bin" "/usr/local/bin/$bin" 2>/dev/null || true
                           echo -e "  ${G}✓${NC} Installed $bin"
                       fi
                   done
                   echo -e "  ${G}● Binary package cache updated.${NC}"
               fi
               rm -rf "$tmp_dir"
           else echo -e "  ${R}● Error reading GitHub package archive.${NC}"; fi
           rm -f "$tmp_zip"; sleep 1.5 ;;
        12)
           echo -e "\n  ${M}● Offline Local Deploy Engine (Scripts & Packages)${NC}"
           for mod in "${ALL_MODULES[@]}"; do
               rel_path="${MOD_MAP[$mod]}"; file_name="$(basename "$rel_path")"
               if [ -s "$LOCAL_DIR/$file_name" ]; then deploy_cached_module "$mod"; echo -e "  ${G}✓${NC} Module: $mod"; fi
           done
           local_pkg_dir="$LOCAL_DIR/packages"
           [ ! -d "$local_pkg_dir" ] && [ -d "./packages" ] && local_pkg_dir="./packages"
           if [ -d "$local_pkg_dir" ]; then
               mkdir -p /usr/local/bin /usr/sbin /etc/haproxy /var/lib/haproxy 2>/dev/null
               [ -f "$local_pkg_dir/haproxy" ] && cp -f "$local_pkg_dir/haproxy" /usr/sbin/haproxy && chmod +x /usr/sbin/haproxy
               for b in bh rathole paqet; do
                   if [ -f "$local_pkg_dir/$b" ]; then cp -f "$local_pkg_dir/$b" /usr/local/bin/$b; chmod +x "/usr/local/bin/$b"; echo -e "  ${G}✓${NC} Binary: $b"; fi
               done
               if ls "$local_pkg_dir"/*.deb >/dev/null 2>&1; then dpkg -i "$local_pkg_dir"/*.deb >/dev/null 2>&1 || true; fi
           fi
           echo -e "  ${G}● Local deployment and binary sync completed successfully.${NC}"; sleep 2 ;;
        13)
           echo -e "\n  ${R}● Force Download & Install Core${NC}"
           mkdir -p "$LOCAL_DIR" 2>/dev/null
           if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 8 -o "$LOCAL_DIR/install.sh" "$REPO_SCRIPTS/install.sh" 2>/dev/null
           elif command -v wget >/dev/null 2>&1; then wget -q --timeout=8 -O "$LOCAL_DIR/install.sh" "$REPO_SCRIPTS/install.sh" 2>/dev/null
           fi
           if [ -s "$LOCAL_DIR/install.sh" ]; then chmod +x "$LOCAL_DIR/install.sh"; bash "$LOCAL_DIR/install.sh" --force
           else echo -e "  ${R}✗ Failed to fetch installer from GitHub.${NC}"; sleep 1.5; fi ;;
        14)
            clear
            echo -e "\n  ${R}╭────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${R}│${NC} ${W}MTunnel Nuclear Wipe${NC}                                      ${R}│${NC}"
            echo -e "  ${R}╰────────────────────────────────────────────────────────────╯${NC}\n"
            echo -ne "  ${R}Type WIPE-MTUNNEL to continue: ${NC}"; read del_confirm
            del_confirm="${del_confirm//[$' \r\n']/}"
            if [[ "$del_confirm" == "WIPE-MTUNNEL" ]]; then
                systemctl stop mgre.service mxlan.service mporter.service mporter-watchdog.service mweb.service mhealer.service mshield.service mbackhaul@* mrathole@* mpaqet@* 2>/dev/null || true
                systemctl disable mgre.service mxlan.service mporter.service mporter-watchdog.service mweb.service mhealer.service mshield.service mbackhaul@* mrathole@* mpaqet@* 2>/dev/null || true
                rm -f /etc/systemd/system/mgre.service /etc/systemd/system/mxlan.service /etc/systemd/system/mporter*.service /etc/systemd/system/mweb.service /etc/systemd/system/mhealer.service /etc/systemd/system/mshield*.service /etc/systemd/system/mbackhaul@.service /etc/systemd/system/mrathole@.service /etc/systemd/system/mpaqet@.service
                systemctl daemon-reload
                ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(gre|br_|vx_)' | while read -r iface; do [ -n "$iface" ]||continue; ip link del "$iface" 2>/dev/null||true; ip tunnel del "$iface" 2>/dev/null||true; done
                rm -rf /etc/mgre /etc/mporter /etc/mweb /etc/mshield /etc/mstats /etc/mrathole /etc/mbackhaul /etc/paqet /root/mtunnel
                rm -f /usr/bin/mtunnel /usr/bin/mgre /usr/bin/mxlan /usr/bin/mbackhaul /usr/bin/mpaqet /usr/bin/mporter /usr/bin/minterface /usr/bin/mdiag /usr/bin/mshield /usr/bin/mstats /usr/bin/mstat /usr/bin/mhealer /usr/bin/mweb /usr/bin/mrathole /usr/bin/mbbr /usr/bin/linktest
                echo -e "\n  ${G}✓ MTunnel wipe completed.${NC}\n"; exit 0
            fi ;;
        15)
           echo -e "\n  ${DIM}┌─[ CUSTOM ZIP DEPLOYMENT ]${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter Direct ZIP Link: ${NC}"; read zip_url
           zip_url=$(echo "$zip_url" | tr -d '\r' | tr -d ' ')
           if [ -z "$zip_url" ]; then echo -e "  ${R}✖ Invalid URL!${NC}"; sleep 1.5; continue; fi

           apt-get install -y -q unzip wget curl >/dev/null 2>&1 || true

           tmp_zip="$(mktemp /tmp/custom-repo.XXXXXX.zip 2>/dev/null || echo /tmp/custom-repo.zip)"
           rm -f "$tmp_zip"
           
           if command -v curl >/dev/null 2>&1; then
               curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 -o "$tmp_zip" "$zip_url" &
               pid=$!; draw_progress_bar "$pid" "Downloading Custom ZIP"; wait "$pid"; rc=$?
           elif command -v wget >/dev/null 2>&1; then
               wget -q --timeout=10 --tries=2 -O "$tmp_zip" "$zip_url" &
               pid=$!; draw_progress_bar "$pid" "Downloading Custom ZIP"; wait "$pid"; rc=$?
           else rc=1; fi

           if [ "${rc:-1}" -eq 0 ] && command -v unzip >/dev/null 2>&1 && unzip -t "$tmp_zip" >/dev/null 2>&1; then
               tmp_dir="$(mktemp -d /tmp/custom-repo.XXXXXX)"
               unzip -q -o "$tmp_zip" -d "$tmp_dir" 2>/dev/null
               
               repo_root="$(find "$tmp_dir" -type f -name "main.sh" -exec dirname {} \; | head -n 1)"
               
               if [ -n "$repo_root" ] && [ -d "$repo_root" ]; then
                   mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
                   cp -rf "$repo_root"/* "$LOCAL_DIR/" 2>/dev/null
                   chmod -R +x "$LOCAL_DIR"/*.sh "$LOCAL_DIR"/tunnels/*.sh "$LOCAL_DIR"/tools/*.sh 2>/dev/null || true
                   
                   echo -e "  ${G}● Extraction successful! Deploying modules...${NC}"
                   for mod in "${ALL_MODULES[@]}"; do
                       rel_path="${MOD_MAP[$mod]}"; file_name="$(basename "$rel_path")"
                       if [ -s "$LOCAL_DIR/$rel_path" ] && [ "$rel_path" != "$file_name" ]; then
                           cp -f "$LOCAL_DIR/$rel_path" "$LOCAL_DIR/$file_name" 2>/dev/null
                       fi
                       if [ -s "$LOCAL_DIR/$file_name" ]; then 
                           deploy_cached_module "$mod"
                           echo -e "  ${G}✓${NC} Module: $mod"
                       fi
                   done
                   
                   local_pkg_dir="$LOCAL_DIR/packages"
                   if [ -d "$local_pkg_dir" ]; then
                       mkdir -p /usr/local/bin /usr/sbin /etc/haproxy /var/lib/haproxy 2>/dev/null
                       [ -f "$local_pkg_dir/haproxy" ] && cp -f "$local_pkg_dir/haproxy" /usr/sbin/haproxy && chmod +x /usr/sbin/haproxy
                       for b in bh rathole paqet; do
                           if [ -f "$local_pkg_dir/$b" ]; then cp -f "$local_pkg_dir/$b" /usr/local/bin/$b; chmod +x "/usr/local/bin/$b"; echo -e "  ${G}✓${NC} Binary: $b"; fi
                       done
                       if ls "$local_pkg_dir"/*.deb >/dev/null 2>&1; then dpkg -i "$local_pkg_dir"/*.deb >/dev/null 2>&1 || true; fi
                   fi
                   
                   if [ -f "$LOCAL_DIR/main.sh" ]; then
                       cp -f "$LOCAL_DIR/main.sh" "$MTUNNEL_PATH" 2>/dev/null
                       chmod +x "$MTUNNEL_PATH" 2>/dev/null
                   fi

                   echo -e "  ${G}● Full Custom Deployment Completed!${NC}"; sleep 2
               else
                   echo -e "  ${R}✖ Invalid structure! Couldn't find 'main.sh' in the ZIP.${NC}"; sleep 2
               fi
               rm -rf "$tmp_dir"
           else
               echo -e "  ${R}✖ Download failed or ZIP is corrupted!${NC}"; sleep 2
           fi
           rm -f "$tmp_zip"
           ;;
        0) clear; exit 0 ;;
    esac
done
