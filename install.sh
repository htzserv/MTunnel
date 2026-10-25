#!/bin/bash
# MTunnel standalone installer: local source tree or HTTPS bootstrap (v1.3.4).
MODULE_VERSION="1.4.0"
umask 077
DEFAULT_REMOTE="${MTUNNEL_REPO_URL:-${MTUNNEL_GITHUB_BASE:-https://raw.githubusercontent.com/htzserv/MTunnel/main}}"
MIRROR_REMOTE="${MTUNNEL_MIRROR_BASE:-https://c107328.parspack.net/c107328/MTunnel}"

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
    elif [[ "$mode" != remote && -n "$script_dir" && -f "$PWD/core/common.sh" ]]; then
        candidate="$PWD/core/common.sh"
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
        [[ -z "${MT_INSTALLER_BOOTSTRAP_TEMP:-}" ]] || rm -f "$MT_INSTALLER_BOOTSTRAP_TEMP"
        unset MT_INSTALLER_BOOTSTRAP_TEMP
        return 1
    fi
    # shellcheck source=core/common.sh
    if ! source "$candidate"; then
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
DEFAULT_REMOTE="${MTUNNEL_REPO_URL:-$MTUNNEL_GITHUB_BASE}"


# Backward-compatible installer fallbacks. These make install.sh independently
# updatable: if it is pasted/replaced before common.sh, it still cannot fail with
# "command not found" for release-line/downgrade helpers.
if ! declare -F mt_is_retired_version >/dev/null; then
    mt_is_retired_version() { [[ "${1:-}" =~ ^(15|16)\.[0-9]+(\.[0-9]+)?$ ]]; }
fi
if ! declare -F mt_is_current_release_line >/dev/null; then
    mt_is_current_release_line() { [[ "${1:-}" =~ ^1\.[0-9]+(\.[0-9]+)?$ ]]; }
fi
if ! declare -F mt_release_migration >/dev/null; then
    mt_release_migration() { mt_is_retired_version "$1" && mt_is_current_release_line "$2"; }
fi
if ! declare -F mt_retired_bundle_blocked >/dev/null; then mt_retired_bundle_blocked() { return 1; }; fi
# v1.2.7 helpers: defined here only when an older installed shared core (1.2.7) lacks them,
# so main.sh/install.sh can be updated independently of core/common.sh.
if ! declare -F mt_normalize_pasted_file >/dev/null 2>&1; then
# ---- v1.2.7 shared install helpers -------------------------------------------
# Append a cache-buster to a script/package URL that has no query string.
# raw.githubusercontent.com caches by full URL, so a unique query forces a fresh copy.
mt_cb_url() {
    local url="${1:-}"
    [[ "$url" == *\?* ]] && { printf '%s' "$url"; return 0; }
    printf '%s?t=%s' "$url" "$(date +%s 2>/dev/null || echo 0)"
}
# Turn a GitHub "blob" page link into its raw-file link; any other URL is unchanged.
mt_normalize_download_url() {
    local url="${1:-}"
    if [[ "$url" =~ ^https://(www\.)?github\.com/([^/]+)/([^/]+)/blob/(.+)$ ]]; then
        printf 'https://raw.githubusercontent.com/%s/%s/%s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    else
        printf '%s' "$url"
    fi
}
# Trim whitespace/CR, strip one pair of surrounding quotes, expand a leading ~.
mt_clean_path() {
    local p="${1-}"
    p="${p//$'\r'/}"
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    if [[ ${#p} -ge 2 ]] && { [[ "${p:0:1}" == "'" && "${p: -1}" == "'" ]] || [[ "${p:0:1}" == '"' && "${p: -1}" == '"' ]]; }; then
        p="${p:1:${#p}-2}"
    fi
    case "$p" in
        '~') p="${HOME:-/root}";;
        '~/'*) p="${HOME:-/root}/${p#\~/}";;
    esac
    printf '%s' "$p"
}
# True when the file starts like a ZIP, gzip or tar archive.
mt_is_archive_file() {
    local f="${1:-}" magic
    [ -f "$f" ] || return 1
    magic=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')
    case "$magic" in 504b0304|504b0506|504b0708|1f8b*) return 0;; esac
    [ "$(od -An -c -j257 -N5 "$f" 2>/dev/null | tr -d ' \n')" == ustar ]
}
# True when a downloaded "script" is really a web page (wrong link, 404 page, GitHub blob page).
mt_looks_like_html() {
    local f="${1:-}"
    [ -f "$f" ] || return 1
    head -c 1024 "$f" 2>/dev/null | tr 'A-Z' 'a-z' | grep -Eq '<!doctype html|<html|<head|<body'
}
# Clean text that was pasted/saved by an editor: CRLF, BOM, leading/trailing blank
# lines and an optional Markdown code fence (```bash, ```sh, ```shell, ``` ...).
mt_normalize_pasted_file() {
    local f="${1:-}" tmp
    [[ -n "$f" && -f "$f" && ! -L "$f" ]] || return 1
    sed -i 's/\r$//' "$f" || return 1
    sed -i '1s/^\xEF\xBB\xBF//' "$f" || return 1
    tmp=$(mktemp "${f}.norm.XXXXXX") || return 1
    if awk '
        { lines[++n] = $0 }
        END {
            s = 1; e = n
            while (s <= e && lines[s] ~ /^[ \t]*$/) s++
            while (e >= s && lines[e] ~ /^[ \t]*$/) e--
            if (s <= e && lines[s] ~ /^[ \t]*```[A-Za-z0-9_+-]*[ \t]*$/) {
                s++
                if (e >= s && lines[e] ~ /^[ \t]*```[ \t]*$/) e--
                while (s <= e && lines[s] ~ /^[ \t]*$/) s++
                while (e >= s && lines[e] ~ /^[ \t]*$/) e--
            }
            for (i = s; i <= e; i++) print lines[i]
        }' "$f" > "$tmp"; then
        cat "$tmp" > "$f"; rm -f "$tmp"
    else
        rm -f "$tmp"; return 1
    fi
}
# Open nano for pasting. -I ignores ~/.nanorc (autoindent / tab conversion / hard wrap would
# corrupt pasted code), -w disables hard-wrapping, -t saves on Ctrl+X without prompting.
mt_nano_edit() {
    local file="${1:-}" help; local -a opts=(-t)
    help=$(nano --help 2>&1 || true)
    [[ "$help" == *--ignorercfiles* ]] && opts+=(-I)
    [[ "$help" == *--nowrap* || "$help" == *' -w'* ]] && opts+=(-w)
    nano "${opts[@]}" -- "$file"
}
# ------------------------------------------------------------------------------
fi
if ! declare -F mt_confirm_downgrade >/dev/null; then mt_confirm_downgrade() { return 0; }; fi


















B='\033[1;37m'; G='\033[1;33m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[1;33m'; M='\033[1;33m'; W='\033[1;37m'; DIM='\033[0;37m'; NC='\033[0m'
FR='\033[1;33m'

draw_progress() {
    local n=$1; local total=$2; local text=$3; local ver=$4; local width=26
    [ -z "$total" ] || [ "$total" -le 0 ] && total=1
    local percent=$(( n * 100 / total ))
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar=$(printf "%${filled}s" "" | tr ' ' '#')
    local empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')

    local ver_clean=""
    [ -n "$ver" ] && [ "$ver" != "Unknown" ] && ver_clean=" (v${ver})"

    local plain_label="${text}${ver_clean}"
    local pad_spaces=$(( 26 - ${#plain_label} ))
    [ "$pad_spaces" -lt 0 ] && pad_spaces=0
    local padding=$(printf '%*s' "$pad_spaces" "")

    tput civis 2>/dev/null || true
    if [ -n "$ver_clean" ]; then
        printf "\r  %b✔%b %b%s%b%b%s%b%s %b[%b%s%b%s%b] %b%3d%%%b" \
            "$G" "$NC" \
            "$W" "$text" "$NC" \
            "$Y" "$ver_clean" "$NC" \
            "$padding" \
            "$W" "$W" "$bar" "$DIM" "$empty_bar" "$NC" \
            "$W" "$percent" "$NC"
    else
        printf "\r  %b✔%b %b%s%b%s %b[%b%s%b%s%b] %b%3d%%%b" \
            "$G" "$NC" \
            "$W" "$text" "$NC" \
            "$padding" \
            "$W" "$W" "$bar" "$DIM" "$empty_bar" "$NC" \
            "$W" "$percent" "$NC"
    fi
    tput cnorm 2>/dev/null || true
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
#   1-3  official GitHub : full package / scripts + tunnels / scripts only
#   4-6  Iranian mirror  : full package / scripts + tunnels / scripts only
#   7    uninstall MTunnel from this system          0  quit
# One menu entry (name only, one per line).
_wiz_item() {
    case "$1" in
        1|4) echo -e "    ${Y}[$1]${NC} ${W}Full package${NC}";;
        2|5) echo -e "    ${Y}[$1]${NC} ${W}Scripts + tunnels${NC}";;
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
    systemctl stop mgre-watchdog.timer mxlan-watchdog.timer mporter-watchdog.service 2>/dev/null || true
    /usr/bin/mgre --teardown-all 2>/dev/null || true
    /usr/bin/mxlan --teardown-all 2>/dev/null || true
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
    systemctl stop mgre-watchdog.timer mxlan-watchdog.timer mbackhaul-apply.service mrathole-apply.service mpaqet-apply.service mporter-iptables.service mporter-obfs.service 2>/dev/null || true
    systemctl disable mgre-watchdog.timer mxlan-watchdog.timer mbackhaul-apply.service mrathole-apply.service mpaqet-apply.service mporter-iptables.service mporter-obfs.service 2>/dev/null || true
    rm -f /etc/systemd/system/mgre-watchdog.{service,timer} /etc/systemd/system/mxlan-watchdog.{service,timer} /etc/systemd/system/{mbackhaul,mrathole,mpaqet}-apply.service /etc/systemd/system/mporter-{iptables,obfs}.service
    rm -f /usr/local/bin/mhealer_daemon.sh /usr/local/bin/mporter-{watchdog,iptables,obfs}.sh /etc/mhealer.conf
    rm -f /var/lock/mporter-state.lock /run/mporter-backends.tsv
    # Generic Gost/Realm installations may belong to another project: remove only when MPorter marked ownership.
    if [ -f /etc/mporter/.owns_gost ]; then systemctl disable --now gost.service 2>/dev/null || true; rm -f /etc/systemd/system/gost.service /usr/local/bin/gost; rm -rf /etc/gost; fi
    if [ -f /etc/mporter/.owns_realm ]; then systemctl disable --now realm.service 2>/dev/null || true; rm -f /etc/systemd/system/realm.service /usr/local/bin/realm; rm -rf /etc/realm; fi
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
    rm -rf /var/lib/mtunnel/owned-binaries /usr/lib/mtunnel /etc/mgre /etc/mporter /etc/mrathole /etc/mbackhaul /etc/paqet /root/mtunnel 2>/dev/null || true
    rm -f /usr/bin/mtunnel /usr/bin/mgre /usr/bin/mxlan /usr/bin/mbackhaul /usr/bin/mpaqet /usr/bin/mporter /usr/bin/mrathole /usr/bin/mdoctor /usr/bin/linktest
    rm -f /usr/local/bin/mtunnel
    echo -e "\n  ${Y}✓ MTunnel was completely removed from this system.${NC}\n"
    return 0
}

# Echoes "<state>|<installed-version>" for a .deb file name: state is "current" (same or newer version already
# installed), "older" (installed but older), or "missing".
installer_deb_state() {
    local base="${1##*/}" pkg ver cur
    base="${base%.deb}"; pkg="${base%%_*}"; ver="${base#*_}"; ver="${ver%_*}"; ver="${ver//%3a/:}"
    cur=$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' "$pkg" 2>/dev/null) || { echo "missing|"; return 0; }
    case "$cur" in
        ii*) cur="${cur#*|}"
             if dpkg --compare-versions "$cur" ge "$ver" 2>/dev/null; then echo "current|$cur"; else echo "older|$cur"; fi;;
        *) echo "missing|";;
    esac
}

# Installs the .deb prerequisites of a full package: from the remote prereqs/ folder or a local prereqs/ folder.
# Already-installed packages are reported as such (not as errors) and are not downloaded again.
installer_install_prereqs() {
    local remote="$1" src="$2" work="$3" dir="$3/prereqs" name deb st ver pkg
    local total=0 n_ok=0 n_have=0 n_apt=0 n_fail=0 progress
    local -a debs=() pending=() next=() failed=()
    mkdir -p "$dir" || return 1
    local -a deb_names=() core_names=() fixed_names=(
        cron_3.0pl1-184ubuntu2_amd64.deb
        curl_8.5.0-2ubuntu10.16_amd64.deb
        gzip_1.12-1ubuntu3.2_amd64.deb
        haproxy_2.8.30-0ubuntu0.24.04.1_amd64.deb
        libiperf0_3.16-1build2_amd64.deb
        iperf3_3.16-1build2_amd64.deb
        iproute2_6.1.0-1ubuntu6.4_amd64.deb
        libonig5_6.9.9-1build1_amd64.deb
        libjq1_1.7.1-3ubuntu0.24.04.2_amd64.deb
        jq_1.7.1-3ubuntu0.24.04.2_amd64.deb
        qrencode_4.1.1-1build2_amd64.deb
        socat_1.8.0.0-4ubuntu0.1_amd64.deb
        wget_1.21.4-1ubuntu4.5_amd64.deb
    )
    local mf line
    if [ -n "$remote" ]; then
        # Prefer the remote prereqs/manifest.txt (every .deb in the folder, dependencies included);
        # fall back to the built-in list when the source has no manifest.
        mf="$work/prereqs-manifest.txt"
        if mt_download "$(mt_cb_url "$remote/prereqs/manifest.txt")" "$mf" 2>/dev/null; then
            while IFS= read -r line || [ -n "$line" ]; do
                line="${line//$'\r'/}"; line="${line##*[[:space:]]}"; line="${line#\*}"
                [[ "$line" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*\.deb$ ]] && deb_names+=("$line")
            done < "$mf"
        fi
        [ "${#deb_names[@]}" -gt 0 ] || deb_names=("${fixed_names[@]}")
    else
        for deb in "$src"/prereqs/*.deb; do [ -f "$deb" ] && deb_names+=("${deb##*/}"); done
    fi
    # Packages listed individually in the report; the rest (libraries pulled in as dependencies) are only counted.
    local primary=" cron curl gzip haproxy libiperf0 iperf3 iproute2 jq qrencode socat wget "
    [ "${#deb_names[@]}" -gt 0 ] || { echo -e "  ${Y}● No .deb prerequisites found for this package.${NC}"; return 0; }
    total=${#deb_names[@]}
    for name in "${deb_names[@]}"; do
        pkg="${name%%_*}"
        st=$(installer_deb_state "$name"); ver="${st#*|}"; st="${st%%|*}"
        if [ "$st" == current ]; then
            [[ "$primary" == *" $pkg "* ]] && echo -e "  ${G}✓ ${pkg}${NC} ${DIM}— already installed (${ver})${NC}"
            n_have=$((n_have+1)); continue
        fi
        if [ -n "$remote" ]; then
            if mt_download "$(mt_cb_url "$remote/prereqs/$name")" "$dir/$name" 2>/dev/null; then debs+=("$dir/$name")
            else
                # Not on the source: fall back to the system package manager when available.
                if command -v apt-get >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1; then
                    echo -e "  ${G}✓ ${pkg}${NC} ${DIM}— installed via apt${NC}"; n_apt=$((n_apt+1))
                else
                    echo -e "  ${R}✖ ${pkg} — not available on the source and apt could not install it${NC}" >&2
                    failed+=("$name"); n_fail=$((n_fail+1))
                fi
            fi
        else
            debs+=("$src/prereqs/$name")
        fi
    done
    pending=("${debs[@]}"); progress=1
    while [ "${#pending[@]}" -gt 0 ] && [ "$progress" == 1 ]; do
        progress=0; next=()
        for deb in "${pending[@]}"; do
            if DEBIAN_FRONTEND=noninteractive dpkg -i --force-confdef --force-confold "$deb" >/dev/null 2>&1; then
                progress=1; n_ok=$((n_ok+1)); echo -e "  ${G}✓ ${deb##*/}${NC} ${DIM}— installed${NC}"
            else next+=("$deb"); fi
        done
        pending=("${next[@]}")
    done
    for deb in "${pending[@]}"; do
        pkg="${deb##*/}"; pkg="${pkg%%_*}"
        st=$(installer_deb_state "$deb"); st="${st%%|*}"
        if [ "$st" == current ]; then
            echo -e "  ${G}✓ ${pkg}${NC} ${DIM}— already installed${NC}"; n_have=$((n_have+1))
        elif command -v apt-get >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1; then
            echo -e "  ${G}✓ ${pkg}${NC} ${DIM}— installed via apt${NC}"; n_apt=$((n_apt+1))
        else
            echo -e "  ${R}✖ Not installed: ${deb##*/}${NC}" >&2; failed+=("$deb"); n_fail=$((n_fail+1))
        fi
    done
    echo -e "  ${G}● Prerequisites: ${n_have} already installed, $((n_ok+n_apt)) newly installed, ${n_fail} failed (total ${total})${NC}"
    [ "$n_fail" -eq 0 ]
}

installer_main() {
    local source_dir='' root='' with_cores=0 launch=1 remote='' work path name target item
    local scripts_only=0 want_prereqs=0 do_uninstall=0
    local script_file="${BASH_SOURCE[0]:-}" script_dir=''
    [[ ! -f "$script_file" ]] || script_dir=$(cd -- "$(dirname -- "$script_file")" && pwd) || return 1
    local -a modules=(main:main.sh mporter:mporter.sh linktest:linktest.sh mgre:tunnels/mgre.sh mxlan:tunnels/mxlan.sh mrathole:tunnels/mrathole.sh mbackhaul:tunnels/mbackhaul.sh mpaqet:tunnels/mpaqet.sh mdoctor:mdoctor.sh mmirror:mirror.sh)
    local -a active_modules=()
    local -a files=()
    local current=0 mod_ver
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --local) [ "$#" -ge 2 ] || { echo '--local needs a directory.' >&2; return 1; }; source_dir="$2"; remote=''; shift 2;;
            --root) [ "$#" -ge 2 ] || { echo '--root needs an absolute directory.' >&2; return 1; }; root="${2%/}"; launch=0; shift 2;;
            --with-cores) with_cores=1; shift;;
            --no-launch) launch=0; shift;;
            --remote) [ "$#" -ge 2 ] || { echo '--remote needs an HTTPS base URL.' >&2; return 1; }; remote="${2%/}"; source_dir=''; shift 2;;
            --online) remote="$DEFAULT_REMOTE"; source_dir=''; shift;;
            --allow-downgrade) export MT_ALLOW_DOWNGRADE=1; shift;;
            --uninstall) do_uninstall=1; shift;;
            --help|-h)
                echo 'Usage: sudo bash install.sh [--local DIR] [--remote HTTPS_BASE | --online] [--no-launch]'
                echo 'Without options: use adjacent scripts, or download from the official GitHub source.'
                echo '  --online             Force online install from the official GitHub source.'
                echo '  --allow-downgrade    Compatibility alias; downgrades are always permitted.'
                echo '  --remote URL         Use a custom HTTPS repository base instead of the official source.'
                echo '  --with-cores         Also install bundled binary cores when available.'
                echo '  --root DIR           Test-install under DIR without touching the live root.'
                echo '  --uninstall          Remove MTunnel completely (asks for confirmation).'
                echo ''
                echo 'Version switching is unrestricted: upgrade or downgrade directly from any compatible bundle.'
                echo 'Local install example:'
                echo '  sudo bash install.sh --local .'
                echo 'Online one-line example:'
                echo "  curl -fsSL $MTUNNEL_GITHUB_BASE/install.sh | sudo bash -s -- --online"
                return 0;;
            *) echo "Unknown option: $1" >&2; return 1;;
        esac
    done
    if [ -n "$root" ]; then
        [[ "$root" == /* && "$root" != / ]] || { echo 'Unsafe --root path (must be an absolute directory other than /).' >&2; return 1; }
        [[ ! "$root" =~ (^|/)\.\.(/|$) && ! "$root" =~ (^|/)\.(/|$) ]] || { echo 'Unsafe --root path.' >&2; return 1; }
        root=$(readlink -m -- "$root") || return 1
        [ "$root" != / ] || return 1
    elif [ "$EUID" != 0 ]; then echo 'Run the installer with sudo.' >&2; return 1; fi
    if [ "$do_uninstall" == 1 ]; then installer_uninstall; return $?; fi
    if [ -z "$source_dir" ] && [ -z "$remote" ]; then
        if [ -n "$script_dir" ] && [ -f "$script_dir/main.sh" ]; then source_dir="$script_dir"
        elif [ -n "$script_dir" ] && [ -f "$PWD/main.sh" ]; then source_dir="$PWD"
        elif { : </dev/tty; } 2>/dev/null && installer_wizard; then
            if [ "${WIZ_UNINSTALL:-0}" == 1 ]; then do_uninstall=1
            else remote="$WIZ_REMOTE"; with_cores="$WIZ_CORES"; scripts_only="$WIZ_SCRIPTS_ONLY"; want_prereqs="$WIZ_PREREQS"; fi
        else remote="$DEFAULT_REMOTE"; fi
    fi
    if [ "$do_uninstall" == 1 ]; then installer_uninstall; return $?; fi
    # Scripts-only skips the tunnel modules (they stay as they are and are fetched on demand).
    for item in "${modules[@]}"; do
        path="${item#*:}"
        [ "$scripts_only" == 1 ] && [[ "$path" == tunnels/* ]] && continue
        active_modules+=("$item")
    done
    work=$(mktemp -d "${TMPDIR:-/tmp}/mtunnel-install.XXXXXX") || return 1
    chmod 700 "$work"
    INSTALLER_WORK="$work"
    trap 'rm -rf -- "$INSTALLER_WORK"; mt_installer_hdr_cleanup' EXIT
    draw_installer_header
    if [ -n "$remote" ]; then
        [[ "$remote" == https://* ]] || { echo 'Download requires HTTPS.' >&2; return 1; }
        remote="${remote%/}"
        mkdir "$work/scripts" "$work/scripts/core" || return 1
        if ! mt_download "$(mt_cb_url "$remote/core/common.sh")" "$work/scripts/core/common.sh" || ! mt_validate_shared_core "$work/scripts/core/common.sh"; then
            echo 'Cannot prepare shared core; current installation preserved.' >&2; return 1
        fi
        for item in "${active_modules[@]}"; do
            path="${item#*:}"
            mkdir -p "$work/scripts/$(dirname "$path")" || return 1
            if ! mt_download "$(mt_cb_url "$remote/$path")" "$work/scripts/$path" || ! mt_validate_script "$work/scripts/$path"; then
                echo "Cannot prepare module: $path. Installed scripts preserved." >&2; return 1
            fi
            current=$((current+1)); name="${item%%:*}"
            mod_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$work/scripts/$path")
            draw_progress "$current" "${#active_modules[@]}" "$name" "$mod_ver"
            echo ''
        done
        if ! mt_download "$(mt_cb_url "$remote/install.sh")" "$work/scripts/install.sh" || ! mt_validate_script "$work/scripts/install.sh"; then
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
        files+=("$source_dir/$path" "$target" "$source_dir/$path" "$root/root/mtunnel/$path")
        if [ -z "$remote" ]; then
            current=$((current+1))
            mod_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$source_dir/$path")
            draw_progress "$current" "${#active_modules[@]}" "$name" "$mod_ver"
            echo ''
        fi
    done
    files+=("$source_dir/install.sh" "$root/root/mtunnel/install.sh")
    # Engines: install every one that exists at the source and is a valid ELF; a missing one is reported and
    # skipped (it can be added later from the main menu) instead of aborting the whole installation.
    local -a got_cores=() skipped_cores=() same_cores=()
    if [ "$with_cores" == 1 ]; then
        local gz_arch='' gz_name='' src_file=''
        case "$(uname -m)" in x86_64) gz_arch=amd64;; aarch64|arm64) gz_arch=arm64;; esac
        for name in bh rathole paqet gost haproxy; do
            path="engines/$name"; src_file="$source_dir/$path"
            # gost is also published as gost-linux-<arch>-2.11.5.gz (gzip of the binary): used when no plain file exists.
            gz_name=''; [ "$name" != gost ] || [ -z "$gz_arch" ] || gz_name="gost-linux-${gz_arch}-2.11.5.gz"
            if [ -n "$remote" ]; then
                mkdir -p "$work/scripts/engines" || return 1
                if ! mt_download "$(mt_cb_url "$remote/engines/$name")" "$src_file" 2>/dev/null; then
                    if [ -n "$gz_name" ] && mt_download "$(mt_cb_url "$remote/engines/$gz_name")" "$work/scripts/engines/$gz_name" 2>/dev/null \
                       && gzip -dc "$work/scripts/engines/$gz_name" > "$src_file" 2>/dev/null && [ -s "$src_file" ]; then :
                    else rm -f "$src_file"; skipped_cores+=("$name (not found in engines/)"); continue; fi
                fi
            elif [ ! -f "$src_file" ] && [ -n "$gz_name" ] && [ -f "$source_dir/engines/$gz_name" ]; then
                mkdir -p "$work/engines" || return 1
                src_file="$work/engines/$name"
                gzip -dc "$source_dir/engines/$gz_name" > "$src_file" 2>/dev/null || { skipped_cores+=("$name (cannot unpack $gz_name)"); continue; }
            fi
            if ! mt_valid_elf "$src_file"; then
                skipped_cores+=("$name (missing or not a valid ELF for this CPU)"); continue
            fi
            got_cores+=("$name")
            if cmp -s "$src_file" "$root/usr/local/bin/$name" 2>/dev/null; then same_cores+=("$name"); fi
            files+=("$src_file" "$root/usr/local/bin/$name" "$src_file" "$root/usr/bin/$name" "$src_file" "$root/root/mtunnel/$path")
        done
        if [ "${#skipped_cores[@]}" -gt 0 ]; then
            echo -e "  ${Y}● Engines skipped:${NC}" >&2
            for name in "${skipped_cores[@]}"; do echo -e "    ${Y}-${NC} $name" >&2; done
        fi
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
        local n_eng_total=5 n_eng_ok=0 n_eng_same=0 eng eng_same
        echo -e "\n  ${Y}● Engines report:${NC}"
        for eng in bh rathole paqet gost haproxy; do
            if [[ " ${got_cores[*]} " == *" $eng "* ]]; then
                eng_same=0; [[ " ${same_cores[*]} " == *" $eng "* ]] && eng_same=1
                if [ "$eng_same" == 1 ]; then
                    echo -e "  ${G}✓ ${eng}${NC} ${DIM}— already installed (up to date)${NC}"; n_eng_same=$((n_eng_same+1))
                else
                    echo -e "  ${G}✓ ${eng}${NC} ${DIM}— installed${NC}"; n_eng_ok=$((n_eng_ok+1))
                fi
            else
                echo -e "  ${R}✖ ${eng}${NC} ${DIM}— skipped${NC}" >&2
            fi
        done
        echo -e "  ${G}● Engines: ${n_eng_same} already up to date, ${n_eng_ok} newly installed, ${#skipped_cores[@]} skipped (total ${n_eng_total})${NC}"
    fi
    for name in "${owned_candidates[@]}"; do
        MTUNNEL_TEST_ROOT="$root" mt_owned_binary_register "$name" "$root/usr/local/bin/$name" || echo "Warning: Could not record $name ownership" >&2
    done
    if [ -z "$root" ]; then
        mt_installer_retire_legacy
    fi
    if [ "$want_prereqs" == 1 ]; then
        echo -e "\n  ${Y}● Installing prerequisites...${NC}"
        installer_install_prereqs "$remote" "$source_dir" "$work" || echo -e "  ${Y}● Some prerequisites were not installed (see above).${NC}" >&2
    fi
    if [ "$launch" == 1 ]; then
        echo -e "\n  ${G}● MTunnel Installation Complete! Launching Core Dashboard...${NC}\n"
    else echo -e "\n  ${G}● MTunnel Installation Complete!${NC}\n"; fi
    if [ "$with_cores" == 1 ] && [ -z "$root" ]; then
        while read -r target; do
            [ -z "$target" ] || systemctl restart "$target" || return 1
        done < <(systemctl list-units --type=service --state=active --no-legend --plain 'mrathole@*.service' 'mbackhaul@*.service' 'mpaqet@*.service' 'gost.service' 'haproxy.service' 2>/dev/null | awk '{print $1}')
    fi
    if [ "$launch" == 1 ]; then
        sleep 1.5
        rm -rf -- "$INSTALLER_WORK"; mt_installer_hdr_cleanup
        trap - EXIT
        # After "curl ... | bash" stdin is the exhausted pipe: give the dashboard the terminal.
        if [ ! -t 0 ] && { : </dev/tty; } 2>/dev/null; then exec "$root/usr/bin/mtunnel" </dev/tty; fi
        exec "$root/usr/bin/mtunnel"
    fi
}
trap 'mt_installer_hdr_cleanup' EXIT
installer_main "$@"
