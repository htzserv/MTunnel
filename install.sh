#!/bin/bash
# MTunnel standalone installer: local source tree or HTTPS bootstrap (v1.6.0).
MODULE_VERSION="1.6.0"
[ -n "${BASH_VERSION:-}" ] || { echo 'Run this installer with bash: sudo bash install.sh' >&2; exit 1; }
umask 077
DEFAULT_REMOTE="${MTUNNEL_REPO_URL:-${MTUNNEL_GITHUB_BASE:-https://raw.githubusercontent.com/htzserv/MTunnel/main}}"
MIRROR_REMOTE="${MTUNNEL_MIRROR_BASE:-https://c107328.parspack.net/c107328/MTunnel}"

# Printed before the shared core is fetched, so --help works offline.
installer_usage() {
    echo 'Usage: sudo bash install.sh [--local DIR] [--remote HTTPS_BASE | --online] [--no-launch]'
    echo 'Without options: use adjacent scripts, or download from the official GitHub source.'
    echo '  --online             Force online install from the official GitHub source.'
    echo '  --remote URL         Use a custom HTTPS repository base instead of the official source.'
    echo '  --with-cores         Also install the tunnel engines (bh, rathole, paqet, gost, haproxy, realm).'
    echo '  --with-prereqs       Also install the APT prerequisites (Debian/Ubuntu only).'
    echo '  --scripts-only       Install only the scripts, not the tunnel modules.'
    echo '  --allow-downgrade    Compatibility alias; downgrades are always permitted.'
    echo '  --root DIR           Test-install under DIR without touching the live root.'
    echo '  --uninstall          Remove MTunnel completely (asks for confirmation).'
    echo ''
    echo 'Version switching is unrestricted: upgrade or downgrade directly from any compatible bundle.'
    echo 'Local install example:'
    echo '  sudo bash install.sh --local .'
    echo 'Online one-line example:'
    echo "  curl -fsSL ${MTUNNEL_GITHUB_BASE:-$DEFAULT_REMOTE}/install.sh | sudo bash -s -- --online"
}
for _a in "$@"; do case "$_a" in -h|--help) installer_usage; exit 0;; esac; done; unset _a

# MTUNNEL_COMMON_LOADER -- installer bootstrap (also supports curl | bash --online).
# Installers cannot assume a shared core has been installed yet, so fetch it
# from the same selected source, or use a bundled local core when available.
mt_installer_load_common() {
    local script_dir='' source_dir='' remote='' mode='' arg candidate tmp rc
    local -a args=("$@")
    # When piped (curl | bash) BASH_SOURCE[0] is not a file: there is no "adjacent"
    # directory, and the current directory must never be trusted as a source.
    if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    fi
    for ((arg=0; arg<${#args[@]}; arg++)); do
        case "${args[$arg]}" in
            --local)
                ((arg+1 < ${#args[@]})) || { echo '--local needs a directory.' >&2; return 1; }
                source_dir="${args[$((arg+1))]}"; mode=local; ((arg+=1));;
            --remote)
                ((arg+1 < ${#args[@]})) || { echo '--remote needs an HTTPS base URL.' >&2; return 1; }
                remote="${args[$((arg+1))]}"; mode=remote; ((arg+=1));;
            --online) remote="$DEFAULT_REMOTE"; mode=remote;;
        esac
    done
    if [[ "$mode" == local ]]; then
        candidate="${source_dir%/}/core/common.sh"
        [[ -f "$candidate" && -r "$candidate" ]] || { echo "Missing local shared core: $candidate" >&2; return 1; }
        # A newer installer must run its own matching helper API while staging
        # an older target bundle. The target core is separately validated.
        if [[ -n "$script_dir" && -f "$script_dir/core/common.sh" ]] &&
           grep -Fqx "MTUNNEL_RELEASE_VERSION=\"${MODULE_VERSION}\"" "$script_dir/core/common.sh"; then
            candidate="$script_dir/core/common.sh"
        fi
    elif [[ "$mode" == remote && -n "$script_dir" && -f "$script_dir/core/common.sh" ]] &&
         grep -Fqx "MTUNNEL_RELEASE_VERSION=\"${MODULE_VERSION}\"" "$script_dir/core/common.sh"; then
        candidate="$script_dir/core/common.sh"
    elif [[ "$mode" != remote && -n "$script_dir" && -f "$script_dir/core/common.sh" ]]; then
        candidate="$script_dir/core/common.sh"
    else
        # A curl/process-substitution bootstrap must not borrow an older installed
        # common.sh: installer helper functions may have changed within the same API.
        # Fetch the core from the same source as this installer instead.
        if [[ "$mode" != remote ]]; then remote="$DEFAULT_REMOTE"; fi
        [[ "$remote" == https://* ]] || { echo 'Shared core download requires HTTPS.' >&2; return 1; }
        tmp=$(mktemp "${TMPDIR:-/tmp}/mtunnel-core.XXXXXXXX") || return 1
        MT_INSTALLER_BOOTSTRAP_TEMP="$tmp"
        rc=1
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 --retry 2 -o "$tmp" "${remote%/}/core/common.sh?t=$(date +%s)" && rc=0
        elif command -v wget >/dev/null 2>&1; then
            wget -q --https-only --timeout=30 --tries=2 -O "$tmp" "${remote%/}/core/common.sh?t=$(date +%s)" && rc=0
        fi
        [[ "$rc" == 0 && -s "$tmp" ]] || { echo 'Unable to fetch the shared MTunnel core.' >&2; rm -f "$tmp"; return 1; }
        candidate="$tmp"
    fi
    if ! bash -n "$candidate" 2>/dev/null; then
        echo "Shared core has a syntax error (bad or incomplete download): $candidate" >&2
        [[ -z "${MT_INSTALLER_BOOTSTRAP_TEMP:-}" ]] || rm -f "$MT_INSTALLER_BOOTSTRAP_TEMP"
        unset MT_INSTALLER_BOOTSTRAP_TEMP
        return 1
    fi
    # shellcheck source=core/common.sh
    if ! source "$candidate"; then
        echo "Shared core failed to load: $candidate" >&2
        [[ -z "${MT_INSTALLER_BOOTSTRAP_TEMP:-}" ]] || rm -f "$MT_INSTALLER_BOOTSTRAP_TEMP"
        unset MT_INSTALLER_BOOTSTRAP_TEMP
        return 1
    fi
    if [[ "${MTUNNEL_CORE_API:-}" != 1 || "${MTUNNEL_LAYOUT_REV:-}" != 2 ]]; then
        echo "Incompatible shared core: $candidate" >&2
        [[ -z "${MT_INSTALLER_BOOTSTRAP_TEMP:-}" ]] || rm -f "$MT_INSTALLER_BOOTSTRAP_TEMP"
        unset MT_INSTALLER_BOOTSTRAP_TEMP
        return 1
    fi
    [[ -z "${MT_INSTALLER_BOOTSTRAP_TEMP:-}" ]] || rm -f "$MT_INSTALLER_BOOTSTRAP_TEMP"
    unset MT_INSTALLER_BOOTSTRAP_TEMP
}
mt_installer_load_common "$@" || exit 1
unset -f mt_installer_load_common
DEFAULT_REMOTE="${MTUNNEL_REPO_URL:-${MTUNNEL_GITHUB_BASE:-$DEFAULT_REMOTE}}"


# Cache-buster for raw.githubusercontent.com and mirrors (they cache by full URL).
# Defined only when the loaded shared core does not already provide it.
if ! declare -F mt_cb_url >/dev/null 2>&1; then
mt_cb_url() {
    local url="${1:-}"
    [[ "$url" == *\?* ]] && { printf '%s' "$url"; return 0; }
    printf '%s?t=%s' "$url" "$(date +%s 2>/dev/null || echo 0)"
}
fi

# Helpers this installer calls from the shared core. A core that lacks one stops here with a
# clear message instead of "command not found" half way through an install.
installer_require_core_api() {
    local fn missing=''
    for fn in mt_validate_script mt_validate_module_role mt_validate_module_core_contract \
              mt_install_files mt_valid_elf mt_owned_binary_register mt_owned_binary_remove \
              mt_delete_tagged_rules; do
        declare -F "$fn" >/dev/null 2>&1 || missing+=" $fn"
    done
    [ -z "$missing" ] && return 0
    echo "The loaded shared core is too old; missing:$missing" >&2
    echo 'Use --online (or --remote URL) so the matching core is downloaded.' >&2
    return 1
}

B='\033[1;37m'; G='\033[1;32m'; LG='\033[0;92m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
FR='\033[1;33m'

# Bounded HTTPS download for interactive installer operations.  The shared
# mt_download helper can take several minutes *per file* on a bad connection.
# A failed transfer does not replace an already-staged file.
INSTALLER_FETCH_ERR=''
installer_fetch() {
    local url="$1" dest="$2" label="${3:-${1##*/}}" quiet="${4:-0}" tmp rc=1 err=''
    local max_time="${MT_INSTALL_FETCH_TIMEOUT:-90}" conn_time="${MT_INSTALL_CONNECT_TIMEOUT:-8}"
    [[ "$max_time" =~ ^[0-9]+$ ]] && ((max_time >= 5 && max_time <= 300)) || max_time=90
    [[ "$conn_time" =~ ^[0-9]+$ ]] && ((conn_time >= 2 && conn_time <= 40)) || conn_time=8
    INSTALLER_FETCH_ERR=''
    [[ "$url" == https://* ]] || { printf '  Download requires HTTPS: %s\n' "$label" >&2; INSTALLER_FETCH_ERR='not https'; return 1; }
    tmp=$(mktemp "${dest}.download.XXXXXX") || return 1
    [ "$quiet" = 1 ] || printf '  %b⟳%b %b%s%b\n' "$C" "$NC" "$W" "$label" "$NC" >&2
    if command -v curl >/dev/null 2>&1; then
        err=$(curl -fLsS --proto '=https' --proto-redir '=https' \
            --connect-timeout "$conn_time" --max-time "$max_time" \
            --retry 1 --retry-delay 1 -o "$tmp" "$url" 2>&1) && rc=0
    elif command -v wget >/dev/null 2>&1; then
        err=$(wget -q --https-only --timeout="$conn_time" --tries=2 -O "$tmp" "$url" 2>&1) && rc=0
    else
        err='neither curl nor wget is installed'
    fi
    if [ "$rc" = 0 ] && [ -s "$tmp" ] && mv -f -- "$tmp" "$dest"; then
        [ "$quiet" = 1 ] || printf '  %b✓%b %b%s%b\n' "$G" "$NC" "$W" "$label" "$NC" >&2
        return 0
    fi
    rm -f -- "$tmp"
    err="${err//$'\n'/ }"; INSTALLER_FETCH_ERR="${err:0:120}"
    if [ "$quiet" != 1 ]; then
        printf '  %b✖%b %b%s%b %b— %s%b\n' "$R" "$NC" "$W" "$label" "$NC" "$DIM" "${INSTALLER_FETCH_ERR:-unavailable or download timed out}" "$NC" >&2
    fi
    return 1
}

# One compact row per install phase. The same row is redrawn from 0% to 100%;
# item-level details are intentionally reserved for the final report.
draw_stage_progress() {
    local n="$1" total="$2" text="$3" state="${4:-run}" suffix="${5:-}" width=26
    [[ "$total" =~ ^[0-9]+$ ]] && [ "$total" -gt 0 ] || total=1
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    local percent=$(( n * 100 / total )) filled empty bar empty_bar icon icon_col
    ((percent > 100)) && percent=100
    filled=$(( percent * width / 100 )); empty=$(( width - filled ))
    bar=$(printf "%${filled}s" "" | tr ' ' '#')
    empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')

    if [ "$state" = fail ]; then
        icon='✖'; icon_col="$R"
    elif [ "$percent" -ge 100 ]; then
        icon='✓'; icon_col="$G"
    else
        icon='●'; icon_col="$Y"
    fi

    tput civis 2>/dev/null || true
    printf "\r\033[K  %b%s%b %b%-16.16s%b %b[%b%s%b%s%b] %b%3d%%%b %b%s%b" \
        "$icon_col" "$icon" "$NC" \
        "$W" "$text" "$NC" \
        "$W" "$W" "$bar" "$DIM" "$empty_bar" "$NC" \
        "$W" "$percent" "$NC" "$DIM" "$suffix" "$NC"
    tput cnorm 2>/dev/null || true
}

installer_script_version() {
    sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$1" 2>/dev/null | head -n1
}

installer_pkg_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

installer_file_build_tag() {
    local f="$1" h=''
    [ -f "$f" ] || return 0
    h=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
    [ -z "$h" ] || printf 'sha:%s' "${h:0:12}"
}

installer_print_report_group() {
    local title="$1"; shift
    local row name ver status icon col ver_text
    [ "$#" -gt 0 ] || return 0
    printf '\n  %b%s%b\n' "$Y" "$title" "$NC"
    for row in "$@"; do
        IFS='|' read -r name ver status <<< "$row"
        icon='✓'; col="$G"
        [[ "$status" == skipped* ]] && { icon='↷'; col="$Y"; }
        [[ "$status" == failed* ]] && { icon='✖'; col="$R"; }
        ver_text=''
        if [ -n "$ver" ] && [ "$ver" != Unknown ]; then
            case "$ver" in sha:*) ver_text="(${ver})";; *) ver_text="(v${ver})";; esac
        fi
        printf '    %b%s%b %b%-16.16s%b %b%-20.20s%b %b— %s%b\n' \
            "$col" "$icon" "$NC" "$W" "$name" "$NC" "$Y" "$ver_text" "$NC" "$DIM" "$status" "$NC"
    done
}

installer_print_report() {
    printf '\n  %b════════════════ INSTALLATION REPORT ════════════════%b\n' "$FR" "$NC"
    installer_print_report_group 'Scripts' "${INSTALL_REPORT_SCRIPTS[@]}"
    installer_print_report_group 'Tunnel engines' "${INSTALL_REPORT_ENGINES[@]}"
    installer_print_report_group 'Prerequisites' "${INSTALL_REPORT_PREREQS[@]}"
    if [ "${#INSTALLER_NOTES[@]}" -gt 0 ]; then
        local note
        printf '\n  %bNotes%b\n' "$Y" "$NC"
        for note in "${INSTALLER_NOTES[@]}"; do printf '    %b- %s%b\n' "$DIM" "$note" "$NC"; done
    fi
    printf '\n  %b═════════════════════════════════════════════════════%b\n' "$FR" "$NC"
}

# ---- Installer header: same dashboard facts as the MTunnel main header -------------------------
# IPv4 / IPv6, BBR, Porter, CPU, cores, RAM and network rates, drawn in the same gold double-line
# frame. The tunnel rows are left out: the installer has no tunnels to list yet.
mt_installer_hdr_cleanup() {
    [ -z "${MT_INSTALLER_HDR_TMP:-}" ] || rm -rf -- "$MT_INSTALLER_HDR_TMP" 2>/dev/null
    MT_INSTALLER_HDR_TMP=''
}

# Shown when the loaded shared core is too old to provide the dashboard helpers.
_installer_header_basic() {
    local l1="  MTunnel Installer" l2="  Installer v${MODULE_VERSION}   |   Core v${MTUNNEL_RELEASE_VERSION:-?}"
    local w=62 p1 p2
    p1=$((w-${#l1}-1)); p2=$((w-${#l2}-1)); [ "$p1" -ge 0 ] || p1=0; [ "$p2" -ge 0 ] || p2=0
    echo -e "\n  ${FR}╔$(printf '═%.0s' $(seq 1 $w))╗${NC}"
    printf "  ${FR}║${NC}${W}%s%*s${NC}${FR}║${NC}\n" "$l1" "$p1" ''
    printf "  ${FR}║${NC}${DIM}%s%*s${NC}${FR}║${NC}\n" "$l2" "$p2" ''
    echo -e "  ${FR}╚$(printf '═%.0s' $(seq 1 $w))╝${NC}\n"
}

# One quick CPU sample (the dashboard keeps a running sample; the installer has none yet).
_installer_cpu_pct() {
    local _c u n s i io ir sir st rest i1 t1 i2 t2 d
    read -r _c u n s i io ir sir st rest < /proc/stat 2>/dev/null || { echo 0; return 0; }
    i1=$(( ${i:-0} + ${io:-0} )); t1=$(( ${u:-0} + ${n:-0} + ${s:-0} + ${i:-0} + ${io:-0} + ${ir:-0} + ${sir:-0} + ${st:-0} ))
    sleep 0.2
    read -r _c u n s i io ir sir st rest < /proc/stat 2>/dev/null || { echo 0; return 0; }
    i2=$(( ${i:-0} + ${io:-0} )); t2=$(( ${u:-0} + ${n:-0} + ${s:-0} + ${i:-0} + ${io:-0} + ${ir:-0} + ${sir:-0} + ${st:-0} ))
    d=$(( t2 - t1 ))
    if [ "$d" -gt 0 ]; then d=$(( (d - (i2 - i1)) * 100 / d )); [ "$d" -lt 0 ] && d=0; [ "$d" -gt 100 ] && d=100; echo "$d"; else echo 0; fi
}

draw_installer_header() {
    clear 2>/dev/null || true
    if ! declare -F mt_header_static_read >/dev/null 2>&1 || ! declare -F mt_sys_stats_read >/dev/null 2>&1 ||
       ! declare -F mt_hdr_cols_update >/dev/null 2>&1; then
        _installer_header_basic; return 0
    fi
    local inst_v="${MODULE_VERSION:-?}" core_v="${MTUNNEL_RELEASE_VERSION:-?}" LC_CTYPE=C.UTF-8
    local title="MTunnel Installer v${inst_v}"
    if [ -z "${MT_INSTALLER_HDR_TMP:-}" ] || [ ! -d "$MT_INSTALLER_HDR_TMP" ]; then
        MT_INSTALLER_HDR_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mtunnel-installer-hdr.XXXXXX" 2>/dev/null) || MT_INSTALLER_HDR_TMP=''
    fi
    local SECURE_TMP="${MT_INSTALLER_HDR_TMP:-/root/mtunnel/tmp}" HEADER_LIVE=''
    mt_header_static_read force 2>/dev/null || true
    mt_sys_stats_read 2>/dev/null || true
    local cpu_pct; cpu_pct=$(_installer_cpu_pct); [[ "$cpu_pct" =~ ^[0-9]+$ ]] || cpu_pct=0
    local s_ip="${MT_STATIC_IP4:-Unknown}" s_v6="${MT_STATIC_IP6:-}" bbr_cc="${MT_STATIC_BBR:-}"
    s_ip="${s_ip:0:16}"
    local bbr_col="$DIM" bbr_icon="○" bbr_text="OFF"
    [ "$bbr_cc" = bbr ] && { bbr_col="$G"; bbr_icon="●"; bbr_text="ON"; }
    local porter_col="$DIM" porter_icon="○" porter_text="OFF"
    [ "${MT_STATIC_PORTER:-OFF}" = ON ] && { porter_col="$G"; porter_icon="●"; porter_text="ON"; }
    local cpu_col="$G" ram_col="$G" rx_col="$DIM" tx_col="$DIM" cores="${MT_CPU_CORES:-1}" core_label
    local ram_pct="${MT_RAM_PCT:-0}" rx="${MT_RX:-0 B/s}" tx="${MT_TX:-0 B/s}"
    core_label="${cores} Cores"; [ "$cores" = 1 ] && core_label="1 Core"
    [ "$cpu_pct" -gt 60 ] 2>/dev/null && cpu_col="$Y"; [ "$cpu_pct" -gt 85 ] 2>/dev/null && cpu_col="$R"
    [ "$ram_pct" -gt 70 ] 2>/dev/null && ram_col="$Y"; [ "$ram_pct" -gt 88 ] 2>/dev/null && ram_col="$R"
    [[ "$rx" != "0 B/s" && -n "$rx" ]] && rx_col="$G"
    [[ "$tx" != "0 B/s" && -n "$tx" ]] && tx_col="$Y"
    local cpu_str="${cpu_pct}%" ram_str="${MT_RAM_USED:-0G}/${MT_RAM_TOTAL:-0G} [${ram_pct}%]"
    local ver_line="Installer v${inst_v}   |   Core v${core_v}"

    local term_cols boxw content_w border
    mt_hdr_cols_update 2>/dev/null || true; term_cols="${MT_HDR_COLS:-120}"
    [[ "$term_cols" =~ ^[0-9]+$ ]] || term_cols=120

    if [ "$term_cols" -lt 124 ]; then
        # Compact stacked layout for narrow terminals (same facts, one per line group).
        local v6_txt="OFF"; [ -z "$s_v6" ] || v6_txt="$s_v6"
        boxw=$((term_cols - 4)); [ "$boxw" -lt 32 ] && boxw=32; [ "$boxw" -gt 78 ] && boxw=78
        content_w=$((boxw - 2))
        printf -v border '%*s' "$content_w" ''; border="${border// /═}"
        _inst_hdr_line() {
            local t="$1" w=$((content_w-2)) LC_CTYPE=C.UTF-8
            (( ${#t} > w )) && t="${t:0:w}"
            printf "  ${FR}║${NC} %s%*s ${FR}║${NC}\033[K\n" "$t" "$((w-${#t}))" ''
        }
        printf '\033[K\n  %b╔%s╗%b\033[K\n' "$FR" "$border" "$NC"
        _inst_hdr_line "${title} | ${s_ip}"
        _inst_hdr_line "IPv6 ${v6_txt}"
        _inst_hdr_line "CPU ${cpu_str} (${core_label}) | RAM ${ram_str}"
        _inst_hdr_line "BBR ${bbr_text} | Porter ${porter_text}"
        _inst_hdr_line "Net ▼ ${rx} | Net ▲ ${tx}"
        printf '  %b╠%s╣%b\033[K\n' "$FR" "$border" "$NC"
        _inst_hdr_line "$ver_line"
        printf '  %b╚%s╝%b\033[K\n\n' "$FR" "$border" "$NC"
        unset -f _inst_hdr_line
        return 0
    fi

    # Wide dashboard: identical column layout and sizing rules as the main header.
    local total extra v6_col v6_text v6_need need_total w6 w4 v6_field
    if [ -n "$s_v6" ]; then v6_col="$M"; v6_text="$s_v6"; v6_need=$(( ${#s_v6} + 10 ))
    else v6_col="$DIM"; v6_text="OFF"; v6_need=21; fi
    (( v6_need < 21 )) && v6_need=21
    need_total=$(( 31 + 25 + v6_need + 29 + 3 ))
    (( need_total < 117 )) && need_total=117
    total=$(( term_cols - 4 )); (( total > 150 )) && total=150
    (( total > need_total )) && total=$need_total
    (( total < 117 )) && total=117
    w6=$v6_need
    (( w6 > total - 31 - 25 - 29 - 3 )) && w6=$(( total - 31 - 25 - 29 - 3 ))
    w4=$(( total - 31 - 25 - w6 - 3 ))
    v6_field=$(( w6 - 10 ))
    printf -v border '%*s' "$total" ''; border="${border// /═}"

    printf '\033[K\n  %b╔%s╗%b\033[K\n' "$FR" "$border" "$NC"
    printf "  ${FR}║${NC} ${W}%-29.29s${NC} ${FR}║${NC} ${C}◆${NC} ${DIM}IPv4${NC}  ${M}%-15.15s${NC} ${FR}║${NC} ${M}◆${NC} ${DIM}IPv6${NC}  %b%-*.*s%b ${FR}║${NC} ${DIM}BBR:${NC} %b%s%b %-3.3s  ${DIM}Porter:${NC} %b%s%b %-*.*s ${FR}║${NC}\033[K\n" \
        "$title" "$s_ip" \
        "$v6_col" "$v6_field" "$v6_field" "$v6_text" "$NC" \
        "$bbr_col" "$bbr_icon" "$NC" "$bbr_text" \
        "$porter_col" "$porter_icon" "$NC" "$((w4-24))" "$((w4-24))" "$porter_text"
    printf '  %b╠%s╣%b\033[K\n' "$FR" "$border" "$NC"
    printf "  ${FR}║${NC} ${DIM}CPU:${NC} %b%-4.4s%b   ${DIM}Cores:${NC} ${W}%-10.10s${NC} ${FR}║${NC} ${DIM}RAM:${NC} %b%-18.18s%b ${FR}║${NC} ${DIM}Net ▼:${NC} %b%-*.*s%b ${FR}║${NC} ${DIM}Net ▲:${NC} %b%-*.*s%b ${FR}║${NC}\033[K\n" \
        "$cpu_col" "$cpu_str" "$NC" "$core_label" \
        "$ram_col" "$ram_str" "$NC" \
        "$rx_col" "$((w6-9))" "$((w6-9))" "$rx" "$NC" \
        "$tx_col" "$((w4-9))" "$((w4-9))" "$tx" "$NC"
    printf '  %b╠%s╣%b\033[K\n' "$FR" "$border" "$NC"
    printf "  ${FR}║${NC} ${DIM}%-*.*s${NC} ${FR}║${NC}\033[K\n" "$((total-2))" "$((total-2))" "$ver_line"
    printf '  %b╚%s╝%b\033[K\n\n' "$FR" "$border" "$NC"
}

mt_validate_shared_core() {
    local file="$1"
    [ -s "$file" ] && bash -n "$file" 2>/dev/null && grep -q '^MTUNNEL_CORE_API=1$' "$file" && grep -q '^MTUNNEL_LAYOUT_REV=2$' "$file" && grep -q '^MTUNNEL_RELEASE_VERSION="[0-9][0-9.]*"$' "$file"
}
# Retire components that were folded into core/common.sh (or removed on purpose).
# Nothing is deleted before a copy is stored under /root/mtunnel/backup, and any
# cron/systemd entry that still points at a retired tool is reported, not edited.
mt_installer_retire_legacy() {
    local f stamp backup_dir found=0 failed=0 refs=''
    local -a legacy=(/etc/mweb /etc/systemd/system/mweb.service /usr/bin/mweb /root/mtunnel/tools/mweb.sh
        /usr/bin/mbbr /usr/bin/mhealer /usr/bin/minterface
        /root/mtunnel/tools/mbbr.sh /root/mtunnel/tools/mhealer.sh /root/mtunnel/tools/minterface.sh)
    for f in "${legacy[@]}"; do
        if [ -e "$f" ] || [ -L "$f" ]; then found=1; break; fi
    done
    [ "$found" == 1 ] || return 0
    stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
    backup_dir="/root/mtunnel/backup/legacy-$stamp"
    mkdir -p "$backup_dir" && chmod 700 "$backup_dir" || {
        echo -e "  ${Y}● Cannot create $backup_dir; legacy files were left untouched.${NC}" >&2; return 0; }
    for f in "${legacy[@]}"; do
        if [ -e "$f" ] || [ -L "$f" ]; then cp -a --parents "$f" "$backup_dir" 2>/dev/null || failed=1; fi
    done
    if [ "$failed" == 1 ]; then
        echo -e "  ${Y}● Backup of legacy files failed; they were left untouched.${NC}" >&2; return 0
    fi
    systemctl disable --now mweb.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/mweb.service /usr/bin/mweb /root/mtunnel/tools/mweb.sh
    rm -rf /etc/mweb
    rm -f /usr/bin/mbbr /usr/bin/mhealer /usr/bin/minterface /root/mtunnel/tools/mbbr.sh /root/mtunnel/tools/mhealer.sh /root/mtunnel/tools/minterface.sh
    rmdir /root/mtunnel/tools 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo -e "  ${DIM}● Retired legacy mweb web panel and standalone mbbr/mhealer/minterface scripts (now part of the shared core).${NC}"
    echo -e "  ${DIM}  A copy was stored in ${backup_dir}.${NC}"
    refs=$(grep -rlE '/usr/bin/(mweb|mbbr|mhealer|minterface)\b' /etc/cron.d /etc/cron.daily /etc/cron.hourly /var/spool/cron /etc/systemd/system 2>/dev/null | head -n 5)
    if [ -n "$refs" ]; then
        echo -e "  ${Y}● These files still reference a retired tool; please review them:${NC}"
        while IFS= read -r f; do echo -e "    ${Y}-${NC} $f"; done <<< "$refs"
    fi
    return 0
}
# ---- Interactive menu (shown when started with no source flags) ------------------------------
# One number does everything:
#   1-3  official GitHub : full package / scripts + tunnels + engines / scripts only
#   4-6  Iranian mirror  : full package / scripts + tunnels + engines / scripts only
#   7    uninstall MTunnel from this system          0  quit
# One menu entry (name only, one per line).
_wiz_item() {
    case "$1" in
        1|4) echo -e "    ${Y}[$1]${NC} ${W}Full package${NC}";;
        2|5) echo -e "    ${Y}[$1]${NC} ${W}Scripts + tunnels + engines${NC}";;
        3|6) echo -e "    ${Y}[$1]${NC} ${W}Scripts only${NC}";;
        7)   echo -e "    ${Y}[7]${NC} ${W}Uninstall${NC}";;
    esac
}
installer_wizard() {
    local key pkg src
    WIZ_UNINSTALL=0
    while true; do
        draw_installer_header
        local n
        echo -e "  ${Y}OFFICIAL GITHUB${NC}"
        for n in 1 2 3; do _wiz_item "$n"; done
        echo -e "\n  ${Y}IRANIAN MIRROR${NC}"
        for n in 4 5 6; do _wiz_item "$n"; done
        echo -e "\n  ${Y}REMOVE${NC}"
        _wiz_item 7
        echo -e "\n  ${FR}════════════════════════════════════════════════════════════${NC}"
        echo -e "    ${Y}[0]${NC} ${W}Quit${NC}\n"
        printf "  ${Y}❯❯ ${NC}${W}"
        IFS= read -r key </dev/tty || { printf '%b' "$NC"; return 1; }
        printf '%b' "$NC"
        key="${key//[$' \r\t']/}"
        case "${key,,}" in
            1|2|3|4|5|6)
                if [ "$key" -le 3 ]; then src=github; pkg="$key"; else src=mirror; pkg=$((key-3)); fi
                case "$pkg" in
                    1) WIZ_CORES=1; WIZ_SCRIPTS_ONLY=0; WIZ_PREREQS=1;;
                    2) WIZ_CORES=1; WIZ_SCRIPTS_ONLY=0; WIZ_PREREQS=0;;
                    3) WIZ_CORES=0; WIZ_SCRIPTS_ONLY=1; WIZ_PREREQS=0;;
                esac
                if [ "$src" == mirror ]; then WIZ_REMOTE="$MIRROR_REMOTE"; else WIZ_REMOTE="$DEFAULT_REMOTE"; fi
                return 0;;
            7) WIZ_UNINSTALL=1; return 0;;
            0|q) return 1;;
        esac
    done
}

# Complete removal (same steps as "Nuclear Wipe" in the main menu), confirmed by typing WIPE-MTUNNEL.
installer_uninstall() {
    local del_confirm cron_tmp bin table chain tag core_bin
    draw_installer_header
    echo -e "  ${Y}⚠ This stops and removes all tunnels, services, MTunnel tunnel cores${NC}"
    echo -e "  ${Y}  and MTunnel-owned configs from this system!${NC}\n"
    printf "  ${Y}Type WIPE-MTUNNEL to continue (anything else cancels): ${W}"
    IFS= read -r del_confirm </dev/tty || { printf '%b\n' "$NC"; return 1; }
    printf '%b' "$NC"
    del_confirm="${del_confirm//[$' \r\n']/}"
    if [ "$del_confirm" != "WIPE-MTUNNEL" ]; then
        echo -e "\n  ${Y}● Uninstall cancelled.${NC}\n"; return 1
    fi
    echo -e "\n  ${Y}● Terminating services and wiping files...${NC}"
    systemctl stop mtunnel-smart-watchdog.timer mtunnel-smart-agent.service mgre-watchdog.timer mxlan-watchdog.timer mporter-watchdog.service 2>/dev/null || true
    /usr/bin/mgre --teardown-all 2>/dev/null || true
    /usr/bin/mxlan --teardown-all 2>/dev/null || true
    if command -v iptables >/dev/null 2>&1; then
        while iptables -D INPUT -p tcp --dport 29876 -m comment --comment MTUNNEL_SMART_AGENT -j ACCEPT 2>/dev/null; do :; done
    fi
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        for table in filter nat mangle raw; do
            for chain in INPUT OUTPUT FORWARD PREROUTING POSTROUTING; do
                for tag in MGRE_ MXLAN_ MPORTER_ MBH_ RAT_ MPAQET_ OBFS_CNT_; do mt_delete_tagged_rules "$bin" "$table" "$chain" "$tag" prefix; done
            done
        done
        for chain in MGRE_GUARD MGRE6_GUARD MXLAN_GUARD MXLAN6_GUARD; do
            "$bin" -F "$chain" 2>/dev/null; "$bin" -X "$chain" 2>/dev/null
        done
    done
    if command -v crontab >/dev/null 2>&1; then
        cron_tmp=$(mktemp "${TMPDIR:-/tmp}/uninstall-cron.XXXXXX") && {
            crontab -l 2>/dev/null | awk '!/mbackhaul@|mrathole@|mpaqet@|\/usr\/bin\/mgre|\/usr\/bin\/mxlan|\/usr\/local\/bin\/mporter-watchdog/' > "$cron_tmp"
            crontab "$cron_tmp"; rm -f "$cron_tmp"
        }
    fi
    systemctl stop mtunnel-smart-watchdog.timer mtunnel-smart-agent.service mgre-watchdog.timer mxlan-watchdog.timer mbackhaul-apply.service mrathole-apply.service mpaqet-apply.service mporter-iptables.service mporter-obfs.service 2>/dev/null || true
    systemctl disable mtunnel-smart-watchdog.timer mtunnel-smart-agent.service mgre-watchdog.timer mxlan-watchdog.timer mbackhaul-apply.service mrathole-apply.service mpaqet-apply.service mporter-iptables.service mporter-obfs.service 2>/dev/null || true
    rm -f /etc/systemd/system/mtunnel-smart-agent.service /etc/systemd/system/mtunnel-smart-watchdog.{service,timer} /etc/systemd/system/mgre-watchdog.{service,timer} /etc/systemd/system/mxlan-watchdog.{service,timer} /etc/systemd/system/{mbackhaul,mrathole,mpaqet}-apply.service /etc/systemd/system/mporter-{iptables,obfs}.service
    rm -f /usr/local/bin/mhealer_daemon.sh /usr/local/bin/mporter-{watchdog,iptables,obfs}.sh /etc/mhealer.conf
    rm -f /var/lock/mporter-state.lock /run/mporter-backends.tsv
    # Generic Gost/Realm installations may belong to another project: remove only when MPorter marked ownership.
    if [ -f /etc/mporter/.owns_gost ]; then systemctl disable --now gost.service 2>/dev/null || true; rm -f /etc/systemd/system/gost.service /usr/local/bin/gost; rm -rf /etc/gost; fi
    if [ -f /etc/mporter/.owns_realm ]; then systemctl disable --now realm.service 2>/dev/null || true; rm -f /etc/systemd/system/realm.service /usr/local/bin/realm; rm -rf /etc/realm; fi
    # HAProxy is removed only when MPorter installed it itself (ownership marker); must run before /etc/mporter is deleted.
    if [ -f /etc/mporter/.owns_haproxy ]; then
        systemctl disable --now haproxy.service 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get purge -y haproxy >/dev/null 2>&1 || true
        rm -rf /etc/haproxy /var/lib/haproxy
    fi
    rm -rf /run/mtunnel-healer
    systemctl stop mgre.service mxlan.service mporter.service mporter-watchdog.service 'mbackhaul@*' 'mrathole@*' 'mpaqet@*' 2>/dev/null || true
    systemctl disable mgre.service mxlan.service mporter.service mporter-watchdog.service 'mbackhaul@*' 'mrathole@*' 'mpaqet@*' 2>/dev/null || true
    rm -f /etc/systemd/system/mgre.service /etc/systemd/system/mxlan.service /etc/systemd/system/mporter.service \
          /etc/systemd/system/mporter-watchdog.service /etc/systemd/system/mbackhaul@.service \
          /etc/systemd/system/mrathole@.service /etc/systemd/system/mpaqet@.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    # Only delete MTunnel-provisioned cores whose stored hash still matches.
    for core_bin in bh rathole paqet; do
        mt_owned_binary_remove "$core_bin" "/usr/local/bin/$core_bin" "/usr/bin/$core_bin" || true
    done
    rm -rf /var/lib/mtunnel/owned-binaries /usr/lib/mtunnel /etc/mgre /etc/mporter /etc/mrathole /etc/mbackhaul /etc/paqet /etc/mtunnel/smart /root/mtunnel 2>/dev/null || true
    rm -f /usr/bin/mtunnel /usr/bin/msmart /usr/bin/mgre /usr/bin/mxlan /usr/bin/mbackhaul /usr/bin/mpaqet /usr/bin/mporter /usr/bin/mrathole /usr/bin/mdoctor /usr/bin/linktest /usr/bin/mmirror
    # MTunnel-owned persistent sysctl drop-ins (live kernel values are left untouched until the next reload/reboot).
    rm -f /etc/sysctl.d/99-mtunnel-doctor.conf /etc/sysctl.d/99-mtunnel-bbr.conf /etc/sysctl.d/99-mporter-ipv4.conf /etc/sysctl.d/99-mporter-ipv6.conf
    rm -f /usr/local/bin/mtunnel
    echo -e "\n  ${Y}✓ MTunnel was completely removed from this system.${NC}\n"
    return 0
}

# Validate the manifest as data; no filename-only or unsigned fallback.
installer_manifest_hash() {
    local manifest="$1" wanted="$2" line hash name result=''
    [ -f "$manifest" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"; line="${line#$'\xEF\xBB\xBF'}"
        [[ "$line" =~ ^[[:space:]]*($|#) ]] && continue
        [[ "$line" =~ ^([0-9a-fA-F]{64})[[:space:]]+\*?([^[:space:]]+)[[:space:]]*$ ]] || return 1
        hash="${BASH_REMATCH[1],,}"; name="${BASH_REMATCH[2]}"
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]] || return 1
        if [ "$name" = "$wanted" ]; then
            [ -z "$result" ] || return 1
            result="$hash"
        fi
    done < "$manifest"
    [ -n "$result" ] || return 1
    printf '%s' "$result"
}
installer_verify_package() {
    local manifest="$1" file="$2" name="$3" hash
    hash=$(installer_manifest_hash "$manifest" "$name") || { echo "Missing/invalid SHA256 manifest entry: $name" >&2; return 1; }
    [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$hash" ] || { echo "SHA256 mismatch: $name" >&2; return 1; }
}

# Install only tools actually required by MTunnel.  The old Full mode fetched
# *every* .deb from the 244-entry manifest (including mutually incompatible
# Ubuntu releases and base libc/systemd packages).  Checking commands before
# APT avoids unneeded downloads or OS upgrades and lets APT resolve deps safely.
INSTALL_REPORT_SCRIPTS=()
INSTALL_REPORT_ENGINES=()
INSTALL_REPORT_PREREQS=()
INSTALLER_NOTES=()
PREREQ_FAILED_LIST=''

# Runs a command in the background under a hard time limit and keeps the progress row alive
# (package name + elapsed seconds), so a slow or locked APT never looks frozen.
# usage: installer_run_live LOG LIMIT_SECS DONE TOTAL LABEL DETAIL command...
installer_run_live() {
    local log="$1" limit="$2" n="$3" total="$4" label="$5" detail="$6" pid start rc
    shift 6
    if command -v timeout >/dev/null 2>&1; then
        set -- timeout --signal=TERM --kill-after=5s "$limit" "$@"
    fi
    DEBIAN_FRONTEND=noninteractive "$@" </dev/null >"$log" 2>&1 &
    pid=$!; start=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        draw_stage_progress "$n" "$total" "$label" run "$detail $((SECONDS-start))s"
        sleep 0.5
    done
    wait "$pid"; rc=$?
    return "$rc"
}

# Keep a copy of an engine binary MTunnel did not put there before it is replaced.
installer_backup_foreign_binary() {
    local root="$1" name="$2" src="$3" dst bdir='' stamp
    [ -f "$root/var/lib/mtunnel/owned-binaries/$name" ] && return 0
    [ -f "$root/etc/mporter/.owns_$name" ] && return 0
    for dst in "$root/usr/local/bin/$name" "$root/usr/bin/$name"; do
        [ -f "$dst" ] && [ ! -L "$dst" ] || continue
        cmp -s "$dst" "$src" 2>/dev/null && continue
        cmp -s "$dst" "$root/root/mtunnel/engines/$name" 2>/dev/null && continue
        if [ -z "$bdir" ]; then
            stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
            bdir="$root/root/mtunnel/backup/engines-$stamp"
            mkdir -p "$bdir" && chmod 700 "$bdir" || return 0
        fi
        if cp -a --parents "$dst" "$bdir" 2>/dev/null; then
            INSTALLER_NOTES+=("Existing $dst was not installed by MTunnel; backed up to $bdir")
        fi
    done
    return 0
}

installer_install_prereqs() {
    local pkg cmd ver state idx=0 apt_log total base i=0 rc update_failed=0 update_err=''
    local -a missing=() failed_pkgs=() packages=(ca-certificates curl wget python3 openssl iperf3 iputils-ping iptables iproute2 util-linux gzip coreutils jq unzip tar procps cron nano)
    local -A checks=(
        [ca-certificates]='cert' [curl]='curl' [wget]='wget'
        [python3]='python3' [openssl]='openssl' [iperf3]='iperf3'
        [iputils-ping]='ping' [iptables]='iptables' [iproute2]='ip'
        [util-linux]='flock' [gzip]='gzip' [coreutils]='sha256sum'
        [jq]='jq' [unzip]='unzip' [tar]='tar'
        [procps]='ps' [cron]='cron' [nano]='nano'
    )
    local -A was_missing=() apt_err=()
    INSTALL_REPORT_PREREQS=(); PREREQ_FAILED_LIST=''

    if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
        echo 'APT/dpkg not found. Automatic prerequisite installation requires Debian/Ubuntu.' >&2
        return 1
    fi

    total=${#packages[@]}
    for pkg in "${packages[@]}"; do
        cmd="${checks[$pkg]}"
        if { [ "$cmd" = cert ] && [ -s /etc/ssl/certs/ca-certificates.crt ]; } || command -v "$cmd" >/dev/null 2>&1; then
            was_missing["$pkg"]=0
        else
            was_missing["$pkg"]=1
            missing+=("$pkg")
        fi
    done
    base=$(( total - ${#missing[@]} ))
    draw_stage_progress "$base" "$total" "Prerequisites"

    if [ "${#missing[@]}" -gt 0 ]; then
        apt_log=$(mktemp "${TMPDIR:-/tmp}/mtunnel-apt.XXXXXXXX") || return 1
        # IPv4 only: a broken IPv6 route is the usual reason APT hangs on a VPS.
        local -a apt_base=(apt-get -o DPkg::Lock::Timeout=120 -o Acquire::Retries=2 -o Acquire::ForceIPv4=true
            -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
        # Refresh package lists first; a failure here is not fatal (existing lists may still work).
        if ! installer_run_live "$apt_log" 120 "$base" "$total" Prerequisites 'apt update' "${apt_base[@]}" update; then
            update_failed=1; update_err=$(tail -n 2 "$apt_log" 2>/dev/null | tr '\n' ' ')
        fi
        for pkg in "${missing[@]}"; do
            i=$((i+1))
            if installer_run_live "$apt_log" 180 "$((base+i-1))" "$total" Prerequisites "$pkg" "${apt_base[@]}" -y install "$pkg"; then
                :
            else
                rc=$?
                failed_pkgs+=("$pkg")
                if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then apt_err["$pkg"]='timed out'
                else apt_err["$pkg"]=$(tail -n 2 "$apt_log" 2>/dev/null | tr '\n' ' '); fi
            fi
            draw_stage_progress "$((base+i))" "$total" Prerequisites
        done
        rm -f "$apt_log"
    fi

    for pkg in "${packages[@]}"; do
        idx=$((idx+1)); cmd="${checks[$pkg]}"; ver=$(installer_pkg_version "$pkg")
        if { [ "$cmd" = cert ] && [ -s /etc/ssl/certs/ca-certificates.crt ]; } || command -v "$cmd" >/dev/null 2>&1; then
            if [ "${was_missing[$pkg]:-0}" = 1 ]; then state='newly installed'; else state='already installed'; fi
            INSTALL_REPORT_PREREQS+=("$pkg|${ver:-Unknown}|$state")
        else
            INSTALL_REPORT_PREREQS+=("$pkg|${ver:-Unknown}|failed: ${apt_err[$pkg]:-not installed}")
            PREREQ_FAILED_LIST+="${PREREQ_FAILED_LIST:+ }$pkg"
        fi
    done

    if [ -n "$PREREQ_FAILED_LIST" ]; then
        draw_stage_progress "$(( total - $(wc -w <<< "$PREREQ_FAILED_LIST") ))" "$total" Prerequisites fail
        printf '\n'
        [ "$update_failed" != 1 ] || INSTALLER_NOTES+=("apt-get update failed: ${update_err:-unknown error}")
        return 1
    fi
    draw_stage_progress "$total" "$total" Prerequisites
    printf '\n'
    [ "$update_failed" != 1 ] || INSTALLER_NOTES+=("apt-get update failed (existing package lists were used): ${update_err:-unknown error}")
    return 0
}

installer_main() {
    local source_dir='' root='' with_cores=0 launch=1 remote='' work path name target item
    local scripts_only=0 want_prereqs=0 do_uninstall=0 prereq_failed=0
    local script_file="${BASH_SOURCE[0]:-}" script_dir=''
    [[ ! -f "$script_file" ]] || script_dir=$(cd -- "$(dirname -- "$script_file")" && pwd) || return 1
    local -a modules=(main:main.sh mporter:mporter.sh msmart:tunnels/msmart.sh linktest:linktest.sh mgre:tunnels/mgre.sh mxlan:tunnels/mxlan.sh mrathole:tunnels/mrathole.sh mbackhaul:tunnels/mbackhaul.sh mpaqet:tunnels/mpaqet.sh mdoctor:mdoctor.sh mmirror:mirror.sh)
    local -a active_modules=()
    local -a files=()
    local current=0 mod_ver installed_ver script_state
    local -A engine_versions=() engine_skips=()
    INSTALLER_NOTES=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --local) [ "$#" -ge 2 ] || { echo '--local needs a directory.' >&2; return 1; }; source_dir="$2"; remote=''; shift 2;;
            --root) [ "$#" -ge 2 ] || { echo '--root needs an absolute directory.' >&2; return 1; }; [[ "$2" == /* && "$2" != / ]] || { echo 'Unsafe --root path.' >&2; return 1; }; root="${2%/}"; launch=0; shift 2;;
            --with-cores) with_cores=1; shift;;
            --with-prereqs) want_prereqs=1; shift;;
            --scripts-only) scripts_only=1; shift;;
            --no-launch) launch=0; shift;;
            --remote) [ "$#" -ge 2 ] || { echo '--remote needs an HTTPS base URL.' >&2; return 1; }; remote="${2%/}"; source_dir=''; shift 2;;
            --online) remote="$DEFAULT_REMOTE"; source_dir=''; shift;;
            --allow-downgrade) export MT_ALLOW_DOWNGRADE=1; shift;;
            --uninstall) do_uninstall=1; shift;;
            --help|-h) installer_usage; return 0;;
            *) echo "Unknown option: $1" >&2; return 1;;
        esac
    done
    installer_require_core_api || return 1
    if [ -n "$root" ]; then
        [[ "$root" == /* && "$root" != / ]] || { echo 'Unsafe --root path (must be an absolute directory other than /).' >&2; return 1; }
        [[ ! "$root" =~ (^|/)\.\.(/|$) && ! "$root" =~ (^|/)\.(/|$) ]] || { echo 'Unsafe --root path.' >&2; return 1; }
        root=$(readlink -m -- "$root") || return 1
        [ "$root" != / ] || return 1
    elif [ "$EUID" != 0 ]; then echo 'Run the installer with sudo.' >&2; return 1; fi
    if [ "$do_uninstall" == 1 ]; then
        [ -z "$root" ] || { echo '--uninstall cannot be combined with --root.' >&2; return 1; }
        installer_uninstall; return $?
    fi
    if [ -z "$source_dir" ] && [ -z "$remote" ]; then
        if [ -n "$script_dir" ] && [ -f "$script_dir/main.sh" ]; then source_dir="$script_dir"
        elif { : </dev/tty; } 2>/dev/null; then
            installer_wizard || return 0
            if [ "${WIZ_UNINSTALL:-0}" == 1 ]; then do_uninstall=1
            else remote="$WIZ_REMOTE"; with_cores="$WIZ_CORES"; scripts_only="$WIZ_SCRIPTS_ONLY"; want_prereqs="$WIZ_PREREQS"; fi
        else remote="$DEFAULT_REMOTE"; fi
    fi
    if [ "$do_uninstall" == 1 ]; then
        [ -z "$root" ] || { echo '--uninstall cannot be combined with --root.' >&2; return 1; }
        installer_uninstall; return $?
    fi
    [ -z "$root" ] || [ "$want_prereqs" != 1 ] || {
        echo 'Prerequisite installation is not supported with --root.' >&2; return 1;
    }
    if [ "$want_prereqs" == 1 ] && { ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; }; then
        echo 'Prerequisite installation needs Debian/Ubuntu (apt-get). Choose the option without prerequisites.' >&2
        return 1
    fi
    # Scripts-only skips the tunnel modules (they stay as they are and are fetched on demand).
    for item in "${modules[@]}"; do
        path="${item#*:}"
        [ "$scripts_only" == 1 ] && [[ "$path" == tunnels/* ]] && continue
        active_modules+=("$item")
    done
    INSTALL_REPORT_SCRIPTS=()
    INSTALL_REPORT_ENGINES=()
    INSTALL_REPORT_PREREQS=()
    work=$(mktemp -d "${TMPDIR:-/tmp}/mtunnel-install.XXXXXX") || return 1
    chmod 700 "$work"
    INSTALLER_WORK="$work"
    trap 'rm -rf -- "$INSTALLER_WORK"; mt_installer_hdr_cleanup' EXIT
    draw_installer_header
    draw_stage_progress 0 "${#active_modules[@]}" "Scripts"
    if [ -n "$remote" ]; then
        [[ "$remote" == https://* ]] || { echo 'Download requires HTTPS.' >&2; return 1; }
        remote="${remote%/}"
        mkdir "$work/scripts" "$work/scripts/core" || return 1
        if ! installer_fetch "$(mt_cb_url "$remote/core/common.sh")" "$work/scripts/core/common.sh" 'core/common.sh' 1 || ! mt_validate_shared_core "$work/scripts/core/common.sh"; then
            echo 'Cannot prepare shared core; current installation preserved.' >&2; return 1
        fi
        for item in "${active_modules[@]}"; do
            path="${item#*:}"
            mkdir -p "$work/scripts/$(dirname "$path")" || return 1
            if ! installer_fetch "$(mt_cb_url "$remote/$path")" "$work/scripts/$path" "$path" 1 || ! mt_validate_script "$work/scripts/$path"; then
                echo "Cannot prepare module: $path. Installed scripts preserved." >&2; return 1
            fi
            current=$((current+1))
            draw_stage_progress "$current" "${#active_modules[@]}" "Scripts"
        done
        # If this fixed standalone install.sh was supplied locally, keep that
        # exact copy. Do not silently overwrite it with an older remote file.
        if [ "${script_file##*/}" = install.sh ] && [ -f "$script_file" ] && mt_validate_script "$script_file"; then
            cp -f -- "$script_file" "$work/scripts/install.sh" || return 1
        elif ! installer_fetch "$(mt_cb_url "$remote/install.sh")" "$work/scripts/install.sh" 'install.sh' 1 || ! mt_validate_script "$work/scripts/install.sh"; then
            echo 'Cannot prepare installer: install.sh. Installed scripts preserved.' >&2; return 1
        fi
        # The remote VERSION file is only an update marker and may lag behind the files.
        # Bundle consistency is enforced below by comparing the staged core, every module
        # and install.sh, so a stale VERSION marker must never block an install.
        source_dir="$work/scripts"
    fi
    [ -n "$source_dir" ] && [ -d "$source_dir" ] || { echo 'Script directory does not exist.' >&2; return 1; }
    mt_validate_shared_core "$source_dir/core/common.sh" || {
        echo 'Shared core is missing or invalid. Existing installation preserved.' >&2; return 1;
    }
    # Release numbers are informational and any compatible mix of module versions is
    # accepted. The only gate is the shared-core API/layout contract (validated above
    # and re-checked by every module at start-up).
    mt_validate_script "$source_dir/install.sh" || { echo 'Missing or invalid install.sh in complete bundle.' >&2; return 1; }
    head -n 5 "$source_dir/install.sh" | grep -Fq '# MTunnel standalone installer:' || { echo 'Incorrect install.sh in complete bundle.' >&2; return 1; }
    if [ -n "$remote" ]; then
        :
    else
        # A partial package must not silently leave mixed module/core versions.
        for item in "${active_modules[@]}"; do
            path="${item#*:}"
            mt_validate_script "$source_dir/$path" || { echo "Missing module: $path. Existing installation preserved." >&2; return 1; }
            mt_validate_module_role "$source_dir/$path" "$path" || { echo "Wrong module role: $path. Existing installation preserved." >&2; return 1; }
            mt_validate_module_core_contract "$source_dir/$path" || { echo "Incompatible module/core contract: $path. Existing installation preserved." >&2; return 1; }
        done
    fi
    # Install the shared API before replacing any dependent module. All files
    # are staged and rolled back together by mt_install_files on copy failure.
    files+=("$source_dir/core/common.sh" "$root/usr/lib/mtunnel/common.sh"
            "$source_dir/core/common.sh" "$root/root/mtunnel/core/common.sh")
    for item in "${active_modules[@]}"; do
        name="${item%%:*}"; path="${item#*:}"; target="$root/usr/bin/$name"
        [ "$name" != main ] || target="$root/usr/bin/mtunnel"
        mt_validate_script "$source_dir/$path" || { echo "Missing or invalid module: $path. Installed scripts preserved." >&2; return 1; }
        mt_validate_module_role "$source_dir/$path" "$path" || { echo "Wrong module role: $path. Installed scripts preserved." >&2; return 1; }
        mt_validate_module_core_contract "$source_dir/$path" || { echo "Incompatible module/core contract: $path. Installed scripts preserved." >&2; return 1; }
        mod_ver=$(installer_script_version "$source_dir/$path")
        installed_ver=''; script_state='newly installed'
        if [ -f "$target" ]; then
            installed_ver=$(installer_script_version "$target")
            if cmp -s "$source_dir/$path" "$target" 2>/dev/null; then
                script_state='already installed (up to date)'
            elif [ -n "$installed_ver" ]; then
                script_state="updated from v${installed_ver}"
            else
                script_state='updated existing file'
            fi
        fi
        INSTALL_REPORT_SCRIPTS+=("$name|${mod_ver:-Unknown}|$script_state")
        files+=("$source_dir/$path" "$target" "$source_dir/$path" "$root/root/mtunnel/$path")
        if [ -z "$remote" ]; then
            current=$((current+1))
            draw_stage_progress "$current" "${#active_modules[@]}" "Scripts"
        fi
    done
    printf '\n'
    files+=("$source_dir/install.sh" "$root/root/mtunnel/install.sh")
    # Engines: install every one that exists at the source and is a valid ELF; a missing one is
    # skipped without aborting the whole installation. Progress still reaches 100% because every
    # engine is accounted for as installed/already-present/skipped.
    local -a got_cores=() skipped_cores=() same_cores=()
    local -a engine_names=(bh rathole paqet gost haproxy realm)
    local engine_total=${#engine_names[@]} gost_ver="${MT_GOST_VERSION:-2.11.5}" dst fetch_err=''
    if [ "$with_cores" == 1 ]; then
        local gz_arch='' gz_name='' src_file='' engine_manifest engine_input eng_tag='' skip_reason='' eng_current=0
        draw_stage_progress 0 "$engine_total" "Engines"
        engine_manifest="$source_dir/engines/manifest.txt"
        if [ -n "$remote" ]; then
            mkdir -p "$work/scripts/engines" || return 1
            if ! installer_fetch "$(mt_cb_url "$remote/engines/manifest.txt")" "$engine_manifest" 'engines/manifest.txt' 1; then
                echo "Cannot download the tunnel-engine manifest: ${INSTALLER_FETCH_ERR:-unknown error}" >&2
                return 1
            fi
        fi
        case "$(uname -m)" in x86_64) gz_arch=amd64;; aarch64|arm64) gz_arch=arm64;; esac
        for name in "${engine_names[@]}"; do
            path="engines/$name"; src_file="$source_dir/$path"; engine_input="$name"; skip_reason=''
            gz_name=''; [ "$name" != gost ] || [ -z "$gz_arch" ] || gz_name="gost-linux-${gz_arch}-${gost_ver}.gz"

            if [ -n "$remote" ]; then
                mkdir -p "$work/scripts/engines" || return 1
                if [ -f "$root/usr/local/bin/$name" ] && mt_valid_elf "$root/usr/local/bin/$name" &&
                   installer_verify_package "$engine_manifest" "$root/usr/local/bin/$name" "$name" >/dev/null 2>&1; then
                    src_file="$root/usr/local/bin/$name"
                elif ! installer_fetch "$(mt_cb_url "$remote/engines/$name")" "$src_file" "engines/$name" 1; then
                    fetch_err="$INSTALLER_FETCH_ERR"
                    if [ -n "$gz_name" ] && installer_fetch "$(mt_cb_url "$remote/engines/$gz_name")" "$work/scripts/engines/$gz_name" "engines/$gz_name" 1; then
                        installer_verify_package "$engine_manifest" "$work/scripts/engines/$gz_name" "$gz_name" || return 1
                        gzip -dc "$work/scripts/engines/$gz_name" > "$src_file" || return 1
                        engine_input="$gz_name"
                    else
                        rm -f "$src_file"
                        skip_reason="download failed: ${fetch_err:-not available at selected source}"
                    fi
                fi
            elif [ ! -f "$src_file" ] && [ -n "$gz_name" ] && [ -f "$source_dir/engines/$gz_name" ]; then
                mkdir -p "$work/engines" || return 1
                src_file="$work/engines/$name"
                installer_verify_package "$engine_manifest" "$source_dir/engines/$gz_name" "$gz_name" || return 1
                engine_input="$gz_name"
                gzip -dc "$source_dir/engines/$gz_name" > "$src_file" 2>/dev/null || skip_reason="cannot unpack $gz_name"
            fi

            if [ -z "$skip_reason" ] && [ "$engine_input" = "$name" ] && [ -f "$src_file" ]; then
                installer_verify_package "$engine_manifest" "$src_file" "$name" || return 1
            fi
            if [ -z "$skip_reason" ] && ! mt_valid_elf "$src_file"; then
                skip_reason='missing or not a valid ELF for this CPU'
            fi

            eng_current=$((eng_current+1))
            if [ -n "$skip_reason" ]; then
                skipped_cores+=("$name")
                engine_skips["$name"]="$skip_reason"
                draw_stage_progress "$eng_current" "$engine_total" "Engines"
                continue
            fi

            got_cores+=("$name")
            if cmp -s "$src_file" "$root/usr/local/bin/$name" 2>/dev/null; then same_cores+=("$name"); fi
            eng_tag=$(installer_file_build_tag "$src_file")
            if [[ "$engine_input" =~ ^gost-linux-[^-]+-([0-9.]+)\.gz$ ]]; then eng_tag="${BASH_REMATCH[1]}"; fi
            engine_versions["$name"]="${eng_tag:-Unknown}"
            installer_backup_foreign_binary "$root" "$name" "$src_file"
            # Never queue a copy of a file onto itself (the installed binary can be the source).
            for dst in "$root/usr/local/bin/$name" "$root/usr/bin/$name" "$root/root/mtunnel/$path"; do
                [ "$src_file" -ef "$dst" ] || files+=("$src_file" "$dst")
            done
            draw_stage_progress "$eng_current" "$engine_total" "Engines"
        done
        printf '\n'
    fi

    local -a owned_candidates=()
    for name in "${got_cores[@]}"; do
        case "$name" in bh|rathole|paqet) ;; *) continue;; esac
        if [ -f "$root/var/lib/mtunnel/owned-binaries/$name" ] || \
           { [ ! -e "$root/usr/local/bin/$name" ] && [ ! -e "$root/usr/bin/$name" ]; }; then
            owned_candidates+=("$name")
        fi
    done

    mt_install_files 755 "${files[@]}" || { echo 'Install failed; committed files were rolled back.' >&2; return 1; }

    if [ "$with_cores" == 1 ]; then
        local eng eng_state
        for eng in "${engine_names[@]}"; do
            if [[ " ${got_cores[*]} " == *" $eng "* ]]; then
                if [[ " ${same_cores[*]} " == *" $eng "* ]]; then eng_state='already installed (up to date)'; else eng_state='newly installed'; fi
                INSTALL_REPORT_ENGINES+=("$eng|${engine_versions[$eng]:-Unknown}|$eng_state")
            else
                INSTALL_REPORT_ENGINES+=("$eng|Unknown|skipped: ${engine_skips[$eng]:-not available}")
            fi
        done
    fi
    for name in "${owned_candidates[@]}"; do
        MTUNNEL_TEST_ROOT="$root" mt_owned_binary_register "$name" "$root/usr/local/bin/$name" || echo "Warning: Could not record $name ownership" >&2
    done
    if [ -z "$root" ]; then
        mt_installer_retire_legacy
    fi
    if [ "$want_prereqs" == 1 ]; then
        installer_install_prereqs || prereq_failed=1
    fi

    # Finish post-install service work before the final report. Only services whose engine
    # binary actually changed are restarted; one failed restart no longer aborts the install.
    if [ "$with_cores" == 1 ] && [ -z "$root" ]; then
        local -a restart_pats=() restart_failed=()
        for name in "${got_cores[@]}"; do
            [[ " ${same_cores[*]} " == *" $name "* ]] && continue
            case "$name" in
                bh)      restart_pats+=('mbackhaul@*.service');;
                rathole) restart_pats+=('mrathole@*.service');;
                paqet)   restart_pats+=('mpaqet@*.service');;
                gost)    restart_pats+=('gost.service');;
                haproxy) restart_pats+=('haproxy.service');;
                realm)   restart_pats+=('realm.service');;
            esac
        done
        if [ "${#restart_pats[@]}" -gt 0 ]; then
            while read -r target; do
                [ -z "$target" ] || systemctl restart "$target" || restart_failed+=("$target")
            done < <(systemctl list-units --type=service --state=active --no-legend --plain "${restart_pats[@]}" 2>/dev/null | awk '{print $1}')
        fi
        [ "${#restart_failed[@]}" -eq 0 ] || INSTALLER_NOTES+=("Could not restart: ${restart_failed[*]}")
    fi

    installer_print_report

    if [ "$prereq_failed" == 1 ]; then
        echo -e "\n  ${R}✖ Scripts and engines were installed, but some prerequisites failed: ${PREREQ_FAILED_LIST}${NC}" >&2
        echo -e "  ${Y}  Fix the network/APT problem and run the full option again, or install them manually:${NC}" >&2
        echo -e "  ${W}    apt-get update && apt-get install -y ${PREREQ_FAILED_LIST}${NC}\n" >&2
        return 1
    fi
    if [ "${#skipped_cores[@]}" -gt 0 ]; then
        echo -e "\n  ${Y}● MTunnel installed; ${#skipped_cores[@]} engine(s) skipped: ${skipped_cores[*]}${NC}\n"
    else
        echo -e "\n  ${G}● MTunnel Installation Complete!${NC}\n"
    fi
    if [ "$launch" == 1 ] && { : </dev/tty; } 2>/dev/null; then
        printf "  ${W}Results will remain on screen for 30 seconds.${NC}\n"
        printf "  ${Y}Press Enter or any key to skip the results.${NC}"
        IFS= read -r -s -N 1 -t 30 </dev/tty || true
        printf "\r\033[K"
    fi
    if [ "$launch" == 1 ]; then
        rm -rf -- "$INSTALLER_WORK"; mt_installer_hdr_cleanup
        trap - EXIT
        # After "curl ... | bash" stdin is the exhausted pipe: give the dashboard the terminal.
        if [ ! -t 0 ] && { : </dev/tty; } 2>/dev/null; then exec "$root/usr/bin/mtunnel" </dev/tty; fi
        exec "$root/usr/bin/mtunnel"
    fi
}
trap 'mt_installer_hdr_cleanup' EXIT
installer_main "$@"
