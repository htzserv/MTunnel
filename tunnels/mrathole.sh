#!/bin/bash
# --- MTunnel MRathole | Reverse Tunnel Engine v1.2.2 ---
# [Features: Leak-Free Updater | Strict Port Guard | Universal Download | Port Collision Check]

MODULE_VERSION="1.2.2"
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
if ! declare -F mt_hdr_draw >/dev/null || ! declare -F mt_port_guard >/dev/null || ! declare -F mt_unit_live_peer >/dev/null; then
    echo 'MTunnel: the installed shared core (common.sh) is older than this module (requires the current shared-core API/layout).' >&2
    echo 'Update the whole bundle from the main menu (Sync) or run: bash install.sh --local .' >&2
    exit 1
fi
unset -f mt_load_common
if [ "$EUID" != 0 ]; then echo "Run MTunnel with sudo." >&2; exit 1; fi


















B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mrathole"
CONF_DIR="/etc/mrathole/tunnels"
SERVICE_TPL="/etc/systemd/system/mrathole@.service"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

# Never delete a pre-existing executable merely by opening this menu.

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$CONF_DIR" "$SECURE_TMP" 2>/dev/null
find "$CONF_DIR" -maxdepth 3 -type f -exec chmod 600 {} + 2>/dev/null || true
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
if [[ "${1:-}" != --* ]]; then ensure_dependencies; fi

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    mt_install_files 755 "$0" "$INSTALL_PATH" || { echo "Cannot install module." >&2; exit 1; }
fi

is_valid_host() {
    mt_valid_host "$1"
}

validate_forward_ports() {
    if ! mt_validate_port_list "$1" "$2" "$3" "${4:-}"; then
        echo 'Invalid, duplicate, or busy forwarded port.' >&2; return 1
    fi
    local item; local -a parts=(); IFS=, read -ra parts <<< "$1"
    for item in "${parts[@]}"; do
        [ -z "$item" ] && continue
        if mt_valid_port "${LINK_PORT:-}" && ((10#$item == 10#$LINK_PORT)); then
            echo 'Forwarded port conflicts with the tunnel link port.' >&2; return 1
        fi
    done
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
    touch "$SECURE_TMP/.mrathole_in_menu"
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
    rm -f "$SECURE_TMP/.mrathole_in_menu" 2>/dev/null
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

    rm -f "$SECURE_TMP/.mrathole_in_menu" 2>/dev/null
    printf -v "$__resultvar" '%s' "$buffer"
}

fetch_remote_version() {
    local url="$1" payload=''
    if command -v curl >/dev/null 2>&1; then
        payload=$(curl -fSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$url" 2>/dev/null) || return 1
    elif command -v wget >/dev/null 2>&1; then
        payload=$(wget -qO- --header="Cache-Control: no-cache" --timeout=5 "$url" 2>/dev/null) || return 1
    else return 1; fi
    printf '%s
' "$payload" | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2
}
check_update_bg() {
    local cb="?t=$(date +%s)" gh mirror combined
    gh=$(fetch_remote_version "${MTUNNEL_GITHUB_BASE}/tunnels/mrathole.sh${cb}" 2>/dev/null || true)
    mirror=$(fetch_remote_version "${MTUNNEL_MIRROR_BASE}/tunnels/mrathole.sh${cb}" 2>/dev/null || true)
    printf '%s
' "${gh:-Unknown}" > "$SECURE_TMP/.mrathole_remote_ver_github"
    printf '%s
' "${mirror:-Unknown}" > "$SECURE_TMP/.mrathole_remote_ver_mirror"
    combined="$gh"; [ -n "$combined" ] || combined="$mirror"
    printf '%s
' "${combined:-Unknown}" > "$SECURE_TMP/.mrathole_remote_ver"
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
if [[ "${1:-}" != --* ]]; then update_watcher_loop & fi
WATCHER_PID=$!
trap 'kill "$WATCHER_PID" ${HDR_PID:-} 2>/dev/null; rm -f "$SECURE_TMP/.mrathole_in_menu" 2>/dev/null' EXIT

self_update_module() {
    local src_opt="${1:-}" custom_url dl_url tmp_file confirm
    local rel_path="tunnels/mrathole.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mrathole_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mrathole_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && mt_update_available "$remote_v" "$MODULE_VERSION"; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    if [ -z "$src_opt" ]; then
    clear; echo -e "\n  ${DIM}┌─[ OTA Update (MRathole) ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ AUTOMATIC MIRRORS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${gh_text}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Iranian Mirror${NC} ${DIM}(${MTUNNEL_MIRROR_BASE})${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MANUAL OVERRIDES ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Nano / Ctrl+X Auto Apply)${NC}"
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
        if [ "$src_opt" == 4 ]; then
            confirm=y  # Ctrl+X saved and validated this Nano candidate.
            echo -e "  ${G}✔ Nano file validated — applying automatically.${NC}"
        else
            echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read -r confirm
        fi
        
    [[ "${confirm,,}" == y || "${confirm,,}" == yes ]] || { echo -e "  ${Y}● Update cancelled by user.${NC}"; rm -f "$tmp_file"; return 0; }
    if ! mt_install_script "$tmp_file" "$rel_path" "$INSTALL_PATH" "$0"; then
        rm -f "$tmp_file"; echo -e "  ${R}✖ Update failed. Previous module preserved.${NC}"; return 1
    fi
    rm -f "$tmp_file"
    echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
    [ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null || true
    exec "$INSTALL_PATH" "$@"
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

is_rathole_core_valid() {
    local candidate
    for candidate in /usr/local/bin/rathole /usr/bin/rathole; do
        [ -x "$candidate" ] && mt_valid_elf "$candidate" && return 0
    done
    return 1
}

# Rathole download helpers are embedded in this module; no external lib is needed.
rh_release_triplet() {
    case "${1:-$(uname -m)}" in
        x86_64) printf 'x86_64-unknown-linux-gnu';;
        aarch64|arm64) printf 'aarch64-unknown-linux-musl';;
        *) echo 'Unsupported CPU architecture.' >&2; return 1;;
    esac
}

rh_ensure_download_tools() {
    local need_zip="${1:-0}" missing=() log
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then missing+=(curl); fi
    if [ "$need_zip" = 1 ] && ! command -v unzip >/dev/null 2>&1; then missing+=(unzip); fi
    [ -s /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
    [ "${#missing[@]}" -gt 0 ] || return 0
    command -v apt-get >/dev/null 2>&1 || { echo "Install the missing packages: ${missing[*]}" >&2; return 1; }
    echo -e "  ${DIM}● Installing download prerequisites: ${missing[*]}...${NC}"
    log=$(mktemp "$SECURE_TMP/rh-deps.XXXXXX") || return 1
    DEBIAN_FRONTEND=noninteractive timeout 120 apt-get -o DPkg::Lock::Timeout=45 update -q > "$log" 2>&1 || true
    if ! DEBIAN_FRONTEND=noninteractive timeout 180 apt-get -o DPkg::Lock::Timeout=45 install -y -q "${missing[@]}" >> "$log" 2>&1; then
        echo 'Download prerequisites could not be installed:' >&2
        tail -n 6 "$log" >&2; rm -f "$log"; return 1
    fi
    rm -f "$log"
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || return 1
    [ "$need_zip" != 1 ] || command -v unzip >/dev/null 2>&1 || return 1
    [ -s /etc/ssl/certs/ca-certificates.crt ] || { echo 'System CA certificate bundle is missing.' >&2; return 1; }
}

rh_download() {
    local url="$1" dest="$2" tmp log tool family rc=1 code permanent=false
    [[ "$url" == https://* ]] || { echo 'Download requires an HTTPS URL.' >&2; return 1; }
    tmp=$(mktemp "${dest}.download.XXXXXX") || return 1
    log=$(mktemp "$SECURE_TMP/rh-download.XXXXXX") || { rm -f "$tmp"; return 1; }
    local -a args=()
    for tool in curl wget; do
        command -v "$tool" >/dev/null 2>&1 || continue
        for family in auto ipv4; do
            args=(); [ "$family" != ipv4 ] || args=(-4)
            : > "$tmp"
            echo -e "  ${DIM}● Downloading with $tool ($family)...${NC}"
            if [ "$tool" = curl ]; then
                code=$(curl "${args[@]}" -fsSL --proto '=https' --proto-redir '=https' \
                    --connect-timeout 10 --max-time 120 --retry 1 -w '%{http_code}' -o "$tmp" "$url" 2> "$log"); rc=$?
                if [ "$rc" = 22 ] && [[ "$code" =~ ^(400|401|403|404|410)$ ]]; then permanent=true; fi
            else
                wget "${args[@]}" --https-only --timeout=30 --tries=2 -O "$tmp" "$url" 2> "$log"; rc=$?
                [ "$rc" != 8 ] || permanent=true
            fi
            if [ "$rc" = 0 ] && [ -s "$tmp" ]; then
                mv -f "$tmp" "$dest"; rc=$?
                rm -f "$log"; return "$rc"
            fi
            [ "$permanent" != true ] || break
        done
        [ "$permanent" != true ] || break
    done
    echo 'Rathole download failed:' >&2
    if [ -s "$log" ]; then tail -n 4 "$log" >&2; else echo 'The server returned an empty file or no downloader is available.' >&2; fi
    rm -f "$tmp" "$log"; return 1
}

rh_validate_package() {
    local source="$1" stage item count=0
    mt_valid_elf "$source" && return 0
    stage=$(mktemp -d "$SECURE_TMP/rh-validate.XXXXXX") || return 1
    if ! mt_extract_archive "$source" "$stage"; then rm -rf "$stage"; return 1; fi
    while IFS= read -r item; do
        mt_valid_elf "$item" && count=$((count+1))
    done < <(find "$stage" -type f -name '*rathole*')
    rm -rf "$stage"
    [ "$count" = 1 ]
}

install_core_from_source() {
    local src_choice="$1" triplet asset url kind=url source="" work item local_source="" need_zip=0
    triplet=$(rh_release_triplet) || { echo -e "  ${R}✖ Unsupported CPU architecture.${NC}"; return 1; }
    asset="rathole-${triplet}.zip"
    local -a urls=()
    case "$src_choice" in
        1) urls=("https://github.com/rathole-org/rathole/releases/download/v0.5.0/$asset"); need_zip=1;;
        2)
            urls=("${MTUNNEL_MIRROR_BASE}/packages/$asset")
            # The unqualified mirror binary is the bundled x86_64 build only.
            [ "$triplet" != x86_64-unknown-linux-gnu ] || urls+=("${MTUNNEL_MIRROR_BASE}/packages/rathole")
            urls+=("https://github.com/rathole-org/rathole/releases/download/v0.5.0/$asset")
            need_zip=1;;
        3)
            echo -ne "  ${C}● Enter Direct Link: ${NC}"; read -r url || return 0
            url="${url//$'\r'/}"; [ -n "$url" ] || return 0
            [[ "$url" == https://* ]] || { echo 'Use an HTTPS direct link.' >&2; return 1; }
            urls=("$url"); need_zip=1;;
        4)
            kind=local
            for item in "$LOCAL_DIR/packages/rathole" "$LOCAL_DIR/packages/$asset" "$LOCAL_DIR/packages/rathole-${triplet}.tar.gz"; do
                [ -f "$item" ] || continue
                if [ "$item" = "$LOCAL_DIR/packages/rathole" ] && ! mt_valid_elf "$item"; then continue; fi
                source="$item"; break
            done
            [ -n "$source" ] || { echo "No compatible Rathole binary or $asset found in $LOCAL_DIR/packages." >&2; return 1; }
            [[ "$source" != *.zip ]] || need_zip=1;;
        *) return 0;;
    esac
    # Do not require internet/download utilities for a local binary.
    if [ "$kind" = url ]; then rh_ensure_download_tools "$need_zip" || return 1
    elif [ "$need_zip" = 1 ] && ! command -v unzip >/dev/null 2>&1; then
        echo 'Install unzip to use a local ZIP; an unpacked local binary needs no download tools.' >&2; return 1
    fi
    echo -e "  ${DIM}● Preparing Rathole Core ($triplet)...${NC}"
    if [ "$kind" = url ]; then
        work=$(mktemp -d "$SECURE_TMP/rh-package.XXXXXX") || return 1
        source=""
        for url in "${urls[@]}"; do
            local source_host="${url#https://}"; source_host="${source_host%%/*}"; source_host="${source_host##*@}"
            echo -e "  ${DIM}● Source: $source_host${NC}"
            if rh_download "$url" "$work/package"; then
                if rh_validate_package "$work/package"; then source="$work/package"; break
                else echo 'Downloaded file is not a compatible Rathole binary/archive.' >&2; fi
            fi
            [ "$url" = "${urls[-1]}" ] || echo -e "  ${Y}● Trying the next download source...${NC}"
        done
        [ -n "$source" ] || { rm -rf "$work"; echo -e "  ${R}✖ Download failed. Previous installation preserved.${NC}" >&2; return 1; }
    fi
    if mt_update_core rathole mrathole "$source" local; then
        [ -z "$work" ] || rm -rf "$work"
        echo -e "  ${G}✔ Rathole Core installed successfully.${NC}"
        echo -e "  ${DIM}● Previously active tunnels restarted.${NC}"
    else
        [ -z "$work" ] || rm -rf "$work"
        echo -e "  ${R}✖ Package extraction, validation or service restart failed. Previous installation preserved.${NC}" >&2
        return 1
    fi
}

mt_core_version() {
    local out
    out=$(rathole --version 2>/dev/null | head -n1)
    [ -n "$out" ] || out=$(rathole -V 2>/dev/null | head -n1)
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
        echo -e "  ${Y}● Local Rathole core was not found; scripts/tools were still processed.${NC}"
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
    gh_label=$(mt_update_label "$SECURE_TMP/.mrathole_remote_ver_github")
    mirror_label=$(mt_update_label "$SECURE_TMP/.mrathole_remote_ver_mirror")
    core_v=$(mt_core_version)
    [ -n "$core_v" ] && [ "$core_v" != "not-installed" ] && core_tag=" ${G}(installed)${NC}"
    mt_workspace_screen
    echo -e "\n  ${DIM}┌─[ UPDATE & LOCAL INSTALL — MRATHOLE ]${NC}"
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
        read_with_refresh "  ${C}MRATHOLE UPDATE ❯❯ ${NC}" opt render_unified_update_menu || return 0
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
    echo -e "\n  ${DIM}┌─[ INSTALL / UPDATE RATHOLE CORE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Iranian Mirror${NC} ${DIM}(${MTUNNEL_MIRROR_BASE})${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .zip)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r')

    [[ "$src_choice" =~ ^[1-4]$ ]] && install_core_from_source "$src_choice"
}

check_first_run_core() {
    if ! is_rathole_core_valid; then
        local first_prompt_flag="$CONF_DIR/.core_prompted"
        if [ "$(cat "$first_prompt_flag" 2>/dev/null)" != "$MODULE_VERSION" ]; then
            clear
            echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${B}│${NC}   ${R}● Rathole Core binary is NOT installed on this machine!${NC}                  ${B}│${NC}"
            echo -e "  ${B}│${NC}   ${W}Would you like to install the Core binary now?${NC}                           ${B}│${NC}"
            echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
            echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
            echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Iranian Mirror${NC} ${DIM}(${MTUNNEL_MIRROR_BASE})${NC}"
            echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .zip)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages)${NC}"
            echo -e "  ${DIM}│${NC}"
            echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Skip for now${NC}\n"
            echo -ne "  ${C}Select Source ❯❯ ${NC}"; read init_opt
            init_opt=$(echo "$init_opt" | tr -d '\r')
            if [[ "$init_opt" =~ ^[1-4]$ ]]; then
                if install_core_from_source "$init_opt"; then printf '%s\n' "$MODULE_VERSION" > "$first_prompt_flag"
                else rm -f "$first_prompt_flag"; return 1; fi
            elif [[ "$init_opt" = q || -z "$init_opt" ]]; then
                printf '%s\n' "$MODULE_VERSION" > "$first_prompt_flag"
            else return 1
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
ExecStartPre=/usr/bin/mrathole --counters %i
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

clean_rat_counters() {
    local bin chain direction
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        for chain in INPUT OUTPUT; do
            for direction in RX TX; do mt_delete_tagged_rules "$bin" mangle "$chain" "RAT_${direction}_$1"; done
        done
    done
}

zero_rat_counters() {
    local bin chain direction num
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        for chain in INPUT OUTPUT; do
            for direction in RX TX; do
                while read -r num; do [ -n "$num" ] && "$bin" -w 5 -t mangle -Z "$chain" "$num"; done < <(mt_tagged_rules "$bin" mangle "$chain" "RAT_${direction}_$1")
            done
        done
    done
}

generate_toml() {
    local name="$1"
    local dir="$CONF_DIR/$name"
    local meta="$dir/meta.conf"
    local toml="$dir/config.toml"
    
    local TYPE="" LINK_PORT="" REMOTE_IP="" TOKEN="" TCP_PORTS="" UDP_PORTS="" BIND_HOST="0.0.0.0"
    source "$meta" 2>/dev/null
    
    mt_valid_port "$LINK_PORT" && [[ "$TYPE" =~ ^[12]$ ]] || return 1
    BIND_HOST=$(mt_normalize_host "$BIND_HOST")
    mt_valid_ipv4 "$BIND_HOST" || mt_valid_ipv6 "$BIND_HOST" || return 1
    [ "$TYPE" != 2 ] || mt_valid_host "$REMOTE_IP" || return 1
    validate_forward_ports "$TCP_PORTS" 0 tcp && validate_forward_ports "$UDP_PORTS" 0 udp || return 1
    [[ "$TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    local final_toml="$toml"
    toml=$(mktemp "$dir/config.XXXXXX") || return 1
    > "$toml"
    if [ "$TYPE" == "1" ]; then
        echo "[server]" >> "$toml"
        echo "bind_addr = \"$(mt_hostport "$BIND_HOST" "$LINK_PORT")\"" >> "$toml"
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
                echo "bind_addr = \"$(mt_hostport "$BIND_HOST" "$p")\"" >> "$toml"
            done
        fi

        if [ -n "$UDP_PORTS" ]; then
            IFS=',' read -ra UDP_ARR <<< "$UDP_PORTS"
            for p in "${UDP_ARR[@]}"; do
                p=$(echo "$p" | tr -d ' '); [ -z "$p" ] && continue
                echo "" >> "$toml"
                echo "[server.services.udp_${p}]" >> "$toml"
                echo "type = \"udp\"" >> "$toml"
                echo "bind_addr = \"$(mt_hostport "$BIND_HOST" "$p")\"" >> "$toml"
            done
        fi
    else
        echo "[client]" >> "$toml"
        echo "remote_addr = \"$(mt_hostport "$REMOTE_IP" "$LINK_PORT")\"" >> "$toml"
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
    mt_install_files 600 "$toml" "$final_toml" || { rm -f "$toml"; return 1; }
    rm -f "$toml"
    clean_rat_counters "$name"
    mt_setup_counter_pair RAT "$name" "$LINK_PORT" "$REMOTE_IP" "$TYPE" "$BIND_HOST"
    return 0
}

rat_endpoint_host() {
    local ep="$1" host
    [ -n "$ep" ] || return 1
    if [[ "$ep" == \[*\]:* ]]; then host="${ep#\[}"; host="${host%\]:*}"; else host="${ep%:*}"; fi
    host="${host#::ffff:}"; printf '%s' "$host"
}

rat_unit_peer_ip() { mt_unit_live_peer "mrathole@${1}" "${2:-}" "${3:-}"; }

rat_unit_tcp_rtt() { mt_unit_tcp_rtt "mrathole@${1}" "$2"; }

get_tunnel_status() {
    local t_name="$1" known_active="${2:-0}" meta="$CONF_DIR/$t_name/meta.conf"
    local TYPE="" LINK_PORT="" REMOTE_IP="" peer
    source "$meta" 2>/dev/null
    if [ "$known_active" != "1" ] && ! systemctl is-active --quiet "mrathole@$t_name"; then echo "OFFLINE"; return; fi
    if [ "$TYPE" = "1" ]; then peer=$(rat_unit_peer_ip "$t_name" "$LINK_PORT" 2>/dev/null || true)
    else peer=$(rat_unit_peer_ip "$t_name" "" "$REMOTE_IP" 2>/dev/null || true); fi
    if [ -n "$peer" ]; then echo "CONNECTED"
    elif [ "$TYPE" = "1" ]; then echo "WAITING"
    else echo "RECONNECTING"; fi
}

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
        tcp_rtt=$(rat_unit_tcp_rtt "$t_name" "$target_ip" 2>/dev/null || true)
        [ -n "$tcp_rtt" ] && { echo "$tcp_rtt"; return; }
    fi
    if [ -n "$port" ] && [[ "$port" =~ ^[0-9]+$ ]]; then
        start_ts=$(date +%s%3N 2>/dev/null)
        if mt_tcp_probe "$target_ip" "$port"; then
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
HDR_ROWS_FILE="$SECURE_TMP/.mrathole_hdr_rows"
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
        tcp_rtt=$(rat_unit_tcp_rtt "$name" "$ip" 2>/dev/null || true)
        if [ -n "$tcp_rtt" ]; then avg="$tcp_rtt"; loss="---"
        elif [ -n "$(rat_unit_peer_ip "$name" 2>/dev/null || true)" ]; then loss="---"; fi
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
hdr_ss_peer() { rat_unit_peer_ip "$1" "$2" 2>/dev/null || true; }
hdr_conf_has() {
    local v; v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 | tr -d "\"' \r")
    [ -n "$v" ]
}
collect_header_rows() {
    local mode="${1:-}" tmp d meta name role port remote peer fwd up avg loss st act="" ina="" line
    tmp=$(mktemp "$SECURE_TMP/.mrathole_hdr_rows.XXXXXX") || return 1
    for d in "$CONF_DIR"/*; do
        [ -d "$d" ] && [ -f "$d/meta.conf" ] || continue
        meta="$d/meta.conf"; name=$(basename "$d")
        role=$(mt_read_kv "$meta" TYPE 2>/dev/null) || role=""
        port=$(mt_read_kv "$meta" LINK_PORT 2>/dev/null) || port=""
        remote=$(mt_read_kv "$meta" REMOTE_IP 2>/dev/null) || remote=""
        st=0; systemctl is-active --quiet "mrathole@${name}" 2>/dev/null && st=1
        peer="$remote"
        if [ "$st" = 1 ] && [ "$role" = 1 ]; then
            peer=$(hdr_ss_peer "$name" "$port"); [ -n "$peer" ] || peer="Listening"
        fi
        [ -n "$peer" ] && [ "$peer" != "0.0.0.0" ] || peer="---"
        avg="---"; loss="---"
        if [ "$st" = 1 ] && hdr_is_ip "$peer"; then
            if [ "$mode" = fast ]; then avg="..."; else IFS='|' read -r avg loss <<< "$(hdr_ping_probe "$peer" "$name")"; fi
        fi
        fwd="OFF"
        { hdr_conf_has "$meta" TCP_PORTS || hdr_conf_has "$meta" UDP_PORTS; } && fwd="ACT"
        [ "$role" = 2 ] && fwd="CLI"
        up="STOPPED"; [ "$st" = 1 ] && up=$(hdr_unit_uptime "mrathole@${name}")
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
        [ -f "$SECURE_TMP/.mrathole_in_menu" ] && kill -SIGUSR2 "$MAIN_PID" 2>/dev/null
        sleep 5
    done
}

draw_header() {
    local total_t=0; local active_t=0; local online_t=0; local waiting_t=0; local reconnecting_t=0
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
                case "$st" in
                    CONNECTED) ((online_t++));;
                    WAITING) ((waiting_t++));;
                    RECONNECTING) ((reconnecting_t++));;
                esac
            fi
            ((i++))
        done
    fi
    
    local core_color="${R}"; local core_raw="Not Installed"
    if is_rathole_core_valid; then
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
        elif [ "$reconnecting_t" -gt 0 ]; then
            stat_color="${Y}"; stat_icon="◎"; stat_text="CONNECTING"
        elif [ "$waiting_t" -gt 0 ]; then
            stat_color="${Y}"; stat_icon="◎"; stat_text="WAITING"
        else
            stat_color="${Y}"; stat_icon="◎"; stat_text="STARTING"
        fi
    fi

    local peer_ip="" peer_name=""
    local tmp_port=""
    for d in "$CONF_DIR"/*; do
        if [ -d "$d" ] && [ -f "$d/meta.conf" ]; then
            local tmp_type=$(grep "^TYPE=" "$d/meta.conf" | cut -d'=' -f2)
            local tmp_remote=$(grep "^REMOTE_IP=" "$d/meta.conf" | cut -d'=' -f2)
            tmp_port=$(grep "^LINK_PORT=" "$d/meta.conf" | cut -d'=' -f2)
            
            if [ -n "$tmp_remote" ] && [ "$tmp_remote" != "0.0.0.0" ]; then
                peer_ip="$tmp_remote"
                peer_name=$(basename "$d")
                break
            elif [ "$tmp_type" == "1" ]; then
                local tmp_name=$(basename "$d")
                peer_ip=$(rat_unit_peer_ip "$tmp_name" "$tmp_port" 2>/dev/null || true)
                if [ -n "$peer_ip" ]; then peer_name="$tmp_name"; break; fi
            fi
        fi
    done

    local g_color="${DIM}"; local g_text="N/A"
    if [ -n "$peer_ip" ]; then
        local cache_key="${peer_name:-peer}"; cache_key="${cache_key//[^A-Za-z0-9_.-]/_}"
        local ping_cache="$SECURE_TMP/.mrathole_ping_${cache_key}"
        local ping_lock="$SECURE_TMP/.mrathole_ping_${cache_key}.lock"
        local now=$(date +%s)
        local cache_ts=0; [ -f "$ping_cache" ] && cache_ts=$(stat -c %Y "$ping_cache" 2>/dev/null || echo 0)
        local cache_age=$(( now - cache_ts ))

        if [ -f "$ping_cache" ] && [ "$cache_age" -lt 15 ]; then
            local p_val=$(cat "$ping_cache" 2>/dev/null)
            if [[ "$p_val" != "Timeout" && "$p_val" != "N/A" ]]; then
                local p_int=$(echo "$p_val" | tr -dc '0-9')
                [ -z "$p_int" ] && p_int=0
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
                if [ -f "$SECURE_TMP/.mrathole_in_menu" ]; then
                    kill -SIGUSR2 "$MAIN_PID" 2>/dev/null
                fi
            ) &
        fi
    else
        g_color="${DIM}"; g_text="Waiting"
    fi

    # Unified dashboard header (same look as the main screen) -- THIS module's tunnels only.
    local _now _mtime
    _now=$(date +%s); _mtime=$(stat -c %Y "$HDR_ROWS_FILE" 2>/dev/null || echo 0)
    if [ ! -f "$HDR_ROWS_FILE" ] || [ $(( _now - _mtime )) -gt 15 ]; then collect_header_rows fast; fi
    mt_hdr_rows_from_cache "$HDR_ROWS_FILE" "RAT" ""
    HDR_DRAWN_ROWS=$MT_HDR_ROW_COUNT
    mt_hdr_draw "MRathole Core v${MODULE_VERSION}" "Active|${act_text}|${act_color}" \
        "Core|${core_raw}|${core_color}" "Status|${stat_icon} ${stat_text}|${stat_color}" \
        "Peer Ping|${g_text}|${g_color}" "Tunnels|${total_t}|${W}"
}

show_tunnel_registry() {
    draw_header
    echo -e "\n  ${Y}● Tunnel Info & Specs:${NC}"
    local count=0
    for d in "$CONF_DIR"/*; do
        [ ! -d "$d" ] && continue
        local t_name=$(basename "$d")
        local TYPE="" LINK_PORT="" REMOTE_IP="" TOKEN="" TCP_PORTS="" UDP_PORTS="" BIND_HOST="0.0.0.0"
        source "$d/meta.conf" 2>/dev/null
        
        local role_text=$([ "$TYPE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local ping_val="N/A"
        local connected_peer=""

        if [ "$TYPE" == "2" ] && [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "0.0.0.0" ]; then
            ping_val=$(get_peer_ping "$REMOTE_IP" "$LINK_PORT" "$t_name")
            connected_peer="$REMOTE_IP"
        elif [ "$TYPE" == "1" ]; then
            local p_ip=$(rat_unit_peer_ip "$t_name" "$LINK_PORT" 2>/dev/null || true)
            if [ -n "$p_ip" ]; then
                ping_val=$(get_peer_ping "$p_ip" "$LINK_PORT" "$t_name")
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
        if [ "$st" != "CONNECTED" ]; then
            mt_reason_row "$(mt_link_why "mrathole@${t_name}" "$([ "$TYPE" == "1" ] && echo 1 || echo 0)" "$([ "$TYPE" == "1" ] && echo "$LINK_PORT")" "$([ "$TYPE" != "1" ] && echo "$REMOTE_IP")")"
        fi

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
    if [ "${1:-}" != --no-pause ]; then
        echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
    fi
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
            local TYPE="" LINK_PORT="" REMOTE_IP="" TOKEN="" TCP_PORTS="" UDP_PORTS="" BIND_HOST="0.0.0.0"
            source "$d/meta.conf" 2>/dev/null
            
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
        mt_monitor_wait 1 || break
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
        [[ "$interval" =~ ^[0-9]+$ ]] && ((10#$interval >= 1 && 10#$interval <= 24)) || { echo -e "  ${R}Invalid interval! Use 1-24 hours.${NC}"; sleep 1.5; return; }
        
        echo "#!/bin/bash" > "$cron_script"
        echo "systemctl kill -s SIGKILL mrathole@${t_name}" >> "$cron_script"
        echo "systemctl restart mrathole@${t_name}" >> "$cron_script"
        chmod +x "$cron_script"
        
        if command -v crontab >/dev/null 2>&1; then
            local cron_tmp="$SECURE_TMP/crontab.$$"
            crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > "$cron_tmp"
            if [ "$interval" -eq 24 ]; then
                echo "0 0 * * * $cron_script #mrathole@${t_name}" >> "$cron_tmp"
            else
                echo "0 */${interval} * * * $cron_script #mrathole@${t_name}" >> "$cron_tmp"
            fi
            crontab "$cron_tmp"; rm -f "$cron_tmp"
            echo -e "  ${G}✔ Cronjob added: Tunnel will restart every ${interval} hours.${NC}"; sleep 2
        else
            echo -e "  ${R}✖ Crontab utility is missing on this system.${NC}"; sleep 2
        fi
    elif [[ "$cr_opt" == "2" ]]; then
        if command -v crontab >/dev/null 2>&1; then
            local cron_tmp="$SECURE_TMP/crontab.$$"
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
    
    echo -ne "  ${Y}Are you sure you want to proceed? Type '${R}yes${Y}' to confirm: ${NC}"; read confirm
    confirm=$(echo "$confirm" | tr -d '\r ')
    
    if [ "$confirm" != "yes" ]; then
        echo -e "  ${G}● Uninstallation cancelled.${NC}"; sleep 1.5; return
    fi

    echo -e "\n  ${DIM}● [1/5] Stopping services & killing processes...${NC}"
    systemctl stop mrathole@* 2>/dev/null
    systemctl disable mrathole@* 2>/dev/null
    # Do not kill every system process with the same executable name.

    echo -e "  ${DIM}● [2/5] Purging scheduled auto-restart cronjobs...${NC}"
    if command -v crontab >/dev/null 2>&1; then
        local cron_tmp="$SECURE_TMP/crontab.$$"
        crontab -l 2>/dev/null | grep -v "mrathole@" > "$cron_tmp"
        crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
    fi

    echo -e "  ${DIM}● [3/5] Removing systemd unit templates...${NC}"
    rm -f /etc/systemd/system/mrathole@.service
    systemctl daemon-reload 2>/dev/null

    echo -e "  ${DIM}● [4/5] Deleting configurations & core binary...${NC}"
    local dir; for dir in "$CONF_DIR"/*; do [ -d "$dir" ] && clean_rat_counters "$(basename "$dir")"; done
    rm -rf /etc/mrathole "$SECURE_TMP/.mrathole"*
    # Remove only an MTunnel-owned binary matching its ownership manifest.
    mt_owned_binary_remove rathole /usr/local/bin/rathole /usr/bin/rathole || true

    echo -e "  ${DIM}● [5/5] Removing mrathole wrapper script...${NC}"
    rm -f "$INSTALL_PATH" 2>/dev/null
    [ -f "$0" ] && rm -f "$0" 2>/dev/null

    echo -e "\n  ${G}✔ MRathole ecosystem has been completely eradicated from this system.${NC}\n"
    exit 0
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
    mt_valid_index "$t_idx" "${#configs[@]}" || return 1
    t_idx=$((10#$t_idx))
    
    SELECTED_TUN="${configs[$t_idx]}"
    return 0
}

if [ "${1:-}" == --counters ]; then
    [[ "${2:-}" =~ ^[A-Za-z0-9_-]+$ ]] && [ -f "$CONF_DIR/$2/meta.conf" ] || exit 1
    TYPE=''; LINK_PORT=''; REMOTE_IP=''; BIND_HOST='0.0.0.0'; source "$CONF_DIR/$2/meta.conf"
    mt_setup_counter_pair RAT "$2" "$LINK_PORT" "$REMOTE_IP" "$TYPE" "$BIND_HOST"
    exit $?
fi
if [ "${1:-}" == --apply ]; then
    for dir in "$CONF_DIR"/*; do [ -d "$dir" ] && generate_toml "$(basename "$dir")"; done
    exit 0
fi
for dir in "$CONF_DIR"/*; do
    [ -f "$dir/meta.conf" ] || continue
    TYPE=''; LINK_PORT=''; REMOTE_IP=''; BIND_HOST='0.0.0.0'; source "$dir/meta.conf"
    mt_setup_counter_pair RAT "$(basename "$dir")" "$LINK_PORT" "$REMOTE_IP" "$TYPE" "$BIND_HOST"
done

[ -n "${MT_PEER_LINK:-}" ] || check_first_run_core
setup_systemd

show_tunnels_info() {
    mt_tunnels_info_menu rathole draw_header show_tunnel_registry show_tunnel_logs
}

show_tunnel_logs() {
    select_tunnel || return 0
    local t_name int_trap
    t_name=$(basename "$SELECTED_TUN")
    draw_header
    echo -e "\n  ${DIM}● Live logs for ${W}${t_name}${NC} ${DIM}(Ctrl+C to return)${NC}\n"
    int_trap=$(trap -p INT)
    trap ':' INT
    journalctl -u "mrathole@${t_name}" -n 50 -f
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
    is_rathole_core_valid && return 0
    local choice
    echo -e "\n  ${Y}● Rathole Core is required before applying this Peer Code.${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Install Core From Github${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Install Core From Iranian Mirror${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    while true; do
        mt_live_readline choice "  ${C}Select Source ❯❯ ${NC}" || return 1
        choice="${choice//$'\r'/}"
        case "$choice" in
            1|2)
                if install_core_from_source "$choice"; then
                    is_rathole_core_valid && return 0
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

mt_link_deploy_locked() {
    mt_link_validate || return 1
    local name="${MT_LINK_DATA[NAME]}" role="${MT_LINK_DATA[ROLE]}" host="${MT_LINK_DATA[HOST]}" port="${MT_LINK_DATA[LINK_PORT]}" token="${MT_LINK_DATA[TOKEN]}" bind=0.0.0.0 key settings conf tmp unit
    [[ "$token" =~ ^[A-Za-z0-9_-]{1,256}$ ]] || return 1
    [[ "$host" != *:* ]] || bind=::
    bind="${MT_LINK_DATA[BIND_HOST]:-$bind}"
    if [ "$MT_KIND" = backhaul ]; then name="bh_${name#bh_}"; conf="$CONF_DIR/$name.meta"
    else conf="$CONF_DIR/$name/meta.conf"; fi
    [ ! -e "$conf" ] && { [ "$MT_KIND" != rathole ] || [ ! -e "$CONF_DIR/$name" ]; } || { echo 'Tunnel already exists; nothing overwritten.' >&2; return 1; }
    if [ "$role" = 1 ] && mt_port_busy "$port"; then echo 'Link port is already in use.' >&2; return 1; fi
    if [ "$MT_KIND" = backhaul ]; then
        validate_bh_ports "${MT_LINK_DATA[PORTS]}" "$role" || return 1
        settings=$(mktemp "$SECURE_TMP/peer-backhaul.XXXXXX") || return 1
        for key in "${!MT_LINK_DATA[@]}"; do [[ "$key" != ADV_* ]] || printf '%s=%s\n' "$key" "${MT_LINK_DATA[$key]}"; done > "$settings"
        bh_load_options '' "$settings" || { rm -f "$settings"; return 1; }
        # Forwarder is a choice local to the access server; peer configuration uses the native default.
        bh_activate_config "$name" "$role" "${MT_LINK_DATA[TRANSPORT]}" "$port" "$host" "$token" "${MT_LINK_DATA[PORTS]}" "${MT_LINK_DATA[ENABLE_UDP]}" "$bind" backhaul "$settings"
        local rc=$?; rm -f "$settings"
        if [ "$rc" != 0 ]; then systemctl stop "mbackhaul@$name"; bh_clear_forwarder "$name"; clean_bh_counters "$name"; rm -f "$conf" "$CONF_DIR/$name.toml"; return 1; fi
        unit="mbackhaul@$name"
    else
        validate_forward_ports "${MT_LINK_DATA[TCP_PORTS]}" "$role" tcp && validate_forward_ports "${MT_LINK_DATA[UDP_PORTS]}" "$role" udp || return 1
        mkdir "$CONF_DIR/$name" || return 1
        chmod 700 "$CONF_DIR/$name"
        {
            printf 'TYPE=%s\nBIND_HOST=%s\nLINK_PORT=%s\nREMOTE_IP=%s\nTOKEN=%s\nTCP_PORTS=%s\nUDP_PORTS=%s\n' "$role" "$bind" "$port" "$host" "$token" "${MT_LINK_DATA[TCP_PORTS]}" "${MT_LINK_DATA[UDP_PORTS]}"
        } > "$conf"; chmod 600 "$conf"
        unit="mrathole@$name"
        if ! generate_toml "$name" || ! systemctl restart "$unit" || ! mt_workspace_service_ready "$unit"; then
            journalctl -u "$unit" -n 8 --no-pager >&2; systemctl stop "$unit"; clean_rat_counters "$name"; rm -rf "$CONF_DIR/$name"; return 1
        fi
    fi
    systemctl enable "$unit" >/dev/null 2>&1
}
mt_workspace_service_ready() {
    local attempt
    for attempt in 1 2 3 4; do sleep .4; systemctl is-active --quiet "$1" || return 1; done
}
mt_workspace_health() {
    mt_link_select || return 1
    local name conf="$MT_LINK_CONF" host port role unit
    if [ "$MT_KIND" = rathole ]; then name=$(basename "$(dirname "$conf")"); role=$(mt_link_read "$conf" TYPE); port=$(mt_link_read "$conf" LINK_PORT); unit="mrathole@$name"
    else name=$(basename "$conf" .meta); role=$(mt_link_read "$conf" ROLE); port=$(mt_link_read "$conf" TUN_PORT); unit="mbackhaul@$name"; fi
    host=$(mt_link_read "$conf" REMOTE_IP)
    mt_workspace_screen
    systemctl status "$unit" --no-pager -l
    if [ "$role" = 2 ]; then
        if [ "$MT_KIND" = backhaul ] && [ "$(mt_link_read "$conf" TRANSPORT)" = udp ]; then
            echo '  UDP link: a TCP probe does not verify this transport; inspect packet counters and peer logs.'
        elif mt_tcp_probe "$host" "$port"; then echo '  TCP link endpoint is reachable (application forwarding must be checked separately).'
        else echo '  TCP link endpoint could not be reached.'; fi
    else echo '  Listener-side sessions:'; ss -tn "sport = :$port"; fi
    journalctl -u "$unit" -n 12 --no-pager
    mt_workspace_pause
}

# mt_link_deploy supplied by core/common.sh

# mt_workspace_auto_backup supplied by core/common.sh
mt_workspace_update_badge() {
    local rv file="$SECURE_TMP/.mrathole_remote_ver"
    [ -f "$file" ] || return 0
    rv=$(tr -d '\r\n ' < "$file")
    if mt_update_available "$rv" "$MODULE_VERSION"; then
        printf ' %b(Update Available: v%s)%b' "$Y" "$rv" "$NC"
    fi
    return 0
}
if [[ "${1:-}" != --* ]]; then hdr_stats_loop & HDR_PID=$!; fi
MT_KIND=rathole; MT_HEADER=draw_header; MT_SECTION=""
mt_workspace_route() {
    local section="$1"
    case "$section" in
        1) MT_SECTION=1; mt_workspace_menu "CREATE TUNNEL" "1|Manual Rathole Setup|1|${G}" "2|Create From Peer Link|97|${G}" "3|Generate Peer Setup Link|98|${M}" || { MT_SECTION=""; return 1; };;
        2) MT_SECTION=2; mt_workspace_menu "EDIT & MANAGE" "1|Remote Host / IP|3|${C}" "2|Auth Token|6|${G}" "3|Link Port|7|${C}" "4|Tunnel Name|8|${W}" "5|Listen Address|9|${C}" "6|Delete Tunnels|2|${R}" || { MT_SECTION=""; return 1; };;
        3) MT_SECTION=3; mt_workspace_menu "FORWARDING" "1|TCP Port Mappings|4|${Y}" "2|UDP Port Mappings|5|${M}" || { MT_SECTION=""; return 1; };;
        4) MT_SECTION=4; mt_workspace_menu "SYSTEM & SECURITY" "1|Auto Recovery|12|${G}" "2|BBR Settings|13|${G}" "3|Scheduled Restart|14|${Y}" "4|Restart Service|15|${G}" "5|Check Selected Tunnel|99|${C}" || { MT_SECTION=""; return 1; };;
        5) MT_ACTION=10;;
        6) MT_ACTION=11;;
        7) MT_ACTION=20;;
        8) MT_ACTION=96;;
        9) MT_ACTION=201;;
        10) MT_SECTION=2; MT_ACTION=2; MT_SHORTCUT=1;;
        11) MT_ACTION=18;;
        0) MT_ACTION=0;;
        *) return 1;;
    esac
}

render_mrathole_menu() {
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
    mt_workspace_row 11 'Uninstall MRATHOLE' "$R"
    mt_workspace_footer 'Return to Main Core'
}

if [ -n "${MT_PEER_LINK:-}" ]; then mt_link_import; exit $?; fi
while true; do
    if [ -n "$MT_SECTION" ]; then opt="$MT_SECTION"
    else
        render_mrathole_menu
        read_with_refresh "  ${C}MRATHOLE ❯❯ ${NC}" opt render_mrathole_menu || break
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
           
           bind_host="0.0.0.0"
           if [ "$s_type" == 1 ]; then mt_ask_bind_host || continue; bind_host="$MT_BIND_HOST"; fi
           r_ip="0.0.0.0"
           if [ "$s_type" == "2" ]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Target IRAN Host/IP: ${NC}"; read r_ip
                   r_ip=$(mt_normalize_host "${r_ip//$'\r'/}")
                   is_valid_host "$r_ip" && break
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"
               done
           fi
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Tunnel Link Port (e.g. 5050): ${NC}"; read t_port
               t_port=${t_port//$'\r'/}
               if ! mt_valid_port "$t_port"; then
                   echo -e "  ${R}Error: Port must be between 1 and 65535!${NC}"
                   continue
               fi

               if ss -tuln 2>/dev/null | grep -qE ":${t_port}\s"; then
                   echo -e "  ${R}Error: Port ${t_port} is already in use by another service!${NC}"
                   continue
               fi
               break
           done
           
           echo -ne "  ${C}●${NC} ${W}Custom Token (Leave blank to generate auto): ${NC}"; read t_token
           t_token=$(echo "$t_token" | tr -dc 'a-zA-Z0-9_-')
           [ -z "$t_token" ] && t_token=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
           
           # رفع باگ ۲: بررسی و اعتبارسنجی دقیق پورت‌های فوروارد
           while true; do
               echo -ne "  ${C}●${NC} ${W}TCP Ports to Forward (e.g. 80,443) [Blank if none]: ${NC}"; read tcp_p
               tcp_p=$(echo "$tcp_p" | tr -d '\r ')
               if [ "$s_type" = 1 ] && [ -n "$tcp_p" ]; then mt_port_guard bind "$tcp_p" "" "" "" "Rathole ${t_name}" || continue; tcp_p="$MT_PORT_TCP"; fi
               validate_forward_ports "$tcp_p" "$s_type" "tcp" && break
           done

           while true; do
               echo -ne "  ${C}●${NC} ${W}UDP Ports to Forward (e.g. 53) [Blank if none]: ${NC}"; read udp_p
               udp_p=$(echo "$udp_p" | tr -d '\r ')
               if [ "$s_type" = 1 ] && [ -n "$udp_p" ]; then mt_port_guard bind "" "$udp_p" "" "" "Rathole ${t_name}" || continue; udp_p="$MT_PORT_UDP"; fi
               validate_forward_ports "$udp_p" "$s_type" "udp" && break
           done
           
           mkdir -p "$CONF_DIR/$t_name"
           cat <<EOF > "$CONF_DIR/$t_name/meta.conf"
TYPE=$s_type
BIND_HOST=$bind_host
LINK_PORT=$t_port
REMOTE_IP=$r_ip
TOKEN=$t_token
TCP_PORTS=$tcp_p
UDP_PORTS=$udp_p
EOF
           
           chmod 600 "$CONF_DIR/$t_name/meta.conf"
           generate_toml "$t_name" || continue
           systemctl enable mrathole@$t_name >/dev/null 2>&1
           if systemctl restart "mrathole@$t_name" && mt_workspace_service_ready "mrathole@$t_name"; then
               mt_ask_bbr_on_create
               echo -e "  ${G}● Rathole service started successfully.${NC}"
               mt_link_offer "$CONF_DIR/$t_name/meta.conf"
           else
               echo -e "  ${R}✖ Rathole failed to start. Configuration retained for inspection.${NC}"
               journalctl -u "mrathole@$t_name" -n 8 --no-pager
               mt_workspace_pause
           fi
           sleep 1.5 ;;
           
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
                   clean_rat_counters "$t_name"
                   systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null
                   if command -v crontab >/dev/null 2>&1; then
                       cron_tmp="$SECURE_TMP/crontab.$$"
                       crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > "$cron_tmp"
                       crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
                   fi
                   rm -rf "$d"
               done
               echo -e "  ${G}All Tunnels Purged!${NC}"; sleep 1.5
           elif mt_valid_index "$del_idx" "${#tunnels[@]}"; then
               del_idx=$((10#$del_idx))
               t_name=$(basename "${tunnels[$del_idx]}")
               clean_rat_counters "$t_name"
               systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null
               if command -v crontab >/dev/null 2>&1; then
                   cron_tmp="$SECURE_TMP/crontab.$$"
                   crontab -l 2>/dev/null | grep -v "mrathole@${t_name}" > "$cron_tmp"
                   crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
               fi
               rm -rf "${tunnels[$del_idx]}"
               echo -e "  ${G}Tunnel Purged!${NC}"; sleep 1.5
           fi ;;

        3|4|5|6|7|8|14|15|9)
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN")
           TYPE=""; LINK_PORT=""; REMOTE_IP=""; TOKEN=""; TCP_PORTS=""; UDP_PORTS=""; BIND_HOST="0.0.0.0"
           source "$SELECTED_TUN/meta.conf" 2>/dev/null
           
           if [[ "$opt" == "3" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Remote Host/IP (Current: ${REMOTE_IP}): ${NC}"; read n_ip
               n_ip=$(mt_normalize_host "${n_ip//$'\r'/}")
               if [ -z "$n_ip" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if ! is_valid_host "$n_ip"; then
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"; sleep 1.5; continue
               fi
               REMOTE_IP="$n_ip"
               
           elif [[ "$opt" == "4" ]]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Enter TCP Ports (none to clear; e.g. 80,443) [Current: ${Y}${TCP_PORTS:-None}${W}]: ${NC}"; read n_tcp
                   n_tcp=${n_tcp//$'\r'/}
                   if [ "${n_tcp,,}" == none ] || [ "$n_tcp" == - ]; then TCP_PORTS=""; break; fi
                   if [ -z "$n_tcp" ]; then
                       echo -e "  ${Y}● No changes made.${NC}"; break
                   fi
                   if [ "$TYPE" = 1 ]; then mt_port_guard bind "$n_tcp" "" "mrathole@${t_name}.service" "" "Rathole ${t_name}" || continue; n_tcp="$MT_PORT_TCP"; fi
                   validate_forward_ports "$n_tcp" "$TYPE" "tcp" "$TCP_PORTS" && { TCP_PORTS="$n_tcp"; break; }
               done
               [ -z "$n_tcp" ] && continue
               
           elif [[ "$opt" == "5" ]]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Enter UDP Ports (none to clear; e.g. 53) [Current: ${C}${UDP_PORTS:-None}${W}]: ${NC}"; read n_udp
                   n_udp=${n_udp//$'\r'/}
                   if [ "${n_udp,,}" == none ] || [ "$n_udp" == - ]; then UDP_PORTS=""; break; fi
                   if [ -z "$n_udp" ]; then
                       echo -e "  ${Y}● No changes made.${NC}"; break
                   fi
                   if [ "$TYPE" = 1 ]; then mt_port_guard bind "" "$n_udp" "mrathole@${t_name}.service" "" "Rathole ${t_name}" || continue; n_udp="$MT_PORT_UDP"; fi
                   validate_forward_ports "$n_udp" "$TYPE" "udp" "$UDP_PORTS" && { UDP_PORTS="$n_udp"; break; }
               done
               [ -z "$n_udp" ] && continue

           elif [[ "$opt" == "6" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Auth Token / Secret [Current: ${Y}${TOKEN}${W}]: ${NC}"; read n_tok
               n_tok=$(echo "$n_tok" | tr -dc 'a-zA-Z0-9_-')
               if [ -z "$n_tok" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               TOKEN="$n_tok"
               echo -e "  ${G}✔ Auth Token updated.${NC}"

           elif [[ "$opt" == "7" ]]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Enter New Link Port [Current: ${Y}${LINK_PORT}${W}]: ${NC}"; read n_port
                   n_port=${n_port//$'\r'/}
                   if [ -z "$n_port" ]; then
                       echo -e "  ${Y}● No changes made.${NC}"; break
                   fi
                   if ! mt_valid_port "$n_port"; then
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
               echo -ne "  ${C}●${NC} ${W}New Tunnel Name (Current: ${Y}${t_name}${W}): ${NC}"; read new_name
               new_name=$(echo "$new_name" | tr -dc 'a-zA-Z0-9_-')
               if [ -n "$new_name" ]; then
                   if [ -d "$CONF_DIR/$new_name" ]; then
                       echo -e "  ${R}● Error: Tunnel name [${new_name}] already exists!${NC}"; sleep 1.5; continue
                   fi
                   
                   systemctl stop mrathole@$t_name 2>/dev/null; systemctl disable mrathole@$t_name 2>/dev/null
                   
                   if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "mrathole@${t_name}"; then
                       cron_tmp="$SECURE_TMP/crontab.$$"
                       crontab -l | grep -v "mrathole@${t_name}" > "$cron_tmp"
                       crontab "$cron_tmp"; rm -f "$cron_tmp"
                       rm -f "$CONF_DIR/$t_name/restart.sh"
                   fi

                   clean_rat_counters "$t_name"
                   mv "$CONF_DIR/$t_name" "$CONF_DIR/$new_name" 2>/dev/null
                   t_name="$new_name"
                   SELECTED_TUN="$CONF_DIR/$new_name"
                   systemctl enable mrathole@$t_name >/dev/null 2>&1
                   echo -e "  ${G}● Tunnel successfully renamed to: ${new_name}${NC}"
               else
                   echo -e "  ${Y}● Rename cancelled.${NC}"; sleep 1; continue
               fi
               
           elif [[ "$opt" == "14" ]]; then
               manage_cron "$t_name"; continue
               
           elif [[ "$opt" == "9" ]]; then
               [ "$TYPE" == 1 ] || continue
               mt_ask_bind_host || continue; BIND_HOST="$MT_BIND_HOST"

           elif [[ "$opt" == "15" ]]; then
               zero_rat_counters "$t_name"
           fi
           
           cat <<EOF > "$CONF_DIR/$t_name/meta.conf"
TYPE=$TYPE
BIND_HOST=$BIND_HOST
LINK_PORT=$LINK_PORT
REMOTE_IP=$REMOTE_IP
TOKEN=$TOKEN
TCP_PORTS=$TCP_PORTS
UDP_PORTS=$UDP_PORTS
EOF

           chmod 600 "$CONF_DIR/$t_name/meta.conf"
           generate_toml "$t_name" || continue
           systemctl restart mrathole@$t_name
           if systemctl is-active --quiet mrathole@$t_name; then
               echo -e "  ${G}✔ Tunnel updated and service restarted successfully.${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Tunnel failed to start. Please check logs!${NC}"; sleep 2
           fi
           ;;

        10) show_tunnels_info ;;
        16) menu_install_core ;;
        17) self_update_module ;;
        20) unified_update_menu ;;
        18) uninstall_mrathole ;;
        12) mt_run_tool mhealer --scope rathole ;;
        13) mt_run_tool mbbr --from-tunnel ;;
        11) show_live_radar ;;
        0) break ;;
    esac
done
