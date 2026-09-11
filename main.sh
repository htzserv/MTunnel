#!/bin/bash
# --- MDesign Master Core | Central Dashboard v8.3.4 ---
# [Features: True Parallel Multi-Checker | Fast Responsive OTA | Zero-Lag Signal]

MODULE_VERSION="8.3.4"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
MTUNNEL_PATH="/usr/bin/mtunnel"
REPO_ZIP="https://github.com/htzserv/MTunnel/archive/refs/heads/main.zip"
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
MIRROR_SCRIPTS="https://c107328.parspack.net/c107328/MTunnel"
MIRROR_PACKAGES="https://c107328.parspack.net/c107328/MTunnel/packages"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
UPDATE_FILE="$SECURE_TMP/.modules_update_status"

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

mkdir -p "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$LOCAL_DIR/tools" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [[ ! -x "$MTUNNEL_PATH" ]]; then
    cp "$0" "$MTUNNEL_PATH" 2>/dev/null
    chmod +x "$MTUNNEL_PATH" 2>/dev/null
fi

MAIN_PID=$$
NEED_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1

# --- TRUE PARALLEL BACKGROUND CHECKER ---
check_single_module() {
    local mod="$1"
    local rel_path="$2"
    local local_file="$LOCAL_DIR/$rel_path"
    [ ! -f "$local_file" ] && [ -f "/usr/bin/$mod" ] && local_file="/usr/bin/$mod"

    local cur_v=""
    [ -f "$local_file" ] && cur_v=$(grep -m1 '^MODULE_VERSION=' "$local_file" | cut -d'"' -f2)
    [ -z "$cur_v" ] && cur_v="0.0.0"

    local cb="?t=$(date +%s%N)"
    local rem_v=""
    if command -v curl >/dev/null 2>&1; then
        rem_v=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 4 --max-time 6 "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        rem_v=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=6 "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi

    if [ -n "$rem_v" ] && [ "$rem_v" != "$cur_v" ]; then
        echo "${mod}:${cur_v}:${rem_v}" >> "$UPDATE_FILE"
        kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
    fi
}

check_all_updates_bg() {
    > "$UPDATE_FILE"
    for mod in "${!MOD_MAP[@]}"; do
        check_single_module "$mod" "${MOD_MAP[$mod]}" &
    done
    wait
}
check_all_updates_bg &
# ----------------------------------------

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_progress_bar() {
    local pid=$1 text=$2 width=30 progress=0 filled empty bar rest
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        ((progress++))
        [ "$progress" -gt 95 ] && progress=95
        filled=$(( progress * width / 100 ))
        empty=$(( width - filled ))
        bar="$(printf '%*s' "$filled" '' | tr ' ' '#')"
        rest="$(printf '%*s' "$empty" '' | tr ' ' '-')"
        printf "\r  %b→%b %-26s %b[%s%b%s%b] %3d%%" "$C" "$NC" "$text" "$W" "$bar" "$DIM" "$rest" "$NC" "$progress"
        sleep 0.12
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
    local base_url="$2"
    local rel_path="${MOD_MAP[$mod]}"
    [ -z "$rel_path" ] && rel_path="${mod}.sh"
    local target_file="$LOCAL_DIR/$rel_path"
    local tmp="${target_file}.$$"
    
    mkdir -p "$(dirname "$target_file")" 2>/dev/null
    rm -f "$tmp"
    
    local CB="?t=$(date +%s%N)"
    local DL_SUCCESS=false

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 --max-time 120 -o "$tmp" "$base_url/$rel_path$CB" 2>/dev/null && DL_SUCCESS=true
    elif command -v wget >/dev/null 2>&1; then
        wget -q --no-check-certificate --header="Cache-Control: no-cache" --timeout=8 -O "$tmp" "$base_url/$rel_path$CB" 2>/dev/null && DL_SUCCESS=true
    fi

    [ "$DL_SUCCESS" = true ] && [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    sed -i 's/\r$//' "$tmp" 2>/dev/null || true
    chmod 0755 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$target_file"
}

deploy_cached_module() {
    local mod="$1"
    local rel_path="${MOD_MAP[$mod]}"
    [ -z "$rel_path" ] && rel_path="${mod}.sh"
    local target_file="$LOCAL_DIR/$rel_path"

    [ -s "$target_file" ] || return 1
    sed -i 's/\r$//' "$target_file" 2>/dev/null || true
    if ! same_file "$target_file" "/usr/bin/$mod"; then
        install -m 0755 "$target_file" "/usr/bin/$mod" || return 1
    else
        chmod 0755 "/usr/bin/$mod" 2>/dev/null || true
    fi
}

ensure_module() {
    local mod="$1"
    local rel_path="${MOD_MAP[$mod]}"
    [ -z "$rel_path" ] && rel_path="${mod}.sh"
    local target_file="$LOCAL_DIR/$rel_path"

    mkdir -p "$(dirname "$target_file")" 2>/dev/null

    if [ -s "$target_file" ]; then deploy_cached_module "$mod" && return 0; fi
    if [ -s "/usr/bin/$mod" ]; then
        cp -f "/usr/bin/$mod" "$target_file" 2>/dev/null || true
        chmod 0755 "$target_file" 2>/dev/null || true
        deploy_cached_module "$mod" && return 0
    fi
    if download_file_to_cache "$mod" "$REPO_SCRIPTS"; then deploy_cached_module "$mod" && return 0; fi
    echo -e "  ${R}✗ ${W}${mod}${R} is not available locally and GitHub download failed.${NC}"
    return 1
}

run_mod() { local mod="$1"; ensure_module "$mod" || return 1; "$mod"; }

show_ota_update_hub() {
    while true; do
        clear; echo ""
        echo -e "  ${B}╭──────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC} ${W}MDesign Ecosystem Central Updater${NC}                           ${B}│${NC}"
        echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"

        echo -e "\n  ${DIM}┌─[ SCRIPT CORE ENGINE UPDATES ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Sync All Scripts from Official GitHub${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Sync All Scripts from Iranian Mirror (ParsPack)${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─[ BINARY PACKAGES & CORES ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Fetch Binary Packages from Official GitHub Archive${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Fetch Binary Packages from Iranian Mirror${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─[ MANUAL & OVERRIDE METHODS ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Custom Personal Link (.sh Script or ZIP)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${M}Manual Code Paste (Offline Editor)${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Dashboard${NC}\n"

        echo -ne "  ${C}OTA-HUB ❯❯ ${NC}"; read ota_opt
        ota_opt=$(echo "$ota_opt" | tr -d '\r ')

        case $ota_opt in
            1|2)
                local s_url="$REPO_SCRIPTS"
                local s_name="Official GitHub"
                [ "$ota_opt" == "2" ] && s_url="$MIRROR_SCRIPTS" && s_name="ParsPack Mirror"

                clear; echo -e "\n  ${DIM}┌─[ SYNCING SCRIPTS: ${W}${s_name}${DIM} ]${NC}"
                echo -e "  ${DIM}├────────────────────────────────────────────────────────────${NC}"

                for mod in "${ALL_MODULES[@]}"; do
                    local rel_p="${MOD_MAP[$mod]}"
                    printf "  ${C}→${NC} %-22s " "$mod ($rel_p)"
                    if download_file_to_cache "$mod" "$s_url"; then
                        deploy_cached_module "$mod"
                        local n_v=$(grep -m1 '^MODULE_VERSION=' "$LOCAL_DIR/$rel_p" 2>/dev/null | cut -d'"' -f2)
                        printf "${G}[✔ UPGRADED: v%s]${NC}\n" "${n_v:-OK}"
                    else
                        printf "${R}[✖ FAILED]${NC}\n"
                    fi
                done
                > "$UPDATE_FILE"
                echo -e "  ${DIM}└────────────────────────────────────────────────────────────┘${NC}"
                echo -e "  ${G}● Script sync finished. Press Enter to reload core...${NC}"; read dummy
                exec "$MTUNNEL_PATH"
                ;;

            3)
                echo -e "\n  ${DIM}┌─[ GITHUB ASSETS DOWNLOADER ]${NC}"
                mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
                local tmp_zip="$(mktemp /tmp/mtunnel-packages.XXXXXX.zip 2>/dev/null || echo /tmp/mtunnel-packages.zip)"
                rm -f "$tmp_zip"
                local CB="?t=$(date +%s)"
                
                (
                    if command -v curl >/dev/null 2>&1; then
                        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 --max-time 180 -o "$tmp_zip" "$REPO_ZIP$CB" 2>/dev/null
                    elif command -v wget >/dev/null 2>&1; then
                        wget -q --no-check-certificate --header="Cache-Control: no-cache" --timeout=8 -O "$tmp_zip" "$REPO_ZIP$CB" 2>/dev/null
                    fi
                ) &
                local pid=$!; draw_progress_bar "$pid" "Fetching GitHub Packages"; wait "$pid"
                
                if [ -s "$tmp_zip" ] && command -v unzip >/dev/null 2>&1 && unzip -t "$tmp_zip" >/dev/null 2>&1; then
                    (
                        local tmp_dir="$(mktemp -d /tmp/mtunnel-packages.XXXXXX)"
                        unzip -q -o "$tmp_zip" -d "$tmp_dir" 2>/dev/null
                        local pkg_root="$(find "$tmp_dir" -maxdepth 2 -type d -name packages -print -quit 2>/dev/null)"
                        if [ -n "$pkg_root" ] && [ -d "$pkg_root" ]; then
                            cp -f "$pkg_root"/* "$LOCAL_DIR/packages/" 2>/dev/null || true
                            chmod +x "$LOCAL_DIR/packages/"* 2>/dev/null || true
                            [ -f "$LOCAL_DIR/packages/haproxy" ] && install -m 0755 "$LOCAL_DIR/packages/haproxy" /usr/sbin/haproxy 2>/dev/null || true
                            for bin in bh backhaul rathole paqet gost frpc frps; do
                                if [ -f "$LOCAL_DIR/packages/$bin" ]; then
                                    install -m 0755 "$LOCAL_DIR/packages/$bin" "/usr/local/bin/$bin" 2>/dev/null || true
                                fi
                            done
                            if ls "$LOCAL_DIR/packages"/*.deb >/dev/null 2>&1; then dpkg -i "$LOCAL_DIR/packages"/*.deb >/dev/null 2>&1 || true; fi
                        fi
                        rm -rf "$tmp_dir"
                    ) &
                    pid=$!; draw_progress_bar "$pid" "Deploying Packages"; wait "$pid"
                    echo -e "  ${G}● Official binary packages updated successfully.${NC}"
                else
                    echo -e "  ${R}● Failed to download or read archive.${NC}"
                fi
                rm -f "$tmp_zip"; sleep 1.5
                ;;

            4)
                echo -e "\n  ${DIM}┌─[ PARSPACK IRANIAN MIRROR PACKAGES ]${NC}"
                mkdir -p "$LOCAL_DIR/packages" /usr/local/bin /usr/sbin 2>/dev/null
                local bins=("rathole" "bh" "paqet" "gost" "haproxy")
                local CB="?t=$(date +%s)"
                
                for b in "${bins[@]}"; do
                    printf "  ${C}→${NC} Downloading %-15s " "$b"
                    local t_out="$LOCAL_DIR/packages/$b"
                    local dl_ok=false
                    if command -v curl >/dev/null 2>&1; then
                        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 -o "$t_out" "$MIRROR_PACKAGES/$b$CB" 2>/dev/null && dl_ok=true
                    elif command -v wget >/dev/null 2>&1; then
                        wget -q --no-check-certificate --header="Cache-Control: no-cache" --timeout=8 -O "$t_out" "$MIRROR_PACKAGES/$b$CB" 2>/dev/null && dl_ok=true
                    fi

                    if [ "$dl_ok" = true ] && [ -s "$t_out" ]; then
                        chmod +x "$t_out"
                        [ "$b" == "haproxy" ] && install -m 0755 "$t_out" /usr/sbin/haproxy 2>/dev/null
                        [ "$b" != "haproxy" ] && install -m 0755 "$t_out" "/usr/local/bin/$b" 2>/dev/null
                        printf "${G}[✔ INSTALLED]${NC}\n"
                    else
                        printf "${R}[✖ FAILED]${NC}\n"
                    fi
                done
                echo -e "  ${G}● Iranian mirror packages deployed.${NC}"; sleep 1.5
                ;;

            5)
                echo -e "\n  ${DIM}┌─[ CUSTOM DIRECT LINK DEPLOYMENT ]${NC}"
                echo -ne "  ${C}●${NC} ${W}Enter Direct (.sh or .zip) URL: ${NC}"; read custom_url
                custom_url=$(echo "$custom_url" | tr -d '\r ')
                [ -z "$custom_url" ] && continue

                local tmp_dl="$SECURE_TMP/.custom_download.$$"
                rm -f "$tmp_dl"

                if command -v curl >/dev/null 2>&1; then
                    curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 10 -o "$tmp_dl" "$custom_url" 2>/dev/null
                elif command -v wget >/dev/null 2>&1; then
                    wget -q --no-check-certificate --header="Cache-Control: no-cache" --timeout=10 -O "$tmp_dl" "$custom_url" 2>/dev/null
                fi

                if [ -s "$tmp_dl" ]; then
                    if command -v unzip >/dev/null 2>&1 && unzip -t "$tmp_dl" >/dev/null 2>&1; then
                        local t_dir="$(mktemp -d /tmp/custom-unzip.XXXXXX)"
                        unzip -q -o "$tmp_dl" -d "$t_dir" 2>/dev/null
                        local r_root="$(find "$t_dir" -type f -name "main.sh" -exec dirname {} \; | head -n 1)"
                        if [ -n "$r_root" ] && [ -d "$r_root" ]; then
                            cp -rf "$r_root"/* "$LOCAL_DIR/" 2>/dev/null
                            for m in "${ALL_MODULES[@]}"; do deploy_cached_module "$m" 2>/dev/null; done
                            echo -e "  ${G}✔ Archive fully extracted and deployed!${NC}"
                        fi
                        rm -rf "$t_dir"
                    elif grep -q "#!/bin/bash" "$tmp_dl"; then
                        echo -e "\n  ${DIM}Select Module Target to overwrite:${NC}"
                        local i=1
                        for m in "${ALL_MODULES[@]}"; do
                            printf "  ${DIM}%2d)${NC} %-12s " "$i" "$m"
                            ((i % 3 == 0)) && echo ""
                            ((i++))
                        done
                        echo -ne "\n  ${C}Enter number: ${NC}"; read m_num
                        local chosen_mod="${ALL_MODULES[$((m_num - 1))]}"
                        if [ -n "$chosen_mod" ]; then
                            local dest="$LOCAL_DIR/${MOD_MAP[$chosen_mod]}"
                            cat "$tmp_dl" > "$dest"
                            deploy_cached_module "$chosen_mod"
                            echo -e "  ${G}✔ Successfully applied to ${chosen_mod}!${NC}"
                        fi
                    fi
                else
                    echo -e "  ${R}✖ Download failed! Check URL.${NC}"
                fi
                rm -f "$tmp_dl"; sleep 2
                ;;

            6)
                echo -e "\n  ${DIM}┌─[ MANUAL SCRIPT CODE PASTE ]${NC}"
                echo -e "  ${DIM}Select target module to edit:${NC}"
                local i=1
                for m in "${ALL_MODULES[@]}"; do
                    printf "  ${DIM}%2d)${NC} %-12s " "$i" "$m"
                    ((i % 3 == 0)) && echo ""
                    ((i++))
                done
                echo -ne "\n  ${C}Enter number: ${NC}"; read m_num
                local chosen_mod="${ALL_MODULES[$((m_num - 1))]}"
                if [ -n "$chosen_mod" ]; then
                    local dest="$LOCAL_DIR/${MOD_MAP[$chosen_mod]}"
                    mkdir -p "$(dirname "$dest")" 2>/dev/null
                    [ ! -f "$dest" ] && touch "$dest"
                    if command -v nano >/dev/null 2>&1; then
                        nano "$dest"
                    elif command -v vi >/dev/null 2>&1; then
                        vi "$dest"
                    fi
                    chmod +x "$dest"
                    deploy_cached_module "$chosen_mod"
                    echo -e "  ${G}✔ Module ${chosen_mod} saved and deployed!${NC}"
                    sleep 1.5
                fi
                ;;

            0) break ;;
        esac
    done
}

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
            echo -e "\n  ${R}✘ Direct install attempt...${NC}"
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
        i_opt=$(echo "$i_opt" | tr -d '\r ' )

        case $i_opt in
            1) 
                echo -e "\n  ${G}● iPerf3 Server listening on port 5201 (Press Ctrl+C to stop)...${NC}\n"
                iperf3 -s -p 5201
                echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy ;;
            2) 
                echo -ne "\n  ${C}●${NC} ${W}Enter Target Server IP / Tunnel IP: ${NC}"; read t_ip
                t_ip=$(echo "$t_ip" | tr -d '\r ' )
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

    local raw_top=" MDesign Master Core v${MODULE_VERSION} │ IP: ${s_ip} │ Web: ${raw_web} │ BBR: ${raw_bbr} "
    local pad_top=$(( 94 - ${#raw_top} )); [ "$pad_top" -lt 0 ] && pad_top=0
    local padding_top=$(printf '%*s' "$pad_top" "")

    local raw_bot=" Hub: GRE:${st_gre}  VXLAN:${st_vx}  RatHole:${st_rh}  Backhaul:${st_bh}  Paqet:${st_pq} "
    local pad_bot=$(( 94 - ${#raw_bot} )); [ "$pad_bot" -lt 0 ] && pad_bot=0
    local padding_bot=$(printf '%*s' "$pad_bot" "")

    clear; echo ""
    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MDesign Master Core v${MODULE_VERSION}${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}Web:${NC} ${web_stat} ${B}│${NC} ${DIM}BBR:${NC} ${bbr_stat}${padding_top}${B}│${NC}"
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}${DIM} Hub: GRE:${NC}${c_gre}${st_gre}${NC}${DIM}  VXLAN:${NC}${c_vx}${st_vx}${NC}${DIM}  RatHole:${NC}${c_rh}${st_rh}${NC}${DIM}  Backhaul:${NC}${c_bh}${st_bh}${NC}${DIM}  Paqet:${NC}${c_pq}${st_pq}${NC}${padding_bot}${B}│${NC}"
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_tunnel_hub() {
    while true; do
        local b_gre="" b_vx="" b_rh="" b_bh="" b_pq=""
        if [ -f "$UPDATE_FILE" ]; then
            grep -q "^mgre:" "$UPDATE_FILE" && b_gre=" ${Y}(Update Available)${NC}"
            grep -q "^mxlan:" "$UPDATE_FILE" && b_vx=" ${Y}(Update Available)${NC}"
            grep -q "^mrathole:" "$UPDATE_FILE" && b_rh=" ${Y}(Update Available)${NC}"
            grep -q "^mbackhaul:" "$UPDATE_FILE" && b_bh=" ${Y}(Update Available)${NC}"
            grep -q "^mpaqet:" "$UPDATE_FILE" && b_pq=" ${Y}(Update Available)${NC}"
        fi

        draw_main_header; echo ""
        echo -e "  ${DIM}┌─[ PRIMARY INFRASTRUCTURE HUB ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Modular GRE/IP6GRE Core (Mgre)${NC}${b_gre}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}VXLAN Virtual Mesh Fabric (Mxlan)${NC}${b_vx}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Rathole Reverse Tunnel (Mrathole)${NC}${b_rh}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Backhaul Free Multiplexer (MBackhaul)${NC}${b_bh}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Paqet Raw Packet KCP Tunnel (MPaqet)${NC}${b_pq}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Dashboard${NC}\n"
        echo -ne "  ${C}TUNNEL ❯❯ ${NC}"; read t_opt
        case $t_opt in
            1) run_mod "mgre" ;; 2) run_mod "mxlan" ;; 3) run_mod "mrathole" ;; 4) run_mod "mbackhaul" ;; 5) run_mod "mpaqet" ;; 0) break ;;
        esac
    done
}

while true; do
    NEED_REFRESH=false
    badge_hub="" badge_porter="" badge_main="" badge_bbr="" badge_diag="" badge_shield="" badge_link="" badge_stats="" badge_healer="" badge_iface=""
    
    if [ -f "$UPDATE_FILE" ]; then
        if grep -qE "^(mgre|mxlan|mrathole|mbackhaul|mpaqet):" "$UPDATE_FILE"; then
            badge_hub=" ${Y}(Update Available)${NC}"
        fi
        if grep -q "^mporter:" "$UPDATE_FILE"; then
            local p_ver=$(grep "^mporter:" "$UPDATE_FILE" | cut -d: -f3)
            badge_porter=" ${Y}(v${p_ver})${NC}"
        fi
        if grep -q "^main:" "$UPDATE_FILE"; then
            local m_ver=$(grep "^main:" "$UPDATE_FILE" | cut -d: -f3)
            badge_main=" ${Y}(v${m_ver})${NC}"
        fi
        if grep -q "^mbbr:" "$UPDATE_FILE"; then
            local b_ver=$(grep "^mbbr:" "$UPDATE_FILE" | cut -d: -f3)
            badge_bbr=" ${Y}(v${b_ver})${NC}"
        fi
        if grep -q "^mdiag:" "$UPDATE_FILE"; then
            local d_ver=$(grep "^mdiag:" "$UPDATE_FILE" | cut -d: -f3)
            badge_diag=" ${Y}(v${d_ver})${NC}"
        fi
        if grep -q "^mshield:" "$UPDATE_FILE"; then
            local s_ver=$(grep "^mshield:" "$UPDATE_FILE" | cut -d: -f3)
            badge_shield=" ${Y}(v${s_ver})${NC}"
        fi
        if grep -q "^linktest:" "$UPDATE_FILE"; then
            local l_ver=$(grep "^linktest:" "$UPDATE_FILE" | cut -d: -f3)
            badge_link=" ${Y}(v${l_ver})${NC}"
        fi
        if grep -q "^mstats:" "$UPDATE_FILE"; then
            local st_ver=$(grep "^mstats:" "$UPDATE_FILE" | cut -d: -f3)
            badge_stats=" ${Y}(v${st_ver})${NC}"
        fi
        if grep -q "^mhealer:" "$UPDATE_FILE"; then
            local h_ver=$(grep "^mhealer:" "$UPDATE_FILE" | cut -d: -f3)
            badge_healer=" ${Y}(v${h_ver})${NC}"
        fi
        if grep -q "^minterface:" "$UPDATE_FILE"; then
            local if_ver=$(grep "^minterface:" "$UPDATE_FILE" | cut -d: -f3)
            badge_iface=" ${Y}(v${if_ver})${NC}"
        fi
    fi

    draw_main_header; echo ""
    echo -e "  ${DIM}┌─[ CORE NETWORK & ROUTING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Hub (GRE / VXLAN / Rat / BH / Paqet)${NC}${badge_hub}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding Matrix (Mporter)${NC}${badge_porter}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC}${badge_iface}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SECURITY, DIAGNOSTICS & BENCHMARK ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Stealth Anti-Probing & Anti-RST Shield${NC}${badge_shield}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${B}Bandwidth Radar & Web UI${NC}${badge_stats}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Autonomous Tunnel Healer${NC}${badge_healer}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Network Diagnostics & Tests${NC}${badge_diag}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Two-Way Link & Port Filter Scanner (LinkTest)${NC}${badge_link}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${C}iPerf3 Bandwidth Benchmark${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${G}TCP BBR Accelerator (Mbbr)${NC}${badge_bbr}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${G}Unified Multi-Tier OTA Update Hub${NC}${badge_main}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${M}Offline Local Deploy (Packages & Modules)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC}${DIM}❯${NC} ${R}Nuclear Wipe (Uninstall)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}\n"

    echo -ne "  ${C}CORE ❯❯ ${NC}"; read -t 15 opt
    read_exit_status=$?

    # بررسی دریافت سیگنال از چکر پس‌زمینه برای رفرش آنی
    if [ "$NEED_REFRESH" = true ] && [ "$read_exit_status" -gt 128 ]; then
        continue
    fi

    opt=$(echo "$opt" | tr -d '\r ')

    case $opt in
        1) show_tunnel_hub ;;
        2) run_mod "mporter" ;;
        3) run_mod "minterface" ;;
        4) run_mod "mshield" ;;
        5) run_mod "mstats" ;;
        6) run_mod "mhealer" ;;
        7) run_mod "mdiag" ;;
        8) run_mod "linktest" ;;
        9) run_iperf3 ;;
        10) run_mod "mbbr" ;;
        11) show_ota_update_hub ;;
        12)
           echo -e "\n  ${M}● Offline Local Deploy Engine (Scripts & Packages)${NC}"
           (
               for mod in "${ALL_MODULES[@]}"; do
                   rel_path="${MOD_MAP[$mod]}"
                   if [ -s "$LOCAL_DIR/$rel_path" ]; then deploy_cached_module "$mod" >/dev/null 2>&1; fi
               done
               local_pkg_dir="$LOCAL_DIR/packages"
               [ ! -d "$local_pkg_dir" ] && [ -d "./packages" ] && local_pkg_dir="./packages"
               if [ -d "$local_pkg_dir" ]; then
                   mkdir -p /usr/local/bin /usr/sbin /etc/haproxy /var/lib/haproxy 2>/dev/null
                   [ -f "$local_pkg_dir/haproxy" ] && cp -f "$local_pkg_dir/haproxy" /usr/sbin/haproxy && chmod +x /usr/sbin/haproxy
                   for b in bh backhaul rathole paqet gost frpc frps; do
                       if [ -f "$local_pkg_dir/$b" ]; then cp -f "$local_pkg_dir/$b" /usr/local/bin/$b; chmod +x "/usr/local/bin/$b"; fi
                   done
                   if ls "$local_pkg_dir"/*.deb >/dev/null 2>&1; then dpkg -i "$local_pkg_dir"/*.deb >/dev/null 2>&1 || true; fi
               fi
           ) &
           pid=$!; draw_progress_bar "$pid" "Deploying Modules & Packages"; wait "$pid"
           echo -e "  ${G}● Local deployment and binary sync completed successfully.${NC}"; sleep 2 ;;
        13)
            clear
            echo -e "\n  ${R}╭────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${R}│${NC} ${W}MTunnel Nuclear Wipe${NC}                                      ${R}│${NC}"
            echo -e "  ${R}╰────────────────────────────────────────────────────────────╯${NC}\n"
            echo -ne "  ${R}Type WIPE-MTUNNEL to continue: ${NC}"; read del_confirm
            del_confirm="${del_confirm//[$' \r\n']/}"
            if [[ "$del_confirm" == "WIPE-MTUNNEL" ]]; then
                systemctl stop mgre.service mxlan.service mporter.service mporter-watchdog.service mweb.service mhealer.service mshield.service mbackhaul@* mrathole@* mpaqet@* 2>/dev/null || true
                systemctl disable mgre.service mxlan.service mporter.service mporter-watchdog.service mweb.service mhealer.service mshield.service mbackhaul@* mrathole@* mpaqet@* 2>/dev/null || true
                rm -rf /etc/mgre /etc/mporter /etc/mweb /etc/mshield /etc/mstats /etc/mrathole /etc/mbackhaul /etc/paqet /root/mtunnel
                rm -f /usr/bin/mtunnel /usr/bin/mgre /usr/bin/mxlan /usr/bin/mbackhaul /usr/bin/mpaqet /usr/bin/mporter /usr/bin/minterface /usr/bin/mdiag /usr/bin/mshield /usr/bin/mstats /usr/bin/mstat /usr/bin/mhealer /usr/bin/mweb /usr/bin/mrathole /usr/bin/mbbr /usr/bin/linktest
                echo -e "\n  ${G}✓ MTunnel wipe completed.${NC}\n"; exit 0
            fi ;;
        0) clear; exit 0 ;;
    esac
done
