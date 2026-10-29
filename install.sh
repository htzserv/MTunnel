#!/bin/bash
# MTunnel standalone installer: local source tree or HTTPS bootstrap (v1.5.5).
MODULE_VERSION="1.5.6"
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
    else
        # Never source code from the current working directory implicitly when
        # running as root. Use the script's own bundle, an explicit --local tree,
        # or fetch the core from the selected HTTPS source.
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
        fi
        if [[ "$rc" != 0 ]] && command -v wget >/dev/null 2>&1; then
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
DEFAULT_REMOTE="${MTUNNEL_REPO_URL:-${MTUNNEL_GITHUB_BASE:-https://raw.githubusercontent.com/htzserv/MTunnel/main}}"
MIRROR_REMOTE="${MTUNNEL_MIRROR_BASE:-https://c107328.parspack.net/c107328/MTunnel}"


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


















B='\033[1;37m'; G='\033[1;32m'; LG='\033[0;92m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
FR='\033[1;33m'

# This installer has work to do after the script progress bar reaches 100%.
# Print every blocking stage instead of appearing frozen on the last module.
installer_stage() {
    printf '\n  %b● %s%b\n' "$Y" "$1" "$NC" >&2
}

# Bounded HTTPS download for interactive installer operations.  The shared
# mt_download helper can take several minutes *per file* on a bad connection.
# A failed transfer does not replace an already-staged file.
installer_fetch() {
    local url="$1" dest="$2" label="${3:-${1##*/}}" quiet="${4:-0}" tmp rc=1
    local max_time="${MT_INSTALL_FETCH_TIMEOUT:-35}" conn_time="${MT_INSTALL_CONNECT_TIMEOUT:-8}"
    [[ "$max_time" =~ ^[0-9]+$ ]] && ((max_time >= 5 && max_time <= 180)) || max_time=35
    [[ "$conn_time" =~ ^[0-9]+$ ]] && ((conn_time >= 2 && conn_time <= 40)) || conn_time=8
    [[ "$url" == https://* ]] || { printf '  Download requires HTTPS: %s\n' "$label" >&2; return 1; }
    tmp=$(mktemp "${dest}.download.XXXXXX") || return 1
    [ "$quiet" = 1 ] || printf '  %b⟳%b %b%s%b\n' "$C" "$NC" "$W" "$label" "$NC" >&2
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --proto '=https' --proto-redir '=https' \
            --connect-timeout "$conn_time" --max-time "$max_time" \
            --retry 1 --retry-delay 1 -o "$tmp" "$url" 2>/dev/null && rc=0
    fi
    if [[ "$rc" != 0 ]] && command -v wget >/dev/null 2>&1; then
        wget -q --https-only --timeout="$conn_time" --tries=2 -O "$tmp" "$url" 2>/dev/null && rc=0
    fi
    if [ "$rc" = 0 ] && [ -s "$tmp" ] && mv -f -- "$tmp" "$dest"; then
        [ "$quiet" = 1 ] || printf '  %b✓%b %b%s%b\n' "$G" "$NC" "$W" "$label" "$NC" >&2
        return 0
    fi
    rm -f -- "$tmp"
    if [ "$quiet" != 1 ]; then
        printf '  %b✖%b %b%s%b %b— unavailable or download timed out%b\n' "$R" "$NC" "$W" "$label" "$NC" "$DIM" "$NC" >&2
    fi
    return 1
}

# Clean, fixed-column progress row used by all three installer stages.
# Colors: green status icon, white name, yellow version/build tag,
# white filled progress and dim unfilled progress.
draw_progress() {
    local n="$1" total="$2" text="$3" ver="${4:-}" state="${5:-ok}" width=26
    [[ "$total" =~ ^[0-9]+$ ]] && [ "$total" -gt 0 ] || total=1
    local percent=$(( n * 100 / total )) filled empty bar empty_bar icon icon_col ver_text=''
    ((percent > 100)) && percent=100
    filled=$(( percent * width / 100 )); empty=$(( width - filled ))
    bar=$(printf "%${filled}s" "" | tr ' ' '#')
    empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')

    if [ -n "$ver" ] && [ "$ver" != "Unknown" ]; then
        case "$ver" in sha:*) ver_text="(${ver})";; *) ver_text="(v${ver})";; esac
    fi
    case "$state" in
        skip) icon='↷'; icon_col="$Y";;
        fail) icon='✖'; icon_col="$R";;
        *)    icon='✓'; icon_col="$G";;
    esac

    tput civis 2>/dev/null || true
    printf "\r\033[K  %b%s%b %b%-16.16s%b %b%-20.20s%b %b[%b%s%b%s%b] %b%3d%%%b" \
        "$icon_col" "$icon" "$NC" \
        "$W" "$text" "$NC" \
        "$Y" "$ver_text" "$NC" \
        "$W" "$W" "$bar" "$DIM" "$empty_bar" "$NC" \
        "$W" "$percent" "$NC"
    tput cnorm 2>/dev/null || true
}

# One compact row per install phase. The same row is redrawn from 0% to 100%;
# item-level details are intentionally reserved for the final report.
draw_stage_progress() {
    local n="$1" total="$2" text="$3" state="${4:-run}" width=26
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
    printf "\r\033[K  %b%s%b %b%-16.16s%b %b[%b%s%b%s%b] %b%3d%%%b" \
        "$icon_col" "$icon" "$NC" \
        "$W" "$text" "$NC" \
        "$W" "$W" "$bar" "$DIM" "$empty_bar" "$NC" \
        "$W" "$percent" "$NC"
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
#   1-3  official GitHub : full package / scripts + tunnel cores / scripts only
#   4-6  Iranian mirror  : full package / scripts + tunnel cores / scripts only
#   7    uninstall MTunnel from this system          0  quit
# One menu entry (name only, one per line).
_wiz_item() {
    case "$1" in
        1|4) echo -e "    ${Y}[$1]${NC} ${W}Full package${NC}";;
        2|5) echo -e "    ${Y}[$1]${NC} ${W}Scripts + tunnel cores${NC}";;
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
        local cron_backup_dir cron_backup filtered_cron
        cron_tmp=$(mktemp "${TMPDIR:-/tmp}/uninstall-cron.XXXXXX") || cron_tmp=''
        if [ -n "$cron_tmp" ] && crontab -l >"$cron_tmp" 2>/dev/null; then
            cron_backup_dir=/var/backups/mtunnel
            if mkdir -p "$cron_backup_dir" && chmod 700 "$cron_backup_dir"; then
                cron_backup="$cron_backup_dir/root-crontab-$(date +%Y%m%d-%H%M%S)"
                if cp -p -- "$cron_tmp" "$cron_backup"; then
                    filtered_cron="${cron_tmp}.filtered"
                    awk '!/mbackhaul@|mrathole@|mpaqet@|\/usr\/bin\/mgre([[:space:]]|$)|\/usr\/bin\/mxlan([[:space:]]|$)|\/usr\/local\/bin\/mporter-watchdog([[:space:]]|$)/' "$cron_tmp" > "$filtered_cron" && {
                        if crontab "$filtered_cron"; then
                            echo "  Root crontab updated; backup saved to $cron_backup"
                        else
                            echo 'Warning: could not update root crontab; original backup was preserved.' >&2
                        fi
                    }
                    rm -f -- "$filtered_cron"
                else
                    echo 'Warning: crontab backup failed; root crontab was left untouched.' >&2
                fi
            else
                echo 'Warning: could not create crontab backup directory; root crontab was left untouched.' >&2
            fi
        fi
        [ -z "$cron_tmp" ] || rm -f -- "$cron_tmp"
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

# Run APT with a live status line. The progress bar is intentionally not left at 0%
# while APT is downloading/unpacking packages with its output redirected to a log.
installer_run_apt_visible() {
    local log="$1" limit="$2" pid rc line
    shift 2
    if command -v timeout >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive timeout --signal=TERM --kill-after=5s "${limit}s" "$@" >"$log" 2>&1 &
    else
        DEBIAN_FRONTEND=noninteractive "$@" >"$log" 2>&1 &
    fi
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        line=$(tail -n 1 "$log" 2>/dev/null | tr '\r' ' ' | tr -s '[:space:]' ' ' | cut -c1-100)
        [ -n "$line" ] || line="Waiting for APT / package manager..."
        printf '\r\033[K  %b●%b APT: %s' "$Y" "$NC" "$line" >&2
        sleep 1
    done
    wait "$pid"; rc=$?
    printf '\r\033[K\n' >&2
    return "$rc"
}

# Installs the .deb prerequisites of a full package: from the remote prereqs/ folder or a local prereqs/ folder.
# Already-installed packages are reported as such (not as errors) and are not downloaded again.
# Validate the manifest as data; no filename-only or unsigned fallback.
installer_manifest_hash() {
    local manifest="$1" wanted="$2" line hash name result=''
    [ -f "$manifest" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
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

installer_install_prereqs() {
    local pkg cmd ver state idx=0 apt_log=''
    local -a missing=() packages=(ca-certificates curl wget python3 openssl iperf3 iputils-ping iptables iproute2 util-linux gzip coreutils jq unzip tar procps cron nano)
    local -A checks=(
        [ca-certificates]='cert' [curl]='curl' [wget]='wget'
        [python3]='python3' [openssl]='openssl' [iperf3]='iperf3'
        [iputils-ping]='ping' [iptables]='iptables' [iproute2]='ip'
        [util-linux]='flock' [gzip]='gzip' [coreutils]='sha256sum'
        [jq]='jq' [unzip]='unzip' [tar]='tar'
        [procps]='ps' [cron]='cron' [nano]='nano'
    )
    local -A was_missing=()
    INSTALL_REPORT_PREREQS=()

    if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
        echo 'APT/dpkg not found. Automatic prerequisite installation requires Debian/Ubuntu.' >&2
        return 1
    fi

    installer_stage "Checking prerequisite packages"

    for pkg in "${packages[@]}"; do
        cmd="${checks[$pkg]}"
        if { [ "$cmd" = cert ] && [ -s /etc/ssl/certs/ca-certificates.crt ]; } || command -v "$cmd" >/dev/null 2>&1; then
            was_missing["$pkg"]=0
        else
            was_missing["$pkg"]=1
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        apt_log=$(mktemp "${TMPDIR:-/tmp}/mtunnel-apt.XXXXXXXX") || return 1
        local apt_update_log='' apt_error_log="$apt_log"
        local -a apt_cmd=(apt-get -o DPkg::Lock::Timeout=45 \
            -o Acquire::Retries=1 -o Acquire::http::Timeout=15 \
            -o Acquire::https::Timeout=15 -y install)
        printf '  Installing %s missing prerequisite package(s) with APT...\n' "${#missing[@]}" >&2
        if ! installer_run_apt_visible "$apt_log" 240 "${apt_cmd[@]}" "${missing[@]}"; then
            # A fresh VPS may have stale/empty package lists. Refresh once only when
            # APT explicitly cannot resolve a package, then retry the install once.
            if grep -Eqi 'Unable to locate package|no installation candidate|has no installation candidate' "$apt_log"; then
                apt_update_log=$(mktemp "${TMPDIR:-/tmp}/mtunnel-apt-update.XXXXXXXX") || { rm -f "$apt_log"; return 1; }
                local -a update_cmd=(apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 update)
                printf '  APT package lists appear stale; refreshing package indexes and retrying once...\n' >&2
                if installer_run_apt_visible "$apt_update_log" 180 "${update_cmd[@]}"; then
                    apt_error_log="$apt_log"
                    if ! installer_run_apt_visible "$apt_log" 240 "${apt_cmd[@]}" "${missing[@]}"; then
                        draw_stage_progress 0 "${#packages[@]}" "Prerequisites" fail; printf '\n'
                        echo 'APT installation failed after refreshing package indexes. Last APT messages:' >&2
                        tail -n 15 "$apt_log" >&2 || true
                        rm -f "$apt_log" "$apt_update_log"
                        return 1
                    fi
                else
                    apt_error_log="$apt_update_log"
                    draw_stage_progress 0 "${#packages[@]}" "Prerequisites" fail; printf '\n'
                    echo 'APT could not refresh package indexes. Check network access and /etc/apt/sources.list*. Last APT messages:' >&2
                    tail -n 15 "$apt_error_log" >&2 || true
                    rm -f "$apt_log" "$apt_update_log"
                    return 1
                fi
            else
                draw_stage_progress 0 "${#packages[@]}" "Prerequisites" fail; printf '\n'
                echo 'APT installation failed or timed out. Last APT messages:' >&2
                tail -n 15 "$apt_log" >&2 || true
                rm -f "$apt_log"
                return 1
            fi
        fi
        rm -f "$apt_log"
        [ -z "$apt_update_log" ] || rm -f "$apt_update_log"
    fi

    for pkg in "${packages[@]}"; do
        idx=$((idx+1)); cmd="${checks[$pkg]}"; ver=$(installer_pkg_version "$pkg")
        if { [ "$cmd" = cert ] && [ -s /etc/ssl/certs/ca-certificates.crt ]; } || command -v "$cmd" >/dev/null 2>&1; then
            if [ "${was_missing[$pkg]:-0}" = 1 ]; then state='newly installed'; else state='already installed'; fi
            INSTALL_REPORT_PREREQS+=("$pkg|${ver:-Unknown}|$state")
            draw_stage_progress "$idx" "${#packages[@]}" "Prerequisites"
        else
            INSTALL_REPORT_PREREQS+=("$pkg|${ver:-Unknown}|failed after APT")
            draw_stage_progress "$idx" "${#packages[@]}" "Prerequisites" fail
            printf '\n'
            return 1
        fi
    done
    printf '\n'
}

installer_main() {
    local source_dir='' root='' with_cores=0 launch=1 remote='' work path name target item
    local scripts_only=0 want_prereqs=0 do_uninstall=0
    local script_file="${BASH_SOURCE[0]:-}" script_dir=''
    [[ ! -f "$script_file" ]] || script_dir=$(cd -- "$(dirname -- "$script_file")" && pwd) || return 1
    local -a modules=(main:main.sh mporter:mporter.sh msmart:tunnels/msmart.sh linktest:linktest.sh mgre:tunnels/mgre.sh mxlan:tunnels/mxlan.sh mrathole:tunnels/mrathole.sh mbackhaul:tunnels/mbackhaul.sh mpaqet:tunnels/mpaqet.sh mdoctor:mdoctor.sh mmirror:mirror.sh)
    local -a active_modules=()
    local -a files=()
    local current=0 mod_ver installed_ver script_state
    local -A engine_versions=() engine_skips=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --local) [ "$#" -ge 2 ] || { echo '--local needs a directory.' >&2; return 1; }; source_dir="$2"; remote=''; shift 2;;
            --root) [ "$#" -ge 2 ] || { echo '--root needs an absolute directory.' >&2; return 1; }; [[ "$2" == /* && "$2" != / ]] || { echo 'Unsafe --root path.' >&2; return 1; }; root="${2%/}"; launch=0; shift 2;;
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
    if [ "$do_uninstall" == 1 ]; then
        [ -z "$root" ] || { echo '--uninstall cannot be combined with --root.' >&2; return 1; }
        installer_uninstall; return $?
    fi
    if [ -z "$source_dir" ] && [ -z "$remote" ]; then
        if [ -n "$script_dir" ] && [ -f "$script_dir/main.sh" ]; then source_dir="$script_dir"
        elif [ -n "$script_dir" ] && [ -f "$PWD/main.sh" ]; then source_dir="$PWD"
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
            current=$((current+1)); name="${item%%:*}"
            mod_ver=$(installer_script_version "$work/scripts/$path")
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
    if [ "$with_cores" == 1 ]; then
        local gz_arch='' gz_name='' src_file='' engine_manifest engine_input eng_tag='' skip_reason='' eng_current=0
        draw_stage_progress 0 6 "Engines"
        engine_manifest="$source_dir/engines/manifest.txt"
        if [ -n "$remote" ]; then
            mkdir -p "$work/scripts/engines" || return 1
            if ! installer_fetch "$(mt_cb_url "$remote/engines/manifest.txt")" "$engine_manifest" 'engines/manifest.txt' 1; then
                echo 'Cannot download the tunnel-engine manifest.' >&2
                return 1
            fi
        fi
        case "$(uname -m)" in x86_64) gz_arch=amd64;; aarch64|arm64) gz_arch=arm64;; esac
        for name in bh rathole paqet gost haproxy realm; do
            path="engines/$name"; src_file="$source_dir/$path"; engine_input="$name"; skip_reason=''
            gz_name=''; [ "$name" != gost ] || [ -z "$gz_arch" ] || gz_name="gost-linux-${gz_arch}-2.11.5.gz"

            if [ -n "$remote" ]; then
                mkdir -p "$work/scripts/engines" || return 1
                if [ -f "$root/usr/local/bin/$name" ] && mt_valid_elf "$root/usr/local/bin/$name" &&
                   installer_verify_package "$engine_manifest" "$root/usr/local/bin/$name" "$name" >/dev/null 2>&1; then
                    src_file="$root/usr/local/bin/$name"
                elif ! installer_fetch "$(mt_cb_url "$remote/engines/$name")" "$src_file" "engines/$name" 1; then
                    if [ -n "$gz_name" ] && installer_fetch "$(mt_cb_url "$remote/engines/$gz_name")" "$work/scripts/engines/$gz_name" "engines/$gz_name" 1; then
                        installer_verify_package "$engine_manifest" "$work/scripts/engines/$gz_name" "$gz_name" || return 1
                        gzip -dc "$work/scripts/engines/$gz_name" > "$src_file" || return 1
                        engine_input="$gz_name"
                    else
                        rm -f "$src_file"
                        skip_reason='not available at selected source'
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
                draw_stage_progress "$eng_current" 6 "Engines"
                continue
            fi

            got_cores+=("$name")
            if cmp -s "$src_file" "$root/usr/local/bin/$name" 2>/dev/null; then same_cores+=("$name"); fi
            eng_tag=$(installer_file_build_tag "$src_file")
            if [[ "$engine_input" =~ ^gost-linux-[^-]+-([0-9.]+)\.gz$ ]]; then eng_tag="${BASH_REMATCH[1]}"; fi
            engine_versions["$name"]="${eng_tag:-Unknown}"
            files+=("$src_file" "$root/usr/local/bin/$name" "$src_file" "$root/usr/bin/$name" "$src_file" "$root/root/mtunnel/$path")
            draw_stage_progress "$eng_current" 6 "Engines"
        done
        printf '\n'
        if [ "${#got_cores[@]}" -eq 0 ]; then
            echo 'No tunnel engine binary could be downloaded and verified from the selected source. Nothing was installed; check engines/manifest.txt and the engine files.' >&2
            return 1
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

    # Install prerequisites before committing scripts/engines. If APT fails, the
    # existing MTunnel files remain untouched instead of leaving a half-installed bundle.
    if [ "$want_prereqs" == 1 ]; then
        installer_install_prereqs "$remote" "$source_dir" "$work" || {
            echo 'Prerequisites failed; existing scripts and engines were preserved.' >&2; return 1;
        }
    fi

    mt_install_files 755 "${files[@]}" || { echo 'Install failed; committed files were rolled back.' >&2; return 1; }

    if [ "$with_cores" == 1 ]; then
        local eng eng_state
        for eng in bh rathole paqet gost haproxy realm; do
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
    # Finish any post-install service work before showing the final report, so
    # pressing Enter/any key leaves the report and launches immediately.
    if [ "$with_cores" == 1 ] && [ -z "$root" ]; then
        while read -r target; do
            [ -z "$target" ] || systemctl restart "$target" || return 1
        done < <(systemctl list-units --type=service --state=active --no-legend --plain 'mrathole@*.service' 'mbackhaul@*.service' 'mpaqet@*.service' 'gost.service' 'haproxy.service' 2>/dev/null | awk '{print $1}')
    fi

    installer_print_report

    echo -e "\n  ${G}● MTunnel Installation Complete!${NC}\n"
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
