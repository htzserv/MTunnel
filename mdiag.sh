#!/bin/bash
# MTunnel MDiag — Unified Doctor & LinkTest diagnostics engine (v2.0.1).
MODULE_VERSION="2.0.1"
MTUNNEL_REQUIRED_CORE_API=1
MTUNNEL_REQUIRED_LAYOUT_REV=2
umask 077

DIAG_MODE="doctor"
case "${0##*/}" in
    linktest|linktest.sh) DIAG_MODE="linktest" ;;
    mdoctor|mdoctor.sh)   DIAG_MODE="doctor" ;;
esac
if [ "${1:-}" = "--mode" ] && [[ "${2:-}" =~ ^(doctor|linktest)$ ]]; then
    DIAG_MODE="$2"
    shift 2
fi
# MTUNNEL_COMMON_LOADER -- common API 1, required by this module.
mt_load_common() {
    local script_dir candidate
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    for candidate in \
        "$script_dir/../core/common.sh" \
        "$script_dir/core/common.sh" \
        /usr/lib/mtunnel/common.sh \
        /root/mtunnel/core/common.sh; do
        if [[ -f "$candidate" && -r "$candidate" ]]; then
            source "$candidate" || return 1
            if [[ "${MTUNNEL_CORE_API:-}" == "${MTUNNEL_REQUIRED_CORE_API:-1}" && "${MTUNNEL_LAYOUT_REV:-}" == "${MTUNNEL_REQUIRED_LAYOUT_REV:-2}" ]]; then return 0; fi
            printf 'MTunnel Doctor: incompatible shared core: %s\n' "$candidate" >&2
            return 1
        fi
    done
    echo 'MTunnel Doctor: core/common.sh is missing. Reinstall the complete bundle.' >&2
    return 1
}
mt_load_common || exit 1
unset -f mt_load_common
if [ "$EUID" != 0 ]; then echo "Run MTunnel Doctor with sudo." >&2; exit 1; fi


if [ "$DIAG_MODE" = "doctor" ]; then
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
FR='\033[1;33m'   # frame colour: gold (double-line frames and menu tree connectors)
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
REPORT_DIR="$LOCAL_DIR/reports"
mkdir -p "$SECURE_TMP" "$REPORT_DIR" 2>/dev/null
chmod 700 "$SECURE_TMP" "$REPORT_DIR" 2>/dev/null || true

DOC_PASS=0
DOC_WARN=0
DOC_FAIL=0
DOC_TOTAL=0
DOC_LAST_SUMMARY="Not scanned"
DOC_LAST_COLOR="$DIM"
DOC_PLAIN=0

INSTALL_PATH="/usr/bin/mdoctor"
MT_REL_PATH="mdiag.sh"

# ---------------- OTA update engine (same behaviour as mgre / mrathole) ----------------
MAIN_PID=$$
NEED_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1
UPDATE_CHECK_INTERVAL=120
read_with_refresh() {
    local prompt="$1" __resultvar="$2" redraw_func="$3" buffer="" char rc up now last_live=-1
    touch "$SECURE_TMP/.mdoctor_in_menu"
    echo -ne "$prompt"
    while true; do
        if [ "$NEED_REFRESH" = true ] && [ -z "$buffer" ] && [ -n "$redraw_func" ]; then
            NEED_REFRESH=false
            "$redraw_func"
            echo -ne "$prompt$buffer"
        fi
        IFS= read -rsn1 -t 0.3 char
        rc=$?
        if [ $rc -ne 0 ]; then
            if [ "$rc" -eq 142 ] || [ "$rc" -gt 128 ]; then
                read -r up _ < /proc/uptime 2>/dev/null || up=0; now="${up%%.*}"
                if [ "$now" != "$last_live" ]; then last_live="$now"; refresh_doctor_header_live; fi
                continue
            fi
            rm -f "$SECURE_TMP/.mdoctor_in_menu" 2>/dev/null
            return "$rc"
        fi
        if [[ -z "$char" || "$char" == $'\n' || "$char" == $'\r' ]]; then echo ""; break; fi
        if [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
            if [ -n "$buffer" ]; then buffer="${buffer%?}"; echo -ne "\b \b"; fi
            continue
        fi
        buffer+="$char"
        echo -ne "$char"
    done
    rm -f "$SECURE_TMP/.mdoctor_in_menu" 2>/dev/null
    printf -v "$__resultvar" '%s' "$buffer"
}

fetch_remote_version() {
    local url="$1" payload version=""
    if command -v curl >/dev/null 2>&1; then
        payload=$(curl -fsSL -r 0-4095 --connect-timeout 3 --max-time 8 "$url" 2>/dev/null) || return 1
    elif command -v wget >/dev/null 2>&1; then
        payload=$(wget -qO- --header="Range: bytes=0-4095" --timeout=8 "$url" 2>/dev/null) || return 1
    else return 1; fi
    version=$(printf '%s\n' "$payload" | sed -n 's/^MODULE_VERSION="\([^" ]*\)".*/\1/p' | head -n 1)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || return 1
    printf '%s\n' "$version"
}

check_update_bg_legacy() {
    local cb="" gh_ver="" mirror_ver="" latest_ver="" cand
    gh_ver=$(fetch_remote_version "${MTUNNEL_GITHUB_BASE}/${MT_REL_PATH}${cb}")
    mirror_ver=$(fetch_remote_version "${MTUNNEL_MIRROR_BASE}/${MT_REL_PATH}${cb}")
    [ -n "$gh_ver" ] && printf '%s\n' "$gh_ver" > "$SECURE_TMP/.mdoctor_remote_ver_github"
    [ -n "$mirror_ver" ] && printf '%s\n' "$mirror_ver" > "$SECURE_TMP/.mdoctor_remote_ver_mirror"
    for cand in "$gh_ver" "$mirror_ver"; do
        [[ "$cand" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || continue
        latest_ver=$(printf '%s\n%s\n' "$latest_ver" "$cand" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' | sort -V | tail -n 1)
    done
    [ -n "$latest_ver" ] && printf '%s\n' "$latest_ver" > "$SECURE_TMP/.mdoctor_remote_ver"
    return 0
}

check_update_bg() {
    # Shared checker: GitHub and the mirror are asked in parallel, the highest version wins.
    if declare -F mt_check_update_both >/dev/null 2>&1; then mt_check_update_both "mdiag.sh" "mdoctor"; return 0; fi
    check_update_bg_legacy
}

update_watcher_loop() {
    local before after
    while true; do
        before=$(cat "$SECURE_TMP/.mdoctor_remote_ver" 2>/dev/null)
        check_update_bg
        after=$(cat "$SECURE_TMP/.mdoctor_remote_ver" 2>/dev/null)
        if [ -f "$SECURE_TMP/.mdoctor_in_menu" ] && [ "$before" != "$after" ]; then
            kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        fi
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
if [[ "${1:-}" != -* ]]; then
    update_watcher_loop &
    WATCHER_PID=$!
fi
trap '[ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null; rm -f "$SECURE_TMP/.mdoctor_in_menu" 2>/dev/null' EXIT

doc_update_badge() {
    local rv file="$SECURE_TMP/.mdoctor_remote_ver"
    [ -f "$file" ] || return 0
    rv=$(tr -d '\r\n ' < "$file")
    [ -n "$rv" ] && [ "$rv" != Unknown ] || return 0
    declare -F mt_update_available >/dev/null || return 0
    if mt_update_available "$rv" "$MODULE_VERSION"; then
        printf '  %b(Update Available: v%s)%b' "$Y" "$rv" "$NC"
    fi
    return 0
}

self_update_module() {
    local src_opt="${1:-}" dl_url tmp_file confirm new_ver
    local fn
    for fn in mt_download mt_validate_script mt_install_script mt_capture_manual_script mt_module_downgrade_allowed mt_update_available; do
        if ! declare -F "$fn" >/dev/null; then
            echo -e "  ${R}✖ Shared core is too old for OTA ($fn missing). Update the whole bundle first.${NC}"; return 1
        fi
    done
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mdoctor_remote_ver" ] && remote_v=$(tr -d '\r\n ' < "$SECURE_TMP/.mdoctor_remote_ver")
    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && mt_update_available "$remote_v" "$MODULE_VERSION"; then
        gh_text="${gh_text}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${gh_text}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    if [ -z "$src_opt" ]; then
        clear; echo -e "\n  ${FR}┌─[ OTA Update (MDoctor) ]${NC}"
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
            1) dl_url="${MTUNNEL_GITHUB_BASE}/${MT_REL_PATH}";;
            2) dl_url="${MTUNNEL_MIRROR_BASE}/${MT_REL_PATH}";;
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read -r dl_url;;
        esac
        echo -e "\n  ${C}⟳${NC} ${W}Downloading Update...${NC}"
        if ! mt_download "$dl_url" "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Download failed. Installed module preserved.${NC}"; return 1; fi
    fi
    sed -i 's/\r$//' "$tmp_file"
    if ! mt_validate_script "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Invalid Bash module. Installed module preserved.${NC}"; return 1; fi
    new_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$tmp_file")
    if ! mt_module_downgrade_allowed "$MODULE_VERSION" "$new_ver"; then rm -f "$tmp_file"; return 1; fi
    echo -e "\n  ${FR}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
    echo -e "  ${FR}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
    echo -e "  ${FR}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read -r confirm
    [[ "${confirm,,}" == y || "${confirm,,}" == yes ]] || { echo -e "  ${Y}● Update cancelled by user.${NC}"; rm -f "$tmp_file"; return 0; }
    if ! mt_install_script "$tmp_file" "$MT_REL_PATH" "$INSTALL_PATH" "$0"; then
        rm -f "$tmp_file"; echo -e "  ${R}✖ Update failed. Previous module preserved.${NC}"; return 1
    fi
    rm -f "$tmp_file"
    echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
    [ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null || true
    exec "$INSTALL_PATH"
}
# ---------------- end OTA ----------------

_doc_color() { [ "$DOC_PLAIN" = 1 ] && printf '' || printf '%b' "$1"; }
_doc_reset() { [ "$DOC_PLAIN" = 1 ] && printf '' || printf '%b' "$NC"; }
_doc_icon() {
    case "$1" in
        PASS) printf '✔';;
        WARN) printf '⚠';;
        FAIL) printf '✖';;
        INFO) printf '●';;
        *) printf '·';;
    esac
}
_doc_status_color() {
    case "$1" in PASS) printf '%b' "$G";; WARN) printf '%b' "$Y";; FAIL) printf '%b' "$R";; INFO) printf '%b' "$C";; *) printf '%b' "$DIM";; esac
}

doc_reset_counts() { DOC_PASS=0; DOC_WARN=0; DOC_FAIL=0; DOC_TOTAL=0; }
doc_count() {
    case "$1" in
        PASS) DOC_PASS=$((DOC_PASS+1)); DOC_TOTAL=$((DOC_TOTAL+1));;
        WARN) DOC_WARN=$((DOC_WARN+1)); DOC_TOTAL=$((DOC_TOTAL+1));;
        FAIL) DOC_FAIL=$((DOC_FAIL+1)); DOC_TOTAL=$((DOC_TOTAL+1));;
    esac
}

doc_group() {
    local title="$1"
    if [ "$DOC_PLAIN" = 1 ]; then
        printf '\n[%s]\n' "$title"
    else
        printf '\n  %b┌─[ %s ]%b\n' "$FR" "$title" "$NC"
        printf '  %b│%b\n' "$FR" "$NC"
    fi
}

doc_row() {
    local state="$1" label="$2" value="$3" color icon
    doc_count "$state"
    if [ "$DOC_PLAIN" = 1 ]; then
        printf '  %-4s %-27s %s\n' "$state" "$label" "$value"
        return
    fi
    color=$(_doc_status_color "$state"); icon=$(_doc_icon "$state")
    printf '  %b├─%b %b%s%b %b%-27s%b %b%s%b\n' "$FR" "$NC" "$color" "$icon" "$NC" "$W" "$label" "$NC" "$color" "$value" "$NC"
}

doc_info() {
    local label="$1" value="$2"
    if [ "$DOC_PLAIN" = 1 ]; then printf '  INFO %-27s %s\n' "$label" "$value"
    else printf '  %b├─%b %b●%b %b%-27s%b %b%s%b\n' "$FR" "$NC" "$C" "$NC" "$W" "$label" "$NC" "$W" "$value" "$NC"; fi
}

doc_note() {
    if [ "$DOC_PLAIN" = 1 ]; then printf '  NOTE %s\n' "$*"; else printf '  %b│%b  %b%s%b\n' "$FR" "$NC" "$DIM" "$*" "$NC"; fi
}

doc_footer() {
    [ "$DOC_PLAIN" = 1 ] && return
    printf '  %b└────────────────────────────────────────────────────────────%b\n' "$FR" "$NC"
}

doc_pause() {
    local _
    [ "$DOC_PLAIN" = 1 ] && return 0
    printf '\n  %bPress Enter to return...%b' "$DIM" "$NC"
    read -r _
}

doc_local_dev() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

doc_default_mtu() {
    local dev; dev=$(doc_local_dev)
    [ -n "$dev" ] || return 1
    ip -o link show dev "$dev" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") {print $(i+1); exit}}'
}

doc_public_source_check() {
    local url="${MTUNNEL_GITHUB_BASE%/}/VERSION" out=''
    if command -v curl >/dev/null 2>&1; then
        out=$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 2 --max-time 5 "$url?t=$(date +%s)" 2>/dev/null | head -c 32 | tr -d '\r\n ')
    elif command -v wget >/dev/null 2>&1; then
        out=$(wget -qO- --https-only --timeout=5 "$url?t=$(date +%s)" 2>/dev/null | head -c 32 | tr -d '\r\n ')
    fi
    [[ "$out" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && { printf '%s' "$out"; return 0; }
    return 1
}

doc_kernel_module_status() {
    local mod="$1"
    if [ -d "/sys/module/$mod" ]; then printf 'loaded'; return 0; fi
    if command -v modprobe >/dev/null 2>&1 && modprobe -n "$mod" >/dev/null 2>&1; then printf 'available'; return 0; fi
    return 1
}

doc_iptables_backend() {
    local v
    v=$(iptables --version 2>/dev/null | head -n1)
    [ -n "$v" ] || return 1
    case "$v" in *nf_tables*) printf 'iptables-nft';; *legacy*) printf 'iptables-legacy';; *) printf '%s' "$v";; esac
}

doc_version_of() {
    sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$1" 2>/dev/null | head -n1
}

doc_script_check() {
    local label="$1" file="$2" version
    if [ ! -f "$file" ]; then doc_row WARN "$label" "not installed"; return; fi
    if ! bash -n "$file" >/dev/null 2>&1; then doc_row FAIL "$label" "syntax error"; return; fi
    version=$(doc_version_of "$file"); [ -n "$version" ] || version='unknown'
    doc_row PASS "$label" "v${version} / syntax OK"
}

doc_os_name() {
    local p='Linux'
    if [ -r /etc/os-release ]; then
        p=$(awk '$0 ~ /^PRETTY_NAME=/{v=substr($0,index($0,"=")+1); gsub(/^"|"$/,"",v); print v; exit}' /etc/os-release)
    fi
    printf '%s' "${p:-Linux}"
}

doc_scan_system() {
    local diskp sync pid1
    doc_group 'SYSTEM HEALTH'
    doc_row PASS 'Operating System' "$(doc_os_name)"
    doc_row PASS 'Kernel' "$(uname -r) / $(uname -m)"
    pid1=$(cat /proc/1/comm 2>/dev/null)
    if [ "$pid1" = systemd ] && command -v systemctl >/dev/null 2>&1; then doc_row PASS 'systemd' 'running as PID 1'; else doc_row FAIL 'systemd' "PID1=${pid1:-unknown}"; fi
    diskp=$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5);print $5}')
    if [[ "$diskp" =~ ^[0-9]+$ ]]; then
        if [ "$diskp" -ge 95 ]; then doc_row FAIL 'Root Disk Usage' "${diskp}% used"
        elif [ "$diskp" -ge 85 ]; then doc_row WARN 'Root Disk Usage' "${diskp}% used"
        else doc_row PASS 'Root Disk Usage' "${diskp}% used"; fi
    else doc_row WARN 'Root Disk Usage' 'unable to read'; fi
    sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [ "$sync" = yes ]; then doc_row PASS 'Clock Synchronization' 'NTP synchronized'; else doc_row WARN 'Clock Synchronization' "NTP=${sync:-unknown}"; fi
    if [ -r /proc/sys/net/ipv4/ip_forward ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ]; then doc_row PASS 'IPv4 Forwarding' 'enabled'; else doc_row FAIL 'IPv4 Forwarding' 'disabled'; fi
    if [ -r /proc/sys/net/ipv6/conf/all/forwarding ]; then
        if [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" = 1 ]; then doc_row PASS 'IPv6 Forwarding' 'enabled';
        elif [ -n "$(mt_local_ipv6 2>/dev/null)" ]; then doc_row WARN 'IPv6 Forwarding' 'disabled'; else doc_row PASS 'IPv6 Forwarding' 'disabled / no global IPv6'; fi
    else doc_row WARN 'IPv6 Forwarding' 'sysctl unavailable'; fi
    doc_footer
}

doc_scan_network() {
    local v4 v6 dev mtu source_v
    doc_group 'NETWORK & IPv6'
    v4=$(mt_local_ipv4 2>/dev/null); v6=$(mt_local_ipv6 2>/dev/null); dev=$(doc_local_dev); mtu=$(doc_default_mtu)
    [ -n "$v4" ] && doc_row PASS 'Local IPv4' "$v4" || doc_row FAIL 'Local IPv4' 'not detected'
    if ip -4 route show default 2>/dev/null | grep -q '^default'; then doc_row PASS 'IPv4 Default Route' "dev ${dev:-unknown}"; else doc_row FAIL 'IPv4 Default Route' 'missing'; fi
    [ -n "$v6" ] && doc_row PASS 'Global IPv6' "$v6" || doc_row WARN 'Global IPv6' 'not detected'
    if ip -6 route show default 2>/dev/null | grep -q '^default'; then doc_row PASS 'IPv6 Default Route' 'present'; elif [ -n "$v6" ]; then doc_row FAIL 'IPv6 Default Route' 'missing'; else doc_row WARN 'IPv6 Default Route' 'not configured'; fi
    if getent ahostsv4 github.com >/dev/null 2>&1; then doc_row PASS 'DNS Resolution' 'github.com resolves'; else doc_row FAIL 'DNS Resolution' 'resolution failed'; fi
    if source_v=$(doc_public_source_check); then doc_row PASS 'Official Source HTTPS' "reachable / v${source_v}"; else doc_row WARN 'Official Source HTTPS' 'unreachable or blocked'; fi
    [ -n "$mtu" ] && doc_row PASS 'Default Interface MTU' "${mtu} on ${dev:-unknown}" || doc_row WARN 'Default Interface MTU' 'unable to read'
    if command -v ping >/dev/null 2>&1 && ping -4 -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then doc_row PASS 'IPv4 Internet Probe' '1.1.1.1 reachable'; else doc_row WARN 'IPv4 Internet Probe' 'ICMP blocked or unreachable'; fi
    if [ -n "$v6" ]; then
        if command -v ping >/dev/null 2>&1 && ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then doc_row PASS 'IPv6 Internet Probe' 'Cloudflare IPv6 reachable'; else doc_row WARN 'IPv6 Internet Probe' 'ICMPv6 blocked or unreachable'; fi
    fi
    doc_footer
}

doc_scan_kernel() {
    local s
    doc_group 'TUNNEL KERNEL SUPPORT'
    for s in 'ip_gre|GRE / GRE6' 'ipip|IPIP' 'vxlan|VXLAN' 'xfrm_user|XFRM / IPsec'; do
        local mod="${s%%|*}" label="${s#*|}" state
        if state=$(doc_kernel_module_status "$mod"); then doc_row PASS "$label" "$mod $state"; else doc_row FAIL "$label" "$mod unavailable"; fi
    done
    if ip xfrm state >/dev/null 2>&1; then doc_row PASS 'XFRM Userspace' 'ip xfrm operational'; else doc_row WARN 'XFRM Userspace' 'xfrm query failed'; fi
    doc_footer
}

doc_scan_firewall() {
    local backend listeners mt_rules=0 ufw_state='inactive' fw_state='inactive'
    doc_group 'FIREWALL & PORTS'
    if backend=$(doc_iptables_backend); then doc_row PASS 'iptables Backend' "$backend"; else doc_row FAIL 'iptables Backend' 'not available'; fi
    if command -v nft >/dev/null 2>&1; then doc_row PASS 'nftables Tooling' "$(nft --version 2>/dev/null | head -n1)"; else doc_row WARN 'nftables Tooling' 'nft command missing'; fi
    if command -v ufw >/dev/null 2>&1; then ufw_state=$(ufw status 2>/dev/null | awk 'NR==1{print tolower($2)}'); fi
    if [ "$ufw_state" = active ]; then doc_row WARN 'UFW' 'active — verify MTunnel rules are permitted'; else doc_row PASS 'UFW' "${ufw_state:-inactive}"; fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then fw_state='active'; fi
    if [ "$fw_state" = active ]; then doc_row WARN 'firewalld' 'active — verify MTunnel zones/rules'; else doc_row PASS 'firewalld' 'inactive/not installed'; fi
    if command -v ss >/dev/null 2>&1; then
        listeners=$(ss -H -lntu 2>/dev/null | wc -l | tr -d ' ')
        doc_row PASS 'Listening Sockets' "${listeners:-0} TCP/UDP listeners"
    else doc_row FAIL 'Socket Inspector' 'ss command missing'; fi
    if command -v iptables-save >/dev/null 2>&1; then
        mt_rules=$(iptables-save 2>/dev/null | grep -Ec 'MGRE_|MXLAN_|MPORTER_|MBH_|RAT_|MPAQET_|OBFS_CNT_' || true)
        doc_row PASS 'MTunnel IPv4 Rules' "$mt_rules tagged rules"
    else doc_row WARN 'MTunnel IPv4 Rules' 'iptables-save unavailable'; fi
    doc_footer
}

doc_scan_mtunnel() {
    local corev core_file=/usr/lib/mtunnel/common.sh bin corepath
    doc_group 'MTUNNEL CORE & SCRIPT HEALTH'
    if [ -f "$core_file" ] && bash -n "$core_file" >/dev/null 2>&1 && grep -q '^MTUNNEL_CORE_API=1$' "$core_file"; then
        corev=$(sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$core_file" | head -n1)
        doc_row PASS 'Shared Core' "v${corev:-unknown} / API 1"
    else doc_row FAIL 'Shared Core' 'missing or invalid'; fi
    doc_script_check 'MTunnel Dashboard' /usr/bin/mtunnel
    doc_script_check 'GRE Engine' /usr/bin/mgre
    doc_script_check 'VXLAN Engine' /usr/bin/mxlan
    doc_script_check 'Rathole Engine' /usr/bin/mrathole
    doc_script_check 'Backhaul Engine' /usr/bin/mbackhaul
    doc_script_check 'Paqet Engine' /usr/bin/mpaqet
    doc_script_check 'MPorter' /usr/bin/mporter
    doc_script_check 'MTunnel Doctor' /usr/bin/mdoctor
    doc_script_check 'LinkTest Engine' /usr/bin/linktest
    for bin in bh rathole paqet; do
        corepath=$(command -v "$bin" 2>/dev/null || true)
        [ -n "$corepath" ] && doc_row PASS "Binary Core: $bin" "$corepath" || doc_row WARN "Binary Core: $bin" 'not installed yet'
    done
    doc_footer
}

doc_scan_services() {
    local failed mt_failed
    doc_group 'SERVICES & RUNTIME'
    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk 'NF{c++} END{print c+0}')
    if [ "${failed:-0}" -eq 0 ]; then doc_row PASS 'Failed systemd Units' '0'; else doc_row WARN 'Failed systemd Units' "$failed total failed units"; fi
    mt_failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '$1 ~ /^(mgre|mxlan|mporter|mbackhaul|mrathole|mpaqet)/ {print $1}' | paste -sd, -)
    [ -z "$mt_failed" ] && doc_row PASS 'Failed MTunnel Units' 'none' || doc_row FAIL 'Failed MTunnel Units' "$mt_failed"
    if systemctl is-system-running --quiet 2>/dev/null; then doc_row PASS 'systemd Overall State' 'running'; else
        local state; state=$(systemctl is-system-running 2>/dev/null || true)
        [ "$state" = degraded ] && doc_row WARN 'systemd Overall State' 'degraded' || doc_row WARN 'systemd Overall State' "${state:-unknown}"
    fi
    doc_footer
}

doc_print_summary() {
    local score=100 color="$G" verdict='HEALTHY'
    if [ "$DOC_TOTAL" -gt 0 ]; then
        score=$(( (DOC_PASS*100 + DOC_WARN*50) / DOC_TOTAL ))
    fi
    if [ "$DOC_FAIL" -gt 0 ]; then color="$R"; verdict='ACTION REQUIRED'
    elif [ "$DOC_WARN" -gt 0 ]; then color="$Y"; verdict='CHECK WARNINGS'; fi
    DOC_LAST_SUMMARY="${DOC_PASS} pass / ${DOC_WARN} warn / ${DOC_FAIL} fail — ${score}%"
    DOC_LAST_COLOR="$color"
    if [ "$DOC_PLAIN" = 1 ]; then
        printf '\nSUMMARY: %s | %s\n' "$verdict" "$DOC_LAST_SUMMARY"
    else
        printf '\n  %b┌─[ DOCTOR RESULT ]%b\n' "$FR" "$NC"
        printf '  %b│%b\n' "$FR" "$NC"
        printf '  %b├─%b %b%-17s%b %b%s%b\n' "$FR" "$NC" "$color" "$verdict" "$NC" "$W" "$DOC_LAST_SUMMARY" "$NC"
        printf '  %b└────────────────────────────────────────────────────────────%b\n' "$FR" "$NC"
    fi
}

doc_full_scan() {
    local mode="${1:-screen}"
    [ "$mode" = plain ] && DOC_PLAIN=1 || DOC_PLAIN=0
    doc_reset_counts
    if [ "$DOC_PLAIN" != 1 ]; then draw_doctor_header; fi
    doc_scan_system
    doc_scan_network
    doc_scan_kernel
    doc_scan_firewall
    doc_scan_mtunnel
    doc_scan_services
    doc_print_summary
    [ "$DOC_PLAIN" = 1 ] || doc_pause
    DOC_PLAIN=0
}

doc_network_screen() {
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_network; doc_scan_kernel; doc_print_summary; doc_pause
}

doc_firewall_screen() {
    local line n=0
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_firewall
    doc_group 'LISTENING PORT PREVIEW'
    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r line; do
            n=$((n+1)); [ "$n" -gt 18 ] && break
            printf '  %b├─%b %b●%b %s\n' "$FR" "$NC" "$C" "$NC" "$line"
        done < <(ss -H -lntup 2>/dev/null | awk '{printf "%-4s %-24s %s\n", $1, $5, $NF}')
        [ "$n" -gt 0 ] || doc_note 'No TCP/UDP listeners found.'
        [ "$n" -lt 18 ] || doc_note 'Preview limited to first 18 listeners.'
    else doc_note 'ss command is not available.'; fi
    doc_footer; doc_print_summary; doc_pause
}

doc_core_screen() {
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_mtunnel; doc_scan_services; doc_print_summary; doc_pause
}

doc_services_screen() {
    local line n=0
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_services
    doc_group 'FAILED UNIT DETAILS'
    while IFS= read -r line; do
        [ -n "$line" ] || continue; n=$((n+1)); [ "$n" -gt 15 ] && break
        printf '  %b├─%b %b⚠%b %s\n' "$FR" "$NC" "$Y" "$NC" "$line"
    done < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1 " — " $4}')
    [ "$n" -gt 0 ] || doc_note 'No failed systemd units.'
    doc_footer; doc_print_summary; doc_pause
}

doc_persist_forwarding() {
    local v4="$1" v6="$2" file=/etc/sysctl.d/99-mtunnel-doctor.conf tmp
    # Merge with what is already persisted so enabling IPv6 does not drop IPv4 (and vice versa).
    if [ -r "$file" ]; then
        grep -qE '^net\.ipv4\.ip_forward *= *1' "$file" 2>/dev/null && v4=1
        grep -qE '^net\.ipv6\.conf\.all\.forwarding *= *1' "$file" 2>/dev/null && v6=1
    fi
    tmp=$(mktemp "$SECURE_TMP/doctor-sysctl.XXXXXX") || return 1
    {
        echo '# Managed by MTunnel Doctor'
        [ "$v4" = 1 ] && echo 'net.ipv4.ip_forward = 1'
        [ "$v6" = 1 ] && echo 'net.ipv6.conf.all.forwarding = 1'
    } > "$tmp"
    install -m 0644 "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    sysctl --system >/dev/null 2>&1 || return 1
}

doc_confirm() {
    local answer
    printf '  %bType YES to continue ❯❯ %b' "$Y" "$NC"; read -r answer
    [ "$answer" = YES ]
}

doc_safe_repair() {
    local choice mod ok=1
    while true; do
        draw_doctor_header
        printf '\n  %b┌─[ SAFE REPAIR ACTIONS ]%b\n' "$FR" "$NC"
        printf '  %b│%b\n' "$FR" "$NC"
        printf '  %b├─%b %b1%b %b❯%b %bEnable & Persist IPv4 Forwarding%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC"
        printf '  %b├─%b %b2%b %b❯%b %bEnable & Persist IPv6 Forwarding%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$M" "$NC"
        printf '  %b├─%b %b3%b %b❯%b %bLoad Tunnel Kernel Modules%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
        printf '  %b├─%b %b4%b %b❯%b %bReload systemd Unit Database%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
        printf '  %b│%b\n' "$FR" "$NC"
        printf '  %b├────────────────────────────%b\n' "$FR" "$NC"
        printf '  %b└─%b %b0%b %b❯%b %bReturn to Doctor%b\n\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$DIM" "$NC"
        printf '  %bREPAIR ❯❯ %b' "$C" "$NC"; read -r choice
        case "$choice" in
            0|'') return 0;;
            1)
                echo -e "\n  ${Y}This writes /etc/sysctl.d/99-mtunnel-doctor.conf and enables IPv4 forwarding.${NC}"
                if doc_confirm && doc_persist_forwarding 1 0; then echo -e "  ${G}✔ IPv4 forwarding enabled and persisted.${NC}"; else echo -e "  ${R}✖ Cancelled or repair failed.${NC}"; fi; doc_pause;;
            2)
                echo -e "\n  ${Y}This writes /etc/sysctl.d/99-mtunnel-doctor.conf and enables IPv6 forwarding.${NC}"
                if doc_confirm && doc_persist_forwarding 0 1; then echo -e "  ${G}✔ IPv6 forwarding enabled and persisted.${NC}"; else echo -e "  ${R}✖ Cancelled or repair failed.${NC}"; fi; doc_pause;;
            3)
                echo -e "\n  ${DIM}Loading: ip_gre ipip vxlan xfrm_user${NC}"
                if doc_confirm; then
                    ok=1; for mod in ip_gre ipip vxlan xfrm_user; do modprobe "$mod" >/dev/null 2>&1 || ok=0; done
                    [ "$ok" = 1 ] && echo -e "  ${G}✔ Tunnel modules loaded.${NC}" || echo -e "  ${Y}⚠ One or more modules are unavailable on this kernel.${NC}"
                fi; doc_pause;;
            4)
                if doc_confirm && systemctl daemon-reload; then echo -e "  ${G}✔ systemd daemon-reload completed.${NC}"; else echo -e "  ${R}✖ Cancelled or reload failed.${NC}"; fi; doc_pause;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1;;
        esac
    done
}

doc_export_report() {
    local ts file tmp
    ts=$(date +%Y%m%d-%H%M%S); file="$REPORT_DIR/doctor-${ts}.txt"; tmp=$(mktemp "$SECURE_TMP/doctor-report.XXXXXX") || return 1
    {
        echo 'MTunnel Doctor Diagnostic Report'
        echo "Generated: $(date -Is)"
        echo "Doctor Version: $MODULE_VERSION"
        echo "Hostname: $(hostname 2>/dev/null)"
        echo '============================================================'
        doc_full_scan plain
    } > "$tmp"
    chmod 600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" || return 1
    DOC_PLAIN=0
    if [ "${DOC_NONINTERACTIVE:-0}" = 1 ]; then
        printf '%s\n' "$file"
        return 0
    fi
    draw_doctor_header
    echo -e "\n  ${FR}┌─[ REPORT EXPORTED ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${G}✔${NC} ${W}Diagnostic report saved successfully.${NC}"
    echo -e "  ${FR}└─${NC} ${C}${file}${NC}"
    doc_pause
}

draw_doctor_header() {
    clear
    mt_master_header_draw "$MODULE_VERSION"
}

refresh_doctor_header_live() {
    mt_live_vitals_update 2>/dev/null || true
    printf '\033[?25l\0337\033[1;1H'
    HEADER_LIVE=1 mt_master_header_draw "$MODULE_VERSION"
    printf '\0338\033[?25h'
}

render_doctor_menu() {
    draw_doctor_header
    printf '\n  %b┌─[ MTUNNEL DOCTOR & DIAGNOSTICS ]%b\n' "$FR" "$NC"
    printf '  %b│%b\n' "$FR" "$NC"
    printf '  %b├─%b %b1%b %b❯%b %bRun Full Health Scan%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
    printf '  %b├─%b %b2%b %b❯%b %bNetwork & IPv6 Diagnostics%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC"
    printf '  %b├─%b %b3%b %b❯%b %bFirewall & Port Diagnostics%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$Y" "$NC"
    printf '  %b├─%b %b4%b %b❯%b %bTunnel Engines & Core & Script Health%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$M" "$NC"
    printf '  %b├─%b %b5%b %b❯%b %bSystem Services & Failed Units%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC"
    printf '  %b├─%b %b6%b %b❯%b %bSafe Repair Actions%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
    printf '  %b├─%b %b7%b %b❯%b %bExport Diagnostic Report%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$W" "$NC"
    printf '  %b├─%b %b8%b %b❯%b %bOTA Update%b%s\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC" "$(doc_update_badge)"
    printf '  %b│%b\n' "$FR" "$NC"
    printf '  %b├────────────────────────────%b\n' "$FR" "$NC"
    printf '  %b└─%b %b0%b %b❯%b %bReturn to Dashboard%b\n\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$DIM" "$NC"
}

case "${1:-}" in
    --report) DOC_NONINTERACTIVE=1; doc_export_report; exit $?;;
    --scan|--status) doc_full_scan plain; exit $?;;
    --version|-V) printf 'MTunnel Doctor %s\n' "$MODULE_VERSION"; exit 0;;
    --help|-h)
        cat <<EOF
MTunnel Doctor v$MODULE_VERSION
Usage: mdoctor [--scan|--status|--report|--version]
  --scan, --status   Run a non-interactive full health scan
  --report           Export a diagnostic report and print its path
  --version          Show Doctor version
EOF
        exit 0;;
esac

while true; do
    render_doctor_menu
    read_with_refresh "  ${C}DOCTOR ❯❯ ${NC}" opt render_doctor_menu || { clear; exit 0; }
    opt="${opt//[$' \r\n\t']/}"
    case "$opt" in
        1) doc_full_scan;;
        2) doc_network_screen;;
        3) doc_firewall_screen;;
        4) doc_core_screen;;
        5) doc_services_screen;;
        6) doc_safe_repair;;
        7) doc_export_report;;
        8) self_update_module; doc_pause;;
        0|'') clear; exit 0;;
        *) echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1;;
    esac
done
exit 0
fi

if [ "$DIAG_MODE" = "linktest" ]; then

















B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
FR='\033[1;33m'   # frame colour: gold (double-line frames and menu tree connectors)
INSTALL_PATH="/usr/bin/linktest"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
TMP_DIR="$(mktemp -d /tmp/linktest.XXXXXX)"
LISTENER_PIDS=()
SYNC_PORT=49999
SPEED_PORT=49998

mkdir -p "$LOCAL_DIR/engines" "$LOCAL_DIR/prereqs" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    mt_install_files 755 "$0" "$INSTALL_PATH" || { echo "Cannot install module." >&2; exit 1; }
fi

cleanup() {
    local pid
    for pid in "${LISTENER_PIDS[@]}" "${ENGINE_PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
    rm -rf "$TMP_DIR" 2>/dev/null || true
    ip link del mtest_gre 2>/dev/null || true
    ip tunnel del mtest_gre 2>/dev/null || true
    ip link del mtest_sit 2>/dev/null || true
    ip tunnel del mtest_sit 2>/dev/null || true
    ip link del mtest_vx 2>/dev/null || true
    ip link del mtest_br 2>/dev/null || true
}
trap cleanup EXIT INT TERM
cleanup_session() {
    local pid
    for pid in "${LISTENER_PIDS[@]}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
    LISTENER_PIDS=()
    if declare -F lt_stop_engine_pids >/dev/null 2>&1; then lt_stop_engine_pids; fi
    ip link del mtest_gre 2>/dev/null || true
    ip tunnel del mtest_gre 2>/dev/null || true
    ip link del mtest_sit 2>/dev/null || true
    ip tunnel del mtest_sit 2>/dev/null || true
    ip link del mtest_vx 2>/dev/null || true
    ip link del mtest_br 2>/dev/null || true
    find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null || true
}

check_requirements() {
    local missing=()
    for bin in ip python3 ping ss timeout; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo -e "${R}✖ Missing required commands: ${missing[*]}${NC}"
        echo -e "${Y}Install them (e.g. iproute2, python3, iputils-ping, procps) and re-run.${NC}"
        exit 1
    fi
}
check_requirements

# --- ASYNC BACKGROUND UPDATE CHECKER ---
check_update_bg_legacy() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/mdiag.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/mdiag.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fSL -r 0-4095 -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fSL -r 0-4095 -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO-  --header="Range: bytes=0-4095" --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO-  --header="Range: bytes=0-4095" --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.linktest_remote_ver"
}
check_update_bg() {
    if declare -F mt_check_update_both >/dev/null 2>&1; then mt_check_update_both "mdiag.sh" "linktest"; return 0; fi
    check_update_bg_legacy
}
check_update_bg &
# ---------------------------------------

self_update_module() {
    local src_opt custom_url dl_url tmp_file confirm
    local rel_path="mdiag.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.linktest_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.linktest_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && mt_update_available "$remote_v" "$MODULE_VERSION"; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    draw_header; echo -e "\n  ${FR}┌─[ OTA Update (Linktest Engine) ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─[ AUTOMATIC MIRRORS ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${gh_text}"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─[ MANUAL OVERRIDES ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Offline Editor)${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r src_opt
    
    [[ "$src_opt" =~ ^[1-4]$ ]] || return 0
    tmp_file=$(mktemp "$SECURE_TMP/update.XXXXXX") || return 1
    if [ "$src_opt" == 4 ]; then
        if ! mt_capture_manual_script "$tmp_file"; then
            rm -f "$tmp_file"; echo -e "  ${R}✖ Manual paste failed. Installed module preserved.${NC}"; return 1
        fi
    else
        case "$src_opt" in
            1) dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path";;
            2) dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path";;
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read -r dl_url;;
        esac
        echo -e "\n  ${C}⟳${NC} ${W}Downloading Update...${NC}"
        if ! mt_download "$dl_url" "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Download failed. Installed module preserved.${NC}"; return 1; fi
    fi
    sed -i 's/\r$//' "$tmp_file"
    if ! mt_validate_script "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Invalid Bash module. Installed module preserved.${NC}"; return 1; fi
    local new_ver; new_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$tmp_file")
        echo -e "\n  ${FR}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${FR}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${FR}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${FR}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read -r confirm
        
    [[ "${confirm,,}" == y || "${confirm,,}" == yes ]] || { echo -e "  ${Y}● Update cancelled by user.${NC}"; rm -f "$tmp_file"; return 0; }
    if ! mt_install_script "$tmp_file" "$rel_path" "$INSTALL_PATH" "$0"; then
        rm -f "$tmp_file"; echo -e "  ${R}✖ Update failed. Previous module preserved.${NC}"; return 1
    fi
    [ -f /usr/bin/mdoctor ] && mt_install_files 755 "$tmp_file" /usr/bin/mdoctor >/dev/null 2>&1 || true
    rm -f "$tmp_file"
    echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
    [ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null || true
    exec "$INSTALL_PATH"
}

ping6_compat() {
    if command -v ping6 >/dev/null 2>&1; then
        ping6 "$@"
    else
        ping -6 "$@"
    fi
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_header() {
    clear
    mt_master_header_draw "$MODULE_VERSION"
}

verify_tunnel_ping() {
    local target_ip=$1
    local out=$(ping -c 3 -W 2 "$target_ip" 2>&1)
    if echo "$out" | grep -q ", 0% packet loss" || echo "$out" | grep -q ", 0.0% packet loss"; then
        local lat=$(echo "$out" | grep -oP 'time=\K[0-9.]+' | head -1)
        echo "OK|${lat:-1}ms"
    else
        echo "FAIL|---"
    fi
}

measure_tcp_speed() {
    local target_ip=$1; local target_port=$2; local duration=3
    local res=$(TARGET_IP="$target_ip" TARGET_PORT="$target_port" DURATION="$duration" python3 -c "
import socket, time, os
target_ip = os.environ['TARGET_IP']
target_port = int(os.environ['TARGET_PORT'])
duration = float(os.environ['DURATION'])
s = None
try:
    s = socket.create_connection((target_ip, target_port), timeout=3)
    start = time.time()
    total_bytes = 0
    buf = b'X' * 65536
    while time.time() - start < duration:
        s.sendall(buf)
        total_bytes += len(buf)
    elapsed = time.time() - start
    speed_mbps = (total_bytes * 8) / (elapsed * 1000 * 1000)
    print(f'{speed_mbps:.1f}')
except Exception:
    print('ERR')
finally:
    if s is not None: s.close()
" 2>/dev/null)
    echo "${res:-ERR}"
}

run_protocol_matrix_test() {
    draw_header
    echo -e "\n  ${FR}┌─[ AUTO-SYNCED PROTOCOL BENCHMARK ]${NC}"
    echo -e "  ${FR}│${NC} ${W}Info:${NC} Automated Step-by-Step handshake across both endpoints."
    echo -e "  ${FR}├────────────────────────────────────────────────────────────────────────────${NC}"

    while true; do
        echo -ne "  ${C}●${NC} ${W}Server Role [1: IRAN (Responder) | 2: KHAREJ (Initiator) | q: Back]: ${NC}"; read -r s_role
        [[ "$s_role" =~ ^[12q]$ ]] && break
    done
    [[ "$s_role" == "q" ]] && return

    local local_ip=$(mt_local_ipv4)
    [ "$local_ip" != "Unknown" ] || local_ip=$(get_local_ip)
    echo -ne "  ${C}●${NC} ${W}Local Public IPv4 [${Y}${local_ip}${W}]: ${NC}"; read -r custom_l
    local_ip=${custom_l:-$local_ip}; local_ip="${local_ip// /}"
    mt_valid_ipv4 "$local_ip" || { echo -e "  ${R}● A valid local IPv4 is required for the native GRE/SIT/VXLAN stage.${NC}"; sleep 1.5; return; }

    echo -ne "  ${C}●${NC} ${W}Remote Peer Public IPv4: ${NC}"; read -r remote_ip
    remote_ip=$(echo "$remote_ip" | tr -d '\r' | tr -d ' ')
    if ! mt_valid_ipv4 "$remote_ip"; then echo -e "  ${R}● A valid remote IPv4 is required for Option 1 native tests.${NC}"; sleep 1.5; return; fi

    if [ "$s_role" == "1" ]; then
        echo -e "\n  ${G}● IRAN Responder Active.${NC} Awaiting Sync Trigger from Kharej..."
        
        ip link del mtest_gre 2>/dev/null || true; ip tunnel del mtest_gre 2>/dev/null || true
        ip tunnel add mtest_gre mode gre remote "$remote_ip" local "$local_ip" ttl 255 key 999 2>/dev/null
        ip link set mtest_gre up 2>/dev/null; ip addr add "10.254.254.1/30" dev mtest_gre 2>/dev/null

        ip tunnel del mtest_sit 2>/dev/null || true
        ip tunnel add mtest_sit mode sit remote "$remote_ip" local "$local_ip" 2>/dev/null
        ip link set mtest_sit up 2>/dev/null; ip -6 addr add "fdfe:7465:7374::1/64" dev mtest_sit 2>/dev/null

        ip link del mtest_vx 2>/dev/null || true; ip link del mtest_br 2>/dev/null || true
        local eth_iface=$(ip route get "$remote_ip" 2>/dev/null | awk '{print $5}' | head -n 1)
        [ -z "$eth_iface" ] && eth_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -n 1)
        ip link add mtest_br type bridge 2>/dev/null; ip link set mtest_br up 2>/dev/null
        ip link add mtest_vx type vxlan id 9999 dev "$eth_iface" remote "$remote_ip" dstport 4789 2>/dev/null
        ip link set mtest_vx master mtest_br 2>/dev/null; ip link set mtest_vx up 2>/dev/null
        ip addr add "10.253.253.1/24" dev mtest_br 2>/dev/null

        cat > "$TMP_DIR/responder.py" <<PY
import socket, sys, time, threading, os
ports = [8443, 8888, 9443, 9643, 9743, $SYNC_PORT, $SPEED_PORT]

def handle_client(c):
    try:
        while True:
            data = c.recv(65536)
            if not data: break
    except: pass
    finally: c.close()

def listen_port(p):
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        s.bind(('::', p))
        s.listen(128)
        while True:
            c, a = s.accept()
            threading.Thread(target=handle_client, args=(c,), daemon=True).start()
    except Exception as exc:
        print(f"Listener {p} failed: {exc}", file=sys.stderr, flush=True)
        os._exit(1)

for p in ports:
    threading.Thread(target=listen_port, args=(p,), daemon=True).start()

while True:
    time.sleep(1)
PY
        python3 "$TMP_DIR/responder.py" &
        local resp_pid=$!
        LISTENER_PIDS+=("$resp_pid")
        sleep 1
        if ! kill -0 "$resp_pid" 2>/dev/null; then wait "$resp_pid"; cleanup_session; echo 'Responder could not bind all ports.' >&2; return 1; fi

        # Option 1 is the complete lab: prepare real BH/RH dual-stack engines too.
        lt_start_engine_responder --no-wait || true

        echo -e "  ${C}✓ Native tunnels, test ports, and BH/RH matrix responder are ready.${NC}"
        echo -e "  ${Y}● Go to KHAREJ server now and start Option 1.${NC}"
        echo -ne "\n  ${DIM}Press Enter when Kharej tests are finished to tear down...${NC}"; read -r dummy
        cleanup_session
        echo -e "  ${G}● Teardown complete. All test interfaces purged.${NC}"; sleep 1.5
        return

    else
        echo -e "\n  ${Y}● Synchronizing with IRAN server ($remote_ip)...${NC}"
        
        if ! timeout 3 bash -c "exec 3<>/dev/tcp/$remote_ip/$SYNC_PORT" 2>/dev/null; then
            echo -e "\n  ${R}✖ IRAN Server is NOT ready!${NC}"
            echo -e "  ${Y}Step 1:${NC} Open this menu on IRAN server and select ${W}1 (IRAN Responder)${NC}."
            echo -e "  ${Y}Step 2:${NC} Then run this option again on Kharej."
            echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read -r dummy; return
        fi

        echo -e "  ${G}✔ Sync Established!${NC} Executing benchmark matrix...\n"
        echo -e "  ${FR}╔═════════════════════════════╦════════════╦══════════════╦══════════════════════════════╗${NC}"
        printf "  ${FR}║${NC} ${W}%-27s${NC} ${FR}║${NC} ${W}%-10s${NC} ${FR}║${NC} ${W}%-12s${NC} ${FR}║${NC} ${W}%-28s${NC} ${FR}║${NC}\n" "PROTOCOL / TRANSPORT" "STATUS" "LATENCY" "DIAGNOSTICS & DETAILS"
        echo -e "  ${FR}╠═════════════════════════════╬════════════╬══════════════╬══════════════════════════════╣${NC}"

        local passed_protocols=()

        # 1. Standard GRE
        ip link del mtest_gre 2>/dev/null || true; ip tunnel del mtest_gre 2>/dev/null || true
        ip tunnel add mtest_gre mode gre remote "$remote_ip" local "$local_ip" ttl 255 key 999 2>/dev/null
        ip link set mtest_gre up 2>/dev/null; ip addr add "10.254.254.2/30" dev mtest_gre 2>/dev/null
        sleep 1.5
        local res_gre=$(verify_tunnel_ping "10.254.254.1")
        if [[ "$res_gre" =~ ^OK ]]; then
            printf "  ${FR}║${NC} ${C}%-27s${NC} ${FR}║${NC} ${G}%-10s${NC} ${FR}║${NC} ${Y}%-12s${NC} ${FR}║${NC} ${W}%-28s${NC} ${FR}║${NC}\n" "Standard IPv4 GRE" "PASSED" "${res_gre#OK|}" "Protocol 47 (GRE) Clean"
            passed_protocols+=("Standard GRE (L3)|10.254.254.1|$SPEED_PORT")
        else
            printf "  ${FR}║${NC} ${DIM}%-27s${NC} ${FR}║${NC} ${R}%-10s${NC} ${FR}║${NC} ${DIM}%-12s${NC} ${FR}║${NC} ${DIM}%-28s${NC} ${FR}║${NC}\n" "Standard IPv4 GRE" "BLOCKED" "---" "GRE Drop / ISP Filter"
            ip link del mtest_gre 2>/dev/null || true; ip tunnel del mtest_gre 2>/dev/null || true
        fi

        # 2. 6to4 IP6GRE
        ip tunnel del mtest_sit 2>/dev/null || true
        ip tunnel add mtest_sit mode sit remote "$remote_ip" local "$local_ip" 2>/dev/null
        ip link set mtest_sit up 2>/dev/null; ip -6 addr add "fdfe:7465:7374::2/64" dev mtest_sit 2>/dev/null
        sleep 1.5
        local ping_sit=$(ping6_compat -c 3 -W 2 "fdfe:7465:7374::1" 2>&1)
        if echo "$ping_sit" | grep -q ", 0% packet loss" || echo "$ping_sit" | grep -q ", 0.0% packet loss"; then
            local lat6=$(echo "$ping_sit" | grep -oP 'time=\K[0-9.]+' | head -1)
            printf "  ${FR}║${NC} ${M}%-27s${NC} ${FR}║${NC} ${G}%-10s${NC} ${FR}║${NC} ${Y}%-12s${NC} ${FR}║${NC} ${W}%-28s${NC} ${FR}║${NC}\n" "6to4 IP6GRE Encap" "PASSED" "${lat6:-1}ms" "Protocol 41 (SIT) Clean"
            passed_protocols+=("6to4 IP6GRE|fdfe:7465:7374::1|$SPEED_PORT")
        else
            printf "  ${FR}║${NC} ${DIM}%-27s${NC} ${FR}║${NC} ${R}%-10s${NC} ${FR}║${NC} ${DIM}%-12s${NC} ${FR}║${NC} ${DIM}%-28s${NC} ${FR}║${NC}\n" "6to4 IP6GRE Encap" "BLOCKED" "---" "Protocol 41 Filtered"
            ip link del mtest_sit 2>/dev/null || true; ip tunnel del mtest_sit 2>/dev/null || true
        fi

        # 3. VXLAN L2 Mesh
        ip link del mtest_vx 2>/dev/null || true; ip link del mtest_br 2>/dev/null || true
        local eth_iface=$(ip route get "$remote_ip" 2>/dev/null | awk '{print $5}' | head -n 1)
        [ -z "$eth_iface" ] && eth_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -n 1)
        ip link add mtest_br type bridge 2>/dev/null; ip link set mtest_br up 2>/dev/null
        ip link add mtest_vx type vxlan id 9999 dev "$eth_iface" remote "$remote_ip" dstport 4789 2>/dev/null
        ip link set mtest_vx master mtest_br 2>/dev/null; ip link set mtest_vx up 2>/dev/null
        ip addr add "10.253.253.2/24" dev mtest_br 2>/dev/null
        sleep 1.5
        local res_vx=$(verify_tunnel_ping "10.253.253.1")
        if [[ "$res_vx" =~ ^OK ]]; then
            printf "  ${FR}║${NC} ${M}%-27s${NC} ${FR}║${NC} ${G}%-10s${NC} ${FR}║${NC} ${Y}%-12s${NC} ${FR}║${NC} ${W}%-28s${NC} ${FR}║${NC}\n" "VXLAN L2 Bridge Mesh" "PASSED" "${res_vx#OK|}" "UDP 4789 Open & Fast"
            passed_protocols+=("VXLAN L2 Fabric|10.253.253.1|$SPEED_PORT")
        else
            printf "  ${FR}║${NC} ${DIM}%-27s${NC} ${FR}║${NC} ${R}%-10s${NC} ${FR}║${NC} ${DIM}%-12s${NC} ${FR}║${NC} ${DIM}%-28s${NC} ${FR}║${NC}\n" "VXLAN L2 Bridge Mesh" "BLOCKED" "---" "UDP Port 4789 Dropped"
            ip link del mtest_vx 2>/dev/null || true; ip link del mtest_br 2>/dev/null || true
        fi

        # 4. Rathole Reverse TCP
        if timeout 2 bash -c "exec 3<>/dev/tcp/$remote_ip/8443" 2>/dev/null; then
            printf "  ${FR}║${NC} ${R}%-27s${NC} ${FR}║${NC} ${G}%-10s${NC} ${FR}║${NC} ${Y}%-12s${NC} ${FR}║${NC} ${W}%-28s${NC} ${FR}║${NC}\n" "Rathole port precheck" "PASSED" "Direct" "Raw TCP :8443 reachable"
            passed_protocols+=("Rathole port precheck|$remote_ip|8443")
        else
            printf "  ${FR}║${NC} ${DIM}%-27s${NC} ${FR}║${NC} ${R}%-10s${NC} ${FR}║${NC} ${DIM}%-12s${NC} ${FR}║${NC} ${DIM}%-28s${NC} ${FR}║${NC}\n" "Rathole port precheck" "BLOCKED" "---" "Port 8443 Filtered"
        fi

        # 5. Paqet Raw Packet (Port 8888)
        if timeout 2 bash -c "exec 3<>/dev/tcp/$remote_ip/8888" 2>/dev/null; then
            printf "  ${FR}║${NC} ${M}%-27s${NC} ${FR}║${NC} ${G}%-10s${NC} ${FR}║${NC} ${Y}%-12s${NC} ${FR}║${NC} ${W}%-28s${NC} ${FR}║${NC}\n" "Paqet port precheck" "PASSED" "Direct" "Raw TCP :8888 reachable"
            passed_protocols+=("Paqet port precheck|$remote_ip|8888")
        else
            printf "  ${FR}║${NC} ${DIM}%-27s${NC} ${FR}║${NC} ${R}%-10s${NC} ${FR}║${NC} ${DIM}%-12s${NC} ${FR}║${NC} ${DIM}%-28s${NC} ${FR}║${NC}\n" "Paqet port precheck" "BLOCKED" "---" "Port 8888 Filtered"
        fi

        # 6. Backhaul Modes
        test_bh_mode() {
            local mode_name=$1; local port_num=$2; local label_color=$3
            if timeout 2 bash -c "exec 3<>/dev/tcp/$remote_ip/$port_num" 2>/dev/null; then
                printf "  ${FR}║${NC} %b%-27s%b ${FR}║${NC} ${G}%-10s${NC} ${FR}║${NC} ${Y}%-12s${NC} ${FR}║${NC} ${W}%-28s${NC} ${FR}║${NC}\n" "$label_color" "$mode_name" "$NC" "PASSED" "Direct" "Port $port_num Open"
                passed_protocols+=("$mode_name|$remote_ip|$port_num")
            else
                printf "  ${FR}║${NC} %b%-27s%b ${FR}║${NC} ${R}%-10s${NC} ${FR}║${NC} ${DIM}%-12s${NC} ${FR}║${NC} ${DIM}%-28s${NC} ${FR}║${NC}\n" "$label_color" "$mode_name" "$NC" "BLOCKED" "---" "Port $port_num Filtered"
            fi
        }

        test_bh_mode "Backhaul TCPMUX precheck" "9443" "${G}"
        test_bh_mode "Backhaul WSMUX precheck" "9643" "${Y}"
        test_bh_mode "Backhaul WSSMUX precheck" "9743" "${M}"

        echo -e "  ${FR}╚═════════════════════════════╩════════════╩══════════════╩══════════════════════════════╝${NC}"

        if [ ${#passed_protocols[@]} -gt 0 ]; then
            echo ""
            echo -ne "  ${C}●${NC} ${W}Run Live Speedtest benchmark on ${G}PASSED${W} channels? [y/N]: ${NC}"; read -r do_speed
            if [[ "${do_speed,,}" == "y" ]]; then
                echo -e "\n  ${Y}● Measuring Real-time Throughput (3s per channel)...${NC}\n"
                echo -e "  ${FR}╔═════════════════════════════╦══════════════════════════╦══════════════════════════════╗${NC}"
                printf "  ${FR}║${NC} ${W}%-27s${NC} ${FR}║${NC} ${W}%-24s${NC} ${FR}║${NC} ${W}%-28s${NC} ${FR}║${NC}\n" "PASSED CHANNEL" "BANDWIDTH THROUGHPUT" "DIAGNOSTIC STATUS"
                echo -e "  ${FR}╠═════════════════════════════╬══════════════════════════╬══════════════════════════════╣${NC}"

                for item in "${passed_protocols[@]}"; do
                    IFS='|' read -r p_name p_host p_port <<< "$item"

                    local sp_val=$(measure_tcp_speed "$p_host" "$p_port")
                    if [ "$sp_val" != "ERR" ] && [ -n "$sp_val" ]; then
                        printf "  ${FR}║${NC} ${C}%-27s${NC} ${FR}║${NC} ${G}%-24s${NC} ${FR}║${NC} ${W}%-28s${NC} ${FR}║${NC}\n" "$p_name" "▲ ${sp_val} Mbps" "Raw TCP throughput"
                    else
                        printf "  ${FR}║${NC} ${DIM}%-27s${NC} ${FR}║${NC} ${R}%-24s${NC} ${FR}║${NC} ${DIM}%-28s${NC} ${FR}║${NC}\n" "$p_name" "N/A" "Connection Timeout"
                    fi
                done
                echo -e "  ${FR}╚═════════════════════════════╩══════════════════════════╩══════════════════════════════╝${NC}"
            fi
        fi

        # Full Matrix continues with real Backhaul/Rathole IPv4↔IPv6 paths.
        local engine_remote6=''
        echo -ne "\n  ${C}●${NC} ${W}Responder IPv6 for BH/RH 4↔6 / 6↔6 tests [blank if unavailable]: ${NC}"; read -r engine_remote6
        engine_remote6=$(mt_normalize_host "${engine_remote6// /}")
        if [ -z "$engine_remote6" ] || mt_valid_ipv6 "$engine_remote6"; then
            lt_run_engine_matrix_tester "$remote_ip" "$engine_remote6" || true
        else
            echo -e "  ${Y}⚠ Invalid IPv6; IPv6 engine paths skipped.${NC}"
            lt_run_engine_matrix_tester "$remote_ip" "" || true
        fi

        ip link del mtest_gre 2>/dev/null || true; ip tunnel del mtest_gre 2>/dev/null || true
        ip link del mtest_sit 2>/dev/null || true; ip tunnel del mtest_sit 2>/dev/null || true
        ip link del mtest_vx 2>/dev/null || true; ip link del mtest_br 2>/dev/null || true
        lt_stop_engine_pids 2>/dev/null || true

        echo -e "\n  ${DIM}Full Matrix finished. Native tunnels, BH/RH engines, and temporary listeners cleaned up.${NC}"
        echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read -r dummy
    fi
}

# --- BACKHAUL / RATHOLE IPv4+IPv6 ENGINE MATRIX ---
ENGINE_CTRL_PORT=49997
ENGINE_UDP_PORT=49996
ENGINE_PIDS=()

lt_core_path() {
    local name="$1" p
    case "$name" in
        bh) for p in /usr/local/bin/bh /usr/bin/bh; do [ -x "$p" ] && { printf '%s' "$p"; return 0; }; done ;;
        rathole) for p in /usr/local/bin/rathole /usr/bin/rathole; do [ -x "$p" ] && { printf '%s' "$p"; return 0; }; done ;;
    esac
    return 1
}

lt_hp() {
    if [[ "$1" == *:* ]]; then printf '[%s]:%s' "$1" "$2"; else printf '%s:%s' "$1" "$2"; fi
}

lt_engine_record() {
    case "$1" in
        BH44) printf 'BH|4|4|51040|51140|51240' ;;
        BH46) printf 'BH|4|6|51041|51141|51241' ;;
        BH64) printf 'BH|6|4|51042|51142|51242' ;;
        BH66) printf 'BH|6|6|51043|51143|51243' ;;
        RH44) printf 'RH|4|4|51050|51150|51250' ;;
        RH46) printf 'RH|4|6|51051|51151|51251' ;;
        RH64) printf 'RH|6|4|51052|51152|51252' ;;
        RH66) printf 'RH|6|6|51053|51153|51253' ;;
        *) return 1 ;;
    esac
}

lt_engine_label() {
    case "$1" in
        BH44) echo 'BH 4→4' ;; BH46) echo 'BH 4→6' ;; BH64) echo 'BH 6→4' ;; BH66) echo 'BH 6→6' ;;
        RH44) echo 'RH 4→4' ;; RH46) echo 'RH 4→6' ;; RH64) echo 'RH 6→4' ;; RH66) echo 'RH 6→6' ;;
    esac
}

lt_engine_detail() {
    local rec engine payload link a b c
    rec=$(lt_engine_record "$1") || return 1
    IFS='|' read -r engine payload link a b c <<< "$rec"
    printf 'IPv%s payload / IPv%s link' "$payload" "$link"
}

lt_write_bh_server() {
    local file="$1" linkfam="$2" payloadfam="$3" linkport="$4" publicport="$5" backendport="$6"
    local linkbind='0.0.0.0' publicbind='0.0.0.0' backend='127.0.0.1'
    [ "$linkfam" = 6 ] && linkbind='::'
    [ "$payloadfam" = 6 ] && { publicbind='::'; backend='::1'; }
    cat > "$file" <<EOF_BH
[server]
bind_addr = "$(lt_hp "$linkbind" "$linkport")"
transport = "tcp"
accept_udp = false
token = "mtunnel_linktest_123"
log_level = "error"
sniffer = false
web_port = 0
channel_size = 1024
heartbeat = 10
keepalive_period = 30
nodelay = true
mss = 1360
so_rcvbuf = 0
so_sndbuf = 0
proxy_protocol = false
ports = [ "$(lt_hp "$publicbind" "$publicport")=$(lt_hp "$backend" "$backendport")" ]
EOF_BH
}

lt_write_bh_client() {
    local file="$1" remote="$2" linkport="$3"
    cat > "$file" <<EOF_BH
[client]
remote_addr = "$(lt_hp "$remote" "$linkport")"
transport = "tcp"
token = "mtunnel_linktest_123"
log_level = "error"
sniffer = false
web_port = 0
connection_pool = 2
retry_interval = 1
dial_timeout = 5
aggressive_pool = false
keepalive_period = 30
nodelay = true
mss = 1360
so_rcvbuf = 0
so_sndbuf = 0
EOF_BH
}

lt_write_rh_server() {
    local file="$1" linkfam="$2" payloadfam="$3" linkport="$4" publicport="$5"
    local linkbind='0.0.0.0' publicbind='0.0.0.0'
    [ "$linkfam" = 6 ] && linkbind='::'
    [ "$payloadfam" = 6 ] && publicbind='::'
    cat > "$file" <<EOF_RH
[server]
bind_addr = "$(lt_hp "$linkbind" "$linkport")"
default_token = "mtunnel_linktest_123"
heartbeat_interval = 10

[server.transport]
type = "tcp"
[server.transport.tcp]
nodelay = true

[server.services.linktest]
type = "tcp"
bind_addr = "$(lt_hp "$publicbind" "$publicport")"
EOF_RH
}

lt_write_rh_client() {
    local file="$1" remote="$2" linkport="$3" payloadfam="$4" backendport="$5"
    local backend='127.0.0.1'; [ "$payloadfam" = 6 ] && backend='::1'
    cat > "$file" <<EOF_RH
[client]
remote_addr = "$(lt_hp "$remote" "$linkport")"
default_token = "mtunnel_linktest_123"
heartbeat_timeout = 30
retry_interval = 1

[client.transport]
type = "tcp"
[client.transport.tcp]
nodelay = true

[client.services.linktest]
type = "tcp"
local_addr = "$(lt_hp "$backend" "$backendport")"
EOF_RH
}

lt_start_bg() {
    local log="$1"; shift
    "$@" >"$log" 2>&1 &
    LT_LAST_PID=$!
    ENGINE_PIDS+=("$LT_LAST_PID")
    sleep 0.35
    kill -0 "$LT_LAST_PID" 2>/dev/null
}

lt_forget_pid() {
    local drop="$1" p; local -a keep=()
    for p in "${ENGINE_PIDS[@]:-}"; do [ "$p" = "$drop" ] || keep+=("$p"); done
    ENGINE_PIDS=("${keep[@]}")
}

lt_start_echo_backend() {
    local fam="$1" port="$2"
    LT_FAM="$fam" LT_PORT="$port" python3 - <<'PY' >/dev/null 2>&1 &
import os, socket, threading
fam = socket.AF_INET6 if os.environ['LT_FAM'] == '6' else socket.AF_INET
host = '::1' if fam == socket.AF_INET6 else '127.0.0.1'
s = socket.socket(fam, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
if fam == socket.AF_INET6:
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
s.bind((host, int(os.environ['LT_PORT'])))
s.listen(64)
def h(c):
    try:
        while True:
            d = c.recv(65536)
            if not d: break
            c.sendall(d)
    except Exception:
        pass
    finally:
        c.close()
while True:
    c, _ = s.accept()
    threading.Thread(target=h, args=(c,), daemon=True).start()
PY
    LT_ECHO_PID=$!
    ENGINE_PIDS+=("$LT_ECHO_PID")
    sleep 0.2
    kill -0 "$LT_ECHO_PID" 2>/dev/null
}

lt_roundtrip_ms() {
    LT_HOST="$1" LT_PORT="$2" python3 - <<'PY' 2>/dev/null
import os, socket, time
host=os.environ['LT_HOST']; port=int(os.environ['LT_PORT']); marker=b'MTUNNEL-LINKTEST-123\n'
try:
    t=time.monotonic(); s=socket.create_connection((host,port),2.0); s.settimeout(2.0)
    s.sendall(marker); data=b''
    while len(data)<len(marker):
        chunk=s.recv(4096)
        if not chunk: break
        data += chunk
    s.close()
    if data == marker: print(max(1, round((time.monotonic()-t)*1000)))
    else: print('ERR')
except Exception:
    print('ERR')
PY
}

lt_wait_roundtrip() {
    local host="$1" port="$2" i value
    for ((i=0;i<16;i++)); do
        value=$(lt_roundtrip_ms "$host" "$port")
        if [[ "$value" =~ ^[0-9]+$ ]]; then printf '%s' "$value"; return 0; fi
        sleep 0.5
    done
    return 1
}

lt_start_control_server() {
    local caps_file="$1"
    LT_CAPS_FILE="$caps_file" LT_CTRL_PORT="$ENGINE_CTRL_PORT" LT_UDP_PORT="$ENGINE_UDP_PORT" python3 - <<'PY' >"$TMP_DIR/control.log" 2>&1 &
import os, socket, threading, select
caps_file=os.environ['LT_CAPS_FILE']; ctrl=int(os.environ['LT_CTRL_PORT']); udp=int(os.environ['LT_UDP_PORT'])
def caps():
    try: return open(caps_file,'r',encoding='utf-8').read().strip()+'\n'
    except Exception: return '\n'
def tcp_loop(s):
    while True:
        c,_=s.accept()
        try:
            c.settimeout(2); data=c.recv(128)
            c.sendall(caps().encode() if data.startswith(b'CAPS') else b'OK\n')
        except Exception: pass
        finally: c.close()
def udp_loop(s):
    while True:
        try:
            d,a=s.recvfrom(2048); s.sendto(d,a)
        except Exception: pass
socks=[]
try:
    s6=socket.socket(socket.AF_INET6,socket.SOCK_STREAM); s6.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s6.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1); s6.bind(('::',ctrl)); s6.listen(32); socks.append(s6); threading.Thread(target=tcp_loop,args=(s6,),daemon=True).start()
except Exception: pass
try:
    s4=socket.socket(socket.AF_INET,socket.SOCK_STREAM); s4.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s4.bind(('0.0.0.0',ctrl)); s4.listen(32); socks.append(s4); threading.Thread(target=tcp_loop,args=(s4,),daemon=True).start()
except Exception: pass
for fam,host in ((socket.AF_INET,'0.0.0.0'),(socket.AF_INET6,'::')):
    try:
        u=socket.socket(fam,socket.SOCK_DGRAM); u.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        if fam==socket.AF_INET6: u.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
        u.bind((host,udp)); socks.append(u); threading.Thread(target=udp_loop,args=(u,),daemon=True).start()
    except Exception: pass
if not socks: raise SystemExit(1)
threading.Event().wait()
PY
    LT_LAST_PID=$!; ENGINE_PIDS+=("$LT_LAST_PID"); sleep 0.3; kill -0 "$LT_LAST_PID" 2>/dev/null
}

lt_query_caps() {
    LT_HOST="$1" LT_PORT="$ENGINE_CTRL_PORT" python3 - <<'PY' 2>/dev/null
import os, socket
try:
    s=socket.create_connection((os.environ['LT_HOST'],int(os.environ['LT_PORT'])),2.5); s.settimeout(2.5)
    s.sendall(b'CAPS\n'); print(s.recv(4096).decode(errors='ignore').strip()); s.close()
except Exception: pass
PY
}

lt_udp_probe() {
    LT_HOST="$1" LT_PORT="$ENGINE_UDP_PORT" python3 - <<'PY' 2>/dev/null
import os,socket,time
h=os.environ['LT_HOST']; p=int(os.environ['LT_PORT']); fam=socket.AF_INET6 if ':' in h else socket.AF_INET
try:
    s=socket.socket(fam,socket.SOCK_DGRAM); s.settimeout(2); msg=b'MT-LT-UDP'; t=time.monotonic(); s.sendto(msg,(h,p)); d,_=s.recvfrom(128); s.close()
    print(max(1,round((time.monotonic()-t)*1000)) if d==msg else 'ERR')
except Exception: print('ERR')
PY
}

lt_stop_engine_pids() {
    local pid
    for pid in "${ENGINE_PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
    ENGINE_PIDS=()
    rm -f "$TMP_DIR"/*.server.toml "$TMP_DIR"/*.client.toml "$TMP_DIR"/*.server.log "$TMP_DIR"/*.client.log "$TMP_DIR/engine_caps" "$TMP_DIR/control.log" 2>/dev/null || true
}

lt_start_engine_responder() {
    local key rec engine payload link linkport publicport backendport core cfg log bindok cap='' local4 local6
    local4=$(mt_local_ipv4); local6=$(mt_local_ipv6)
    [ "$local4" != Unknown ] || local4=''
    echo -e "\n  ${FR}┌─[ BH / RH DUAL-STACK RESPONDER ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}IPv4:${NC} ${C}${local4:-Unavailable}${NC}"
    echo -e "  ${FR}├─${NC} ${W}IPv6:${NC} ${C}${local6:-Unavailable}${NC}"
    echo -e "  ${FR}├────────────────────────────────────────────────────────────${NC}"
    local caps_file="$TMP_DIR/engine_caps"; : > "$caps_file"
    for key in BH44 BH46 BH64 BH66 RH44 RH46 RH64 RH66; do
        rec=$(lt_engine_record "$key"); IFS='|' read -r engine payload link linkport publicport backendport <<< "$rec"
        if { [ "$link" = 4 ] && [ -z "$local4" ]; } || { [ "$payload" = 4 ] && [ -z "$local4" ]; } || { [ "$link" = 6 ] && [ -z "$local6" ]; } || { [ "$payload" = 6 ] && [ -z "$local6" ]; }; then
            printf '  %b├─%b %-9s %bUNAVAILABLE%b  %s\n' "$FR" "$NC" "$(lt_engine_label "$key")" "$Y" "$NC" "$(lt_engine_detail "$key")"
            continue
        fi
        core=''
        if [ "$engine" = BH ]; then core=$(lt_core_path bh 2>/dev/null || true); else core=$(lt_core_path rathole 2>/dev/null || true); fi
        if [ -z "$core" ]; then
            printf '  %b├─%b %-9s %bCORE MISSING%b  %s\n' "$FR" "$NC" "$(lt_engine_label "$key")" "$Y" "$NC" "$(lt_engine_detail "$key")"
            continue
        fi
        if mt_port_busy "$linkport" tcp || mt_port_busy "$publicport" tcp; then
            printf '  %b├─%b %-9s %bPORT BUSY%b    %s\n' "$FR" "$NC" "$(lt_engine_label "$key")" "$Y" "$NC" "$(lt_engine_detail "$key")"
            continue
        fi
        cfg="$TMP_DIR/${key}.server.toml"; log="$TMP_DIR/${key}.server.log"
        if [ "$engine" = BH ]; then lt_write_bh_server "$cfg" "$link" "$payload" "$linkport" "$publicport" "$backendport"; lt_start_bg "$log" "$core" -c "$cfg"
        else lt_write_rh_server "$cfg" "$link" "$payload" "$linkport" "$publicport"; lt_start_bg "$log" "$core" "$cfg"; fi
        if kill -0 "$LT_LAST_PID" 2>/dev/null; then
            cap+="${cap:+,}$key"; printf '  %b├─%b %-9s %bREADY%b        %s\n' "$FR" "$NC" "$(lt_engine_label "$key")" "$G" "$NC" "$(lt_engine_detail "$key")"
        else
            printf '  %b├─%b %-9s %bENGINE FAIL%b  %s\n' "$FR" "$NC" "$(lt_engine_label "$key")" "$R" "$NC" "$(lt_engine_detail "$key")"
        fi
    done
    printf '%s' "$cap" > "$caps_file"
    if ! mt_port_busy "$ENGINE_CTRL_PORT" tcp && lt_start_control_server "$caps_file"; then
        echo -e "  ${FR}├────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${G}✔ Control + TCP/UDP family probes are ready.${NC}"
    else
        echo -e "  ${R}✖ Control port ${ENGINE_CTRL_PORT} could not be opened.${NC}"
    fi
    echo -e "  ${FR}└────────────────────────────────────────────────────────────${NC}"
    if [ "${1:-}" = "--no-wait" ]; then
        echo -e "  ${G}✔ Embedded in Option 1 Full Matrix; responder remains active.${NC}"
        return 0
    fi
    echo -e "\n  ${Y}● On the peer server choose this same option and select KHAREJ / Tester.${NC}"
    echo -ne "  ${DIM}Press Enter after testing is finished to tear everything down...${NC}"; read -r _
}

lt_matrix_row() {
    local label="$1" status="$2" latency="$3" detail="$4" color="$5"
    printf '  %b║%b %-10s %b║%b %b%-11s%b %b║%b %-9s %b║%b %-34s %b║%b\n' "$FR" "$NC" "$label" "$FR" "$NC" "$color" "$status" "$NC" "$FR" "$NC" "$latency" "$FR" "$NC" "$detail" "$FR" "$NC"
}

lt_run_one_engine_test() {
    local key="$1" remote4="$2" remote6="$3" caps="$4" rec engine payload link linkport publicport backendport core remote_link remote_public cfg log lat clientpid echopid
    rec=$(lt_engine_record "$key"); IFS='|' read -r engine payload link linkport publicport backendport <<< "$rec"
    if [[ ",$caps," != *",$key,"* ]]; then LT_STATUS='UNAVAILABLE'; LT_LAT='---'; LT_DETAIL='Responder/core not ready'; return 1; fi
    remote_link="$remote4"; [ "$link" = 6 ] && remote_link="$remote6"
    remote_public="$remote4"; [ "$payload" = 6 ] && remote_public="$remote6"
    if [ -z "$remote_link" ] || [ -z "$remote_public" ]; then LT_STATUS='NO ADDRESS'; LT_LAT='---'; LT_DETAIL="Need IPv${link} link + IPv${payload} service"; return 1; fi
    core=''
    if [ "$engine" = BH ]; then core=$(lt_core_path bh 2>/dev/null || true); else core=$(lt_core_path rathole 2>/dev/null || true); fi
    if [ -z "$core" ]; then LT_STATUS='CORE MISSING'; LT_LAT='---'; LT_DETAIL="Install ${engine} core locally"; return 1; fi
    if ! lt_start_echo_backend "$payload" "$backendport"; then LT_STATUS='LOCAL PORT'; LT_LAT='---'; LT_DETAIL="Backend :${backendport} unavailable"; return 1; fi
    echopid="$LT_ECHO_PID"; cfg="$TMP_DIR/${key}.client.toml"; log="$TMP_DIR/${key}.client.log"
    if [ "$engine" = BH ]; then lt_write_bh_client "$cfg" "$remote_link" "$linkport"; lt_start_bg "$log" "$core" -c "$cfg"
    else lt_write_rh_client "$cfg" "$remote_link" "$linkport" "$payload" "$backendport"; lt_start_bg "$log" "$core" "$cfg"; fi
    clientpid="$LT_LAST_PID"
    if ! kill -0 "$clientpid" 2>/dev/null; then
        kill "$echopid" 2>/dev/null || true; lt_forget_pid "$echopid"; lt_forget_pid "$clientpid"
        LT_STATUS='ENGINE FAIL'; LT_LAT='---'; LT_DETAIL='Client config/core rejected'; return 1
    fi
    if lat=$(lt_wait_roundtrip "$remote_public" "$publicport"); then
        LT_STATUS='PASSED'; LT_LAT="${lat}ms"; LT_DETAIL="$(lt_engine_detail "$key")"
        kill "$clientpid" "$echopid" 2>/dev/null || true; lt_forget_pid "$clientpid"; lt_forget_pid "$echopid"; return 0
    fi
    kill "$clientpid" "$echopid" 2>/dev/null || true; lt_forget_pid "$clientpid"; lt_forget_pid "$echopid"
    LT_STATUS='BLOCKED'; LT_LAT='---'; LT_DETAIL="$(lt_engine_detail "$key")"; return 1
}

lt_run_engine_matrix_tester() {
    local remote4="$1" remote6="$2" caps cap_host key status_color ud4 ud6 ping4 ping6
    [ -z "$remote4" ] || mt_valid_ipv4 "$remote4" || { echo -e "  ${R}✖ Invalid IPv4.${NC}"; return 1; }
    [ -z "$remote6" ] || mt_valid_ipv6 "$remote6" || { echo -e "  ${R}✖ Invalid IPv6.${NC}"; return 1; }
    [ -n "$remote4$remote6" ] || { echo -e "  ${R}✖ Enter at least one peer address.${NC}"; return 1; }

    cap_host="$remote6"; [ -n "$cap_host" ] || cap_host="$remote4"
    caps=$(lt_query_caps "$cap_host")
    if [ -z "$caps" ] && [ -n "$remote4" ] && [ "$cap_host" != "$remote4" ]; then caps=$(lt_query_caps "$remote4"); fi
    if [ -z "$caps" ]; then
        echo -e "\n  ${Y}⚠ BH/RH engine responder control channel is not reachable.${NC}"
        echo -e "  ${DIM}Native protocol results above remain valid; BH/RH real-engine rows are skipped.${NC}"
        return 1
    fi

    echo -e "\n  ${FR}┌─[ REAL BACKHAUL / RATHOLE IPv4 ↔ IPv6 ENGINE MATRIX ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}4→6:${NC} IPv4 payload over IPv6 engine link"
    echo -e "  ${FR}├─${NC} ${W}6→4:${NC} IPv6 payload over IPv4 engine link"
    echo -e "  ${FR}└────────────────────────────────────────────────────────────${NC}\n"
    echo -e "  ${FR}╔════════════╦═════════════╦═══════════╦════════════════════════════════════╗${NC}"
    echo -e "  ${FR}║${NC} ${W}ENGINE     ${NC}${FR}║${NC} ${W}STATUS      ${NC}${FR}║${NC} ${W}LATENCY  ${NC}${FR}║${NC} ${W}PATH / DIAGNOSTIC                  ${NC}${FR}║${NC}"
    echo -e "  ${FR}╠════════════╬═════════════╬═══════════╬════════════════════════════════════╣${NC}"
    for key in BH44 BH46 BH64 BH66 RH44 RH46 RH64 RH66; do
        if lt_run_one_engine_test "$key" "$remote4" "$remote6" "$caps"; then
            status_color="$G"
        else
            case "$LT_STATUS" in BLOCKED|'ENGINE FAIL') status_color="$R";; *) status_color="$Y";; esac
        fi
        lt_matrix_row "$(lt_engine_label "$key")" "$LT_STATUS" "$LT_LAT" "$LT_DETAIL" "$status_color"
    done
    echo -e "  ${FR}╚════════════╩═════════════╩═══════════╩════════════════════════════════════╝${NC}"

    echo -e "\n  ${FR}┌─[ EXTRA NETWORK FAMILY PROBES ]${NC}"
    if [ -n "$remote4" ]; then
        if mt_tcp_probe "$remote4" "$ENGINE_CTRL_PORT"; then echo -e "  ${FR}├─${NC} ${G}✔${NC} ${W}TCP IPv4${NC}   ${C}reachable${NC}"; else echo -e "  ${FR}├─${NC} ${R}✖${NC} ${W}TCP IPv4${NC}   blocked"; fi
        ud4=$(lt_udp_probe "$remote4"); if [[ "$ud4" =~ ^[0-9]+$ ]]; then echo -e "  ${FR}├─${NC} ${G}✔${NC} ${W}UDP IPv4${NC}   ${C}${ud4}ms${NC}"; else echo -e "  ${FR}├─${NC} ${R}✖${NC} ${W}UDP IPv4${NC}   blocked"; fi
        ping4=$(ping -c 2 -W 1 "$remote4" 2>/dev/null | grep -oP 'time=\K[0-9.]+' | head -1); [ -n "$ping4" ] && echo -e "  ${FR}├─${NC} ${G}✔${NC} ${W}ICMP IPv4${NC}  ${C}${ping4}ms${NC}" || echo -e "  ${FR}├─${NC} ${Y}●${NC} ${W}ICMP IPv4${NC}  no reply"
    fi
    if [ -n "$remote6" ]; then
        if mt_tcp_probe "$remote6" "$ENGINE_CTRL_PORT"; then echo -e "  ${FR}├─${NC} ${G}✔${NC} ${W}TCP IPv6${NC}   ${C}reachable${NC}"; else echo -e "  ${FR}├─${NC} ${R}✖${NC} ${W}TCP IPv6${NC}   blocked"; fi
        ud6=$(lt_udp_probe "$remote6"); if [[ "$ud6" =~ ^[0-9]+$ ]]; then echo -e "  ${FR}├─${NC} ${G}✔${NC} ${W}UDP IPv6${NC}   ${C}${ud6}ms${NC}"; else echo -e "  ${FR}├─${NC} ${R}✖${NC} ${W}UDP IPv6${NC}   blocked"; fi
        ping6=$(ping -6 -c 2 -W 1 "$remote6" 2>/dev/null | grep -oP 'time=\K[0-9.]+' | head -1); [ -n "$ping6" ] && echo -e "  ${FR}├─${NC} ${G}✔${NC} ${W}ICMP IPv6${NC}  ${C}${ping6}ms${NC}" || echo -e "  ${FR}├─${NC} ${Y}●${NC} ${W}ICMP IPv6${NC}  no reply"
    fi
    echo -e "  ${FR}└────────────────────────────────────────────────────────────${NC}"
    return 0
}

run_engine_family_matrix() {
    draw_header
    echo -e "\n  ${FR}┌─[ BACKHAUL / RATHOLE IPv4 ↔ IPv6 MATRIX ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}4→6 means IPv4 payload over an IPv6 engine link.${NC}"
    echo -e "  ${FR}├─${NC} ${W}6→4 means IPv6 payload over an IPv4 engine link.${NC}"
    echo -e "  ${FR}└────────────────────────────────────────────────────────────${NC}\n"
    local role remote4 remote6
    while true; do
        echo -ne "  ${C}●${NC} ${W}Role [1: IRAN / Responder | 2: KHAREJ / Tester | q: Back]: ${NC}"; read -r role
        [[ "$role" =~ ^[12qQ]$ ]] && break
    done
    [[ "$role" =~ ^[qQ]$ ]] && return 0
    if [ "$role" = 1 ]; then lt_start_engine_responder; lt_stop_engine_pids; return 0; fi

    echo -ne "  ${C}●${NC} ${W}IRAN / Responder IPv4 [blank if unavailable]: ${NC}"; read -r remote4; remote4="${remote4// /}"
    echo -ne "  ${C}●${NC} ${W}IRAN / Responder IPv6 [blank if unavailable]: ${NC}"; read -r remote6; remote6=$(mt_normalize_host "${remote6// /}")
    lt_run_engine_matrix_tester "$remote4" "$remote6"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read -r _
}
# --- END ENGINE MATRIX ---


run_mtu_discovery() {
    draw_header
    echo -e "\n  ${FR}┌─[ ACCURATE MTU & PACKET-LOSS DISCOVERY ]${NC}"
    echo -ne "  ${C}●${NC} ${W}Target Peer IP Address: ${NC}"; read -r target_ip
    target_ip=$(echo "$target_ip" | tr -d '\r' | tr -d ' ')
    [ -z "$target_ip" ] && return

    echo -e "\n  ${FR}╔══════════╦══════════════╦═════════════╦══════════════╦═════════════════╗${NC}"
    printf "  ${FR}║${NC} ${W}%-8s${NC} ${FR}║${NC} ${W}%-12s${NC} ${FR}║${NC} ${W}%-11s${NC} ${FR}║${NC} ${W}%-12s${NC} ${FR}║${NC} ${W}%-15s${NC} ${FR}║${NC}\n" "MTU SIZE" "PAYLOAD" "PACKET LOSS" "PING (MS)" "STATUS"
    echo -e "  ${FR}╠══════════╬══════════════╬═════════════╬══════════════╬═════════════════╣${NC}"

    # IPv4 overhead = 20 (IP) + 8 (ICMP) = 28; IPv6 overhead = 40 + 8 = 48 and needs ping -6.
    local overhead=28 ping_family=(-4)
    if [[ "$target_ip" == *:* ]]; then overhead=48; ping_family=(-6); fi
    local test_mtus=(1500 1428 1378 1328 1308 1228 1128 1028)
    for mtu in "${test_mtus[@]}"; do
        local payload=$((mtu - overhead))
        local ping_out=$(ping "${ping_family[@]}" -c 4 -W 1 -M do -s "$payload" "$target_ip" 2>&1)
        local loss="100%"
        local avg_ping="---"
        local st_badge="${R}FAILED${NC}"

        if echo "$ping_out" | grep -qE '(^|, )[[:space:]]*0(\.0+)?% packet loss'; then
            loss="0%"
            avg_ping=$(echo "$ping_out" | grep -oP 'time=\K[0-9.]+' | head -1)
            st_badge="${G}PERFECT${NC}"
        elif echo "$ping_out" | grep -q "packet loss"; then
            loss=$(echo "$ping_out" | grep -oP '[0-9]+% packet loss')
            st_badge="${Y}FRAGMENTED${NC}"
        fi

        printf "  ${FR}║${NC} ${Y}%-8s${NC} ${FR}║${NC} ${DIM}%-12s${NC} ${FR}║${NC} ${W}%-11s${NC} ${FR}║${NC} ${C}%-12s${NC} ${FR}║${NC} %b%-15s%b ${FR}║${NC}\n" "$mtu" "$payload" "$loss" "$avg_ping" "$st_badge" "$NC"
    done
    echo -e "  ${FR}╚══════════╩══════════════╩═════════════╩══════════════╩═════════════════╝${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read -r dummy
}

while true; do
    badge=""
    if [ -f "$SECURE_TMP/.linktest_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.linktest_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && mt_update_available "$rv" "$MODULE_VERSION"; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_header
    echo -e "\n  ${FR}┌─[ LINK & PROTOCOL BENCHMARK ACTIONS ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Full Auto-Synced Protocol + BH/RH Matrix & Speedtest${NC}"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Backhaul / Rathole IPv4 ↔ IPv6 Matrix${NC}"
    echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Run Dynamic MTU & Loss Discovery Test${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─[ DIAGNOSTIC UTILITIES ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Run as Listener (Open Temporary Test Ports)${NC}"
    echo -e "  ${FR}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Run as Tester (Check Peer Ports & Filtering)${NC}"
    echo -e "  ${FR}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${W}View Active Listening Ports (OS Socket State)${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${G}OTA Update${NC}${badge}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"

    echo -ne "  ${C}LINKTEST ❯❯ ${NC}"; read -r opt
    case $opt in
        1) run_protocol_matrix_test ;;
        2) run_engine_family_matrix ;;
        3) run_mtu_discovery ;;
        4) 
           draw_header
           echo -ne "\n  ${C}●${NC} ${W}Target ports to open [e.g. 80,443,8443]: ${NC}"; read -r p_in
           p_in=${p_in:-"80,443,2053,2083,8080,8443,9743"}
           for p in $(echo "$p_in" | tr ',' ' '); do
               mt_valid_port "$p" || { echo -e "  ${R}SKIP${NC} '$p' is not a valid port number."; continue; }
               LISTEN_PORT="$p" python3 -c "
import socket, os
port = int(os.environ['LISTEN_PORT'])
try:
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)   # accept IPv4 and IPv6
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('::', port))
except OSError:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)      # host without IPv6
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('0.0.0.0', port))
s.listen(1024)
while True:
    c, _ = s.accept()
    c.close()
" &
               listener_pid=$!; LISTENER_PIDS+=("$listener_pid")
               sleep 0.1
               if ! kill -0 "$listener_pid" 2>/dev/null; then wait "$listener_pid"; echo "Port $p could not be opened." >&2; continue; fi
               echo -e "  ${G}OK${NC} Port $p is now listening."
           done
           echo -ne "\n  ${Y}Press Enter to stop listeners...${NC}"; read -r dummy
           for listener_pid in "${LISTENER_PIDS[@]}"; do kill "$listener_pid" 2>/dev/null || true; done
           LISTENER_PIDS=() ;;
        5) 
           draw_header
           echo -ne "\n  ${C}●${NC} ${W}Target Peer IP: ${NC}"; read -r r_p
           echo -ne "  ${C}●${NC} ${W}Test Ports [e.g. 80,443,8443]: ${NC}"; read -r p_in
           p_in=${p_in:-"80,443,2053,2083,8080,8443,9743"}
           echo ""
           for p in $(echo "$p_in" | tr ',' ' '); do
               if mt_tcp_probe "$r_p" "$p"; then
                   echo -e "  ${G}✔ OPEN${NC}    Port $p on $r_p is reachable."
               else
                   echo -e "  ${R}✘ BLOCKED${NC} Port $p on $r_p is filtered/closed."
               fi
           done
           echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read -r dummy ;;
        6)
           draw_header
           echo -e "\n  ${FR}┌─[ SYSTEM LISTENING PORTS ]${NC}"
           ss -lntp 2>/dev/null | awk 'NR>1 {split($5, a, ":"); port = a[length(a)]; proc = $0; gsub(/.*users:\(\("/, "", proc); gsub(/".*/, "", proc); if (port != "") printf "  %-7s %-47s\n", port, proc;}' || true
           echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read -r dummy ;;
        7) self_update_module ;;
        0) break ;;
    esac
done
exit 0
fi
