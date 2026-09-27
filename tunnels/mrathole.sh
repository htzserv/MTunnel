#!/bin/bash
# --- MDesign Modular Core (mrathole.sh) | The Ultimate Rathole Engine V3.6.0 ---
# [Features: Tri-Tunnel Dynamic Header | Zero-Lag Stats Cache | Full Deployment Wizard | Zero ANSI Leaks]

MODULE_VERSION="3.6.1"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mrathole"
CONF_DIR="/etc/mrathole/tunnels"
SERVICE_TPL="/etc/systemd/system/mrathole@.service"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mrathole" ] && rm -f "/usr/local/bin/mrathole" 2>/dev/null

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null
rm -f "$SECURE_TMP/.mrathole_in_menu" 2>/dev/null

ensure_dependencies() {
    local missing=()
    command -v crontab >/dev/null 2>&1 || missing+=("cron")
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    if [ ${#missing[@]} -gt 0 ]; then
        apt-get update -y -q >/dev/null 2>&1
        apt-get install -y -q "${missing[@]}" >/dev/null 2>&1
        systemctl enable cron >/dev/null 2>&1
        systemctl start cron >/dev/null 2>&1
    fi
}
ensure_dependencies

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

is_valid_host() {
    local host="$1"
    if [[ "$host" =~ ^([a-zA-Z0-9.-]+)$ ]] || [[ "$host" =~ ^([a-fA-F0-9:]+)$ ]]; then return 0; fi
    return 1
}

validate_forward_ports() {
    local p_list="$1"
    local check_listen="$2"
    local proto="$3"
    [ -z "$p_list" ] && return 0
    
    local ARR p flag
    IFS=',' read -ra ARR <<< "$p_list"
    for p in "${ARR[@]}"; do
        p=$(echo "$p" | tr -dc '0-9')
        [ -z "$p" ] && continue
        if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            echo -e "  ${R}Error: Port ${p} is out of valid range (1-65535)!${NC}"
            return 1
        fi
        if [ "$check_listen" == "1" ]; then
            flag="-t"
            [ "$proto" == "udp" ] && flag="-u"
            if ss "$flag" -ln 2>/dev/null | grep -qE ":${p}\s"; then
                echo -e "  ${R}Error: Port ${p} (${proto^^}) is already in use by another service!${NC}"
                return 1
            fi
        fi
    done
    return 0
}

MAIN_PID=$$
NEED_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1

UPDATE_CHECK_INTERVAL=60
PING_CHECK_INTERVAL=5

read_with_refresh() {
    local prompt="$1"
    local __resultvar="$2"
    local redraw_func="$3"
    local buffer=""
    local char rc

    touch "$SECURE_TMP/.mrathole_in_menu"
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

    rm -f "$SECURE_TMP/.mrathole_in_menu" 2>/dev/null
    eval "$__resultvar=\"\$buffer\""
}

check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tunnels/mrathole.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tunnels/mrathole.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mrathole_remote_ver"
}

update_watcher_loop() {
    while true; do
        check_update_bg
        if [ -f "$SECURE_TMP/.mrathole_in_menu" ]; then
            kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        fi
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
update_watcher_loop &
WATCHER_PID=$!

check_ping_bg() {
    local count=0
    local d t_name TYPE LINK_PORT REMOTE_IP peer_ip conn ping_res loss avg
    > "$SECURE_TMP/.mrathole_stats_cache.tmp"
    for d in "$CONF_DIR"/*; do
        [ -d "$d" ] && [ -f "$d/meta.conf" ] || continue
        TYPE=""; LINK_PORT=""; REMOTE_IP=""; source "$d/meta.conf" 2>/dev/null
        t_name=$(basename "$d")
        ((count++))
        [ "$count" -gt 3 ] && break

        peer_ip="$REMOTE_IP"
        if [ "$TYPE" == "1" ]; then
            conn=$(ss -tn src ":$LINK_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
            peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
            [ -z "$peer_ip" ] && peer_ip="0.0.0.0"
        fi

        avg="---"; loss="0"
        if [[ "$peer_ip" =~ ^[0-9.]+$ && "$peer_ip" != "0.0.0.0" ]]; then
            ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_ip" 2>/dev/null)
            loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
            [ -z "$loss" ] && loss="100"
            if echo "$ping_res" | grep -q "min/avg/max"; then
                avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
                [ -n "$avg" ] && avg="${avg}ms"
            fi
        else
            loss="---"
        fi
        echo "${t_name}|${avg}|${loss}" >> "$SECURE_TMP/.mrathole_stats_cache.tmp"
    done
    mv -f "$SECURE_TMP/.mrathole_stats_cache.tmp" "$SECURE_TMP/.mrathole_stats_cache" 2>/dev/null
}

ping_watcher_loop() {
    while true; do
        check_ping_bg
        if [ -f "$SECURE_TMP/.mrathole_in_menu" ]; then
            kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        fi
        sleep "$PING_CHECK_INTERVAL"
    done
}
ping_watcher_loop &
PING_WATCHER_PID=$!

trap 'kill "$WATCHER_PID" "$PING_WATCHER_PID" 2>/dev/null; rm -f "$SECURE_TMP/.mrathole_in_menu" 2>/dev/null' EXIT

self_update_module() {
    local rel_path="tunnels/mrathole.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mrathole_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mrathole_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (MRathole) ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ AUTOMATIC MIRRORS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${gh_text}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MANUAL OVERRIDES ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Offline Editor)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r src_opt
    
    local tmp_file="$SECURE_TMP/.mrathole_update.$$"
    > "$tmp_file"

    if [[ "$src_opt" == "4" ]]; then
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
            sleep 2; nano "$tmp_file"
        elif command -v vi >/dev/null 2>&1; then
            vi "$tmp_file"
        else
            echo -e "  ${R}✖ No text editor (nano/vi) found!${NC}"; rm -f "$tmp_file"; sleep 2; return
        fi
    elif [[ "$src_opt" =~ ^[123]$ ]]; then
        local dl_url=""
        case $src_opt in
            1) dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path$cb" ;;
            2) dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path$cb" ;;
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read -r custom_url; dl_url=$(echo "$custom_url" | tr -d '\r ') ;;
        esac
        [ -z "$dl_url" ] && rm -f "$tmp_file" && return

        echo -e "\n  ${C}⟳${NC} ${W}Downloading Update...${NC}"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp_file" "$dl_url" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 -O "$tmp_file" "$dl_url" 2>/dev/null
        fi
    else
        rm -f "$tmp_file"
        return
    fi

    if [ -s "$tmp_file" ] && grep -q "#!/bin/bash" "$tmp_file"; then
        local new_ver
        new_ver=$(grep -m1 '^MODULE_VERSION=' "$tmp_file" | cut -d'"' -f2)
        [ -z "$new_ver" ] && new_ver="Unknown"
        
        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read -r confirm
        
        if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
            sed -i 's/\r$//' "$tmp_file" 2>/dev/null
            chmod +x "$tmp_file"
            
            cat "$tmp_file" > "$INSTALL_PATH" 2>/dev/null || true
            [ -f "$0" ] && cat "$tmp_file" > "$0" 2>/dev/null || true
            cp -f "$tmp_file" "$LOCAL_DIR/$rel_path" 2>/dev/null
            
            rm -f "$tmp_file"
            echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
            sleep 1.5
            
            kill "$WATCHER_PID" "$PING_WATCHER_PID" 2>/dev/null
            rm -f "$SECURE_TMP/.mrathole_in_menu" 2>/dev/null
            exec "$INSTALL_PATH" "$@"
        else
            echo -e "  ${Y}● Update cancelled.${NC}"
            rm -f "$tmp_file"; sleep 1.5
        fi
    else
        echo -e "  ${R}✖ Update failed. Invalid format or network timeout.${NC}"
        rm -f "$tmp_file"; sleep 2
    fi
}

get_local_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

get_iface_uptime_rat() {
    local t_name="$1"
    local started
    started=$(systemctl show "mrathole@${t_name}" --property=ActiveEnterTimestampMonotonic 2>/dev/null | cut -d= -f2)
    if [ -n "$started" ] && [ "$started" -gt 0 ]; then
        local now sec d h m
        now=$(cut -d' ' -f1 /proc/uptime | tr -d '.')
        sec=$(( (now * 10000 - started) / 1000000 ))
        [ "$sec" -lt 0 ] && sec=0
        d=$(( sec / 86400 )); h=$(( (sec % 86400) / 3600 )); m=$(( (sec % 3600) / 60 ))
        if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
        elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
        else printf "%dm" "$m"; fi
        return
    fi
    echo "DOWN"
}

is_rathole_core_valid() {
    local bin_path=""
    if [ -x "/usr/local/bin/rathole" ]; then
        bin_path="/usr/local/bin/rathole"
    elif [ -x "/usr/bin/rathole" ]; then
        bin_path="/usr/bin/rathole"
    elif command -v rathole >/dev/null 2>&1; then
        bin_path=$(command -v rathole)
    else
        return 1
    fi

    [ -f "$bin_path" ] && [ -s "$bin_path" ] || return 1

    if command -v file >/dev/null 2>&1; then
        file -L "$bin_path" 2>/dev/null | grep -qiE "ELF.*executable" && return 0
        return 1
    fi

    local magic
    magic=$(head -c 4 "$bin_path" 2>/dev/null)
    [ "$magic" = $'\x7fELF' ] && return 0
    return 1
}

install_core_from_source() {
    local src_choice="$1"
    systemctl stop mrathole@* 2>/dev/null
    killall -9 rathole 2>/dev/null
    
    if [ -f "/usr/local/bin/rathole" ] || [ -f "/usr/bin/rathole" ]; then
        echo -e "  ${Y}● Purging previous Rathole installation...${NC}"
    fi
    rm -f /usr/local/bin/rathole /usr/bin/rathole "$SECURE_TMP/rh_dl.zip" "$SECURE_TMP/rathole"

    command -v unzip >/dev/null 2>&1 || {
        apt-get update -y -q >/dev/null 2>&1
        apt-get install -y -q unzip >/dev/null 2>&1 || true
    }

    if [[ "$src_choice" == "1" || "$src_choice" == "2" ]]; then
        echo -e "  ${DIM}● Downloading latest binary...${NC}"
        local arch target archive dl_url dl_ok=false
        arch=$(uname -m)
        target="x86_64-unknown-linux-gnu"
        { [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ]; } && target="aarch64-unknown-linux-gnu"
        archive="rathole-${target}.zip"
        
        dl_url="https://github.com/rapiz1/rathole/releases/download/v0.5.0/${archive}"
        [ "$src_choice" == "2" ] && dl_url="https://c107328.parspack.net/c107328/MTunnel/packages/${archive}"

        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 10 --max-time 60 -o "$SECURE_TMP/rh_dl.zip" "$dl_url" 2>/dev/null && dl_ok=true
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 -O "$SECURE_TMP/rh_dl.zip" "$dl_url" 2>/dev/null && dl_ok=true
        fi

        if [ "$dl_ok" = true ] && [ -s "$SECURE_TMP/rh_dl.zip" ]; then
            unzip -q -o "$SECURE_TMP/rh_dl.zip" -d "$SECURE_TMP/" >/dev/null 2>&1
            [ -f "$SECURE_TMP/rathole" ] && mv "$SECURE_TMP/rathole" /usr/local/bin/rathole 2>/dev/null
            chmod +x /usr/local/bin/rathole 2>/dev/null || true
            if is_rathole_core_valid; then
                echo -e "  ${G}✔ Rathole Core installed successfully.${NC}"
            else
                rm -f /usr/local/bin/rathole
                echo -e "  ${R}✖ Download did not contain a valid binary!${NC}"
            fi
        else
            echo -e "  ${R}✖ Download failed! Check connection.${NC}"
        fi

    elif [[ "$src_choice" == "3" ]]; then
        echo -ne "  ${C}● Enter Direct Link: ${NC}"; read -r custom_url
        custom_url=$(echo "$custom_url" | tr -d '\r ')
        if [ -n "$custom_url" ]; then
            echo -e "  ${DIM}● Downloading from Custom Link...${NC}"
            local dl_ok=false
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL --connect-timeout 10 --max-time 60 -o "$SECURE_TMP/rh_dl.zip" "$custom_url" 2>/dev/null && dl_ok=true
            elif command -v wget >/dev/null 2>&1; then
                wget -q --timeout=15 -O "$SECURE_TMP/rh_dl.zip" "$custom_url" 2>/dev/null && dl_ok=true
            fi

            if [ "$dl_ok" = true ] && [ -s "$SECURE_TMP/rh_dl.zip" ]; then
                if unzip -t "$SECURE_TMP/rh_dl.zip" >/dev/null 2>&1; then
                    unzip -q -o "$SECURE_TMP/rh_dl.zip" -d "$SECURE_TMP/" >/dev/null 2>&1
                    [ -f "$SECURE_TMP/rathole" ] && mv "$SECURE_TMP/rathole" /usr/local/bin/rathole 2>/dev/null
                else
                    mv "$SECURE_TMP/rh_dl.zip" /usr/local/bin/rathole
                fi
                chmod +x /usr/local/bin/rathole 2>/dev/null || true
                if is_rathole_core_valid; then
                    echo -e "  ${G}✔ Rathole Core installed from custom link.${NC}"
                else
                    rm -f /usr/local/bin/rathole
                    echo -e "  ${R}✖ Downloaded file is not a valid binary!${NC}"
                fi
            else
                echo -e "  ${R}✖ Download failed! Check the link.${NC}"
            fi
        fi

    elif [[ "$src_choice" == "4" ]]; then
        if [ -s "$LOCAL_DIR/packages/rathole" ]; then
            cp "$LOCAL_DIR/packages/rathole" /usr/local/bin/rathole
            chmod +x /usr/local/bin/rathole
            if is_rathole_core_valid; then
                echo -e "  ${G}✔ Rathole Core restored from Local Directory.${NC}"
            else
                rm -f /usr/local/bin/rathole
                echo -e "  ${R}✖ Local file is not a valid binary!${NC}"
            fi
        else
            echo -e "  ${R}✖ File not found in $LOCAL_DIR/packages/rathole!${NC}"
        fi
    fi

    [ -f "/usr/local/bin/rathole" ] && ln -sf /usr/local/bin/rathole /usr/bin/rathole 2>/dev/null
    rm -f "$SECURE_TMP/rh_dl.zip" "$SECURE_TMP/rathole" 2>/dev/null

    local d t_name
    for d in "$CONF_DIR"/*; do
        [ -d "$d" ] || continue
        t_name=$(basename "$d")
        systemctl is-enabled "mrathole@${t_name}" >/dev/null 2>&1 && systemctl restart "mrathole@${t_name}" 2>/dev/null
    done
    sleep 1.5
}

menu_install_core() {
    echo -e "\n  ${DIM}┌─[ INSTALL / UPDATE RATHOLE CORE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .zip)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/rathole)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r')

    [[ "$src_choice" =~ ^[1-4]$ ]] && install_core_from_source "$src_choice"
}

check_first_run_core() {
    if ! is_rathole_core_valid; then
        local first_prompt_flag="$CONF_DIR/.core_prompted"
        if [ ! -f "$first_prompt_flag" ]; then
            touch "$first_prompt_flag"
            clear
            echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${B}│${NC}   ${R}● Rathole Core binary is NOT installed on this machine!${NC}                  ${B}│${NC}"
            echo -e "  ${B}│${NC}   ${W}Would you like to install the Core binary now?${NC}                           ${B}│${NC}"
            echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
            echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
            echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .zip)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/rathole)${NC}"
            echo -e "  ${DIM}│${NC}"
            echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Skip for now${NC}\n"
            echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r init_opt
            init_opt=$(echo "$init_opt" | tr -d '\r')
            if [[ "$init_opt" =~ ^[1-4]$ ]]; then
                install_core_from_source "$init_opt"
            fi
        fi
    fi
}

setup_systemd() {
    local tmp_srv="$SECURE_TMP/mrathole_tpl.service"
    cat <<'EOF' > "$tmp_srv"
[Unit]
Description=MRathole Reverse Engine (%i)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/rathole /etc/mrathole/tunnels/%i/config.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    if ! cmp -s "$tmp_srv" "$SERVICE_TPL" 2>/dev/null; then
        mv -f "$tmp_srv" "$SERVICE_TPL"
        systemctl daemon-reload
    else
        rm -f "$tmp_srv"
    fi
}

generate_toml() {
    local name="$1"
    local dir="$CONF_DIR/$name"
    local meta="$dir/meta.conf"
    local toml="$dir/config.toml"
    
    local TYPE="" LINK_PORT="" REMOTE_IP="" TOKEN="" TCP_PORTS="" UDP_PORTS=""
    source "$meta" 2>/dev/null
    
    > "$toml"
    local p
    if [ "$TYPE" == "1" ]; then
        echo "[server]" >> "$toml"
        echo "bind_addr = \"0.0.0.0:${LINK_PORT}\"" >> "$toml"
        echo "default_token = \"${TOKEN}\"" >> "$toml"
        echo "heartbeat_interval = 30" >> "$toml"
        echo "" >> "$toml"
        echo "[server.transport]" >> "$toml"
        echo "type = \"tcp\"" >> "$toml"
        echo "[server.transport.tcp]" >> "$toml"
        echo "nodelay = true" >> "$toml"

        if [ -n "$TCP_PORTS" ]; then
            IFS=',' read -ra TCP_ARR <<< "$TCP_PORTS"
            for p in "${TCP_ARR[@]}"; do
                p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
                echo "" >> "$toml"
                echo "[server.services.tcp_${p}]" >> "$toml"
                echo "type = \"tcp\"" >> "$toml"
                echo "bind_addr = \"0.0.0.0:${p}\"" >> "$toml"
            done
        fi

        if [ -n "$UDP_PORTS" ]; then
            IFS=',' read -ra UDP_ARR <<< "$UDP_PORTS"
            for p in "${UDP_ARR[@]}"; do
                p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
                echo "" >> "$toml"
                echo "[server.services.udp_${p}]" >> "$toml"
                echo "type = \"udp\"" >> "$toml"
                echo "bind_addr = \"0.0.0.0:${p}\"" >> "$toml"
            done
        fi
    else
        echo "[client]" >> "$toml"
        echo "remote_addr = \"${REMOTE_IP}:${LINK_PORT}\"" >> "$toml"
        echo "default_token = \"${TOKEN}\"" >> "$toml"
        echo "heartbeat_timeout = 40" >> "$toml"
        echo "retry_interval = 1" >> "$toml"
        echo "" >> "$toml"
        echo "[client.transport]" >> "$toml"
        echo "type = \"tcp\"" >> "$toml"
        echo "[client.transport.tcp]" >> "$toml"
        echo "nodelay = true" >> "$toml"

        if [ -n "$TCP_PORTS" ]; then
            IFS=',' read -ra TCP_ARR <<< "$TCP_PORTS"
            for p in "${TCP_ARR[@]}"; do
                p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
                echo "" >> "$toml"
                echo "[client.services.tcp_${p}]" >> "$toml"
                echo "type = \"tcp\"" >> "$toml"
                echo "local_addr = \"127.0.0.1:${p}\"" >> "$toml"
            done
        fi

        if [ -n "$UDP_PORTS" ]; then
            IFS=',' read -ra UDP_ARR <<< "$UDP_PORTS"
            for p in "${UDP_ARR[@]}"; do
                p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
                echo "" >> "$toml"
                echo "[client.services.udp_${p}]" >> "$toml"
                echo "type = \"udp\"" >> "$toml"
                echo "local_addr = \"127.0.0.1:${p}\"" >> "$toml"
            done
        fi
    fi
}

get_tunnel_status() {
    local t_name="$1"
    local known_active="$2"
    local meta="$CONF_DIR/$t_name/meta.conf"
    local TYPE="" LINK_PORT=""
    source "$meta" 2>/dev/null
    
    if [ "$known_active" != "1" ] && ! systemctl is-active --quiet "mrathole@$t_name"; then echo "OFFLINE"; return; fi
    
    if [ "$TYPE" == "1" ]; then
        if ss -tn src ":$LINK_PORT" 2>/dev/null | grep -qE "^ESTAB"; then echo "CONNECTED"; else echo "WAITING"; fi
    else
        if ss -tn dst ":$LINK_PORT" 2>/dev/null | grep -qE "^ESTAB"; then echo "CONNECTED"; else echo "RECONNECTING"; fi
    fi
}

get_peer_ping() {
    local target_ip port ping_res ping_val tcp_rtt rounded_rtt start_ts end_ts t_rtt
    target_ip=$(echo "$1" | tr -d ' \n\r')
    port=$(echo "$2" | tr -d ' \n\r')
    if [ -z "$target_ip" ] || [ "$target_ip" == "0.0.0.0" ]; then echo "N/A"; return; fi
    
    ping_res=$(timeout 2 ping -c 1 -W 1 "$target_ip" 2>/dev/null)
    if echo "$ping_res" | grep -q "time="; then
        ping_val=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+' | awk '{print int($1+0.5)}')
        echo "${ping_val}ms"
        return
    fi
    
    if command -v ss >/dev/null 2>&1; then
        tcp_rtt=$(ss -nti 2>/dev/null | grep -A 1 "$target_ip" | grep -oP 'rtt:\K[0-9.]+' | head -n 1)
        if [ -n "$tcp_rtt" ]; then
            rounded_rtt=$(echo "$tcp_rtt" | awk '{print int($1+0.5)}')
            echo "${rounded_rtt}ms*"
            return
        fi
    fi

    if [ -n "$port" ] && [[ "$port" =~ ^[0-9]+$ ]]; then
        start_ts=$(date +%s%3N 2>/dev/null)
        if timeout 1 bash -c "</dev/tcp/$target_ip/$port" 2>/dev/null; then
            end_ts=$(date +%s%3N 2>/dev/null)
            if [[ "$start_ts" =~ ^[0-9]+$ ]] && [[ "$end_ts" =~ ^[0-9]+$ ]]; then
                t_rtt=$((end_ts - start_ts))
                [ "$t_rtt" -le 0 ] && t_rtt=1
                echo "${t_rtt}ms*"
                return
            fi
        fi
    fi

    echo "Timeout"
}

draw_mrathole_header() {
    local s_ip
    s_ip=$(get_local_ip)
    local active_count=0 d
    for d in "$CONF_DIR"/*; do
        [ -d "$d" ] || continue
        systemctl is-active --quiet "mrathole@$(basename "$d")" && ((active_count++))
    done

    clear; echo ""
    local border="────────────────────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${B}╭${border}╮${NC}"
    printf "  ${B}│${NC} ${W}%-22s${NC} ${B}│${NC} ${DIM}Local:${NC} ${W}%-15s${NC} ${B}│${NC} ${DIM}Active Tunnels:${NC} ${G}%-3s${NC} ${DIM}(Max 3 Shown)${NC}      ${B}│${NC}\n" \
        "MRathole Core v${MODULE_VERSION}" "$s_ip" "$active_count"
    echo -e "  ${B}├${border}┤${NC}"

    local shown=0
    local TYPE LINK_PORT REMOTE_IP TCP_PORTS UDP_PORTS t_name pure peer_ip conn cached_entry avg loss loss_disp loss_col tun_uptime stat_icon stat_col fwd_str
    for d in "$CONF_DIR"/*; do
        [ -d "$d" ] && [ -f "$d/meta.conf" ] || continue
        TYPE=""; LINK_PORT=""; REMOTE_IP=""; TCP_PORTS=""; UDP_PORTS=""; source "$d/meta.conf" 2>/dev/null
        t_name=$(basename "$d")
        ((shown++))
        [ "$shown" -gt 3 ] && break

        pure="$t_name"
        [ ${#pure} -gt 4 ] && pure="${pure:0:4}"

        peer_ip="$REMOTE_IP"
        if [ "$TYPE" == "1" ]; then
            conn=$(ss -tn src ":$LINK_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
            peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
            [ -z "$peer_ip" ] && peer_ip="0.0.0.0"
        fi

        avg="---"; loss="0"
        if [ -f "$SECURE_TMP/.mrathole_stats_cache" ]; then
            cached_entry=$(grep "^${t_name}|" "$SECURE_TMP/.mrathole_stats_cache" 2>/dev/null | head -n 1)
            if [ -n "$cached_entry" ]; then
                avg=$(echo "$cached_entry" | cut -d'|' -f2)
                loss=$(echo "$cached_entry" | cut -d'|' -f3)
            fi
        fi

        loss_col="${DIM}"; loss_disp="---"
        if [ "$loss" != "---" ] && [ -n "$loss" ]; then
            loss_disp="${loss}%"
            if [ "$loss" -eq 0 ] 2>/dev/null; then loss_col="${G}"
            elif [ "$loss" -lt 30 ] 2>/dev/null; then loss_col="${Y}"
            else loss_col="${R}"; fi
        fi

        fwd_str="OFF"
        [ -n "$TCP_PORTS" ] || [ -n "$UDP_PORTS" ] && fwd_str="ACT"
        [ "$TYPE" == "2" ] && fwd_str="CLI"

        tun_uptime=$(get_iface_uptime_rat "$t_name")
        stat_icon="●"; stat_col="${G}"
        if [ "$tun_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi

        printf "  ${B}│${NC} %b%s%b ${W}%-4s${NC} ${DIM}➔${NC} ${Y}%-15s${NC} ${DIM}vIP:%bOFF %b ${B}│${NC} ${DIM}P:${NC}${Y}%-6s${NC} ${DIM}L:${NC}%b%-4s%b ${B}│${NC} ${DIM}Up:${NC}${W}%-6s${NC} ${B}│${NC} ${DIM}FWD:${NC}%b%-4s%b ${B}│${NC}\n" \
            "$stat_col" "$stat_icon" "$NC" "$pure" "$peer_ip" "$DIM" "$NC" "$avg" "$loss_col" "$loss_disp" "$NC" "$tun_uptime" "$C" "$fwd_str" "$NC"
    done

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}%-88s${NC}  ${B}│${NC}\n" "● No active Rathole tunnels configured on this host."
    fi
    echo -e "  ${B}╰${border}╯${NC}"
}

show_tunnel_registry() {
    draw_mrathole_header
    echo -e "\n  ${Y}● Deployed Rathole Tunnels Registry:${NC}"
    local count=0 d t_name TYPE LINK_PORT REMOTE_IP TOKEN TCP_PORTS UDP_PORTS
    local role_text ping_val connected_peer conn p_ip peer_text st stat_icon stat_text stat_color
    local left_p right_p pad sp l1 r1 pad1 sp1 l2 r2 clean_r2 pad2 sp2 l3 r3 pad3 sp3 tcp_str udp_str l4 pad4 sp4 l5 pad5 sp5
    
    for d in "$CONF_DIR"/*; do
        [ ! -d "$d" ] && continue
        t_name=$(basename "$d")
        TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; TCP_PORTS=""; UDP_PORTS=""
        source "$d/meta.conf" 2>/dev/null
        
        role_text=$([ "$TYPE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        ping_val="N/A"
        connected_peer=""

        if [ "$TYPE" == "2" ] && [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "0.0.0.0" ]; then
            ping_val=$(get_peer_ping "$REMOTE_IP" "$LINK_PORT")
            connected_peer="$REMOTE_IP"
        elif [ "$TYPE" == "1" ]; then
            conn=$(ss -tn src ":$LINK_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
            if [ -n "$conn" ]; then
                p_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                ping_val=$(get_peer_ping "$p_ip" "$LINK_PORT")
                connected_peer="$p_ip"
            else
                ping_val="Waiting"
            fi
        fi

        peer_text=$([ "$TYPE" == "1" ] && echo "Listening on :${LINK_PORT}" || echo "${REMOTE_IP}:${LINK_PORT}")
        if [ "$TYPE" == "1" ] && [ -n "$connected_peer" ]; then
            peer_text="${connected_peer}:${LINK_PORT} (Active)"
        fi

        st=$(get_tunnel_status "$t_name")
        stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"
        if [ "$st" == "CONNECTED" ]; then stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}";
        elif [ "$st" == "WAITING" ]; then stat_icon="◎"; stat_text="WAITING CLIENT"; stat_color="${Y}";
        elif [ "$st" == "RECONNECTING" ]; then stat_icon="◎"; stat_text="RECONNECTING..."; stat_color="${Y}"; fi

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        left_p="▼ Tunnel: $t_name"; right_p="Role: $role_text"
        pad=$(( 90 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        l1="Link Port    : ${LINK_PORT}"; r1="Latency: ${ping_val}"
        pad1=$(( 90 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Link Port    :${NC} ${W}${LINK_PORT}${NC}${sp1}${DIM}Latency:${NC} ${Y}${ping_val}${NC} ${B}│${NC}"
        
        l2="Peer Target  : ${peer_text}"; r2="Link State: ${stat_icon} ${stat_text}"
        clean_r2=$(echo -e "$r2" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
        pad2=$(( 90 - ${#l2} - ${#clean_r2} )); [ "$pad2" -lt 0 ] && pad2=0; sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}Peer Target  :${NC} ${W}${peer_text}${NC}${sp2}${DIM}Link State:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${B}│${NC}"

        l3="Auth Token   : ${TOKEN}"; r3="Protocol: TCP (Rathole Native)"
        pad3=$(( 90 - ${#l3} - ${#r3} )); [ "$pad3" -lt 0 ] && pad3=0; sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${Y}Auth Token   :${NC} ${W}${TOKEN}${NC}${sp3}${DIM}Protocol:${NC} ${C}TCP (Rathole Native)${NC} ${B}│${NC}"

        tcp_str="${TCP_PORTS:0:70}"; [ ${#TCP_PORTS} -gt 70 ] && tcp_str="${tcp_str}..."
        udp_str="${UDP_PORTS:0:70}"; [ ${#UDP_PORTS} -gt 70 ] && udp_str="${udp_str}..."
        
        l4="TCP Mappings : ${tcp_str:-None}"
        pad4=$(( 90 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}TCP Mappings :${NC} ${Y}${tcp_str:-None}${NC}${sp4} ${B}│${NC}"
        
        l5="UDP Mappings : ${udp_str:-None}"
        pad5=$(( 90 - ${#l5} )); [ "$pad5" -lt 0 ] && pad5=0; sp5=$(printf '%*s' "$pad5" "")
        echo -e "  ${B}│${NC} ${DIM}UDP Mappings :${NC} ${C}${udp_str:-None}${NC}${sp5} ${B}│${NC}"
        
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯\n"
        ((count++))
    done
    if [ "$count" -eq 0 ]; then echo -e "  ${R}● No tunnels configured yet!${NC}\n"; fi
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r dummy
}

show_live_radar() {
    tput civis; clear
    local count d t_name TYPE LINK_PORT REMOTE_IP TOKEN TCP_PORTS UDP_PORTS
    local st st_color st_text disp_tcp disp_udp key
    while true; do
        printf "\033[H"; draw_mrathole_header
        echo -e "\n  ${DIM}┌─[ RATHOLE TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────────┬────────────────┬──────────────────────────┬────────────────────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} ${W}%-14s${NC} ${B}│${NC} ${Y}%-24s${NC} ${B}│${NC} ${DIM}%-26s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "TCP PORTS" "UDP PORTS"
        echo -e "  ${B}├──────────────────────┼────────────────┼──────────────────────────┼────────────────────────────┤${NC}"

        count=0
        for d in "$CONF_DIR"/*; do
            [ ! -d "$d" ] && continue
            t_name=$(basename "$d")
            TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; TCP_PORTS=""; UDP_PORTS=""
            source "$d/meta.conf" 2>/dev/null
            
            st=$(get_tunnel_status "$t_name")
            st_color="${R}"; st_text="OFFLINE"
            if [ "$st" == "CONNECTED" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "RECONNECTING" ]; then st_color="${Y}"; st_text="RETRYING"; fi

            disp_tcp="${TCP_PORTS:0:24}"; [ ${#TCP_PORTS} -gt 24 ] && disp_tcp="${disp_tcp:0:21}..."
            disp_udp="${UDP_PORTS:0:26}"; [ ${#UDP_PORTS} -gt 26 ] && disp_udp="${disp_udp:0:23}..."

            printf "  ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} %b%-14s%b ${B}│${NC} ${Y}%-24s${NC} ${B}│${NC} ${C}%-26s${NC} ${B}│${NC}\n" "$t_name" "$st_color" "$st_text" "$NC" "${disp_tcp:-None}" "${disp_udp:-None}"
            ((count++))
        done

        if [ "$count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-91s${NC} ${B}│${NC}\n" "  No active Rathole tunnels configured."
        fi
        echo -e "  ${B}╰──────────────────────┴────────────────┴──────────────────────────┴────────────────────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\e' ]]; then break; fi
    done
    tput cnorm
}

manage_cron() {
    local t_name="$1"
    local cron_script="$CONF_DIR/$t_name/restart.sh"
    local cr_opt interval cron_tmp
    
    echo -e "\n  ${DIM}┌─[ ANTI-FREEZE CRONJOB MANAGER ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add/Update Auto-Restart Cronjob${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Remove Auto-Restart Cronjob${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read -r cr_opt

    if [[ "$cr_opt" == "1" ]]; then
        echo -ne "  ${C}●${NC} ${W}Restart interval in hours (e.g. 2, 4, 6): ${NC}"; read -r interval
        interval=$(echo "$interval" | tr -d '\r')
        [[ ! "$interval" =~ ^[0-9]+$ ]] && echo -e "  ${R}Invalid interval!${NC}" && sleep 1.5 && return
        
        echo "#!/bin/bash" > "$cron_script"
        echo "systemctl kill -s SIGKILL mrathole@${t_name}" >> "$cron_script"
        echo "systemctl restart mrathole@${t_name}" >> "$cron_script"
        chmod +x "$cron_script"
        
        if command -v crontab >/dev/null 2>&1; then
            cron_tmp="$SECURE_TMP/crontab.$$"
            crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > "$cron_tmp"
            echo "0 */${interval} * * * $cron_script #mrathole@${t_name}" >> "$cron_tmp"
            crontab "$cron_tmp"; rm -f "$cron_tmp"
            echo -e "  ${G}✔ Cronjob added: Tunnel will restart every ${interval} hours.${NC}"; sleep 2
        else
            echo -e "  ${R}✖ Crontab utility is missing on this system.${NC}"; sleep 2
        fi
    elif [[ "$cr_opt" == "2" ]]; then
        if command -v crontab >/dev/null 2>&1; then
            cron_tmp="$SECURE_TMP/crontab.$$"
            crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > "$cron_tmp"
            crontab "$cron_tmp"; rm -f "$cron_tmp"
        fi
        rm -f "$cron_script"
        echo -e "  ${G}✔ Cronjob removed.${NC}"; sleep 1.5
    fi
}

uninstall_mrathole() {
    clear
    echo -e "\n  ${R}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${R}│${NC}   ${R}⚠ WARNING: COMPLETE PURGE & UNINSTALLATION OF MRATHOLE${NC}                  ${R}│${NC}"
    echo -e "  ${R}│${NC}   This will permanently stop and delete:                                   ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All active Rathole tunnels & systemd units                             ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All TOML configuration files & metadata                                ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All restart cronjobs                                                   ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● Rathole core binary (/usr/local/bin/rathole) & mrathole module         ${R}│${NC}"
    echo -e "  ${R}╰────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    
    local confirm cron_tmp
    echo -ne "  ${Y}Are you sure you want to proceed? Type '${R}yes${Y}' to confirm: ${NC}"; read -r confirm
    confirm=$(echo "$confirm" | tr -d '\r ')
    
    if [ "$confirm" != "yes" ]; then
        echo -e "  ${G}● Uninstallation cancelled.${NC}"; sleep 1.5; return
    fi

    echo -e "\n  ${DIM}● [1/5] Stopping services & killing processes...${NC}"
    systemctl stop mrathole@* 2>/dev/null
    systemctl disable mrathole@* 2>/dev/null
    killall -9 rathole 2>/dev/null

    echo -e "  ${DIM}● [2/5] Purging scheduled auto-restart cronjobs...${NC}"
    if command -v crontab >/dev/null 2>&1; then
        cron_tmp="$SECURE_TMP/crontab.$$"
        crontab -l 2>/dev/null | grep -v "mrathole@" > "$cron_tmp"
        crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
    fi

    echo -e "  ${DIM}● [3/5] Removing systemd unit templates...${NC}"
    rm -f /etc/systemd/system/mrathole@.service
    systemctl daemon-reload 2>/dev/null

    echo -e "  ${DIM}● [4/5] Deleting configurations & core binary...${NC}"
    rm -rf /etc/mrathole "$SECURE_TMP/.mrathole"* /usr/local/bin/rathole /usr/bin/rathole

    echo -e "  ${DIM}● [5/5] Removing mrathole wrapper script...${NC}"
    rm -f "$INSTALL_PATH" 2>/dev/null
    [ -f "$0" ] && rm -f "$0" 2>/dev/null

    echo -e "\n  ${G}✔ MRathole ecosystem has been completely eradicated.${NC}\n"
    exit 0
}

select_tunnel() {
    local configs=("$CONF_DIR"/*)
    local valid_configs=()
    local c
    for c in "${configs[@]}"; do
        [ -d "$c" ] && valid_configs+=("$c")
    done

    [ ${#valid_configs[@]} -eq 0 ] && { echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; }
    
    echo -e "\n  ${B}╭────────────────── Select Target Tunnel ────────────────────╮${NC}"
    local i
    for i in "${!valid_configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${valid_configs[$i]}")"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read -r t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r')
    if [[ "$t_idx" == "q" || -z "$t_idx" || -z "${valid_configs[$t_idx]}" ]]; then return 1; fi
    
    SELECTED_TUN="${valid_configs[$t_idx]}"
    return 0
}

check_first_run_core
setup_systemd

render_mrathole_menu() {
    draw_mrathole_header
    echo -e "\n  ${DIM}┌─[ PROVISION & MANAGE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Deploy New Reverse Tunnel${NC} ${DIM}(Rathole)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC} ${DIM}(Specific / ALL)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ FLAT CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Edit Remote Host / IP Address${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Edit TCP Port Mappings${NC} ${DIM}(Overwrite/Add)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Edit UDP Port Mappings${NC} ${DIM}(Overwrite/Add)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Edit Auth Token (Secret)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${C}Edit Tunnel Link Port${NC} ${DIM}(Connection Port)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${W}Rename Tunnel Interface${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & SYSTEM ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${C}Live Traffic & Port Radar${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${W}View Tunnels Registry & Settings${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${DIM}View Live Service Logs${NC}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${Y}Anti-Freeze Cronjob Manager${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC}${DIM}❯${NC} ${G}Restart Service${NC}"
    echo -e "  ${DIM}├─${NC} ${W}14${NC}${DIM}❯${NC} ${M}Install / Update Core Binary${NC}"
    echo -e "  ${DIM}├─${NC} ${W}15${NC}${DIM}❯${NC} ${G}Instant OTA Update (Sync Module)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}16${NC}${DIM}❯${NC} ${R}Uninstall MRathole${NC} ${DIM}(Purge All)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}

while true; do
    render_mrathole_menu
    read_with_refresh "  ${C}MRATHOLE ❯❯ ${NC}" opt render_mrathole_menu
    opt=$(echo "$opt" | tr -d '\r')
    
    case $opt in
        1) 
           echo -e "\n  ${DIM}┌─[ DEPLOY NEW TUNNEL ]${NC}"
           while true; do 
               echo -ne "  ${C}●${NC} ${W}Role [1: IRAN (Server) | 2: KHAREJ (Client) | q: Back]: ${NC}"; read -r s_type
               s_type=$(echo "$s_type" | tr -d '\r')
               [[ "$s_type" =~ ^[12q]$ ]] && break
           done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do 
               echo -ne "  ${C}●${NC} ${W}Tunnel Name (e.g. rt1): ${NC}"; read -r t_name
               t_name=$(echo "$t_name" | tr -dc 'a-zA-Z0-9_-')
               if [ -d "$CONF_DIR/$t_name" ]; then echo -e "  ${R}Error: Tunnel exists!${NC}"; continue; fi
               [[ -n "$t_name" ]] && break
           done
           
           r_ip="0.0.0.0"
           if [ "$s_type" == "2" ]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Target IRAN Host/IP: ${NC}"; read -r r_ip
                   r_ip=$(echo "$r_ip" | tr -d '\r')
                   is_valid_host "$r_ip" && break
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"
               done
           fi
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Tunnel Link Port (e.g. 5050): ${NC}"; read -r t_port
               t_port=$(echo "$t_port" | tr -dc '0-9')
               if [ -z "$t_port" ] || [ "$t_port" -lt 1 ] || [ "$t_port" -gt 65535 ]; then
                   echo -e "  ${R}Error: Port must be between 1 and 65535!${NC}"
                   continue
               fi

               if ss -tuln 2>/dev/null | grep -qE ":${t_port}\s"; then
                   echo -e "  ${R}Error: Port ${t_port} is already in use by another service!${NC}"
                   continue
               fi
               break
           done
           
           echo -ne "  ${C}●${NC} ${W}Custom Token (Leave blank to generate auto): ${NC}"; read -r t_token
           t_token=$(echo "$t_token" | tr -dc 'a-zA-Z0-9_-')
           [ -z "$t_token" ] && t_token=$(head -c 8 /dev/urandom | xxd -p)
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}TCP Ports to Forward (e.g. 80,443) [Blank if none]: ${NC}"; read -r tcp_p
               tcp_p=$(echo "$tcp_p" | tr -dc '0-9,')
               validate_forward_ports "$tcp_p" "$s_type" "tcp" && break
           done

           while true; do
               echo -ne "  ${C}●${NC} ${W}UDP Ports to Forward (e.g. 53) [Blank if none]: ${NC}"; read -r udp_p
               udp_p=$(echo "$udp_p" | tr -dc '0-9,')
               validate_forward_ports "$udp_p" "$s_type" "udp" && break
           done
           
           mkdir -p "$CONF_DIR/$t_name"
           cat <<EOF > "$CONF_DIR/$t_name/meta.conf"
TYPE=$s_type
LINK_PORT=$t_port
REMOTE_IP=$r_ip
TOKEN=$t_token
TCP_PORTS=$tcp_p
UDP_PORTS=$udp_p
EOF
           
           generate_toml "$t_name"
           systemctl enable "mrathole@$t_name" >/dev/null 2>&1
           systemctl restart "mrathole@$t_name"
           echo -e "  ${G}● Tunnel Deployed with Anti-Flap Optimizations!${NC}"; sleep 1.5 ;;
           
        2)
           tunnels=("$CONF_DIR"/*)
           valid_tunnels=()
           for d in "${tunnels[@]}"; do [ -d "$d" ] && valid_tunnels+=("$d"); done
           [ ${#valid_tunnels[@]} -eq 0 ] && continue
           
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Delete ─────────────────╮${NC}"
           for i in "${!valid_tunnels[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${valid_tunnels[$i]}")"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}Index (or 'all' / 'q'): ${NC}"; read -r del_idx
           del_idx=$(echo "$del_idx" | tr -d '\r')
           if [[ "$del_idx" == "all" ]]; then
               for d in "${valid_tunnels[@]}"; do
                   t_name=$(basename "$d")
                   systemctl stop "mrathole@$t_name" 2>/dev/null; systemctl disable "mrathole@$t_name" 2>/dev/null
                   if command -v crontab >/dev/null 2>&1; then
                       cron_tmp="$SECURE_TMP/crontab.$$"
                       crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > "$cron_tmp"
                       crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
                   fi
                   rm -rf "$d"
               done
               echo -e "  ${G}All Tunnels Purged!${NC}"; sleep 1.5
           elif [[ -n "${valid_tunnels[$del_idx]}" ]]; then
               t_name=$(basename "${valid_tunnels[$del_idx]}")
               systemctl stop "mrathole@$t_name" 2>/dev/null; systemctl disable "mrathole@$t_name" 2>/dev/null
               if command -v crontab >/dev/null 2>&1; then
                   cron_tmp="$SECURE_TMP/crontab.$$"
                   crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > "$cron_tmp"
                   crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
               fi
               rm -rf "${valid_tunnels[$del_idx]}"
               echo -e "  ${G}Tunnel Purged!${NC}"; sleep 1.5
           fi ;;

        3|4|5|6|7|8|12|13)
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN")
           TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; TCP_PORTS=""; UDP_PORTS=""
           source "$SELECTED_TUN/meta.conf" 2>/dev/null
           
           if [[ "$opt" == "3" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Remote Host/IP (Current: ${REMOTE_IP}): ${NC}"; read -r n_ip
               n_ip=$(echo "$n_ip" | tr -d '\r')
               if [ -z "$n_ip" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if ! is_valid_host "$n_ip"; then
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"; sleep 1.5; continue
               fi
               REMOTE_IP="$n_ip"
               
           elif [[ "$opt" == "4" ]]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Enter TCP Ports (e.g. 80,443) [Current: ${Y}${TCP_PORTS:-None}${W}]: ${NC}"; read -r n_tcp
                   n_tcp=$(echo "$n_tcp" | tr -dc '0-9,')
                   if [ -z "$n_tcp" ]; then
                       echo -e "  ${Y}● No changes made.${NC}"; break
                   fi
                   validate_forward_ports "$n_tcp" "$TYPE" "tcp" && { TCP_PORTS="$n_tcp"; break; }
               done
               [ -z "$n_tcp" ] && continue
               
           elif [[ "$opt" == "5" ]]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Enter UDP Ports (e.g. 53) [Current: ${C}${UDP_PORTS:-None}${W}]: ${NC}"; read -r n_udp
                   n_udp=$(echo "$n_udp" | tr -dc '0-9,')
                   if [ -z "$n_udp" ]; then
                       echo -e "  ${Y}● No changes made.${NC}"; break
                   fi
                   validate_forward_ports "$n_udp" "$TYPE" "udp" && { UDP_PORTS="$n_udp"; break; }
               done
               [ -z "$n_udp" ] && continue

           elif [[ "$opt" == "6" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Auth Token / Secret [Current: ${Y}${TOKEN}${W}]: ${NC}"; read -r n_tok
               n_tok=$(echo "$n_tok" | tr -dc 'a-zA-Z0-9_-')
               if [ -z "$n_tok" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               TOKEN="$n_tok"
               echo -e "  ${G}✔ Auth Token updated.${NC}"

           elif [[ "$opt" == "7" ]]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Enter New Link Port [Current: ${Y}${LINK_PORT}${W}]: ${NC}"; read -r n_port
                   n_port=$(echo "$n_port" | tr -dc '0-9')
                   if [ -z "$n_port" ]; then
                       echo -e "  ${Y}● No changes made.${NC}"; break
                   fi
                   if [ "$n_port" -lt 1 ] || [ "$n_port" -gt 65535 ]; then
                       echo -e "  ${R}Error: Port must be between 1 and 65535!${NC}"; continue
                   fi
                   if [ "$n_port" != "$LINK_PORT" ] && ss -tuln 2>/dev/null | grep -qE ":${n_port}\s"; then
                       echo -e "  ${R}Error: Port ${n_port} is already in use!${NC}"; continue
                   fi
                   LINK_PORT="$n_port"
                   echo -e "  ${G}✔ Link Port updated to ${n_port}.${NC}"
                   break
               done
               [ -z "$n_port" ] && continue
               
           elif [[ "$opt" == "8" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Tunnel Name (Current: ${Y}${t_name}${W}): ${NC}"; read -r new_name
               new_name=$(echo "$new_name" | tr -dc 'a-zA-Z0-9_-')
               if [ -n "$new_name" ]; then
                   if [ -d "$CONF_DIR/$new_name" ]; then
                       echo -e "  ${R}● Error: Tunnel name [${new_name}] already exists!${NC}"; sleep 1.5; continue
                   fi
                   
                   systemctl stop "mrathole@$t_name" 2>/dev/null; systemctl disable "mrathole@$t_name" 2>/dev/null
                   
                   if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "mrathole@${t_name}"; then
                       cron_tmp="$SECURE_TMP/crontab.$$"
                       crontab -l | grep -v "mrathole@${t_name}" > "$cron_tmp"
                       crontab "$cron_tmp"; rm -f "$cron_tmp"
                       rm -f "$CONF_DIR/$t_name/restart.sh"
                   fi

                   mv "$CONF_DIR/$t_name" "$CONF_DIR/$new_name" 2>/dev/null
                   t_name="$new_name"
                   SELECTED_TUN="$CONF_DIR/$new_name"
                   systemctl enable "mrathole@$t_name" >/dev/null 2>&1
                   echo -e "  ${G}● Tunnel successfully renamed to: ${new_name}${NC}"
               else
                   echo -e "  ${Y}● Rename cancelled.${NC}"; sleep 1; continue
               fi
               
           elif [[ "$opt" == "12" ]]; then
               manage_cron "$t_name"; continue
               
           elif [[ "$opt" == "13" ]]; then
               true
           fi
           
           cat <<EOF > "$CONF_DIR/$t_name/meta.conf"
TYPE=$TYPE
LINK_PORT=$LINK_PORT
REMOTE_IP=$REMOTE_IP
TOKEN=$TOKEN
TCP_PORTS=$TCP_PORTS
UDP_PORTS=$UDP_PORTS
EOF

           generate_toml "$t_name"
           systemctl restart "mrathole@$t_name"
           if systemctl is-active --quiet "mrathole@$t_name"; then
               echo -e "  ${G}✔ Tunnel updated and service restarted successfully.${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Tunnel failed to start. Please check logs!${NC}"; sleep 2
           fi
           ;;

        9) show_live_radar ;;
        10) show_tunnel_registry ;;
        11) 
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN")
           journalctl -u "mrathole@$t_name" -n 50 -f; continue
           ;;
           
        14) menu_install_core ;;
        15) self_update_module ;;
        16) uninstall_mrathole ;;
        0) break ;;
    esac
done
