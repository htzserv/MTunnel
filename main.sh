#!/bin/bash
# MTunnel — main dashboard for tunnel management, status, and synchronization (v1.4.9).
MODULE_VERSION="1.4.9"
MTUNNEL_REQUIRED_CORE_API=1
MTUNNEL_REQUIRED_LAYOUT_REV=2
umask 077
# MTUNNEL_COMMON_LOADER -- common API 1, required by this module.
# Source next to a checkout first, or from the system-wide installed location.
# Loads the shared core; the update path downloads scripts and verifies them before install.
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
unset -f mt_load_common
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
# v1.4.6 helper: defined here only when an older installed shared core lacks it.
if ! declare -F mt_version_newer >/dev/null 2>&1; then
mt_version_newer() { # true only when $1 is strictly newer than $2 (pure bash)
    local a="${1:-}" b="${2:-}" i x y
    local -a A B
    [[ "$a" =~ ^[0-9]+(\.[0-9]+)*([.-][A-Za-z0-9.-]+)?$ ]] || return 1
    [[ "$b" =~ ^[0-9]+(\.[0-9]+)*([.-][A-Za-z0-9.-]+)?$ ]] || b=0
    a="${a%%-*}"; b="${b%%-*}"
    IFS=. read -ra A <<< "$a"; IFS=. read -ra B <<< "$b"
    for ((i=0; i<${#A[@]} || i<${#B[@]}; i++)); do
        x="${A[i]:-0}"; y="${B[i]:-0}"
        [[ "$x" =~ ^[0-9]+$ ]] || x=0; [[ "$y" =~ ^[0-9]+$ ]] || y=0
        (( 10#$x > 10#$y )) && return 0
        (( 10#$x < 10#$y )) && return 1
    done
    return 1
}
fi
if [ "$EUID" != 0 ]; then echo "Run MTunnel with sudo." >&2; exit 1; fi
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
FR='\033[1;33m'   # frame colour: gold (double-line frames and menu tree connectors)
MTUNNEL_PATH="/usr/bin/mtunnel"
REPO_SCRIPTS="$MTUNNEL_GITHUB_BASE"
MIRROR_SCRIPTS="$MTUNNEL_MIRROR_BASE"
MIRROR_PACKAGES="$MTUNNEL_MIRROR_BASE"   # repo base; engines/ and prereqs/ are appended per file
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
UPDATE_FILE="$SECURE_TMP/.modules_update_status"
declare -A MOD_MAP=(
    ["main"]="main.sh"
    ["mporter"]="mporter.sh"
    ["mgre"]="tunnels/mgre.sh"
    ["mxlan"]="tunnels/mxlan.sh"
    ["mrathole"]="tunnels/mrathole.sh"
    ["mbackhaul"]="tunnels/mbackhaul.sh"
    ["mpaqet"]="tunnels/mpaqet.sh"
    ["mdoctor"]="mdoctor.sh"
    ["linktest"]="linktest.sh"
    ["mmirror"]="mirror.sh"
)
ALL_MODULES=("main" "mporter" "linktest" "mgre" "mxlan" "mrathole" "mbackhaul" "mpaqet" "mdoctor" "mmirror")
# Every shell component can also be updated independently from GitHub/mirror,
# a direct link, or Manual Code Paste. Bundle sync remains available separately.
declare -A COMPONENT_MAP=(
    ["main"]="main.sh"
    ["mporter"]="mporter.sh"
    ["mgre"]="tunnels/mgre.sh"
    ["mxlan"]="tunnels/mxlan.sh"
    ["mrathole"]="tunnels/mrathole.sh"
    ["mbackhaul"]="tunnels/mbackhaul.sh"
    ["mpaqet"]="tunnels/mpaqet.sh"
    ["mdoctor"]="mdoctor.sh"
    ["linktest"]="linktest.sh"
    ["mmirror"]="mirror.sh"
    ["common"]="core/common.sh"
    ["install"]="install.sh"
)
EDITABLE_COMPONENTS=("main" "mporter" "linktest" "mgre" "mxlan" "mrathole" "mbackhaul" "mpaqet" "mdoctor" "mmirror" "common" "install")
UPDATE_COMPONENTS=("main" "mporter" "linktest" "mgre" "mxlan" "mrathole" "mbackhaul" "mpaqet" "mdoctor" "mmirror" "common" "install")
ALL_PACKAGES=(
    "bh"
    "rathole"
    "paqet"
    "gost"
    "haproxy"
    "realm"
    "backhaul_linux_amd64.tar.gz"
    "rathole-x86_64-unknown-linux-gnu.zip"
    "paqet-linux-amd64-v1.0.0-alpha.21.tar.gz"
    "gost-linux-amd64-2.11.5.gz"
    "realm-x86_64-unknown-linux-musl.tar.gz"
    "cron_3.0pl1-184ubuntu2_amd64.deb"
    "curl_8.5.0-2ubuntu10.11_amd64.deb"
    "gzip_1.12-1ubuntu3.2_amd64.deb"
    "haproxy_2.8.16-0ubuntu0.24.04.3_amd64.deb"
    "libiperf0_3.20-2.1_amd64.deb"
    "iperf3_3.16-1build2_amd64.deb"
    "iproute2_6.1.0-1ubuntu6.4_amd64.deb"
    "jq_1.7.1-3ubuntu0.24.04.2_amd64.deb"
    "qrencode_4.1.1-1build2_amd64.deb"
    "socat_1.8.0.0-4ubuntu0.1_amd64.deb"
    "wget_1.21.4-1ubuntu4.1_amd64.deb"
)
declare -A BIN_VERSIONS=(
    ["bh"]="0.7.2"
    ["rathole"]="0.5.0"
    ["paqet"]="1.0.0"
    ["gost"]="2.11.5"
    ["haproxy"]="2.8.16"
)
mkdir -p "$LOCAL_DIR/engines" "$LOCAL_DIR/prereqs" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null
if [[ ! -x "$MTUNNEL_PATH" ]]; then
    cp "$0" "$MTUNNEL_PATH" 2>/dev/null
    chmod +x "$MTUNNEL_PATH" 2>/dev/null
fi
MAIN_PID=$$
NEED_REFRESH=false
NEED_LIVE_HEADER_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1
trap 'NEED_LIVE_HEADER_REFRESH=true' SIGUSR2
UPDATE_CHECK_INTERVAL=120     # 2 min: GitHub + mirror are both checked each round
UPDATE_FIRST_CHECK_DELAY=0    # first check starts immediately (runs in the background, never blocks the UI)
UPDATE_HEAD_BYTES=4095        # MODULE_VERSION sits in the first ~2.2 KB of every component (mporter is the largest offset)
STATS_CHECK_INTERVAL=15
# Shared-core fallbacks: a box whose /usr/lib/mtunnel/common.sh predates the socket snapshot keeps working.
if ! declare -F mt_ss_snapshot_begin >/dev/null 2>&1; then mt_ss_snapshot_begin() { return 1; }; fi
if ! declare -F mt_ss_snapshot_end >/dev/null 2>&1; then mt_ss_snapshot_end() { return 0; }; fi
component_local_version_for_watch() {
    local mod="$1" file=''
    case "$mod" in
        main) file="$MTUNNEL_PATH";;
        common) file=/usr/lib/mtunnel/common.sh;;
        install) file="$LOCAL_DIR/install.sh";;
        *) file="/usr/bin/$mod";;
    esac
    [ -f "$file" ] || file="$LOCAL_DIR/${COMPONENT_MAP[$mod]}"
    if [ "$mod" == common ]; then
        sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$file" 2>/dev/null | head -n1
    else
        sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$file" 2>/dev/null | head -n1
    fi
}
UPD_SRC_GITHUB="$SECURE_TMP/.upd_src_github"      # first line status|ok/down, then module:remote_version
UPD_SRC_MIRROR="$SECURE_TMP/.upd_src_mirror"
UPD_NEW_GITHUB="$SECURE_TMP/.upd_new_github"      # module:current:remote  (only strictly NEWER versions)
UPD_NEW_MIRROR="$SECURE_TMP/.upd_new_mirror"
UPD_LAST_FILE="$SECURE_TMP/.upd_last"
upd_clear() { : > "$UPDATE_FILE"; : > "$UPD_NEW_GITHUB"; : > "$UPD_NEW_MIRROR"; }
upd_parse_version() { # file -> version of MODULE_VERSION / MTUNNEL_RELEASE_VERSION
    local f="$1" line n=0
    [ -s "$f" ] || return 1
    while IFS= read -r line && [ $((n++)) -lt 150 ]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^(MODULE_VERSION|MTUNNEL_RELEASE_VERSION)=\"([0-9][0-9.]*)\"$ ]]; then printf '%s' "${BASH_REMATCH[2]}"; return 0; fi
    done < "$f"
    return 1
}
# Fetch the head of every component from ONE source. One parallel curl when supported
# (all files in a single process), otherwise a short sequential loop that gives up
# after two consecutive network failures so a blocked source cannot stall anything.
upd_fetch_source() { # base outfile
    local base="${1%/}" out="$2" dir mod v rc=0 fails=0 got=0 line
    dir=$(mktemp -d "$SECURE_TMP/.upd.XXXXXX") || return 1
    if command -v curl >/dev/null 2>&1; then
        local -a args=(-sL -f -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' --connect-timeout 4 --max-time 12 -r "0-${UPDATE_HEAD_BYTES}" --parallel --parallel-max 6)
        for mod in "${UPDATE_COMPONENTS[@]}"; do args+=(-o "$dir/$mod" "$(mt_cb_url "$base/${COMPONENT_MAP[$mod]}")"); done
        curl "${args[@]}" >/dev/null 2>&1 || rc=$?
        if [ "$rc" = 2 ]; then   # curl too old for --parallel
            for mod in "${UPDATE_COMPONENTS[@]}"; do
                curl -sL -f -H 'Cache-Control: no-cache' -r "0-${UPDATE_HEAD_BYTES}" --connect-timeout 4 --max-time 8 -o "$dir/$mod" "$(mt_cb_url "$base/${COMPONENT_MAP[$mod]}")" >/dev/null 2>&1 \
                    && fails=0 || { fails=$((fails+1)); [ "$fails" -ge 2 ] && break; }
            done
        fi
    elif command -v wget >/dev/null 2>&1; then
        for mod in "${UPDATE_COMPONENTS[@]}"; do
            wget -q --timeout=6 --header="Range: bytes=0-${UPDATE_HEAD_BYTES}" --header="Cache-Control: no-cache" -O "$dir/$mod" "$(mt_cb_url "$base/${COMPONENT_MAP[$mod]}")" >/dev/null 2>&1 \
                && fails=0 || { fails=$((fails+1)); [ "$fails" -ge 2 ] && break; }
        done
    fi
    : > "$out.new"
    for mod in "${UPDATE_COMPONENTS[@]}"; do
        v=$(upd_parse_version "$dir/$mod") || continue
        printf '%s:%s\n' "$mod" "$v" >> "$out.new"; got=1
    done
    if [ "$got" = 1 ]; then line='status|ok'; else line='status|down'; fi
    { printf '%s\n' "$line"; cat "$out.new"; } > "$out.tmp" && mv -f "$out.tmp" "$out"
    rm -f "$out.new"; rm -rf "$dir"
}
upd_src_version() { # srcfile module
    local m v
    [ -r "$1" ] || return 1
    while IFS=: read -r m v; do [ "$m" = "$2" ] && [ -n "$v" ] && { printf '%s' "$v"; return 0; }; done < "$1"
    return 1
}
# Build UPDATE_FILE (module:current:best:sources) and the per-source "newer" lists.
upd_rebuild_status() {
    local mod cur gv mv best srcs
    : > "$UPDATE_FILE.new"; : > "$UPD_NEW_GITHUB.new"; : > "$UPD_NEW_MIRROR.new"
    for mod in "${UPDATE_COMPONENTS[@]}"; do
        cur=$(component_local_version_for_watch "$mod"); [ -n "$cur" ] || cur='0.0.0'
        gv=$(upd_src_version "$UPD_SRC_GITHUB" "$mod") || gv=''
        mv=$(upd_src_version "$UPD_SRC_MIRROR" "$mod") || mv=''
        best=''; srcs=''
        if [ -n "$gv" ] && mt_version_newer "$gv" "$cur"; then
            printf '%s:%s:%s\n' "$mod" "$cur" "$gv" >> "$UPD_NEW_GITHUB.new"; best="$gv"; srcs='GitHub'
        fi
        if [ -n "$mv" ] && mt_version_newer "$mv" "$cur"; then
            printf '%s:%s:%s\n' "$mod" "$cur" "$mv" >> "$UPD_NEW_MIRROR.new"
            if [ -z "$best" ]; then best="$mv"; srcs='Mirror'
            elif mt_version_newer "$mv" "$best"; then best="$mv"; srcs='Mirror'
            else srcs='GitHub+Mirror'; fi
        fi
        [ -z "$best" ] || printf '%s:%s:%s:%s\n' "$mod" "$cur" "$best" "$srcs" >> "$UPDATE_FILE.new"
    done
    mv -f "$UPD_NEW_GITHUB.new" "$UPD_NEW_GITHUB"; mv -f "$UPD_NEW_MIRROR.new" "$UPD_NEW_MIRROR"
    mv -f "$UPDATE_FILE.new" "$UPDATE_FILE"
}
check_all_updates_round() {
    local before after p1 p2
    before=$(cat "$UPDATE_FILE" "$UPD_SRC_GITHUB" "$UPD_SRC_MIRROR" 2>/dev/null)
    # GitHub and the mirror are queried at the same time: a blocked source never delays the other.
    upd_fetch_source "$REPO_SCRIPTS" "$UPD_SRC_GITHUB" & p1=$!
    upd_fetch_source "$MIRROR_SCRIPTS" "$UPD_SRC_MIRROR" & p2=$!
    wait "$p1" "$p2" 2>/dev/null
    upd_rebuild_status
    printf '%s\n' "${EPOCHSECONDS:-0}" > "$UPD_LAST_FILE" 2>/dev/null
    after=$(cat "$UPDATE_FILE" "$UPD_SRC_GITHUB" "$UPD_SRC_MIRROR" 2>/dev/null)
    # Repaint the menus only when something really changed.
    [ "$before" == "$after" ] || kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
}
update_watcher_loop() {
    [ "$UPDATE_FIRST_CHECK_DELAY" -le 0 ] || sleep "$UPDATE_FIRST_CHECK_DELAY"
    while true; do
        check_all_updates_round
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
WATCHER_PID=""
if [[ "${1:-}" != --* ]]; then update_watcher_loop & WATCHER_PID=$!; fi
format_bytes_speed() {
    local b=$1
    if [ -z "$b" ] || [ "$b" -le 0 ] 2>/dev/null; then echo "0 B/s"; return; fi
    if [ "$b" -lt 1024 ]; then 
        echo "${b} B/s"
    elif [ "$b" -lt 1048576 ]; then 
        local kb=$(( b / 1024 ))
        if [ "$kb" -lt 100 ]; then awk -v v="$b" 'BEGIN {printf "%.1f KB/s", v/1024}'
        else echo "${kb} KB/s"; fi
    elif [ "$b" -lt 1073741824 ]; then 
        local mb=$(( b / 1048576 ))
        if [ "$mb" -lt 100 ]; then awk -v v="$b" 'BEGIN {printf "%.1f MB/s", v/1048576}'
        else echo "${mb} MB/s"; fi
    else 
        awk -v v="$b" 'BEGIN {printf "%.1f GB/s", v/1073741824}'
    fi
}
# Host facts that never change are read once. The per-cycle stats use shell builtins wherever possible
# (no grep/awk/cat/date forks every 5 s) and the default-route / IPv6 lookups are refreshed once a minute.
MT_CPU_CORES=""; MT_DEF_DEV=""; MT_DEF_DEV_TS=0; MT_V6_STATUS="OFF"; MT_V6_TS=0

mt_fmt_kb_gib() {  # KiB -> "12.3G" (one decimal, integer maths only)
    local t=$(( $1 * 10 / 1048576 ))
    printf '%d.%dG' "$(( t / 10 ))" "$(( t % 10 ))"
}

collect_system_vitals() {
    local sys_target="$SECURE_TMP/.main_sys_stats.tmp"
    local now_ts="${EPOCHSECONDS:-$(date +%s)}"

    if [ -z "$MT_CPU_CORES" ]; then
        MT_CPU_CORES=$(nproc 2>/dev/null)
        [ -z "$MT_CPU_CORES" ] && MT_CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
        [ -z "$MT_CPU_CORES" ] && MT_CPU_CORES=1
    fi
    local cpu_cores=$MT_CPU_CORES

    # CPU: /proc/stat is read directly; its first line is the aggregate "cpu" line.
    local cpu_pct=5 label u n s i io ir st _rest
    if read -r label u n s i io ir st _rest < /proc/stat 2>/dev/null; then
        local cur_idle=$(( i + io ))
        local cur_total=$(( u + n + s + i + io + ir + st ))
        if [ -f "$SECURE_TMP/.cpu_last" ]; then
            local p_idle p_total d_idle d_total
            read -r p_idle p_total < "$SECURE_TMP/.cpu_last"
            d_idle=$(( cur_idle - p_idle ))
            d_total=$(( cur_total - p_total ))
            cpu_pct=0
            if [ "$d_total" -gt 0 ]; then
                cpu_pct=$(( (d_total - d_idle) * 100 / d_total ))
                [ "$cpu_pct" -lt 0 ] && cpu_pct=0
                [ "$cpu_pct" -gt 100 ] && cpu_pct=100
            fi
        fi
        echo "$cur_idle $cur_total" > "$SECURE_TMP/.cpu_last"
    fi

    # Memory: one pass over /proc/meminfo with the read builtin.
    local r_used="0G" r_total="0G" r_pct=0 mt='' ma='' mf='' k v _m
    while read -r k v _m; do
        case "$k" in
            MemTotal:) mt=$v;;
            MemAvailable:) ma=$v;;
            MemFree:) mf=$v;;
        esac
    done < /proc/meminfo 2>/dev/null
    [ -n "$ma" ] || ma=$mf
    if [[ "$mt" =~ ^[0-9]+$ ]] && [[ "$ma" =~ ^[0-9]+$ ]] && [ "$mt" -gt 0 ]; then
        local mu=$(( mt - ma ))
        r_pct=$(( mu * 100 / mt ))
        if [ "$mu" -lt 1048576 ]; then r_used="$(( (mu + 512) / 1024 ))M"; else r_used=$(mt_fmt_kb_gib "$mu"); fi
        r_total=$(mt_fmt_kb_gib "$mt")
    fi

    # Default-route device changes rarely: look it up at most once a minute.
    if [ $(( now_ts - MT_DEF_DEV_TS )) -ge 60 ]; then
        MT_DEF_DEV=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
        [ -z "$MT_DEF_DEV" ] && MT_DEF_DEV=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n 1)
        MT_DEF_DEV_TS=$now_ts
    fi
    local def_dev="$MT_DEF_DEV"

    local rx_speed="0 B/s" tx_speed="0 B/s"
    if [ -n "$def_dev" ] && [ -r "/sys/class/net/$def_dev/statistics/rx_bytes" ]; then
        local cur_rx cur_tx p_ts p_rx p_tx dt drx dtx
        read -r cur_rx < "/sys/class/net/$def_dev/statistics/rx_bytes"
        read -r cur_tx < "/sys/class/net/$def_dev/statistics/tx_bytes"
        if [ -f "$SECURE_TMP/.net_last" ]; then
            read -r p_ts p_rx p_tx < "$SECURE_TMP/.net_last"
            dt=$(( now_ts - p_ts ))
            if [ "$dt" -gt 0 ]; then
                drx=$(( (cur_rx - p_rx) / dt ))
                dtx=$(( (cur_tx - p_tx) / dt ))
                [ "$drx" -lt 0 ] && drx=0
                [ "$dtx" -lt 0 ] && dtx=0
                rx_speed=$(format_bytes_speed "$drx")
                tx_speed=$(format_bytes_speed "$dtx")
            fi
        fi
        echo "$now_ts $cur_rx $cur_tx" > "$SECURE_TMP/.net_last"
    fi

    if [ $(( now_ts - MT_V6_TS )) -ge 60 ]; then
        MT_V6_STATUS="OFF"
        if ip -6 route show default 2>/dev/null | grep -q default || ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
            MT_V6_STATUS="ON"
        fi
        MT_V6_TS=$now_ts
    fi

    echo "${cpu_pct}|${cpu_cores}|${r_used}|${r_total}|${r_pct}|${rx_speed}|${tx_speed}|${MT_V6_STATUS}" > "$sys_target"
    mv -f "$sys_target" "$SECURE_TMP/.main_sys_stats" 2>/dev/null
    local _up; read -r _up _ < /proc/uptime 2>/dev/null || _up=0
    printf '%s\n' "${_up%%.*}" > "$SECURE_TMP/.main_sys_stats_stamp"
}

mt_endpoint_host() {
    local ep="$1" host
    [ -n "$ep" ] || return 1
    if [[ "$ep" == \[*\]:* ]]; then
        host="${ep#\[}"; host="${host%\]:*}"
    else
        host="${ep%:*}"
    fi
    host="${host#::ffff:}"
    printf '%s' "$host"
}

# Resolve the TCP peer for exactly one systemd instance. PID scoping keeps
# same-engine tunnels from borrowing each other's live socket.
mt_unit_peer_ip() { mt_unit_live_peer "$1" "${2:-}"; }


# Ping results are reused for MT_PING_CACHE_SEC seconds per target. The stats cycle runs every 5 s,
# and a host that blocks ICMP used to cost up to 3 s of blocking per tunnel on every single cycle.
MT_PING_CACHE_SEC=15
MT_PING_COUNT=1   # one probe per refresh (was 2); set to 2 if steadier loss figures are preferred
mt_ping_stats() {
    local target="$1" iface="${2:-}" unit="${3:-}" ping_res loss avg='---' tcp_rtt now c_ts c_avg c_loss cfile key
    local -a cmd=(ping)
    mt_valid_host "$target" || { printf '%s|%s' '---' '---'; return 1; }
    now="${EPOCHSECONDS:-$(date +%s)}"
    key="${target//[^A-Za-z0-9]/_}_${iface//[^A-Za-z0-9]/_}"
    cfile="$SECURE_TMP/.ping_${key}"
    if [ -r "$cfile" ]; then
        read -r c_ts c_avg c_loss < "$cfile"
        if [[ "$c_ts" =~ ^[0-9]+$ ]] && [ $(( now - c_ts )) -lt "$MT_PING_CACHE_SEC" ] && [ -n "$c_loss" ]; then
            printf '%s|%s' "$c_avg" "$c_loss"
            return 0
        fi
    fi
    [[ "$target" == *:* ]] && cmd=(ping -6)
    if [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1; then cmd+=(-I "$iface"); fi
    ping_res=$(timeout 2 "${cmd[@]}" -c "$MT_PING_COUNT" -i 0.2 -W 1 "$target" 2>/dev/null || true)
    loss=$(printf '%s\n' "$ping_res" | grep -oP '[0-9]+(?=% packet loss)' | head -n1)
    [ -n "$loss" ] || loss=100
    if printf '%s\n' "$ping_res" | grep -q 'min/avg/max'; then
        avg=$(printf '%s\n' "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2 | head -n1)
        [ -n "$avg" ] && avg="$(awk -v v="$avg" 'BEGIN {printf "%.0fms", v}')"
    elif [ -n "$unit" ]; then
        tcp_rtt=$(mt_unit_tcp_rtt "$unit" "$target" 2>/dev/null || true)
        if [ -n "$tcp_rtt" ]; then avg="$tcp_rtt"; loss='---'; fi
    fi
    printf '%s %s %s\n' "$now" "$avg" "$loss" > "$cfile.tmp" 2>/dev/null && mv -f "$cfile.tmp" "$cfile" 2>/dev/null
    printf '%s|%s' "$avg" "$loss"
}

collect_active_tunnels_stats() {
    local tmp_target
    tmp_target=$(mktemp "$SECURE_TMP/.main_tun_stats.XXXXXX") || return 1
    # Service states and the socket table are fetched once per cycle, not once per tunnel.
    local -A MT_ACTIVE_UNITS=()
    local _u
    while read -r _u; do MT_ACTIVE_UNITS["$_u"]=1; done < <(systemctl list-units --type=service --state=active --no-legend --plain 2>/dev/null | awk '{print $1}')
    mt_ss_snapshot_begin 2>/dev/null || true
    local count=0
    # Fair selection under the 3-row header cap: pass 1 takes at most one tunnel
    # per protocol (so GRE can never starve Backhaul/Rathole/Paqet); pass 2 fills
    # any remaining rows with the not-yet-shown tunnels.
    local -A picked=(); local cap sec_n=0
    for cap in 1 3; do
    [ "$count" -lt 3 ] || break
    sec_n=0
    # 1. GRE
    for conf in /etc/mgre/tunnels/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; REMOTE_PUB=""; LOCAL_PUB=""; CORE_SUBNET=""; CORE_V6=""; TUN_ID=""; VNI_ID=""; TUN_PROTO="ipv4"; FAB_PROTO="ipv4"; LOCAL_PUB6=""; REMOTE_PUB6=""; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; mt_source_conf "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        [ -z "${picked[GRE|$T_NAME]:-}" ] || continue
        ip link show "$T_NAME" >/dev/null 2>&1 || continue
        [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" == "down" ] && continue
        local pure="${T_NAME#gre6ir}"; pure="${pure#gre6kh}"; pure="${pure#greir}"; pure="${pure#grekh}"
        local c_sub="${CORE_SUBNET}"
        mt_tunnel_addresses || continue
        local peer_vip="$MT_CORE_PEER"; REMOTE_PUB="$MT_REMOTE_PUBLIC"
        
        local vip_stat="OFF"
        [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null && vip_stat="+${MAX_IPS}"
        local avg="---" loss="---"
        IFS='|' read -r avg loss <<< "$(mt_ping_stats "$peer_vip" "$T_NAME")"
        local fwd_str="OFF"
        if [ "$TYPE" == "1" ]; then
            if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
            elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:4}"
            elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:4}"
            fi
        else fwd_str="GW"; fi
        echo "GRE|${pure:-$T_NAME}|${REMOTE_PUB}|${vip_stat}|${avg}|${loss}|${T_NAME}|${fwd_str}" >> "$tmp_target"
        ((count++))
        picked["GRE|$T_NAME"]=1; ((sec_n++)); [ "$count" -ge 3 ] && break 2; [ "$sec_n" -ge "$cap" ] && break
    done
    sec_n=0
    # 2. VXLAN
    if [ "$count" -lt 3 ]; then
        for conf in /etc/mgre/vxlan/*.conf; do
            [ -f "$conf" ] || continue
                TYPE=""; VX_NAME=""; BR_NAME=""; TUN_PROTO="ipv4"; CORE_V6=""; LOCAL_PUB=""; LOCAL_PUB6=""; REMOTE_PUB6=""; FAB_PROTO="ipv4"; REMOTE_PUB=""; CORE_SUBNET=""; TUN_ID=""; VNI_ID=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; mt_source_conf "$conf" 2>/dev/null
            [ -z "$VX_NAME" ] && continue
            [ -z "${picked[VXLAN|$VX_NAME]:-}" ] || continue
            ip link show "$VX_NAME" >/dev/null 2>&1 || continue
            [ "$(cat /sys/class/net/$VX_NAME/operstate 2>/dev/null)" == "down" ] && continue
            local pure="${VX_NAME#vx_}"
            local c_sub="${CORE_SUBNET:-$(mt_legacy_core_subnet "$VNI_ID" vxlan)}"
            mt_tunnel_addresses || continue
            local peer_vip="$MT_CORE_PEER"; REMOTE_PUB="$MT_REMOTE_PUBLIC"
            local vip_stat="OFF"
            [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null && vip_stat="+${MAX_IPS}"
            local avg="---" loss="---"
            IFS='|' read -r avg loss <<< "$(mt_ping_stats "$peer_vip" "$BR_NAME")"
            local fwd_str="OFF"
            if [ "$TYPE" == "1" ]; then
                if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
                elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:4}"
                elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:4}"
                fi
            else fwd_str="GW"; fi
            echo "VXLAN|${pure:-$VX_NAME}|${REMOTE_PUB}|${vip_stat}|${avg}|${loss}|${VX_NAME}|${fwd_str}" >> "$tmp_target"
            ((count++))
            picked["VXLAN|$VX_NAME"]=1; ((sec_n++)); [ "$count" -ge 3 ] && break 2; [ "$sec_n" -ge "$cap" ] && break
        done
    fi
    sec_n=0
    # 3. Backhaul
    if [ "$count" -lt 3 ]; then
        for conf in /etc/mbackhaul/tunnels/*.meta; do
            [ -f "$conf" ] || continue
            local t_name=$(basename "$conf" .meta)
            ROLE=$(mt_read_kv "$conf" ROLE) || continue
            TUN_PORT=$(mt_read_kv "$conf" TUN_PORT) || continue
            REMOTE_IP=$(mt_read_kv "$conf" REMOTE_IP 2>/dev/null || true)
            PORTS=$(mt_read_kv "$conf" PORTS 2>/dev/null || true)
            TRANSPORT=$(mt_read_kv "$conf" TRANSPORT 2>/dev/null || true); [ -n "$TRANSPORT" ] || TRANSPORT=tcp
            [[ "$ROLE" =~ ^[12]$ && "$TRANSPORT" =~ ^(tcp|tcpmux|ws|wss|wsmux|wssmux|udp)$ ]] && mt_valid_port "$TUN_PORT" || continue
            [ -z "${picked[BH|$t_name]:-}" ] || continue
            [ -n "${MT_ACTIVE_UNITS[mbackhaul@${t_name}.service]:-}" ] || continue
            local pure="${t_name#bh_}"
            local peer_ip="$REMOTE_IP"
            if [ "$ROLE" == "1" ]; then
                if [ "$TRANSPORT" = udp ]; then
                    peer_ip="UDP Listening"
                else
                    peer_ip=$(mt_unit_peer_ip "mbackhaul@${t_name}" "$TUN_PORT" 2>/dev/null || true)
                    [ -n "$peer_ip" ] || peer_ip=$(mt_unit_link_reason "mbackhaul@${t_name}" 1 "$TUN_PORT" 2>/dev/null || true)
                    [ -n "$peer_ip" ] || peer_ip="Listening"
                fi
            fi
            local avg="---" loss="---"
            if mt_valid_host "$peer_ip" 2>/dev/null; then
                IFS='|' read -r avg loss <<< "$(mt_ping_stats "$peer_ip" "" "mbackhaul@${t_name}")"
            fi
            local fwd_str="OFF"
            [ -n "$PORTS" ] && fwd_str="ACT"
            [ "$ROLE" == "2" ] && fwd_str="CLI"
            echo "BH|${pure:-$t_name}|${peer_ip}|OFF|${avg}|${loss}|bh_${t_name}|${fwd_str}" >> "$tmp_target"
            ((count++))
            picked["BH|$t_name"]=1; ((sec_n++)); [ "$count" -ge 3 ] && break 2; [ "$sec_n" -ge "$cap" ] && break
        done
    fi
    sec_n=0
    # 4. Rathole
    if [ "$count" -lt 3 ]; then
        for d in /etc/mrathole/tunnels/*; do
            [ -d "$d" ] && [ -f "$d/meta.conf" ] || continue
            local t_name=$(basename "$d")
            TYPE=$(mt_read_kv "$d/meta.conf" TYPE) || continue
            LINK_PORT=$(mt_read_kv "$d/meta.conf" LINK_PORT) || continue
            REMOTE_IP=$(mt_read_kv "$d/meta.conf" REMOTE_IP 2>/dev/null || true)
            TCP_PORTS=$(mt_read_kv "$d/meta.conf" TCP_PORTS 2>/dev/null || true)
            UDP_PORTS=$(mt_read_kv "$d/meta.conf" UDP_PORTS 2>/dev/null || true)
            [[ "$TYPE" =~ ^[12]$ ]] && mt_valid_port "$LINK_PORT" || continue
            [ -z "${picked[RAT|$t_name]:-}" ] || continue
            [ -n "${MT_ACTIVE_UNITS[mrathole@${t_name}.service]:-}" ] || continue
            local peer_ip="$REMOTE_IP"
            if [ "$TYPE" == "1" ]; then
                peer_ip=$(mt_unit_peer_ip "mrathole@${t_name}" "$LINK_PORT" 2>/dev/null || true)
                [ -n "$peer_ip" ] || peer_ip=$(mt_unit_link_reason "mrathole@${t_name}" 1 "$LINK_PORT" 2>/dev/null || true)
                [ -n "$peer_ip" ] || peer_ip="Listening"
            fi
            local avg="---" loss="---"
            if mt_valid_host "$peer_ip" 2>/dev/null; then
                IFS='|' read -r avg loss <<< "$(mt_ping_stats "$peer_ip" "" "mrathole@${t_name}")"
            fi
            local fwd_str="OFF"
            [ -n "$TCP_PORTS" ] || [ -n "$UDP_PORTS" ] && fwd_str="ACT"
            [ "$TYPE" == "2" ] && fwd_str="CLI"
            echo "RAT|${t_name}|${peer_ip}|OFF|${avg}|${loss}|rat_${t_name}|${fwd_str}" >> "$tmp_target"
            ((count++))
            picked["RAT|$t_name"]=1; ((sec_n++)); [ "$count" -ge 3 ] && break 2; [ "$sec_n" -ge "$cap" ] && break
        done
    fi
    sec_n=0
    # 5. Paqet
    if [ "$count" -lt 3 ]; then
        for conf in /etc/paqet/*.meta; do
            [ -f "$conf" ] || continue
            local t_name=$(basename "$conf" .meta)
            ROLE=$(mt_read_kv "$conf" ROLE) || continue
            TUN_PORT=$(mt_read_kv "$conf" TUN_PORT) || continue
            REMOTE_IP=$(mt_read_kv "$conf" REMOTE_IP 2>/dev/null || true)
            [[ "$ROLE" =~ ^[12]$ ]] && mt_valid_port "$TUN_PORT" || continue
            [ -z "${picked[PAQET|$t_name]:-}" ] || continue
            [ -n "${MT_ACTIVE_UNITS[mpaqet@${t_name}.service]:-}" ] || continue
            local pure="${t_name#pq_}"
            local peer_ip="$REMOTE_IP"
            if [ "$ROLE" == "1" ]; then
                local recent="/proc/net/xt_recent/mpq_${t_name}" cache="/root/mtunnel/tmp/.mpaqet_peer_${t_name}"
                if [ -r "$recent" ]; then
                    peer_ip=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^src=/){print substr($i,5); exit}}' "$recent" 2>/dev/null)
                fi
                [ -n "$peer_ip" ] || peer_ip=$(cat "$cache" 2>/dev/null)
                [ -n "$peer_ip" ] || peer_ip="Listening"
            fi
            local avg="---" loss="---"
            if mt_valid_host "$peer_ip" 2>/dev/null; then
                IFS='|' read -r avg loss <<< "$(mt_ping_stats "$peer_ip" "" "mpaqet@${t_name}")"
            fi
            echo "PAQET|${pure:-$t_name}|${peer_ip}|OFF|${avg}|${loss}|pq_${t_name}|RAW" >> "$tmp_target"
            ((count++))
            picked["PAQET|$t_name"]=1; ((sec_n++)); [ "$count" -ge 3 ] && break 2; [ "$sec_n" -ge "$cap" ] && break
        done
    fi
    done
    mt_ss_snapshot_end 2>/dev/null || true
    mv -f "$tmp_target" "$SECURE_TMP/.main_tun_stats" 2>/dev/null
}
stats_watcher_loop() {
    local prev='' cur=''
    while true; do
        collect_system_vitals
        collect_active_tunnels_stats
        # Repaint the live header only when the collected numbers differ from the previous cycle.
        cur=''
        [ -r "$SECURE_TMP/.main_sys_stats" ] && cur=$(<"$SECURE_TMP/.main_sys_stats")
        [ -r "$SECURE_TMP/.main_tun_stats" ] && cur+=$(<"$SECURE_TMP/.main_tun_stats")
        if [ "$cur" != "$prev" ]; then
            prev="$cur"
            kill -SIGUSR2 "$MAIN_PID" 2>/dev/null
        fi
        sleep "$STATS_CHECK_INTERVAL"
    done
}
STATS_PID=""
if [[ "${1:-}" != --* ]]; then stats_watcher_loop & STATS_PID=$!; fi
trap 'mt_bg_loops_resume; [ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null; [ -z "${STATS_PID:-}" ] || kill "$STATS_PID" 2>/dev/null' EXIT
get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}
get_local_ipv6() {
    local v6
    v6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ && !/deprecated/ {sub(/\/.*/,"",$2); print $2; exit}')
    echo "${v6:-}"
}
get_iface_uptime_pure() {
    local dev="$1"
    if [[ "$dev" == bh_* || "$dev" == rat_* || "$dev" == pq_* ]]; then
        local srv_name="mbackhaul@${dev#bh_}"
        [[ "$dev" == rat_* ]] && srv_name="mrathole@${dev#rat_}"
        [[ "$dev" == pq_* ]] && srv_name="mpaqet@${dev#pq_}"
        local started=$(systemctl show "$srv_name" --property=ActiveEnterTimestampMonotonic 2>/dev/null | cut -d= -f2)
        if [ -n "$started" ] && [ "$started" -gt 0 ]; then
            local now=$(cut -d' ' -f1 /proc/uptime | tr -d '.')
            local sec=$(( (now * 10000 - started) / 1000000 ))
            [ "$sec" -lt 0 ] && sec=0
            local d=$(( sec / 86400 )); local h=$(( (sec % 86400) / 3600 )); local m=$(( (sec % 3600) / 60 ))
            if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
            elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
            else printf "%dm" "$m"; fi
            return
        fi
        echo "ACTIVE"
        return
    fi
    if [ ! -d "/sys/class/net/$dev" ] || [ "$(cat /sys/class/net/$dev/operstate 2>/dev/null)" == "down" ]; then
        echo "DOWN"
        return
    fi
    local sys_uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    local if_sec=$(ip -s -d link show "$dev" 2>/dev/null | grep -oP 'trans_start \K[0-9]+')
    local delta=0
    if [ -n "$if_sec" ] && [ "$if_sec" -gt 0 ]; then
        delta=$(( (sys_uptime * 100 - if_sec) / 100 ))
        [ "$delta" -lt 0 ] && delta=0
    else
        local created=$(stat -c %Y "/sys/class/net/$dev" 2>/dev/null)
        local now=$(date +%s)
        delta=$(( now - created ))
        [ "$delta" -lt 0 ] && delta=0
    fi
    local d=$(( delta / 86400 )); local h=$(( (delta % 86400) / 3600 )); local m=$(( (delta % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
    else printf "%dm" "$m"; fi
}
is_iperf3_valid() {
    command -v iperf3 >/dev/null 2>&1 && iperf3 -v >/dev/null 2>&1
}
is_package_or_bin_installed() {
    local item="$1"
    if [ "$item" == "bh" ]; then
        command -v bh >/dev/null 2>&1 || [ -x /usr/local/bin/bh ]
    elif [ "$item" == "rathole" ]; then
        command -v rathole >/dev/null 2>&1 || [ -x /usr/local/bin/rathole ]
    elif [ "$item" == "paqet" ]; then
        command -v paqet >/dev/null 2>&1 || [ -x /usr/local/bin/paqet ]
    elif [ "$item" == "gost" ]; then
        command -v gost >/dev/null 2>&1 || [ -x /usr/local/bin/gost ]
    elif [ "$item" == "haproxy" ]; then
        command -v haproxy >/dev/null 2>&1 || [ -x /usr/sbin/haproxy ]
    elif [[ "$item" == *.deb ]]; then
        local pkg_name=$(echo "$item" | cut -d'_' -f1)
        if [ "$pkg_name" == "iperf3" ]; then
            is_iperf3_valid
        elif [ "$pkg_name" == "libiperf0" ]; then
            dpkg -s libiperf0 2>/dev/null | grep -q "Status: install ok installed" || ldconfig -p 2>/dev/null | grep -q "libiperf\.so\.0"
        else
            command -v "$pkg_name" >/dev/null 2>&1 || dpkg -s "$pkg_name" 2>/dev/null | grep -q "Status: install ok installed"
        fi
    else
        command -v "$item" >/dev/null 2>&1
    fi
}
# Terminal-frame helpers: strip SGR sequences only for measuring visible columns.
# C.UTF-8 ensures box glyphs and status symbols count as characters, not bytes.
mt_main_visible_text() {
    local rendered
    rendered=$(printf '%b' "$1")
    printf '%s' "$rendered" | sed -E $'s/\033\\[[0-9;]*m//g'
}
mt_main_frame_row() {
    local raw="$1" width="$2" frame_color="${3:-$FR}"
    local rendered plain padding
    local LC_CTYPE=C.UTF-8
    rendered=$(printf '%b' "$raw")
    plain=$(mt_main_visible_text "$rendered")
    if (( ${#plain} > width )); then
        rendered="${plain:0:width}"   # safe overflow fallback, do not split ANSI codes
        plain="$rendered"
    fi
    padding=$((width-${#plain}))
    printf '  %b║%b%s%*s%b║%b\033[K\n' "$frame_color" "$NC" "$rendered" "$padding" '' "$frame_color" "$NC"
}
mt_main_header_cell() {
    local width="$1" raw="$2" rendered plain padding
    local LC_CTYPE=C.UTF-8
    rendered=$(printf '%b' "$raw")
    plain=$(mt_main_visible_text "$rendered")
    if (( ${#plain} > width-2 )); then
        rendered="${plain:0:width-2}"
        plain="$rendered"
    fi
    padding=$((width-2-${#plain}))
    printf ' %s%*s ' "$rendered" "$padding" ''
}
mt_main_header_row4() {
    # Dynamic wide header. Base width 120, extra terminal width is given to title/local area.
    local total="${MT_MAIN_HEADER_WIDTH:-120}" extra join
    (( total < 120 )) && total=120
    extra=$((total-120))
    join=$(printf '%b' " ${FR}║${NC} ")
    mt_main_frame_row "$(mt_main_header_cell $((33+extra)) "$1")${join}$(mt_main_header_cell 23 "$2")${join}$(mt_main_header_cell 29 "$3")${join}$(mt_main_header_cell 26 "$4")" "$total"
}
mt_main_header_row7() {
    # Keep the tunnel identity readable while still reserving a wide Peer cell.
    # Base: 22+31+9+10+9+11+10 + 6 x ' │ ' = 120.
    # Extra terminal width is donated to Peer so long/compressed IPv6 peers fit.
    local total="${MT_MAIN_HEADER_WIDTH:-120}" extra join
    (( total < 120 )) && total=120
    extra=$((total-120))
    join=$(printf '%b' " ${FR}║${NC} ")
    mt_main_frame_row "$(mt_main_header_cell 22 "$1")${join}$(mt_main_header_cell $((31+extra)) "$2")${join}$(mt_main_header_cell 9 "$3")${join}$(mt_main_header_cell 10 "$4")${join}$(mt_main_header_cell 9 "$5")${join}$(mt_main_header_cell 11 "$6")${join}$(mt_main_header_cell 10 "$7")" "$total"
}
mt_main_menu_separator() {
    local w="$1" title="${2:-}" border=''
    printf -v border '%*s' "$w" ''
    border="${border// /═}"
    if [[ -n $title ]]; then
        local prefix="═[ $title ]" title_len
        local LC_CTYPE=C.UTF-8
        title_len=${#prefix}
        if (( title_len < w )); then
            border="${prefix}${border:0:w-title_len}"
        fi
    fi
    printf '  %b╠%s╣%b\033[K\n' "$FR" "$border" "$NC"
}
mt_main_menu_option() {
    local w="$1" number="$2" color="$3" label="$4" module="${5:-}" badge=''
    [[ -z "$module" ]] || badge=$(module_update_badge "$module")
    mt_main_frame_row "  ${W}$(printf '%-2s' "$number")${NC} ${DIM}❯${NC} ${color}${label}${NC}${badge}" "$w" "$FR"
}

draw_header_lines_only() {
    mt_master_header_draw "$MODULE_VERSION"
}

draw_main_header() {
    clear
    draw_header_lines_only
}

refresh_header_live() {
    mt_live_vitals_update 2>/dev/null || true
    printf "\033[?25l\0337\033[1;1H"
    HEADER_LIVE=1 draw_header_lines_only
    printf "\0338\033[?25h"
}
read_with_refresh() {
    local prompt="$1"
    local __resultvar="$2"
    local redraw_func="$3"
    local buffer="" char rc up now last_live=-1
    echo -ne "$prompt"
    while true; do
        if [ "$NEED_REFRESH" = true ]; then
            NEED_REFRESH=false
            if [ -n "$redraw_func" ]; then "$redraw_func"; fi
            echo -ne "$prompt$buffer"
        fi
        if [ "$NEED_LIVE_HEADER_REFRESH" = true ]; then
            NEED_LIVE_HEADER_REFRESH=false
            refresh_header_live
        fi
        IFS= read -rsn1 -t 0.25 char
        rc=$?
        if [ $rc -ne 0 ]; then
            if [ "$rc" -eq 142 ] || [ "$rc" -gt 128 ]; then
                read -r up _ < /proc/uptime 2>/dev/null || up=0; now="${up%%.*}"
                if [ "$now" != "$last_live" ]; then last_live="$now"; refresh_header_live; fi
                continue
            fi
            return "$rc"
        fi
        if [[ -z "$char" ]]; then echo ""; break; fi
        if [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
            if [ -n "$buffer" ]; then buffer="${buffer%?}"; echo -ne "\b \b"; fi
            continue
        fi
        buffer+="$char"; echo -ne "$char"
    done
    printf -v "$__resultvar" '%s' "$buffer"
}
draw_progress_bar() {
    local pid=$1 text=$2 width=30 progress=0 filled empty bar rest
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        ((progress++))
        [ "$progress" -gt 95 ] && progress=95
        filled=$(( progress * width / 100 ))
        empty=$(( width - filled ))
        bar="$(printf '%*s' "$filled" '' | tr ' ' '#')"
        rest="$(printf '%*s' "$empty" '' | tr ' ' '-')"
        printf "\r  %b→%b %-26s %b[%s%b%s%b] %3d%%" "$C" "$NC" "$text" "$W" "$bar" "$DIM" "$rest" "$NC" "$progress"
        sleep 0.12
    done
    bar="$(printf '%*s' "$width" '' | tr ' ' '#')"
    printf "\r  %b✔%b %-26s %b[%b%s%b] %3d%%\n" "$G" "$NC" "$text" "$W" "$G" "$bar" "$W" 100
    tput cnorm 2>/dev/null || true
}
same_file() {
    local a="$1" b="$2"
    [ -f "$a" ] && [ -f "$b" ] && [ "$(readlink -f "$a" 2>/dev/null)" = "$(readlink -f "$b" 2>/dev/null)" ]
}
download_file_to_cache() {
    local mod="$1" base_url="$2" rel_path="${MOD_MAP[$1]:-}" tmp
    [ -n "$rel_path" ] || return 1
    tmp=$(mktemp "$SECURE_TMP/module.XXXXXX") || return 1
    if ! mt_download "$(mt_cb_url "$base_url/$rel_path")" "$tmp" || ! mt_validate_script "$tmp"; then rm -f "$tmp"; return 1; fi
    local installed="/usr/bin/$mod"; [ "$mod" != main ] || installed="$MTUNNEL_PATH"
    local cur new; cur=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$installed" 2>/dev/null); new=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$tmp")
    mt_validate_module_core_contract "$tmp" || { rm -f "$tmp"; return 1; }
    mt_install_files 755 "$tmp" "$LOCAL_DIR/$rel_path"
    local rc=$?; rm -f "$tmp"; return "$rc"
}
deploy_cached_module() {
    local mod="$1" rel_path="${MOD_MAP[$1]:-}" installed="/usr/bin/$1"
    [ -n "$rel_path" ] || return 1
    [ "$mod" != main ] || installed="$MTUNNEL_PATH"
    mt_install_script "$LOCAL_DIR/$rel_path" "$rel_path" "$installed"
}
deploy_binaries_from_dir() {
    local src_dir="$1" name source unit rc=0 deb arch
    MT_DEPLOY_FAILED=()
    [ -d "$src_dir" ] || return 1
    # Original archive for each engine: used when the raw binary is missing or not a valid ELF.
    declare -A ARC=([bh]=backhaul_linux_amd64.tar.gz [rathole]=rathole-x86_64-unknown-linux-gnu.zip
                    [paqet]=paqet-linux-amd64-v1.0.0-alpha.21.tar.gz [gost]=gost-linux-amd64-2.11.5.gz)
    for name in bh rathole paqet gost haproxy; do
        source="$src_dir/$name"
        [ "$name" != bh ] || [ -f "$source" ] || source="$src_dir/backhaul"
        if ! { [ -f "$source" ] && mt_valid_elf "$source"; }; then
            if [ -n "${ARC[$name]:-}" ] && [ -f "$src_dir/${ARC[$name]}" ]; then
                source="$src_dir/${ARC[$name]}"
            elif [ -f "$source" ]; then
                echo "Invalid/incompatible binary: $source" >&2; rc=1; MT_DEPLOY_FAILED+=("$name"); continue
            else
                continue
            fi
        fi
        case "$name" in bh) unit=mbackhaul;; rathole) unit=mrathole;; paqet) unit=mpaqet;; *) unit="$name";; esac
        mt_update_core "$name" "$unit" "$source" local || { rc=1; MT_DEPLOY_FAILED+=("$name"); }
        if [ "$src_dir" != "$(mt_engines_dir)" ] && mt_valid_elf "$source"; then mt_install_files 755 "$source" "$(mt_engines_dir)/$name" || rc=1; fi
    done
    # Original archives (tar.gz / zip / gz) are kept next to the binaries: they are the fallback when a binary is unusable.
    if [ "$src_dir" != "$(mt_engines_dir)" ]; then
        for f in "$src_dir"/*.tar.gz "$src_dir"/*.zip "$src_dir"/*.gz; do
            [ -f "$f" ] && mt_is_archive_file "$f" && mt_install_files 644 "$f" "$(mt_engines_dir)/${f##*/}" || true
        done
    fi
    local -a debs=()
    for deb in "$src_dir"/*.deb; do [ -f "$deb" ] && debs+=("$deb"); done
    if [ "${#debs[@]}" -gt 0 ]; then mt_install_debs "${debs[@]}" || rc=1; fi
    return "$rc"
}
# Install every .deb it is given (all of them in ONE dpkg run, so inter-package dependencies such as
# libiperf0 -> iperf3 or iptables -> libxtables resolve among themselves). A package is skipped only when
# the same or a NEWER version is already installed, so a pinned older .deb can never downgrade the system.
# If dpkg fails as a batch, each package is retried alone so one bad file cannot block the rest.
mt_install_debs() {
    local deb pkg ver arch inst sys_arch log rc=0 installed_n=0 skipped_n=0
    local -a todo=() failed=()
    declare -gA MT_DEB_REASON=()
    MT_DEB_FAILED=()
    sys_arch=$(dpkg --print-architecture 2>/dev/null)
    for deb in "$@"; do
        [ -f "$deb" ] || continue
        pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null); ver=$(dpkg-deb -f "$deb" Version 2>/dev/null); arch=$(dpkg-deb -f "$deb" Architecture 2>/dev/null)
        if [ -z "$pkg" ] || [ -z "$ver" ]; then echo -e "  ${R}✖ Not a valid .deb: ${deb##*/}${NC}" >&2; rc=1; continue; fi
        if [ "$arch" != all ] && [ "$arch" != "$sys_arch" ]; then echo -e "  ${R}✖ Wrong architecture (${arch}, system is ${sys_arch}): ${deb##*/}${NC}" >&2; rc=1; continue; fi
        inst=$(dpkg-query -W -f='${Status}|${Version}' "$pkg" 2>/dev/null || true)
        if [ "${inst%%|*}" == 'install ok installed' ] && ! dpkg --compare-versions "${inst#*|}" lt "$ver"; then
            skipped_n=$((skipped_n+1)); continue
        fi
        todo+=("$deb")
    done
    if [ "${#todo[@]}" -gt 0 ]; then
        log=$(mktemp "$SECURE_TMP/dpkg.XXXXXX") || return 1
        local -a dpkg_cmd=(env DEBIAN_FRONTEND=noninteractive dpkg -i --force-confdef --force-confold)
        local -A lasts=()
        if ! "${dpkg_cmd[@]}" "${todo[@]}" >"$log" 2>&1; then
            if grep -qiE 'lock|frontend' "$log"; then
                mt_apt_wait_unlocked || { rm -f "$log"; return 1; }
            fi
            if "${dpkg_cmd[@]}" "${todo[@]}" >"$log" 2>&1; then installed_n=${#todo[@]}
            else
                # The batch failed: go package by package and repeat while a pass makes progress, so a package
                # whose dependency comes later in the list still gets installed. Whatever is left is reported.
                local -a pending=("${todo[@]}") next=()
                local progress=1
                while [ "${#pending[@]}" -gt 0 ] && [ "$progress" == 1 ]; do
                    progress=0; next=()
                    for deb in "${pending[@]}"; do
                        if "${dpkg_cmd[@]}" "$deb" >"$log" 2>&1; then installed_n=$((installed_n+1)); progress=1
                        else lasts["$deb"]=$( { grep -iE 'returned error|dependency problems|depends on|conflicts with|not installable|cannot' "$log" || grep -iE 'error|fail' "$log" || cat "$log"; } | grep -v '^[[:space:]]*$' | head -n1 ); next+=("$deb"); fi
                    done
                    pending=("${next[@]}")
                done
                for deb in "${pending[@]}"; do failed+=("${deb##*/}: ${lasts[$deb]:-unknown error}"); MT_DEB_FAILED+=("${deb##*/}"); MT_DEB_REASON["${deb##*/}"]="${lasts[$deb]:-unknown error}"; done
                [ "${#failed[@]}" -eq 0 ] || rc=1
            fi
        else installed_n=${#todo[@]}; fi
        rm -f "$log"
        ldconfig 2>/dev/null || true
    fi
    for deb in "${failed[@]}"; do echo -e "  ${R}✖ dpkg failed — ${deb}${NC}" >&2; done
    echo -e "  ${DIM}● Packages installed: ${installed_n}, already up to date: ${skipped_n}, failed: $((${#failed[@]}))${NC}"
    return "$rc"
}
# Dependency-free check of a staged file (the staged bundle's OWN validators run later).
mt_stage_script_ok() { [ -s "$1" ] && bash -n "$1" 2>/dev/null; }
# Validate a staged bundle with the validators that ship INSIDE that bundle (its own core/common.sh), not with
# the installed core. A stale installed common.sh used to reject every newer module ("Wrong module role")
# and so the bundle could never replace the very core that would accept it. Runs in a subshell, so the
# staged core never leaks into this running process.
mt_validate_staged_bundle() {
    local src="$1"
    (
        # shellcheck disable=SC1090
        source "$src/core/common.sh" >/dev/null || { echo 'Staged shared core could not be loaded.' >&2; exit 1; }
        declare -F mt_validate_script >/dev/null && declare -F mt_validate_module_role >/dev/null &&
            declare -F mt_validate_module_core_contract >/dev/null || { echo 'Staged shared core lacks the module validators.' >&2; exit 1; }
        local mod rel cand
        for mod in "${ALL_MODULES[@]}"; do
            [ "${MT_SCRIPTS_ONLY:-0}" == 1 ] && [[ "${MOD_MAP[$mod]}" == tunnels/* ]] && continue
            rel="${MOD_MAP[$mod]}"; cand="$src/$rel"
            mt_validate_script "$cand" || { echo "Invalid module (shebang, syntax or MODULE_VERSION): $rel" >&2; exit 1; }
            mt_validate_module_role "$cand" "$rel" || { echo "Wrong module role in bundle: $rel" >&2; exit 1; }
            mt_validate_module_core_contract "$cand" || { echo "Incompatible module/core contract in bundle: $rel" >&2; exit 1; }
        done
        mt_validate_script "$src/install.sh" || { echo 'Missing or invalid install.sh in complete bundle.' >&2; exit 1; }
        head -n 5 "$src/install.sh" | grep -Fq '# MTunnel standalone installer:' || { echo 'Incorrect install.sh in complete bundle.' >&2; exit 1; }
        exit 0
    )
}
ensure_module() {
    local mod="$1"
    local rel_path="${MOD_MAP[$mod]}"
    [ -z "$rel_path" ] && rel_path="${mod}.sh"
    local target_file="$LOCAL_DIR/$rel_path" installed_file="/usr/bin/$mod"
    [ "$mod" != main ] || installed_file="$MTUNNEL_PATH"
    # Fast path: the installed module is already identical to the cached copy, so skip the
    # full re-validation (2x bash -n) and re-install that used to run on every menu entry.
    if [ -x "$installed_file" ] && [ -s "$installed_file" ] && { [ ! -e "$target_file" ] || cmp -s "$installed_file" "$target_file"; }; then
        return 0
    fi
    mkdir -p "$(dirname "$target_file")" 2>/dev/null
    if [ -s "$target_file" ]; then deploy_cached_module "$mod" && return 0; fi
    if [ -s "/usr/bin/$mod" ]; then
        cp -f "/usr/bin/$mod" "$target_file" 2>/dev/null || true
        chmod 0755 "$target_file" 2>/dev/null || true
        deploy_cached_module "$mod" && return 0
    fi
    if download_file_to_cache "$mod" "$REPO_SCRIPTS"; then deploy_cached_module "$mod" && return 0; fi
    echo -e "  ${R}✗ ${W}${mod}${R} is not available locally and source download failed.${NC}"
    return 1
}
# Package-manager locks: the processes holding dpkg / apt locks, then a forced release of them.
mt_apt_lock_holders() {
    local p fd tgt
    for p in /proc/[0-9]*; do
        for fd in "$p"/fd/*; do
            tgt=$(readlink "$fd" 2>/dev/null) || continue
            case "$tgt" in
                /var/lib/dpkg/lock|/var/lib/dpkg/lock-frontend|/var/lib/apt/lists/lock|/var/cache/apt/archives/lock)
                    echo "${p#/proc/}"; break;;
            esac
        done
    done | sort -u
}
# Wait for package managers without stopping services or killing their processes.
mt_apt_wait_unlocked() {
    local limit="${MTUNNEL_APT_LOCK_TIMEOUT:-120}" start=$SECONDS
    [[ "$limit" =~ ^[0-9]{1,5}$ ]] || { echo 'Invalid APT lock timeout.' >&2; return 1; }
    limit=$((10#$limit))
    while [ -n "$(mt_apt_lock_holders)" ]; do
        if (( SECONDS - start >= limit )); then
            echo 'Package manager is busy; retry after the running update finishes. No processes were stopped.' >&2
            return 1
        fi
        sleep 1
    done
}
# unzip is installed before an install-from-link. Silent when it is already there; otherwise installed
# behind MTunnel's own progress bar. If apt is unavailable the python3 fallback in the shared core takes over.
mt_ensure_unzip() {
    if command -v unzip >/dev/null 2>&1; then
        echo -e "  ${G}✔ unzip is already installed.${NC}"
        return 0
    fi
    echo -e "  ${Y}● unzip is not installed; preparing archive extraction.${NC}"
    # On minimal systems, Python's validated zipfile extractor is an equally safe
    # fallback and avoids touching apt/dpkg locks unnecessarily.
    if ! command -v apt-get >/dev/null 2>&1; then
        if command -v python3 >/dev/null 2>&1; then
            echo -e "  ${C}● Using Python ZIP extraction; no package installation required.${NC}"
            return 1
        fi
        echo -e "  ${R}✖ Neither unzip, apt-get nor python3 is available.${NC}" >&2
        return 1
    fi
    local log="$SECURE_TMP/.unzip_install.log" pid rc=0
    mt_apt_wait_unlocked || return 1
    (
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -q || exit $?
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -q unzip
    ) >"$log" 2>&1 &
    pid=$!
    draw_progress_bar "$pid" 'Installing unzip'
    wait "$pid" 2>/dev/null || rc=$?
    if command -v unzip >/dev/null 2>&1; then
        echo -e "\n  ${G}✔ unzip installed successfully.${NC}"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        echo -e "\n  ${Y}● unzip installation failed; Python extraction will be used instead.${NC}"
        return 1
    fi
    echo -e "\n  ${R}✖ Could not install unzip. Details: ${log}${NC}" >&2
    return "${rc:-1}"
}
# A module runs as a child process. The menu's two background loops are paused while it runs, so they
# neither poll nor repaint underneath it; they resume as soon as the module exits (or the shell does).
mt_bg_loops_pause()  { local p; for p in "${WATCHER_PID:-}" "${STATS_PID:-}"; do [ -n "$p" ] && kill -STOP "$p" 2>/dev/null; done; return 0; }
mt_bg_loops_resume() { local p; for p in "${WATCHER_PID:-}" "${STATS_PID:-}"; do [ -n "$p" ] && kill -CONT "$p" 2>/dev/null; done; return 0; }
run_mod() {
    local mod="$1" rc=0
    ensure_module "$mod" || return 1
    mt_bg_loops_pause
    "$mod"; rc=$?
    mt_bg_loops_resume
    return "$rc"
}
install_bundle_scripts() {
    local source="$1" mod rel candidate target cur new bundle_version=''
    local -a files=() mods=()
    [ -d "$source" ] || return 1
    # Entire bundles must include the shared core. Never deploy loader scripts
    # without their matching dependency.
    [ -s "$source/core/common.sh" ] && bash -n "$source/core/common.sh" &&
        grep -q '^MTUNNEL_CORE_API=[0-9][0-9]*$' "$source/core/common.sh" &&
        grep -q '^MTUNNEL_LAYOUT_REV=[0-9][0-9]*$' "$source/core/common.sh" || {
        echo 'MTunnel shared core missing or invalid in the bundle.' >&2; return 1;
    }
    # The bundle is replaced as ONE unit (core + every module + installer), so its API/layout only has to be
    # self-consistent. That is verified with the bundle's own validators, never the installed (older) ones.
    mt_validate_staged_bundle "$source" || return 1
    files+=("$source/core/common.sh" /usr/lib/mtunnel/common.sh
            "$source/core/common.sh" "$LOCAL_DIR/core/common.sh")
    for mod in "${ALL_MODULES[@]}"; do
        [ "${MT_SCRIPTS_ONLY:-0}" == 1 ] && [[ "${MOD_MAP[$mod]}" == tunnels/* ]] && continue
        rel="${MOD_MAP[$mod]}"; candidate="$source/$rel"
        local candidate_version
        candidate_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$candidate")
        if [ -z "${bundle_version:-}" ]; then bundle_version="$candidate_version"; fi
        mods+=("$mod")
    done
    local core_version
    core_version=$(sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$source/core/common.sh")
    # Installer must be included too: otherwise the installed release is mixed
    # after a successful "Sync All Scripts" downgrade.
    local installer_version
    installer_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$source/install.sh")
    # Compare ALL installed scripts to the candidate and authorize one coherent
    # downgrade of the entire bundle (not seven separate prompts).
    local installed_highest='' installed_version unknown_installed=0 conf_installed
    for mod in "${mods[@]}"; do
        target="/usr/bin/$mod"; [ "$mod" != main ] || target="$MTUNNEL_PATH"
        installed_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$target" 2>/dev/null)
        if [ -z "$installed_version" ]; then
            [ ! -f "$target" ] || unknown_installed=1
        elif [ -z "$installed_highest" ] || mt_is_newer_version "$installed_version" "$installed_highest"; then
            installed_highest="$installed_version"
        fi
    done
    # Also compare the installed copy of install.sh and the installed shared core.
    for target in "$LOCAL_DIR/install.sh" /usr/lib/mtunnel/common.sh; do
        case "$target" in
            */install.sh) installed_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$target" 2>/dev/null);;
            *) installed_version=$(sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$target" 2>/dev/null);;
        esac
        if [ -n "$installed_version" ] && { [ -z "$installed_highest" ] || mt_is_newer_version "$installed_version" "$installed_highest"; }; then
            installed_highest="$installed_version"
        fi
    done
    conf_installed="$installed_highest"
    # An unreadable installed version is treated as unknown unless the bundle is
    # strictly newer than every readable installed version.
    if [ "$unknown_installed" == 1 ] && { [ -z "$conf_installed" ] || ! mt_is_newer_version "$bundle_version" "$conf_installed"; }; then conf_installed=unknown; fi
    files+=("$source/install.sh" "$LOCAL_DIR/install.sh")
    for mod in "${mods[@]}"; do
        rel="${MOD_MAP[$mod]}"; candidate="$source/$rel"; target="/usr/bin/$mod"
        [ "$mod" != main ] || target="$MTUNNEL_PATH"
        files+=("$candidate" "$LOCAL_DIR/$rel" "$candidate" "$target")
    done
    mt_install_files 755 "${files[@]}" || return 1
    if [ "${2:-0}" == 1 ]; then
        local current=0 version total="${#mods[@]}"
        for mod in "${mods[@]}"; do
            current=$((current+1)); rel="${MOD_MAP[$mod]}"
            version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$source/$rel")
            draw_item_progress "$current" "$total" "$mod" "$version"
        done
    fi
    return 0
}
sync_script_bundle() {
    local base="$1" stage mod rel rc=0
    stage=$(mktemp -d "$SECURE_TMP/sync.XXXXXX") || return 1
    # Stage the shared core and all scripts before committing any module.
    mkdir -p "$stage/core"
    if ! mt_download "$(mt_cb_url "$base/core/common.sh")" "$stage/core/common.sh"; then
        echo "Could not download core/common.sh from $base" >&2; rm -rf "$stage"; return 1
    fi
    if ! bash -n "$stage/core/common.sh" 2>/dev/null ||
       ! grep -q '^MTUNNEL_CORE_API=[0-9][0-9]*$' "$stage/core/common.sh" ||
       ! grep -q '^MTUNNEL_LAYOUT_REV=[0-9][0-9]*$' "$stage/core/common.sh"; then
        echo 'Downloaded core/common.sh is not a valid MTunnel shared core.' >&2; rm -rf "$stage"; return 1
    fi
    # VERSION is metadata only. Mirrors, caches and custom sources may refresh
    # files at different times, so a marker/core version mismatch must never
    # block a sync. The staged scripts are still syntax-checked and the shared
    # core API/layout contract is validated above before anything is installed.
    # Fetch VERSION only as optional cached metadata; ignore absence/mismatch.
    mt_download "$(mt_cb_url "$base/VERSION")" "$stage/VERSION" 2>/dev/null || true
    for mod in "${ALL_MODULES[@]}"; do
        [ "${MT_SCRIPTS_ONLY:-0}" == 1 ] && [[ "${MOD_MAP[$mod]}" == tunnels/* ]] && continue
        rel="${MOD_MAP[$mod]}"
        mkdir -p "$(dirname "$stage/$rel")" || { rc=1; break; }
        if ! mt_download "$(mt_cb_url "$base/$rel")" "$stage/$rel"; then
            echo "Could not download $rel from $base; existing scripts preserved." >&2
            rc=1; break
        fi
        if ! mt_stage_script_ok "$stage/$rel"; then
            echo "Invalid Bash module from source: $rel; existing scripts preserved." >&2
            rc=1; break
        fi
    done
    if [ "$rc" == 0 ]; then
        if ! mt_download "$(mt_cb_url "$base/install.sh")" "$stage/install.sh"; then
            echo 'Could not download install.sh; existing scripts preserved.' >&2
            rc=1
        elif ! mt_stage_script_ok "$stage/install.sh"; then
            echo 'Invalid Bash installer from source: install.sh; existing scripts preserved.' >&2
            rc=1
        fi
    fi
    [ "$rc" != 0 ] || install_bundle_scripts "$stage" "${2:-0}" || rc=$?
    rm -rf "$stage"
    return "$rc"
}
mt_local_source_has_packages() {
    local dir="$1" f
    [ -d "$dir" ] || return 1
    for f in bh backhaul rathole paqet gost haproxy realm; do [ -f "$dir/$f" ] && return 0; done
    compgen -G "$dir/*.deb" >/dev/null 2>&1 && return 0
    compgen -G "$dir/*.tar.gz" >/dev/null 2>&1 || compgen -G "$dir/*.zip" >/dev/null 2>&1 || compgen -G "$dir/*.gz" >/dev/null 2>&1
}
mt_bundle_root_is_complete() {
    local d="$1" mod rel
    [ -d "$d" ] || return 1
    [ -f "$d/main.sh" ] && [ -f "$d/install.sh" ] && [ -f "$d/core/common.sh" ] || return 1
    for mod in "${ALL_MODULES[@]}"; do rel="${MOD_MAP[$mod]}"; [ -f "$d/$rel" ] || return 1; done
    return 0
}
mt_find_bundle_root() {
    local source="$1" f d found=''
    if mt_bundle_root_is_complete "$source"; then printf '%s\n' "$source"; return 0; fi
    while IFS= read -r -d '' f; do
        d="${f%/main.sh}"
        mt_bundle_root_is_complete "$d" || continue
        if [ -n "$found" ] && [ "$(readlink -f "$found" 2>/dev/null)" != "$(readlink -f "$d" 2>/dev/null)" ]; then
            echo 'Multiple complete MTunnel bundles were found. Select the exact bundle directory.' >&2
            return 2
        fi
        found="$d"
    done < <(find "$source" -maxdepth 5 -type f -name main.sh -print0 2>/dev/null)
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}
offline_local_deploy() {
    local source stage='' bundle='' rc=0 find_rc=0
    source=$(mt_clean_path "${1:-}")
    [ -n "$source" ] || source="$PWD"
    if [ -f "$source" ]; then
        stage=$(mktemp -d "$SECURE_TMP/offline.XXXXXX") || return 1
        if ! mt_extract_archive "$source" "$stage"; then
            echo 'Local file is not a supported/safe ZIP, TAR.GZ, or TAR archive.' >&2
            rm -rf "$stage"; return 1
        fi
        source="$stage"
    fi
    [ -d "$source" ] || { [ -z "$stage" ] || rm -rf "$stage"; echo 'Local source path does not exist or is not a directory.' >&2; return 1; }

    bundle=$(mt_find_bundle_root "$source") || find_rc=$?
    if [ "$find_rc" == 2 ]; then [ -z "$stage" ] || rm -rf "$stage"; return 1; fi
    if [ -n "$bundle" ]; then
        # A package was selected: rebuild the MTunnel folder from it (tunnel state is kept).
        # The package is copied out first when it lives inside that folder, so it is not deleted under us.
        case "$bundle" in
            "$LOCAL_DIR"|"$LOCAL_DIR"/*)
                local keep; keep=$(mktemp -d "$SECURE_TMP/package.XXXXXX") || return 1
                cp -a "$bundle/." "$keep/" || { rm -rf "$keep"; return 1; }
                [ -n "$stage" ] && rm -rf "$stage"; stage="$keep"; bundle="$keep";;
        esac
        # Tunnel state, backups and reports are moved aside and put back; everything else is rebuilt from the package.
        local keep_dir keep_item; keep_dir=$(mktemp -d "$SECURE_TMP/keep.XXXXXX") || { [ -z "$stage" ] || rm -rf "$stage"; return 1; }
        for keep_item in tunnels backups reports; do
            [ -e "$LOCAL_DIR/$keep_item" ] && mv "$LOCAL_DIR/$keep_item" "$keep_dir/"
        done
        rm -rf "$LOCAL_DIR" || { [ -z "$stage" ] || rm -rf "$stage"; return 1; }
        mkdir -p "$LOCAL_DIR/engines" "$LOCAL_DIR/prereqs" || { [ -z "$stage" ] || rm -rf "$stage"; return 1; }
        for keep_item in tunnels backups reports; do
            [ -e "$keep_dir/$keep_item" ] && mv "$keep_dir/$keep_item" "$LOCAL_DIR/"
        done
        rm -rf "$keep_dir"
        install_bundle_scripts "$bundle" "${2:-0}" || { rc=$?; [ -z "$stage" ] || rm -rf "$stage"; return "$rc"; }
        # engines/ = binaries + archives, prereqs/ = .deb files.
        local sub
        for sub in engines prereqs; do
            if [ -d "$bundle/$sub" ] && mt_local_source_has_packages "$bundle/$sub"; then
                deploy_binaries_from_dir "$bundle/$sub" || {
                    rc=1; echo "Scripts were installed, but some files in $sub/ failed to install." >&2
                }
            fi
        done
    elif mt_local_source_has_packages "$source"; then
        deploy_binaries_from_dir "$source" || rc=1
    else
        echo 'No complete MTunnel bundle or recognized installable packages were found in the selected source.' >&2
        rc=1
    fi
    [ -z "$stage" ] || rm -rf "$stage"
    return "$rc"
}

# Why a package file cannot be used (prints nothing when it is fine): size, checksum, ELF / .deb validity.
mt_package_problem() {
    local file="$1" item="$2" hash="${3:--}" size
    [ -s "$file" ] || { printf 'missing or empty file'; return 0; }
    size=$(wc -c < "$file")
    if [ "$hash" != - ] && [ "$(sha256sum "$file" | cut -d' ' -f1)" != "$hash" ]; then
        printf 'checksum differs from manifest.txt (stale or corrupted upload)'; return 0
    fi
    case "$item" in
        *.deb) dpkg-deb --info "$file" >/dev/null 2>&1 || printf 'not a valid .deb package (%s bytes)' "$size";;
        *.tar.gz|*.zip|*.gz) mt_is_archive_file "$file" || printf 'not a valid archive (%s bytes)' "$size";;
        *)     mt_valid_elf "$file" || printf 'not a valid %s ELF executable (%s bytes; empty or wrong upload?)' "$(uname -m)" "$size";;
    esac
    return 0
}
# Remote repo layout: <base>/engines/ (engines + archives) and <base>/prereqs/ (.deb files). Each folder has its own
# manifest.txt ("<sha256>  <n>" or just "<n>"), built with make_manifest.py. With it, a file dropped into the repo/mirror
# is picked up automatically (no script edit) and its sha256 is verified. Without a manifest the built-in
# ALL_PACKAGES list is used for that folder.
mt_pkg_sub() { case "$1" in *.deb) printf prereqs;; *) printf engines;; esac; }
# Appends "<hash|-> <n>" lines of the manifest of folder $2 (engines|prereqs) to $3. Fails if there is none.
mt_fetch_package_manifest() {
    local base="$1" sub="$2" out="$3" tmp line name hash n=0
    tmp=$(mktemp "$SECURE_TMP/manifest.XXXXXX") || return 1
    if ! mt_download "$(mt_cb_url "$base/$sub/manifest.txt")" "$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*($|#) ]] && continue
        if [[ "$line" =~ ^([0-9a-fA-F]{64})[[:space:]]+\*?([^[:space:]]+)[[:space:]]*$ ]]; then
            hash="${BASH_REMATCH[1],,}"; name="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
            hash='-'; name="${BASH_REMATCH[1]}"
        else continue; fi
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]] || continue   # plain file names only (no paths)
        if [ "$sub" == prereqs ]; then
            [[ "$name" == *.deb ]] || continue
        else
            case "$name" in *.deb) continue;; *.tar.gz|*.zip|*.gz|bh|backhaul|rathole|paqet|gost|haproxy|realm) ;; *) continue;; esac
        fi
        printf '%s %s\n' "$hash" "$name" >> "$out"; n=$((n+1))
    done < "$tmp"
    rm -f "$tmp"
    [ "$n" -gt 0 ]
}
# Build the download plan for kind cores|deps|all into $3 and set MT_PLAN_SOURCE (manifest|builtin).
mt_package_plan() {
    local base="$1" kind="$2" out="$3" all hash item sub
    local -A seen=()
    all=$(mktemp "$SECURE_TMP/plan.XXXXXX") || return 1
    : > "$all"; MT_PLAN_SOURCE=manifest
    for sub in engines prereqs; do
        case "$kind" in cores) [ "$sub" == engines ] || continue;; deps) [ "$sub" == prereqs ] || continue;; esac
        if ! mt_fetch_package_manifest "$base" "$sub" "$all"; then
            MT_PLAN_SOURCE=builtin
            for item in "${ALL_PACKAGES[@]}"; do
                [ "$(mt_pkg_sub "$item")" == "$sub" ] || continue
                printf '%s %s\n' - "$item" >> "$all"
            done
        fi
    done
    : > "$out"
    while read -r hash item; do
        [ -z "${seen[$item]:-}" ] || continue; seen[$item]=1
        case "$kind" in
            cores) [[ "$item" != *.deb ]] || continue;;
            deps)  [[ "$item" == *.deb ]] || continue;;
        esac
        printf '%s %s\n' "$hash" "$item" >> "$out"
    done < "$all"
    rm -f "$all"
    [ -s "$out" ]
}
# Final list of a group install: what is installed and what is not, with the reason for each.
# Written to $MT_REPORT_FILE when set (background runs), otherwise to the terminal.
mt_group_report() {
    local -n _rn="$1" _rs="$2" _rr="$3"
    local out=/dev/stdout i r reason okc=0 badc=0
    [ -n "${MT_REPORT_FILE:-}" ] && out="$MT_REPORT_FILE"
    {
        echo -e "\n  ${W}Installed${NC}"
        for i in "${!_rn[@]}"; do
            [ "${_rs[$i]}" == ok ] || continue
            okc=$((okc+1)); echo -e "    ${G}✔${NC} ${_rn[$i]}"
        done
        [ "$okc" -gt 0 ] || echo -e "    ${DIM}(none)${NC}"
        echo -e "\n  ${W}Not installed${NC}"
        for i in "${!_rn[@]}"; do
            [ "${_rs[$i]}" == failed ] || continue
            badc=$((badc+1)); reason=''
            for r in "${_rr[@]}"; do
                if [[ "$r" == "${_rn[$i]} — "* ]]; then reason="${r#* — }"; break; fi
            done
            echo -e "    ${R}✖${NC} ${_rn[$i]}  ${DIM}${reason:-unknown reason}${NC}"
        done
        [ "$badc" -gt 0 ] || echo -e "    ${DIM}(none)${NC}"
    } >> "$out" 2>/dev/null
    [ "$badc" -eq 0 ]
}
# Download + validate every item of the plan, then install what passed. One bad file no longer hides the
# reason or blocks the others: each failure is printed with its file name and cause (HTTP error, checksum,
# not an ELF/.deb, size). Returns 1 if anything failed; the valid items are still installed.
fetch_package_group() {
    local base="$1" kind="$2" show="${3:-0}" stage plan item hash file i size reason rc=0 n_ok=0 sys_arch
    local -a names=() hashes=() status=() reasons=() files=()
    sys_arch=$(uname -m)
    stage=$(mktemp -d "$SECURE_TMP/download.XXXXXX") || return 1
    plan="$stage/.plan"
    if ! mt_package_plan "$base" "$kind" "$plan"; then
        echo -e "  ${R}✖ Nothing to download for '${kind}' from ${base}${NC}" >&2; rm -rf "$stage"; return 1
    fi
    while read -r hash item; do hashes+=("$hash"); names+=("$item"); done < "$plan"
    [ "${MT_PLAN_SOURCE:-}" != builtin ] || echo -e "  ${DIM}● manifest.txt not found in engines/ or prereqs/ at the source; using the built-in package list.${NC}"
    for i in "${!names[@]}"; do
        item="${names[$i]}"; hash="${hashes[$i]}"; file="$stage/$item"; reason=''
        if ! mt_download "$(mt_cb_url "$base/$(mt_pkg_sub "$item")/$item")" "$file" 2>"$stage/.err"; then
            reason="download failed: $(grep -v '^[[:space:]]*$' "$stage/.err" 2>/dev/null | tail -n1)"
        else
            reason=$(mt_package_problem "$file" "$item" "$hash")
        fi
        if [ -n "$reason" ]; then rm -f "$file"; status+=(failed); reasons+=("$item — $reason"); rc=1
        else status+=(ok); n_ok=$((n_ok+1)); fi
    done
    if [ "$n_ok" -gt 0 ]; then
        for i in "${!names[@]}"; do [ "${status[$i]}" != ok ] || files+=("$stage/${names[$i]}" "$(mt_cache_dir_for "${names[$i]}")/${names[$i]}"); done
        mt_install_files 755 "${files[@]}" || rc=1
        # Engines go to their service locations; every .deb is installed (missing or older ones only).
        MT_DEB_FAILED=(); MT_DEPLOY_FAILED=()
        deploy_binaries_from_dir "$stage" || rc=1
        for i in "${!names[@]}"; do
            for item in "${MT_DEB_FAILED[@]}"; do [ "$item" != "${names[$i]}" ] || { status[$i]=failed; reasons+=("${names[$i]} — dpkg: ${MT_DEB_REASON[$item]:-failed}"); }; done
            for item in "${MT_DEPLOY_FAILED[@]}"; do [ "$item" != "${names[$i]}" ] || { status[$i]=failed; reasons+=("${names[$i]} — could not be installed into its service location"); }; done
        done
    fi
    if [ "$show" == 1 ]; then
        local current=0 version label
        for i in "${!names[@]}"; do
            item="${names[$i]}"; current=$((current+1)); label="$item"; version="${BIN_VERSIONS[$item]:-Core}"
            if [[ "$item" == *.deb ]]; then
                label="${item%%_*}"; version="${item#*_}"; version="${version%%_*}"
                [[ "$item" == *_* ]] || version='?'
            fi
            draw_item_progress "$current" "${#names[@]}" "$label" "$version" "${status[$i]}"
        done
    fi
    if [ "$show" == 1 ]; then
        mt_group_report names status reasons
    else
        for reason in "${reasons[@]}"; do echo -e "  ${R}✖ ${reason}${NC}" >&2; done
    fi
    rm -rf "$stage"
    return "$rc"
}
# GitHub: the branch archive of the same repo that MTUNNEL_GITHUB_BASE points to. Mirror: <base>/MTunnel.zip
# (upload a zip of the whole repo folder there).
mt_repo_archive_url() {
    local base="$1"
    if [[ "$base" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/(.+)$ ]]; then
        printf 'https://github.com/%s/%s/archive/refs/heads/%s.zip' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    else
        printf '%s/MTunnel.zip' "${base%/}"
    fi
}
# ONE mechanism for GitHub and the mirror: fetch the whole repo as a single archive (HTTP hosts cannot list a
# folder, an archive is the only thing both can serve), unpack it on the server, build engines/ and prereqs/ manifest.txt from the
# files that are really there, and install item by item. Anything that cannot be installed is reported with its
# reason and skipped; the next item is still processed.
#
# Writes <dir>/manifest.txt ("<sha256>  <name>") for every engine / .deb found in <dir>.
mt_build_local_manifest() {
    local dir="$1" f name n=0 tmp
    tmp=$(mktemp "$SECURE_TMP/localmanifest.XXXXXX") || return 1
    for f in "$dir"/*; do
        [ -f "$f" ] || continue; name="${f##*/}"
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]] || continue
        case "$name" in *.deb|*.tar.gz|*.zip|*.gz|bh|backhaul|rathole|paqet|gost|haproxy|realm) ;; *) continue;; esac
        printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$name" >> "$tmp"; n=$((n+1))
    done
    if [ "$n" -eq 0 ]; then rm -f "$tmp"; return 1; fi
    cat "$tmp" > "$dir/manifest.txt"; rm -f "$tmp"
}
# Install what the source folder <dir> contains (kind: cores | deps | all). Valid engines/archives are cached in
# /root/mtunnel/engines and .deb files in /root/mtunnel/prereqs; invalid ones are listed and skipped.
mt_install_packages_dir() {
    local dir="$1" kind="$2" show="${3:-0}" hash item i rc=0 reason n_ok=0 stage current=0 label version
    local -a names=() status=() reasons=() files=()
    if ! mt_build_local_manifest "$dir"; then
        echo -e "  ${R}✖ No engines or .deb packages found in the source folder.${NC}" >&2; return 1
    fi
    stage=$(mktemp -d "$SECURE_TMP/pkginst.XXXXXX") || return 1
    while read -r hash item; do
        case "$kind" in cores) [[ "$item" != *.deb ]] || continue;; deps) [[ "$item" == *.deb ]] || continue;; esac
        names+=("$item")
        reason=$(mt_package_problem "$dir/$item" "$item" "$hash")
        if [ -n "$reason" ]; then status+=(failed); reasons+=("$item — $reason"); rc=1
        else status+=(ok); cp -f "$dir/$item" "$stage/$item"; files+=("$dir/$item" "$(mt_cache_dir_for "$item")/$item"); n_ok=$((n_ok+1)); fi
    done < "$dir/manifest.txt"
    if [ "${#names[@]}" -eq 0 ]; then echo -e "  ${R}✖ Nothing of this kind in the source folder.${NC}" >&2; rm -rf "$stage"; return 1; fi
    if [ "$n_ok" -gt 0 ]; then
        mt_install_files 755 "${files[@]}" || rc=1
        MT_DEB_FAILED=(); MT_DEPLOY_FAILED=()
        deploy_binaries_from_dir "$stage" || rc=1
        for i in "${!names[@]}"; do
            for item in "${MT_DEB_FAILED[@]}"; do [ "$item" != "${names[$i]}" ] || { status[$i]=failed; reasons+=("${names[$i]} — dpkg: ${MT_DEB_REASON[$item]:-failed}"); }; done
            for item in "${MT_DEPLOY_FAILED[@]}"; do [ "$item" != "${names[$i]}" ] || { status[$i]=failed; reasons+=("${names[$i]} — could not be installed into its service location"); }; done
        done
    fi
    if [ "$show" == 1 ]; then
        for i in "${!names[@]}"; do
            item="${names[$i]}"; current=$((current+1)); label="$item"; version="${BIN_VERSIONS[$item]:-Core}"
            if [[ "$item" == *.deb ]]; then
                label="${item%%_*}"; version="${item#*_}"; version="${version%%_*}"; [[ "$item" == *_* ]] || version='?'
            fi
            draw_item_progress "$current" "${#names[@]}" "$label" "$version" "${status[$i]}"
        done
    fi
    if [ "$show" == 1 ]; then
        mt_group_report names status reasons
    else
        for reason in "${reasons[@]}"; do echo -e "  ${R}✖ ${reason}${NC}" >&2; done
    fi
    rm -rf "$stage"
    return "$rc"
}
# Download + unpack the repo archive. Sets MT_ARCHIVE_WORK (caller deletes), MT_ARCHIVE_ROOT (complete script
# bundle, or empty), MT_ARCHIVE_ENGINES and MT_ARCHIVE_PREREQS (its engines/ and prereqs/ folders, or empty).
mt_fetch_repo_archive() {
    local url="$1" f err sub dir
    MT_ARCHIVE_ROOT=''; MT_ARCHIVE_ENGINES=''; MT_ARCHIVE_PREREQS=''
    MT_ARCHIVE_WORK=$(mktemp -d "$SECURE_TMP/archive.XXXXXX") || return 1
    mkdir "$MT_ARCHIVE_WORK/extracted"; f="$MT_ARCHIVE_WORK/repo.archive"; err="$MT_ARCHIVE_WORK/.err"
    echo -e "  ${DIM}● Downloading the whole repository as one archive...${NC}"
    if ! mt_download "$url" "$f" 2>"$err"; then
        echo -e "  ${R}✖ Archive download failed: $(grep -v '^[[:space:]]*$' "$err" | tail -n1)${NC}" >&2; return 1
    fi
    if ! mt_is_archive_file "$f"; then echo -e "  ${R}✖ The link did not return an archive: ${url}${NC}" >&2; return 1; fi
    mt_ensure_unzip || true
    if ! mt_extract_archive "$f" "$MT_ARCHIVE_WORK/extracted"; then
        echo -e "  ${R}✖ Archive could not be extracted (unsupported, unsafe, or unzip missing).${NC}" >&2; return 1
    fi
    MT_ARCHIVE_ROOT=$(mt_find_bundle_root "$MT_ARCHIVE_WORK/extracted" 2>/dev/null) || MT_ARCHIVE_ROOT=''
    for sub in engines prereqs; do
        if [ -n "$MT_ARCHIVE_ROOT" ] && [ -d "$MT_ARCHIVE_ROOT/$sub" ]; then dir="$MT_ARCHIVE_ROOT/$sub"
        else dir=$(find "$MT_ARCHIVE_WORK/extracted" -maxdepth 4 -type d -name "$sub" -print -quit 2>/dev/null); fi
        if [ "$sub" == engines ]; then MT_ARCHIVE_ENGINES="$dir"; else MT_ARCHIVE_PREREQS="$dir"; fi
    done
    return 0
}
# what = scripts | engines | deps | all. Returns 9 when the archive is unavailable (caller falls back).
# For "all" the result is the script bundle's result; package failures are printed and flagged in OTA_PKG_FAILED.
ota_sync_from_archive() {
    local what="$1" url="$2" kind pkg_rc=0 script_rc=0 did_pkg=0
    OTA_PKG_FAILED=0
    if ! mt_fetch_repo_archive "$url"; then rm -rf "$MT_ARCHIVE_WORK"; return 9; fi
    if [ "$what" != scripts ]; then
        case "$what" in engines) kind=cores;; deps) kind=deps;; *) kind=all;; esac
        echo -e "\n  ${W}Prerequisites & engines${NC} ${DIM}(${what})${NC}"
        if [ "$kind" != deps ]; then
            if [ -z "$MT_ARCHIVE_ENGINES" ]; then echo -e "  ${R}✖ The archive has no engines folder.${NC}" >&2; pkg_rc=1
            else mt_install_packages_dir "$MT_ARCHIVE_ENGINES" cores 1 || pkg_rc=$?; fi
        fi
        if [ "$kind" != cores ]; then
            if [ -z "$MT_ARCHIVE_PREREQS" ]; then echo -e "  ${R}✖ The archive has no prereqs folder.${NC}" >&2; pkg_rc=1
            else mt_install_packages_dir "$MT_ARCHIVE_PREREQS" deps 1 || pkg_rc=$?; fi
        fi
        did_pkg=1
    fi
    if [ "$what" == scripts ] || [ "$what" == all ]; then
        echo -e "\n  ${W}Scripts${NC} ${DIM}(shared core + all modules)${NC}"
        if [ -z "$MT_ARCHIVE_ROOT" ]; then echo -e "  ${R}✖ No complete script bundle found in the archive.${NC}" >&2; script_rc=1
        else install_bundle_scripts "$MT_ARCHIVE_ROOT" 1 || script_rc=$?; fi
    fi
    rm -rf "$MT_ARCHIVE_WORK"
    if [ "$what" == all ]; then [ "$pkg_rc" == 0 ] || OTA_PKG_FAILED=1; return "$script_rc"; fi
    [ "$did_pkg" == 1 ] && return "$pkg_rc"
    return "$script_rc"
}
# Archive first; if it cannot be obtained, the old file-by-file download takes over.
ota_group_install() {
    local what="$1" scripts_base="$2" pkg_base="$3" rc=0
    ota_sync_from_archive "$what" "$(mt_repo_archive_url "$scripts_base")" || rc=$?
    if [ "$rc" == 9 ]; then
        echo -e "\n  ${Y}● Single-archive download unavailable; falling back to file-by-file download.${NC}\n"
        rc=0; OTA_PKG_FAILED=0
        case "$what" in
            scripts) sync_script_bundle "$scripts_base" 1 || rc=$?;;
            engines) fetch_package_group "$pkg_base" cores 1 || rc=$?;;
            deps)    fetch_package_group "$pkg_base" deps 1 || rc=$?;;
            all)     fetch_package_group "$pkg_base" cores 1 || OTA_PKG_FAILED=1
                     fetch_package_group "$pkg_base" deps 1 || OTA_PKG_FAILED=1
                     sync_script_bundle "$scripts_base" 1 || rc=$?;;
        esac
    fi
    return "$rc"
}
render_ota_menu() {
    draw_main_header
    echo -e "\n  ${FR}┌─[ Update & Local Install ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}R${NC} ${DIM}❯${NC} ${Y}Check for updates now${NC} ${DIM}(GitHub + Mirror)${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─[ INSTALL FULL PACKAGE ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}A${NC} ${DIM}❯${NC} ${C}Install Full Package from GitHub${NC} ${DIM}(scripts + engines + every .deb)${NC}"
    echo -e "  ${FR}├─${NC} ${W}B${NC} ${DIM}❯${NC} ${G}Install Full Package from Mirror${NC} ${DIM}(scripts + engines + every .deb)${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─[ DOWNLOAD FROM OFFICIAL GITHUB ]${NC}  $(src_status_text github)"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Download Scripts${NC} ${DIM}(All Modules + Shared Core)${NC}$(src_summary_badge github)"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Download Main Script${NC}$(src_module_badge github main)"
    echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Download Mirror Script${NC}$(src_module_badge github mmirror)"
    echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Download Engines${NC} ${DIM}(BH, Rathole, Paqet, GOST, HAProxy)${NC}"
    echo -e "  ${FR}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Download & Install Prerequisites${NC} ${DIM}(every .deb in prereqs)${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─[ DOWNLOAD FROM IRANIAN MIRROR ]${NC}  $(src_status_text mirror)"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Download Scripts${NC} ${DIM}(All Modules + Shared Core)${NC}$(src_summary_badge mirror)"
    echo -e "  ${FR}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${G}Download Main Script${NC}$(src_module_badge mirror main)"
    echo -e "  ${FR}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${G}Download Mirror Script${NC}$(src_module_badge mirror mmirror)"
    echo -e "  ${FR}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${G}Download Engines${NC} ${DIM}(BH, Rathole, Paqet, GOST, HAProxy)${NC}"
    echo -e "  ${FR}├─${NC} ${W}10${NC} ${DIM}❯${NC} ${G}Download & Install Prerequisites${NC} ${DIM}(every .deb in prereqs)${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─[ OFFLINE & MANUAL INSTALL ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}11${NC} ${DIM}❯${NC} ${M}Offline Install${NC} ${DIM}(Directory / ZIP / Archive)${NC}"
    echo -e "  ${FR}├─${NC} ${W}12${NC}${DIM}❯${NC} ${Y}Install from Link${NC} ${DIM}(Direct .sh / .zip URL)${NC}"
    echo -e "  ${FR}├─${NC} ${W}13${NC}${DIM}❯${NC} ${Y}Install via Code Paste${NC} ${DIM}(Nano / Ctrl+X to Save)${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├────────────────────────────${NC}"
    echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit to Dashboard${NC}\n"
}
draw_item_progress() {
    local n="$1" total="$2" label="$3" version="$4" state="${5:-ok}" width=30
    local percent=$((n*100/total)) filled empty bar_f bar_e suffix padding pad_len
    filled=$((percent*width/100)); empty=$((width-filled))
    bar_f=$(printf '%*s' "$filled" '' | tr ' ' '#')
    bar_e=$(printf '%*s' "$empty" '' | tr ' ' '-')
    suffix=" (v${version})"; [ "$state" != failed ] || suffix=' (FAILED)'
    pad_len=$((26-${#label}-${#suffix})); [ "$pad_len" -ge 0 ] || pad_len=0
    padding=$(printf '%*s' "$pad_len" '')
    if [ "$state" == failed ]; then
        printf "  ${R}✖${NC} ${R}%s%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$label" "$suffix" "$padding" "$bar_f" "$bar_e" "$percent"
    else
        printf "  ${G}✔${NC} ${W}%s${NC}${Y}%s${NC}%s ${W}[%s${DIM}%s${W}] %3d%%${NC}\n" "$label" "$suffix" "$padding" "$bar_f" "$bar_e" "$percent"
    fi
}
choose_module() {
    local i selection branch mode="${1:-OVERWRITE}"
    draw_main_header
    if [ "$mode" == EDITOR ]; then
        echo -e "\n  ${FR}┌─[ MANUAL CODE PASTE (NANO) ]${NC}\n  ${FR}│${NC}"
    else
        echo -e "\n  ${FR}┌─[ SELECT COMPONENT TARGET ]${NC}\n  ${FR}│${NC}"
    fi
    for i in "${!EDITABLE_COMPONENTS[@]}"; do
        branch='├─'; [ "$i" -ne "$((${#EDITABLE_COMPONENTS[@]}-1))" ] || branch='└─'
        echo -e "  ${FR}${branch}${NC} ${W}$((i+1))${NC} ${DIM}❯${NC} ${C}${EDITABLE_COMPONENTS[$i]}${NC} ${DIM}(${COMPONENT_MAP[${EDITABLE_COMPONENTS[$i]}]})${NC}$(module_update_badge "${EDITABLE_COMPONENTS[$i]}")"
    done
    echo -ne "\n  ${C}${mode} ❯❯ ${NC}"; read -r selection
    [[ "$selection" =~ ^[0-9]{1,2}$ ]] && ((10#$selection>=1 && 10#$selection<=${#EDITABLE_COMPONENTS[@]})) || return 1
    CHOSEN_MODULE="${EDITABLE_COMPONENTS[$((10#$selection-1))]}"
}

component_primary_target() {
    case "$1" in
        main) printf '%s\n' "$MTUNNEL_PATH";;
        common) printf '%s\n' '/usr/lib/mtunnel/common.sh';;
        install) printf '%s\n' "$LOCAL_DIR/install.sh";;
        *) printf '/usr/bin/%s\n' "$1";;
    esac
}
component_version_from_file() {
    local component="$1" file="$2"
    if [ "$component" == common ]; then
        sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$file" | head -n1
    else
        sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$file" | head -n1
    fi
}
validate_component_candidate() {
    local component="$1" file="$2" rel="${COMPONENT_MAP[$1]:-}" api layout
    [ -n "$rel" ] || return 1
    if [ "$component" == common ]; then
        [ -s "$file" ] && bash -n "$file" || return 1
        grep -q '^MTUNNEL_CORE_API=[0-9][0-9]*$' "$file" || return 1
        grep -q '^MTUNNEL_LAYOUT_REV=[0-9][0-9]*$' "$file" || return 1
        grep -q '^MTUNNEL_RELEASE_VERSION="[0-9][0-9.]*"$' "$file" || return 1
        api=$(sed -n 's/^MTUNNEL_CORE_API=\([0-9][0-9]*\)$/\1/p' "$file" | head -n1)
        layout=$(sed -n 's/^MTUNNEL_LAYOUT_REV=\([0-9][0-9]*\)$/\1/p' "$file" | head -n1)
        if [ "$api" != "${MTUNNEL_CORE_API:-}" ] || [ "$layout" != "${MTUNNEL_LAYOUT_REV:-}" ]; then
            echo "Shared-core API/layout change ($api/$layout) requires Full Bundle Sync; independent core updates may only keep the current API/layout contract." >&2
            return 1
        fi
        return 0
    fi
    mt_validate_script "$file" || return 1
    if [ "$component" == install ]; then
        head -n 5 "$file" | grep -Fq '# MTunnel standalone installer:' || { echo 'Incorrect installer script pasted. Existing file preserved.' >&2; return 1; }
        return 0
    fi
    mt_validate_module_role "$file" "$rel" || return 1
    mt_validate_module_core_contract "$file" || return 1
}
install_component_candidate() {
    local component="$1" file="$2" rel="${COMPONENT_MAP[$1]:-}" target current_v new_v
    validate_component_candidate "$component" "$file" || return 1
    target=$(component_primary_target "$component")
    current_v=$(component_version_from_file "$component" "$target" 2>/dev/null)
    new_v=$(component_version_from_file "$component" "$file")
    if [ -n "$current_v" ]; then mt_module_downgrade_allowed "$current_v" "$new_v" || return $?; fi
    case "$component" in
        common) mt_install_files 644 "$file" /usr/lib/mtunnel/common.sh "$file" "$LOCAL_DIR/core/common.sh";;
        install) mt_install_files 755 "$file" "$LOCAL_DIR/install.sh";;
        *) mt_install_script "$file" "$rel" "$target";;
    esac
}
capture_manual_component() {
    local output="$1" component="$2"
    [[ -t 0 && -t 1 ]] || { echo 'Manual Code Paste requires an interactive SSH terminal (TTY).' >&2; return 1; }
    mt_ensure_nano || return 1
    : > "$output" || return 1
    printf '\033[2J\033[H'
    mt_nano_edit "$output" || return 1
    [ -s "$output" ] || { echo 'Nothing saved; existing component preserved.' >&2; return 1; }
    mt_normalize_pasted_file "$output" || return 1
    [ -s "$output" ] || { echo 'Nothing left after cleaning the pasted text; existing component preserved.' >&2; return 1; }
    validate_component_candidate "$component" "$output"
}

ota_pause() {
    local dummy
    echo -ne "  ${DIM}Press Enter to return...${NC}\n"; read -r dummy
}
reload_dashboard() {
    [ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null || true
    [ -z "${STATS_PID:-}" ] || kill "$STATS_PID" 2>/dev/null || true
    exec "$MTUNNEL_PATH"
}
# Download ONE component (used for the main script) from the chosen source, confirm, install, reload.
ota_update_one_file() {
    local module="$1" base="$2" source_name="$3" rel work file target current_v new_ver confirm
    rel="${COMPONENT_MAP[$module]}"
    work=$(mktemp -d "$SECURE_TMP/onefile.XXXXXX") || return 1
    file="$work/input"
    draw_main_header
    echo -e "\n  ${FR}┌─[ DOWNLOAD ${module^^} SCRIPT FROM ${source_name} ]${NC}\n"
    if ! mt_download "$base/$rel?t=$(date +%s)" "$file"; then
        echo -e "  ${R}✖ Download failed. Existing script preserved.${NC}"
        rm -rf "$work"; return 1
    fi
    if ! validate_component_candidate "$module" "$file"; then
        echo -e "  ${R}✖ Downloaded file is invalid or incompatible. Existing script preserved.${NC}"
        echo -e "  ${DIM}  Tip: 'Download Scripts' (1/6) or 'Install Full Package' (A/B) validates with the bundle's own shared core.${NC}"
        rm -rf "$work"; return 1
    fi
    target=$(component_primary_target "$module")
    current_v=$(component_version_from_file "$module" "$target" 2>/dev/null)
    new_ver=$(component_version_from_file "$module" "$file")
    echo -e "  ${FR}├─${NC} ${W}Current Version :${NC} ${R}v${current_v:-Unknown}${NC}"
    echo -e "  ${FR}├─${NC} ${W}Remote Version  :${NC} ${G}v${new_ver:-Unknown}${NC}"
    echo -ne "  ${FR}└─${NC} ${C}Apply this script? (y/n): ${NC}"; read -r confirm
    if [[ "${confirm,,}" == y || "${confirm,,}" == yes ]]; then
        if install_component_candidate "$module" "$file"; then
            echo -e "\n  ${G}✔ ${rel} (v${new_ver:-Unknown}) updated successfully.${NC}\n"
            rm -rf "$work"; reload_dashboard
        else
            echo -e "\n  ${R}✖ Update failed. Previous script preserved.${NC}\n"
            rm -rf "$work"; return 1
        fi
    else
        echo -e "\n  ${Y}● Update cancelled by user.${NC}\n"
    fi
    rm -rf "$work"
}
show_ota_update_hub() {
    local option base_scripts base_packages source_name act work file module rel target confirm new_ver current_v sync_rc url pid last=0
    [ -r "$UPD_LAST_FILE" ] && read -r last < "$UPD_LAST_FILE"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [ $(( ${EPOCHSECONDS:-0} - last )) -ge 15 ]; then { check_all_updates_round >/dev/null 2>&1 & } 2>/dev/null; fi
    while true; do
        render_ota_menu
        read_with_refresh "  ${C}OTA-HUB ❯❯ ${NC}" option render_ota_menu || return 0
        option="${option//[$' \r']/}"
        case "$option" in
            0|'') return 0;;
            r|R)
                echo -e "\n  ${C}⟳${NC} ${W}Checking GitHub and the mirror...${NC}"
                check_all_updates_round >/dev/null 2>&1
                continue;;
            1|2|3|4|5|6|7|8|9|10)
                if [ "$option" -le 5 ]; then
                    base_scripts="$REPO_SCRIPTS"; base_packages="$REPO_SCRIPTS"; source_name='OFFICIAL GITHUB'
                else
                    base_scripts="$MIRROR_SCRIPTS"; base_packages="$MIRROR_PACKAGES"; source_name='IRANIAN MIRROR'
                fi
                act=$(( (option - 1) % 5 ))
                case "$act" in
                    0)  # Download scripts (whole bundle: shared core + every module + installer)
                        draw_main_header
                        echo -e "\n  ${FR}┌─[ DOWNLOADING ALL SCRIPTS FROM ${source_name} ]${NC}\n"
                        sync_rc=0; ota_group_install scripts "$base_scripts" "$base_packages" || sync_rc=$?
                        if [ "$sync_rc" == 0 ]; then
                            upd_clear
                            echo -e "\n\n  ${G}● Scripts downloaded and installed. Press Enter to reload core...${NC}\n"
                            read -r confirm
                            reload_dashboard
                        elif [ "$sync_rc" == 2 ]; then
                            echo -e "\n  ${Y}● Downgrade cancelled by operator. Existing scripts preserved.${NC}\n"
                        else
                            echo -e "\n  ${R}✖ Script download failed. Previous scripts preserved.${NC}\n" >&2
                        fi;;
                    1)  # Download the main script only
                        ota_update_one_file main "$base_scripts" "$source_name" || true;;
                    2)  # Download Mirror independently, using the normal component validation/rollback path
                        ota_update_one_file mmirror "$base_scripts" "$source_name" || true;;
                    3)  # Download engines (binary cores)
                        draw_main_header
                        echo -e "\n  ${FR}┌─[ DOWNLOADING ENGINES FROM ${source_name} (BH, RATHOLE, PAQET, GOST, HAPROXY) ]${NC}\n"
                        if ota_group_install engines "$base_scripts" "$base_packages"; then
                            echo -e "\n\n  ${G}● Engines downloaded and installed successfully.${NC}\n"
                        else
                            echo -e "\n  ${R}✖ Some engines failed (reasons above). Engines that passed validation were still installed.${NC}\n" >&2
                        fi;;
                    4)  # Download & install prerequisites: progress bar only, output goes to a log
                        draw_main_header
                        echo -e "\n  ${FR}┌─[ PREREQUISITES: ${source_name} ]${NC}\n"
                        pre_log=$(mktemp "$SECURE_TMP/prereq.XXXXXX.log") || pre_log="$SECURE_TMP/prereq.log"
                        pre_rc=$(mktemp "$SECURE_TMP/prereq.XXXXXX.rc") || pre_rc="$SECURE_TMP/prereq.rc"
                        pre_report=$(mktemp "$SECURE_TMP/prereq.XXXXXX.report") || pre_report="$SECURE_TMP/prereq.report"
                        : > "$pre_report"
                        ( export MT_REPORT_FILE="$pre_report"; ota_group_install deps "$base_scripts" "$base_packages" >"$pre_log" 2>&1; echo $? >"$pre_rc" ) &
                        pid=$!
                        draw_progress_bar "$pid" "Prerequisites"
                        wait "$pid" 2>/dev/null
                        cat "$pre_report" 2>/dev/null
                        if [ "$(cat "$pre_rc" 2>/dev/null)" == 0 ]; then
                            rm -f "$pre_log"
                            echo -e "  ${G}● All prerequisites downloaded and installed.${NC}\n"
                        else
                            echo -e "  ${R}✖ Some prerequisites were not installed (see above). Log: ${pre_log}${NC}\n" >&2
                        fi
                        rm -f "$pre_rc" "$pre_report"
                        ;;
                esac;;
            a|A|b|B)  # Everything in one press, same mechanism for GitHub and the mirror
                if [[ "$option" == [aA] ]]; then
                    base_scripts="$REPO_SCRIPTS"; base_packages="$REPO_SCRIPTS"; source_name='OFFICIAL GITHUB'
                else
                    base_scripts="$MIRROR_SCRIPTS"; base_packages="$MIRROR_PACKAGES"; source_name='IRANIAN MIRROR'
                fi
                draw_main_header
                echo -e "\n  ${FR}┌─[ INSTALLING FULL PACKAGE FROM ${source_name} ]${NC}\n"
                sync_rc=0; ota_group_install all "$base_scripts" "$base_packages" || sync_rc=$?
                if [ "$sync_rc" == 0 ]; then
                    upd_clear
                    [ "${OTA_PKG_FAILED:-0}" != 1 ] || echo -e "\n  ${Y}● Some packages failed (reasons above); everything else was installed.${NC}"
                    echo -e "\n\n  ${G}● Scripts installed. Press Enter to reload core...${NC}\n"
                    read -r confirm
                    reload_dashboard
                else
                    echo -e "\n  ${R}✖ Script install failed (reason above). Previous scripts preserved.${NC}\n" >&2
                fi;;
            11) show_local_install; continue;;
            12)  # Install from a direct link (single .sh component or a full .zip bundle)
                work=$(mktemp -d "$SECURE_TMP/link.XXXXXX") || return 1
                file="$work/input"
                draw_main_header
                echo -e "\n  ${FR}┌─[ INSTALL FROM LINK ]${NC}\n"
                echo -ne "  ${C}●${NC} ${W}Enter Direct HTTPS (.sh / .zip / .tar.gz) URL: ${NC}"; read -r url
                url="${url//[$'\r\n\t ']/}"
                [ -n "$url" ] || { rm -rf "$work"; continue; }
                [[ "$url" == https://* ]] || { echo -e "\n  ${R}✖ Only HTTPS links are supported.${NC}\n" >&2; rm -rf "$work"; ota_pause; continue; }
                url=$(mt_normalize_download_url "$url")
                mt_download "$url" "$file" &
                pid=$!
                draw_progress_bar "$pid" 'Downloading Custom Resource'
                if ! wait "$pid"; then
                    echo -e "\n  ${R}✖ Download failed! Check URL.${NC}\n" >&2
                    rm -rf "$work"; ota_pause; continue
                fi
                if mt_looks_like_html "$file"; then
                    echo -e "\n  ${R}✖ The link returned a web page, not a script/archive. Use a direct (raw) file link.${NC}\n" >&2
                    rm -rf "$work"; ota_pause; continue
                fi
                mkdir "$work/extracted"
                if mt_is_archive_file "$file"; then
                    # Only prepare unzip after we know this link is an archive; .sh links
                    # must not trigger apt/dpkg work. Missing unzip is reported and installed
                    # with the themed progress bar, or the validated Python extractor is used.
                    mt_ensure_unzip || true
                    if ! mt_extract_archive "$file" "$work/extracted"; then
                        echo -e "\n  ${R}✖ Archive could not be extracted (unsupported, unsafe, or unzip missing). Nothing was changed.${NC}\n" >&2
                        rm -rf "$work"; ota_pause; continue
                    fi
                    offline_local_deploy "$work/extracted" 1 && sync_rc=0 || sync_rc=$?
                    if [ "$sync_rc" == 0 ]; then
                        echo -e "\n  ${G}✔ Archive extracted and modules deployed successfully!${NC}\n"
                        rm -rf "$work"; reload_dashboard
                    elif [ "$sync_rc" == 2 ]; then
                        echo -e "\n  ${Y}● Downgrade cancelled by operator. Existing installation preserved.${NC}\n"
                    else
                        echo -e "\n  ${R}✖ Bundle deployment failed.${NC}\n" >&2
                    fi
                    rm -rf "$work"; ota_pause; continue
                fi
                echo -e "\n  ${C}● Link is not a supported archive; treating it as a single component script.${NC}"
                if ! choose_module; then
                    echo -e "\n  ${R}✖ Component selection cancelled.${NC}\n"
                    rm -rf "$work"; ota_pause; continue
                fi
                module="$CHOSEN_MODULE"
                if ! validate_component_candidate "$module" "$file"; then
                    echo -e "\n  ${R}✖ Invalid or incompatible component file.${NC}\n"
                    rm -rf "$work"; ota_pause; continue
                fi
                rel="${COMPONENT_MAP[$module]}"; target=$(component_primary_target "$module")
                new_ver=$(component_version_from_file "$module" "$file")
                current_v=$(component_version_from_file "$module" "$target" 2>/dev/null)
                draw_main_header
                echo -e "\n  ${FR}┌─[ VERSION CHECK & CONFIRMATION ]${NC}\n  ${FR}│${NC}"
                echo -e "  ${FR}├─${NC} ${W}Target Component:${NC} ${C}${module}${NC} ${DIM}(${rel})${NC}"
                echo -e "  ${FR}├─${NC} ${W}Current Version :${NC} ${R}v${current_v:-Unknown}${NC}"
                echo -e "  ${FR}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver:-Unknown}${NC}"
                echo -e "  ${FR}│${NC}"
                echo -ne "  ${FR}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}"; read -r confirm
                if [[ "${confirm,,}" == y || "${confirm,,}" == yes ]]; then
                    if install_component_candidate "$module" "$file"; then
                        echo -e "\n  ${G}✔ Component ${module} (v${new_ver:-Unknown}) successfully applied!${NC}\n"
                        rm -rf "$work"
                        [ "$module" == install ] || reload_dashboard
                    else
                        echo -e "\n  ${R}✖ Component install failed. Previous file preserved.${NC}\n" >&2
                    fi
                else
                    echo -e "\n  ${Y}● Link update cancelled by user.${NC}\n"
                fi
                rm -rf "$work";;
            13)  # Install via code paste
                work=$(mktemp -d "$SECURE_TMP/manual.XXXXXX") || return 1
                file="$work/input"
                if ! choose_module EDITOR; then rm -rf "$work"; continue; fi
                module="$CHOSEN_MODULE"
                : > "$file"
                if ! capture_manual_component "$file" "$module"; then
                    echo -e "\n  ${R}✖ Manual paste failed or cancelled. Previous component preserved.${NC}\n"
                    rm -rf "$work"; ota_pause; continue
                fi
                rel="${COMPONENT_MAP[$module]}"; target=$(component_primary_target "$module")
                new_ver=$(component_version_from_file "$module" "$file")
                current_v=$(component_version_from_file "$module" "$target" 2>/dev/null)
                draw_main_header
                echo -e "\n  ${FR}┌─[ VERSION CHECK & CONFIRMATION ]${NC}\n  ${FR}│${NC}"
                echo -e "  ${FR}├─${NC} ${W}Target Component:${NC} ${C}${module}${NC} ${DIM}(${rel})${NC}"
                echo -e "  ${FR}├─${NC} ${W}Current Version :${NC} ${R}v${current_v:-Unknown}${NC}"
                echo -e "  ${FR}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver:-Unknown}${NC}"
                echo -e "  ${FR}│${NC}"
                echo -ne "  ${FR}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}"; read -r confirm
                if [[ "${confirm,,}" == y || "${confirm,,}" == yes ]]; then
                    if install_component_candidate "$module" "$file"; then
                        echo -e "\n  ${G}✔ Component ${module} (v${new_ver:-Unknown}) successfully applied!${NC}\n"
                        rm -rf "$work"
                        [ "$module" == install ] || reload_dashboard
                    else
                        echo -e "\n  ${R}✖ Component install failed. Previous file preserved.${NC}\n" >&2
                    fi
                else
                    echo -e "\n  ${Y}● Code paste update cancelled by user.${NC}\n"
                fi
                rm -rf "$work";;
            *) continue;;
        esac
        ota_pause
    done
}
install_iperf3_source() {
    local src_choice="$1"
    local deb_iperf="iperf3_3.16-1build2_amd64.deb"
    local deb_lib="libiperf0_3.20-2.1_amd64.deb"
    case $src_choice in
        1)
            echo -e "\n  ${DIM}● Preparing APT environment...${NC}"
            # Wait for the package-manager lock; never kill apt/dpkg.
            dpkg --configure -a >/dev/null 2>&1 || true
            (
                DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 update -y -q >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -q libiperf0 iperf3 >/dev/null 2>&1
            ) &
            local pid=$!
            draw_progress_bar "$pid" "Installing iPerf3 via APT"
            wait "$pid" 2>/dev/null
            ldconfig 2>/dev/null || true
            ;;
        2|3)
            local base_url="$MIRROR_PACKAGES/prereqs"
            local fb_url="${MTUNNEL_GITHUB_BASE}/prereqs"
            local src_name="Iranian Mirror"
            if [ "$src_choice" == "3" ]; then
                base_url="${MTUNNEL_GITHUB_BASE}/prereqs"
                fb_url="$MIRROR_PACKAGES/prereqs"
                src_name="Official GitHub"
            fi
            echo -e "\n  ${DIM}● Fetching iPerf3 & Libs from ${src_name}...${NC}"
            (
                for deb in "$deb_lib" "$deb_iperf"; do
                    local out_f="$SECURE_TMP/$deb"
                    local ok=false
                    if command -v curl >/dev/null 2>&1; then
                        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 -o "$out_f" "$base_url/$deb" 2>/dev/null && ok=true
                    elif command -v wget >/dev/null 2>&1; then
                        wget -q  --header="Cache-Control: no-cache" --timeout=8 -O "$out_f" "$base_url/$deb" 2>/dev/null && ok=true
                    fi
                    if [ "$ok" != true ] || [ ! -s "$out_f" ]; then
                        if command -v curl >/dev/null 2>&1; then
                            curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 -o "$out_f" "$fb_url/$deb" 2>/dev/null || true
                        fi
                    fi
                done
            ) &
            local pid=$!
            draw_progress_bar "$pid" "Downloading iPerf3 & Libs"
            wait "$pid" 2>/dev/null
            for deb_f in "$SECURE_TMP"/libiperf*.deb "$SECURE_TMP"/iperf3*.deb; do
                if [ -s "$deb_f" ]; then
                    dpkg -i --force-confdef --force-confold "$deb_f" >/dev/null 2>&1
                    mkdir -p "$LOCAL_DIR/prereqs" 2>/dev/null
                    cp -f "$deb_f" "$LOCAL_DIR/prereqs/" 2>/dev/null
                    rm -f "$deb_f"
                fi
            done
            apt-get -o DPkg::Lock::Timeout=180 install -f -y -q >/dev/null 2>&1 || true
            ldconfig 2>/dev/null || true
            ;;
        4)
            echo -e "\n  ${DIM}● Checking local prereqs directory for iperf3 and libiperf...${NC}"
            local found_any=false
            for deb in $(find "$LOCAL_DIR/prereqs" -type f \( -name "*libiperf*.deb" -o -name "*iperf3*.deb" \) 2>/dev/null | sort -V); do
                if [ -s "$deb" ]; then
                    dpkg -i --force-confdef --force-confold "$deb" >/dev/null 2>&1
                    found_any=true
                fi
            done
            if [ "$found_any" = true ]; then
                apt-get -o DPkg::Lock::Timeout=180 install -f -y -q >/dev/null 2>&1 || true
                ldconfig 2>/dev/null || true
            else
                echo -e "  ${R}✖ No iPerf3 or libiperf .deb packages found in ${LOCAL_DIR}/prereqs/${NC}"
                sleep 2
                return 1
            fi
            ;;
        5)
            echo -ne "  ${C}● Enter HTTPS Direct (.deb) Link: ${NC}"; read -r custom_url
            custom_url=$(echo "$custom_url" | tr -d '\r\n ')
            [[ "$custom_url" == https://* ]] || { echo -e "  ${R}✖ Custom packages require HTTPS.${NC}"; return 1; }
            echo -e "\n  ${DIM}● Downloading custom package...${NC}"
            local dl_target="$SECURE_TMP/custom_iperf.deb"
            rm -f "$dl_target"
            if ! mt_download "$custom_url" "$dl_target"; then
                echo -e "  ${R}✖ HTTPS download failed.${NC}"; rm -f "$dl_target"; return 1
            fi
            if ! dpkg-deb --info "$dl_target" >/dev/null 2>&1; then
                echo -e "  ${R}✖ Downloaded file is not a valid Debian package.${NC}"; rm -f "$dl_target"; return 1
            fi
            if ! dpkg -i --force-confdef --force-confold "$dl_target" >/dev/null 2>&1; then
                apt-get -o DPkg::Lock::Timeout=180 install -f -y -q >/dev/null 2>&1 || { rm -f "$dl_target"; return 1; }
                dpkg -i --force-confdef --force-confold "$dl_target" >/dev/null 2>&1 || { rm -f "$dl_target"; return 1; }
            fi
            ldconfig 2>/dev/null || true
            mkdir -p "$LOCAL_DIR/prereqs" 2>/dev/null
            cp -f "$dl_target" "$LOCAL_DIR/prereqs/" 2>/dev/null
            rm -f "$dl_target"
            ;;
    esac
    if is_iperf3_valid; then
        echo -e "\n  ${G}✔ iPerf3 and shared libraries verified and functional.${NC}\n"
        sleep 1.5
        return 0
    else
        echo -e "\n  ${R}✖ Installation failed or shared libraries (libiperf.so.0) missing!${NC}\n"
        echo -e "  ${Y}Tip: Run 'apt-get install -y libiperf0 iperf3' or check package dependencies.${NC}\n"
        echo -ne "  ${DIM}Press Enter to return...${NC}\n"; read -r dummy
        return 1
    fi
}
run_iperf3() {
    if ! is_iperf3_valid; then
        draw_main_header
        echo -e "\n  ${FR}┌─[ IPERF3 BENCHMARK INSTALLER ]${NC}"
        echo -e "  ${FR}│${NC}"
        echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official APT Repository (apt-get install libiperf0 iperf3)${NC}"
        echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Iranian Mirror (.deb Packages)${NC} ${DIM}(${MTUNNEL_MIRROR_BASE})${NC}"
        echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Official GitHub Packages (.deb)${NC}"
        echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/engines)${NC}"
        echo -e "  ${FR}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Custom Direct Link (.deb)${NC}"
        echo -e "  ${FR}│${NC}"
        echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel / Return to Main Core${NC}\n"
        echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r inst_opt
        inst_opt=$(echo "$inst_opt" | tr -d '\r ')
        if [[ "$inst_opt" =~ ^[1-5]$ ]]; then
            install_iperf3_source "$inst_opt" || return 1
        else
            return 0
        fi
    fi
    render_iperf_menu() {
        draw_main_header
        echo -e "\n  ${FR}┌─[ IPERF3 BANDWIDTH BENCHMARK (Port: 5201 TCP/UDP) ]${NC}"
        echo -e "  ${FR}│${NC}"
        echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run as Server (Listener Mode)${NC} ${DIM}(Wait for peer connections)${NC}"
        echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run as Client (Sender Mode)${NC}   ${DIM}(Push bandwidth stream to server)${NC}"
        echo -e "  ${FR}│${NC}\n  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    }
    while true; do
        render_iperf_menu
        read_with_refresh "  ${C}iPerf3 ❯❯ ${NC}" i_opt render_iperf_menu || break
        i_opt=$(echo "$i_opt" | tr -d '\r ' )
        case $i_opt in
            1)
                echo -e "\n  ${G}● iPerf3 Server listening on port 5201 (Press Ctrl+C to stop)...${NC}\n"
                iperf3 -s -p 5201
                echo -ne "\n  ${DIM}Press Enter to return...${NC}\n"; read -r dummy ;;
            2)
                echo -ne "\n  ${C}●${NC} ${W}Enter Target Server IP / Tunnel IP: ${NC}"; read -r t_ip
                t_ip=$(echo "$t_ip" | tr -d '\r ' )
                [ -z "$t_ip" ] && continue
                echo -ne "  ${C}●${NC} ${W}Test Duration in Seconds [Default 10]: ${NC}"; read -r t_sec
                t_sec=${t_sec:-10}
                echo -e "\n  ${Y}● Running Benchmark against $t_ip (10s)...${NC}\n"
                iperf3 -c "$t_ip" -p 5201 -t "$t_sec"
                echo -ne "\n  ${DIM}Press Enter to return...${NC}\n"; read -r dummy ;;
            0) break ;;
        esac
    done
}
module_update_badge() {
    local m c v rest
    [ -r "$UPDATE_FILE" ] || return 0
    while IFS=: read -r m c v rest; do
        if [ "$m" = "$1" ] && [ -n "$v" ]; then printf ' %b' "${Y}(Update Available: v${v})${NC}"; return 0; fi
    done < "$UPDATE_FILE"
    return 0
}
updates_summary_badge() {
    local m c v rest n=0 first='' multi=0
    [ -s "$UPDATE_FILE" ] || return 0
    while IFS=: read -r m c v rest; do
        [ -n "$v" ] || continue
        n=$((n+1)); if [ -z "$first" ]; then first="$v"; elif [ "$first" != "$v" ]; then multi=1; fi
    done < "$UPDATE_FILE"
    [ "$n" -gt 0 ] || return 0
    if [ "$multi" = 0 ]; then printf ' %b' "${Y}(Update Available: v${first})${NC}"
    else printf ' %b' "${Y}(Updates Available)${NC}"; fi
}
# Per-source badges for the Update hub: each link shows the newer version it offers.
src_newfile() { case "$1" in github) printf '%s' "$UPD_NEW_GITHUB";; *) printf '%s' "$UPD_NEW_MIRROR";; esac; }
src_module_badge() { # github|mirror module
    local f m c v; f=$(src_newfile "$1")
    [ -r "$f" ] || return 0
    while IFS=: read -r m c v; do
        if [ "$m" = "$2" ] && [ -n "$v" ]; then printf ' %b' "${Y}(v${c} ➔ v${v})${NC}"; return 0; fi
    done < "$f"
    return 0
}
src_summary_badge() { # github|mirror
    local f m c v n=0 first='' multi=0; f=$(src_newfile "$1")
    [ -s "$f" ] || return 0
    while IFS=: read -r m c v; do
        [ -n "$v" ] || continue
        n=$((n+1)); if [ -z "$first" ]; then first="$v"; elif [ "$first" != "$v" ]; then multi=1; fi
    done < "$f"
    [ "$n" -gt 0 ] || return 0
    if [ "$multi" = 0 ]; then printf ' %b' "${Y}(${n} newer: v${first})${NC}"; else printf ' %b' "${Y}(${n} newer)${NC}"; fi
}
src_status_text() { # github|mirror
    local f st=''; case "$1" in github) f="$UPD_SRC_GITHUB";; *) f="$UPD_SRC_MIRROR";; esac
    if [ ! -r "$f" ]; then printf '%b' "${DIM}checking…${NC}"; return 0; fi
    read -r st < "$f"
    case "$st" in
        status\|ok) printf '%b' "${G}reachable${NC}";;
        *) printf '%b' "${R}unreachable${NC}";;
    esac
}
update_banner() { # one line under the header whenever ANY link has a newer version
    local m c v s out=''
    [ -s "$UPDATE_FILE" ] || return 0
    while IFS=: read -r m c v s; do
        [ -n "$v" ] || continue
        out+="${m} v${v} (${s}); "
    done < "$UPDATE_FILE"
    [ -n "$out" ] || return 0
    printf '  %b⬆ New version available:%b %s\n' "$Y" "$NC" "${out%; }"
}
# Menu "p": paste a Peer Code once; the matching module (gre/vxlan/rathole/backhaul/paqet) is opened
# by the code's own type and imports it directly (modules read MT_PEER_LINK on start-up).
use_peer_code() {
    local link kind mod rc=0
    draw_main_header
    echo -e "\n  ${FR}┌─[ USE PEER CODE ]${NC}\n"
    echo -ne "  ${C}●${NC} ${W}Paste Peer Code (q: back): ${NC}"
    read -r link || return 0
    link="${link//$'\r'/}"
    link="${link#"${link%%[![:space:]]*}"}"; link="${link%"${link##*[![:space:]]}"}"
    case "$link" in ''|q|Q) return 0;; esac
    if [[ "$link" =~ ^mtunnel://[0-9]+/([a-z]+)/ ]]; then kind="${BASH_REMATCH[1]}"; else kind=''; fi
    case "$kind" in
        gre) mod=mgre;;
        vxlan) mod=mxlan;;
        rathole) mod=mrathole;;
        backhaul) mod=mbackhaul;;
        paqet) mod=mpaqet;;
        *) echo -e "\n  ${R}✖ This is not a valid Peer Code. No changes made.${NC}"; ota_pause; return 0;;
    esac
    export MT_PEER_LINK="$link"
    run_mod "$mod" || rc=$?
    unset MT_PEER_LINK
    return "$rc"
}
render_main_menu() {
    draw_main_header
    printf '\n'
    update_banner
    printf '  %b┌─[ TUNNEL CORE & FABRIC MODULES ]%b\n' "$FR" "$NC"
    printf '  %b│%b\n' "$FR" "$NC"
    printf '  %b├─%b %bp%b %b❯%b %bUse Peer Code%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
    printf '  %b├─%b %b1%b %b❯%b %bGRE / GRE6 / IPIP Tunnel%b%s\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC" "$(module_update_badge mgre)"
    printf '  %b├─%b %b2%b %b❯%b %bVXLAN Virtual Mesh Fabric%b%s\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$M" "$NC" "$(module_update_badge mxlan)"
    printf '  %b├─%b %b3%b %b❯%b %bRathole Reverse Tunnel%b%s\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$R" "$NC" "$(module_update_badge mrathole)"
    printf '  %b├─%b %b4%b %b❯%b %bBackhaul Multiplexer%b%s\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC" "$(module_update_badge mbackhaul)"
    printf '  %b├─%b %b5%b %b❯%b %bPaqet Raw Packet KCP Tunnel%b%s\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$M" "$NC" "$(module_update_badge mpaqet)"
    printf '  %b│%b\n' "$FR" "$NC"
    printf '  %b├─[ TOOLS & BENCHMARK UTILITIES ]%b\n' "$FR" "$NC"
    printf '  %b│%b\n' "$FR" "$NC"
    printf '  %b├─%b %b6%b %b❯%b %bPort Forwarding Matrix (Mporter)%b%s\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC" "$(module_update_badge mporter)"
    printf '  %b├─%b %b7%b %b❯%b %bLink Test & Protocol Benchmark%b%s\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$Y" "$NC" "$(module_update_badge linktest)"
    printf '  %b├─%b %b8%b %b❯%b %biPerf3 Bandwidth Benchmark%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC"
    printf '  %b├─%b %b9%b %b❯%b %bMTunnel Doctor & Diagnostics%b%s\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC" "$(module_update_badge mdoctor)"
    printf '  %b├─%b %b10%b %b❯%b %bMirror (DNS & APT Optimizer)%b%s\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$M" "$NC" "$(module_update_badge mmirror)"
    printf '  %b│%b\n' "$FR" "$NC"
    printf '  %b├─[ SYSTEM UPDATE & MAINTENANCE ]%b\n' "$FR" "$NC"
    printf '  %b│%b\n' "$FR" "$NC"
    printf '  %b├─%b %b11%b %b❯%b %bUpdate & Local Install%b%s\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC" "$(updates_summary_badge)"
    printf '  %b├─%b %b12%b %b❯%b %bDelete All Tunnels & Forwardings%b %b(files stay)%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$Y" "$NC" "$DIM" "$NC"
    printf '  %b├─%b %b13%b %b❯%b %bNuclear Wipe (Uninstall)%b\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$R" "$NC"
    printf '  %b│%b\n' "$FR" "$NC"
    printf '  %b└─%b %b0%b %b❯%b %bExit Terminal%b\n\n' "$FR" "$NC" "$W" "$NC" "$DIM" "$NC" "$DIM" "$NC"
}
# Delete every tunnel and forwarding of every type, but keep all scripts, cores and packages.
delete_all_tunnels_keep_files() {
    local confirm step bin flag label path out rc failed=0 deleted=0 cron_tmp tbin table chain
    local -a steps=(
        "mporter|--wipe-mappings|MPorter forwardings"
        "mbackhaul|--delete-all|Backhaul tunnels"
        "mrathole|--delete-all|Rathole tunnels"
        "mpaqet|--delete-all|Paqet tunnels"
        "mgre|--delete-all|GRE / GRE6 / IPIP tunnels"
        "mxlan|--delete-all|VXLAN fabrics"
    )
    draw_main_header
    echo -e "\n  ${FR}╔════════════════════════════════════════════════════════════╗${NC}"
    printf '  %b║%b %b%-58s%b %b║%b\n' "$FR" "$NC" "$W" "Delete ALL Tunnels & Forwardings (Files Stay)" "$NC" "$FR" "$NC"
    echo -e "  ${FR}╚════════════════════════════════════════════════════════════╝${NC}\n"
    echo -e "  ${R}Will be deleted:${NC}"
    echo -e "  ${DIM}●${NC} All GRE / GRE6 / IPIP / VXLAN tunnels and their interfaces"
    echo -e "  ${DIM}●${NC} All Rathole, Backhaul and Paqet tunnels and their services"
    echo -e "  ${DIM}●${NC} All MPorter forwardings and every MTunnel firewall rule"
    echo -e "\n  ${G}Will be kept:${NC}"
    echo -e "  ${DIM}●${NC} All scripts and modules (mtunnel, mgre, mporter, ...)"
    echo -e "  ${DIM}●${NC} Tunnel cores and packages (bh, rathole, paqet, gost, haproxy)\n"
    echo -ne "  ${R}Type DELETE-TUNNELS to continue: ${NC}"; read -r confirm
    confirm="${confirm//[$' \r\n']/}"
    if [[ "$confirm" != "DELETE-TUNNELS" ]]; then
        echo -e "\n  ${Y}● Cancelled. Nothing was changed.${NC}"; sleep 1.5; return 0
    fi
    echo
    for step in "${steps[@]}"; do
        IFS='|' read -r bin flag label <<< "$step"
        path="/usr/bin/$bin"
        if [ ! -x "$path" ]; then
            echo -e "  ${DIM}○ ${label}: ${bin} not installed, skipped${NC}"; continue
        fi
        if ! grep -q -- "$flag" "$path" 2>/dev/null; then
            echo -e "  ${R}✖ ${label}: installed ${bin} is too old for this action. Update it, then retry.${NC}"; failed=1; continue
        fi
        if out=$(timeout 180 "$path" "$flag" </dev/null 2>&1); then
            echo -e "  ${G}✔${NC} ${label} deleted"; deleted=$((deleted+1))
        else
            rc=$?
            echo -e "  ${R}✖ ${label}: failed (exit ${rc})${NC}"; failed=1
            [ -z "$out" ] || printf '%s\n' "$out" | tail -n 2 | sed 's/^/      /'
        fi
    done
    # Final sweep: leftover tagged firewall rules and per-tunnel cron lines.
    for tbin in iptables ip6tables; do
        command -v "$tbin" >/dev/null 2>&1 || continue
        for table in filter nat mangle raw; do
            for chain in INPUT OUTPUT FORWARD PREROUTING POSTROUTING; do
                for tag in MGRE_ MXLAN_ MPORTER_ MBH_ RAT_ MPAQET_ OBFS_CNT_; do mt_delete_tagged_rules "$tbin" "$table" "$chain" "$tag" prefix; done
            done
        done
    done
    if command -v crontab >/dev/null 2>&1; then
        cron_tmp=$(mktemp "$SECURE_TMP/deltun-cron.XXXXXX")
        crontab -l 2>/dev/null | awk '!/mbackhaul@|mrathole@|mpaqet@/' > "$cron_tmp"
        crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
    fi
    systemctl daemon-reload 2>/dev/null || true
    echo
    if [ "$failed" -eq 0 ]; then
        echo -e "  ${G}✔ All tunnels and forwardings were deleted. Scripts, cores and packages were not touched.${NC}\n"
    else
        echo -e "  ${Y}● Finished with problems (see above). Scripts, cores and packages were not touched.${NC}\n"
    fi
    ota_pause
}
show_local_install() {
    local local_input
    draw_main_header
    echo -e "\n  ${FR}┌─[ OFFLINE LOCAL INSTALL ]${NC}\n"
    echo -ne "  ${C}●${NC} ${W}Enter local path (Directory, .zip, or .tar.gz) [Enter for current]: ${NC}"; read -r local_input
    draw_main_header
    echo -e "\n  ${FR}┌─[ INSTALLING FROM LOCAL SOURCE ]${NC}\n"
    local deploy_rc=0
    offline_local_deploy "$local_input" 1 || deploy_rc=$?
    if [ "$deploy_rc" == 0 ]; then
        echo -e "\n\n  ${G}● Local scripts and available binary packages installed successfully.${NC}\n"
    elif [ "$deploy_rc" == 2 ]; then
        echo -e "\n  ${Y}● Downgrade cancelled by operator. Existing installation preserved.${NC}\n"
    else echo -e "\n  ${R}✖ Local install failed. Check the reported error.${NC}\n" >&2; fi
    ota_pause
}
mtunnel_cli() {
    local cmd="${1:-}" src rc=0 local_path
    case "$cmd" in
        --version|-V)
            printf 'MTunnel %s\n' "$MODULE_VERSION"
            return 0
            ;;
        --linktest)
            shift
            ensure_module linktest || return 1
            exec /usr/bin/linktest "$@"
            ;;
        --doctor)
            shift
            ensure_module mdoctor || return 1
            exec /usr/bin/mdoctor "$@"
            ;;
        --status)
            ensure_module mdoctor || return 1
            exec /usr/bin/mdoctor --status
            ;;
        --report)
            ensure_module mdoctor || return 1
            exec /usr/bin/mdoctor --report
            ;;
        --sync|--sync-github)
            src="$REPO_SCRIPTS"
            printf 'MTunnel %s: syncing all scripts from Official GitHub...\n' "$MODULE_VERSION"
            sync_script_bundle "$src" 0 || rc=$?
            [ "$rc" -eq 0 ] && upd_clear
            [ "$rc" -eq 0 ] && printf 'Sync completed successfully.\n' || printf 'Sync failed; previous scripts were preserved.\n' >&2
            return "$rc"
            ;;
        --sync-mirror)
            src="$MIRROR_SCRIPTS"
            printf 'MTunnel %s: syncing all scripts from configured mirror...\n' "$MODULE_VERSION"
            sync_script_bundle "$src" 0 || rc=$?
            [ "$rc" -eq 0 ] && upd_clear
            [ "$rc" -eq 0 ] && printf 'Sync completed successfully.\n' || printf 'Sync failed; previous scripts were preserved.\n' >&2
            return "$rc"
            ;;
        --local)
            [ "$#" -ge 2 ] || { echo 'Usage: mtunnel --local PATH' >&2; return 2; }
            local_path="$2"
            offline_local_deploy "$local_path" 0
            return $?
            ;;
        --help|-h)
            cat <<EOF
MTunnel v$MODULE_VERSION
Usage: mtunnel [option]
  --linktest         Open Link Test & Protocol Benchmark
  --doctor [args]   Open MTunnel Doctor or pass Doctor arguments
  --status          Run non-interactive health scan
  --report          Export Doctor diagnostic report
  --sync            Sync all scripts from Official GitHub
  --sync-mirror     Sync all scripts from configured mirror
  --local PATH      Install/switch to a local bundle or archive
  --version         Show MTunnel version

Version direction is unrestricted. Upgrade and downgrade are both allowed;
script syntax plus shared-core API/layout compatibility are still validated.
EOF
            return 0
            ;;
        --*)
            printf 'Unknown option: %s\nUse: mtunnel --help\n' "$cmd" >&2
            return 2
            ;;
        *) return 2;;
    esac
}

if [[ "${1:-}" == --* || "${1:-}" == -V ]]; then
    mtunnel_cli "$@"
    exit $?
fi

while true; do
    render_main_menu
    read_with_refresh "  ${C}CORE ❯❯ ${NC}" opt render_main_menu || break
    opt=$(echo "$opt" | tr -d '\r ')
    case $opt in
        p|P) use_peer_code ;;
        1) run_mod "mgre" ;;
        2) run_mod "mxlan" ;;
        3) run_mod "mrathole" ;;
        4) run_mod "mbackhaul" ;;
        5) run_mod "mpaqet" ;;
        6) run_mod "mporter" ;;
        7) run_mod "linktest" ;;
        8) run_iperf3 ;;
        9) run_mod "mdoctor" ;;
        10) run_mod "mmirror" ;;
        0) kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null; clear; exit 0 ;;
        11) show_ota_update_hub ;;
        12) delete_all_tunnels_keep_files ;;
        13)
            draw_main_header
            echo -e "\n  ${R}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "  ${R}║${NC} ${W}MTunnel Nuclear Wipe (Complete Uninstaller)${NC}                  ${R}║${NC}"
            echo -e "  ${R}╚════════════════════════════════════════════════════════════╝${NC}\n"
            echo -e "  ${Y}⚠ Warning: This will stop and remove all tunnels, services,${NC}"
            echo -e "  ${Y}  MTunnel tunnel cores, MTunnel services, and MTunnel-owned configs!${NC}\n"
            echo -ne "  ${R}Type WIPE-MTUNNEL to continue: ${NC}"; read -r del_confirm
            del_confirm="${del_confirm//[$' \r\n']/}"
            if [[ "$del_confirm" == "WIPE-MTUNNEL" ]]; then
                echo -e "\n  ${C}● Terminating services and wiping files...${NC}"
                
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
                    cron_tmp=$(mktemp "$SECURE_TMP/uninstall-cron.XXXXXX")
                    crontab -l 2>/dev/null | awk '!/mbackhaul@|mrathole@|mpaqet@|\/usr\/bin\/mgre|\/usr\/bin\/mxlan|\/usr\/local\/bin\/mporter-watchdog/' > "$cron_tmp"
                    crontab "$cron_tmp"; rm -f "$cron_tmp"
                fi
                systemctl stop mgre-watchdog.timer mxlan-watchdog.timer mbackhaul-apply.service mrathole-apply.service mpaqet-apply.service mporter-iptables.service mporter-obfs.service 2>/dev/null || true
                systemctl disable mgre-watchdog.timer mxlan-watchdog.timer mbackhaul-apply.service mrathole-apply.service mpaqet-apply.service mporter-iptables.service mporter-obfs.service 2>/dev/null || true
                rm -f /etc/systemd/system/mgre-watchdog.{service,timer} /etc/systemd/system/mxlan-watchdog.{service,timer} /etc/systemd/system/{mbackhaul,mrathole,mpaqet}-apply.service /etc/systemd/system/mporter-{iptables,obfs}.service
                rm -f /usr/local/bin/mhealer_daemon.sh /usr/local/bin/mporter-{watchdog,iptables,obfs}.sh /etc/mhealer.conf
                rm -f /var/lock/mporter-state.lock /run/mporter-backends.tsv
                # Generic Gost/Realm installations may belong to another project. Remove only when MPorter explicitly marked ownership.
                if [ -f /etc/mporter/.owns_gost ]; then systemctl disable --now gost.service 2>/dev/null || true; rm -f /etc/systemd/system/gost.service /usr/local/bin/gost; rm -rf /etc/gost; fi
                if [ -f /etc/mporter/.owns_realm ]; then systemctl disable --now realm.service 2>/dev/null || true; rm -f /etc/systemd/system/realm.service /usr/local/bin/realm; rm -rf /etc/realm; fi
                # HAProxy is removed only when MPorter installed it itself (ownership marker); must run before /etc/mporter is deleted.
                if [ -f /etc/mporter/.owns_haproxy ]; then
                    systemctl disable --now haproxy.service 2>/dev/null || true
                    DEBIAN_FRONTEND=noninteractive apt-get purge -y haproxy >/dev/null 2>&1 || true
                    rm -rf /etc/haproxy /var/lib/haproxy
                fi
                rm -rf /run/mtunnel-healer
                systemctl stop mgre.service mxlan.service mporter.service mporter-watchdog.service mbackhaul@* mrathole@* mpaqet@* 2>/dev/null || true
                systemctl disable mgre.service mxlan.service mporter.service mporter-watchdog.service mbackhaul@* mrathole@* mpaqet@* 2>/dev/null || true
                
                rm -f /etc/systemd/system/mgre.service \
                      /etc/systemd/system/mxlan.service \
                      /etc/systemd/system/mporter.service \
                      /etc/systemd/system/mporter-watchdog.service \
                      /etc/systemd/system/mbackhaul@.service \
                      /etc/systemd/system/mrathole@.service \
                      /etc/systemd/system/mpaqet@.service 2>/dev/null || true
                systemctl daemon-reload 2>/dev/null || true
                # Only delete MTunnel-provisioned cores whose stored hash still matches.
                for core_bin in bh rathole paqet; do
                    mt_owned_binary_remove "$core_bin" "/usr/local/bin/$core_bin" "/usr/bin/$core_bin" || true
                done
                rm -rf /var/lib/mtunnel/owned-binaries /usr/lib/mtunnel /etc/mgre /etc/mporter /etc/mrathole /etc/mbackhaul /etc/paqet /root/mtunnel 2>/dev/null || true
                rm -f /usr/bin/mtunnel /usr/bin/mgre /usr/bin/mxlan /usr/bin/mbackhaul /usr/bin/mpaqet /usr/bin/mporter /usr/bin/mrathole /usr/bin/mdoctor /usr/bin/linktest /usr/bin/mmirror
                # MTunnel-owned persistent sysctl drop-ins (live kernel values are left untouched until the next reload/reboot).
                rm -f /etc/sysctl.d/99-mtunnel-doctor.conf /etc/sysctl.d/99-mtunnel-bbr.conf /etc/sysctl.d/99-mporter-ipv4.conf /etc/sysctl.d/99-mporter-ipv6.conf
                rm -f /usr/local/bin/mtunnel
                kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
                echo -e "\n  ${G}✓ MTunnel ecosystem completely wiped from this system.${NC}\n"; exit 0
            else
                echo -e "\n  ${Y}● Wipe cancelled.${NC}"; sleep 1.5
            fi
            ;;
    esac
done
