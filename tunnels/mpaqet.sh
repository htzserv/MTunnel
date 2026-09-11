#!/bin/bash
# --- MPaqet Modular Core (mpaqet.sh) | Raw Packet Tunnel Engine v7.5.4 ---
# [Features: Refined Spacing | Async Background Checker | Minimal Badges]

MODULE_VERSION="7.5.5"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mpaqet"
CONF_DIR="/etc/paqet"
SERVICE_DIR="/etc/systemd/system"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mpaqet" ] && rm -f "/usr/local/bin/mpaqet" 2>/dev/null

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

# فاصله‌ی چک خودکار آپدیت در پس‌زمینه (ثانیه) - پیشنهاد حداقل 20-30 ثانیه
UPDATE_CHECK_INTERVAL=30

# --- Character-by-character read که رفرش زنده رو بدون پاک شدن تایپ کاربر مدیریت می‌کنه ---
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

# --- ASYNC BACKGROUND UPDATE CHECKER ---
check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tunnels/mpaqet.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tunnels/mpaqet.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mpaqet_remote_ver"
}
update_watcher_loop() {
    while true; do
        check_update_bg
        kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
update_watcher_loop &
# ---------------------------------------

self_update_module() {
    local rel_path="tunnels/mpaqet.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mpaqet_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mpaqet_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (MPaqet Engine) ]${NC}"
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
    
    local tmp_file="$SECURE_TMP/.mpaqet_update.$$"
    > "$tmp_file"

    if [[ "$src_opt" == "4" ]]; then
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste your code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
            sleep 2; nano "$tmp_file"
        elif command -v vi >/dev/null 2>&1; then
            vi "$tmp_file"
        else
            echo -e "  ${R}✖ No text editor (nano/vi) found on this system!${NC}"; rm -f "$tmp_file"; sleep 2; return
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

format_speed() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B/s"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B/s"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB/s"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB/s\", $bytes/1048576}"
    else awk "BEGIN {printf \"%.2f GB/s\", $bytes/1073741824}"; fi
}

format_total() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -lt 1099511627776 ]; then awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    else awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"; fi
}

menu_install_core() {
    echo -e "\n  ${DIM}┌─[ INSTALL / UPDATE PAQET CORE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/paqet)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r\n ')

    [[ "$src_choice" == "q" ]] && return

    echo -e "  ${R}● Purging old MPaqet binaries and processes...${NC}"
    systemctl stop mpaqet@* 2>/dev/null
    killall -9 paqet 2>/dev/null
    rm -f /usr/local/bin/paqet /usr/bin/paqet "$SECURE_TMP/paqet_dl" "$SECURE_TMP/paqet.tar.gz"

    apt-get update -y -q >/dev/null 2>&1 || true
    apt-get install -y -q libpcap-dev wget curl xxd >/dev/null 2>&1 || true

    if [[ "$src_choice" == "1" || "$src_choice" == "2" ]]; then
        echo -e "  ${DIM}● Fetching latest release from GitHub API...${NC}"
        local arch=$(uname -m)
        local target="amd64"
        [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="arm64"
        
        local dl_url=""
        if [ "$src_choice" == "1" ]; then
            local api_url="https://api.github.com/repos/hanselime/paqet/releases/latest"
            dl_url=$(curl -m 10 -s "$api_url" | grep "browser_download_url.*linux-${target}" | cut -d '"' -f 4 | head -1)
            [ -z "$dl_url" ] && dl_url="https://github.com/hanselime/paqet/releases/latest/download/paqet-linux-${target}.tar.gz"
        else
            dl_url="https://c107328.parspack.net/c107328/MTunnel/packages/paqet-linux-${target}.tar.gz"
        fi
        
        if [ -n "$dl_url" ]; then
            wget -q --timeout=15 -O "$SECURE_TMP/paqet.tar.gz" "$dl_url" || { echo -e "  ${R}✖ Download failed!${NC}"; return; }
            if gzip -t "$SECURE_TMP/paqet.tar.gz" 2>/dev/null; then
                tar -xzf "$SECURE_TMP/paqet.tar.gz" -C "$SECURE_TMP/" >/dev/null 2>&1 || { echo -e "  ${R}✖ Extraction failed!${NC}"; return; }
                local bin_found=$(find "$SECURE_TMP" -maxdepth 1 -type f -name "*paqet*" -executable | head -1)
                
                if [ -n "$bin_found" ]; then
                    mv "$bin_found" /usr/local/bin/paqet
                    chmod +x /usr/local/bin/paqet
                    echo -e "  ${G}✔ MPaqet Core installed successfully.${NC}"
                else
                    echo -e "  ${R}✖ Binary not found in archive!${NC}"
                fi
                rm -f "$SECURE_TMP"/paqet*
            else
                echo -e "  ${R}✖ Downloaded file is corrupted or not a valid archive!${NC}"
            fi
        else
            echo -e "  ${R}✖ Failed to fetch release URL from GitHub!${NC}"
        fi

    elif [[ "$src_choice" == "3" ]]; then
        echo -ne "  ${C}● Enter Direct Link: ${NC}"; read custom_url
        custom_url=$(echo "$custom_url" | tr -d '\r')
        if [ -n "$custom_url" ]; then
            echo -e "  ${DIM}● Downloading from Custom Link...${NC}"
            wget -q --timeout=15 -O "$SECURE_TMP/paqet_dl" "$custom_url" || { echo -e "  ${R}✖ Download failed! Check the link.${NC}"; return; }
            
            if gzip -t "$SECURE_TMP/paqet_dl" 2>/dev/null; then
                tar -xzf "$SECURE_TMP/paqet_dl" -C "$SECURE_TMP/" >/dev/null 2>&1
                local bin_found=$(find "$SECURE_TMP" -maxdepth 1 -type f -name "*paqet*" -executable | head -1)
                if [ -n "$bin_found" ]; then 
                    mv "$bin_found" /usr/local/bin/paqet
                else 
                    mv "$SECURE_TMP/paqet_dl" /usr/local/bin/paqet
                fi
            else
                mv "$SECURE_TMP/paqet_dl" /usr/local/bin/paqet
            fi
            chmod +x /usr/local/bin/paqet
            echo -e "  ${G}✔ MPaqet Core installed from custom link.${NC}"
            rm -f "$SECURE_TMP/paqet"*
        fi

    elif [[ "$src_choice" == "4" ]]; then
        if [ -s "$LOCAL_DIR/packages/paqet" ]; then
            cp "$LOCAL_DIR/packages/paqet" /usr/local/bin/paqet
            chmod +x /usr/local/bin/paqet
            echo -e "  ${G}✔ MPaqet Core restored from Local Directory.${NC}"
        else
            echo -e "  ${R}✖ File not found in $LOCAL_DIR/packages/paqet!${NC}"
        fi
    fi

    [ -f "/usr/local/bin/paqet" ] && ln -sf /usr/local/bin/paqet /usr/bin/paqet 2>/dev/null
    
    echo -e "  ${DIM}● Restarting active tunnels...${NC}"
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            t_name=$(basename "$conf" .meta)
            systemctl start "mpaqet@${t_name}" 2>/dev/null
        fi
    done
    sleep 2
}

install_paqet_silent() {
    if ! command -v paqet >/dev/null 2>&1 && [ ! -f "/usr/local/bin/paqet" ]; then
        apt-get update -y -q >/dev/null 2>&1 || true
        apt-get install -y -q libpcap-dev wget curl xxd >/dev/null 2>&1 || true
        local arch=$(uname -m)
        local target="amd64"
        [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="arm64"
        
        local dl_url="https://github.com/hanselime/paqet/releases/latest/download/paqet-linux-${target}.tar.gz"
        local mirror_url="https://c107328.parspack.net/c107328/MTunnel/packages/paqet-linux-${target}.tar.gz"
        
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 8 --max-time 40 -o "$SECURE_TMP/paqet.tar.gz" "$dl_url" 2>/dev/null || curl -fsSL --connect-timeout 8 --max-time 40 -o "$SECURE_TMP/paqet.tar.gz" "$mirror_url" 2>/dev/null
        else
            wget -q --timeout=12 -O "$SECURE_TMP/paqet.tar.gz" "$dl_url" 2>/dev/null || wget -q --timeout=12 -O "$SECURE_TMP/paqet.tar.gz" "$mirror_url" 2>/dev/null
        fi

        if [ -s "$SECURE_TMP/paqet.tar.gz" ]; then
            if gzip -t "$SECURE_TMP/paqet.tar.gz" 2>/dev/null; then
                tar -xzf "$SECURE_TMP/paqet.tar.gz" -C "$SECURE_TMP/" >/dev/null 2>&1
                local bin_found=$(find "$SECURE_TMP" -maxdepth 1 -type f -name "*paqet*" -executable | head -1)
                if [ -n "$bin_found" ]; then
                    mv "$bin_found" /usr/local/bin/paqet
                    chmod +x /usr/local/bin/paqet
                fi
                rm -f "$SECURE_TMP"/paqet*
            fi
        fi
    fi
    [ -f "/usr/local/bin/paqet" ] && ln -sf /usr/local/bin/paqet /usr/bin/paqet 2>/dev/null
}

setup_paqet_counters() {
    local name="$1"; local l_port="$2"
    iptables -t mangle -C INPUT -p tcp --dport "$l_port" -m comment --comment "MPAQET_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -p tcp --dport "$l_port" -m comment --comment "MPAQET_RX_${name}" 2>/dev/null
    iptables -t mangle -C OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_TX_${name}" 2>/dev/null
    
    iptables -t raw -C PREROUTING -p tcp --dport "$l_port" -m comment --comment "MPAQET_RAW_${name}" >/dev/null 2>&1 || iptables -t raw -A PREROUTING -p tcp --dport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" 2>/dev/null
    iptables -t raw -C OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_RAW_${name}" >/dev/null 2>&1 || iptables -t raw -A OUTPUT -p tcp --sport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" 2>/dev/null
    
    iptables -t mangle -C OUTPUT -p tcp --sport "$l_port" --tcp-flags RST RST -m comment --comment "MPAQET_RST_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -p tcp --sport "$l_port" --tcp-flags RST RST -j DROP -m comment --comment "MPAQET_RST_${name}" 2>/dev/null
}

clean_paqet_counters() {
    local name="$1"
    iptables -t mangle -S 2>/dev/null | grep -E "MPAQET_(RX|TX|RST)_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t mangle $r 2>/dev/null; done
    iptables -t raw -S 2>/dev/null | grep "MPAQET_RAW_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t raw $r 2>/dev/null; done
}

zero_paqet_counters() {
    iptables -Z -t mangle 2>/dev/null || true
    iptables -Z -t raw 2>/dev/null || true
}

if [[ "$1" == "--apply" ]]; then
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        t_name=$(basename "$conf" .meta)
        ROLE=""; TUN_PORT=""; TCP_PORTS=""; source "$conf" 2>/dev/null
        
        if [ "$ROLE" == "1" ]; then
            setup_paqet_counters "$t_name" "$TUN_PORT"
        else
            if [ -n "$TCP_PORTS" ]; then
                IFS=',' read -ra P_ARR <<< "$TCP_PORTS"
                for p_clean in "${P_ARR[@]}"; do
                    if [ -n "$p_clean" ] && [ "$p_clean" -le 65535 ]; then
                        setup_paqet_counters "$t_name" "$p_clean"
                    fi
                done
            fi
        fi
    done
    exit 0
fi

get_paqet_rx() {
    local rx=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep "MPAQET_RX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${rx:-0}"
}

get_paqet_tx() {
    local tx=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null | grep "MPAQET_TX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${tx:-0}"
}

check_paqet_connection() {
    local t_name="$1"
    local meta="$CONF_DIR/${t_name}.meta"
    [ ! -f "$meta" ] && { echo "OFFLINE"; return; }
    
    if ! systemctl is-active --quiet "mpaqet@${t_name}" 2>/dev/null; then echo "OFFLINE"; return; fi

    local ROLE=$(grep -m1 "^ROLE=" "$meta" | cut -d'=' -f2 | tr -d '"')
    local TUN_PORT=$(grep -m1 "^TUN_PORT=" "$meta" | cut -d'=' -f2 | tr -d '"')
    
    if [ "$ROLE" == "1" ]; then
        if ss -tn src ":$TUN_PORT" 2>/dev/null | grep -qE "^ESTAB"; then echo "ONLINE"; else echo "WAITING"; fi
    else
        if ss -tn dst ":$TUN_PORT" 2>/dev/null | grep -qE "^ESTAB"; then echo "ONLINE"; else echo "CONNECTING"; fi
    fi
}

get_peer_ping() {
    local target_ip=$(echo "$1" | tr -d ' \n\r')
    local port=$(echo "$2" | tr -d ' \n\r')
    if [ -z "$target_ip" ] || [ "$target_ip" == "0.0.0.0" ]; then echo "N/A"; return; fi
    
    local ping_res=$(ping -c 1 -W 1 "$target_ip" 2>/dev/null)
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
    local s_ip=$(get_local_ip); local total_tunnels=0; local online_tunnels=0; local active_t=0
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            ((total_tunnels++))
            local t_name=$(basename "$conf" .meta)
            if systemctl is-active --quiet "mpaqet@${t_name}" 2>/dev/null; then
                ((active_t++))
                local st=$(check_paqet_connection "$t_name")
                [ "$st" == "ONLINE" ] && ((online_tunnels++))
            fi
        fi
    done
    
    local core_color="${R}"; local core_raw="Not Installed"
    if command -v paqet >/dev/null 2>&1 || [ -f "/usr/local/bin/paqet" ]; then
        core_color="${G}"; core_raw="Installed"
    fi

    local act_color="${DIM}"; local act_text="0/0"
    if [ "$total_tunnels" -gt 0 ]; then
        act_text="${active_t}/${total_tunnels}"
        if [ "$active_t" -eq "$total_tunnels" ]; then act_color="${G}"
        elif [ "$active_t" -gt 0 ]; then act_color="${Y}"
        else act_color="${R}"; fi
    fi

    local stat_color="${R}"; local stat_icon="○"; local stat_text="STOPPED"
    if [ "$active_t" -gt 0 ]; then
        if [ "$online_tunnels" -eq "$active_t" ]; then 
            stat_color="${G}"; stat_icon="●"; stat_text="CONNECTED"
        elif [ "$online_tunnels" -gt 0 ]; then 
            stat_color="${Y}"; stat_icon="◐"; stat_text="PARTIAL"
        else 
            stat_color="${Y}"; stat_icon="◎"; stat_text="WAITING"
        fi
    fi

    local peer_ip=""
    local tmp_port=""
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            local tmp_role=$(grep "^ROLE=" "$conf" | cut -d'=' -f2)
            local tmp_remote=$(grep "^REMOTE_IP=" "$conf" | cut -d'=' -f2)
            tmp_port=$(grep "^TUN_PORT=" "$conf" | cut -d'=' -f2)
            
            if [ -n "$tmp_remote" ] && [ "$tmp_remote" != "0.0.0.0" ]; then
                peer_ip="$tmp_remote"
                break
            elif [ "$tmp_role" == "1" ]; then
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
        local p_val=$(get_peer_ping "$peer_ip" "$tmp_port")
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
        g_color="${DIM}"; g_text="Waiting"
    fi

    local title=" MPaqet Engine v${MODULE_VERSION} "
    local full_str=" │${title}│ IP: ${s_ip} │ Core: ${core_raw} │ Peer Ping: ${g_text} │ ACTIVE: ${act_text} │ STATUS: ${stat_icon} ${stat_text} "
    local pad_len=$(( 126 - ${#full_str} ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${title}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${B}│${NC}${DIM} Core:${NC} ${core_color}${core_raw}${NC} ${B}│${NC}${DIM} Peer Ping:${NC} ${g_color}${g_text}${NC} ${B}│${NC}${DIM} ACTIVE:${NC} ${act_color}${act_text}${NC} ${B}│${NC}${DIM} STATUS:${NC} ${stat_color}${stat_icon} ${stat_text}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

setup_systemd_service() {
    cat <<'EOF' > /etc/systemd/system/mpaqet@.service
[Unit]
Description=MPaqet Raw Packet Tunnel (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/paqet run -c /etc/paqet/%i.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    cat <<'EOF' > /etc/systemd/system/mpaqet-apply.service
[Unit]
Description=MPaqet Boot Restorer
After=network.target

[Service]
ExecStart=/usr/bin/mpaqet --apply
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mpaqet-apply.service >/dev/null 2>&1
}

show_tunnel_registry() {
    draw_header
    echo -e "\n  ${Y}● Deployed Paqet Tunnels Registry:${NC}"
    local count=0
    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        ROLE=""; TUN_PORT=""; REMOTE_IP=""; TCP_PORTS=""
        source "$conf" 2>/dev/null
        
        local yaml_f="$CONF_DIR/${t_name}.yaml"
        [ ! -f "$yaml_f" ] && continue
        
        local key=$(grep "key:" "$yaml_f" | awk -F'"' '{print $2}')
        local mode=$(grep "mode:" "$yaml_f" | awk -F'"' '{print $2}')
        local block=$(grep "block:" "$yaml_f" | awk -F'"' '{print $2}')
        local mtu=$(grep "mtu:" "$yaml_f" | awk '{print $2}')
        local conn_c=$(grep "conn:" "$yaml_f" | head -1 | awk '{print $2}')
        
        local role_text=$([ "$ROLE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local ping_val="N/A"
        local connected_peer=""

        if [ "$ROLE" == "2" ] && [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "0.0.0.0" ]; then
            ping_val=$(get_peer_ping "$REMOTE_IP" "$TUN_PORT")
            connected_peer="$REMOTE_IP"
        elif [ "$ROLE" == "1" ]; then
            local est_conn=$(ss -tn src ":$TUN_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
            if [ -n "$est_conn" ]; then
                local p_ip=$(echo "$est_conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                ping_val=$(get_peer_ping "$p_ip" "$TUN_PORT")
                connected_peer="$p_ip"
            else
                ping_val="Waiting"
            fi
        fi

        local peer_text=$([ "$ROLE" == "1" ] && echo "Listening on :${TUN_PORT}" || echo "${REMOTE_IP}:${TUN_PORT}")
        if [ "$ROLE" == "1" ] && [ -n "$connected_peer" ]; then
            peer_text="${connected_peer}:${TUN_PORT} (Active)"
        fi

        local st=$(check_paqet_connection "$t_name")
        local stat_icon="○"; local stat_text="OFFLINE"; local stat_color="${R}"
        if [ "$st" == "ONLINE" ]; then stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}";
        elif [ "$st" == "WAITING" ]; then stat_icon="◎"; stat_text="WAITING CLIENT"; stat_color="${Y}";
        elif [ "$st" == "CONNECTING" ]; then stat_icon="◎"; stat_text="CONNECTING..."; stat_color="${Y}"; fi

        local rx=$(get_paqet_rx "$t_name"); local tx=$(get_paqet_tx "$t_name")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $t_name"; local right_p="Role: $role_text"
        local pad=$(( 122 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="Link Port    : ${TUN_PORT}"; local r1="Latency: ${ping_val}"
        local pad1=$(( 122 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Link Port    :${NC} ${W}${TUN_PORT}${NC}${sp1}${DIM}Latency:${NC} ${Y}${ping_val}${NC} ${B}│${NC}"
        
        local l2="Peer Target  : ${peer_text}"; local r2="Link State: ${stat_icon} ${stat_text}"
        local clean_r2=$(echo -e "$r2" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
        local pad2=$(( 122 - ${#l2} - ${#clean_r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}Peer Target  :${NC} ${W}${peer_text}${NC}${sp2}${DIM}Link State:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${B}│${NC}"

        local l3="Secret Key   : ${key}"; local r3="Crypto: ${block^^}"
        local pad3=$(( 122 - ${#l3} - ${#r3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${Y}Secret Key   :${NC} ${W}${key}${NC}${sp3}${DIM}Crypto:${NC} ${C}${block^^}${NC} ${B}│${NC}"

        local l4="Traffic Usage: RX $(format_total $rx) / TX $(format_total $tx)"; local r4="Mode: ${mode^^} | MTU: ${mtu} | Conn: ${conn_c}"
        local pad4=$(( 122 - ${#l4} - ${#r4} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Traffic Usage:${NC} ${G}RX $(format_total $rx)${NC} ${DIM}/${NC} ${Y}TX $(format_total $tx)${NC}${sp4}${DIM}${r4}${NC} ${B}│${NC}"
        
        if [ "$ROLE" == "2" ]; then
            local p_str="${TCP_PORTS:0:100}"
            [ ${#TCP_PORTS} -gt 100 ] && p_str="${p_str}..."
            local l5="Port Mappings: ${p_str}"
            local pad5=$(( 122 - ${#l5} )); [ "$pad5" -lt 0 ] && pad5=0; local sp5=$(printf '%*s' "$pad5" "")
            echo -e "  ${B}│${NC} ${DIM}Port Mappings:${NC} ${Y}${p_str}${NC}${sp5} ${B}│${NC}"
        fi
        
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯\n"
        ((count++))
    done
    if [ "$count" -eq 0 ]; then echo -e "  ${R}● No tunnels configured yet!${NC}\n"; fi
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

show_live_radar() {
    tput civis; clear
    declare -A rx_old tx_old

    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        rx_old[$t_name]=$(get_paqet_rx "$t_name")
        tx_old[$t_name]=$(get_paqet_tx "$t_name")
    done

    while true; do
        printf "\033[H"; draw_header
        echo -e "\n  ${DIM}┌─[ PAQET TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL RX" "∑ TOTAL TX"
        echo -e "  ${B}├──────────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤${NC}"

        local count=0
        for conf in "$CONF_DIR"/*.meta; do
            [ ! -f "$conf" ] && continue
            local t_name=$(basename "$conf" .meta)
            local st=$(check_paqet_connection "$t_name")
            local st_color="${R}"; local st_text="OFFLINE"
            if [ "$st" == "ONLINE" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING"; fi

            local r_new=$(get_paqet_rx "$t_name"); local t_new=$(get_paqet_tx "$t_name")
            local r_prev=${rx_old[$t_name]:-$r_new}; local t_prev=${tx_old[$t_name]:-$t_new}
            local rx_s=$((r_new - r_prev)); local tx_s=$((t_new - t_prev))
            [ "$rx_s" -lt 0 ] && rx_s=0; [ "$tx_s" -lt 0 ] && tx_s=0
            rx_old[$t_name]=$r_new; tx_old[$t_name]=$t_new

            local c_rx="${DIM}"; [ "$rx_s" -gt 0 ] && c_rx="${G}"
            local c_tx="${DIM}"; [ "$tx_s" -gt 0 ] && c_tx="${Y}"

            printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} %b%-10s%b ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "$t_name" "$st_color" "$st_text" "$NC" "$c_rx" "$(format_speed $rx_s)" "$NC" "$c_tx" "$(format_speed $tx_s)" "$NC" "$(format_total $r_new)" "$(format_total $t_new)"
            ((count++))
        done

        if [ "$count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" "  No active Paqet tunnels configured."
        fi
        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\e' ]]; then break; fi
    done
    tput cnorm
}

edit_paqet_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.yaml 2>/dev/null))
    [ ${#configs[@]} -eq 0 ] && { echo -e "\n  ${R}● No tunnels configured!${NC}"; sleep 1.5; return; }

    echo -e "\n  ${B}╭────────────────── Select Tunnel to Edit ───────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .yaml)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}● Select Index or 'q': ${NC}"; read t_idx
    t_idx=$(echo "$t_idx" | tr -dc '0-9')
    [[ -z "$t_idx" || -z "${configs[$t_idx]}" ]] && return

    local sel_cfg="${configs[$t_idx]}"
    local old_tname=$(basename "$sel_cfg" .yaml)

    echo -e "\n  ${DIM}┌─[ EDIT PAQET TUNNEL: ${W}${old_tname}${DIM} ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Edit KCP Mode${NC} ${DIM}(normal, fast, fast2, fast3)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Edit MTU Size${NC} ${DIM}(1000-1500)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Edit Connection Count${NC} ${DIM}(conn: 1-32)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Edit Encryption${NC} ${DIM}(aes-128-gcm, aes-256, none)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${W}Rename Tunnel Interface${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read e_opt
    e_opt=$(echo "$e_opt" | tr -dc '0-9')

    case $e_opt in
        1)
           echo -ne "  ${C}● New KCP Mode [normal|fast|fast2|fast3]: ${NC}"; read n_m
           n_m=$(echo "$n_m" | tr -dc 'a-zA-Z0-9')
           if [[ "$n_m" =~ ^(normal|fast|fast2|fast3)$ ]]; then
               sed -i "s|mode:.*|mode: \"$n_m\"|" "$sel_cfg"
           else
               echo -e "  ${R}✖ Invalid Mode!${NC}"; sleep 1.5; return
           fi
           ;;
        2)
           echo -ne "  ${C}● New MTU Size [1000-1500]: ${NC}"; read n_mtu
           n_mtu=$(echo "$n_mtu" | tr -dc '0-9')
           if [[ ! "$n_mtu" =~ ^[0-9]+$ ]] || [ "$n_mtu" -lt 1000 ] || [ "$n_mtu" -gt 1500 ]; then 
               echo -e "  ${R}✖ MTU must be between 1000 and 1500!${NC}"; sleep 1.5; return
           fi
           sed -i "s|mtu:.*|mtu: $n_mtu|" "$sel_cfg"
           ;;
        3)
           echo -ne "  ${C}● New Connections Count [1-32]: ${NC}"; read n_c
           n_c=$(echo "$n_c" | tr -dc '0-9')
           if [[ ! "$n_c" =~ ^[0-9]+$ ]] || [ "$n_c" -lt 1 ] || [ "$n_c" -gt 32 ]; then 
               echo -e "  ${R}✖ Connections must be between 1 and 32!${NC}"; sleep 1.5; return
           fi
           sed -i "s|conn:.*|conn: $n_c|" "$sel_cfg"
           ;;
        4)
           echo -ne "  ${C}● New Encryption Block [aes-128-gcm|aes-256|none]: ${NC}"; read n_b
           n_b=$(echo "$n_b" | tr -dc 'a-zA-Z0-9-')
           if [[ "$n_b" =~ ^(aes-128-gcm|aes-256|none)$ ]]; then
               sed -i "s|block:.*|block: \"$n_b\"|" "$sel_cfg"
           else
               echo -e "  ${R}✖ Invalid Encryption!${NC}"; sleep 1.5; return
           fi
           ;;
        5)
           echo -ne "  ${C}●${NC} ${W}New Tunnel Suffix (Current: ${Y}${old_tname#pq_}${W}, Max 5 chars): ${NC}"; read new_suffix
           new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
           if [ -n "$new_suffix" ]; then
               local new_t_name="pq_${new_suffix}"
               if [ -f "$CONF_DIR/${new_t_name}.yaml" ]; then
                   echo -e "  ${R}● Error: Tunnel [${new_t_name}] already exists!${NC}"; sleep 1.5; return
               fi
               
               systemctl stop "mpaqet@${old_tname}" 2>/dev/null; systemctl disable "mpaqet@${old_tname}" 2>/dev/null
               clean_paqet_counters "$old_tname"
               
               mv "$sel_cfg" "$CONF_DIR/${new_t_name}.yaml"
               mv "$CONF_DIR/${old_tname}.meta" "$CONF_DIR/${new_t_name}.meta" 2>/dev/null
               
               ROLE=""; TUN_PORT=""; TCP_PORTS=""; source "$CONF_DIR/${new_t_name}.meta" 2>/dev/null
               if [ "$ROLE" == "1" ]; then
                   setup_paqet_counters "$new_t_name" "$TUN_PORT"
               else
                   if [ -n "$TCP_PORTS" ]; then
                       IFS=',' read -ra P_ARR <<< "$TCP_PORTS"
                       for p_clean in "${P_ARR[@]}"; do
                           if [ -n "$p_clean" ] && [ "$p_clean" -le 65535 ]; then
                               setup_paqet_counters "$new_t_name" "$p_clean"
                           fi
                       done
                   fi
               fi
               
               old_tname="$new_t_name"
               systemctl enable "mpaqet@${old_tname}" >/dev/null 2>&1
               echo -e "  ${G}● Tunnel successfully renamed to: ${new_t_name}${NC}"
           else
               return
           fi
           ;;
        *) return ;;
    esac

    systemctl restart "mpaqet@${old_tname}" 2>/dev/null
    sleep 1.5
    if systemctl is-active --quiet "mpaqet@${old_tname}"; then
        echo -e "\n  ${G}● Tunnel [${old_tname}] updated and restarted successfully!${NC}"; sleep 2
    else
        echo -e "\n  ${R}✖ Failed to start! Checking logs...${NC}"
        journalctl -u "mpaqet@${old_tname}" -n 5 --no-pager
        echo -ne "  ${DIM}Press Enter...${NC}"; read dummy
    fi
}

install_paqet_silent
setup_systemd_service

render_mpaqet_menu() {
    badge=""
    if [ -f "$SECURE_TMP/.mpaqet_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.mpaqet_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_header
    echo -e "\n  ${DIM}┌─[ DEPLOYMENT & DESTRUCTION ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup Server Tunnel${NC} ${DIM}(Kharej Raw Listener)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Setup Client Tunnel${NC} ${DIM}(Iran Port Forward)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Advanced Edit Tunnel${NC} ${DIM}(Mode/MTU/Conn/Rename)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & DETAILS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Live Traffic & Bandwidth Radar${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${M}View Tunnels Registry & Settings${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${DIM}View Live Service Logs${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${G}Restart Service & Zero Counters${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${M}Install / Update MPaqet Core${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${G}Instant OTA Update (Sync Module)${NC}${badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}

while true; do
    render_mpaqet_menu
    read_with_refresh "  ${C}PAQET ❯❯ ${NC}" opt render_mpaqet_menu
    opt=$(echo "$opt" | tr -dc '0-9')
    
    case $opt in
        1)
           echo -e "\n  ${DIM}┌─[ DEPLOY SERVER TUNNEL ]${NC}"
           echo -ne "  ${C}● Tunnel Suffix Name (e.g. srv1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
           if [ -z "$suffix" ]; then echo -e "  ${R}✖ Invalid Name!${NC}"; sleep 1.5; continue; fi
           
           t_name="pq_${suffix}"
           
           if [ -f "$CONF_DIR/${t_name}.yaml" ]; then
               echo -e "  ${R}✖ Tunnel '${t_name}' already exists! Delete it first or use another name.${NC}"; sleep 2; continue
           fi
           
           iface=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
           [ -z "$iface" ] && iface=$(ip link show | grep -v "lo:" | awk -F': ' '{print $2}' | head -1)
           [ -z "$iface" ] && iface="eth0"
           
           l_ip=$(get_local_ip)
           
           gw_mac=$(ip neigh show dev "$iface" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
           [ -z "$gw_mac" ] && gw_mac=$(ip neigh show 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
           [ -z "$gw_mac" ] && gw_mac="00:00:00:00:00:00"
           
           if [ "$gw_mac" == "00:00:00:00:00:00" ]; then
               echo -e "  ${Y}⚠ Warning: MAC address could not be resolved. Raw packets may fail to route properly!${NC}"
               sleep 2
           fi
           
           while true; do
               echo -ne "  ${C}● Tunnel Listen Port [8888]: ${NC}"; read t_port
               t_port=$(echo "$t_port" | tr -dc '0-9')
               t_port=${t_port:-8888}
               if [ -n "$t_port" ] && [ "$t_port" -le 65535 ]; then break; else echo -e "  ${R}✖ Invalid port!${NC}"; fi
           done
           
           s_key=$(head -c 16 /dev/urandom | xxd -p 2>/dev/null)
           [ -z "$s_key" ] && s_key=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)
           echo -ne "  ${C}● Secret Key [Default ${s_key}]: ${NC}"; read u_key
           u_key=$(echo "$u_key" | tr -dc 'a-zA-Z0-9_=-')
           key=${u_key:-$s_key}
           
           > "$CONF_DIR/${t_name}.yaml.tmp"
           cat <<'EOF' > "$CONF_DIR/${t_name}.yaml.tmp"
role: "server"
log:
  level: "info"
listen:
  addr: ":%PORT%"
network:
  interface: "%IFACE%"
  ipv4:
    addr: "%LIP%:%PORT%"
    router_mac: "%MAC%"
  tcp:
    local_flag: ["PA"]
transport:
  protocol: "kcp"
  conn: 4
  kcp:
    key: "%KEY%"
    mode: "fast"
    block: "aes-128-gcm"
    mtu: 1350
EOF
           sed -e "s|%PORT%|${t_port}|g" \
               -e "s|%IFACE%|${iface}|g" \
               -e "s|%LIP%|${l_ip}|g" \
               -e "s|%MAC%|${gw_mac}|g" \
               -e "s|%KEY%|${key}|g" \
               "$CONF_DIR/${t_name}.yaml.tmp" > "$CONF_DIR/${t_name}.yaml"
           rm -f "$CONF_DIR/${t_name}.yaml.tmp"
           
           echo -e "ROLE=1\nTUN_PORT=$t_port\nREMOTE_IP=0.0.0.0\nTCP_PORTS=" > "$CONF_DIR/${t_name}.meta"
           
           setup_paqet_counters "$t_name" "$t_port"
           systemctl enable "mpaqet@${t_name}" >/dev/null 2>&1
           systemctl restart "mpaqet@${t_name}"
           
           sleep 1.5
           if systemctl is-active --quiet "mpaqet@${t_name}"; then
               echo -e "\n  ${G}● Paqet Server Tunnel Deployed! Key: ${key}${NC}"; sleep 2
           else
               echo -e "\n  ${R}✖ Failed to start! Checking logs...${NC}"
               journalctl -u "mpaqet@${t_name}" -n 5 --no-pager
               echo -ne "  ${DIM}Press Enter...${NC}"; read dummy
           fi
           ;;
           
        2)
           echo -e "\n  ${DIM}┌─[ DEPLOY CLIENT TUNNEL ]${NC}"
           echo -ne "  ${C}● Tunnel Suffix Name (e.g. cl1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
           if [ -z "$suffix" ]; then echo -e "  ${R}✖ Invalid Name!${NC}"; sleep 1.5; continue; fi
           
           t_name="pq_${suffix}"
           
           if [ -f "$CONF_DIR/${t_name}.yaml" ]; then
               echo -e "  ${R}✖ Tunnel '${t_name}' already exists! Delete it first or use another name.${NC}"; sleep 2; continue
           fi
           
           iface=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
           [ -z "$iface" ] && iface=$(ip link show | grep -v "lo:" | awk -F': ' '{print $2}' | head -1)
           [ -z "$iface" ] && iface="eth0"
           
           l_ip=$(get_local_ip)
           
           gw_mac=$(ip neigh show dev "$iface" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
           [ -z "$gw_mac" ] && gw_mac=$(ip neigh show 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
           [ -z "$gw_mac" ] && gw_mac="00:00:00:00:00:00"
           
           if [ "$gw_mac" == "00:00:00:00:00:00" ]; then
               echo -e "  ${Y}⚠ Warning: MAC address could not be resolved. Raw packets may fail to route properly!${NC}"
               sleep 2
           fi
           
           while true; do
               echo -ne "  ${C}● Remote Kharej Server IP: ${NC}"; read r_ip
               r_ip=$(echo "$r_ip" | tr -dc '0-9.')
               if [[ "$r_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then break; else echo -e "  ${R}✖ Invalid IPv4 format!${NC}"; fi
           done
           
           while true; do
               echo -ne "  ${C}● Remote Listen Port [8888]: ${NC}"; read r_port
               r_port=$(echo "$r_port" | tr -dc '0-9')
               r_port=${r_port:-8888}
               if [ -n "$r_port" ] && [ "$r_port" -le 65535 ]; then break; else echo -e "  ${R}✖ Invalid port!${NC}"; fi
           done
           
           echo -ne "  ${C}● Secret Key (from Server): ${NC}"; read key
           key=$(echo "$key" | tr -dc 'a-zA-Z0-9_=-')
           
           fwd_ports=""
           while true; do
               echo -ne "  ${C}● Forward Ports (e.g. 443,8080): ${NC}"; read fwd_ports
               fwd_ports=$(echo "$fwd_ports" | tr -dc '0-9,')
               if [ -z "$fwd_ports" ]; then
                   echo -e "  ${R}Error: MUST specify at least one forwarded port!${NC}"
               else
                   break
               fi
           done
           
           if echo ",$fwd_ports," | grep -q ",$r_port,"; then
               echo -e "  ${R}✖ Loop Error: Forward port cannot match Tunnel port ($r_port)!${NC}"; sleep 2; continue
           fi
           
           > "$CONF_DIR/${t_name}.yaml.tmp"
           cat <<'EOF' > "$CONF_DIR/${t_name}.yaml.tmp"
role: "client"
log:
  level: "info"
forward:
EOF
           IFS=',' read -ra P_ARR <<< "$fwd_ports"
           local meta_ports=""
           for p_raw in "${P_ARR[@]}"; do
               p_clean=$(echo "$p_raw" | tr -dc '0-9')
               if [ -n "$p_clean" ] && [ "$p_clean" -le 65535 ]; then
                   echo "  - listen: \"0.0.0.0:$p_clean\"" >> "$CONF_DIR/${t_name}.yaml.tmp"
                   echo "    target: \"127.0.0.1:$p_clean\"" >> "$CONF_DIR/${t_name}.yaml.tmp"
                   echo "    protocol: \"tcp\"" >> "$CONF_DIR/${t_name}.yaml.tmp"
                   setup_paqet_counters "$t_name" "$p_clean"
                   meta_ports="${meta_ports}${p_clean},"
               fi
           done
           
           cat <<'EOF' >> "$CONF_DIR/${t_name}.yaml.tmp"
network:
  interface: "%IFACE%"
  ipv4:
    addr: "%LIP%:0"
    router_mac: "%MAC%"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
server:
  addr: "%RIP%:%RPORT%"
transport:
  protocol: "kcp"
  conn: 4
  kcp:
    key: "%KEY%"
    mode: "fast"
    block: "aes-128-gcm"
    mtu: 1350
EOF
           sed -e "s|%IFACE%|${iface}|g" \
               -e "s|%LIP%|${l_ip}|g" \
               -e "s|%MAC%|${gw_mac}|g" \
               -e "s|%RIP%|${r_ip}|g" \
               -e "s|%RPORT%|${r_port}|g" \
               -e "s|%KEY%|${key}|g" \
               "$CONF_DIR/${t_name}.yaml.tmp" > "$CONF_DIR/${t_name}.yaml"
           rm -f "$CONF_DIR/${t_name}.yaml.tmp"

           echo -e "ROLE=2\nTUN_PORT=$r_port\nREMOTE_IP=$r_ip\nTCP_PORTS=${meta_ports%,}" > "$CONF_DIR/${t_name}.meta"

           systemctl enable "mpaqet@${t_name}" >/dev/null 2>&1
           systemctl restart "mpaqet@${t_name}"
           
           sleep 1.5
           if systemctl is-active --quiet "mpaqet@${t_name}"; then
               echo -e "\n  ${G}● Paqet Client Tunnel Deployed!${NC}"; sleep 2
           else
               echo -e "\n  ${R}✖ Failed to start! Checking logs...${NC}"
               journalctl -u "mpaqet@${t_name}" -n 5 --no-pager
               echo -ne "  ${DIM}Press Enter...${NC}"; read dummy
           fi
           ;;

        3) edit_paqet_tunnel ;;
        4) show_live_radar ;;
        5)
           configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"; done
           echo -ne "  ${C}● Enter Index or 'all': ${NC}"; read del_idx
           del_idx=$(echo "$del_idx" | tr -dc '0-9a-zA-Z')
           
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do
                   t_name=$(basename "$conf" .meta)
                   systemctl stop "mpaqet@${t_name}" 2>/dev/null; systemctl disable "mpaqet@${t_name}" 2>/dev/null
                   clean_paqet_counters "$t_name"
                   rm -f "$conf" "$CONF_DIR/${t_name}.yaml"
               done
               echo -e "  ${G}● All Tunnels Purged!${NC}"; sleep 1.5
           elif [[ "$del_idx" =~ ^[0-9]+$ ]] && [[ -n "${configs[$del_idx]}" ]]; then
               t_name=$(basename "${configs[$del_idx]}" .meta)
               systemctl stop "mpaqet@${t_name}" 2>/dev/null; systemctl disable "mpaqet@${t_name}" 2>/dev/null
               clean_paqet_counters "$t_name"
               rm -f "${configs[$del_idx]}" "$CONF_DIR/${t_name}.yaml"
               echo -e "  ${G}● Purged!${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Invalid Selection!${NC}"; sleep 1.5
           fi ;;
        6) show_tunnel_registry ;;
        7) 
           configs=($(ls "$CONF_DIR"/*.yaml 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel for Logs ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .yaml)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}● Select Index: ${NC}"; read l_idx
           if [[ -n "${configs[$l_idx]}" ]]; then
               journalctl -u "mpaqet@$(basename "${configs[$l_idx]}" .yaml)" -n 50 -f
           fi ;;
        8) zero_paqet_counters; systemctl restart mpaqet@* 2>/dev/null; echo -e "  ${G}● Services restarted and traffic counters zeroed.${NC}"; sleep 1.5 ;;
        9) menu_install_core ;;
        10) self_update_module ;;
        0) break ;;
    esac
done
