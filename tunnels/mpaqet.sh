#!/bin/bash
# --- MPaqet Modular Core (mpaqet.sh) | Raw Packet Tunnel Engine v8.2.0 ---
# [Features: Tri-Tunnel Dynamic Header | Zero-Lag Stats Cache | Full Deployment Wizard | Zero ANSI Leaks]

MODULE_VERSION="8.2.0"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mpaqet"
CONF_DIR="/etc/paqet"
SERVICE_DIR="/etc/systemd/system"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mpaqet" ] && rm -f "/usr/local/bin/mpaqet" 2>/dev/null

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null
rm -f "$SECURE_TMP/.mpaqet_in_menu" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

is_valid_host() {
    local host="$1"
    if [[ "$host" =~ ^([a-zA-Z0-9.-]+)$ ]] || [[ "$host" =~ ^([a-fA-F0-9:]+)$ ]]; then return 0; fi
    return 1
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

    touch "$SECURE_TMP/.mpaqet_in_menu"
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

    rm -f "$SECURE_TMP/.mpaqet_in_menu" 2>/dev/null
    eval "$__resultvar=\"\$buffer\""
}

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
        if [ -f "$SECURE_TMP/.mpaqet_in_menu" ]; then
            kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        fi
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
update_watcher_loop &
WATCHER_PID=$!

check_ping_bg() {
    local count=0
    local conf t_name ROLE TUN_PORT REMOTE_IP peer_ip conn ping_res loss avg
    > "$SECURE_TMP/.mpaqet_stats_cache.tmp"
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        ROLE=""; TUN_PORT=""; REMOTE_IP=""; source "$conf" 2>/dev/null
        t_name=$(basename "$conf" .meta)
        ((count++))
        [ "$count" -gt 3 ] && break

        peer_ip="$REMOTE_IP"
        if [ "$ROLE" == "1" ]; then
            conn=$(ss -tn src ":$TUN_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
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
        echo "${t_name}|${avg}|${loss}" >> "$SECURE_TMP/.mpaqet_stats_cache.tmp"
    done
    mv -f "$SECURE_TMP/.mpaqet_stats_cache.tmp" "$SECURE_TMP/.mpaqet_stats_cache" 2>/dev/null
}

ping_watcher_loop() {
    while true; do
        check_ping_bg
        if [ -f "$SECURE_TMP/.mpaqet_in_menu" ]; then
            kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        fi
        sleep "$PING_CHECK_INTERVAL"
    done
}
ping_watcher_loop &
PING_WATCHER_PID=$!

trap 'kill "$WATCHER_PID" "$PING_WATCHER_PID" 2>/dev/null; rm -f "$SECURE_TMP/.mpaqet_in_menu" 2>/dev/null' EXIT

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
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r src_opt
    
    local tmp_file="$SECURE_TMP/.mpaqet_update.$$"
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
            rm -f "$SECURE_TMP/.mpaqet_in_menu" 2>/dev/null
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

get_iface_uptime_pq() {
    local t_name="$1"
    local started
    started=$(systemctl show "mpaqet@${t_name}" --property=ActiveEnterTimestampMonotonic 2>/dev/null | cut -d= -f2)
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

is_paqet_core_valid() {
    local bin_path=""
    if [ -x "/usr/local/bin/paqet" ]; then
        bin_path="/usr/local/bin/paqet"
    elif [ -x "/usr/bin/paqet" ]; then
        bin_path="/usr/bin/paqet"
    elif command -v paqet >/dev/null 2>&1; then
        bin_path=$(command -v paqet)
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

install_core_from_source() {
    local src_choice="$1"
    systemctl stop mpaqet@* 2>/dev/null
    killall -9 paqet 2>/dev/null
    
    if [ -f "/usr/local/bin/paqet" ] || [ -f "/usr/bin/paqet" ]; then
        echo -e "  ${Y}● Purging previous MPaqet installation...${NC}"
    fi
    rm -f /usr/local/bin/paqet /usr/bin/paqet "$SECURE_TMP/paqet_dl" "$SECURE_TMP/paqet.tar.gz"

    apt-get update -y -q >/dev/null 2>&1 || true
    apt-get install -y -q libpcap-dev wget curl xxd >/dev/null 2>&1 || true

    if [[ "$src_choice" == "1" || "$src_choice" == "2" ]]; then
        echo -e "  ${DIM}● Fetching latest release binary...${NC}"
        local arch target dl_url="" api_url dl_ok=false
        arch=$(uname -m)
        target="amd64"
        { [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ]; } && target="arm64"
        
        if [ "$src_choice" == "1" ]; then
            api_url="https://api.github.com/repos/hanselime/paqet/releases/latest"
            dl_url=$(curl -m 10 -s "$api_url" | grep "browser_download_url.*linux-${target}" | cut -d '"' -f 4 | head -1)
            [ -z "$dl_url" ] && dl_url="https://github.com/hanselime/paqet/releases/latest/download/paqet-linux-${target}.tar.gz"
        else
            dl_url="https://c107328.parspack.net/c107328/MTunnel/packages/paqet-linux-${target}.tar.gz"
        fi
        
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 10 --max-time 60 -o "$SECURE_TMP/paqet.tar.gz" "$dl_url" 2>/dev/null && dl_ok=true
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 -O "$SECURE_TMP/paqet.tar.gz" "$dl_url" 2>/dev/null && dl_ok=true
        fi

        if [ "$dl_ok" = true ] && [ -s "$SECURE_TMP/paqet.tar.gz" ]; then
            if gzip -t "$SECURE_TMP/paqet.tar.gz" 2>/dev/null; then
                tar -xzf "$SECURE_TMP/paqet.tar.gz" -C "$SECURE_TMP/" >/dev/null 2>&1
                local bin_found
                bin_found=$(find "$SECURE_TMP" -maxdepth 1 -type f -name "*paqet*" -executable | head -1)
                
                if [ -n "$bin_found" ]; then
                    mv "$bin_found" /usr/local/bin/paqet
                    chmod +x /usr/local/bin/paqet
                    echo -e "  ${G}✔ MPaqet Core installed successfully.${NC}"
                else
                    echo -e "  ${R}✖ Binary not found in archive!${NC}"
                fi
                rm -f "$SECURE_TMP"/paqet*
            else
                echo -e "  ${R}✖ Downloaded file is corrupted!${NC}"
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
                curl -fsSL --connect-timeout 10 --max-time 60 -o "$SECURE_TMP/paqet_dl" "$custom_url" 2>/dev/null && dl_ok=true
            elif command -v wget >/dev/null 2>&1; then
                wget -q --timeout=15 -O "$SECURE_TMP/paqet_dl" "$custom_url" 2>/dev/null && dl_ok=true
            fi

            if [ "$dl_ok" = true ] && [ -s "$SECURE_TMP/paqet_dl" ]; then
                if gzip -t "$SECURE_TMP/paqet_dl" 2>/dev/null; then
                    tar -xzf "$SECURE_TMP/paqet_dl" -C "$SECURE_TMP/" >/dev/null 2>&1
                    local bin_found
                    bin_found=$(find "$SECURE_TMP" -maxdepth 1 -type f -name "*paqet*" -executable | head -1)
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
                rm -f "$SECURE_TMP"/paqet*
            else
                echo -e "  ${R}✖ Download failed! Check the link.${NC}"
            fi
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
    local conf t_name
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            t_name=$(basename "$conf" .meta)
            systemctl start "mpaqet@${t_name}" 2>/dev/null
        fi
    done
    sleep 1.5
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
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r\n ')

    [[ "$src_choice" =~ ^[1-4]$ ]] && install_core_from_source "$src_choice"
}

check_first_run_core() {
    if ! is_paqet_core_valid; then
        local first_prompt_flag="$CONF_DIR/.core_prompted"
        if [ ! -f "$first_prompt_flag" ]; then
            touch "$first_prompt_flag"
            clear
            echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${B}│${NC}   ${R}● Paqet Core binary is NOT installed on this machine!${NC}                   ${B}│${NC}"
            echo -e "  ${B}│${NC}   ${W}Would you like to install the Core binary now?${NC}                           ${B}│${NC}"
            echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
            echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
            echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/paqet)${NC}"
            echo -e "  ${DIM}│${NC}"
            echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Skip for now${NC}\n"
            echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r init_opt
            init_opt=$(echo "$init_opt" | tr -d '\r ')
            if [[ "$init_opt" =~ ^[1-4]$ ]]; then
                install_core_from_source "$init_opt"
            fi
        fi
    fi
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
    local chain rulenum
    for chain in INPUT OUTPUT; do
        while read -r rulenum; do
            [ -n "$rulenum" ] && iptables -t mangle -D "$chain" "$rulenum" 2>/dev/null
        done < <(iptables -t mangle -L "$chain" -n --line-numbers 2>/dev/null | grep -E "MPAQET_(RX|TX|RST)_${name}( |\*/)" | awk '{print $1}' | tac)
    done
    for chain in PREROUTING OUTPUT; do
        while read -r rulenum; do
            [ -n "$rulenum" ] && iptables -t raw -D "$chain" "$rulenum" 2>/dev/null
        done < <(iptables -t raw -L "$chain" -n --line-numbers 2>/dev/null | grep -E "MPAQET_RAW_${name}( |\*/)" | awk '{print $1}' | tac)
    done
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
    local rx
    rx=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep "MPAQET_RX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${rx:-0}"
}

get_paqet_tx() {
    local tx
    tx=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null | grep "MPAQET_TX_$1" | awk '{sum+=$2} END {print sum}')
    echo "${tx:-0}"
}

check_paqet_connection() {
    local t_name="$1"
    local known_active="$2"
    local meta="$CONF_DIR/${t_name}.meta"
    [ ! -f "$meta" ] && { echo "OFFLINE"; return; }
    
    if [ "$known_active" != "1" ] && ! systemctl is-active --quiet "mpaqet@${t_name}" 2>/dev/null; then echo "OFFLINE"; return; fi

    local ROLE TUN_PORT
    ROLE=$(grep -m1 "^ROLE=" "$meta" | cut -d'=' -f2 | tr -d '"')
    TUN_PORT=$(grep -m1 "^TUN_PORT=" "$meta" | cut -d'=' -f2 | tr -d '"')
    
    if [ "$ROLE" == "1" ]; then
        if ss -tn src ":$TUN_PORT" 2>/dev/null | grep -qE "^ESTAB"; then echo "ONLINE"; else echo "WAITING"; fi
    else
        if ss -tn dst ":$TUN_PORT" 2>/dev/null | grep -qE "^ESTAB"; then echo "ONLINE"; else echo "CONNECTING"; fi
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

setup_systemd_service() {
    local changed=false
    local tmp_srv="$SECURE_TMP/mpaqet_tpl.service"
    local tmp_app="$SECURE_TMP/mpaqet_apply.service"

    cat <<'EOF' > "$tmp_srv"
[Unit]
Description=MPaqet Raw Packet Tunnel (%i)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

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

    cat <<'EOF' > "$tmp_app"
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

    if ! cmp -s "$tmp_srv" "/etc/systemd/system/mpaqet@.service" 2>/dev/null; then
        mv -f "$tmp_srv" "/etc/systemd/system/mpaqet@.service"
        changed=true
    else
        rm -f "$tmp_srv"
    fi

    if ! cmp -s "$tmp_app" "/etc/systemd/system/mpaqet-apply.service" 2>/dev/null; then
        mv -f "$tmp_app" "/etc/systemd/system/mpaqet-apply.service"
        changed=true
    else
        rm -f "$tmp_app"
    fi

    if [ "$changed" = true ]; then
        systemctl daemon-reload
        systemctl enable mpaqet-apply.service >/dev/null 2>&1
    fi
}

draw_mpaqet_header() {
    local s_ip
    s_ip=$(get_local_ip)
    local active_count=0 conf
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        systemctl is-active --quiet "mpaqet@$(basename "$conf" .meta)" && ((active_count++))
    done

    clear; echo ""
    local border="────────────────────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${B}╭${border}╮${NC}"
    printf "  ${B}│${NC} ${W}%-22s${NC} ${B}│${NC} ${DIM}Local:${NC} ${W}%-15s${NC} ${B}│${NC} ${DIM}Active Tunnels:${NC} ${G}%-3s${NC} ${DIM}(Max 3 Shown)${NC}      ${B}│${NC}\n" \
        "MPaqet Raw Engine v${MODULE_VERSION}" "$s_ip" "$active_count"
    echo -e "  ${B}├${border}┤${NC}"

    local shown=0
    local ROLE TUN_PORT REMOTE_IP t_name pure peer_ip conn cached_entry avg loss loss_disp loss_col tun_uptime stat_icon stat_col
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        ROLE=""; TUN_PORT=""; REMOTE_IP=""; source "$conf" 2>/dev/null
        t_name=$(basename "$conf" .meta)
        ((shown++))
        [ "$shown" -gt 3 ] && break

        pure="${t_name#pq_}"
        [ ${#pure} -gt 4 ] && pure="${pure:0:4}"

        peer_ip="$REMOTE_IP"
        if [ "$ROLE" == "1" ]; then
            conn=$(ss -tn src ":$TUN_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
            peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
            [ -z "$peer_ip" ] && peer_ip="0.0.0.0"
        fi

        avg="---"; loss="0"
        if [ -f "$SECURE_TMP/.mpaqet_stats_cache" ]; then
            cached_entry=$(grep "^${t_name}|" "$SECURE_TMP/.mpaqet_stats_cache" 2>/dev/null | head -n 1)
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

        tun_uptime=$(get_iface_uptime_pq "$t_name")
        stat_icon="●"; stat_col="${G}"
        if [ "$tun_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi

        printf "  ${B}│${NC} %b%s%b ${W}%-4s${NC} ${DIM}➔${NC} ${Y}%-15s${NC} ${DIM}vIP:%bOFF %b ${B}│${NC} ${DIM}P:${NC}${Y}%-6s${NC} ${DIM}L:${NC}%b%-4s%b ${B}│${NC} ${DIM}Up:${NC}${W}%-6s${NC} ${B}│${NC} ${DIM}FWD:${NC}%bRAW %b ${B}│${NC}\n" \
            "$stat_col" "$stat_icon" "$NC" "$pure" "$peer_ip" "$DIM" "$NC" "$avg" "$loss_col" "$loss_disp" "$NC" "$tun_uptime" "$C" "$NC"
    done

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}%-88s${NC}  ${B}│${NC}\n" "● No active Paqet tunnels configured on this host."
    fi
    echo -e "  ${B}╰${border}╯${NC}"
}

show_tunnel_registry() {
    draw_mpaqet_header
    echo -e "\n  ${Y}● Deployed Paqet Tunnels Registry:${NC}"
    local count=0 conf t_name ROLE TUN_PORT REMOTE_IP TCP_PORTS yaml_f
    local key mode block mtu conn_c role_text ping_val connected_peer est_conn p_ip peer_text
    local st stat_icon stat_text stat_color rx tx
    local left_p right_p pad sp l1 r1 pad1 sp1 l2 r2 clean_r2 pad2 sp2 l3 r3 pad3 sp3 l4 r4 pad4 sp4 p_str l5 pad5 sp5
    
    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        t_name=$(basename "$conf" .meta)
        ROLE=""; TUN_PORT=""; REMOTE_IP=""; TCP_PORTS=""
        source "$conf" 2>/dev/null
        
        yaml_f="$CONF_DIR/${t_name}.yaml"
        [ ! -f "$yaml_f" ] && continue
        
        key=$(grep "key:" "$yaml_f" | awk -F'"' '{print $2}')
        mode=$(grep "mode:" "$yaml_f" | awk -F'"' '{print $2}')
        block=$(grep "block:" "$yaml_f" | awk -F'"' '{print $2}')
        mtu=$(grep "mtu:" "$yaml_f" | awk '{print $2}')
        conn_c=$(grep "conn:" "$yaml_f" | head -1 | awk '{print $2}')
        
        role_text=$([ "$ROLE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        ping_val="N/A"
        connected_peer=""

        if [ "$ROLE" == "2" ] && [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "0.0.0.0" ]; then
            ping_val=$(get_peer_ping "$REMOTE_IP" "$TUN_PORT")
            connected_peer="$REMOTE_IP"
        elif [ "$ROLE" == "1" ]; then
            est_conn=$(ss -tn src ":$TUN_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
            if [ -n "$est_conn" ]; then
                p_ip=$(echo "$est_conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                ping_val=$(get_peer_ping "$p_ip" "$TUN_PORT")
                connected_peer="$p_ip"
            else
                ping_val="Waiting"
            fi
        fi

        peer_text=$([ "$ROLE" == "1" ] && echo "Listening on :${TUN_PORT}" || echo "${REMOTE_IP}:${TUN_PORT}")
        if [ "$ROLE" == "1" ] && [ -n "$connected_peer" ]; then
            peer_text="${connected_peer}:${TUN_PORT} (Active)"
        fi

        st=$(check_paqet_connection "$t_name")
        stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"
        if [ "$st" == "ONLINE" ]; then stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}";
        elif [ "$st" == "WAITING" ]; then stat_icon="◎"; stat_text="WAITING CLIENT"; stat_color="${Y}";
        elif [ "$st" == "CONNECTING" ]; then stat_icon="◎"; stat_text="CONNECTING..."; stat_color="${Y}"; fi

        rx=$(get_paqet_rx "$t_name"); tx=$(get_paqet_tx "$t_name")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        left_p="▼ Tunnel: $t_name"; right_p="Role: $role_text"
        pad=$(( 90 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        l1="Link Port    : ${TUN_PORT}"; r1="Latency: ${ping_val}"
        pad1=$(( 90 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Link Port    :${NC} ${W}${TUN_PORT}${NC}${sp1}${DIM}Latency:${NC} ${Y}${ping_val}${NC} ${B}│${NC}"
        
        l2="Peer Target  : ${peer_text}"; r2="Link State: ${stat_icon} ${stat_text}"
        clean_r2=$(echo -e "$r2" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
        pad2=$(( 90 - ${#l2} - ${#clean_r2} )); [ "$pad2" -lt 0 ] && pad2=0; sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}Peer Target  :${NC} ${W}${peer_text}${NC}${sp2}${DIM}Link State:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${B}│${NC}"

        l3="Secret Key   : ${key}"; r3="Crypto: ${block^^}"
        pad3=$(( 90 - ${#l3} - ${#r3} )); [ "$pad3" -lt 0 ] && pad3=0; sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${Y}Secret Key   :${NC} ${W}${key}${NC}${sp3}${DIM}Crypto:${NC} ${C}${block^^}${NC} ${B}│${NC}"

        l4="Traffic Usage: RX $(format_total "$rx") / TX $(format_total "$tx")"; r4="Mode: ${mode^^} | MTU: ${mtu} | Conn: ${conn_c}"
        pad4=$(( 90 - ${#l4} - ${#r4} )); [ "$pad4" -lt 0 ] && pad4=0; sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Traffic Usage:${NC} ${G}RX $(format_total "$rx")${NC} ${DIM}/${NC} ${Y}TX $(format_total "$tx")${NC}${sp4}${DIM}${r4}${NC} ${B}│${NC}"
        
        if [ "$ROLE" == "2" ]; then
            p_str="${TCP_PORTS:0:70}"
            [ ${#TCP_PORTS} -gt 70 ] && p_str="${p_str}..."
            l5="Port Mappings: ${p_str}"
            pad5=$(( 90 - ${#l5} )); [ "$pad5" -lt 0 ] && pad5=0; sp5=$(printf '%*s' "$pad5" "")
            echo -e "  ${B}│${NC} ${DIM}Port Mappings:${NC} ${Y}${p_str}${NC}${sp5} ${B}│${NC}"
        fi
        
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯\n"
        ((count++))
    done
    if [ "$count" -eq 0 ]; then echo -e "  ${R}● No tunnels configured yet!${NC}\n"; fi
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r dummy
}

show_live_radar() {
    tput civis; clear
    declare -A rx_old tx_old
    local conf t_name count st st_color st_text r_new t_new r_prev t_prev rx_s tx_s c_rx c_tx key

    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        t_name=$(basename "$conf" .meta)
        rx_old[$t_name]=$(get_paqet_rx "$t_name")
        tx_old[$t_name]=$(get_paqet_tx "$t_name")
    done

    while true; do
        printf "\033[H"; draw_mpaqet_header
        echo -e "\n  ${DIM}┌─[ PAQET TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL RX" "∑ TOTAL TX"
        echo -e "  ${B}├──────────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤${NC}"

        count=0
        for conf in "$CONF_DIR"/*.meta; do
            [ ! -f "$conf" ] && continue
            t_name=$(basename "$conf" .meta)
            st=$(check_paqet_connection "$t_name")
            st_color="${R}"; st_text="OFFLINE"
            if [ "$st" == "ONLINE" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING"; fi

            r_new=$(get_paqet_rx "$t_name"); t_new=$(get_paqet_tx "$t_name")
            r_prev=${rx_old[$t_name]:-$r_new}; t_prev=${tx_old[$t_name]:-$t_new}
            rx_s=$((r_new - r_prev)); tx_s=$((t_new - t_prev))
            [ "$rx_s" -lt 0 ] && rx_s=0; [ "$tx_s" -lt 0 ] && tx_s=0
            rx_old[$t_name]=$r_new; tx_old[$t_name]=$t_new

            c_rx="${DIM}"; [ "$rx_s" -gt 0 ] && c_rx="${G}"
            c_tx="${DIM}"; [ "$tx_s" -gt 0 ] && c_tx="${Y}"

            printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} %b%-10s%b ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "$t_name" "$st_color" "$st_text" "$NC" "$c_rx" "$(format_speed "$rx_s")" "$NC" "$c_tx" "$(format_speed "$tx_s")" "$NC" "$(format_total "$r_new")" "$(format_total "$t_new")"
            ((count++))
        done

        if [ "$count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-78s${NC} ${B}│${NC}\n" "  No active Paqet tunnels configured."
        fi
        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\e' ]]; then break; fi
    done
    tput cnorm
}

select_tunnel() {
    local configs=("$CONF_DIR"/*.yaml)
    [ ! -e "${configs[0]}" ] && { echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; fi
    
    echo -e "\n  ${B}╭────────────────── Select Target Tunnel ────────────────────╮${NC}"
    local i
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .yaml)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read -r t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r')
    if [[ "$t_idx" == "q" || -z "$t_idx" || -z "${configs[$t_idx]}" ]]; then return 1; fi

    SELECTED_TUN="${configs[$t_idx]}"
    return 0
}

uninstall_mpaqet() {
    clear
    echo -e "\n  ${R}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${R}│${NC}   ${R}⚠ WARNING: COMPLETE PURGE & UNINSTALLATION OF MPAQET${NC}                   ${R}│${NC}"
    echo -e "  ${R}│${NC}   This will permanently stop and delete:                                   ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All active Paqet tunnels & systemd units                               ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All YAML configurations & metadata in /etc/paqet                       ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All raw & mangle iptables counters                                    ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● Paqet core binary (/usr/local/bin/paqet) & mpaqet module               ${R}│${NC}"
    echo -e "  ${R}╰────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    
    local confirm tbl r
    echo -ne "  ${Y}Are you sure you want to proceed? Type '${R}yes${Y}' to confirm: ${NC}"; read -r confirm
    confirm=$(echo "$confirm" | tr -d '\r ')
    
    if [ "$confirm" != "yes" ]; then
        echo -e "  ${G}● Uninstallation cancelled.${NC}"; sleep 1.5; return
    fi

    echo -e "\n  ${DIM}● [1/5] Stopping services & killing processes...${NC}"
    systemctl stop mpaqet@* mpaqet-apply.service 2>/dev/null
    systemctl disable mpaqet@* mpaqet-apply.service 2>/dev/null
    killall -9 paqet 2>/dev/null

    echo -e "  ${DIM}● [2/5] Purging raw & mangle iptables rules...${NC}"
    for tbl in mangle raw; do
        iptables -t "$tbl" -S 2>/dev/null | grep -E "MPAQET_" | sed 's/^-A /-D /' | while read -r r; do
            [ -n "$r" ] && iptables -t "$tbl" "$r" 2>/dev/null
        done
    done

    echo -e "  ${DIM}● [3/5] Removing systemd unit files...${NC}"
    rm -f /etc/systemd/system/mpaqet@.service /etc/systemd/system/mpaqet-apply.service
    systemctl daemon-reload 2>/dev/null

    echo -e "  ${DIM}● [4/5] Deleting configurations & core binary...${NC}"
    rm -rf /etc/paqet "$SECURE_TMP/.mpaqet"* /usr/local/bin/paqet /usr/bin/paqet

    echo -e "  ${DIM}● [5/5] Removing mpaqet wrapper script...${NC}"
    rm -f "$INSTALL_PATH" 2>/dev/null
    [ -f "$0" ] && rm -f "$0" 2>/dev/null

    echo -e "\n  ${G}✔ MPaqet ecosystem has been completely eradicated.${NC}\n"
    exit 0
}

check_first_run_core
setup_systemd_service

render_mpaqet_menu() {
    draw_mpaqet_header
    echo -e "\n  ${DIM}┌─[ PROVISION & MANAGE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup Server Tunnel${NC} ${DIM}(Kharej Raw Listener)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Setup Client Tunnel${NC} ${DIM}(Iran Port Forward)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC} ${DIM}(Specific / ALL)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ FLAT CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Edit Secret Key${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Edit KCP Mode${NC} ${DIM}(normal, fast, fast2, fast3)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Edit MTU Size${NC} ${DIM}(1000-1500)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${Y}Edit Connection Count${NC} ${DIM}(conn: 1-32)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${M}Edit Encryption${NC} ${DIM}(aes-128-gcm, aes-256, none)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${W}Rename Tunnel Interface${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & SYSTEM ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${G}Live Traffic & Bandwidth Radar${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${M}View Tunnels Registry & Settings${NC}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${DIM}View Live Service Logs${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC}${DIM}❯${NC} ${G}Restart Service & Zero Counters${NC}"
    echo -e "  ${DIM}├─${NC} ${W}14${NC}${DIM}❯${NC} ${M}Install / Update MPaqet Core${NC}"
    echo -e "  ${DIM}├─${NC} ${W}15${NC}${DIM}❯${NC} ${G}Instant OTA Update (Sync Module)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}16${NC}${DIM}❯${NC} ${R}Uninstall MPaqet${NC} ${DIM}(Purge All)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}

while true; do
    render_mpaqet_menu
    read_with_refresh "  ${C}PAQET ❯❯ ${NC}" opt render_mpaqet_menu
    opt=$(echo "$opt" | tr -d '\r')
    
    case $opt in
        1)
           echo -e "\n  ${DIM}┌─[ DEPLOY SERVER TUNNEL ]${NC}"
           echo -ne "  ${C}● Tunnel Suffix Name (e.g. srv1): ${NC}"; read -r suffix
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
               echo -ne "  ${C}● Tunnel Listen Port [8888]: ${NC}"; read -r t_port
               t_port=$(echo "$t_port" | tr -dc '0-9')
               t_port=${t_port:-8888}
               if [ -z "$t_port" ] || [ "$t_port" -lt 1 ] || [ "$t_port" -gt 65535 ]; then
                   echo -e "  ${R}✖ Invalid port!${NC}"
                   continue
               fi
               if ss -tuln 2>/dev/null | grep -qE ":${t_port}\s"; then
                   echo -e "  ${R}Error: Port ${t_port} is already in use by another service!${NC}"
                   continue
               fi
               break
           done
           
           s_key=$(head -c 16 /dev/urandom | xxd -p 2>/dev/null)
           [ -z "$s_key" ] && s_key=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)
           echo -ne "  ${C}● Secret Key [Default ${s_key}]: ${NC}"; read -r u_key
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
               echo -ne "  ${DIM}Press Enter...${NC}"; read -r dummy
           fi
           ;;
           
        2)
           echo -e "\n  ${DIM}┌─[ DEPLOY CLIENT TUNNEL ]${NC}"
           echo -ne "  ${C}● Tunnel Suffix Name (e.g. cl1): ${NC}"; read -r suffix
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
               echo -ne "  ${C}● Remote Kharej Server Host/IP: ${NC}"; read -r r_ip
               r_ip=$(echo "$r_ip" | tr -d '\r ')
               is_valid_host "$r_ip" && break
               echo -e "  ${R}✖ Invalid Host/IP format!${NC}"
           done
           
           while true; do
               echo -ne "  ${C}● Remote Listen Port [8888]: ${NC}"; read -r r_port
               r_port=$(echo "$r_port" | tr -dc '0-9')
               r_port=${r_port:-8888}
               if [ -n "$r_port" ] && [ "$r_port" -le 65535 ]; then break; else echo -e "  ${R}✖ Invalid port!${NC}"; fi
           done
           
           echo -ne "  ${C}● Secret Key (from Server): ${NC}"; read -r key
           key=$(echo "$key" | tr -dc 'a-zA-Z0-9_=-')
           
           fwd_ports=""
           while true; do
               echo -ne "  ${C}● Forward Ports (e.g. 443,8080): ${NC}"; read -r fwd_ports
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
           meta_ports=""
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
               echo -ne "  ${DIM}Press Enter...${NC}"; read -r dummy
           fi
           ;;

        3)
           configs=("$CONF_DIR"/*.meta)
           [ ! -e "${configs[0]}" ] && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Delete ─────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}Index (or 'all' / 'q'): ${NC}"; read -r del_idx
           del_idx=$(echo "$del_idx" | tr -d '\r ')
           
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
           fi ;;

        4|5|6|7|8|9)
           select_tunnel || continue
           sel_cfg="$SELECTED_TUN"
           old_tname=$(basename "$sel_cfg" .yaml)

           if [[ "$opt" == "4" ]]; then
               curr_key=$(grep "key:" "$sel_cfg" | awk -F'"' '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New Secret Key [Current: ${Y}${curr_key}${W}]: ${NC}"; read -r n_k
               n_k=$(echo "$n_k" | tr -dc 'a-zA-Z0-9_=-')
               if [ -n "$n_k" ]; then
                   sed -i "s|key:.*|key: \"$n_k\"|" "$sel_cfg"
                   echo -e "  ${G}✔ Secret Key updated.${NC}"
               else
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi

           elif [[ "$opt" == "5" ]]; then
               curr_mode=$(grep "mode:" "$sel_cfg" | awk -F'"' '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New KCP Mode [normal|fast|fast2|fast3] [Current: ${Y}${curr_mode}${W}]: ${NC}"; read -r n_m
               n_m=$(echo "$n_m" | tr -dc 'a-zA-Z0-9')
               if [ -z "$n_m" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if [[ "$n_m" =~ ^(normal|fast|fast2|fast3)$ ]]; then
                   sed -i "s|mode:.*|mode: \"$n_m\"|" "$sel_cfg"
                   echo -e "  ${G}✔ KCP Mode updated.${NC}"
               else
                   echo -e "  ${R}✖ Invalid Mode!${NC}"; sleep 1.5; continue
               fi

           elif [[ "$opt" == "6" ]]; then
               curr_mtu=$(grep "mtu:" "$sel_cfg" | awk '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New MTU Size [1000-1500] [Current: ${Y}${curr_mtu}${W}]: ${NC}"; read -r n_mtu
               n_mtu=$(echo "$n_mtu" | tr -dc '0-9')
               if [ -z "$n_mtu" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if [ "$n_mtu" -lt 1000 ] || [ "$n_mtu" -gt 1500 ]; then 
                   echo -e "  ${R}✖ MTU must be between 1000 and 1500!${NC}"; sleep 1.5; continue
               fi
               sed -i "s|mtu:.*|mtu: $n_mtu|" "$sel_cfg"
               echo -e "  ${G}✔ MTU updated.${NC}"

           elif [[ "$opt" == "7" ]]; then
               curr_conn=$(grep "conn:" "$sel_cfg" | head -1 | awk '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New Connections Count [1-32] [Current: ${Y}${curr_conn}${W}]: ${NC}"; read -r n_c
               n_c=$(echo "$n_c" | tr -dc '0-9')
               if [ -z "$n_c" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if [ "$n_c" -lt 1 ] || [ "$n_c" -gt 32 ]; then 
                   echo -e "  ${R}✖ Connections must be between 1 and 32!${NC}"; sleep 1.5; continue
               fi
               sed -i "s|conn:.*|conn: $n_c|" "$sel_cfg"
               echo -e "  ${G}✔ Connection count updated.${NC}"

           elif [[ "$opt" == "8" ]]; then
               curr_block=$(grep "block:" "$sel_cfg" | awk -F'"' '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New Encryption Block [aes-128-gcm|aes-256|none] [Current: ${Y}${curr_block}${W}]: ${NC}"; read -r n_b
               n_b=$(echo "$n_b" | tr -dc 'a-zA-Z0-9-')
               if [ -z "$n_b" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if [[ "$n_b" =~ ^(aes-128-gcm|aes-256|none)$ ]]; then
                   sed -i "s|block:.*|block: \"$n_b\"|" "$sel_cfg"
                   echo -e "  ${G}✔ Encryption Block updated.${NC}"
               else
                   echo -e "  ${R}✖ Invalid Encryption!${NC}"; sleep 1.5; continue
               fi

           elif [[ "$opt" == "9" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Tunnel Suffix (Current: ${Y}${old_tname#pq_}${W}): ${NC}"; read -r new_suffix
               new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
               if [ -n "$new_suffix" ]; then
                   new_t_name="pq_${new_suffix}"
                   if [ -f "$CONF_DIR/${new_t_name}.yaml" ]; then
                       echo -e "  ${R}● Error: Tunnel [${new_t_name}] already exists!${NC}"; sleep 1.5; continue
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
                   echo -e "  ${G}● Tunnel renamed to: ${new_t_name}${NC}"
               else
                   echo -e "  ${Y}● Rename cancelled.${NC}"; sleep 1; continue
               fi
           fi

           systemctl restart "mpaqet@${old_tname}" 2>/dev/null
           sleep 1.5
           if systemctl is-active --quiet "mpaqet@${old_tname}"; then
               echo -e "  ${G}✔ Tunnel updated and restarted successfully.${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Tunnel failed to start. Check logs!${NC}"; sleep 2
           fi
           ;;

        10) show_live_radar ;;
        11) show_tunnel_registry ;;
        12) 
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN" .yaml)
           journalctl -u "mpaqet@${t_name}" -n 50 -f; continue
           ;;
        13) zero_paqet_counters; systemctl restart mpaqet@* 2>/dev/null; echo -e "  ${G}● Services restarted and traffic counters zeroed.${NC}"; sleep 1.5 ;;
        14) menu_install_core ;;
        15) self_update_module ;;
        16) uninstall_mpaqet ;;
        0) break ;;
    esac
done
