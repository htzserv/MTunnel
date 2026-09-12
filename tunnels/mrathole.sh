#!/bin/bash
# --- MDesign Modular Core (mrathole.sh) | The Ultimate Rathole Engine V3.2.0 ---
# [Features: Async Background Checker | Smart Systemd Reload | Zero-Delay Entry]

MODULE_VERSION="3.2.0"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mrathole"
CONF_DIR="/etc/mrathole/tunnels"
SERVICE_TPL="/etc/systemd/system/mrathole@.service"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mrathole" ] && rm -f "/usr/local/bin/mrathole" 2>/dev/null

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

is_valid_host() {
    local host=$1
    if [[ "$host" =~ ^([a-zA-Z0-9.-]+)$ ]]; then return 0; fi
    return 1
}

MAIN_PID=$$
NEED_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1

UPDATE_CHECK_INTERVAL=30

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
        kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
update_watcher_loop &
WATCHER_PID=$!
trap 'kill "$WATCHER_PID" 2>/dev/null' EXIT

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
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_opt
    
    local tmp_file="$SECURE_TMP/.mrathole_update.$$"
    > "$tmp_file"

    if [[ "$src_opt" == "4" ]]; then
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste your code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
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
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read custom_url; dl_url=$(echo "$custom_url" | tr -d '\r ') ;;
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
        local new_ver=$(grep -m1 '^MODULE_VERSION=' "$tmp_file" | cut -d'"' -f2)
        [ -z "$new_ver" ] && new_ver="Unknown"
        
        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read confirm
        
        if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
            sed -i 's/\r$//' "$tmp_file" 2>/dev/null
            chmod +x "$tmp_file"
            
            cat "$tmp_file" > "$INSTALL_PATH" 2>/dev/null || true
            [ -f "$0" ] && cat "$tmp_file" > "$0" 2>/dev/null || true
            cp -f "$tmp_file" "$LOCAL_DIR/$rel_path" 2>/dev/null
            
            rm -f "$tmp_file"
            echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
            sleep 1.5
            exec "$INSTALL_PATH" "$@"
        else
            echo -e "  ${Y}● Update cancelled by user.${NC}"
            rm -f "$tmp_file"; sleep 1.5
        fi
    else
        echo -e "  ${R}✖ Update failed. Invalid format or network timeout.${NC}"
        rm -f "$tmp_file"
        sleep 2
    fi
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
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
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r')

    [[ "$src_choice" == "q" ]] && return

    echo -e "  ${R}● Purging old Rathole binaries and processes...${NC}"
    systemctl stop mrathole@* 2>/dev/null
    killall -9 rathole 2>/dev/null
    rm -f /usr/local/bin/rathole /usr/bin/rathole "$SECURE_TMP/rh_dl.zip" "$SECURE_TMP/rathole"

    if [[ "$src_choice" == "1" || "$src_choice" == "2" ]]; then
        echo -e "  ${DIM}● Downloading latest binary...${NC}"
        local arch=$(uname -m)
        local target="x86_64-unknown-linux-gnu"
        [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="aarch64-unknown-linux-gnu"
        local archive="rathole-${target}.zip"
        
        local dl_url="https://github.com/rapiz1/rathole/releases/download/v0.5.0/${archive}"
        [ "$src_choice" == "2" ] && dl_url="https://c107328.parspack.net/c107328/MTunnel/packages/${archive}"

        local dl_ok=false
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 10 --max-time 60 -o "$SECURE_TMP/rh_dl.zip" "$dl_url" 2>/dev/null && dl_ok=true
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 -O "$SECURE_TMP/rh_dl.zip" "$dl_url" 2>/dev/null && dl_ok=true
        fi

        if [ "$dl_ok" = true ] && [ -s "$SECURE_TMP/rh_dl.zip" ]; then
            apt-get install -y -q unzip >/dev/null 2>&1 || true
            unzip -q -o "$SECURE_TMP/rh_dl.zip" -d "$SECURE_TMP/" >/dev/null 2>&1
            [ -f "$SECURE_TMP/rathole" ] && mv "$SECURE_TMP/rathole" /usr/local/bin/rathole 2>/dev/null
            chmod +x /usr/local/bin/rathole 2>/dev/null || true
            echo -e "  ${G}✔ Rathole Core installed successfully.${NC}"
        else
            echo -e "  ${R}✖ Download failed!${NC}"
        fi

    elif [[ "$src_choice" == "3" ]]; then
        echo -ne "  ${C}● Enter Direct Link: ${NC}"; read custom_url
        custom_url=$(echo "$custom_url" | tr -d '\r')
        if [ -n "$custom_url" ]; then
            echo -e "  ${DIM}● Downloading from Custom Link...${NC}"
            wget -q --timeout=15 -O "$SECURE_TMP/rh_dl.zip" "$custom_url" 2>/dev/null
            if [ -s "$SECURE_TMP/rh_dl.zip" ]; then
                if unzip -t "$SECURE_TMP/rh_dl.zip" >/dev/null 2>&1; then
                    unzip -q -o "$SECURE_TMP/rh_dl.zip" -d "$SECURE_TMP/" >/dev/null 2>&1
                    [ -f "$SECURE_TMP/rathole" ] && mv "$SECURE_TMP/rathole" /usr/local/bin/rathole 2>/dev/null
                else
                    mv "$SECURE_TMP/rh_dl.zip" /usr/local/bin/rathole
                fi
                chmod +x /usr/local/bin/rathole 2>/dev/null || true
                echo -e "  ${G}✔ Rathole Core installed from custom link.${NC}"
            else
                echo -e "  ${R}✖ Download failed! Check the link.${NC}"
            fi
        fi

    elif [[ "$src_choice" == "4" ]]; then
        if [ -s "$LOCAL_DIR/packages/rathole" ]; then
            cp "$LOCAL_DIR/packages/rathole" /usr/local/bin/rathole
            chmod +x /usr/local/bin/rathole
            echo -e "  ${G}✔ Rathole Core restored from Local Directory.${NC}"
        else
            echo -e "  ${R}✖ File not found in $LOCAL_DIR/packages/rathole!${NC}"
        fi
    fi

    [ -f "/usr/local/bin/rathole" ] && ln -sf /usr/local/bin/rathole /usr/bin/rathole 2>/dev/null
    rm -f "$SECURE_TMP/rh_dl.zip" "$SECURE_TMP/rathole" 2>/dev/null
    systemctl start mrathole@* 2>/dev/null
    sleep 2
}

install_rathole_silent() {
    if ! command -v rathole >/dev/null 2>&1 && [ ! -f "/usr/local/bin/rathole" ]; then
        local arch=$(uname -m)
        local target="x86_64-unknown-linux-gnu"
        [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="aarch64-unknown-linux-gnu"
        local archive="rathole-${target}.zip"
        
        local dl_url="https://github.com/rapiz1/rathole/releases/download/v0.5.0/${archive}"
        local mirror_url="https://c107328.parspack.net/c107328/MTunnel/packages/${archive}"
        
        apt-get update -y -q >/dev/null 2>&1
        apt-get install -y -q unzip >/dev/null 2>&1
        
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 8 --max-time 40 -o "$SECURE_TMP/rh.zip" "$dl_url" 2>/dev/null || curl -fsSL --connect-timeout 8 --max-time 40 -o "$SECURE_TMP/rh.zip" "$mirror_url" 2>/dev/null
        else
            wget -q --timeout=12 -O "$SECURE_TMP/rh.zip" "$dl_url" 2>/dev/null || wget -q --timeout=12 -O "$SECURE_TMP/rh.zip" "$mirror_url" 2>/dev/null
        fi

        if [ -s "$SECURE_TMP/rh.zip" ]; then
            unzip -q -o "$SECURE_TMP/rh.zip" -d "$SECURE_TMP/" >/dev/null 2>&1
            [ -f "$SECURE_TMP/rathole" ] && mv "$SECURE_TMP/rathole" /usr/local/bin/rathole 2>/dev/null
            chmod +x /usr/local/bin/rathole 2>/dev/null
            rm -f "$SECURE_TMP/rh.zip"
        fi
    fi
    [ -f "/usr/local/bin/rathole" ] && ln -sf /usr/local/bin/rathole /usr/bin/rathole 2>/dev/null
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
    
    TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; TCP_PORTS=""; UDP_PORTS=""; source "$meta"
    
    > "$toml"
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

        IFS=',' read -ra TCP_ARR <<< "$TCP_PORTS"
        for p in "${TCP_ARR[@]}"; do
            p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
            echo "" >> "$toml"
            echo "[server.services.tcp_${p}]" >> "$toml"
            echo "type = \"tcp\"" >> "$toml"
            echo "bind_addr = \"0.0.0.0:${p}\"" >> "$toml"
        done

        IFS=',' read -ra UDP_ARR <<< "$UDP_PORTS"
        for p in "${UDP_ARR[@]}"; do
            p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
            echo "" >> "$toml"
            echo "[server.services.udp_${p}]" >> "$toml"
            echo "type = \"udp\"" >> "$toml"
            echo "bind_addr = \"0.0.0.0:${p}\"" >> "$toml"
        done
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

        IFS=',' read -ra TCP_ARR <<< "$TCP_PORTS"
        for p in "${TCP_ARR[@]}"; do
            p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
            echo "" >> "$toml"
            echo "[client.services.tcp_${p}]" >> "$toml"
            echo "type = \"tcp\"" >> "$toml"
            echo "local_addr = \"127.0.0.1:${p}\"" >> "$toml"
        done

        IFS=',' read -ra UDP_ARR <<< "$UDP_PORTS"
        for p in "${UDP_ARR[@]}"; do
            p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
            echo "" >> "$toml"
            echo "[client.services.udp_${p}]" >> "$toml"
            echo "type = \"udp\"" >> "$toml"
            echo "local_addr = \"127.0.0.1:${p}\"" >> "$toml"
        done
    fi
}

get_tunnel_status() {
    local t_name="$1"
    local known_active="$2"
    local meta="$CONF_DIR/$t_name/meta.conf"
    TYPE=""; LINK_PORT=""; source "$meta" 2>/dev/null
    
    if [ "$known_active" != "1" ] && ! systemctl is-active --quiet mrathole@$t_name; then echo "OFFLINE"; return; fi
    
    if [ "$TYPE" == "1" ]; then
        if ss -tn src ":$LINK_PORT" 2>/dev/null | grep -qE "^ESTAB"; then echo "CONNECTED"; else echo "WAITING"; fi
    else
        if ss -tn dst ":$LINK_PORT" 2>/dev/null | grep -qE "^ESTAB"; then echo "CONNECTED"; else echo "RECONNECTING"; fi
    fi
}

get_peer_ping() {
    local target_ip=$(echo "$1" | tr -d ' \n\r')
    local port=$(echo "$2" | tr -d ' \n\r')
    if [ -z "$target_ip" ] || [ "$target_ip" == "0.0.0.0" ]; then echo "N/A"; return; fi
    
    local ping_res=$(timeout 2 ping -c 1 -W 1 "$target_ip" 2>/dev/null)
    if echo "$ping_res" | grep -q "time="; then
        local ping_val=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+' | awk '{print int($1+0.5)}')
        echo "${ping_val}ms"
        return
    fi
    
    if command -v ss >/dev/null 2>&1; then
        local tcp_rtt=$(ss -nti | grep -A 1 "$target_ip" | grep -oP 'rtt:\K[0-9.]+' | head -n 1)
        if [ -n "$tcp_rtt" ]; then
            local rounded_rtt=$(echo "$tcp_rtt" | awk '{print int($1+0.5)}')
            echo "${rounded_rtt}ms*"
            return
        fi
    fi

    if [ -n "$port" ] && [[ "$port" =~ ^[0-9]+$ ]]; then
        local start_ts=$(date +%s%3N 2>/dev/null)
        if timeout 1 bash -c "</dev/tcp/$target_ip/$port" 2>/dev/null; then
            local end_ts=$(date +%s%3N 2>/dev/null)
            if [[ "$start_ts" =~ ^[0-9]+$ ]] && [[ "$end_ts" =~ ^[0-9]+$ ]]; then
                local t_rtt=$((end_ts - start_ts))
                [ "$t_rtt" -le 0 ] && t_rtt=1
                echo "${t_rtt}ms*"
                return
            fi
        fi
    fi

    echo "Timeout"
}

draw_header() {
    local s_ip=$(get_local_ip); local total_t=0; local active_t=0; local online_t=0
    local t_names=() units=()
    for d in "$CONF_DIR"/*; do
        if [ -d "$d" ]; then
            local t_name=$(basename "$d")
            t_names+=("$t_name"); units+=("mrathole@$t_name")
        fi
    done
    total_t=${#t_names[@]}
    if [ "$total_t" -gt 0 ]; then
        local states=() i=0
        while IFS= read -r st_line; do states+=("$st_line"); done < <(systemctl is-active "${units[@]}" 2>/dev/null)
        for t_name in "${t_names[@]}"; do
            if [ "${states[$i]}" == "active" ]; then
                ((active_t++))
                local st=$(get_tunnel_status "$t_name" "1")
                [ "$st" == "CONNECTED" ] && ((online_t++))
            fi
            ((i++))
        done
    fi
    
    local core_color="${R}"; local core_raw="Not Installed"
    if command -v rathole >/dev/null 2>&1 || [ -f "/usr/local/bin/rathole" ]; then
        core_color="${G}"; core_raw="Installed"
    fi
    
    local act_color="${DIM}"; local act_text="0/0"
    if [ "$total_t" -gt 0 ]; then
        act_text="${active_t}/${total_t}"
        if [ "$active_t" -eq "$total_t" ]; then act_color="${G}"
        elif [ "$active_t" -gt 0 ]; then act_color="${Y}"
        else act_color="${R}"; fi
    fi

    local stat_color="${R}"; local stat_icon="○"; local stat_text="STOPPED"
    if [ "$active_t" -gt 0 ]; then
        if [ "$online_t" -eq "$active_t" ]; then 
            stat_color="${G}"; stat_icon="●"; stat_text="CONNECTED"
        elif [ "$online_t" -gt 0 ]; then 
            stat_color="${Y}"; stat_icon="◐"; stat_text="PARTIAL"
        else 
            stat_color="${Y}"; stat_icon="◎"; stat_text="WAITING"
        fi
    fi

    local peer_ip=""
    local tmp_port=""
    for d in "$CONF_DIR"/*; do
        if [ -d "$d" ] && [ -f "$d/meta.conf" ]; then
            local tmp_type=$(grep "^TYPE=" "$d/meta.conf" | cut -d'=' -f2)
            local tmp_remote=$(grep "^REMOTE_IP=" "$d/meta.conf" | cut -d'=' -f2)
            tmp_port=$(grep "^LINK_PORT=" "$d/meta.conf" | cut -d'=' -f2)
            
            if [ -n "$tmp_remote" ] && [ "$tmp_remote" != "0.0.0.0" ]; then
                peer_ip="$tmp_remote"
                break
            elif [ "$tmp_type" == "1" ]; then
                local conn=$(ss -tn src ":$tmp_port" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
                if [ -n "$conn" ]; then
                    peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                    break
                fi
            fi
        fi
    done

    local g_color="${DIM}"; local g_text="N/A"
    if [ -n "$peer_ip" ]; then
        local ping_cache="$SECURE_TMP/.mrathole_ping_cache"
        local ping_lock="$SECURE_TMP/.mrathole_ping_lock"
        local now=$(date +%s)
        local cache_ts=0; [ -f "$ping_cache" ] && cache_ts=$(stat -c %Y "$ping_cache" 2>/dev/null || echo 0)
        local cache_age=$(( now - cache_ts ))

        if [ -f "$ping_cache" ] && [ "$cache_age" -lt 15 ]; then
            local p_val=$(cat "$ping_cache" 2>/dev/null)
            if [[ "$p_val" != "Timeout" && "$p_val" != "N/A" ]]; then
                local p_int=$(echo "$p_val" | tr -dc '0-9')
                if [ -z "$p_int" ]; then p_int=0; fi
                if [ "$p_int" -lt 90 ]; then g_color="${G}"
                elif [ "$p_int" -lt 160 ]; then g_color="${Y}"
                else g_color="${R}"
                fi
                g_text="${p_val}"
            else
                g_color="${R}"; g_text="Timeout"
            fi
        else
            g_color="${DIM}"; g_text="Calculating..."
        fi

        local lock_ts=0; [ -f "$ping_lock" ] && lock_ts=$(stat -c %Y "$ping_lock" 2>/dev/null || echo 0)
        local lock_age=$(( now - lock_ts ))
        if { [ ! -f "$ping_cache" ] || [ "$cache_age" -ge 15 ]; } && { [ ! -f "$ping_lock" ] || [ "$lock_age" -gt 5 ]; }; then
            touch "$ping_lock"
            (
                bg_val=$(get_peer_ping "$peer_ip" "$tmp_port")
                echo "$bg_val" > "$ping_cache"
                rm -f "$ping_lock"
                kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
            ) &
        fi
    else
        g_color="${DIM}"; g_text="Waiting"
    fi

    local title=" MRathole Engine v${MODULE_VERSION} "
    local full_str=" │${title}│ IP: ${s_ip} │ Core: ${core_raw} │ Peer Ping: ${g_text} │ ACTIVE: ${act_text} │ STATUS: ${stat_icon} ${stat_text} "
    local pad_len=$(( 126 - ${#full_str} ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${title}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${B}│${NC}${DIM} Core:${NC} ${core_color}${core_raw}${NC} ${B}│${NC}${DIM} Peer Ping:${NC} ${g_color}${g_text}${NC} ${B}│${NC}${DIM} ACTIVE:${NC} ${act_color}${act_text}${NC} ${B}│${NC}${DIM} STATUS:${NC} ${stat_color}${stat_icon} ${stat_text}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_tunnel_registry() {
    draw_header
    echo -e "\n  ${Y}● Deployed Rathole Tunnels Registry:${NC}"
    local count=0
    for d in "$CONF_DIR"/*; do
        [ ! -d "$d" ] && continue
        local t_name=$(basename "$d")
        TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; TCP_PORTS=""; UDP_PORTS=""
        source "$d/meta.conf" 2>/dev/null
        
        local role_text=$([ "$TYPE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local ping_val="N/A"
        local connected_peer=""

        if [ "$TYPE" == "2" ] && [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "0.0.0.0" ]; then
            ping_val=$(get_peer_ping "$REMOTE_IP" "$LINK_PORT")
            connected_peer="$REMOTE_IP"
        elif [ "$TYPE" == "1" ]; then
            local conn=$(ss -tn src ":$LINK_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
            if [ -n "$conn" ]; then
                local p_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                ping_val=$(get_peer_ping "$p_ip" "$LINK_PORT")
                connected_peer="$p_ip"
            else
                ping_val="Waiting"
            fi
        fi

        local peer_text=$([ "$TYPE" == "1" ] && echo "Listening on :${LINK_PORT}" || echo "${REMOTE_IP}:${LINK_PORT}")
        if [ "$TYPE" == "1" ] && [ -n "$connected_peer" ]; then
            peer_text="${connected_peer}:${LINK_PORT} (Active)"
        fi

        local st=$(get_tunnel_status "$t_name")
        local stat_icon="○"; local stat_text="OFFLINE"; local stat_color="${R}"
        if [ "$st" == "CONNECTED" ]; then stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}";
        elif [ "$st" == "WAITING" ]; then stat_icon="◎"; stat_text="WAITING CLIENT"; stat_color="${Y}";
        elif [ "$st" == "RECONNECTING" ]; then stat_icon="◎"; stat_text="RECONNECTING..."; stat_color="${Y}"; fi

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $t_name"; local right_p="Role: $role_text"
        local pad=$(( 122 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="Link Port    : ${LINK_PORT}"; local r1="Latency: ${ping_val}"
        local pad1=$(( 122 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Link Port    :${NC} ${W}${LINK_PORT}${NC}${sp1}${DIM}Latency:${NC} ${Y}${ping_val}${NC} ${B}│${NC}"
        
        local l2="Peer Target  : ${peer_text}"; local r2="Link State: ${stat_icon} ${stat_text}"
        local clean_r2=$(echo -e "$r2" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
        local pad2=$(( 122 - ${#l2} - ${#clean_r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}Peer Target  :${NC} ${W}${peer_text}${NC}${sp2}${DIM}Link State:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${B}│${NC}"

        local l3="Auth Token   : ${TOKEN}"; local r3="Protocol: TCP (Rathole Native)"
        local pad3=$(( 122 - ${#l3} - ${#r3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${Y}Auth Token   :${NC} ${W}${TOKEN}${NC}${sp3}${DIM}Protocol:${NC} ${C}TCP (Rathole Native)${NC} ${B}│${NC}"

        local tcp_str="${TCP_PORTS:0:100}"; [ ${#TCP_PORTS} -gt 100 ] && tcp_str="${tcp_str}..."
        local udp_str="${UDP_PORTS:0:100}"; [ ${#UDP_PORTS} -gt 100 ] && udp_str="${udp_str}..."
        
        local l4="TCP Mappings : ${tcp_str:-None}"
        local pad4=$(( 122 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}TCP Mappings :${NC} ${Y}${tcp_str:-None}${NC}${sp4} ${B}│${NC}"
        
        local l5="UDP Mappings : ${udp_str:-None}"
        local pad5=$(( 122 - ${#l5} )); [ "$pad5" -lt 0 ] && pad5=0; local sp5=$(printf '%*s' "$pad5" "")
        echo -e "  ${B}│${NC} ${DIM}UDP Mappings :${NC} ${C}${udp_str:-None}${NC}${sp5} ${B}│${NC}"
        
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯\n"
        ((count++))
    done
    if [ "$count" -eq 0 ]; then echo -e "  ${R}● No tunnels configured yet!${NC}\n"; fi
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

show_live_radar() {
    tput civis; clear
    while true; do
        printf "\033[H"; draw_header
        echo -e "\n  ${DIM}┌─[ RATHOLE TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────────┬────────────────┬──────────────────────────┬────────────────────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} ${W}%-14s${NC} ${B}│${NC} ${Y}%-24s${NC} ${B}│${NC} ${DIM}%-26s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "TCP PORTS" "UDP PORTS"
        echo -e "  ${B}├──────────────────────┼────────────────┼──────────────────────────┼────────────────────────────┤${NC}"

        local count=0
        for d in "$CONF_DIR"/*; do
            [ ! -d "$d" ] && continue
            local t_name=$(basename "$d")
            TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; TCP_PORTS=""; UDP_PORTS=""; source "$d/meta.conf" 2>/dev/null
            
            local st=$(get_tunnel_status "$t_name")
            local st_color="${R}"; local st_text="OFFLINE"
            if [ "$st" == "CONNECTED" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "RECONNECTING" ]; then st_color="${Y}"; st_text="RETRYING"; fi

            local disp_tcp="${TCP_PORTS:0:24}"; [ ${#TCP_PORTS} -gt 24 ] && disp_tcp="${disp_tcp:0:21}..."
            local disp_udp="${UDP_PORTS:0:26}"; [ ${#UDP_PORTS} -gt 26 ] && disp_udp="${disp_udp:0:23}..."

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
    
    echo -e "\n  ${DIM}┌─[ ANTI-FREEZE CRONJOB MANAGER ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add/Update Auto-Restart Cronjob${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Remove Auto-Restart Cronjob${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read cr_opt

    if [[ "$cr_opt" == "1" ]]; then
        echo -ne "  ${C}●${NC} ${W}Restart interval in hours (e.g. 2, 4, 6): ${NC}"; read interval
        interval=$(echo "$interval" | tr -d '\r')
        [[ ! "$interval" =~ ^[0-9]+$ ]] && echo -e "  ${R}Invalid interval!${NC}" && sleep 1.5 && return
        
        echo "#!/bin/bash" > "$cron_script"
        echo "systemctl kill -s SIGKILL mrathole@${t_name}" >> "$cron_script"
        echo "systemctl restart mrathole@${t_name}" >> "$cron_script"
        chmod +x "$cron_script"
        
        local cron_tmp="$SECURE_TMP/crontab.$$"
        crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > "$cron_tmp"
        echo "0 */${interval} * * * $cron_script #mrathole@${t_name}" >> "$cron_tmp"
        crontab "$cron_tmp"; rm -f "$cron_tmp"
        echo -e "  ${G}✔ Cronjob added: Tunnel will restart every ${interval} hours.${NC}"; sleep 2
    elif [[ "$cr_opt" == "2" ]]; then
        local cron_tmp="$SECURE_TMP/crontab.$$"
        crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > "$cron_tmp"
        crontab "$cron_tmp"; rm -f "$cron_tmp"
        rm -f "$cron_script"
        echo -e "  ${G}✔ Cronjob removed.${NC}"; sleep 1.5
    fi
}

select_tunnel() {
    local configs=($(ls -d "$CONF_DIR"/* 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; fi
    
    echo -e "\n  ${B}╭────────────────── Select Tunnel to Manage ─────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}")"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r')
    if [[ "$t_idx" == "q" || -z "$t_idx" || -z "${configs[$t_idx]}" ]]; then return 1; fi
    
    SELECTED_TUN="${configs[$t_idx]}"
    return 0
}

install_rathole_silent
setup_systemd

render_mrathole_menu() {
    badge=""
    if [ -f "$SECURE_TMP/.mrathole_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.mrathole_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_header
    echo -e "\n  ${DIM}┌─[ DEPLOYMENT & DESTRUCTION ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Deploy New Reverse Tunnel${NC} ${DIM}(Rathole)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC} ${DIM}(Specific / ALL)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Edit Remote Host / IP Address${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Edit TCP Port Mappings${NC} ${DIM}(Overwrite/Add)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Edit UDP Port Mappings${NC} ${DIM}(Overwrite/Add)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${W}Rename Tunnel Interface${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & DETAILS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${C}Live Traffic & Port Radar${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${W}View Tunnels Registry & Settings${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${DIM}View Live Service Logs${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${Y}Anti-Freeze Cronjob Manager${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${G}Restart Service${NC}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${M}Install / Update Core Binary${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC}${DIM}❯${NC} ${G}Instant OTA Update (Sync Module)${NC}${badge}"
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
               echo -ne "  ${C}●${NC} ${W}Role [1: IRAN (Server) | 2: KHAREJ (Client) | q: Back]: ${NC}"; read s_type
               s_type=$(echo "$s_type" | tr -d '\r')
               [[ "$s_type" =~ ^[12q]$ ]] && break
           done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do 
               echo -ne "  ${C}●${NC} ${W}Tunnel Name (e.g. rt1): ${NC}"; read t_name
               t_name=$(echo "$t_name" | tr -dc 'a-zA-Z0-9_-')
               if [ -d "$CONF_DIR/$t_name" ]; then echo -e "  ${R}Error: Tunnel exists!${NC}"; continue; fi
               [[ -n "$t_name" ]] && break
           done
           
           r_ip="0.0.0.0"
           if [ "$s_type" == "2" ]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Target IRAN Host/IP: ${NC}"; read r_ip
                   r_ip=$(echo "$r_ip" | tr -d '\r')
                   is_valid_host "$r_ip" && break
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"
               done
           fi
           
           echo -ne "  ${C}●${NC} ${W}Tunnel Link Port (e.g. 5050): ${NC}"; read t_port
           t_port=$(echo "$t_port" | tr -dc '0-9')
           
           echo -ne "  ${C}●${NC} ${W}Custom Token (Leave blank to generate auto): ${NC}"; read t_token
           t_token=$(echo "$t_token" | tr -dc 'a-zA-Z0-9_-')
           [ -z "$t_token" ] && t_token=$(head -c 8 /dev/urandom | xxd -p)
           
           echo -ne "  ${C}●${NC} ${W}TCP Ports to Forward (e.g. 80,443) [Leave blank if none]: ${NC}"; read tcp_p
           echo -ne "  ${C}●${NC} ${W}UDP Ports to Forward (e.g. 53) [Leave blank if none]: ${NC}"; read udp_p
           tcp_p=$(echo "$tcp_p" | tr -dc '0-9,')
           udp_p=$(echo "$udp_p" | tr -dc '0-9,')
           
           mkdir -p "$CONF_DIR/$t_name"
           echo -e "TYPE=$s_type\nLINK_PORT=$t_port\nREMOTE_IP=$r_ip\nTOKEN=$t_token\nTCP_PORTS=$tcp_p\nUDP_PORTS=$udp_p" > "$CONF_DIR/$t_name/meta.conf"
           
           generate_toml "$t_name"
           systemctl enable mrathole@$t_name >/dev/null 2>&1
           systemctl restart mrathole@$t_name
           echo -e "  ${G}● Tunnel Deployed with Anti-Flap Optimizations!${NC}"; sleep 1.5 ;;
           
        2)
           tunnels=($(ls -d "$CONF_DIR"/* 2>/dev/null))
           [ ${#tunnels[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Delete ─────────────────╮${NC}"
           for i in "${!tunnels[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${tunnels[$i]}")"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}Index (or 'all' / 'q'): ${NC}"; read del_idx
           del_idx=$(echo "$del_idx" | tr -d '\r')
           if [[ "$del_idx" == "all" ]]; then
               for d in "${tunnels[@]}"; do
                   t_name=$(basename "$d")
                   systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null
                   local cron_tmp="$SECURE_TMP/crontab.$$"
                   crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > "$cron_tmp"
                   crontab "$cron_tmp"; rm -f "$cron_tmp"
                   rm -rf "$d"
               done
               echo -e "  ${G}All Tunnels Purged!${NC}"; sleep 1.5
           elif [[ -n "${tunnels[$del_idx]}" ]]; then
               t_name=$(basename "${tunnels[$del_idx]}")
               systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null
               local cron_tmp="$SECURE_TMP/crontab.$$"
               crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > "$cron_tmp"
               crontab "$cron_tmp"; rm -f "$cron_tmp"
               rm -rf "${tunnels[$del_idx]}"
               echo -e "  ${G}Tunnel Purged!${NC}"; sleep 1.5
           fi ;;

        3|4|5|6|10|11)
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN")
           TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; TCP_PORTS=""; UDP_PORTS=""; source "$SELECTED_TUN/meta.conf" 2>/dev/null
           
           if [[ "$opt" == "3" ]]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}New Remote Host/IP (Current: ${REMOTE_IP}): ${NC}"; read n_ip
                   n_ip=$(echo "$n_ip" | tr -d '\r')
                   [ -z "$n_ip" ] && break
                   is_valid_host "$n_ip" && {
                       sed -i "s/^REMOTE_IP=.*/REMOTE_IP=$n_ip/" "$SELECTED_TUN/meta.conf"
                       break
                   }
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"
               done
               
           elif [[ "$opt" == "4" ]]; then
               echo -ne "  ${C}●${NC} ${W}Enter TCP Ports (e.g. 80,443) [Current: ${Y}${TCP_PORTS:-None}${W}]: ${NC}"; read n_tcp
               n_tcp=$(echo "$n_tcp" | tr -dc '0-9,')
               [ -n "$n_tcp" ] && sed -i "s/^TCP_PORTS=.*/TCP_PORTS=$n_tcp/" "$SELECTED_TUN/meta.conf"
               
           elif [[ "$opt" == "5" ]]; then
               echo -ne "  ${C}●${NC} ${W}Enter UDP Ports (e.g. 53) [Current: ${C}${UDP_PORTS:-None}${W}]: ${NC}"; read n_udp
               n_udp=$(echo "$n_udp" | tr -dc '0-9,')
               [ -n "$n_udp" ] && sed -i "s/^UDP_PORTS=.*/UDP_PORTS=$n_udp/" "$SELECTED_TUN/meta.conf"
               
           elif [[ "$opt" == "6" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Tunnel Name (Current: ${Y}${t_name}${W}): ${NC}"; read new_name
               new_name=$(echo "$new_name" | tr -dc 'a-zA-Z0-9_-')
               if [ -n "$new_name" ]; then
                   if [ -d "$CONF_DIR/$new_name" ]; then
                       echo -e "  ${R}● Error: Tunnel name [${new_name}] already exists!${NC}"; sleep 1.5; continue
                   fi
                   
                   systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null
                   
                   if crontab -l 2>/dev/null | grep -q "mrathole@${t_name}"; then
                       local cron_tmp="$SECURE_TMP/crontab.$$"
                       crontab -l | grep -v "mrathole@${t_name}" > "$cron_tmp"
                       crontab "$cron_tmp"; rm -f "$cron_tmp"
                       rm -f "$CONF_DIR/$t_name/restart.sh"
                   fi

                   mv "$CONF_DIR/$t_name" "$CONF_DIR/$new_name" 2>/dev/null
                   t_name="$new_name"
                   systemctl enable mrathole@$t_name >/dev/null 2>&1
                   echo -e "  ${G}● Tunnel successfully renamed to: ${new_name}${NC}"
               else
                   continue
               fi
               
           elif [[ "$opt" == "10" ]]; then
               manage_cron "$t_name"; continue
               
           elif [[ "$opt" == "11" ]]; then
               true
           fi
           
           generate_toml "$t_name"
           systemctl restart mrathole@$t_name
           if systemctl is-active --quiet mrathole@$t_name; then
               echo -e "  ${G}✔ Tunnel updated and service restarted successfully.${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Tunnel failed to start. Please check logs!${NC}"; sleep 2
           fi
           ;;

        7) show_live_radar ;;
        8) show_tunnel_registry ;;
        9) 
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN")
           journalctl -u mrathole@$t_name -n 50 -f; continue
           ;;
           
        12) menu_install_core ;;
        13) self_update_module ;;
        0) break ;;
    esac
done
