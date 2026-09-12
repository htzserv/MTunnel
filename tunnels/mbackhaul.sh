#!/bin/bash
# --- MBackhaul Modular Core (mbackhaul.sh) | MDesign Ecosystem v1.7.18 ---
# [Features: Refined Spacing | Async Background Checker | Minimal Badges]

MODULE_VERSION="1.9.0"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mbackhaul"
CONF_DIR="/etc/mbackhaul/tunnels"
CERT_DIR="/etc/mbackhaul/certs"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mbackhaul" ] && rm -f "/usr/local/bin/mbackhaul" 2>/dev/null

mkdir -p "$CONF_DIR" "$CERT_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
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
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tunnels/mbackhaul.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tunnels/mbackhaul.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mbackhaul_remote_ver"
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
# ---------------------------------------

self_update_module() {
    local rel_path="tunnels/mbackhaul.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mbackhaul_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mbackhaul_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (MBackhaul) ]${NC}"
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
    
    local tmp_file="$SECURE_TMP/.mbackhaul_update.$$"
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

apply_bbr_optimization() {
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
}

generate_ssl_cert() {
    if [[ ! -f "$CERT_DIR/wssmux.crt" ]] || [[ ! -f "$CERT_DIR/wssmux.key" ]]; then
        openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/wssmux.key" \
            -out "$CERT_DIR/wssmux.crt" -days 3650 -nodes \
            -subj "/CN=mdesign-backhaul" \
            -addext "subjectAltName=DNS:mdesign-backhaul,IP:127.0.0.1" >/dev/null 2>&1
    fi
}

menu_install_core() {
    echo -e "\n  ${DIM}┌─[ INSTALL / UPDATE BACKHAUL CORE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/bh)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r')

    [[ "$src_choice" == "q" ]] && return

    echo -e "  ${R}● Purging old Backhaul binaries and processes...${NC}"
    systemctl stop mbackhaul@* 2>/dev/null
    killall -9 bh 2>/dev/null
    rm -f /usr/local/bin/bh /usr/bin/bh "$SECURE_TMP/bh_dl" "$SECURE_TMP/backhaul" "$SECURE_TMP/bh"

    if [[ "$src_choice" == "1" || "$src_choice" == "2" ]]; then
        echo -e "  ${DIM}● Downloading latest binary...${NC}"
        local arch=$(uname -m)
        local target="backhaul_linux_amd64.tar.gz"
        [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="backhaul_linux_arm64.tar.gz"
        
        local dl_url="https://github.com/Musixal/Backhaul/releases/latest/download/${target}"
        [ "$src_choice" == "2" ] && dl_url="https://c107328.parspack.net/c107328/MTunnel/packages/${target}"

        local dl_ok=false
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 10 --max-time 60 -o "$SECURE_TMP/bh_dl" "$dl_url" 2>/dev/null && dl_ok=true
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 -O "$SECURE_TMP/bh_dl" "$dl_url" 2>/dev/null && dl_ok=true
        fi

        if [ "$dl_ok" = true ] && [ -s "$SECURE_TMP/bh_dl" ]; then
            tar -xzf "$SECURE_TMP/bh_dl" -C "$SECURE_TMP/" >/dev/null 2>&1
            [ -f "$SECURE_TMP/backhaul" ] && mv "$SECURE_TMP/backhaul" /usr/local/bin/bh 2>/dev/null
            [ -f "$SECURE_TMP/bh" ] && mv "$SECURE_TMP/bh" /usr/local/bin/bh 2>/dev/null
            chmod +x /usr/local/bin/bh 2>/dev/null || true
            echo -e "  ${G}✔ Backhaul Core installed successfully.${NC}"
        else
            echo -e "  ${R}✖ Download failed!${NC}"
        fi

    elif [[ "$src_choice" == "3" ]]; then
        echo -ne "  ${C}● Enter Direct Link: ${NC}"; read custom_url
        custom_url=$(echo "$custom_url" | tr -d '\r')
        if [ -n "$custom_url" ]; then
            echo -e "  ${DIM}● Downloading from Custom Link...${NC}"
            wget -q --timeout=15 -O "$SECURE_TMP/bh_dl" "$custom_url" 2>/dev/null
            if [ -s "$SECURE_TMP/bh_dl" ]; then
                if gzip -t "$SECURE_TMP/bh_dl" 2>/dev/null; then
                    tar -xzf "$SECURE_TMP/bh_dl" -C "$SECURE_TMP/" >/dev/null 2>&1
                    [ -f "$SECURE_TMP/backhaul" ] && mv "$SECURE_TMP/backhaul" /usr/local/bin/bh 2>/dev/null
                    [ -f "$SECURE_TMP/bh" ] && mv "$SECURE_TMP/bh" /usr/local/bin/bh 2>/dev/null
                else
                    mv "$SECURE_TMP/bh_dl" /usr/local/bin/bh
                fi
                chmod +x /usr/local/bin/bh 2>/dev/null || true
                echo -e "  ${G}✔ Backhaul Core installed from custom link.${NC}"
            else
                echo -e "  ${R}✖ Download failed! Check the link.${NC}"
            fi
        fi

    elif [[ "$src_choice" == "4" ]]; then
        if [ -s "$LOCAL_DIR/packages/bh" ]; then
            cp "$LOCAL_DIR/packages/bh" /usr/local/bin/bh
            chmod +x /usr/local/bin/bh
            echo -e "  ${G}✔ Backhaul Core restored from Local Directory.${NC}"
        else
            echo -e "  ${R}✖ File not found in $LOCAL_DIR/packages/bh!${NC}"
        fi
    fi

    [ -f "/usr/local/bin/bh" ] && ln -sf /usr/local/bin/bh /usr/bin/bh 2>/dev/null
    rm -f "$SECURE_TMP/bh_dl" "$SECURE_TMP/backhaul" "$SECURE_TMP/bh" 2>/dev/null
    systemctl start mbackhaul@* 2>/dev/null
    sleep 2
}

install_backhaul_silent() {
    if ! command -v bh >/dev/null 2>&1 && [ ! -f "/usr/local/bin/bh" ]; then
        local arch=$(uname -m)
        local target="backhaul_linux_amd64.tar.gz"
        [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ] && target="backhaul_linux_arm64.tar.gz"
        local dl_url="https://github.com/Musixal/Backhaul/releases/latest/download/${target}"
        local mirror_url="https://c107328.parspack.net/c107328/MTunnel/packages/${target}"
        
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 8 --max-time 40 -o "$SECURE_TMP/bh.tar.gz" "$dl_url" 2>/dev/null || curl -fsSL --connect-timeout 8 --max-time 40 -o "$SECURE_TMP/bh.tar.gz" "$mirror_url" 2>/dev/null
        else
            wget -q --timeout=12 -O "$SECURE_TMP/bh.tar.gz" "$dl_url" 2>/dev/null || wget -q --timeout=12 -O "$SECURE_TMP/bh.tar.gz" "$mirror_url" 2>/dev/null
        fi

        if [ -s "$SECURE_TMP/bh.tar.gz" ]; then
            tar -xzf "$SECURE_TMP/bh.tar.gz" -C "$SECURE_TMP/" >/dev/null 2>&1
            [ -f "$SECURE_TMP/backhaul" ] && mv "$SECURE_TMP/backhaul" /usr/local/bin/bh 2>/dev/null
            [ -f "$SECURE_TMP/bh" ] && mv "$SECURE_TMP/bh" /usr/local/bin/bh 2>/dev/null
            chmod +x /usr/local/bin/bh 2>/dev/null
            rm -f "$SECURE_TMP/bh.tar.gz"
        fi
    fi
    [ -f "/usr/local/bin/bh" ] && ln -sf /usr/local/bin/bh /usr/bin/bh 2>/dev/null
}

setup_bh_counters() {
    local name="$1"; local l_port="$2"; local r_ip="$3"; local role="$4"
    if [ "$role" == "1" ]; then
        iptables -t mangle -C INPUT -p tcp --dport "$l_port" -m comment --comment "MBH_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -p tcp --dport "$l_port" -m comment --comment "MBH_RX_${name}" 2>/dev/null
        iptables -t mangle -C OUTPUT -p tcp --sport "$l_port" -m comment --comment "MBH_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -p tcp --sport "$l_port" -m comment --comment "MBH_TX_${name}" 2>/dev/null
    else
        if [ -n "$r_ip" ] && [ "$r_ip" != "0.0.0.0" ]; then
            iptables -t mangle -C INPUT -s "$r_ip" -p tcp --sport "$l_port" -m comment --comment "MBH_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -s "$r_ip" -p tcp --sport "$l_port" -m comment --comment "MBH_RX_${name}" 2>/dev/null
            iptables -t mangle -C OUTPUT -d "$r_ip" -p tcp --dport "$l_port" -m comment --comment "MBH_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -d "$r_ip" -p tcp --dport "$l_port" -m comment --comment "MBH_TX_${name}" 2>/dev/null
        fi
    fi
}

clean_bh_counters() {
    local name="$1"
    iptables -t mangle -S INPUT 2>/dev/null | grep "MBH_RX_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t mangle $r 2>/dev/null; done
    iptables -t mangle -S OUTPUT 2>/dev/null | grep "MBH_TX_${name}" | sed 's/^-A /-D /' | while read -r r; do iptables -t mangle $r 2>/dev/null; done
}

zero_bh_counters() {
    local name="$1"
    iptables -Z -t mangle 2>/dev/null || true
}

if [[ "$1" == "--apply" ]]; then
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        t_name=$(basename "$conf" .meta)
        ROLE=""; TUN_PORT=""; REMOTE_IP=""; source "$conf" 2>/dev/null
        setup_bh_counters "$t_name" "$TUN_PORT" "$REMOTE_IP" "$ROLE"
    done
    exit 0
fi

get_bh_rx() {
    local rx=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep "MBH_RX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${rx:-0}"
}

get_bh_tx() {
    local tx=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null | grep "MBH_TX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${tx:-0}"
}

check_bh_connection() {
    local t_name="$1"
    local known_active="$2"
    local meta="$CONF_DIR/${t_name}.meta"
    [ ! -f "$meta" ] && { echo "OFFLINE"; return; }
    
    ROLE=""; TUN_PORT=""; REMOTE_IP=""; source "$meta" 2>/dev/null
    if [ "$known_active" != "1" ] && ! systemctl is-active --quiet "mbackhaul@${t_name}" 2>/dev/null; then echo "OFFLINE"; return; fi

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
    
    # 1. Native ICMP Ping
    local ping_res=$(timeout 2 ping -c 1 -W 1 "$target_ip" 2>/dev/null)
    if echo "$ping_res" | grep -q "time="; then
        local ping_val=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+' | awk '{print int($1+0.5)}')
        echo "${ping_val}ms"
        return
    fi
    
    # 2. Kernel Socket Extraction (ss 1.7.8 Fallback)
    if command -v ss >/dev/null 2>&1; then
        local tcp_rtt=$(ss -nti | grep -A 1 "$target_ip" | grep -oP 'rtt:\K[0-9.]+' | head -n 1)
        if [ -n "$tcp_rtt" ]; then
            local rounded_rtt=$(echo "$tcp_rtt" | awk '{print int($1+0.5)}')
            echo "${rounded_rtt}ms*"
            return
        fi
    fi

    # 3. Bash TCP Ping (Ultimate Fallback)
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

write_bh_config() {
    local name="$(echo "$1" | tr -d '\r\n')"
    local role="$(echo "$2" | tr -d '\r\n')"
    local transport="$(echo "$3" | tr -d '\r\n')"
    local port="$(echo "$4" | tr -d '\r\n')"
    local r_ip="$(echo "$5" | tr -d '\r\n')"
    local token="$(echo "$6" | tr -d '\r\n' | sed 's/"/\\"/g')"
    local ports_str="$(echo "$7" | tr -d '\r\n')"

    local toml="$CONF_DIR/${name}.toml"
    local meta="$CONF_DIR/${name}.meta"

    echo "ROLE=$role" > "$meta"
    echo "TRANSPORT=$transport" >> "$meta"
    echo "TUN_PORT=$port" >> "$meta"
    echo "REMOTE_IP=$r_ip" >> "$meta"
    echo "TOKEN=$token" >> "$meta"
    echo "PORTS=$ports_str" >> "$meta"

    [ -z "$role" ] && role="1"
    [ -z "$transport" ] && transport="tcp"
    [ -z "$port" ] && port="8443"
    [ -z "$token" ] && token="mdesign_token"

    > "$toml"

    if [ "$role" == "1" ]; then
        echo "[server]" >> "$toml"
        echo "bind_addr = \"0.0.0.0:${port}\"" >> "$toml"
        echo "transport = \"${transport}\"" >> "$toml"
        [ "$transport" == "tcp" ] && echo "accept_udp = false" >> "$toml"
        echo "token = \"${token}\"" >> "$toml"
        echo "keepalive_period = 75" >> "$toml"
        echo "nodelay = true" >> "$toml"
        echo "heartbeat = 40" >> "$toml"
        echo "channel_size = 4096" >> "$toml"
        
        if [ "$transport" != "tcp" ]; then
            echo "mux_con = 8" >> "$toml"
            echo "mux_version = 1" >> "$toml"
            echo "mux_framesize = 32768" >> "$toml"
            echo "mux_recievebuffer = 4194304" >> "$toml"
            echo "mux_streambuffer = 65536" >> "$toml"
        fi
        
        if [ "$transport" == "tcp" ] || [ "$transport" == "tcpmux" ]; then
            echo "mss = 1360" >> "$toml"
            echo "so_rcvbuf = 4194304" >> "$toml"
            echo "so_sndbuf = 4194304" >> "$toml"
        fi
        
        if [ "$transport" == "wssmux" ]; then
            generate_ssl_cert
            echo "tls_cert = \"${CERT_DIR}/wssmux.crt\"" >> "$toml"
            echo "tls_key = \"${CERT_DIR}/wssmux.key\"" >> "$toml"
        fi
        
        echo "sniffer = false" >> "$toml"
        echo "web_port = 0" >> "$toml"
        echo "log_level = \"info\"" >> "$toml"
        
        local port_lines=""
        if [ -n "$ports_str" ]; then
            IFS=',' read -ra P_ARR <<< "$ports_str"
            for p_raw in "${P_ARR[@]}"; do
                local p_clean=$(echo "$p_raw" | tr -d ' ' | tr -d '\r' | tr -d '\n')
                if [ -n "$p_clean" ]; then
                    if [[ "$p_clean" =~ ^[0-9]+$ ]]; then p_clean="${p_clean}=127.0.0.1:${p_clean}"; fi
                    if [ -z "$port_lines" ]; then
                        port_lines="\"${p_clean}\""
                    else
                        port_lines="${port_lines}, \"${p_clean}\""
                    fi
                fi
            done
        fi
        [ -z "$port_lines" ] && port_lines="\"65535=127.0.0.1:65535\""
        
        echo "ports = [ ${port_lines} ]" >> "$toml"

    else
        echo "[client]" >> "$toml"
        echo "remote_addr = \"${r_ip}:${port}\"" >> "$toml"
        if [ "$transport" == "wsmux" ] || [ "$transport" == "wssmux" ]; then
            echo "edge_ip = \"\"" >> "$toml"
        fi
        echo "transport = \"${transport}\"" >> "$toml"
        echo "token = \"${token}\"" >> "$toml"
        echo "connection_pool = 8" >> "$toml"
        echo "aggressive_pool = false" >> "$toml"
        echo "keepalive_period = 75" >> "$toml"
        echo "nodelay = true" >> "$toml"
        echo "retry_interval = 3" >> "$toml"
        echo "dial_timeout = 10" >> "$toml"
        
        if [ "$transport" != "tcp" ]; then
            echo "mux_version = 1" >> "$toml"
            echo "mux_framesize = 32768" >> "$toml"
            echo "mux_recievebuffer = 4194304" >> "$toml"
            echo "mux_streambuffer = 65536" >> "$toml"
        fi
        
        if [ "$transport" == "tcp" ] || [ "$transport" == "tcpmux" ]; then
            echo "mss = 1360" >> "$toml"
            echo "so_rcvbuf = 4194304" >> "$toml"
            echo "so_sndbuf = 4194304" >> "$toml"
        fi
        
        echo "sniffer = false" >> "$toml"
        echo "web_port = 0" >> "$toml"
        echo "log_level = \"info\"" >> "$toml"
    fi

    setup_bh_counters "$name" "$port" "$r_ip" "$role"
}

setup_systemd_service() {
    cat <<'EOF' > /etc/systemd/system/mbackhaul@.service
[Unit]
Description=MBackhaul Multi-Multiplexer (%i)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/bh -c /etc/mbackhaul/tunnels/%i.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    cat <<'EOF' > /etc/systemd/system/mbackhaul-apply.service
[Unit]
Description=MBackhaul Boot Restorer
After=network.target

[Service]
ExecStart=/usr/bin/mbackhaul --apply
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mbackhaul-apply.service >/dev/null 2>&1
}

draw_header() {
    local s_ip=$(get_local_ip); local total_t=0; local active_t=0; local online_t=0
    local t_names=() units=()
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            local t_name=$(basename "$conf" .meta)
            t_names+=("$t_name"); units+=("mbackhaul@$t_name")
        fi
    done
    total_t=${#t_names[@]}
    if [ "$total_t" -gt 0 ]; then
        local states=() i=0
        while IFS= read -r st_line; do states+=("$st_line"); done < <(systemctl is-active "${units[@]}" 2>/dev/null)
        for t_name in "${t_names[@]}"; do
            if [ "${states[$i]}" == "active" ]; then
                ((active_t++))
                local st=$(check_bh_connection "$t_name" "1")
                [ "$st" == "ONLINE" ] && ((online_t++))
            fi
            ((i++))
        done
    fi

    local core_color="${R}"; local core_raw="Not Installed"
    if command -v bh >/dev/null 2>&1 || [ -f "/usr/local/bin/bh" ]; then
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
        local ping_cache="$SECURE_TMP/.mbackhaul_ping_cache"
        local ping_lock="$SECURE_TMP/.mbackhaul_ping_lock"
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

    local title=" MBackhaul Engine v${MODULE_VERSION} "
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
    echo -e "\n  ${Y}● Deployed Backhaul Tunnels Registry:${NC}"
    local count=0
    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""
        source "$conf" 2>/dev/null
        
        local role_text=$([ "$ROLE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local ping_val="N/A"
        local connected_peer=""

        if [ "$ROLE" == "2" ] && [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "0.0.0.0" ]; then
            ping_val=$(get_peer_ping "$REMOTE_IP" "$TUN_PORT")
            connected_peer="$REMOTE_IP"
        elif [ "$ROLE" == "1" ]; then
            local conn=$(ss -tn src ":$TUN_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
            if [ -n "$conn" ]; then
                local p_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
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

        local st=$(check_bh_connection "$t_name")
        local stat_icon="○"; local stat_text="OFFLINE"; local stat_color="${R}"
        if [ "$st" == "ONLINE" ]; then stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}";
        elif [ "$st" == "WAITING" ]; then stat_icon="◎"; stat_text="WAITING CLIENT"; stat_color="${Y}";
        elif [ "$st" == "CONNECTING" ]; then stat_icon="◎"; stat_text="CONNECTING..."; stat_color="${Y}"; fi

        local rx=$(get_bh_rx "$t_name"); local tx=$(get_bh_tx "$t_name")

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

        local l3="Auth Token   : ${TOKEN}"; local r3="Protocol: ${TRANSPORT^^}"
        local pad3=$(( 122 - ${#l3} - ${#r3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${Y}Auth Token   :${NC} ${W}${TOKEN}${NC}${sp3}${DIM}Protocol:${NC} ${C}${TRANSPORT^^}${NC} ${B}│${NC}"

        local l4="Traffic Usage: RX $(format_total $rx) / TX $(format_total $tx)"
        local pad4=$(( 122 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Traffic Usage:${NC} ${G}RX $(format_total $rx)${NC} ${DIM}/${NC} ${Y}TX $(format_total $tx)${NC}${sp4} ${B}│${NC}"
        
        if [ "$ROLE" == "1" ]; then
            local p_str="${PORTS:0:100}"
            [ ${#PORTS} -gt 100 ] && p_str="${p_str}..."
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
        source "$conf" 2>/dev/null
        setup_bh_counters "$t_name" "$TUN_PORT" "$REMOTE_IP" "$ROLE"
        rx_old[$t_name]=$(get_bh_rx "$t_name")
        tx_old[$t_name]=$(get_bh_tx "$t_name")
    done

    while true; do
        printf "\033[H"; draw_header
        echo -e "\n  ${DIM}┌─[ BACKHAUL TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────────┬────────────────┬──────────────────┬──────────────────┬────────────────────┬────────────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} ${W}%-14s${NC} ${B}│${NC} ${C}%-16s${NC} ${B}│${NC} ${M}%-16s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL RX" "∑ TOTAL TX"
        echo -e "  ${B}├──────────────────────┼────────────────┼──────────────────┼──────────────────┼────────────────────┼────────────────────┤${NC}"

        local count=0
        for conf in "$CONF_DIR"/*.meta; do
            [ ! -f "$conf" ] && continue
            local t_name=$(basename "$conf" .meta)
            local st=$(check_bh_connection "$t_name")
            local st_color="${R}"; local st_text="OFFLINE"
            if [ "$st" == "ONLINE" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING"; fi

            local r_new=$(get_bh_rx "$t_name"); local t_new=$(get_bh_tx "$t_name")
            local r_prev=${rx_old[$t_name]:-$r_new}; local t_prev=${tx_old[$t_name]:-$t_new}
            local rx_s=$((r_new - r_prev)); local tx_s=$((t_new - t_prev))
            [ "$rx_s" -lt 0 ] && rx_s=0; [ "$tx_s" -lt 0 ] && tx_s=0
            rx_old[$t_name]=$r_new; tx_old[$t_name]=$t_new

            local c_rx="${DIM}"; [ "$rx_s" -gt 0 ] && c_rx="${G}"
            local c_tx="${DIM}"; [ "$tx_s" -gt 0 ] && c_tx="${Y}"

            printf "  ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} %b%-14s%b ${B}│${NC} %b%-16s%b ${B}│${NC} %b%-16s%b ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC}\n" "$t_name" "$st_color" "$st_text" "$NC" "$c_rx" "$(format_speed $rx_s)" "$NC" "$c_tx" "$(format_speed $tx_s)" "$NC" "$(format_total $r_new)" "$(format_total $t_new)"
            ((count++))
        done

        if [ "$count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-120s${NC} ${B}│${NC}\n" "  No active Backhaul tunnels configured."
        fi
        echo -e "  ${B}╰──────────────────────┴────────────────┴──────────────────┴──────────────────┴────────────────────┴────────────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\e' ]]; then break; fi
    done
    tput cnorm
}

manage_cron() {
    local t_name="$1"
    local cron_script="$CONF_DIR/${t_name}_restart.sh"
    
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
        echo "systemctl kill -s SIGKILL mbackhaul@${t_name}" >> "$cron_script"
        echo "systemctl restart mbackhaul@${t_name}" >> "$cron_script"
        chmod +x "$cron_script"
        
        local cron_tmp="$SECURE_TMP/crontab.$$"
        crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
        echo "0 */${interval} * * * $cron_script #mbackhaul@${t_name}" >> "$cron_tmp"
        crontab "$cron_tmp"; rm -f "$cron_tmp"
        echo -e "  ${G}✔ Cronjob added: Tunnel will restart every ${interval} hours.${NC}"; sleep 2
    elif [[ "$cr_opt" == "2" ]]; then
        local cron_tmp="$SECURE_TMP/crontab.$$"
        crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
        crontab "$cron_tmp"; rm -f "$cron_tmp"
        rm -f "$cron_script"
        echo -e "  ${G}✔ Cronjob removed.${NC}"; sleep 1.5
    fi
}

select_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; fi
    
    echo -e "\n  ${B}╭────────────────── Select Tunnel to Manage ─────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r')
    if [[ "$t_idx" == "q" || -z "$t_idx" || -z "${configs[$t_idx]}" ]]; then return 1; fi
    
    SELECTED_TUN="${configs[$t_idx]}"
    return 0
}

install_backhaul_silent
setup_systemd_service
apply_bbr_optimization

render_mbackhaul_menu() {
    badge=""
    if [ -f "$SECURE_TMP/.mbackhaul_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.mbackhaul_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_header
    echo -e "\n  ${DIM}┌─[ DEPLOYMENT & DESTRUCTION ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Deploy New Backhaul Tunnel${NC} ${DIM}(TCP / MUX / WSS)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC} ${DIM}(Specific / ALL)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Edit Remote Host / IP Address${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Edit Port Mappings${NC} ${DIM}(Iran Server)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Change Transport Protocol${NC} ${DIM}(Hot-Swap)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${W}Rename Tunnel Interface${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & DETAILS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${C}Live Traffic & Bandwidth Radar${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${W}View Tunnels Registry & Settings${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${DIM}View Live Service Logs${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${Y}Anti-Freeze Cronjob Manager${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${G}Restart Service & Zero Counters${NC}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${M}Install / Update Core Binary${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC}${DIM}❯${NC} ${G}Instant OTA Update (Sync Module)${NC}${badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}

while true; do
    render_mbackhaul_menu
    read_with_refresh "  ${C}MBACKHAUL ❯❯ ${NC}" opt render_mbackhaul_menu
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
               echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}TCP${NC} | ${W}2${NC} ${DIM}❯${NC} ${C}TCPMUX${NC} | ${W}3${NC} ${DIM}❯${NC} ${M}WSMUX${NC} | ${W}4${NC} ${DIM}❯${NC} ${G}WSSMUX (TLS)${NC}"
               echo -ne "  ${C}● Transport Protocol [1-4]: ${NC}"; read tr_choice
               tr_choice=$(echo "$tr_choice" | tr -d '\r')
               [[ "$tr_choice" =~ ^[1-4]$ ]] && break
           done
           
           tr_val="tcp"
           case $tr_choice in 1) tr_val="tcp" ;; 2) tr_val="tcpmux" ;; 3) tr_val="wsmux" ;; 4) tr_val="wssmux" ;; esac
           
           echo -ne "  ${C}● Tunnel Suffix Name (e.g. bh1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
           t_name="bh_${suffix}"
           
           def_p=8443; [ "$tr_val" == "tcpmux" ] && def_p=9443; [ "$tr_val" == "wssmux" ] && def_p=9743
           echo -ne "  ${C}● Tunnel Link Port [Default ${def_p}]: ${NC}"; read t_port
           t_port=$(echo "$t_port" | tr -dc '0-9')
           t_port=${t_port:-$def_p}
           
           r_ip="0.0.0.0"
           if [ "$s_type" == "2" ]; then
               while true; do
                   echo -ne "  ${C}● Iran Server Host/IP: ${NC}"; read r_ip
                   r_ip=$(echo "$r_ip" | tr -d '\r')
                   is_valid_host "$r_ip" && break
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"
               done
           fi
           
           gen_tok=$(head -c 8 /dev/urandom | xxd -p)
           echo -ne "  ${C}● Auth Token [Default ${gen_tok}]: ${NC}"; read u_tok
           u_tok=$(echo "$u_tok" | tr -dc 'a-zA-Z0-9_-')
           tok=${u_tok:-$gen_tok}
           
           fwd_ports=""
           if [ "$s_type" == "1" ]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Forward Ports (e.g. 443=127.0.0.1:443): ${NC}"; read fwd_ports
                   fwd_ports=$(echo "$fwd_ports" | tr -d '\r')
                   if [ -z "$fwd_ports" ]; then
                       echo -e "  ${R}Error: IRAN Server MUST have at least one forwarded port!${NC}"
                   else
                       break
                   fi
               done
           fi
           
           write_bh_config "$t_name" "$s_type" "$tr_val" "$t_port" "$r_ip" "$tok" "$fwd_ports"
           systemctl enable "mbackhaul@${t_name}" >/dev/null 2>&1
           systemctl restart "mbackhaul@${t_name}"
           echo -e "  ${G}● Backhaul Tunnel Deployed Successfully!${NC}"; sleep 2 ;;
           
        2)
           configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Delete ─────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}Index (or 'all' / 'q'): ${NC}"; read del_idx
           del_idx=$(echo "$del_idx" | tr -d '\r')
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do
                   t_name=$(basename "$conf" .meta)
                   systemctl stop mbackhaul@$t_name 2>/dev/null; systemctl disable mbackhaul@$t_name 2>/dev/null
                   clean_bh_counters "$t_name"
                   local cron_tmp="$SECURE_TMP/crontab.$$"
                   crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
                   crontab "$cron_tmp"; rm -f "$cron_tmp"
                   rm -f "$conf" "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${t_name}_restart.sh"
               done
               echo -e "  ${G}All Tunnels Purged!${NC}"; sleep 1.5
           elif [[ -n "${configs[$del_idx]}" ]]; then
               t_name=$(basename "${configs[$del_idx]}" .meta)
               systemctl stop mbackhaul@$t_name 2>/dev/null; systemctl disable mbackhaul@$t_name 2>/dev/null
               clean_bh_counters "$t_name"
               local cron_tmp="$SECURE_TMP/crontab.$$"
               crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
               crontab "$cron_tmp"; rm -f "$cron_tmp"
               rm -f "${configs[$del_idx]}" "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${t_name}_restart.sh"
               echo -e "  ${G}Tunnel Purged!${NC}"; sleep 1.5
           fi ;;
           
        3|4|5|6|10|11)
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN" .meta)
           ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; source "$SELECTED_TUN" 2>/dev/null
           
           if [[ "$opt" == "3" ]]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}New Remote Host/IP (Current: ${REMOTE_IP}): ${NC}"; read n_ip
                   n_ip=$(echo "$n_ip" | tr -d '\r')
                   [ -z "$n_ip" ] && break
                   is_valid_host "$n_ip" && {
                       clean_bh_counters "$t_name"
                       REMOTE_IP="$n_ip"
                       break
                   }
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"
               done
               
           elif [[ "$opt" == "4" ]]; then
               if [ "$ROLE" == "1" ]; then
                   echo -ne "  ${C}●${NC} ${W}New Port Mappings (e.g. 443=127.0.0.1:443) [Current: ${PORTS:-None}]: ${NC}"; read n_ports
                   n_ports=$(echo "$n_ports" | tr -d '\r')
                   [ -n "$n_ports" ] && PORTS="$n_ports"
               else
                   echo -e "  ${Y}● Client role doesn't use port mappings.${NC}"; sleep 1.5; continue
               fi
               
           elif [[ "$opt" == "5" ]]; then
               echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}TCP${NC} | ${W}2${NC} ${DIM}❯${NC} ${C}TCPMUX${NC} | ${W}3${NC} ${DIM}❯${NC} ${M}WSMUX${NC} | ${W}4${NC} ${DIM}❯${NC} ${G}WSSMUX (TLS)${NC}"
               while true; do
                   echo -ne "  ${C}● Select New Transport [1-4]: ${NC}"; read tr_choice
                   tr_choice=$(echo "$tr_choice" | tr -d '\r')
                   [[ "$tr_choice" =~ ^[1-4]$ ]] && break
                   echo -e "  ${R}Invalid option. Please choose 1 to 4.${NC}"
               done
               
               if [ "$tr_choice" == "1" ]; then TRANSPORT="tcp"
               elif [ "$tr_choice" == "2" ]; then TRANSPORT="tcpmux"
               elif [ "$tr_choice" == "3" ]; then TRANSPORT="wsmux"
               elif [ "$tr_choice" == "4" ]; then TRANSPORT="wssmux"; fi
               
               echo -e "  ${Y}⚠ Target protocol changed to ${TRANSPORT^^}. Make sure to update the peer!${NC}"
               clean_bh_counters "$t_name"
               
           elif [[ "$opt" == "6" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Tunnel Suffix Name (Current: ${Y}${t_name#bh_}${W}): ${NC}"; read new_suffix
               new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
               if [ -n "$new_suffix" ]; then
                   local new_t_name="bh_${new_suffix}"
                   if [ -f "$CONF_DIR/${new_t_name}.meta" ]; then
                       echo -e "  ${R}● Error: Tunnel name [${new_t_name}] already exists!${NC}"; sleep 1.5; continue
                   fi
                   
                   systemctl stop mbackhaul@$t_name 2>/dev/null; systemctl disable mbackhaul@$t_name 2>/dev/null
                   clean_bh_counters "$t_name"
                   
                   if crontab -l 2>/dev/null | grep -q "mbackhaul@${t_name}"; then
                       local cron_tmp="$SECURE_TMP/crontab.$$"
                       crontab -l | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
                       crontab "$cron_tmp"; rm -f "$cron_tmp"
                       rm -f "$CONF_DIR/${t_name}_restart.sh"
                   fi

                   mv "$CONF_DIR/${t_name}.meta" "$CONF_DIR/${new_t_name}.meta" 2>/dev/null
                   mv "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${new_t_name}.toml" 2>/dev/null
                   
                   t_name="$new_t_name"
                   systemctl enable mbackhaul@$t_name >/dev/null 2>&1
                   echo -e "  ${G}● Tunnel successfully renamed to: ${new_t_name}${NC}"
               else
                   continue
               fi
               
           elif [[ "$opt" == "10" ]]; then
               manage_cron "$t_name"; continue
               
           elif [[ "$opt" == "11" ]]; then
               zero_bh_counters "$t_name" # Reset traffic memory on restart
           fi
           
           write_bh_config "$t_name" "$ROLE" "$TRANSPORT" "$TUN_PORT" "$REMOTE_IP" "$TOKEN" "$PORTS"
           systemctl restart mbackhaul@$t_name
           if systemctl is-active --quiet mbackhaul@$t_name; then
               echo -e "  ${G}✔ Tunnel updated and service restarted successfully.${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Tunnel failed to start. Please check logs!${NC}"; sleep 2
           fi
           ;;
           
        7) show_live_radar ;;
        8) show_tunnel_registry ;;
        9) 
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN" .meta)
           journalctl -u mbackhaul@$t_name -n 50 -f; continue
           ;;
           
        12) menu_install_core ;;
        13) self_update_module ;;
        0) break ;;
    esac
done
