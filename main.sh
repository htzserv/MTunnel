#!/bin/bash
# --- MDesign Master Core | Central Dashboard v8.4.3 ---
# [Features: Signal-Interrupted Instant Refresh | Original Colors | Unblocked Typing]

MODULE_VERSION="9.0.0"

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

# پکیج‌ها و باینری‌های پوشه packages
ALL_PACKAGES=(
    "bh"
    "rathole"
    "paqet"
    "gost"
    "haproxy"
    "cron_3.0pl1-184ubuntu2_amd64.deb"
    "curl_8.5.0-2ubuntu10.11_amd64.deb"
    "gzip_1.12-1ubuntu3.2_amd64.deb"
    "haproxy_2.8.16-0ubuntu0.24.04.3_amd64.deb"
    "iperf3_3.16-1build2_amd64.deb"
    "iproute2_6.1.0-1ubuntu6.4_amd64.deb"
    "jq_1.7.1-3ubuntu0.24.04.2_amd64.deb"
    "qrencode_4.1.1-1build2_amd64.deb"
    "socat_1.8.0.0-4ubuntu0.1_amd64.deb"
    "wget_1.21.4-1ubuntu4.1_amd64.deb"
)

mkdir -p "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$LOCAL_DIR/tools" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [[ ! -x "$MTUNNEL_PATH" ]]; then
    cp "$0" "$MTUNNEL_PATH" 2>/dev/null
    chmod +x "$MTUNNEL_PATH" 2>/dev/null
fi

MAIN_PID=$$
NEED_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1

UPDATE_CHECK_INTERVAL=30

# --- PARALLEL BACKGROUND CHECKER (WORKER) ---
check_single_module_silent() {
    local mod="$1"
    local rel_path="$2"
    local out_file="$SECURE_TMP/.chk_${mod}"
    rm -f "$out_file"

    local local_file="$LOCAL_DIR/$rel_path"
    [ ! -f "$local_file" ] && [ -f "/usr/bin/$mod" ] && local_file="/usr/bin/$mod"

    local cur_v=""
    [ -f "$local_file" ] && cur_v=$(grep -m1 '^MODULE_VERSION=' "$local_file" | cut -d'"' -f2)
    [ -z "$cur_v" ] && cur_v="0.0.0"

    local cb="?t=$(date +%s%N)"
    local rem_v=""
    if command -v curl >/dev/null 2>&1; then
        rem_v=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 2 --max-time 4 "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        rem_v=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=4 "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi

    if [ -n "$rem_v" ] && [ "$rem_v" != "$cur_v" ]; then
        echo "${mod}:${cur_v}:${rem_v}" > "$out_file"
    fi
}

check_all_updates_round() {
    local pids=()
    for mod in "${!MOD_MAP[@]}"; do
        check_single_module_silent "$mod" "${MOD_MAP[$mod]}" &
        pids+=("$!")
    done
    for p in "${pids[@]}"; do
        wait "$p" 2>/dev/null
    done

    : > "$UPDATE_FILE.new"
    for mod in "${!MOD_MAP[@]}"; do
        f="$SECURE_TMP/.chk_${mod}"
        [ -s "$f" ] && cat "$f" >> "$UPDATE_FILE.new"
        rm -f "$f"
    done
    mv -f "$UPDATE_FILE.new" "$UPDATE_FILE" 2>/dev/null

    kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
}

update_watcher_loop() {
    while true; do
        check_all_updates_round
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
update_watcher_loop &
WATCHER_PID=$!
trap 'kill "$WATCHER_PID" 2>/dev/null' EXIT
# -------------------------------------------

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

read_with_refresh() {
    local prompt="$1"
    local __resultvar="$2"
    local redraw_func="$3"
    local buffer=""
    local char rc

    echo -ne "$prompt"

    while true; do
        if [ "$NEED_REFRESH" = true ]; then
            NEED_REFRESH=false
            if [ -n "$redraw_func" ]; then
                "$redraw_func"
            fi
            echo -ne "$prompt$buffer"
        fi

        IFS= read -rsn1 -t 0.3 char
        rc=$?

        if [ $rc -ne 0 ]; then
            continue
        fi

        if [[ -z "$char" ]]; then
            echo ""
            break
        fi

        if [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
            if [ -n "$buffer" ]; then
                buffer="${buffer%?}"
                echo -ne "\b \b"
            fi
            continue
        fi

        buffer+="$char"
        echo -ne "$char"
    done

    eval "$__resultvar=\"\$buffer\""
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

    if [ "$mod" = "main" ]; then
        if ! same_file "$target_file" "$MTUNNEL_PATH"; then
            install -m 0755 "$target_file" "$MTUNNEL_PATH" 2>/dev/null || return 1
        fi
        ln -sf "$MTUNNEL_PATH" /usr/bin/main 2>/dev/null
    else
        if ! same_file "$target_file" "/usr/bin/$mod"; then
            install -m 0755 "$target_file" "/usr/bin/$mod" || return 1
        else
            chmod 0755 "/usr/bin/$mod" 2>/dev/null || true
        fi
    fi
}

deploy_binaries_from_dir() {
    local src_dir="$1"
    [ ! -d "$src_dir" ] && return 1

    mkdir -p /usr/local/bin /usr/sbin /etc/haproxy /var/lib/haproxy "$LOCAL_DIR/packages" 2>/dev/null

    # HAProxy
    if [ -f "$src_dir/haproxy" ]; then
        install -m 0755 "$src_dir/haproxy" /usr/sbin/haproxy 2>/dev/null
        ln -sf /usr/sbin/haproxy /usr/local/bin/haproxy 2>/dev/null
        [ "$src_dir" != "$LOCAL_DIR/packages" ] && cp -f "$src_dir/haproxy" "$LOCAL_DIR/packages/" 2>/dev/null
    fi

    # Rathole, Paqet, Gost, FRPC, FRPS
    for b in rathole paqet gost frpc frps; do
        if [ -f "$src_dir/$b" ]; then
            install -m 0755 "$src_dir/$b" "/usr/local/bin/$b" 2>/dev/null
            [ "$src_dir" != "$LOCAL_DIR/packages" ] && cp -f "$src_dir/$b" "$LOCAL_DIR/packages/" 2>/dev/null
        fi
    done

    # Backhaul / bh
    if [ -f "$src_dir/bh" ]; then
        install -m 0755 "$src_dir/bh" /usr/local/bin/bh 2>/dev/null
        ln -sf /usr/local/bin/bh /usr/local/bin/backhaul 2>/dev/null
        [ "$src_dir" != "$LOCAL_DIR/packages" ] && cp -f "$src_dir/bh" "$LOCAL_DIR/packages/" 2>/dev/null
    elif [ -f "$src_dir/backhaul" ]; then
        install -m 0755 "$src_dir/backhaul" /usr/local/bin/backhaul 2>/dev/null
        ln -sf /usr/local/bin/backhaul /usr/local/bin/bh 2>/dev/null
        [ "$src_dir" != "$LOCAL_DIR/packages" ] && cp -f "$src_dir/backhaul" "$LOCAL_DIR/packages/" 2>/dev/null
    fi

    # استقرار پکیج‌های DEB
    if compgen -G "$src_dir/*.deb" > /dev/null; then
        dpkg -i --force-confdef --force-confold "$src_dir"/*.deb >/dev/null 2>&1 || true
        [ "$src_dir" != "$LOCAL_DIR/packages" ] && cp -f "$src_dir"/*.deb "$LOCAL_DIR/packages/" 2>/dev/null
    fi
    return 0
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
    render_ota_menu() {
        clear; echo ""
        echo -e "  ${B}╭──────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC} ${W}MDesign Ecosystem Central Updater${NC}                           ${B}│${NC}"
        echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"

        echo -e "\n  ${DIM}┌─[ SCRIPT CORE ENGINE UPDATES ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Sync All Scripts from Official GitHub${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Sync All Scripts from Iranian Mirror (ParsPack)${NC}"

        main_sub_badge=""
        if [ -f "$UPDATE_FILE" ]; then
            m_line=$(grep "^main:" "$UPDATE_FILE")
            if [ -n "$m_line" ]; then
                o_v=$(echo "$m_line" | cut -d: -f2)
                n_v=$(echo "$m_line" | cut -d: -f3)
                main_sub_badge="  ${Y}(v${o_v} ➔ v${n_v})${NC}"
            fi
        fi
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Update Master Core Dashboard (Main Script Only)${NC}${main_sub_badge}"

        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─[ BINARY PACKAGES & PREREQUISITES ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Fetch All Prerequisites & Packages from Official GitHub${NC}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${G}Fetch All Prerequisites & Packages from Iranian Mirror${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─[ MANUAL & OVERRIDE METHODS ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${Y}Custom Personal Link (.sh Script or ZIP)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${M}Manual Code Paste (Raw Editor)${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Dashboard${NC}\n"
    }

    while true; do
        render_ota_menu
        read_with_refresh "  ${C}OTA-HUB ❯❯ ${NC}" ota_opt render_ota_menu
        ota_opt=$(echo "$ota_opt" | tr -d '\r ')

        case $ota_opt in
            1|2)
                clear
                s_url="$REPO_SCRIPTS"
                sync_name="OFFICIAL GITHUB"
                if [ "$ota_opt" == "2" ]; then
                    s_url="$MIRROR_SCRIPTS"
                    sync_name="IRANIAN MIRROR (PARSPACK)"
                fi

                echo -e "\n  ${DIM}┌─[ SYNCING ALL SCRIPTS FROM ${sync_name} ]${NC}"

                total_mods=${#ALL_MODULES[@]}
                current=0
                width=30

                for mod in "${ALL_MODULES[@]}"; do
                    ((current++))
                    rel_p="${MOD_MAP[$mod]}"
                    
                    percent=$(( current * 100 / total_mods ))
                    filled=$(( percent * width / 100 ))
                    empty=$(( width - filled ))
                    
                    bar_f=$(printf "%${filled}s" "" | tr ' ' '#')
                    bar_e=$(printf "%${empty}s" "" | tr ' ' '-')

                    if download_file_to_cache "$mod" "$s_url"; then
                        deploy_cached_module "$mod"
                        n_v=$(grep -m1 '^MODULE_VERSION=' "$LOCAL_DIR/$rel_p" 2>/dev/null | cut -d'"' -f2)
                        n_v="${n_v:-Unknown}"
                        
                        ver_str=" (v${n_v})"
                        plain_len=$(( ${#mod} + ${#ver_str} ))
                        pad_len=$(( 26 - plain_len ))
                        [ "$pad_len" -lt 0 ] && pad_len=0
                        padding=$(printf '%*s' "$pad_len" "")

                        printf "  ${G}✔${NC} ${W}%s${NC}${Y}%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$mod" "$ver_str" "$padding" "$bar_f" "$bar_e" "$percent"
                    else
                        ver_str=" (FAILED)"
                        plain_len=$(( ${#mod} + ${#ver_str} ))
                        pad_len=$(( 26 - plain_len ))
                        [ "$pad_len" -lt 0 ] && pad_len=0
                        padding=$(printf '%*s' "$pad_len" "")

                        printf "  ${R}✖${NC} ${R}%s%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$mod" "$ver_str" "$padding" "$bar_f" "$bar_e" "$percent"
                    fi
                done
                
                > "$UPDATE_FILE"
                echo -e "\n  ${G}● Script sync finished. Press Enter to reload core...${NC}"
                read dummy
                kill "$WATCHER_PID" 2>/dev/null
                exec "$MTUNNEL_PATH"
                ;;

            3)
                clear
                echo -e "\n  ${DIM}┌─[ UPDATING MASTER CORE (MAIN.SH) ]${NC}"
                width=30
                bar_full=$(printf "%${width}s" "" | tr ' ' '#')

                if download_file_to_cache "main" "$REPO_SCRIPTS"; then
                    deploy_cached_module "main"
                    m_new_v=$(grep -m1 '^MODULE_VERSION=' "$LOCAL_DIR/main.sh" 2>/dev/null | cut -d'"' -f2)
                    m_new_v="${m_new_v:-Unknown}"
                    
                    ver_str=" (v${m_new_v})"
                    plain_len=$(( 4 + ${#ver_str} ))
                    pad_len=$(( 26 - plain_len ))
                    [ "$pad_len" -lt 0 ] && pad_len=0
                    padding=$(printf '%*s' "$pad_len" "")

                    printf "  ${G}✔${NC} ${W}main${NC}${Y}%s${NC}%s ${W}[%s] 100%%${NC}\n" "$ver_str" "$padding" "$bar_full"
                    echo -e "\n  ${G}● Master Core successfully updated! Reloading...${NC}"
                    sleep 1.5
                    kill "$WATCHER_PID" 2>/dev/null
                    exec "$MTUNNEL_PATH"
                else
                    ver_str=" (FAILED)"
                    plain_len=$(( 4 + ${#ver_str} ))
                    pad_len=$(( 26 - plain_len ))
                    [ "$pad_len" -lt 0 ] && pad_len=0
                    padding=$(printf '%*s' "$pad_len" "")
                    bar_empty=$(printf "%${width}s" "" | tr ' ' '-')

                    printf "  ${R}✖${NC} ${R}main%s${NC}%s ${W}[${DIM}%s${W}]   0%%${NC}\n" "$ver_str" "$padding" "$bar_empty"
                    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
                fi
                ;;

            4|5)
                clear
                target_name="OFFICIAL GITHUB"
                pkg_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/packages"
                if [ "$ota_opt" == "5" ]; then
                    target_name="PARSPACK IRANIAN MIRROR"
                    pkg_url="$MIRROR_PACKAGES"
                fi

                echo -e "\n  ${DIM}┌─[ FETCHING PREREQUISITES & PACKAGES FROM ${target_name} ]${NC}"
                mkdir -p "$LOCAL_DIR/packages" /usr/local/bin /usr/sbin 2>/dev/null
                CB="?t=$(date +%s)"
                
                total_pkgs=${#ALL_PACKAGES[@]}
                current=0
                width=30

                for item in "${ALL_PACKAGES[@]}"; do
                    ((current++))
                    t_out="$LOCAL_DIR/packages/$item"
                    dl_ok=false
                    
                    percent=$(( current * 100 / total_pkgs ))
                    filled=$(( percent * width / 100 ))
                    empty=$(( width - filled ))
                    
                    bar_f=$(printf "%${filled}s" "" | tr ' ' '#')
                    bar_e=$(printf "%${empty}s" "" | tr ' ' '-')

                    if command -v curl >/dev/null 2>&1; then
                        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 -o "$t_out" "$pkg_url/$item$CB" 2>/dev/null && dl_ok=true
                    elif command -v wget >/dev/null 2>&1; then
                        wget -q --no-check-certificate --header="Cache-Control: no-cache" --timeout=8 -O "$t_out" "$pkg_url/$item$CB" 2>/dev/null && dl_ok=true
                    fi

                    # نمایش نام خلاصه شده در صورت طولانی بودن فایل‌های deb
                    display_name="$item"
                    if [[ "$item" == *.deb ]]; then
                        display_name=$(echo "$item" | cut -d'_' -f1)".deb"
                    fi

                    pad_len=$(( 26 - ${#display_name} ))
                    [ "$pad_len" -lt 0 ] && pad_len=0
                    padding=$(printf '%*s' "$pad_len" "")

                    if [ "$dl_ok" = true ] && [ -s "$t_out" ]; then
                        if [[ "$item" == *.deb ]]; then
                            dpkg -i --force-confdef --force-confold "$t_out" >/dev/null 2>&1 || true
                        else
                            chmod +x "$t_out"
                            if [ "$item" == "haproxy" ]; then
                                install -m 0755 "$t_out" /usr/sbin/haproxy 2>/dev/null
                                ln -sf /usr/sbin/haproxy /usr/local/bin/haproxy 2>/dev/null
                            elif [ "$item" == "bh" ]; then
                                install -m 0755 "$t_out" /usr/local/bin/bh 2>/dev/null
                                ln -sf /usr/local/bin/bh /usr/local/bin/backhaul 2>/dev/null
                            else
                                install -m 0755 "$t_out" "/usr/local/bin/$item" 2>/dev/null
                            fi
                        fi

                        printf "  ${G}✔${NC} ${W}%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$display_name" "$padding" "$bar_f" "$bar_e" "$percent"
                    else
                        printf "  ${R}✖${NC} ${R}%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$display_name" "$padding" "$bar_f" "$bar_e" "$percent"
                    fi
                done

                echo -e "\n  ${G}● All prerequisite packages and cores deployed successfully.${NC}"
                echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
                ;;

            6)
                clear
                echo -e "\n  ${DIM}┌─[ CUSTOM DIRECT LINK DEPLOYMENT ]${NC}"
                echo -ne "  ${C}●${NC} ${W}Enter Direct (.sh or .zip) URL: ${NC}"; read custom_url
                custom_url=$(echo "$custom_url" | tr -d '\r ')
                [ -z "$custom_url" ] && continue

                tmp_dl="$SECURE_TMP/.custom_download.$$"
                rm -f "$tmp_dl"

                (
                    if command -v curl >/dev/null 2>&1; then
                        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 10 -o "$tmp_dl" "$custom_url" 2>/dev/null
                    elif command -v wget >/dev/null 2>&1; then
                        wget -q --no-check-certificate --header="Cache-Control: no-cache" --timeout=10 -O "$tmp_dl" "$custom_url" 2>/dev/null
                    fi
                ) &
                pid=$!
                draw_progress_bar "$pid" "Downloading Custom Resource"
                wait "$pid" 2>/dev/null

                if [ -s "$tmp_dl" ]; then
                    if ! command -v unzip >/dev/null 2>&1; then
                        DEBIAN_FRONTEND=noninteractive apt-get update -y -q >/dev/null 2>&1
                        DEBIAN_FRONTEND=noninteractive apt-get install -y -q unzip >/dev/null 2>&1
                    fi

                    if command -v unzip >/dev/null 2>&1 && unzip -t "$tmp_dl" >/dev/null 2>&1; then
                        t_dir="$(mktemp -d /tmp/custom-unzip.XXXXXX)"
                        unzip -q -o "$tmp_dl" -d "$t_dir" 2>/dev/null
                        
                        r_root="$(find "$t_dir" -type f -name "main.sh" -exec dirname {} \; | head -n 1)"
                        
                        if [ -n "$r_root" ] && [ -d "$r_root" ]; then
                            cp -rf "$r_root"/* "$LOCAL_DIR/" 2>/dev/null
                            for m in "${ALL_MODULES[@]}"; do deploy_cached_module "$m" 2>/dev/null; done
                            
                            if [ -d "$r_root/packages" ]; then
                                deploy_binaries_from_dir "$r_root/packages"
                            elif [ -d "$t_dir/packages" ]; then
                                deploy_binaries_from_dir "$t_dir/packages"
                            elif [ -d "$LOCAL_DIR/packages" ]; then
                                deploy_binaries_from_dir "$LOCAL_DIR/packages"
                            fi

                            echo -e "  ${G}✔ Archive fully extracted, modules and binary cores deployed!${NC}"
                            sleep 1.5
                            kill "$WATCHER_PID" 2>/dev/null
                            exec "$MTUNNEL_PATH"
                        else
                            # فال‌بک هوشمند: در صورتی که main.sh در زیپ نبود
                            echo -e "  ${Y}● No main.sh found in archive. Scanning for packages, scripts and binaries...${NC}"
                            
                            deployed_anything=false

                            # 1. جستجوی پوشه packages یا هر پوشه‌ای که باینری/deb دارد
                            while IFS= read -r dir_cand; do
                                if deploy_binaries_from_dir "$dir_cand"; then
                                    deployed_anything=true
                                fi
                            done < <(find "$t_dir" -type d)

                            # 2. کپی هر اسکریپت شلی که احتمالاً در زیپ وجود دارد به دایرکتوری اصلی
                            while IFS= read -r sh_cand; do
                                bname=$(basename "$sh_cand" .sh)
                                cp -f "$sh_cand" "$LOCAL_DIR/${bname}.sh" 2>/dev/null
                                chmod +x "$LOCAL_DIR/${bname}.sh" 2>/dev/null
                                deploy_cached_module "$bname" 2>/dev/null || true
                                deployed_anything=true
                            done < <(find "$t_dir" -type f -name "*.sh")

                            if [ "$deployed_anything" = true ]; then
                                echo -e "  ${G}✔ Fallback success: All packages, .deb files, and scripts from archive deployed successfully!${NC}"
                            else
                                echo -e "  ${R}✖ Error: No valid scripts, binaries, or debian packages found inside the ZIP!${NC}"
                            fi
                        fi
                        rm -rf "$t_dir"
                    elif grep -q "#!/bin/bash" "$tmp_dl"; then
                        echo -e "\n  ${DIM}Select Module Target to overwrite:${NC}"
                        i=1
                        for m in "${ALL_MODULES[@]}"; do
                            printf "  ${DIM}%2d)${NC} %-12s " "$i" "$m"
                            ((i % 3 == 0)) && echo ""
                            ((i++))
                        done
                        echo -ne "\n  ${C}Enter number: ${NC}"; read m_num
                        chosen_mod="${ALL_MODULES[$((m_num - 1))]}"
                        if [ -n "$chosen_mod" ]; then
                            dest="$LOCAL_DIR/${MOD_MAP[$chosen_mod]}"
                            mkdir -p "$(dirname "$dest")" 2>/dev/null
                            cat "$tmp_dl" > "$dest"
                            deploy_cached_module "$chosen_mod"
                            echo -e "  ${G}✔ Successfully applied to ${chosen_mod}!${NC}"
                            if [ "$chosen_mod" = "main" ]; then
                                sleep 1.5
                                kill "$WATCHER_PID" 2>/dev/null
                                exec "$MTUNNEL_PATH"
                            fi
                        fi
                    else
                        echo -e "  ${R}✖ Downloaded file is neither a valid ZIP nor a bash script!${NC}"
                    fi
                else
                    echo -e "  ${R}✖ Download failed! Check URL.${NC}"
                fi
                rm -f "$tmp_dl"; sleep 2
                ;;

            7)
                clear
                echo -e "\n  ${DIM}┌─[ MANUAL RAW CODE PASTE (EDITOR) ]${NC}"
                echo -e "  ${DIM}Select target module to edit:${NC}"
                i=1
                for m in "${ALL_MODULES[@]}"; do
                    printf "  ${DIM}%2d)${NC} %-12s " "$i" "$m"
                    ((i % 3 == 0)) && echo ""
                    ((i++))
                done
                echo -ne "\n  ${C}Enter number: ${NC}"; read m_num
                chosen_mod="${ALL_MODULES[$((m_num - 1))]}"
                if [ -n "$chosen_mod" ]; then
                    dest="$LOCAL_DIR/${MOD_MAP[$chosen_mod]}"
                    mkdir -p "$(dirname "$dest")" 2>/dev/null

                    temp_paste_file="$SECURE_TMP/.manual_paste.$$"
                    > "$temp_paste_file"

                    if command -v nano >/dev/null 2>&1; then
                        echo -e "  ${DIM}● Opening clean editor... Paste your raw code, save (Ctrl+O, Enter) and exit (Ctrl+X).${NC}"
                        sleep 1.5
                        nano "$temp_paste_file"
                    elif command -v vi >/dev/null 2>&1; then
                        vi "$temp_paste_file"
                    fi

                    if [ -s "$temp_paste_file" ] && grep -q "#!/bin/bash" "$temp_paste_file"; then
                        new_ver=$(grep -m1 '^MODULE_VERSION=' "$temp_paste_file" | cut -d'"' -f2)
                        [ -z "$new_ver" ] && new_ver="Unknown"

                        current_v="Unknown"
                        [ -f "$dest" ] && current_v=$(grep -m1 '^MODULE_VERSION=' "$dest" 2>/dev/null | cut -d'"' -f2)
                        [ -z "$current_v" ] && current_v="Unknown"

                        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
                        echo -e "  ${DIM}├─${NC} ${W}Target Module   :${NC} ${C}${chosen_mod}${NC}"
                        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${current_v}${NC}"
                        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
                        echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read confirm

                        if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
                            sed -i 's/\r$//' "$temp_paste_file" 2>/dev/null
                            chmod +x "$temp_paste_file"
                            cat "$temp_paste_file" > "$dest"
                            rm -f "$temp_paste_file"

                            deploy_cached_module "$chosen_mod"
                            echo -e "  ${G}✔ Module ${chosen_mod} (v${new_ver}) successfully applied! Rebooting core...${NC}"
                            sleep 1.5
                            kill "$WATCHER_PID" 2>/dev/null
                            exec "$MTUNNEL_PATH"
                        else
                            echo -e "  ${Y}● Manual update cancelled by user.${NC}"
                            rm -f "$temp_paste_file"
                        fi
                    else
                        echo -e "  ${R}✖ Invalid format (Missing #!/bin/bash) or empty paste!${NC}"
                        rm -f "$temp_paste_file"
                    fi
                    sleep 2
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
        pid=$!
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

    render_iperf_menu() {
        clear; echo ""
        s_ip=$(get_local_ip)
        str1=" iPerf3 Network Bandwidth Benchmark "
        raw_len=$(( ${#str1} ))
        pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
        padding=$(printf '%*s' "$pad_len" "")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Port:${NC} ${C}5201 TCP/UDP${NC} ${padding}${B}│${NC}"
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"

        echo -e "\n  ${DIM}┌─[ BENCHMARK MODE ]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run as Server (Listener Mode)${NC} ${DIM}(Wait for peer connections)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run as Client (Sender Mode)${NC}   ${DIM}(Push bandwidth stream to server)${NC}"
        echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    }

    while true; do
        render_iperf_menu
        read_with_refresh "  ${C}iPerf3 ❯❯ ${NC}" i_opt render_iperf_menu
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
    s_ip=$(get_local_ip)
    st_gre="○"; c_gre="${DIM}"; [ -n "$(ls -A /etc/mgre/tunnels/*.conf 2>/dev/null)" ] && { st_gre="●"; c_gre="${G}"; }
    st_vx="○"; c_vx="${DIM}"; [ -n "$(ls -A /etc/mgre/vxlan/*.conf 2>/dev/null)" ] && { st_vx="●"; c_vx="${G}"; }
    st_rh="○"; c_rh="${DIM}"; [ -n "$(ls -A /etc/mrathole/tunnels/*.toml 2>/dev/null)" ] && { st_rh="●"; c_rh="${G}"; }
    st_bh="○"; c_bh="${DIM}"; [ -n "$(ls -A /etc/mbackhaul/tunnels/*.meta 2>/dev/null)" ] && { st_bh="●"; c_bh="${G}"; }
    st_pq="○"; c_pq="${DIM}"; [ -n "$(ls -A /etc/paqet/*.yaml 2>/dev/null)" ] && { st_pq="●"; c_pq="${G}"; }

    bbr_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    bbr_stat="${DIM}○ OFF${NC}"
    raw_bbr="○ OFF"
    if [ "$bbr_cc" == "bbr" ]; then bbr_stat="${G}● ON${NC}"; raw_bbr="● ON"; fi

    web_stat="${DIM}○ OFFLINE${NC}"
    raw_web="○ OFFLINE"
    if systemctl is-active --quiet mweb.service 2>/dev/null; then
        w_port="1000"
        [ -f "/etc/mweb/web.conf" ] && w_port=$(grep "WEB_PORT" /etc/mweb/web.conf | cut -d= -f2 | tr -d ' ' | tr -d '\r')
        web_stat="${G}● PORT ${w_port}${NC}"
        raw_web="● PORT ${w_port}"
    fi

    raw_top=" MDesign Master Core v${MODULE_VERSION} │ IP: ${s_ip} │ Web: ${raw_web} │ BBR: ${raw_bbr} "
    pad_top=$(( 94 - ${#raw_top} )); [ "$pad_top" -lt 0 ] && pad_top=0
    padding_top=$(printf '%*s' "$pad_top" "")

    raw_bot=" Hub: GRE:${st_gre}  VXLAN:${st_vx}  RatHole:${st_rh}  Backhaul:${st_bh}  Paqet:${st_pq} "
    pad_bot=$(( 94 - ${#raw_bot} )); [ "$pad_bot" -lt 0 ] && pad_bot=0
    padding_bot=$(printf '%*s' "$pad_bot" "")

    clear; echo ""
    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MDesign Master Core v${MODULE_VERSION}${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC} ${B}│${NC} ${DIM}Web:${NC} ${web_stat} ${B}│${NC} ${DIM}BBR:${NC} ${bbr_stat}${padding_top}${B}│${NC}"
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}${DIM} Hub: GRE:${NC}${c_gre}${st_gre}${NC}${DIM}  VXLAN:${NC}${c_vx}${st_vx}${NC}${DIM}  RatHole:${NC}${c_rh}${st_rh}${NC}${DIM}  Backhaul:${NC}${c_bh}${st_bh}${NC}${DIM}  Paqet:${NC}${c_pq}${st_pq}${NC}${padding_bot}${B}│${NC}"
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_tunnel_hub() {
    render_tunnel_menu() {
        badge_mgre="" badge_mxlan="" badge_mrathole="" badge_mbackhaul="" badge_mpaqet=""
        if [ -f "$UPDATE_FILE" ]; then
            grep -q "^mgre:" "$UPDATE_FILE" && badge_mgre=" ${Y}(Update Available: v$(grep "^mgre:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
            grep -q "^mxlan:" "$UPDATE_FILE" && badge_mxlan=" ${Y}(Update Available: v$(grep "^mxlan:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
            grep -q "^mrathole:" "$UPDATE_FILE" && badge_mrathole=" ${Y}(Update Available: v$(grep "^mrathole:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
            grep -q "^mbackhaul:" "$UPDATE_FILE" && badge_mbackhaul=" ${Y}(Update Available: v$(grep "^mbackhaul:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
            grep -q "^mpaqet:" "$UPDATE_FILE" && badge_mpaqet=" ${Y}(Update Available: v$(grep "^mpaqet:" "$UPDATE_FILE" | cut -d: -f3))${NC}"
        fi

        draw_main_header
        echo -e "\n  ${DIM}┌─[ PRIMARY INFRASTRUCTURE HUB ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Modular GRE/IP6GRE Core (Mgre)${NC}${badge_mgre}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}VXLAN Virtual Mesh Fabric (Mxlan)${NC}${badge_mxlan}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Rathole Reverse Tunnel (Mrathole)${NC}${badge_mrathole}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Backhaul Free Multiplexer (MBackhaul)${NC}${badge_mbackhaul}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Paqet Raw Packet KCP Tunnel (MPaqet)${NC}${badge_mpaqet}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Dashboard${NC}\n"
    }

    while true; do
        render_tunnel_menu
        read_with_refresh "  ${C}TUNNEL ❯❯ ${NC}" t_opt render_tunnel_menu
        t_opt=$(echo "$t_opt" | tr -d '\r ')
        case $t_opt in
            1) run_mod "mgre" ;; 2) run_mod "mxlan" ;; 3) run_mod "mrathole" ;; 4) run_mod "mbackhaul" ;; 5) run_mod "mpaqet" ;; 0) break ;;
        esac
    done
}

render_main_menu() {
    badge_hub="" badge_porter="" badge_main="" badge_bbr="" badge_diag="" badge_shield="" badge_link="" badge_stats="" badge_healer="" badge_iface=""

    if [ -f "$UPDATE_FILE" ]; then
        tun_updates=""
        grep -q "^mgre:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(MGRE)${NC}"
        grep -q "^mxlan:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(MXLAN)${NC}"
        grep -q "^mrathole:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(Rathole)${NC}"
        grep -q "^mbackhaul:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(Backhaul)${NC}"
        grep -q "^mpaqet:" "$UPDATE_FILE" && tun_updates="${tun_updates} ${Y}(Paqet)${NC}"

        if [ -n "$tun_updates" ]; then
            badge_hub=" ${Y}(Update Available)${NC}${tun_updates}"
        fi

        if grep -q "^mporter:" "$UPDATE_FILE"; then
            p_ver=$(grep "^mporter:" "$UPDATE_FILE" | cut -d: -f3)
            badge_porter=" ${Y}(Update Available: v${p_ver})${NC}"
        fi
        if grep -q "^main:" "$UPDATE_FILE"; then
            m_ver=$(grep "^main:" "$UPDATE_FILE" | cut -d: -f3)
            badge_main=" ${Y}(Update Available: v${m_ver})${NC}"
        fi
        if grep -q "^mbbr:" "$UPDATE_FILE"; then
            b_ver=$(grep "^mbbr:" "$UPDATE_FILE" | cut -d: -f3)
            badge_bbr=" ${Y}(Update Available: v${b_ver})${NC}"
        fi
        if grep -q "^mdiag:" "$UPDATE_FILE"; then
            d_ver=$(grep "^mdiag:" "$UPDATE_FILE" | cut -d: -f3)
            badge_diag=" ${Y}(Update Available: v${d_ver})${NC}"
        fi
        if grep -q "^mshield:" "$UPDATE_FILE"; then
            s_ver=$(grep "^mshield:" "$UPDATE_FILE" | cut -d: -f3)
            badge_shield=" ${Y}(Update Available: v${s_ver})${NC}"
        fi
        if grep -q "^linktest:" "$UPDATE_FILE"; then
            l_ver=$(grep "^linktest:" "$UPDATE_FILE" | cut -d: -f3)
            badge_link=" ${Y}(Update Available: v${l_ver})${NC}"
        fi
        if grep -q "^mstats:" "$UPDATE_FILE"; then
            st_ver=$(grep "^mstats:" "$UPDATE_FILE" | cut -d: -f3)
            badge_stats=" ${Y}(Update Available: v${st_ver})${NC}"
        fi
        if grep -q "^mhealer:" "$UPDATE_FILE"; then
            h_ver=$(grep "^mhealer:" "$UPDATE_FILE" | cut -d: -f3)
            badge_healer=" ${Y}(Update Available: v${h_ver})${NC}"
        fi
        if grep -q "^minterface:" "$UPDATE_FILE"; then
            if_ver=$(grep "^minterface:" "$UPDATE_FILE" | cut -d: -f3)
            badge_iface=" ${Y}(Update Available: v${if_ver})${NC}"
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
    echo -e "  ${DIM}├─${NC} ${W}10${NC} ${DIM}❯${NC} ${G}TCP BBR Accelerator (Mbbr)${NC}${badge_bbr}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC} ${DIM}❯${NC} ${G}Unified Multi-Tier OTA Update Hub${NC}${badge_main}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC} ${DIM}❯${NC} ${M}Offline Local Deploy (Packages & Modules)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC} ${DIM}❯${NC} ${R}Nuclear Wipe (Uninstall)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}\n"
}

while true; do
    render_main_menu
    read_with_refresh "  ${C}CORE ❯❯ ${NC}" opt render_main_menu
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
                current_exec_dir="$(pwd)"
                script_dir="$(dirname "$(readlink -f "$0" 2>/dev/null)")"

                # همگام‌سازی از دایرکتوری جاری در صورتی که خارج از /root/mtunnel اجرا شده باشد
                for src_cand in "$current_exec_dir" "$script_dir"; do
                    if [ "$src_cand" != "$LOCAL_DIR" ] && [ -f "$src_cand/main.sh" ]; then
                        cp -rf "$src_cand"/* "$LOCAL_DIR/" 2>/dev/null
                        break
                    fi
                done

                # استقرار ماژول‌های متنی با پشتیبانی از fallback مسیر جاری
                for mod in "${ALL_MODULES[@]}"; do
                    rel_path="${MOD_MAP[$mod]}"
                    if [ ! -s "$LOCAL_DIR/$rel_path" ]; then
                        if [ -s "$current_exec_dir/$rel_path" ]; then
                            mkdir -p "$(dirname "$LOCAL_DIR/$rel_path")" 2>/dev/null
                            cp -f "$current_exec_dir/$rel_path" "$LOCAL_DIR/$rel_path" 2>/dev/null
                        elif [ -s "$script_dir/$rel_path" ]; then
                            mkdir -p "$(dirname "$LOCAL_DIR/$rel_path")" 2>/dev/null
                            cp -f "$script_dir/$rel_path" "$LOCAL_DIR/$rel_path" 2>/dev/null
                        fi
                    fi
                    if [ -s "$LOCAL_DIR/$rel_path" ]; then
                        deploy_cached_module "$mod" >/dev/null 2>&1
                    fi
                done

                # استقرار پکیج‌ها و هسته‌ها از تمام مسیرهای در دسترس
                for p_dir in "$current_exec_dir/packages" "$script_dir/packages" "$LOCAL_DIR/packages" "./packages"; do
                    if [ -d "$p_dir" ]; then
                        deploy_binaries_from_dir "$p_dir" >/dev/null 2>&1
                        break
                    fi
                done
            ) &
            pid=$!; draw_progress_bar "$pid" "Deploying Modules & Packages"; wait "$pid"
            echo -e "  ${G}● Local deployment and binary sync completed successfully.${NC}"; sleep 2 ;;

        13)
            clear
            echo -e "\n  ${R}╭────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${R}│${NC} ${W}MTunnel Nuclear Wipe (Complete Uninstaller)${NC}                  ${R}│${NC}"
            echo -e "  ${R}╰────────────────────────────────────────────────────────────╯${NC}\n"
            echo -e "  ${Y}⚠ Warning: This will stop and remove all tunnels, services,${NC}"
            echo -e "  ${Y}  binary cores (rathole, backhaul, paqet, gost), and configs!${NC}\n"
            echo -ne "  ${R}Type WIPE-MTUNNEL to continue: ${NC}"; read del_confirm
            del_confirm="${del_confirm//[$' \r\n']/}"
            if [[ "$del_confirm" == "WIPE-MTUNNEL" ]]; then
                echo -e "\n  ${C}● Terminating services and wiping files...${NC}"
                
                # توقف و غیرفعال‌سازی سرویس‌ها
                systemctl stop mgre.service mxlan.service mporter.service mporter-watchdog.service mweb.service mhealer.service mshield.service mbackhaul@* mrathole@* mpaqet@* gost@* 2>/dev/null || true
                systemctl disable mgre.service mxlan.service mporter.service mporter-watchdog.service mweb.service mhealer.service mshield.service mbackhaul@* mrathole@* mpaqet@* gost@* 2>/dev/null || true
                
                # حذف Unit فایل‌های سرویس‌ها
                rm -f /etc/systemd/system/mgre.service \
                      /etc/systemd/system/mxlan.service \
                      /etc/systemd/system/mporter.service \
                      /etc/systemd/system/mporter-watchdog.service \
                      /etc/systemd/system/mweb.service \
                      /etc/systemd/system/mhealer.service \
                      /etc/systemd/system/mshield.service \
                      /etc/systemd/system/mbackhaul@.service \
                      /etc/systemd/system/mrathole@.service \
                      /etc/systemd/system/mpaqet@.service \
                      /etc/systemd/system/gost@.service 2>/dev/null || true
                systemctl daemon-reload 2>/dev/null || true

                # حذف تمام پوشه‌های کانفیگ
                rm -rf /etc/mgre /etc/mporter /etc/mweb /etc/mshield /etc/mstats /etc/mrathole /etc/mbackhaul /etc/paqet /etc/mhealer /etc/minterface /etc/mdiag /etc/linktest /etc/mbbr /root/mtunnel /tmp/custom-unzip.* 2>/dev/null || true

                # حذف فایل‌های اجرایی اسکریپتی (شامل main و بدون mstat زائد)
                rm -f /usr/bin/mtunnel /usr/bin/main /usr/bin/mgre /usr/bin/mxlan /usr/bin/mbackhaul /usr/bin/mpaqet /usr/bin/mporter /usr/bin/minterface /usr/bin/mdiag /usr/bin/mshield /usr/bin/mstats /usr/bin/mhealer /usr/bin/mweb /usr/bin/mrathole /usr/bin/mbbr /usr/bin/linktest

                # حذف باینری‌ها و هسته‌های کامپایل‌شده
                rm -f /usr/local/bin/rathole /usr/local/bin/bh /usr/local/bin/backhaul /usr/local/bin/paqet /usr/local/bin/gost /usr/local/bin/frpc /usr/local/bin/frps /usr/local/bin/haproxy /usr/sbin/haproxy

                kill "$WATCHER_PID" 2>/dev/null
                echo -e "\n  ${G}✓ MTunnel ecosystem completely wiped from this system.${NC}\n"; exit 0
            else
                echo -e "\n  ${Y}● Wipe cancelled.${NC}"; sleep 1.5
            fi ;;

        0) 
            kill "$WATCHER_PID" 2>/dev/null
            clear; exit 0 ;;
    esac
done
