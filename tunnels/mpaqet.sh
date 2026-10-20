#!/bin/bash
# --- MTunnel MPaqet | Raw Packet KCP Engine v1.2.7 ---
# [Features: Unified Flat Menu | First-Run Prompt | Port Collision Check | Signal-Safe Menu | Full Uninstaller]

MODULE_VERSION="1.2.7"
MTUNNEL_REQUIRED_CORE_API=1
MTUNNEL_REQUIRED_LAYOUT_REV=2
umask 077

# MTUNNEL_COMMON_LOADER -- common API 1, required by this module.
# Source next to a checkout first, or from the system-wide installed location.
# No network calls, implicit fallbacks to generated code, or silent failures.
mt_load_common() {
    local script_dir candidate
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    for candidate in \
        "$script_dir/core/common.sh" \
        "$script_dir/../core/common.sh" \
        /usr/lib/mtunnel/common.sh \
        /root/mtunnel/core/common.sh; do
        if [[ -f "$candidate" && -r "$candidate" ]]; then
            # A bad or incompatible shared core must fail loudly, not fall back.
            source "$candidate" || return 1
            if [[ "${MTUNNEL_CORE_API:-}" == "${MTUNNEL_REQUIRED_CORE_API:-1}" && "${MTUNNEL_LAYOUT_REV:-}" == "${MTUNNEL_REQUIRED_LAYOUT_REV:-2}" ]]; then return 0; fi
            printf 'MTunnel: incompatible shared core: %s\n' "$candidate" >&2
            return 1
        fi
    done
    echo 'MTunnel: core/common.sh is missing. Reinstall the complete bundle (bash install.sh --local .).' >&2
    return 1
}
mt_load_common || exit 1
if ! declare -F mt_hdr_draw >/dev/null || ! declare -F mt_port_guard >/dev/null || ! declare -F mt_unit_tcp_rtt >/dev/null; then
    echo 'MTunnel: the installed shared core (common.sh) is older than this module (requires the current shared-core API/layout).' >&2
    echo 'Update the whole bundle from the main menu (Sync) or run: bash install.sh --local .' >&2
    exit 1
fi
unset -f mt_load_common
if [ "$EUID" != 0 ]; then echo "Run MTunnel with sudo." >&2; exit 1; fi


















B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mpaqet"
CONF_DIR="/etc/paqet"
SERVICE_DIR="/etc/systemd/system"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

# Never delete a pre-existing executable merely by opening this menu.

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$CONF_DIR" "$SECURE_TMP" 2>/dev/null
find "$CONF_DIR" -maxdepth 2 -type f -exec chmod 600 {} + 2>/dev/null || true
chmod 700 "$SECURE_TMP" 2>/dev/null
rm -f "$SECURE_TMP/.mpaqet_in_menu" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    mt_install_files 755 "$0" "$INSTALL_PATH" || { echo "Cannot install module." >&2; exit 1; }
fi

is_newer_version() {   # is_newer_version REMOTE LOCAL -> true only if REMOTE > LOCAL
    [ -n "$1" ] && mt_update_available "$1" "$2"
}

is_valid_host() {
    mt_valid_host "$1" && [[ "$1" != *:* ]]
}

MAIN_PID=$$
NEED_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1
NEED_HDR=false
trap 'NEED_HDR=true' SIGUSR2

UPDATE_CHECK_INTERVAL=60

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
            if [ -z "$buffer" ] && [ -n "$redraw_func" ]; then
                NEED_REFRESH=false
                "$redraw_func"
                echo -ne "$prompt$buffer"
            fi
        fi

        if [ "$NEED_HDR" = true ]; then
            NEED_HDR=false
            [ -n "$redraw_func" ] && refresh_header_live
        fi
        IFS= read -rsn1 -t 0.3 char
        rc=$?
        if [ $rc -ne 0 ]; then
            if [ "$rc" -eq 142 ] || [ "$rc" -gt 128 ]; then
                continue
            fi
    rm -f "$SECURE_TMP/.mpaqet_in_menu" 2>/dev/null
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

    rm -f "$SECURE_TMP/.mpaqet_in_menu" 2>/dev/null
    printf -v "$__resultvar" '%s' "$buffer"
}

fetch_remote_version() {
    local url="$1" payload version=""
    if command -v curl >/dev/null 2>&1; then
        payload=$(curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 8 "$url" 2>/dev/null) || return 1
    elif command -v wget >/dev/null 2>&1; then
        payload=$(wget -qO- --header="Cache-Control: no-cache" --timeout=8 "$url" 2>/dev/null) || return 1
    else
        return 1
    fi
    version=$(printf '%s\n' "$payload" | sed -n 's/^MODULE_VERSION="\([^" ]*\)".*/\1/p' | head -n 1)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || return 1
    printf '%s\n' "$version"
}
# Keeps the last known good value when a source is unreachable (no "Unknown" overwrite).
check_update_bg() {
    local cb="?t=$(date +%s)" gh_ver="" mirror_ver="" latest_ver="" cand
    gh_ver=$(fetch_remote_version "${MTUNNEL_GITHUB_BASE}/tunnels/mpaqet.sh${cb}")
    mirror_ver=$(fetch_remote_version "${MTUNNEL_MIRROR_BASE}/tunnels/mpaqet.sh${cb}")
    [ -n "$gh_ver" ] && printf '%s\n' "$gh_ver" > "$SECURE_TMP/.mpaqet_remote_ver_github"
    [ -n "$mirror_ver" ] && printf '%s\n' "$mirror_ver" > "$SECURE_TMP/.mpaqet_remote_ver_mirror"
    for cand in "$gh_ver" "$mirror_ver"; do
        [[ "$cand" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || continue
        latest_ver=$(printf '%s\n%s\n' "$latest_ver" "$cand" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' | sort -V | tail -n 1)
    done
    [ -n "$latest_ver" ] && printf '%s\n' "$latest_ver" > "$SECURE_TMP/.mpaqet_remote_ver"
    return 0
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
if [[ "${1:-}" != --* ]]; then update_watcher_loop & fi
WATCHER_PID=$!
trap 'kill "$WATCHER_PID" ${HDR_PID:-} 2>/dev/null; rm -f "$SECURE_TMP/.mpaqet_in_menu" 2>/dev/null' EXIT

self_update_module() {
    local src_opt="${1:-}" custom_url dl_url tmp_file confirm
    local rel_path="tunnels/mpaqet.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mpaqet_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mpaqet_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ "$remote_v" != "Unknown" ] && is_newer_version "$remote_v" "$MODULE_VERSION"; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    if [ -z "$src_opt" ]; then
    clear; echo -e "\n  ${DIM}┌─[ OTA Update (MPaqet Engine) ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ AUTOMATIC MIRRORS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${gh_text}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Iranian Mirror${NC} ${DIM}(${MTUNNEL_MIRROR_BASE})${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MANUAL OVERRIDES ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Nano / Ctrl+X to Save)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
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
        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read -r confirm
        
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
# mt_choose_peer_host supplied by core/common.sh

is_paqet_core_valid() {
    local candidate
    for candidate in /usr/local/bin/paqet /usr/bin/paqet; do
        [ -x "$candidate" ] && mt_valid_elf "$candidate" && return 0
    done
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
    local src_choice="$1" arch target dl_url kind=url
    arch=$(uname -m)
    case "$arch" in x86_64) target=amd64;; aarch64|arm64) target=arm64;; *) echo -e "  ${R}✖ Unsupported CPU architecture.${NC}"; return 1;; esac
    case "$src_choice" in
        1|2)
            local asset="paqet-linux-${target}-v1.0.0-alpha.21.tar.gz"
            dl_url="https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.21/$asset"
            [ "$src_choice" != 2 ] || dl_url="${MTUNNEL_MIRROR_BASE}/packages/$asset"
            ;;
        3) echo -ne "  ${C}● Enter Direct Link: ${NC}"; read -r dl_url; [ -n "$dl_url" ] || return 0;;
        4) dl_url="$LOCAL_DIR/packages/paqet"; kind=local;;
        *) return 0;;
    esac
    echo -e "  ${DIM}● Preparing MPaqet Core...${NC}"
    if mt_update_core "paqet" "mpaqet" "$dl_url" "$kind"; then
        echo -e "  ${G}✔ MPaqet Core installed successfully.${NC}"
        echo -e "  ${DIM}● Previously active tunnels restarted.${NC}"
    else
        echo -e "  ${R}✖ Core update failed. Previous installation preserved.${NC}" >&2
        return 1
    fi
}

mt_core_version() {
    local out
    out=$(paqet --version 2>/dev/null | head -n1)
    [ -n "$out" ] || out=$(paqet -V 2>/dev/null | head -n1)
    out=$(printf '%s' "$out" | grep -oE '[0-9]+(\.[0-9A-Za-z-]+)+' | head -n1)
    printf '%s' "${out:-not-installed}"
}
mt_install_local_bundle() {
    local installer="$LOCAL_DIR/install.sh" rc=0
    if [ -f "$installer" ]; then
        bash "$installer" --local "$LOCAL_DIR" --no-launch || rc=1
    else
        echo -e "  ${R}✖ $LOCAL_DIR/install.sh was not found.${NC}"; rc=1
    fi
    if ! install_core_from_source 4; then
        echo -e "  ${Y}● Local Paqet core was not found; scripts/tools were still processed.${NC}"
        rc=1
    fi
    return "$rc"
}
mt_update_label() {
    local file="$1" rv='Unknown'
    [ -f "$file" ] && rv=$(tr -d '\r\n ' < "$file")
    if [ -n "$rv" ] && [ "$rv" != Unknown ]; then
        if mt_update_available "$rv" "$MODULE_VERSION" 2>/dev/null; then printf 'v%s → v%s' "$MODULE_VERSION" "$rv"
        else printf 'v%s' "$rv"; fi
    else printf 'version unavailable'; fi
}
render_unified_update_menu() {
    local gh_label mirror_label core_v core_tag=""
    gh_label=$(mt_update_label "$SECURE_TMP/.mpaqet_remote_ver_github")
    mirror_label=$(mt_update_label "$SECURE_TMP/.mpaqet_remote_ver_mirror")
    core_v=$(mt_core_version)
    [ -n "$core_v" ] && [ "$core_v" != "not-installed" ] && core_tag=" ${G}(installed)${NC}"
    mt_workspace_screen
    echo -e "\n  ${DIM}┌─[ UPDATE & LOCAL INSTALL — MPAQET ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Install Core From Github${NC}${core_tag}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Install Core From Iranian Mirror${NC}${core_tag}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Install Script From Github${NC} ${DIM}(${gh_label})${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Install Script From Iranian Mirror${NC} ${DIM}(${mirror_label})${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Install Everything from /root/mtunnel${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${Y}Paste Script Code Manually${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return${NC}\n"
}
unified_update_menu() {
    local opt
    while true; do
        render_unified_update_menu
        read_with_refresh "  ${C}MPAQET UPDATE ❯❯ ${NC}" opt render_unified_update_menu || return 0
        opt="${opt//$'\r'/}"
        case "$opt" in
            1) install_core_from_source 1; mt_workspace_pause;;
            2) install_core_from_source 2; mt_workspace_pause;;
            3) self_update_module 1; mt_workspace_pause;;
            4) self_update_module 2; mt_workspace_pause;;
            5) mt_install_local_bundle; mt_workspace_pause;;
            6) self_update_module 4; mt_workspace_pause;;
            0|q|Q) return 0;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1;;
        esac
    done
}

menu_install_core() {
    echo -e "\n  ${DIM}┌─[ INSTALL / UPDATE PAQET CORE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Iranian Mirror${NC} ${DIM}(${MTUNNEL_MIRROR_BASE})${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/paqet)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_choice
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
            echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Iranian Mirror${NC} ${DIM}(${MTUNNEL_MIRROR_BASE})${NC}"
            echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/paqet)${NC}"
            echo -e "  ${DIM}│${NC}"
            echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Skip for now${NC}\n"
            echo -ne "  ${C}Select Source ❯❯ ${NC}"; read init_opt
            init_opt=$(echo "$init_opt" | tr -d '\r ')
            if [[ "$init_opt" =~ ^[1-4]$ ]]; then
                install_core_from_source "$init_opt"
            fi
        fi
    fi
}

resolve_paqet_route() {
    local target="$1" route next_hop mac
    if ! mt_valid_ipv4 "$target"; then
        target=$(getent ahostsv4 "$target" 2>/dev/null | awk 'NR==1{print $1}')
        mt_valid_ipv4 "$target" || return 1
    fi
    route=$(ip -4 route get "$target" 2>/dev/null) || return 1
    PQ_ROUTE_IFACE=$(awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}' <<< "$route")
    PQ_ROUTE_SRC=$(awk '{for(i=1;i<NF;i++)if($i=="src"){print $(i+1);exit}}' <<< "$route")
    next_hop=$(awk '{for(i=1;i<NF;i++)if($i=="via"){print $(i+1);exit}}' <<< "$route")
    next_hop="${next_hop:-$target}"
    [ -n "$PQ_ROUTE_IFACE" ] && mt_valid_ipv4 "$PQ_ROUTE_SRC" || return 1
    mac=$(ip -4 neigh show to "$next_hop" dev "$PQ_ROUTE_IFACE" 2>/dev/null | awk '$0!~/FAILED|INCOMPLETE/{for(i=1;i<NF;i++)if($i=="lladdr"){print $(i+1);exit}}')
    if [ -z "$mac" ]; then
        ping -I "$PQ_ROUTE_IFACE" -c 1 -W 1 "$next_hop" >/dev/null 2>&1 || true
        mac=$(ip -4 neigh show to "$next_hop" dev "$PQ_ROUTE_IFACE" 2>/dev/null | awk '$0!~/FAILED|INCOMPLETE/{for(i=1;i<NF;i++)if($i=="lladdr"){print $(i+1);exit}}')
    fi
    if [[ ! "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ || "$mac" == 00:00:00:00:00:00 ]]; then
        echo -ne "  ${C}●${NC} ${W}MAC of next hop $next_hop on $PQ_ROUTE_IFACE: ${NC}"; read -r mac
    fi
    [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ && "$mac" != 00:00:00:00:00:00 ]] || return 1
    PQ_ROUTE_MAC="$mac"; PQ_ROUTE_TARGET="$target"
}

paqet_port_available() {
    local port="$1" skip="${2:-}" conf role link ports
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        [ "$(basename "$conf" .meta)" != "$skip" ] || continue
        role=$(sed -n 's/^ROLE=//p' "$conf")
        link=$(sed -n 's/^TUN_PORT=//p' "$conf")
        ports=$(sed -n 's/^TCP_PORTS=//p' "$conf")
        if [ "$role" == 1 ] && [ "$link" == "$port" ]; then return 1; fi
        mt_list_has_port "$ports" "$port" && return 1
    done
    return 0
}

validate_paqet_ports() {
    local list="$1" skip="${2:-}" owned='' p; local -a parts=()
    [ -z "$skip" ] || owned=$(sed -n 's/^TCP_PORTS=//p' "$CONF_DIR/$skip.meta" 2>/dev/null)
    [ -n "$list" ] && mt_validate_port_list "$list" 1 tcp "$owned" || return 1
    IFS=, read -ra parts <<< "$list"
    for p in "${parts[@]}"; do paqet_port_available "$p" "$skip" || return 1; done
}

setup_paqet_counters() {
    local name="$1"; local l_port="$2"
    iptables -w 5 -t mangle -C INPUT -p tcp --dport "$l_port" -m comment --comment "MPAQET_RX_${name}" >/dev/null 2>&1 || iptables -w 5 -t mangle -A INPUT -p tcp --dport "$l_port" -m comment --comment "MPAQET_RX_${name}" 2>/dev/null
    iptables -w 5 -t mangle -C OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_TX_${name}" >/dev/null 2>&1 || iptables -w 5 -t mangle -A OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_TX_${name}" 2>/dev/null
    
    iptables -w 5 -t raw -C PREROUTING -p tcp --dport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" >/dev/null 2>&1 || iptables -w 5 -t raw -A PREROUTING -p tcp --dport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" 2>/dev/null
    iptables -w 5 -t raw -C OUTPUT -p tcp --sport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" >/dev/null 2>&1 || iptables -w 5 -t raw -A OUTPUT -p tcp --sport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" 2>/dev/null
    
    iptables -w 5 -t mangle -C OUTPUT -p tcp --sport "$l_port" --tcp-flags RST RST -j DROP -m comment --comment "MPAQET_RST_${name}" >/dev/null 2>&1 || iptables -w 5 -t mangle -A OUTPUT -p tcp --sport "$l_port" --tcp-flags RST RST -j DROP -m comment --comment "MPAQET_RST_${name}" 2>/dev/null
}

clean_paqet_counters() {
    local name="$1"
    local chain rulenum
    rm -f "$SECURE_TMP/.mpaqet_link_${name}" "$SECURE_TMP/.mpaqet_peer_${name}" 2>/dev/null
    for chain in INPUT OUTPUT; do
        while read -r rulenum; do
            [ -n "$rulenum" ] && iptables -w 5 -t mangle -D "$chain" "$rulenum" 2>/dev/null
        done < <(iptables -t mangle -L "$chain" -n --line-numbers 2>/dev/null | grep -E "MPAQET_(RX|TX|RST|PEER|LINK)_${name}( |\*/)" | awk '{print $1}' | tac)
    done
    for chain in PREROUTING OUTPUT; do
        while read -r rulenum; do
            [ -n "$rulenum" ] && iptables -w 5 -t raw -D "$chain" "$rulenum" 2>/dev/null
        done < <(iptables -t raw -L "$chain" -n --line-numbers 2>/dev/null | grep -E "MPAQET_RAW_${name}( |\*/)" | awk '{print $1}' | tac)
    done
}

zero_paqet_counters() {
    local name="$1" table chain tag num
    if [ -z "$name" ]; then
        local conf
        for conf in "$CONF_DIR"/*.meta; do [ -f "$conf" ] && zero_paqet_counters "$(basename "$conf" .meta)"; done
        return 0
    fi
    for table in mangle raw; do
        for chain in INPUT OUTPUT PREROUTING; do
            for tag in RX TX RAW RST PEER LINK; do
                while read -r num; do [ -n "$num" ] && iptables -w 5 -t "$table" -Z "$chain" "$num"; done < <(mt_tagged_rules iptables "$table" "$chain" "MPAQET_${tag}_${name}")
            done
        done
    done
}

# Extra iptables rules used only for detection (never drop or alter traffic):
#   server: xt_recent list of sources hitting the tunnel port  -> client IP
#   client: counter of packets coming from the server port      -> link liveness
setup_paqet_probe() {
    local name="$1" meta="$CONF_DIR/${name}.meta" role port remote src_args=()
    [ -f "$meta" ] || return 0
    role=$(grep -m1 '^ROLE=' "$meta" | cut -d'=' -f2 | tr -d '"\r ')
    port=$(grep -m1 '^TUN_PORT=' "$meta" | cut -d'=' -f2 | tr -d '"\r ')
    remote=$(grep -m1 '^REMOTE_IP=' "$meta" | cut -d'=' -f2 | tr -d '"\r ')
    [[ "$port" =~ ^[0-9]+$ ]] || return 0
    # Replace any pre-1.0.10 broad detector rule. Keeping an old broad rule
    # would make same-port instances count each other's traffic after upgrade.
    mt_delete_tagged_rules iptables mangle INPUT "MPAQET_PEER_${name}" >/dev/null 2>&1 || true
    mt_delete_tagged_rules iptables mangle INPUT "MPAQET_LINK_${name}" >/dev/null 2>&1 || true
    if [ "$role" = "1" ]; then
        iptables -w 5 -t mangle -C INPUT -p tcp --dport "$port" -m recent --set --name "mpq_${name}" --rsource -m comment --comment "MPAQET_PEER_${name}" >/dev/null 2>&1 || \
        iptables -w 5 -t mangle -A INPUT -p tcp --dport "$port" -m recent --set --name "mpq_${name}" --rsource -m comment --comment "MPAQET_PEER_${name}" >/dev/null 2>&1
    else
        # Client-side liveness must be scoped to this instance's remote host as
        # well as the port. Several Paqet tunnels can legitimately use the
        # same server port on different remote servers.
        mt_valid_ipv4 "$remote" 2>/dev/null && src_args=(-s "$remote")
        iptables -w 5 -t mangle -C INPUT -p tcp "${src_args[@]}" --sport "$port" -m comment --comment "MPAQET_LINK_${name}" >/dev/null 2>&1 || \
        iptables -w 5 -t mangle -A INPUT -p tcp "${src_args[@]}" --sport "$port" -m comment --comment "MPAQET_LINK_${name}" >/dev/null 2>&1
    fi
    return 0
}

if [[ "${1:-}" == "--delete-all" ]]; then
    # Delete every Paqet tunnel (units, firewall counters, configs) but keep this script and the paqet core.
    for conf in "$CONF_DIR"/*.yaml; do
        [ -f "$conf" ] || continue
        systemctl disable --now "mpaqet@$(basename "$conf" .yaml)" >/dev/null 2>&1
    done
    systemctl stop 'mpaqet@*' mpaqet-apply.service >/dev/null 2>&1
    systemctl disable 'mpaqet@*' mpaqet-apply.service >/dev/null 2>&1
    for chain in INPUT OUTPUT PREROUTING; do
        mt_delete_tagged_rules iptables mangle "$chain" "MPAQET_" substring 2>/dev/null || true
        mt_delete_tagged_rules iptables raw "$chain" "MPAQET_" substring 2>/dev/null || true
    done
    rm -f /etc/systemd/system/multi-user.target.wants/mpaqet@*.service /etc/systemd/system/mpaqet@.service /etc/systemd/system/mpaqet-apply.service
    systemctl daemon-reload >/dev/null 2>&1
    [ -d "$CONF_DIR" ] && find "$CONF_DIR" -mindepth 1 -maxdepth 1 ! -name '.*' -exec rm -rf {} +
    rm -f "$SECURE_TMP"/.mpaqet_link_* "$SECURE_TMP"/.mpaqet_peer_* 2>/dev/null
    exit 0
fi
if [[ "$1" == "--apply" ]]; then
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        t_name=$(basename "$conf" .meta)
        ROLE=""; TUN_PORT=""; TCP_PORTS=""; mt_source_conf "$conf" 2>/dev/null
        
        if [ "$ROLE" == "1" ]; then
            setup_paqet_counters "$t_name" "$TUN_PORT"
        else
            if [ -n "$TCP_PORTS" ]; then
                IFS=',' read -ra P_ARR <<< "$TCP_PORTS"
                for p_clean in "${P_ARR[@]}"; do
                    if mt_valid_port "$p_clean"; then
                        setup_paqet_counters "$t_name" "$p_clean"
                    fi
                done
            fi
        fi
        setup_paqet_probe "$t_name"
    done
    exit 0
fi

get_paqet_rx() {
    local data; data=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null)
    mt_counter_sum "$data" "MPAQET_RX_$1"
}

get_paqet_tx() {
    local data; data=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null)
    mt_counter_sum "$data" "MPAQET_TX_$1"
}

# ================================================================
# KCP PROFILE ENGINE - official Paqet core, no custom binary, no python
# ================================================================
KCP_PROFILE="FAST"
KCP_MODE="fast"
KCP_CONN=2
KCP_MTU=1350
KCP_RCVWND=1024
KCP_SNDWND=1024
KCP_SMUXBUF=4194304
KCP_STREAMBUF=2097152
KCP_PCAP_SOCKBUF=8388608
KCP_TCPBUF=8192
KCP_UDPBUF=4096
KCP_NODELAY=1
KCP_WDELAY=false
KCP_ACKNODELAY=true
KCP_INTERVAL=20
KCP_RESEND=2
KCP_NOCONGESTION=1

cpu_cores() { local n; n=$(nproc 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || n=1; echo "$n"; }
cap_at() { local v="$1" m="$2"; [ "$v" -gt "$m" ] && v="$m"; echo "$v"; }

# CPU cost of a raw-packet KCP tunnel is per PACKET, not per megabit, and every extra conn adds a
# session (timers, buffers, crypto). So the profiles below (a) batch writes/acks (wdelay=true,
# acknodelay=false => fewer small packets), (b) keep conn close to the CPU core count of THIS machine
# and (c) never touch the MTU (KCP_MTU empty = keep the tunnel's current MTU, clamped to the NIC).
# They are written as explicit KCP values (mode "manual"), so every number really takes effect.
# smuxbuf follows the rule from the paqet tuning guide: >= 2 x streambuf x conn.
profile_defaults() {
    local profile="${1^^}" role="${2:-client}" cores
    cores=$(cpu_cores)
    KCP_PROFILE="$profile"; KCP_MTU=""
    KCP_MODE=manual; KCP_NODELAY=0; KCP_WDELAY=true; KCP_ACKNODELAY=false
    KCP_INTERVAL=30; KCP_RESEND=2; KCP_NOCONGESTION=1
    KCP_RCVWND=1024; KCP_SNDWND=1024; KCP_STREAMBUF=2097152
    KCP_PCAP_SOCKBUF=8388608; KCP_TCPBUF=8192; KCP_UDPBUF=4096
    case "$profile" in
        ECO)      KCP_CONN=1; KCP_INTERVAL=50 ;;
        BALANCED) KCP_CONN=$(cap_at "$cores" 2) ;;
        SPEED)    KCP_CONN=$(cap_at "$cores" 4); KCP_NODELAY=1; KCP_INTERVAL=20
                  KCP_RCVWND=2048; KCP_SNDWND=2048; KCP_STREAMBUF=4194304; KCP_PCAP_SOCKBUF=16777216; KCP_TCPBUF=16384; KCP_UDPBUF=8192 ;;
        LATENCY)  KCP_CONN=$(cap_at "$cores" 2); KCP_NODELAY=1; KCP_INTERVAL=10; KCP_WDELAY=false; KCP_ACKNODELAY=true ;;
        # EXTREME: 300+ Mbit on 4+ cores. conn follows the cores (max 8), windows 4096, and buffers sized as in
        # the paqet tuning guide (streambuf 8MB, smuxbuf = 2 x stream x conn: 64MB at 4 conn, 128MB at 8).
        EXTREME)  KCP_CONN=$(cap_at "$cores" 8); [ "$KCP_CONN" -lt 2 ] && KCP_CONN=2
                  KCP_NODELAY=1; KCP_INTERVAL=20; KCP_RCVWND=4096; KCP_SNDWND=4096
                  KCP_STREAMBUF=8388608; KCP_PCAP_SOCKBUF=33554432; KCP_TCPBUF=65536; KCP_UDPBUF=16384 ;;
        # classic paqet built-in modes (only the four kcptun timers change)
        NORMAL)   KCP_MODE=normal; KCP_CONN=1; KCP_RCVWND=512; KCP_SNDWND=512
                  [ "$role" = "server" ] && { KCP_RCVWND=1024; KCP_SNDWND=1024; } ;;
        FAST)     KCP_MODE=fast;  KCP_CONN=$(cap_at "$cores" 2) ;;
        FAST2)    KCP_MODE=fast2; KCP_CONN=$(cap_at "$cores" 4) ;;
        FAST3)    KCP_MODE=fast3; KCP_CONN=$(cap_at "$cores" 4); KCP_PCAP_SOCKBUF=16777216 ;;
        MANUAL|CUSTOM) KCP_MODE=manual; KCP_CONN=$(cap_at "$cores" 2) ;;
        *) profile_defaults BALANCED "$role"; return 0 ;;
    esac
    KCP_SMUXBUF=$((KCP_STREAMBUF * 2 * KCP_CONN))
    return 0
}

kcp_nic_mtu() {
    local iface; iface=$(get_yaml_value interface "$1")
    [ -n "$iface" ] && cat "${SYS_NET_DIR:-/sys/class/net}/$iface/mtu" 2>/dev/null
}
# Highest KCP MTU the network interface can carry (NIC MTU minus IP/TCP headers and a safety margin).
kcp_mtu_cap() {
    local nic c; nic=$(kcp_nic_mtu "$1")
    [[ "$nic" =~ ^[0-9]+$ ]] || return 0
    c=$((nic - 100)); [ "$c" -lt 576 ] && c=576
    echo "$c"
}

get_yaml_value() {
    local key="$1" file="$2"
    awk -v k="$key" '$1 == k":" {gsub(/"/,"",$2); print $2; exit}' "$file" 2>/dev/null
}

get_tunnel_profile() {
    local t_name="$1" meta="$CONF_DIR/${t_name}.meta" yaml="$CONF_DIR/${t_name}.yaml" p mode
    [ -f "$meta" ] && p=$(grep -m1 '^PROFILE=' "$meta" | cut -d'=' -f2 | tr -d '\r" ')
    if [ -z "$p" ] && [ -f "$yaml" ]; then
        mode=$(get_yaml_value mode "$yaml")
        case "$mode" in normal) p=NORMAL;; fast) p=FAST;; fast2) p=FAST2;; fast3) p=FAST3;; manual) p=MANUAL;; *) p=CUSTOM;; esac
    fi
    echo "${p:-CUSTOM}"
}

set_meta_profile() {
    local t_name="$1" profile="$2" meta="$CONF_DIR/${t_name}.meta"
    [ ! -f "$meta" ] && return 0
    if grep -q '^PROFILE=' "$meta"; then sed -i "s/^PROFILE=.*/PROFILE=$profile/" "$meta"; else echo "PROFILE=$profile" >> "$meta"; fi
}

# A hand edit (MTU / conn) of a preset makes it a custom profile, so the label never lies.
mark_profile_custom() {
    local t_name="$1"
    case "$(get_tunnel_profile "$t_name")" in ECO|BALANCED|SPEED|LATENCY|EXTREME|NORMAL|FAST|FAST2|FAST3) set_meta_profile "$t_name" CUSTOM ;; esac
}

ask_int() {   # ask_int VAR "label" default min max
    local __v="$1" label="$2" def="$3" min="$4" max="$5" ans
    while true; do
        mt_ask ans "${label} [${def}] (${min}-${max}): " || return 1
        ans="${ans:-$def}"
        if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge "$min" ] && [ "$ans" -le "$max" ]; then
            printf -v "$__v" '%s' "$ans"; return 0
        fi
        echo -e "  ${R}✖ Enter a whole number between ${min} and ${max}.${NC}"
    done
}

ask_bool() {  # ask_bool VAR "label" default(true|false)
    local __v="$1" label="$2" def="$3" ans
    while true; do
        mt_ask ans "${label} [${def}] (true/false): " || return 1
        ans="${ans:-$def}"; ans="${ans,,}"
        if [ "$ans" = "true" ] || [ "$ans" = "false" ]; then printf -v "$__v" '%s' "$ans"; return 0; fi
        echo -e "  ${R}✖ Type true or false.${NC}"
    done
}

choose_kcp_profile() {
    local role="$1" current="${2:-BALANCED}" choice sub cores
    cores=$(cpu_cores)
    mt_workspace_screen
    echo -e "\n  ${B}╭──────────────────────── KCP PROFILE ────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}CPU-aware presets. MTU is never changed by a profile.${NC}"
    echo -e "  ${B}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC} ${G}1${NC}) ECO         lowest CPU: 1 conn, slow timers, batched"
    echo -e "  ${B}│${NC} ${C}2${NC}) BALANCED    default: up to 2 conn, batched writes/acks"
    echo -e "  ${B}│${NC} ${Y}3${NC}) SPEED       up to 4 conn, window 2048, fast timers"
    echo -e "  ${B}│${NC} ${M}4${NC}) LOW-LATENCY fastest timers, immediate flush (more CPU)"
    echo -e "  ${B}│${NC} ${W}5${NC}) MANUAL      every KCP value by hand (validated)"
    echo -e "  ${B}│${NC} ${W}6${NC}) CLASSIC     paqet built-in normal / fast / fast2 / fast3"
    echo -e "  ${B}│${NC} ${R}7${NC}) EXTREME     300+ Mbit: needs 4+ cores and 2GB+ RAM, window 4096"
    echo -e "  ${B}│${NC} ${DIM}Current: ${current}   |   CPU cores on this server: ${cores}${NC}"
    echo -e "  ${B}╰─────────────────────────────────────────────────────────────╯${NC}"
    echo -e "  ${DIM}Apply the profile on BOTH servers. conn is capped by this server's cores.${NC}"
    echo -ne "  ${C}Profile ❯❯ ${NC}"; read choice
    case "$choice" in
        1) profile_defaults ECO "$role";;
        2) profile_defaults BALANCED "$role";;
        3) profile_defaults SPEED "$role";;
        4) profile_defaults LATENCY "$role";;
        6)
            echo -ne "  ${C}1) normal  2) fast  3) fast2  4) fast3  ❯❯ ${NC}"; read sub
            case "$sub" in 1) profile_defaults NORMAL "$role";; 2) profile_defaults FAST "$role";;
                           3) profile_defaults FAST2 "$role";; 4) profile_defaults FAST3 "$role";; *) return 1;; esac ;;
        5)
            profile_defaults MANUAL "$role"
            ask_int  KCP_NODELAY      "nodelay (0=off 1=on)"        0        0 1 || return 1
            ask_bool KCP_WDELAY       "wdelay (true = batch writes, less CPU)"   true  || return 1
            ask_bool KCP_ACKNODELAY   "acknodelay (false = batch acks, less CPU)" false || return 1
            ask_int  KCP_INTERVAL     "interval ms"                  30       10 5000 || return 1
            ask_int  KCP_RESEND       "resend"                       2         0 2 || return 1
            ask_int  KCP_NOCONGESTION "nocongestion (0=off 1=on)"    1         0 1 || return 1
            local mtu_in
            mt_ask mtu_in "MTU (Enter = keep current) (576-1500): " || return 1
            if [ -n "$mtu_in" ]; then
                if [[ "$mtu_in" =~ ^[0-9]+$ ]] && [ "$mtu_in" -ge 576 ] && [ "$mtu_in" -le 1500 ]; then KCP_MTU="$mtu_in"
                else echo -e "  ${R}✖ Invalid MTU - keeping the current one.${NC}"; fi
            fi
            ask_int  KCP_RCVWND       "Receive window"               1024    128 32768 || return 1
            ask_int  KCP_SNDWND       "Send window"                  1024    128 32768 || return 1
            ask_int  KCP_CONN         "Connections (about = CPU cores)" "$KCP_CONN" 1 32 || return 1
            ask_int  KCP_STREAMBUF    "Stream buffer"                2097152 65536 134217728 || return 1
            KCP_SMUXBUF=$((KCP_STREAMBUF * 2 * KCP_CONN))
            ask_int  KCP_SMUXBUF      "SMUX buffer (>= 2 x stream x conn)" "$KCP_SMUXBUF" 65536 268435456 || return 1
            ask_int  KCP_PCAP_SOCKBUF "PCAP sockbuf"                 8388608 65536 268435456 || return 1
            ask_int  KCP_TCPBUF       "TCP buffer"                   8192     1024 1048576 || return 1
            ask_int  KCP_UDPBUF       "UDP buffer"                   4096     1024 1048576 || return 1
            KCP_PROFILE=MANUAL
            ;;
        7)
            if [ "$cores" -lt 4 ]; then
                echo -e "  ${Y}⚠ This server has only ${cores} core(s). EXTREME is meant for 4+ cores; SPEED is safer here.${NC}"
                local go; mt_ask go "Use EXTREME anyway? [y/N]: "
                [[ "${go,,}" == "y" ]] || return 1
            fi
            profile_defaults EXTREME "$role" ;;
        *) return 1;;
    esac
    return 0
}

# Rewrites conn/tcpbuf/udpbuf, network.pcap.sockbuf and the whole kcp: block from the KCP_* globals.
# Pure awk (no python). Unknown keys inside kcp:/pcap: (dshard, pshard, smuxkalive ...) are kept.
# The result is read back and verified; on any failure the original file is left untouched and 1 is returned.
write_kcp_settings() {
    local yaml="$1" key="$2" block="$3"
    local tmp="${yaml}.kcp.new" bak="$SECURE_TMP/$(basename "$yaml").bak"

    if [ ! -f "$yaml" ] || [ -z "$key" ] || [ -z "$block" ]; then
        echo -e "  ${R}✖ Config, key or cipher not found - nothing was changed.${NC}"; return 1
    fi
    cp -f "$yaml" "$bak" 2>/dev/null

    # MTU: a preset never overrides it (empty = keep); anything above the NIC limit is lowered.
    local cur_mtu cap
    cur_mtu=$(get_yaml_value mtu "$yaml"); [[ "$cur_mtu" =~ ^[0-9]+$ ]] || cur_mtu=1350
    [ -z "$KCP_MTU" ] && KCP_MTU="$cur_mtu"
    cap=$(kcp_mtu_cap "$yaml")
    if [ -n "$cap" ] && [ "$KCP_MTU" -gt "$cap" ]; then
        echo -e "  ${Y}⚠ MTU ${KCP_MTU} is above what this interface can send (NIC MTU $(kcp_nic_mtu "$yaml")); using ${cap}.${NC}"
        KCP_MTU="$cap"
    fi

    awk -v mode="$KCP_MODE" -v conn="$KCP_CONN" -v mtu="$KCP_MTU" -v rcv="$KCP_RCVWND" -v snd="$KCP_SNDWND" \
        -v smux="$KCP_SMUXBUF" -v stream="$KCP_STREAMBUF" -v pcap="$KCP_PCAP_SOCKBUF" \
        -v tcpbuf="$KCP_TCPBUF" -v udpbuf="$KCP_UDPBUF" -v nodelay="$KCP_NODELAY" -v wdelay="$KCP_WDELAY" \
        -v ack="$KCP_ACKNODELAY" -v interval="$KCP_INTERVAL" -v resend="$KCP_RESEND" -v nc="$KCP_NOCONGESTION" \
        -v key="$key" -v block="$block" '
    BEGIN {
        n = split("key mode block mtu rcvwnd sndwnd smuxbuf streambuf nodelay wdelay acknodelay interval resend nocongestion", m, " ")
        for (i = 1; i <= n; i++) managed[m[i]] = 1
        sec = ""; in_drop = 0
    }
    function emit_network() {
        print "  pcap:"; print "    sockbuf: " pcap
        printf "%s", pcap_extra
    }
    function emit_transport() {
        print "  conn: " conn; print "  tcpbuf: " tcpbuf; print "  udpbuf: " udpbuf
        print "  kcp:"
        print "    key: \"" key "\""; print "    mode: \"" mode "\""; print "    block: \"" block "\""
        print "    mtu: " mtu; print "    rcvwnd: " rcv; print "    sndwnd: " snd
        print "    smuxbuf: " smux; print "    streambuf: " stream
        if (mode == "manual") {
            print "    nodelay: " nodelay; print "    wdelay: " wdelay; print "    acknodelay: " ack
            print "    interval: " interval; print "    resend: " resend; print "    nocongestion: " nc
        }
        printf "%s", kcp_extra
    }
    function leave_section() {
        if (sec == "network") emit_network()
        else if (sec == "transport") emit_transport()
        sec = ""; in_drop = 0
    }
    {
        line = $0
        if (line ~ /^[A-Za-z_]/) {
            leave_section()
            name = line; sub(/:.*/, "", name)
            if (name == "network" || name == "transport") { sec = name; seen[name] = 1 }
            print line; next
        }
        if (sec == "network" || sec == "transport") {
            if (line ~ /^  [A-Za-z_]/) {
                child = line; sub(/^  /, "", child); sub(/:.*/, "", child)
                if (sec == "network" && child == "pcap") { in_drop = 1; drop_child = child; next }
                if (sec == "transport" && (child == "conn" || child == "tcpbuf" || child == "udpbuf" || child == "kcp")) { in_drop = 1; drop_child = child; next }
                in_drop = 0; print line; next
            }
            if (in_drop) {
                if (line ~ /^    [A-Za-z_]/) {
                    ck = line; sub(/^    /, "", ck); sub(/:.*/, "", ck)
                    if (sec == "network" && drop_child == "pcap") {
                        if (ck != "sockbuf") pcap_extra = pcap_extra line "\n"
                    } else if (sec == "transport" && drop_child == "kcp") {
                        if (!(ck in managed)) kcp_extra = kcp_extra line "\n"
                    }
                }
                next
            }
        }
        print line
    }
    END {
        leave_section()
        if (!seen["network"] || !seen["transport"]) exit 2
    }' "$yaml" > "$tmp" 2>/dev/null
    local rc=$?

    local ok=1
    [ "$rc" -eq 0 ] && [ -s "$tmp" ] && grep -q '^role:' "$tmp" || ok=0
    if [ "$ok" -eq 1 ]; then
        [ "$(get_yaml_value mode "$tmp")"    = "$KCP_MODE" ]        || ok=0
        [ "$(get_yaml_value conn "$tmp")"    = "$KCP_CONN" ]        || ok=0
        [ "$(get_yaml_value mtu "$tmp")"     = "$KCP_MTU" ]         || ok=0
        [ "$(get_yaml_value rcvwnd "$tmp")"  = "$KCP_RCVWND" ]      || ok=0
        [ "$(get_yaml_value sndwnd "$tmp")"  = "$KCP_SNDWND" ]      || ok=0
        [ "$(get_yaml_value sockbuf "$tmp")" = "$KCP_PCAP_SOCKBUF" ] || ok=0
        [ "$(get_yaml_value key "$tmp")"     = "$key" ]             || ok=0
        [ "$(get_yaml_value block "$tmp")"   = "$block" ]           || ok=0
        if [ "$KCP_MODE" = "manual" ]; then
            [ "$(get_yaml_value interval "$tmp")" = "$KCP_INTERVAL" ] || ok=0
            [ "$(get_yaml_value nodelay "$tmp")"  = "$KCP_NODELAY" ]  || ok=0
        elif grep -qE '^    (nodelay|interval|resend|nocongestion|wdelay|acknodelay):' "$tmp"; then
            ok=0
        fi
    fi

    if [ "$ok" -ne 1 ]; then
        rm -f "$tmp"
        echo -e "  ${R}✖ Could not write the profile safely - config left unchanged (backup: $bak).${NC}"
        return 1
    fi
    mv -f "$tmp" "$yaml"
    chmod 600 "$yaml" 2>/dev/null || return 1
    return 0
}


# ================================================================
# CONNECTION / PEER DETECTION
# paqet talks through raw sockets, so the kernel has no TCP session and `ss ... ESTAB`
# is always empty. Liveness is measured from iptables packet counters instead:
#   server -> packets arriving on the tunnel port (MPAQET_RX_<name>)
#   client -> packets arriving FROM the server port (MPAQET_LINK_<name>, created by setup_paqet_probe)
# ONLINE means that counter grew since the previous sample.
# ================================================================
get_link_pkts() {
    local name="$1" role="$2" tag out
    if [ "$role" = "1" ]; then tag="MPAQET_RX_${name} */"; else tag="MPAQET_LINK_${name} */"; fi
    out=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep -F "$tag")
    if [ -z "$out" ]; then
        [ "$role" != "1" ] && setup_paqet_probe "$name"
        echo 0; return 0
    fi
    echo "$out" | awk '{s+=$1} END {print s+0}'
}

# Fallback only (first sample / counters were zeroed): last connection event in the service log.
log_link_verdict() {
    local last
    last=$(journalctl -u "mpaqet@${1}" -n 200 --no-pager 2>/dev/null | grep -Ei 'established|connection lost|retrying|failed to connect|connection closed|broken pipe' | tail -n 1)
    echo "$last" | grep -qi 'established' && echo "ONLINE"
    return 0
}

# Client IP as seen by the server: the xt_recent list filled by the MPAQET_PEER rule.
# The busiest source in the last interval wins (scanner noise sends few packets); the list is
# cleared after each read and the last answer is cached.
get_server_peer_ip() {
    local name="$1" dir="${XT_RECENT_DIR:-/proc/net/xt_recent}" f cache best
    f="$dir/mpq_${name}"; cache="$SECURE_TMP/.mpaqet_peer_${name}"
    [ -e "$f" ] || setup_paqet_probe "$name"
    if [ -r "$f" ]; then
        best=$(awk '
            { ip = ""; p = 0; ls = 0
              for (i = 1; i <= NF; i++) {
                  if ($i ~ /^src=/) ip = substr($i, 5)
                  if ($i == "oldest_pkt:") p = i
                  if ($i == "last_seen:") ls = $(i + 1)
              }
              if (ip == "" || p == 0) next
              n = NF - (p + 1)
              if (n > bn || (n == bn && ls + 0 > bl + 0)) { bn = n; bl = ls; bip = ip }
            }
            END { if (bip != "") print bip }' "$f" 2>/dev/null)
        if [[ "$best" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
            echo "$best" > "$cache"
            echo / > "$f" 2>/dev/null
        fi
    fi
    [ -s "$cache" ] && cat "$cache"
    return 0
}

# Known failure modes are read from the service log of the last 45 seconds:
#   "send: Message too large"  -> MTU above what the NIC can send  (state MTU-ERR)
#   5+ other [ERROR] lines     -> streams failing                  (state ERRORS)
apply_log_health() {
    local name="$1" v="$2" log mtu_n err_n
    log=$(journalctl -u "mpaqet@${name}" --since "45 seconds ago" --no-pager 2>/dev/null)
    mtu_n=$(printf '%s\n' "$log" | grep -c 'Message too large')
    err_n=$(printf '%s\n' "$log" | grep -c '\[ERROR\]')
    if [ "$mtu_n" -ge 3 ]; then echo "MTU-ERR"; elif [ "$err_n" -ge 5 ]; then echo "ERRORS"; else echo "$v"; fi
}

check_paqet_connection() {
    local t_name="$1" known_active="${2:-0}"
    local meta="$CONF_DIR/${t_name}.meta"
    [ ! -f "$meta" ] && { echo "OFFLINE"; return; }
    if [ "$known_active" != "1" ] && ! systemctl is-active --quiet "mpaqet@${t_name}" 2>/dev/null; then echo "OFFLINE"; return; fi

    local ROLE idle sf now cur p_pk="" p_ts="" p_v="" age verdict
    ROLE=$(grep -m1 '^ROLE=' "$meta" | cut -d'=' -f2 | tr -d '"\r ')
    idle="CONNECTING"; [ "$ROLE" = "1" ] && idle="WAITING"
    sf="$SECURE_TMP/.mpaqet_link_${t_name}"
    now=$(date +%s); cur=$(get_link_pkts "$t_name" "$ROLE")
    [ -f "$sf" ] && read -r p_pk p_ts p_v < "$sf"

    if [[ "$p_pk" =~ ^[0-9]+$ && "$p_ts" =~ ^[0-9]+$ ]]; then
        age=$((now - p_ts))
        if [ "$age" -lt 3 ] && [ -n "$p_v" ]; then echo "$p_v"; return; fi
        if [ "$age" -le 180 ] && [ "$cur" -ge "$p_pk" ]; then
            if [ "$cur" -gt "$p_pk" ]; then verdict="ONLINE"; else verdict="$idle"; fi
            verdict=$(apply_log_health "$t_name" "$verdict")
            echo "$cur $now $verdict" > "$sf"; echo "$verdict"; return
        fi
    fi
    verdict=$(log_link_verdict "$t_name"); verdict="${verdict:-$idle}"
    verdict=$(apply_log_health "$t_name" "$verdict")
    echo "$cur $now $verdict" > "$sf"; echo "$verdict"
}

pq_unit_tcp_rtt() { mt_unit_tcp_rtt "mpaqet@${1}" "$2"; }

get_peer_ping() {
    local target_ip port t_name ping_res ping_val tcp_rtt start_ts end_ts t_rtt
    target_ip=$(echo "$1" | tr -d ' \n\r'); port=$(echo "$2" | tr -d ' \n\r'); t_name="${3:-}"
    if [ -z "$target_ip" ] || [ "$target_ip" = "0.0.0.0" ]; then echo "N/A"; return; fi
    local -a pcmd=(ping); [[ "$target_ip" == *:* ]] && pcmd=(ping -6)
    ping_res=$(timeout 2 "${pcmd[@]}" -c 1 -W 1 "$target_ip" 2>/dev/null || true)
    if echo "$ping_res" | grep -q 'time='; then
        ping_val=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+' | head -n1 | awk '{print int($1+0.5)}')
        echo "${ping_val}ms"; return
    fi
    if [ -n "$t_name" ]; then
        tcp_rtt=$(pq_unit_tcp_rtt "$t_name" "$target_ip" 2>/dev/null || true)
        [ -n "$tcp_rtt" ] && { echo "$tcp_rtt"; return; }
    fi
    if [ -n "$port" ] && [[ "$port" =~ ^[0-9]+$ ]] && [[ "$target_ip" != *:* ]]; then
        start_ts=$(date +%s%3N 2>/dev/null)
        if timeout 1 bash -c "</dev/tcp/$target_ip/$port" 2>/dev/null; then
            end_ts=$(date +%s%3N 2>/dev/null)
            if [[ "$start_ts" =~ ^[0-9]+$ && "$end_ts" =~ ^[0-9]+$ ]]; then
                t_rtt=$((end_ts-start_ts)); [ "$t_rtt" -le 0 ] && t_rtt=1
                echo "${t_rtt}ms*"; return
            fi
        fi
    fi
    echo "Timeout"
}

# ---- Per-tunnel header rows: background cache + in-place live refresh ----
HDR_ROWS_FILE="$SECURE_TMP/.mpaqet_hdr_rows"
HDR_DRAWN_ROWS=0
hdr_ping_probe() {
    local ip="$1" name="${2:-}" res loss avg="---" tcp_rtt
    local -a pcmd=(ping); [[ "$ip" == *:* ]] && pcmd=(ping -6)
    res=$(timeout 3 "${pcmd[@]}" -c 2 -i 0.2 -W 1 "$ip" 2>/dev/null || true)
    loss=$(echo "$res" | grep -oP '[0-9]+(?=% packet loss)' | head -n1); [ -n "$loss" ] || loss=100
    if echo "$res" | grep -q 'min/avg/max'; then
        avg=$(echo "$res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2 | head -n1)
        [ -n "$avg" ] && avg="$(awk -v v="$avg" 'BEGIN {printf "%.0fms", v}')" || avg="---"
    elif [ -n "$name" ]; then
        tcp_rtt=$(pq_unit_tcp_rtt "$name" "$ip" 2>/dev/null || true)
        if [ -n "$tcp_rtt" ]; then avg="$tcp_rtt"; loss="---"; fi
    fi
    echo "${avg}|${loss}"
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
hdr_ss_peer() {
    local conn peer
    conn=$(ss -tn src ":$1" 2>/dev/null | awk '/^ESTAB/ {print $5; exit}')
    peer=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
    echo "$peer"
}
hdr_conf_has() {
    local v; v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 | tr -d "\"' \r")
    [ -n "$v" ]
}
collect_header_rows() {
    local mode="${1:-}" tmp conf name role port remote peer fwd up avg loss st act="" ina="" line
    tmp=$(mktemp "$SECURE_TMP/.mpaqet_hdr_rows.XXXXXX") || return 1
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        name=$(basename "$conf" .meta)
        role=$(mt_read_kv "$conf" ROLE 2>/dev/null) || role=""
        port=$(mt_read_kv "$conf" TUN_PORT 2>/dev/null) || port=""
        remote=$(mt_read_kv "$conf" REMOTE_IP 2>/dev/null) || remote=""
        st=0; systemctl is-active --quiet "mpaqet@${name}" 2>/dev/null && st=1
        peer="$remote"
        if [ "$st" = 1 ] && [ "$role" = 1 ]; then
            peer=$(get_server_peer_ip "$name" 2>/dev/null); [ -n "$peer" ] || peer="Listening"
        fi
        [ -n "$peer" ] && [ "$peer" != "0.0.0.0" ] || peer="---"
        avg="---"; loss="---"
        if [ "$st" = 1 ] && hdr_is_ip "$peer"; then
            if [ "$mode" = fast ]; then avg="..."; else IFS='|' read -r avg loss <<< "$(hdr_ping_probe "$peer" "$name")"; fi
        fi
        fwd="RAW"
        up="STOPPED"; [ "$st" = 1 ] && up=$(hdr_unit_uptime "mpaqet@${name}")
        line="${st}|${name}|${peer}|${avg}|${loss}|${up}|${fwd}"
        if [ "$st" = 1 ]; then act+="${line}"$'\n'; else ina+="${line}"$'\n'; fi
    done
    printf '%s%s' "$act" "$ina" | head -n 3 > "$tmp"
    mv -f "$tmp" "$HDR_ROWS_FILE" 2>/dev/null
}
hdr_rows_count() { [ -s "$HDR_ROWS_FILE" ] && wc -l < "$HDR_ROWS_FILE" || echo 0; }
refresh_header_live() {
    if [ "$(hdr_rows_count)" != "$HDR_DRAWN_ROWS" ]; then NEED_REFRESH=true; return; fi
    printf '\033[?25l\0337\033[1;1H'
    HEADER_LIVE=1 draw_header
    printf '\0338\033[?25h'
}
hdr_stats_loop() {
    while true; do
        collect_header_rows
        [ -f "$SECURE_TMP/.mpaqet_in_menu" ] && kill -SIGUSR2 "$MAIN_PID" 2>/dev/null
        sleep 5
    done
}

draw_header() {
    local total_tunnels=0; local online_tunnels=0; local active_t=0; local mtu_err_t=0; local err_t=0; local waiting_t=0; local connecting_t=0
    local t_names=() units=()
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            local t_name=$(basename "$conf" .meta)
            t_names+=("$t_name"); units+=("mpaqet@$t_name")
        fi
    done
    total_tunnels=${#t_names[@]}
    if [ "$total_tunnels" -gt 0 ]; then
        local states=() i=0
        while IFS= read -r st_line; do states+=("$st_line"); done < <(systemctl is-active "${units[@]}" 2>/dev/null)
        for t_name in "${t_names[@]}"; do
            if [ "${states[$i]}" == "active" ]; then
                ((active_t++))
                local st=$(check_paqet_connection "$t_name" "1")
                case "$st" in
                    ONLINE) ((online_tunnels++));;
                    WAITING) ((waiting_t++));;
                    CONNECTING) ((connecting_t++));;
                    MTU-ERR) ((mtu_err_t++));;
                    ERRORS) ((err_t++));;
                esac
            fi
            ((i++))
        done
    fi
    
    local core_color="${R}"; local core_raw="Not Installed"
    if is_paqet_core_valid; then
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
        if [ "$mtu_err_t" -gt 0 ]; then
            stat_color="${R}"; stat_icon="✖"; stat_text="MTU ERROR"
        elif [ "$err_t" -gt 0 ]; then
            stat_color="${R}"; stat_icon="✖"; stat_text="ERRORS"
        elif [ "$online_tunnels" -eq "$active_t" ]; then 
            stat_color="${G}"; stat_icon="●"; stat_text="CONNECTED"
        elif [ "$online_tunnels" -gt 0 ]; then 
            stat_color="${Y}"; stat_icon="◐"; stat_text="PARTIAL"
        elif [ "$connecting_t" -gt 0 ]; then
            stat_color="${Y}"; stat_icon="◎"; stat_text="CONNECTING"
        elif [ "$waiting_t" -gt 0 ]; then
            stat_color="${Y}"; stat_icon="◎"; stat_text="WAITING"
        else
            stat_color="${Y}"; stat_icon="◎"; stat_text="STARTING"
        fi
    fi

    local peer_ip="" peer_name=""
    local tmp_port=""
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            local tmp_role=$(grep "^ROLE=" "$conf" | cut -d'=' -f2)
            local tmp_remote=$(grep "^REMOTE_IP=" "$conf" | cut -d'=' -f2)
            tmp_port=$(grep "^TUN_PORT=" "$conf" | cut -d'=' -f2)
            
            if [ -n "$tmp_remote" ] && [ "$tmp_remote" != "0.0.0.0" ]; then
                peer_ip="$tmp_remote"
                peer_name=$(basename "$conf" .meta)
                break
            elif [ "$tmp_role" == "1" ]; then
                local tmp_name=$(basename "$conf" .meta)
                local srv_peer=$(get_server_peer_ip "$tmp_name")
                if [ -n "$srv_peer" ]; then
                    peer_ip="$srv_peer"; peer_name="$tmp_name"
                    break
                fi
            fi
        fi
    done

    local g_color="${DIM}"; local g_text="N/A"
    if [ -n "$peer_ip" ]; then
        local cache_key="${peer_name:-peer}"; cache_key="${cache_key//[^A-Za-z0-9_.-]/_}"
        local ping_cache="$SECURE_TMP/.mpaqet_ping_${cache_key}"
        local ping_lock="$SECURE_TMP/.mpaqet_ping_${cache_key}.lock"
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
                bg_val=$(get_peer_ping "$peer_ip" "$tmp_port" "$peer_name")
                echo "$bg_val" > "$ping_cache"
                rm -f "$ping_lock"
                if [ -f "$SECURE_TMP/.mpaqet_in_menu" ]; then
                    kill -SIGUSR2 "$MAIN_PID" 2>/dev/null
                fi
            ) &
        fi
    else
        g_color="${DIM}"; g_text="Waiting"
        [ "$online_tunnels" -gt 0 ] && g_text="N/A"
    fi

    # Unified dashboard header (same look as the main screen) -- THIS module's tunnels only.
    local _now _mtime
    _now=$(date +%s); _mtime=$(stat -c %Y "$HDR_ROWS_FILE" 2>/dev/null || echo 0)
    if [ ! -f "$HDR_ROWS_FILE" ] || [ $(( _now - _mtime )) -gt 15 ]; then collect_header_rows fast; fi
    mt_hdr_rows_from_cache "$HDR_ROWS_FILE" "PAQET" "pq_"
    HDR_DRAWN_ROWS=$MT_HDR_ROW_COUNT
    mt_hdr_draw "MPaqet Core v${MODULE_VERSION}" "Active|${act_text}|${act_color}" \
        "Core|${core_raw}|${core_color}" "Status|${stat_icon} ${stat_text}|${stat_color}" \
        "Peer Ping|${g_text}|${g_color}" "Tunnels|${total_tunnels}|${W}"
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

show_tunnel_registry() {
    draw_header
    echo -e "\n  ${Y}● Tunnel Info & Specs:${NC}"
    local count=0
    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        ROLE=""; TUN_PORT=""; REMOTE_IP=""; TCP_PORTS=""
        mt_source_conf "$conf" 2>/dev/null
        
        local yaml_f="$CONF_DIR/${t_name}.yaml"
        [ ! -f "$yaml_f" ] && continue
        
        local key=$(grep "key:" "$yaml_f" | awk -F'"' '{print $2}')
        local mode=$(grep "mode:" "$yaml_f" | awk -F'"' '{print $2}')
        local block=$(grep "block:" "$yaml_f" | awk -F'"' '{print $2}')
        local mtu=$(grep "mtu:" "$yaml_f" | awk '{print $2}')
        local conn_c=$(grep "conn:" "$yaml_f" | head -1 | awk '{print $2}')
        
        local role_text=$([ "$ROLE" == "1" ] && echo "KHAREJ (Server)" || echo "IRAN (Client)")
        local ping_val="N/A"
        local connected_peer=""

        if [ "$ROLE" == "2" ] && [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "0.0.0.0" ]; then
            ping_val=$(get_peer_ping "$REMOTE_IP" "$TUN_PORT" "$t_name")
            connected_peer="$REMOTE_IP"
        elif [ "$ROLE" == "1" ]; then
            local p_ip=$(get_server_peer_ip "$t_name")
            if [ -n "$p_ip" ]; then
                ping_val=$(get_peer_ping "$p_ip" "$TUN_PORT" "$t_name")
                connected_peer="$p_ip"
            else
                ping_val="N/A"
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
        elif [ "$st" == "CONNECTING" ]; then stat_icon="◎"; stat_text="CONNECTING..."; stat_color="${Y}";
        elif [ "$st" == "MTU-ERR" ]; then stat_icon="✖"; stat_text="MTU ERROR"; stat_color="${R}";
        elif [ "$st" == "ERRORS" ]; then stat_icon="✖"; stat_text="ERRORS"; stat_color="${R}"; fi

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
    if [ "${1:-}" != --no-pause ]; then
        echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
    fi
}

show_live_radar() {
    tput civis; clear
    declare -A rx_old tx_old sample_old

    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        rx_old[$t_name]=$(get_paqet_rx "$t_name")
        sample_old[$t_name]=$(mt_milliseconds)
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
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING";
            elif [ "$st" == "MTU-ERR" ]; then st_color="${R}"; st_text="MTU ERROR";
            elif [ "$st" == "ERRORS" ]; then st_color="${R}"; st_text="ERRORS"; fi

            local r_new=$(get_paqet_rx "$t_name"); local t_new=$(get_paqet_tx "$t_name")
            local r_prev=${rx_old[$t_name]:-$r_new}; local t_prev=${tx_old[$t_name]:-$t_new}
            local now_ms=$(mt_milliseconds) ms_diff; ms_diff=$((now_ms-${sample_old[$t_name]:-$now_ms}))
            local rx_s=$(mt_rate "$r_new" "$r_prev" "$ms_diff"); local tx_s=$(mt_rate "$t_new" "$t_prev" "$ms_diff")
            sample_old[$t_name]=$now_ms
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
        mt_monitor_wait 1 || break
    done
    tput cnorm
}

select_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.yaml 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; fi

    echo -e "\n  ${B}╭────────────────── Select Tunnel to Manage ─────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .yaml)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r')
    mt_valid_index "$t_idx" "${#configs[@]}" || return 1
    t_idx=$((10#$t_idx))

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
    
    echo -ne "  ${Y}Are you sure you want to proceed? Type '${R}yes${Y}' to confirm: ${NC}"; read confirm
    confirm=$(echo "$confirm" | tr -d '\r ')
    
    if [ "$confirm" != "yes" ]; then
        echo -e "  ${G}● Uninstallation cancelled.${NC}"; sleep 1.5; return
    fi

    echo -e "\n  ${DIM}● [1/5] Stopping services & killing processes...${NC}"
    systemctl stop mpaqet@* mpaqet-apply.service 2>/dev/null
    systemctl disable mpaqet@* mpaqet-apply.service 2>/dev/null
    # Do not kill every system process with the same executable name.

    echo -e "  ${DIM}● [2/5] Purging raw & mangle iptables rules...${NC}"
    for chain in INPUT OUTPUT PREROUTING; do
        mt_delete_tagged_rules iptables mangle "$chain" "MPAQET_" substring 2>/dev/null || true
        mt_delete_tagged_rules iptables raw "$chain" "MPAQET_" substring 2>/dev/null || true
    done

    echo -e "  ${DIM}● [3/5] Removing systemd unit files...${NC}"
    rm -f /etc/systemd/system/mpaqet@.service /etc/systemd/system/mpaqet-apply.service
    systemctl daemon-reload 2>/dev/null

    echo -e "  ${DIM}● [4/5] Deleting configurations & core binary...${NC}"
    rm -rf /etc/paqet "$SECURE_TMP/.mpaqet"*
    # Remove only an MTunnel-owned binary matching its ownership manifest.
    mt_owned_binary_remove paqet /usr/local/bin/paqet /usr/bin/paqet || true

    echo -e "  ${DIM}● [5/5] Removing mpaqet wrapper script...${NC}"
    rm -f "$INSTALL_PATH" 2>/dev/null
    [ -f "$0" ] && rm -f "$0" 2>/dev/null

    echo -e "\n  ${G}✔ MPaqet ecosystem has been completely eradicated from this system.${NC}\n"
    exit 0
}

[ -n "${MT_PEER_LINK:-}" ] || check_first_run_core
setup_systemd_service

show_tunnels_info() {
    mt_tunnels_info_menu paqet draw_header show_tunnel_registry show_tunnel_logs
}

show_tunnel_logs() {
    select_tunnel || return 0
    local t_name int_trap
    t_name=$(basename "$SELECTED_TUN" .yaml)
    draw_header
    echo -e "\n  ${DIM}● Live logs for ${W}${t_name}${NC} ${DIM}(Ctrl+C to return)${NC}\n"
    int_trap=$(trap -p INT)
    trap ':' INT
    journalctl -u "mpaqet@${t_name}" -n 50 -f
    if [ -n "$int_trap" ]; then eval "$int_trap"; else trap - INT; fi
}

# BEGIN MTUNNEL WORKSPACE V1.0.2
# Embedded in each module: no external library or sourced setup-link code.
# mt_header_refresh_now supplied by core/common.sh
# mt_live_readline supplied by core/common.sh
# mt_ask supplied by core/common.sh
# mt_workspace_screen supplied by core/common.sh
# mt_term_cols supplied by core/common.sh
# Responsive menu row: compact on all terminal widths; visual labels may trim on narrow screens.
# mt_workspace_row supplied by core/common.sh
# mt_workspace_group supplied by core/common.sh
# mt_workspace_footer supplied by core/common.sh
# mt_workspace_menu supplied by core/common.sh
# mt_workspace_pause supplied by core/common.sh
# mt_link_encode supplied by core/common.sh
# mt_link_decode supplied by core/common.sh
# mt_bbr_state supplied by core/common.sh
# mt_sync_bbr_from_peer supplied by core/common.sh
# mt_ask_bbr_from_peer supplied by core/common.sh
# mt_clipboard_copy supplied by core/common.sh
# mt_peer_copy_prompt supplied by core/common.sh
# mt_link_box supplied by core/common.sh
mt_main_logs() { show_tunnel_logs; }
# mt_link_read supplied by core/common.sh
# mt_link_uint supplied by core/common.sh
# mt_link_ports supplied by core/common.sh
mt_link_field_valid() {
    local key="$1" val="$2" safe='^[][A-Za-z0-9_:.,=-]*$'
    # Reject whitespace, control bytes, shell syntax, quotes, paths and unknown keys.
    [ "${#val}" -le 4096 ] && [[ "$val" =~ $safe ]] || return 1
    case "$key" in
        ROLE) [[ "$val" =~ ^[12]$ ]];;
        BBR) [[ "$val" =~ ^[01]$ ]];;
        NAME) [[ "$val" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]];;
        BIND_HOST) [[ "$val" = 0.0.0.0 || "$val" = :: ]];;
        EXPIRES) mt_link_uint "$val" 1 9999999999;;
        CORE_V6) [ -z "$val" ] || mt_valid_ipv6 "$val::1";;
        HOST|LOCAL_PUB|REMOTE_PUB|LOCAL_PUB6|REMOTE_PUB6|LOCAL_IP6|REMOTE_IP6|REMOTE_V4)
            [ -z "$val" ] || mt_valid_host "$val";;
        TOKEN|TUN_SECRET|SYNC_KEY) [[ "$val" =~ ^[A-Za-z0-9_=-]{1,256}$ ]];;
        LINK_PORT) mt_valid_port "$val";;
        TCP_PORTS|UDP_PORTS) mt_link_ports "$val";;
        TRANSPORT) [[ "$val" =~ ^(tcp|tcpmux|ws|wss|wsmux|wssmux|udp)$ ]];;
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
        ADV_KEEPALIVE|ADV_HEARTBEAT|ADV_CHANNEL|ADV_POOL|ADV_RETRY|ADV_DIAL|ADV_MUX_CON|ADV_MUX_VERSION|ADV_MUX_FRAME|ADV_MUX_RECEIVE|ADV_MUX_STREAM|ADV_MTU|ADV_MSS|ADV_RCVBUF|ADV_SNDBUF) mt_link_uint "$val" 0 1073741824;;
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
# mt_link_validate supplied by core/common.sh
# mt_link_select supplied by core/common.sh
# mt_link_export supplied by core/common.sh
mt_link_offer() {
    local ans
    mt_ask ans 'Generate a setup link for the peer now? [Y/n]: ' || return 0
    case "${ans,,}" in n|no) return 0;; esac
    mt_link_export "$1"
}
mt_peer_ensure_core() {
    is_paqet_core_valid && return 0
    local choice
    echo -e "\n  ${Y}● Paqet Core is required before applying this Peer Code.${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Install Core From Github${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Install Core From Iranian Mirror${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    while true; do
        mt_live_readline choice "  ${C}Select Source ❯❯ ${NC}" || return 1
        choice="${choice//$'\r'/}"
        case "$choice" in
            1|2)
                if install_core_from_source "$choice"; then
                    is_paqet_core_valid && return 0
                    echo -e "  ${R}✖ Core installer returned but the binary is still unavailable.${NC}" >&2
                    return 1
                fi
                echo -e "  ${R}✖ Core installation failed. Peer setup was not changed.${NC}" >&2
                return 1
                ;;
            0|q|Q|'') return 1 ;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}" ;;
        esac
    done
}
mt_link_import() {
    local link ans name
    mt_workspace_screen
    if [ -n "${MT_PEER_LINK:-}" ]; then link="$MT_PEER_LINK"; MT_PEER_LINK=; else mt_ask link 'Paste Peer Setup Link (q: back): ' || return 1; fi
    [ "$link" != q ] || return 0
    mt_link_decode "$link" || { echo -e "  ${R}✖ Invalid / expired link. No changes made.${NC}"; mt_workspace_pause; return 1; }
    echo -e "\n  ${DIM}┌─[ PEER SETUP PREVIEW ]${NC}"
    echo -e "  ${DIM}│${NC}"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "Module" "$NC" "$DIM" "$NC" "$W" "$MT_KIND" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "Role" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[ROLE]}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "Peer" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[HOST]:--}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "Link port" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[LINK_PORT]:--}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "Transport" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[TRANSPORT]:-${MT_LINK_DATA[PROTO]:-KCP/TCP}}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "TCP ports" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[TCP_PORTS]:-${MT_LINK_DATA[PORTS]:--}}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "UDP ports" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[UDP_PORTS]:--}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "vIPs" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[MAX_IPS]:--}" "$NC"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}Secret is hidden. Existing tunnels will not be overwritten.${NC}"
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
# mt_workspace_vip supplied by core/common.sh
# mt_workspace_backup supplied by core/common.sh
# END MTUNNEL WORKSPACE V1.0.2

mt_link_paqet_values() {
    local yaml="$1" key val source
    for key in MODE CONN MTU RCVWND SNDWND SMUXBUF STREAMBUF TCPBUF UDPBUF NODELAY WDELAY ACKNODELAY INTERVAL RESEND NOCONGESTION DSHARD PSHARD SMUXKALIVE; do
        source="${key,,}"; val=$(get_yaml_value "$source" "$yaml")
        [ -z "$val" ] || MT_LINK_DATA[KCP_$key]="$val"
    done
    val=$(get_yaml_value sockbuf "$yaml"); MT_LINK_DATA[KCP_PCAP_SOCKBUF]="${val:-8388608}"
    # Older minimal configurations rely on the engine defaults, rather than explicit buffers/windows.
    : "${MT_LINK_DATA[KCP_CONN]:=4}" "${MT_LINK_DATA[KCP_MTU]:=1350}" "${MT_LINK_DATA[KCP_RCVWND]:=1024}" "${MT_LINK_DATA[KCP_SNDWND]:=1024}"
    : "${MT_LINK_DATA[KCP_SMUXBUF]:=16777216}" "${MT_LINK_DATA[KCP_STREAMBUF]:=2097152}" "${MT_LINK_DATA[KCP_TCPBUF]:=8192}" "${MT_LINK_DATA[KCP_UDPBUF]:=4096}"
    if [ "${MT_LINK_DATA[KCP_MODE]}" = manual ]; then
        : "${MT_LINK_DATA[KCP_NODELAY]:=0}" "${MT_LINK_DATA[KCP_WDELAY]:=true}" "${MT_LINK_DATA[KCP_ACKNODELAY]:=false}" "${MT_LINK_DATA[KCP_INTERVAL]:=30}" "${MT_LINK_DATA[KCP_RESEND]:=2}" "${MT_LINK_DATA[KCP_NOCONGESTION]:=1}"
    fi
}
mt_link_deploy_locked() {
    mt_link_validate || return 1
    local name="pq_${MT_LINK_DATA[NAME]#pq_}" role="${MT_LINK_DATA[ROLE]}" port="${MT_LINK_DATA[LINK_PORT]}" host="${MT_LINK_DATA[HOST]}" key="${MT_LINK_DATA[TOKEN]}" block="${MT_LINK_DATA[BLOCK]}" target p variable yaml meta tmp unit
    yaml="$CONF_DIR/$name.yaml"; meta="$CONF_DIR/$name.meta"; unit="mpaqet@$name"
    [ ! -e "$yaml" ] && [ ! -e "$meta" ] || { echo 'Tunnel already exists; nothing overwritten.' >&2; return 1; }
    [ "$role" != 1 ] || { ! mt_port_busy "$port" && paqet_port_available "$port"; } || return 1
    if [ "$role" = 2 ]; then
        validate_paqet_ports "${MT_LINK_DATA[TCP_PORTS]}" || return 1
        mt_list_has_port "${MT_LINK_DATA[TCP_PORTS]}" "$port" && { echo 'A forwarded port matches the link port.' >&2; return 1; }
        target="$host"
    else target=1.1.1.1; fi
    resolve_paqet_route "$target" || { echo 'Cannot resolve the IPv4 route / gateway MAC.' >&2; return 1; }
    [[ "$PQ_ROUTE_IFACE" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    tmp=$(mktemp "$SECURE_TMP/peer-paqet.XXXXXX") || return 1
    {
        printf 'role: "%s"\nlog:\n  level: "info"\n' "$([ "$role" = 1 ] && echo server || echo client)"
        if [ "$role" = 1 ]; then printf 'listen:\n  addr: ":%s"\n' "$port"
        else
            printf 'forward:\n'
            IFS=, read -ra MT_PQ_PORTS <<< "${MT_LINK_DATA[TCP_PORTS]}"
            for p in "${MT_PQ_PORTS[@]}"; do printf '  - listen: "0.0.0.0:%s"\n    target: "127.0.0.1:%s"\n    protocol: "tcp"\n' "$p" "$p"; done
            printf 'server:\n  addr: "%s:%s"\n' "$PQ_ROUTE_TARGET" "$port"
        fi
        printf 'network:\n  interface: "%s"\n  ipv4:\n    addr: "%s:%s"\n    router_mac: "%s"\n  tcp:\n    local_flag: ["PA"]\n' "$PQ_ROUTE_IFACE" "$PQ_ROUTE_SRC" "$([ "$role" = 1 ] && echo "$port" || echo 0)" "$PQ_ROUTE_MAC"
        [ "$role" != 2 ] || printf '    remote_flag: ["PA"]\n'
        printf 'transport:\n  protocol: "kcp"\n  kcp:\n    key: "%s"\n    block: "%s"\n    mode: "%s"\n    mtu: %s\n' "$key" "$block" "${MT_LINK_DATA[KCP_MODE]}" "${MT_LINK_DATA[KCP_MTU]}"
        for variable in DSHARD PSHARD SMUXKALIVE; do
            [ -z "${MT_LINK_DATA[KCP_$variable]:-}" ] || printf '    %s: %s\n' "${variable,,}" "${MT_LINK_DATA[KCP_$variable]}"
        done
    } > "$tmp"
    # Copy only validated scalar settings into the existing KCP writer.
    for variable in MODE CONN MTU RCVWND SNDWND SMUXBUF STREAMBUF PCAP_SOCKBUF TCPBUF UDPBUF NODELAY WDELAY ACKNODELAY INTERVAL RESEND NOCONGESTION; do
        printf -v "KCP_$variable" '%s' "${MT_LINK_DATA[KCP_$variable]:-}"
    done
    if [ "$KCP_MODE" = manual ]; then
        for variable in NODELAY WDELAY ACKNODELAY INTERVAL RESEND NOCONGESTION; do
            mt_link_field_valid "KCP_$variable" "${MT_LINK_DATA[KCP_$variable]:-}" || { rm -f "$tmp"; return 1; }
        done
    fi
    if ! write_kcp_settings "$tmp" "$key" "$block"; then rm -f "$tmp"; return 1; fi
    (umask 077; set -o noclobber; cat "$tmp" > "$yaml") 2>/dev/null || { rm -f "$tmp"; return 1; }; rm -f "$tmp"
    {
        printf 'ROLE=%s\nTUN_PORT=%s\nREMOTE_IP=%s\nTCP_PORTS=%s\nPROFILE=%s\n' "$role" "$port" "$host" "${MT_LINK_DATA[TCP_PORTS]}" "${MT_LINK_DATA[PROFILE]}"
    } > "$meta"; chmod 600 "$meta"
    if [ "$role" = 1 ]; then setup_paqet_counters "$name" "$port"
    else
        for p in "${MT_PQ_PORTS[@]}"; do setup_paqet_counters "$name" "$p"; done
        setup_paqet_probe "$name" "$PQ_ROUTE_TARGET" "$port"
    fi
    if ! systemctl restart "$unit" || ! mt_workspace_service_ready "$unit"; then
        journalctl -u "$unit" -n 8 --no-pager >&2; systemctl stop "$unit"; clean_paqet_counters "$name"; rm -f "$yaml" "$meta"; return 1
    fi
    systemctl enable "$unit" >/dev/null 2>&1
}
mt_workspace_service_ready() {
    local attempt
    for attempt in 1 2 3 4; do sleep .4; systemctl is-active --quiet "$1" || return 1; done
}
mt_workspace_health() {
    mt_link_select || return 1
    local name; name=$(basename "$MT_LINK_CONF" .meta)
    mt_workspace_screen
    systemctl status "mpaqet@$name" --no-pager -l
    journalctl -u "mpaqet@$name" -n 12 --no-pager
    echo '  Paqet uses raw packets. A TCP connect probe cannot verify the raw link.'
    echo '  Use Live Monitor for packet activity and test an actual forwarded application from the peer.'
    mt_workspace_pause
}

# mt_link_deploy supplied by core/common.sh

# mt_workspace_auto_backup supplied by core/common.sh
mt_workspace_update_badge() {
    local rv file="$SECURE_TMP/.mpaqet_remote_ver"
    [ -f "$file" ] || return 0
    rv=$(tr -d '\r\n ' < "$file")
    if mt_update_available "$rv" "$MODULE_VERSION"; then
        printf ' %b(Update Available: v%s)%b' "$Y" "$rv" "$NC"
    fi
    return 0
}
if [[ "${1:-}" != --* ]]; then hdr_stats_loop & HDR_PID=$!; fi
MT_KIND=paqet; MT_HEADER=draw_header; MT_SECTION=""
mt_workspace_route() {
    local section="$1"
    case "$section" in
        1) MT_SECTION=1; mt_workspace_menu "CREATE TUNNEL" "1|Manual Server Setup (Kharej)|1|${G}" "2|Manual Client Setup (Iran)|2|${C}" "3|Create From Peer Link|97|${G}" "4|Generate Peer Setup Link|98|${M}" || { MT_SECTION=""; return 1; };;
        2) MT_SECTION=2; mt_workspace_menu "EDIT & MANAGE" "1|Secret Key|4|${G}" "2|KCP Profile / Manual Settings|5|${C}" "3|MTU Size|6|${G}" "4|Connection Count|7|${Y}" "5|Encryption|8|${M}" "6|Tunnel Name|10|${W}" "7|Delete Tunnels|3|${R}" || { MT_SECTION=""; return 1; };;
        3) MT_SECTION=3; mt_workspace_menu "FORWARDING" "1|Forwarded TCP Ports (Client)|9|${C}" || { MT_SECTION=""; return 1; };;
        4) MT_SECTION=4; mt_workspace_menu "SYSTEM & SECURITY" "1|Auto Recovery|13|${G}" "2|BBR Settings|14|${G}" "3|Restart & Zero Counters|15|${G}" "4|Check Selected Tunnel|99|${C}" || { MT_SECTION=""; return 1; };;
        5) MT_ACTION=11;;
        6) MT_ACTION=12;;
        7) MT_ACTION=20;;
        8) MT_ACTION=96;;
        9) MT_ACTION=201;;
        10) MT_SECTION=2; MT_ACTION=3; MT_SHORTCUT=1;;
        11) MT_ACTION=18;;
        0) MT_ACTION=0;;
        *) return 1;;
    esac
}

render_mpaqet_menu() {
    mt_workspace_screen
    mt_workspace_group 'PROVISION & MANAGE' first
    mt_workspace_row 1 'Create Tunnel' "$C"
    mt_workspace_row 2 'Edit & Manage' "$Y"
    mt_workspace_row 3 'Forwarding' "$G"
    mt_workspace_row 4 'System & Security' "$M"
    mt_workspace_row 5 'Tunnel Info & Specs' "$M"
    mt_workspace_row 6 'Live Monitor' "$C"
    mt_workspace_row 7 'Update & Local Install' "$G" "$(mt_workspace_update_badge)"
    mt_workspace_row 8 'Backup & Restore' "$W"
    mt_workspace_row 9 'Logs' "$Y"
    mt_workspace_row 10 'Delete Tunnels' "$R"
    mt_workspace_row 11 'Uninstall MPAQET' "$R"
    mt_workspace_footer 'Return to Main Core'
}

if [ -n "${MT_PEER_LINK:-}" ]; then mt_link_import; exit $?; fi
while true; do
    if [ -n "$MT_SECTION" ]; then opt="$MT_SECTION"
    else
        render_mpaqet_menu
        read_with_refresh "  ${C}MPAQET ❯❯ ${NC}" opt render_mpaqet_menu || break
        opt="${opt//$'\r'/}"
    fi
    mt_workspace_route "$opt" || continue
    case "$MT_ACTION" in
        97) mt_link_import; continue;;
        98) mt_link_export; continue;;
        99) mt_workspace_health; continue;;
        201) mt_main_logs; continue;;
        96) mt_workspace_menu "BACKUP & RESTORE" "1|Save Config Backup|save|${W}" || continue; mt_workspace_backup; continue;;
    esac
    # Every edit/forwarding action gets a private config restore point first.
    if [[ "$MT_SECTION" == 2 || "$MT_SECTION" == 3 ]]; then
        mt_workspace_auto_backup || { echo 'Could not save the config restore point; operation cancelled.' >&2; mt_workspace_pause; continue; }
    fi
    [ "${MT_SHORTCUT:-}" = 1 ] && { MT_SECTION=""; MT_SHORTCUT=""; }
    opt="$MT_ACTION"
    case $opt in
        1)
           mt_workspace_screen
           echo -e "\n  ${DIM}┌─[ DEPLOY SERVER TUNNEL ]${NC}"
           echo -ne "  ${C}● Tunnel Suffix Name (e.g. srv1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
           if [ -z "$suffix" ]; then echo -e "  ${R}✖ Invalid Name!${NC}"; sleep 1.5; continue; fi
           
           t_name="pq_${suffix}"
           
           if [ -f "$CONF_DIR/${t_name}.yaml" ]; then
               echo -e "  ${R}✖ Tunnel '${t_name}' already exists! Delete it first or use another name.${NC}"; sleep 2; continue
           fi
           
           resolve_paqet_route "1.1.1.1" || { echo 'Cannot determine the route/gateway MAC.' >&2; continue; }
           iface="$PQ_ROUTE_IFACE"; l_ip="$PQ_ROUTE_SRC"; gw_mac="$PQ_ROUTE_MAC"

           while true; do
               echo -ne "  ${C}● Tunnel Listen Port [8888]: ${NC}"; read t_port
               t_port=${t_port//$'\r'/}
               t_port=${t_port:-8888}
               if ! mt_valid_port "$t_port"; then
                   echo -e "  ${R}✖ Invalid port!${NC}"
                   continue
               fi
               if mt_port_busy "$t_port" || ! paqet_port_available "$t_port"; then
                   echo -e "  ${R}Error: Port ${t_port} is already in use by another service!${NC}"
                   continue
               fi
               break
           done
           
           s_key=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
           echo -ne "  ${C}● Secret Key [Default ${s_key}]: ${NC}"; read u_key
           u_key=$(echo "$u_key" | tr -dc 'a-zA-Z0-9_=-')
           key=${u_key:-$s_key}

           choose_kcp_profile "server" "FAST" || continue
           profile_name="$KCP_PROFILE"
           
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
           chmod 600 "$CONF_DIR/${t_name}.yaml"
           if ! write_kcp_settings "$CONF_DIR/${t_name}.yaml" "$key" "aes-128-gcm"; then
               clean_paqet_counters "$t_name"; rm -f "$CONF_DIR/${t_name}.yaml"
               echo -e "  ${R}✖ Tunnel was NOT created (profile could not be written).${NC}"; sleep 2; continue
           fi
           
           echo -e "ROLE=1\nTUN_PORT=$t_port\nREMOTE_IP=0.0.0.0\nTCP_PORTS=\nPROFILE=$profile_name" > "$CONF_DIR/${t_name}.meta"
           chmod 600 "$CONF_DIR/${t_name}.meta"
           
           setup_paqet_counters "$t_name" "$t_port"
           systemctl enable "mpaqet@${t_name}" >/dev/null 2>&1
           systemctl restart "mpaqet@${t_name}"
           
           sleep 1.5
           if systemctl is-active --quiet "mpaqet@${t_name}"; then
               mt_ask_bbr_on_create
               mt_link_offer "$CONF_DIR/$t_name.meta"
               echo -e "\n  ${G}● Paqet Server Tunnel Deployed! Key: ${key}${NC}"; sleep 2
           else
               echo -e "\n  ${R}✖ Failed to start! Checking logs...${NC}"
               journalctl -u "mpaqet@${t_name}" -n 5 --no-pager
               echo -ne "  ${DIM}Press Enter...${NC}"; read dummy
           fi
           ;;
           
        2)
           mt_workspace_screen
           echo -e "\n  ${DIM}┌─[ DEPLOY CLIENT TUNNEL ]${NC}"
           echo -ne "  ${C}● Tunnel Suffix Name (e.g. cl1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
           if [ -z "$suffix" ]; then echo -e "  ${R}✖ Invalid Name!${NC}"; sleep 1.5; continue; fi
           
           t_name="pq_${suffix}"
           
           if [ -f "$CONF_DIR/${t_name}.yaml" ]; then
               echo -e "  ${R}✖ Tunnel '${t_name}' already exists! Delete it first or use another name.${NC}"; sleep 2; continue
           fi
           
           # Resolve the route after the remote IPv4 endpoint is known.

           while true; do
               echo -ne "  ${C}● Remote Kharej Server Host/IP: ${NC}"; read r_ip
               r_ip=$(echo "$r_ip" | tr -d '\r ')
               is_valid_host "$r_ip" && break
               echo -e "  ${R}✖ Invalid Host/IP format!${NC}"
           done
           
           while true; do
               echo -ne "  ${C}● Remote Listen Port [8888]: ${NC}"; read r_port
               r_port=${r_port//$'\r'/}
               r_port=${r_port:-8888}
               if mt_valid_port "$r_port"; then break; else echo -e "  ${R}✖ Invalid port!${NC}"; fi
           done
           
           resolve_paqet_route "$r_ip" || { echo 'Cannot resolve the remote route/gateway MAC.' >&2; continue; }
           iface="$PQ_ROUTE_IFACE"; l_ip="$PQ_ROUTE_SRC"; gw_mac="$PQ_ROUTE_MAC"; r_ip="$PQ_ROUTE_TARGET"

           while true; do
               echo -ne "  ${C}● Secret Key (from Server): ${NC}"; read -r key
               [[ "$key" == q ]] && break
               key=$(echo "$key" | tr -dc 'A-Za-z0-9_=-')
               [ -n "$key" ] && break
               echo -e "  ${R}✖ Secret Key cannot be empty.${NC}"
           done
           [[ "$key" == q ]] && continue
           key=$(echo "$key" | tr -dc 'a-zA-Z0-9_=-')
           
           fwd_ports=""
           while true; do
               echo -ne "  ${C}● Forward Ports (e.g. 443,8080): ${NC}"; read fwd_ports
               fwd_ports=${fwd_ports//$'\r'/}
               if [ -n "$fwd_ports" ]; then mt_port_guard bind "$fwd_ports" "" "" "" "Paqet" || continue; fwd_ports="$MT_PORT_TCP"; fi
               if ! validate_paqet_ports "$fwd_ports"; then
                   echo -e "  ${R}Error: Specify valid, unique, available forwarded ports (1-65535)!${NC}"
               else
                   break
               fi
           done
           
           if echo ",$fwd_ports," | grep -q ",$r_port,"; then
               echo -e "  ${R}✖ Loop Error: Forward port cannot match Tunnel port ($r_port)!${NC}"; sleep 2; continue
           fi
           
           choose_kcp_profile "client" "FAST" || continue
           profile_name="$KCP_PROFILE"
           
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
           chmod 600 "$CONF_DIR/${t_name}.yaml"
           if ! write_kcp_settings "$CONF_DIR/${t_name}.yaml" "$key" "aes-128-gcm"; then
               clean_paqet_counters "$t_name"; rm -f "$CONF_DIR/${t_name}.yaml"
               echo -e "  ${R}✖ Tunnel was NOT created (profile could not be written).${NC}"; sleep 2; continue
           fi

           echo -e "ROLE=2\nTUN_PORT=$r_port\nREMOTE_IP=$r_ip\nTCP_PORTS=${meta_ports%,}\nPROFILE=$profile_name" > "$CONF_DIR/${t_name}.meta"
           chmod 600 "$CONF_DIR/${t_name}.meta"

           systemctl enable "mpaqet@${t_name}" >/dev/null 2>&1
           systemctl restart "mpaqet@${t_name}"
           
           sleep 1.5
           if systemctl is-active --quiet "mpaqet@${t_name}"; then
               mt_ask_bbr_on_create
               mt_link_offer "$CONF_DIR/$t_name.meta"
               echo -e "\n  ${G}● Paqet Client Tunnel Deployed!${NC}"; sleep 2
           else
               echo -e "\n  ${R}✖ Failed to start! Checking logs...${NC}"
               journalctl -u "mpaqet@${t_name}" -n 5 --no-pager
               echo -ne "  ${DIM}Press Enter...${NC}"; read dummy
           fi
           ;;

        3)
           configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Delete ─────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}Index (or 'all' / 'q'): ${NC}"; read del_idx
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

        4|5|6|7|8|9|10)
           select_tunnel || continue
           sel_cfg="$SELECTED_TUN"
           old_tname=$(basename "$sel_cfg" .yaml)

           if [[ "$opt" == "4" ]]; then
               curr_key=$(grep "key:" "$sel_cfg" | awk -F'"' '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New Secret Key [Current: ${Y}${curr_key}${W}]: ${NC}"; read n_k
               n_k=$(echo "$n_k" | tr -dc 'a-zA-Z0-9_=-')
               if [ -n "$n_k" ]; then
                   sed -i "s|key:.*|key: \"$n_k\"|" "$sel_cfg"
                   echo -e "  ${G}✔ Secret Key updated.${NC}"
               else
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi

           elif [[ "$opt" == "5" ]]; then
               curr_profile=$(get_tunnel_profile "$old_tname")
               role_name="client"
               [ "$(grep -m1 '^ROLE=' "$CONF_DIR/${old_tname}.meta" | cut -d'=' -f2)" = "1" ] && role_name="server"
               if choose_kcp_profile "$role_name" "$curr_profile"; then
                   if ! write_kcp_settings "$sel_cfg" "$(get_yaml_value key "$sel_cfg")" "$(get_yaml_value block "$sel_cfg")"; then
                       sleep 2; continue
                   fi
                   set_meta_profile "$old_tname" "$KCP_PROFILE"
                   echo -e "  ${G}✔ ${KCP_PROFILE} profile applied and verified in YAML. Apply the same profile on the other server.${NC}"
               else
                   echo -e "  ${Y}● Profile change cancelled.${NC}"
                   continue
               fi

           elif [[ "$opt" == "6" ]]; then
               curr_mtu=$(grep "mtu:" "$sel_cfg" | awk '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New MTU Size [576-1500] [Current: ${Y}${curr_mtu}${W}]: ${NC}"; read n_mtu
               n_mtu=$(echo "$n_mtu" | tr -dc '0-9')
               if [ -z "$n_mtu" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if [ "$n_mtu" -lt 576 ] || [ "$n_mtu" -gt 1500 ]; then 
                   echo -e "  ${R}✖ MTU must be between 576 and 1500!${NC}"; sleep 1.5; continue
               fi
               nic_cap=$(kcp_mtu_cap "$sel_cfg")
               if [ -n "$nic_cap" ] && [ "$n_mtu" -gt "$nic_cap" ]; then
                   echo -e "  ${Y}⚠ This interface can only send ${nic_cap}; using ${nic_cap}.${NC}"; n_mtu="$nic_cap"
               fi
               sed -i "s|mtu:.*|mtu: $n_mtu|" "$sel_cfg"
               mark_profile_custom "$old_tname"
               echo -e "  ${G}✔ MTU updated.${NC}"

           elif [[ "$opt" == "7" ]]; then
               curr_conn=$(grep "conn:" "$sel_cfg" | head -1 | awk '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New Connections Count [1-32] [Current: ${Y}${curr_conn}${W}]: ${NC}"; read n_c
               n_c=$(echo "$n_c" | tr -dc '0-9')
               if [ -z "$n_c" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if [ "$n_c" -lt 1 ] || [ "$n_c" -gt 32 ]; then 
                   echo -e "  ${R}✖ Connections must be between 1 and 32!${NC}"; sleep 1.5; continue
               fi
               sed -i "s|conn:.*|conn: $n_c|" "$sel_cfg"
               mark_profile_custom "$old_tname"
               echo -e "  ${G}✔ Connection count updated.${NC}"

           elif [[ "$opt" == "8" ]]; then
               curr_block=$(grep "block:" "$sel_cfg" | awk -F'"' '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New Encryption Block [aes-128-gcm|aes-256|none] [Current: ${Y}${curr_block}${W}]: ${NC}"; read n_b
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
               is_client=false
               if grep -qi 'role: *"client"' "$sel_cfg"; then
                   is_client=true
               fi

               if [ "$is_client" != true ]; then
                   echo -e "  ${R}✖ Error: Forwarded ports can only be configured on Client tunnels!${NC}"
                   sleep 2; continue
               fi

               meta_file="$CONF_DIR/${old_tname}.meta"
               curr_ports=""
               [ -f "$meta_file" ] && curr_ports=$(grep -m1 "^TCP_PORTS=" "$meta_file" | cut -d'=' -f2 | tr -d '"')
               if [ -z "$curr_ports" ]; then
                   curr_ports=$(grep "listen:" "$sel_cfg" | awk -F':' '{print $NF}' | tr -d '"' | tr '\n' ',' | sed 's/,$//')
               fi

               t_tun_port=""
               [ -f "$meta_file" ] && t_tun_port=$(grep -m1 "^TUN_PORT=" "$meta_file" | cut -d'=' -f2 | tr -d '"')

               echo -ne "  ${C}●${NC} ${W}New Forward Ports [Current: ${Y}${curr_ports}${W}] (e.g. 443,8080): ${NC}"; read n_ports
               n_ports=$(echo "$n_ports" | tr -d '\r ' )
               if [ -z "$n_ports" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi

               mt_port_guard bind "$n_ports" "" "mpaqet@${old_tname}.service" "" "Paqet ${old_tname}" || { sleep 1; continue; }
               n_ports="$MT_PORT_TCP"
               validate_paqet_ports "$n_ports" "$old_tname" || { echo 'Invalid or conflicting port list.' >&2; sleep 1; continue; }
               if [ -n "$t_tun_port" ] && echo ",$n_ports," | grep -q ",$t_tun_port,"; then
                   echo -e "  ${R}✖ Loop Error: Forward port cannot match Tunnel port ($t_tun_port)!${NC}"
                   sleep 2; continue
               fi

               tmp_yaml="$SECURE_TMP/${old_tname}.yaml.tmp"
               new_meta_ports=""
               
               {
                   sed -n '1,/^forward:/p' "$sel_cfg"
                   IFS=',' read -ra P_ARR <<< "$n_ports"
                   for p_raw in "${P_ARR[@]}"; do
                       p_clean=$(echo "$p_raw" | tr -dc '0-9')
                       if mt_valid_port "$p_clean"; then
                           echo "  - listen: \"0.0.0.0:$p_clean\""
                           echo "    target: \"127.0.0.1:$p_clean\""
                           echo "    protocol: \"tcp\""
                           new_meta_ports="${new_meta_ports}${p_clean},"
                       fi
                   done
                   sed -n '/^network:/,$p' "$sel_cfg"
               } > "$tmp_yaml"

               if [ -z "$new_meta_ports" ]; then
                   echo -e "  ${R}✖ Invalid port list! Must specify at least one valid port.${NC}"
                   rm -f "$tmp_yaml"; sleep 2; continue
               fi

               if [ -s "$tmp_yaml" ] && grep -q "role:" "$tmp_yaml"; then
                   clean_paqet_counters "$old_tname"
                   mv -f "$tmp_yaml" "$sel_cfg"
                   chmod 600 "$sel_cfg"

                   new_meta_ports="${new_meta_ports%,}"
                   IFS=',' read -ra NP_ARR <<< "$new_meta_ports"
                   for p_clean in "${NP_ARR[@]}"; do
                       setup_paqet_counters "$old_tname" "$p_clean"
                   done

                   if [ -f "$meta_file" ]; then
                       if grep -q "^TCP_PORTS=" "$meta_file"; then
                           sed -i "s|^TCP_PORTS=.*|TCP_PORTS=$new_meta_ports|" "$meta_file"
                       else
                           echo "TCP_PORTS=$new_meta_ports" >> "$meta_file"
                       fi
                   fi
                   echo -e "  ${G}✔ Forwarded ports updated successfully.${NC}"
               else
                   rm -f "$tmp_yaml"
                   echo -e "  ${R}✖ Failed to update YAML configuration.${NC}"
                   sleep 2; continue
               fi

           elif [[ "$opt" == "10" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Tunnel Suffix (Current: ${Y}${old_tname#pq_}${W}): ${NC}"; read new_suffix
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
                   
                   ROLE=""; TUN_PORT=""; TCP_PORTS=""; mt_source_conf "$CONF_DIR/${new_t_name}.meta" 2>/dev/null
                   if [ "$ROLE" == "1" ]; then
                       setup_paqet_counters "$new_t_name" "$TUN_PORT"
                   else
                       if [ -n "$TCP_PORTS" ]; then
                           IFS=',' read -ra P_ARR <<< "$TCP_PORTS"
                           for p_clean in "${P_ARR[@]}"; do
                               if mt_valid_port "$p_clean"; then
                                   setup_paqet_counters "$new_t_name" "$p_clean"
                               fi
                           done
                       fi
                   fi
                   
                   old_tname="$new_t_name"
                   systemctl enable "mpaqet@${old_tname}" >/dev/null 2>&1
                   echo -e "  ${G}● Tunnel successfully renamed to: ${new_t_name}${NC}"
               else
                   echo -e "  ${Y}● Rename cancelled.${NC}"; sleep 1; continue
               fi
           fi

           systemctl restart "mpaqet@${old_tname}" 2>/dev/null
           sleep 1.5
           if systemctl is-active --quiet "mpaqet@${old_tname}"; then
               echo -e "  ${G}✔ Tunnel updated and restarted successfully.${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Tunnel failed to start. Please check logs!${NC}"; sleep 2
           fi
           ;;

        11) show_tunnels_info ;;
        15) zero_paqet_counters; systemctl restart mpaqet@* 2>/dev/null; echo -e "  ${G}● Services restarted and traffic counters zeroed.${NC}"; sleep 1.5 ;;
        16) menu_install_core ;;
        17) self_update_module ;;
        20) unified_update_menu ;;
        18) uninstall_mpaqet ;;
        13) mt_run_tool mhealer --scope paqet ;;
        14) mt_run_tool mbbr --from-tunnel ;;
        12) show_live_radar ;;
        0) break ;;
    esac
done
