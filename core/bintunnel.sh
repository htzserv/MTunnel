#!/bin/bash
# MTunnel Shared Binary-Tunnel Library (MBackhaul / MPaqet / MRathole) — API 1
MODULE_VERSION="2.1.0"
MTUNNEL_BINTUNNEL_API=1

bt_init_runtime() {
    MAIN_PID=$$
    NEED_REFRESH=false
    NEED_HDR=false
    trap 'NEED_REFRESH=true' SIGUSR1
    trap 'NEED_HDR=true' SIGUSR2
    UPDATE_CHECK_INTERVAL=120
    HDR_CHECK_INTERVAL=10
    HDR_ROWS_FILE="$SECURE_TMP/.${BT_MOD}_hdr_rows"
    HDR_DRAWN_ROWS=0
    WATCHER_PID=""
    HDR_PID=""
    if [[ "${1:-}" != --* ]]; then
        update_watcher_loop & WATCHER_PID=$!
        hdr_stats_loop & HDR_PID=$!
    fi
    trap 'kill "${WATCHER_PID:-}" "${HDR_PID:-}" 2>/dev/null; rm -f "$SECURE_TMP/.${BT_MOD}_in_menu" 2>/dev/null' EXIT
}

read_with_refresh() {
    local prompt="$1" __resultvar="$2" redraw_func="$3" buffer="" char rc up now last_live=-1
    touch "$SECURE_TMP/.${BT_MOD}_in_menu"
    echo -ne "$prompt"
    while true; do
        if [ "$NEED_REFRESH" = true ] && [ -z "$buffer" ] && [ -n "$redraw_func" ]; then
            NEED_REFRESH=false
            "$redraw_func"
            echo -ne "$prompt$buffer"
        fi
        if [ "$NEED_HDR" = true ]; then
            NEED_HDR=false
            [ -n "$redraw_func" ] && refresh_header_live
        fi
        IFS= read -rsn1 -t 0.3 char
        rc=$?
        if [ $rc -ne 0 ]; then
            if [ "$rc" -eq 142 ] || [ "$rc" -gt 128 ]; then
                read -r up _ < /proc/uptime 2>/dev/null || up=0; now="${up%%.*}"
                if [ "$now" != "$last_live" ]; then last_live="$now"; refresh_header_live; fi
                continue
            fi
            rm -f "$SECURE_TMP/.${BT_MOD}_in_menu" 2>/dev/null
            return "$rc"
        fi
        if [[ -z "$char" || "$char" == $'\n' || "$char" == $'\r' ]]; then
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
    rm -f "$SECURE_TMP/.${BT_MOD}_in_menu" 2>/dev/null
    printf -v "$__resultvar" '%s' "$buffer"
}

fetch_remote_version() {
    local url="$1" payload version=""
    if command -v curl >/dev/null 2>&1; then
        payload=$(curl -fsSL -r 0-4095 --connect-timeout 3 --max-time 8 "$url" 2>/dev/null) || return 1
    elif command -v wget >/dev/null 2>&1; then
        payload=$(wget -qO- --header="Range: bytes=0-4095" --timeout=8 "$url" 2>/dev/null) || return 1
    else
        return 1
    fi
    version=$(printf '%s\n' "$payload" | sed -n 's/^MODULE_VERSION="\([^" ]*\)".*/\1/p' | head -n 1)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || return 1
    printf '%s\n' "$version"
}

check_update_bg_legacy() {
    local cb="" gh_ver="" mirror_ver="" latest_ver="" cand
    gh_ver=$(fetch_remote_version "${MTUNNEL_GITHUB_BASE}/${BT_REL_PATH}${cb}")
    mirror_ver=$(fetch_remote_version "${MTUNNEL_MIRROR_BASE}/${BT_REL_PATH}${cb}")
    [ -n "$gh_ver" ] && printf '%s\n' "$gh_ver" > "$SECURE_TMP/.${BT_MOD}_remote_ver_github"
    [ -n "$mirror_ver" ] && printf '%s\n' "$mirror_ver" > "$SECURE_TMP/.${BT_MOD}_remote_ver_mirror"
    for cand in "$gh_ver" "$mirror_ver"; do
        [[ "$cand" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || continue
        latest_ver=$(printf '%s\n%s\n' "$latest_ver" "$cand" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' | sort -V | tail -n 1)
    done
    [ -n "$latest_ver" ] && printf '%s\n' "$latest_ver" > "$SECURE_TMP/.${BT_MOD}_remote_ver"
    return 0
}

check_update_bg() {
    if declare -F mt_check_update_both >/dev/null 2>&1; then mt_check_update_both "$BT_REL_PATH" "$BT_MOD"; return 0; fi
    check_update_bg_legacy
}

update_watcher_loop() {
    local before after
    while true; do
        before=$(cat "$SECURE_TMP/.${BT_MOD}_remote_ver" 2>/dev/null)
        check_update_bg
        after=$(cat "$SECURE_TMP/.${BT_MOD}_remote_ver" 2>/dev/null)
        if [ -f "$SECURE_TMP/.${BT_MOD}_in_menu" ] && [ "$before" != "$after" ]; then
            kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        fi
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}

self_update_module() {
    local src_opt="${1:-}" custom_url dl_url tmp_file confirm
    local rel_path="$BT_REL_PATH"
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.${BT_MOD}_remote_ver" ] && remote_v=$(tr -d '\r\n ' < "$SECURE_TMP/.${BT_MOD}_remote_ver")

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && mt_update_available "$remote_v" "$MODULE_VERSION"; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    if [ -z "$src_opt" ]; then
        clear; echo -e "\n  ${FR}┌─[ OTA Update (${BT_TITLE}) ]${NC}"
        echo -e "  ${FR}│${NC}"
        echo -e "  ${FR}├─[ AUTOMATIC MIRRORS ]${NC}"
        echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${gh_text}"
        echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Iranian Mirror${NC} ${DIM}(${MTUNNEL_MIRROR_BASE})${NC}"
        echo -e "  ${FR}│${NC}"
        echo -e "  ${FR}├─[ MANUAL OVERRIDES ]${NC}"
        echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
        echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Nano / Ctrl+X to Save)${NC}"
        echo -e "  ${FR}│${NC}"
        echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
        echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r src_opt
    fi

    [[ "$src_opt" =~ ^[1-4]$ ]] || return 0
    tmp_file=$(mktemp "$SECURE_TMP/update.XXXXXX") || return 1
    if [ "$src_opt" == 4 ]; then
        if ! mt_capture_manual_script "$tmp_file"; then
            rm -f "$tmp_file"
            echo -e "  ${R}✖ Manual paste failed or was cancelled. Existing script preserved.${NC}"
            return 1
        fi
    else
        case "$src_opt" in
            1) dl_url="${MTUNNEL_GITHUB_BASE}/$rel_path";;
            2) dl_url="${MTUNNEL_MIRROR_BASE}/$rel_path";;
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read -r dl_url;;
        esac
        echo -e "\n  ${C}⟳${NC} ${W}Downloading Update...${NC}"
        if ! mt_download "$dl_url" "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Download failed. Installed module preserved.${NC}"; return 1; fi
    fi
    sed -i 's/\r$//' "$tmp_file"
    if ! mt_validate_script "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Invalid Bash module. Installed module preserved.${NC}"; return 1; fi
    local new_ver; new_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$tmp_file")
    if ! mt_module_downgrade_allowed "$MODULE_VERSION" "$new_ver"; then rm -f "$tmp_file"; return 1; fi
    echo -e "\n  ${FR}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
    echo -e "  ${FR}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
    echo -e "  ${FR}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read -r confirm

    [[ "${confirm,,}" == y || "${confirm,,}" == yes ]] || { echo -e "  ${Y}● Update cancelled by user.${NC}"; rm -f "$tmp_file"; return 0; }
    if ! mt_install_script "$tmp_file" "$rel_path" "$INSTALL_PATH" "$0"; then
        rm -f "$tmp_file"; echo -e "  ${R}✖ Update failed. Previous module preserved.${NC}"; return 1
    fi
    rm -f "$tmp_file"
    echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
    [ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null || true
    exec "$INSTALL_PATH"
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

get_local_ipv6() {
    local ip
    ip=$(ip -6 -o addr show scope global 2>/dev/null | awk '$3=="inet6" && $0 !~ / tentative | dadfailed | deprecated / {print $4; exit}')
    ip="${ip%%/*}"
    printf '%s' "$ip"
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

mt_update_label() {
    local file="$1" rv='Unknown'
    [ -f "$file" ] && rv=$(tr -d '\r\n ' < "$file")
    if [ -n "$rv" ] && [ "$rv" != Unknown ]; then
        if mt_update_available "$rv" "$MODULE_VERSION" 2>/dev/null; then printf 'v%s → v%s' "$MODULE_VERSION" "$rv"
        else printf 'v%s' "$rv"; fi
    else printf 'version unavailable'; fi
}

hdr_unit_uptime() {
    local started now sec d h m
    started=$(systemctl show "$1" --property=ActiveEnterTimestampMonotonic 2>/dev/null | cut -d= -f2)
    if [[ "$started" =~ ^[0-9]+$ ]] && [ "$started" -gt 0 ]; then
        now=$(awk '{printf "%d", $1*1000000}' /proc/uptime)
        sec=$(( (now - started) / 1000000 )); [ "$sec" -lt 0 ] && sec=0
        d=$(( sec / 86400 )); h=$(( (sec % 86400) / 3600 )); m=$(( (sec % 3600) / 60 ))
        if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
        elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
        else printf "%dm" "$m"; fi
        return
    fi
    echo "ACTIVE"
}

hdr_is_ip() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ || ( "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:]+$ ) ]]; }

hdr_conf_has() {
    local v; v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 | tr -d "\"' \r")
    [ -n "$v" ]
}

hdr_rows_count() {
    local _n=0 _l
    if [ -s "$HDR_ROWS_FILE" ]; then while IFS= read -r _l; do [ -n "$_l" ] && _n=$((_n+1)); done < "$HDR_ROWS_FILE"; fi
    HDR_ROWS_COUNT="$_n"
}

refresh_header_live() {
    hdr_rows_count
    if [ "$HDR_ROWS_COUNT" != "$HDR_DRAWN_ROWS" ]; then NEED_REFRESH=true; return; fi
    mt_live_vitals_update 2>/dev/null || true
    printf '\033[?25l\0337\033[1;1H'
    HEADER_LIVE=1 draw_header
    printf '\0338\033[?25h'
}

hdr_stats_loop() {
    while true; do
        if declare -F collect_header_rows >/dev/null 2>&1; then
            collect_header_rows
        fi
        [ -f "$SECURE_TMP/.${BT_MOD}_in_menu" ] && kill -SIGUSR2 "$MAIN_PID" 2>/dev/null
        sleep "$HDR_CHECK_INTERVAL"
    done
}

mt_main_logs() { show_tunnel_logs; }

mt_link_field_valid() {
    local key="$1" val="$2" safe='^[][A-Za-z0-9_:.,/=-]*$'
    [ "${#val}" -le 4096 ] && [[ "$val" =~ $safe ]] || return 1
    case "$key" in
        ROLE) [[ "$val" =~ ^[12]$ ]];;
        BBR) [[ "$val" =~ ^[01]$ ]];;
        NAME) [[ "$val" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]];;
        BIND_HOST) mt_valid_ipv4 "$val" || mt_valid_ipv6 "$val";;
        EXPIRES) mt_link_uint "$val" 1 9999999999;;
        CORE_V6) [ -z "$val" ] || mt_valid_ipv6 "$val::1";;
        HOST|LOCAL_PUB|REMOTE_PUB|LOCAL_PUB6|REMOTE_PUB6|LOCAL_IP6|REMOTE_IP6|REMOTE_V4)
            [ -z "$val" ] || mt_valid_host "$val";;
        TOKEN|TUN_SECRET|SYNC_KEY) [[ "$val" =~ ^[A-Za-z0-9_=-]{1,256}$ ]];;
        LINK_PORT) mt_valid_port "$val";;
        TCP_PORTS|UDP_PORTS) mt_link_ports "$val";;
        TRANSPORT) [[ "$val" =~ ^(tcp|tcpmux|tls|tlsmux|ws|wss|wsmux|wssmux|udp|kcp|kcpmux|xhttp|xhttps|xhttpmux|xhttpsmux)$ ]];;
        PORTS) return 0;;
        ENABLE_UDP|ADV_AGGRESSIVE|ADV_NODELAY|ADV_PROXY|KCP_WDELAY|KCP_ACKNODELAY) [[ "$val" =~ ^(true|false)$ ]];;
        PROTO) [[ "$val" =~ ^(ipv4|ipv6|6to4|gre6|ipip4to4|ipip4to6|ipip6to6)$ ]];;
        CORE_SUBNET) mt_valid_ipv4 "$val.1";;
        TUN_ID) mt_link_uint "$val" 0 16777215;;
        VNI_ID) mt_link_uint "$val" 1 16777215;;
        MAX_IPS) mt_link_uint "$val" 0 64;;
        CUSTOM_MTU) [ -z "$val" ] || mt_link_uint "$val" 512 9000;;
        ENCRYPT) [[ "$val" =~ ^[01]$ ]];;
        ADV_LOG) [[ "$val" =~ ^(trace|debug|info|warn|error)$ ]];;
        ADV_SNI|ADV_XHTTP_HOST) [ -z "$val" ] || mt_valid_host "$val";;
        ADV_UTLS) [[ "$val" =~ ^(chrome|firefox|safari|edge|ios|random|none)$ ]];;
        ADV_KCP_MODE) [[ "$val" =~ ^(normal|fast|fast2|fast3|manual)$ ]];;
        ADV_KCP_CRYPT) [[ "$val" =~ ^(aes|aes-128|aes-256|salsa20|xor|tea|xtea|sm4|blowfish|twofish|cast5|3des|none)$ ]];;
        ADV_KCP_NOFEC) [[ "$val" =~ ^(true|false)$ ]];;
        ADV_XHTTP_MODE) [[ "$val" =~ ^(auto|stream-up|packet-up)$ ]];;
        ADV_XHTTP_PATH) [[ "$val" =~ ^/[A-Za-z0-9._/-]*$ ]];;
        ADV_KEEPALIVE|ADV_HEARTBEAT|ADV_TIMEOUT|ADV_CHANNEL|ADV_POOL|ADV_RETRY|ADV_DIAL|ADV_MUX_CON|ADV_MUX_VERSION|ADV_MUX_FRAME|ADV_MUX_RECEIVE|ADV_MUX_STREAM|ADV_MTU|ADV_MSS|ADV_RCVBUF|ADV_SNDBUF) mt_link_uint "$val" 0 1073741824;;
        PROFILE) [[ "$val" =~ ^(ECO|BALANCED|SPEED|LATENCY|EXTREME|NORMAL|FAST|FAST2|FAST3|MANUAL|CUSTOM)$ ]];;
        BLOCK) [[ "$val" =~ ^(aes-128-gcm|aes|aes-128|aes-192|aes-256|salsa20|blowfish|twofish|cast5|3des|tea|xtea|xor|sm4|none)$ ]];;
        KCP_MODE) [[ "$val" =~ ^(normal|fast|fast2|fast3|manual)$ ]];;
        KCP_CONN) mt_link_uint "$val" 1 32;;
        KCP_MTU) mt_link_uint "$val" 576 1500;;
        KCP_NODELAY|KCP_NOCONGESTION) [[ "$val" =~ ^[01]$ ]];;
        KCP_RESEND) mt_link_uint "$val" 0 2;;
        KCP_INTERVAL) mt_link_uint "$val" 10 5000;;
        KCP_RCVWND|KCP_SNDWND) mt_link_uint "$val" 128 32768;;
        KCP_STREAMBUF|KCP_SMUXBUF|KCP_PCAP_SOCKBUF) mt_link_uint "$val" 65536 268435456;;
        KCP_TCPBUF|KCP_UDPBUF) mt_link_uint "$val" 1024 1048576;;
        KCP_DSHARD|KCP_PSHARD|KCP_SMUXKALIVE) mt_link_uint "$val" 0 65535;;
        *) return 1;;
    esac
}

mt_link_offer() {
    local ans
    mt_ask ans 'Generate a setup link for the peer now? [Y/n]: ' || return 0
    case "${ans,,}" in n|no) return 0;; esac
    mt_link_export "$1"
}

mt_link_import() {
    local link ans name
    mt_workspace_screen
    if [ -n "${MT_PEER_LINK:-}" ]; then link="$MT_PEER_LINK"; MT_PEER_LINK=; else mt_link_read_input link "  ${C}●${NC} ${W}Paste Peer Setup Link (q: back): ${NC} " || return 1; fi
    [ "$link" != q ] || return 0
    mt_link_decode "$link" || { echo -e "  ${R}✖ Invalid / expired link. No changes made.${NC}"; mt_workspace_pause; return 1; }
    echo -e "\n  ${FR}┌─[ PEER SETUP PREVIEW ]${NC}"
    echo -e "  ${FR}│${NC}"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$FR" "$NC" "$W" "Module" "$NC" "$DIM" "$NC" "$W" "$MT_KIND" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$FR" "$NC" "$W" "Role" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[ROLE]}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$FR" "$NC" "$W" "Peer" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[HOST]:--}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$FR" "$NC" "$W" "Link port" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[LINK_PORT]:--}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$FR" "$NC" "$W" "Transport" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[TRANSPORT]:-${MT_LINK_DATA[PROTO]:-KCP/TCP}}" "$NC"
    if [ -n "${MT_LINK_DATA[PROFILE]:-}" ]; then
        printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$FR" "$NC" "$W" "Profile" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[PROFILE]}" "$NC"
    fi
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$FR" "$NC" "$W" "TCP ports" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[TCP_PORTS]:-${MT_LINK_DATA[PORTS]:--}}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$FR" "$NC" "$W" "UDP ports" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[UDP_PORTS]:--}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$FR" "$NC" "$W" "vIPs" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[MAX_IPS]:--}" "$NC"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}└─${NC} ${W}Secret is hidden. Existing tunnels will not be overwritten.${NC}"
    mt_ask name "Local tunnel name/suffix [${MT_LINK_DATA[NAME]}]: " || return 1
    name="${name:-${MT_LINK_DATA[NAME]}}"
    mt_link_field_valid NAME "$name" || { echo 'Invalid name.' >&2; return 1; }
    MT_LINK_DATA[NAME]="$name"
    mt_ask ans 'Is this correct? Create this peer tunnel? [y/N]: ' || return 1
    [[ "${ans,,}" == y || "${ans,,}" == yes ]] || return 0
    mt_peer_ensure_core || { echo -e "  ${Y}● Peer setup cancelled before deployment.${NC}"; mt_workspace_pause; return 1; }
    if mt_link_deploy; then
        echo -e "  ${G}● Peer configuration created. Check Live Monitor for the peer connection.${NC}"
        mt_sync_bbr_from_peer "${MT_LINK_DATA[BBR]:-0}"
    else echo -e "  ${R}✖ Creation failed; see the error above.${NC}"; fi
    mt_workspace_pause
}

mt_workspace_service_ready() {
    local attempt
    for attempt in 1 2 3 4; do sleep .4; systemctl is-active --quiet "$1" || return 1; done
}

mt_workspace_update_badge() {
    local rv file="$SECURE_TMP/.${BT_MOD}_remote_ver"
    [ -f "$file" ] || return 0
    rv=$(tr -d '\r\n ' < "$file")
    if mt_update_available "$rv" "$MODULE_VERSION"; then
        printf ' %b(Update Available: v%s)%b' "$Y" "$rv" "$NC"
    fi
    return 0
}
