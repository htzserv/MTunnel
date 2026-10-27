#!/bin/bash
# MTunnel Smart — paired Iran controller / Foreign agent, multi-tunnel benchmark and failover (v15.0.1).
MODULE_VERSION="15.0.1"
MODULE_BUILD="2026102705"
MTUNNEL_REQUIRED_CORE_API=1
MTUNNEL_REQUIRED_LAYOUT_REV=2
SMART_API_REV=1
umask 077
# MTUNNEL_COMMON_LOADER -- common API 1, required by this module.
mt_load_common() {
    local script_dir candidate
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    for candidate in "$script_dir/core/common.sh" "$script_dir/../core/common.sh" /usr/lib/mtunnel/common.sh /root/mtunnel/core/common.sh; do
        if [[ -f "$candidate" && -r "$candidate" ]]; then
            source "$candidate" || return 1
            [[ "${MTUNNEL_CORE_API:-}" == "${MTUNNEL_REQUIRED_CORE_API}" && "${MTUNNEL_LAYOUT_REV:-}" == "${MTUNNEL_REQUIRED_LAYOUT_REV}" ]] && return 0
            echo "MTunnel: incompatible shared core: $candidate" >&2; return 1
        fi
    done
    echo 'MTunnel: core/common.sh is missing. Reinstall the complete bundle.' >&2
    return 1
}
mt_load_common || exit 1
unset -f mt_load_common

for _mt_fn in mt_hdr_draw mt_workspace_group mt_workspace_row mt_workspace_footer mt_workspace_pause mt_validate_script mt_install_script mt_check_update_both mt_update_available mt_download mt_link_read; do
    declare -F "$_mt_fn" >/dev/null 2>&1 || { echo "MTunnel: shared core is missing required helper: $_mt_fn" >&2; exit 1; }
done
unset _mt_fn

[ "$EUID" -eq 0 ] || { echo 'Run MTunnel Smart with sudo.' >&2; exit 1; }

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'; FR='\033[1;33m'
SMART_DIR=/etc/mtunnel/smart
GROUP_DIR="$SMART_DIR/groups"
AGENT_PORT=29876
IPERF_PORT=5201
AGENT_SERVICE=/etc/systemd/system/mtunnel-smart-agent.service
WATCH_SERVICE=/etc/systemd/system/mtunnel-smart-watchdog.service
WATCH_TIMER=/etc/systemd/system/mtunnel-smart-watchdog.timer
SECURE_TMP=/root/mtunnel/tmp
INSTALL_PATH=/usr/bin/msmart
UPDATE_CHECK_INTERVAL=600
mkdir -p "$SMART_DIR" "$GROUP_DIR" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SMART_DIR" "$GROUP_DIR" "$SECURE_TMP" 2>/dev/null

# Smart update status is build-aware. Module versions may stay on the same release
# line while a hotfix is published, so MODULE_BUILD is compared when versions match.
SMART_UPD_GH="$SECURE_TMP/.msmart_update_github"
SMART_UPD_MIR="$SECURE_TMP/.msmart_update_mirror"
SMART_UPD_LOCK="$SECURE_TMP/.msmart_update.lock"
SMART_UPD_REFRESH_AGE=90

smart_fetch_remote_meta() { # url -> version|build
    local url="$1" tmp line ver='' build='0' n=0
    tmp=$(mktemp "$SECURE_TMP/.msmart-meta.XXXXXX") || return 1
    url=$(mt_cb_url "$url")
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -r 0-8191 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
            --connect-timeout 3 --max-time 8 -o "$tmp" "$url" 2>/dev/null || { rm -f "$tmp"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp" --header='Range: bytes=0-8191' --header='Cache-Control: no-cache' \
            --timeout=8 "$url" 2>/dev/null || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp"; return 1
    fi
    while IFS= read -r line && [ $((n++)) -lt 180 ]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^MODULE_VERSION=\"([0-9][0-9.]*)\"$ ]]; then ver="${BASH_REMATCH[1]}"; fi
        if [[ "$line" =~ ^MODULE_BUILD=\"?([0-9]+)\"?$ ]]; then build="${BASH_REMATCH[1]}"; fi
        [ -n "$ver" ] && [ "$build" != 0 ] && break
    done < "$tmp"
    rm -f "$tmp"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
    [[ "$build" =~ ^[0-9]+$ ]] || build=0
    printf '%s|%s\n' "$ver" "$build"
}

smart_meta_newer() { # remote_ver remote_build
    local rv="${1:-}" rb="${2:-0}"
    mt_version_newer "$rv" "$MODULE_VERSION" 2>/dev/null && return 0
    [ "$rv" = "$MODULE_VERSION" ] || return 1
    [[ "$rb" =~ ^[0-9]+$ && "$MODULE_BUILD" =~ ^[0-9]+$ ]] || return 1
    ((10#$rb > 10#$MODULE_BUILD))
}

smart_write_update_state() { # state-file rc meta
    local file="$1" rc="$2" meta="${3:-}" now tmp ver='' build='0'
    now=$(date +%s 2>/dev/null || echo 0)
    tmp=$(mktemp "$SECURE_TMP/.msmart-state.XXXXXX") || return 1
    if [ "$rc" -eq 0 ] && [[ "$meta" == *'|'* ]]; then
        IFS='|' read -r ver build <<< "$meta"
        printf 'ok|%s|%s|%s\n' "$ver" "${build:-0}" "$now" > "$tmp"
    else
        printf 'down|||%s\n' "$now" > "$tmp"
    fi
    mv -f "$tmp" "$file"
}

smart_check_update_bg() {
    local gtmp mtmp gp mp gr=1 mr=1
    exec 8>"$SMART_UPD_LOCK" || return 1
    flock -n 8 || return 0
    gtmp=$(mktemp "$SECURE_TMP/.msmart-gh.XXXXXX") || return 1
    mtmp=$(mktemp "$SECURE_TMP/.msmart-mi.XXXXXX") || { rm -f "$gtmp"; return 1; }
    smart_fetch_remote_meta "${MTUNNEL_GITHUB_BASE}/tunnels/msmart.sh" > "$gtmp" 2>/dev/null & gp=$!
    smart_fetch_remote_meta "${MTUNNEL_MIRROR_BASE}/tunnels/msmart.sh" > "$mtmp" 2>/dev/null & mp=$!
    wait "$gp"; gr=$?
    wait "$mp"; mr=$?
    smart_write_update_state "$SMART_UPD_GH" "$gr" "$(cat "$gtmp" 2>/dev/null)"
    smart_write_update_state "$SMART_UPD_MIR" "$mr" "$(cat "$mtmp" 2>/dev/null)"
    rm -f "$gtmp" "$mtmp"
    # Remove legacy version-only caches so stale data cannot paint the badge.
    rm -f "$SECURE_TMP/.msmart_remote_ver" "$SECURE_TMP/.msmart_remote_ver_github" "$SECURE_TMP/.msmart_remote_ver_mirror"
}

smart_update_select() {
    local file st rv rb ts src bestv='' bestb=0 bestsrc='' any=0 newest=0
    SMART_UPD_ANY_OK=0; SMART_UPD_AVAILABLE=0; SMART_UPD_VERSION=''; SMART_UPD_BUILD=0; SMART_UPD_SOURCES=''; SMART_UPD_LAST=0
    for src in GitHub Mirror; do
        [ "$src" = GitHub ] && file="$SMART_UPD_GH" || file="$SMART_UPD_MIR"
        [ -s "$file" ] || continue
        IFS='|' read -r st rv rb ts < "$file"
        [[ "$ts" =~ ^[0-9]+$ ]] && ((ts > SMART_UPD_LAST)) && SMART_UPD_LAST=$ts
        [ "$st" = ok ] || continue
        SMART_UPD_ANY_OK=1
        smart_meta_newer "$rv" "${rb:-0}" || continue
        if [ "$newest" -eq 0 ] || mt_version_newer "$rv" "$bestv" 2>/dev/null || { [ "$rv" = "$bestv" ] && [[ "${rb:-0}" =~ ^[0-9]+$ ]] && ((10#${rb:-0} > 10#$bestb)); }; then
            bestv="$rv"; bestb="${rb:-0}"; bestsrc="$src"; newest=1
        elif [ "$rv" = "$bestv" ] && [ "${rb:-0}" = "$bestb" ]; then
            bestsrc+="+$src"
        fi
    done
    if [ "$newest" -eq 1 ]; then
        SMART_UPD_AVAILABLE=1; SMART_UPD_VERSION="$bestv"; SMART_UPD_BUILD="$bestb"; SMART_UPD_SOURCES="$bestsrc"
    fi
}

smart_update_watcher_loop() {
    while true; do smart_check_update_bg; sleep "$UPDATE_CHECK_INTERVAL"; done
}
if [[ "${1:-}" != --* ]]; then
    smart_update_watcher_loop & WATCHER_PID=$!
    trap '[ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null || true' EXIT
fi

smart_update_badge() {
    smart_update_select
    if [ "$SMART_UPD_AVAILABLE" -eq 1 ]; then
        if [ "$SMART_UPD_VERSION" = "$MODULE_VERSION" ] && [ "$SMART_UPD_BUILD" -gt 0 ] 2>/dev/null; then
            printf ' %b(Update: v%s build %s)%b' "$Y" "$SMART_UPD_VERSION" "$SMART_UPD_BUILD" "$NC"
        else
            printf ' %b(Update Available: v%s)%b' "$Y" "$SMART_UPD_VERSION" "$NC"
        fi
    elif [ "$SMART_UPD_ANY_OK" -eq 1 ]; then
        printf ' %b(Up to date)%b' "$DIM" "$NC"
    elif [ -s "$SMART_UPD_GH" ] || [ -s "$SMART_UPD_MIR" ]; then
        printf ' %b(Update check unavailable)%b' "$R" "$NC"
    else
        printf ' %b(Checking...)%b' "$DIM" "$NC"
    fi
}

smart_pause() { mt_workspace_pause; }
smart_header_state() {
    local gd groups=0 paired='UNPAIRED' pair_col="$Y" agent='OFF' agent_col="$DIM"
    local watchdog='OFF' watchdog_col="$DIM" ports=0 peer4='---' active='' label='' score='' svc count=0
    local primary_gid='' primary_label='' primary_score='' primary_state=0
    MT_HDR_ROWS=''
    if [ -s "$SMART_DIR/peer.conf" ]; then
        paired='PAIRED'; pair_col="$G"
        peer4=$(mt_link_read "$SMART_DIR/peer.conf" FOREIGN_IPV4 2>/dev/null || true)
        [ -n "$peer4" ] || peer4='---'
    fi
    if systemctl is-active --quiet mtunnel-smart-agent.service 2>/dev/null; then agent='ON'; agent_col="$G"; fi
    if systemctl is-active --quiet mtunnel-smart-watchdog.timer 2>/dev/null; then watchdog='ON'; watchdog_col="$G"; fi
    for gd in "$GROUP_DIR"/*; do
        [ -d "$gd" ] || continue
        groups=$((groups+1))
        svc=$(mt_link_read "$gd/group.conf" SERVICE_PORTS 2>/dev/null || true)
        if [ -n "$svc" ]; then
            count=$(awk -F, '{print NF}' <<< "$svc" 2>/dev/null || echo 0)
            [[ "$count" =~ ^[0-9]+$ ]] && ports=$((ports+count))
        fi
        active=$(cat "$gd/active.state" 2>/dev/null || true)
        IFS='|' read -r _ label score <<< "$active"
        # Show only one group summary in the main Smart dashboard. Prefer an active group.
        if [ -z "$primary_gid" ] || { [ "$primary_state" -eq 0 ] && [ -n "$label" ]; }; then
            primary_gid=$(basename "$gd"); primary_label="${label:-OFF}"; primary_score="${score:-DOWN}"
            primary_state=0; [ -n "$label" ] && primary_state=1
        fi
    done
    if [ "$groups" -gt 0 ]; then
        MT_HDR_ROWS+="${primary_state}|${primary_gid:-SmartGroup}|SMART|${peer4}|${primary_label:-OFF}|---|---|${primary_score:-DOWN}|${primary_label:-OFF}"
    fi
    SMART_HDR_GROUPS="$groups"; SMART_HDR_ACTIVE="${primary_label:-OFF}"
    SMART_HDR_PAIRED="$paired"; SMART_HDR_PAIR_COL="$pair_col"
    SMART_HDR_AGENT="$agent"; SMART_HDR_AGENT_COL="$agent_col"; SMART_HDR_WATCHDOG="$watchdog"; SMART_HDR_WATCHDOG_COL="$watchdog_col"
    SMART_HDR_PORTS="$ports"
}

smart_header() {
    smart_header_state
    MT_HDR_EMPTY_TEXT="No Smart groups are configured on this host."
    local group_col="$DIM"; [ "$SMART_HDR_GROUPS" -gt 0 ] 2>/dev/null && group_col="$G"
    mt_hdr_draw "MSmart Core v${MODULE_VERSION}" "Groups|${SMART_HDR_GROUPS}|${group_col}" \
        "Active|${SMART_HDR_ACTIVE:-OFF}|$([ "${SMART_HDR_ACTIVE:-OFF}" != OFF ] && printf '%s' "$G" || printf '%s' "$DIM")" \
        "Pair|${SMART_HDR_PAIRED}|${SMART_HDR_PAIR_COL}" \
        "Watchdog|${SMART_HDR_WATCHDOG}|${SMART_HDR_WATCHDOG_COL}" \
        "Ports|${SMART_HDR_PORTS}|${C}"
}

smart_install_update_file() { # candidate path
    local candidate="$1" new_ver confirm
    mt_validate_script "$candidate" || { echo -e "  ${R}✖ Invalid Bash module. Installed module preserved.${NC}"; return 1; }
    new_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$candidate" | head -n1)
    [[ "$new_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo -e "  ${R}✖ MODULE_VERSION was not found.${NC}"; return 1; }
    mt_module_downgrade_allowed "$MODULE_VERSION" "$new_ver" || return 1
    echo -e "\n  ${FR}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}Current Version :${NC} ${Y}v${MODULE_VERSION}${NC}"
    echo -e "  ${FR}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
    echo -ne "  ${FR}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}"; read -r confirm
    [[ "${confirm,,}" == y || "${confirm,,}" == yes ]] || { echo -e "  ${Y}● Update cancelled.${NC}"; return 0; }
    mt_install_script "$candidate" "tunnels/msmart.sh" "$INSTALL_PATH" "$0" || { echo -e "  ${R}✖ Update failed. Previous module preserved.${NC}"; return 1; }
    if systemctl is-active --quiet mtunnel-smart-agent.service 2>/dev/null; then
        systemctl restart mtunnel-smart-agent.service >/dev/null 2>&1 || echo -e "  ${Y}⚠ Agent service could not be restarted automatically.${NC}"
    fi
    echo -e "  ${G}✔ MSmart updated successfully. Restarting module...${NC}"
    [ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null || true
    exec "$INSTALL_PATH"
}
smart_self_update() { # 1 github, 2 mirror, 3 direct, 4 manual
    local src="$1" url tmp
    tmp=$(mktemp "$SECURE_TMP/msmart-update.XXXXXX") || return 1
    case "$src" in
        1) url="${MTUNNEL_GITHUB_BASE}/tunnels/msmart.sh";;
        2) url="${MTUNNEL_MIRROR_BASE}/tunnels/msmart.sh";;
        3) echo -ne "  ${C}●${NC} ${W}Direct .sh URL: ${NC}"; read -r url;;
        4) mt_capture_manual_script "$tmp" || { rm -f "$tmp"; return 1; }; smart_install_update_file "$tmp"; rm -f "$tmp"; return $?;;
        *) rm -f "$tmp"; return 1;;
    esac
    echo -e "  ${C}⟳${NC} ${W}Downloading MSmart update...${NC}"
    mt_download "$url" "$tmp" || { rm -f "$tmp"; echo -e "  ${R}✖ Download failed.${NC}"; return 1; }
    smart_install_update_file "$tmp"; local rc=$?; rm -f "$tmp"; return "$rc"
}
smart_local_install() {
    local path tmp
    echo -ne "  ${C}●${NC} ${W}Local msmart.sh path [${LOCAL_DIR:-/root/mtunnel}/tunnels/msmart.sh]: ${NC}"; read -r path
    path="${path:-${LOCAL_DIR:-/root/mtunnel}/tunnels/msmart.sh}"
    [ -f "$path" ] || { echo -e "  ${R}✖ File not found: $path${NC}"; return 1; }
    tmp=$(mktemp "$SECURE_TMP/msmart-local.XXXXXX") || return 1
    cp -f -- "$path" "$tmp" || { rm -f "$tmp"; return 1; }
    smart_install_update_file "$tmp"; local rc=$?; rm -f "$tmp"; return "$rc"
}
smart_update_source_text() { # state-file label
    local file="$1" label="$2" st rv rb ts age now suffix
    [ -s "$file" ] || { printf '%s%s: checking...%s' "$DIM" "$label" "$NC"; return; }
    IFS='|' read -r st rv rb ts < "$file"
    if [ "$st" != ok ]; then printf '%s%s: unavailable%s' "$R" "$label" "$NC"; return; fi
    if smart_meta_newer "$rv" "${rb:-0}"; then
        suffix="v${MODULE_VERSION}"
        [ "${MODULE_BUILD:-0}" -gt 0 ] 2>/dev/null && suffix+=" b${MODULE_BUILD}"
        suffix+=" → v${rv}"
        [ "${rb:-0}" -gt 0 ] 2>/dev/null && suffix+=" b${rb}"
        printf '%s%s: %s%s' "$Y" "$label" "$suffix" "$NC"
    else
        suffix="v${rv}"
        [ "${rb:-0}" -gt 0 ] 2>/dev/null && suffix+=" b${rb}"
        printf '%s%s: %s • current%s' "$DIM" "$label" "$suffix" "$NC"
    fi
}

smart_update_refresh_now() {
    local now age newest=0 st rv rb ts
    now=$(date +%s 2>/dev/null || echo 0)
    for f in "$SMART_UPD_GH" "$SMART_UPD_MIR"; do
        [ -s "$f" ] || { newest=0; break; }
        IFS='|' read -r st rv rb ts < "$f"
        [[ "$ts" =~ ^[0-9]+$ ]] || { newest=0; break; }
        ((ts > newest)) && newest=$ts
    done
    age=$((now-newest))
    if [ "$newest" -eq 0 ] || [ "$age" -ge "$SMART_UPD_REFRESH_AGE" ]; then
        echo -e "  ${C}⟳${NC} ${W}Refreshing update status...${NC}"
        smart_check_update_bg
    fi
}

smart_update_menu() {
    local opt
    smart_update_refresh_now
    while true; do
        smart_header
        mt_workspace_group 'UPDATE STATUS — MSMART' first
        mt_workspace_row '' "Local: v${MODULE_VERSION} • build ${MODULE_BUILD}" "$W"
        mt_workspace_row '' "$(smart_update_source_text "$SMART_UPD_GH" GitHub)" "$C"
        mt_workspace_row '' "$(smart_update_source_text "$SMART_UPD_MIR" Mirror)" "$G"
        mt_workspace_group 'FULL MTUNNEL PACKAGE — REQUIRED FOR SMART'
        mt_workspace_row A 'Install Full Package from GitHub' "$C" 'scripts + tunnel cores + prerequisites'
        mt_workspace_row B 'Install Full Package from Mirror' "$G" 'scripts + tunnel cores + prerequisites'
        mt_workspace_group 'UPDATE & LOCAL INSTALL — MSMART'
        mt_workspace_row 1 'Install Script From Github' "$C"
        mt_workspace_row 2 'Install Script From Iranian Mirror' "$G"
        mt_workspace_row 3 'Install Script From Direct Link' "$Y"
        mt_workspace_row 4 'Paste Script Code Manually' "$M"
        mt_workspace_row 5 'Install Local msmart.sh' "$W"
        mt_workspace_row 6 'Refresh Update Status Now' "$C"
        mt_workspace_footer 'Return to Smart Menu'
        echo -ne "  ${C}MSMART UPDATE ❯❯ ${NC}"; read -r opt
        case "$opt" in
            a|A) smart_install_full_package github; smart_pause;;
            b|B) smart_install_full_package mirror; smart_pause;;
            1) smart_self_update 1; smart_pause;;
            2) smart_self_update 2; smart_pause;;
            3) smart_self_update 3; smart_pause;;
            4) smart_self_update 4; smart_pause;;
            5) smart_local_install; smart_pause;;
            6) smart_check_update_bg; smart_pause;;
            0|q|Q) return 0;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1;;
        esac
    done
}

smart_local_ipv4() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
    [ -n "$ip" ] || ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/");print a[1];exit}')
    mt_valid_ipv4 "$ip" && printf '%s' "$ip" || printf 'Unknown'
}
smart_local_ipv6() {
    local ip
    # Prefer the source address selected by the default IPv6 route; fall back to a stable global address.
    ip=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
    if ! { [ -n "$ip" ] && mt_valid_ipv6 "$ip" && [[ "${ip,,}" != fe80:* ]]; }; then
        ip=$(ip -6 -o addr show scope global 2>/dev/null | grep -vE 'temporary|deprecated|tentative' | awk '{split($4,a,"/");print a[1];exit}')
    fi
    if [ -n "$ip" ] && mt_valid_ipv6 "$ip" && [[ "${ip,,}" != fe80:* ]]; then printf '%s' "${ip,,}"; else printf 'Unknown'; fi
}
smart_random_hex() { od -An -tx1 -N"${1:-24}" /dev/urandom 2>/dev/null | tr -d ' \n'; }
smart_sha() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
smart_b64url_encode_file() { gzip -9n < "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
smart_b64url_decode() {
    local s="$1" pad
    pad=$(printf '%s' "$s" | tr '_-' '/+')
    case $((${#pad}%4)) in 2) pad+='==';; 3) pad+='=';; 1) return 1;; esac
    printf '%s' "$pad" | base64 -d 2>/dev/null | gunzip 2>/dev/null
}
smart_pair_encode() {
    local ip6="$1" port="$2" fp="$3" secret="$4" expires="$5" tmp enc sum
    tmp=$(mktemp /root/mtunnel/tmp/smart-pair.XXXXXX) || return 1
    printf 'V=1\nIP6=%s\nPORT=%s\nFP=%s\nSECRET=%s\nEXPIRES=%s\n' "$ip6" "$port" "$fp" "$secret" "$expires" > "$tmp"
    enc=$(smart_b64url_encode_file "$tmp") || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    sum=$(printf '%s' "1/$enc" | sha256sum | awk '{print substr($1,1,16)}')
    printf 'mtpair://1/%s.%s\n' "$enc" "$sum"
}
smart_pair_decode() {
    local code="$1" rest enc sum actual raw key val
    code="${code//$'\r'/}"; code="${code#"${code%%[![:space:]]*}"}"; code="${code%"${code##*[![:space:]]}"}"
    [[ "$code" == mtpair://1/* ]] || return 1
    rest="${code#mtpair://1/}"; enc="${rest%.*}"; sum="${rest##*.}"
    [[ "$enc" =~ ^[A-Za-z0-9_-]+$ && "$sum" =~ ^[0-9a-f]{16}$ ]] || return 1
    actual=$(printf '%s' "1/$enc" | sha256sum | awk '{print substr($1,1,16)}')
    [ "$sum" = "$actual" ] || return 1
    raw=$(smart_b64url_decode "$enc") || return 1
    PAIR_IP6='Unknown'; PAIR_PORT=''; PAIR_FP=''; PAIR_SECRET=''; PAIR_EXPIRES=''
    while IFS='=' read -r key val; do
        case "$key" in
            V) [ "$val" = 1 ] || return 1;;
            IP6) PAIR_IP6="$val";; PORT) PAIR_PORT="$val";; FP) PAIR_FP="$val";; SECRET) PAIR_SECRET="$val";; EXPIRES) PAIR_EXPIRES="$val";;
            *) return 1;;
        esac
    done <<< "$raw"
    mt_valid_port "$PAIR_PORT" || return 1
    [[ "$PAIR_FP" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$PAIR_SECRET" =~ ^[0-9a-f]{48,128}$ ]] || return 1
    [[ "$PAIR_EXPIRES" =~ ^[0-9]{10}$ ]] || return 1
    ((PAIR_EXPIRES >= $(date +%s))) || { echo 'Pair Code has expired.' >&2; return 1; }
    if [ "$PAIR_IP6" != Unknown ]; then mt_valid_ipv6 "$PAIR_IP6" || return 1; fi
}
smart_encode_peer_link() { # kind file
    local kind="$1" file="$2" enc sum
    enc=$(LC_ALL=C sort "$file" | gzip -9n | base64 -w0 | tr '+/' '-_' | tr -d '=') || return 1
    sum=$(printf '%s' "2/$kind/$enc" | sha256sum | awk '{print substr($1,1,16)}')
    printf 'mtunnel://2/%s/%s.%s\n' "$kind" "$enc" "$sum"
}
smart_json_field() { # json field
    JSON_IN="$1" FIELD_IN="$2" python3 - <<'PY'
import json,os
try:
    v=json.loads(os.environ.get('JSON_IN','{}')).get(os.environ.get('FIELD_IN',''),'')
    if isinstance(v,bool): print('1' if v else '0')
    elif v is None: print('')
    elif isinstance(v,(dict,list)): print(json.dumps(v,separators=(',',':')))
    else: print(v)
except Exception: pass
PY
}
smart_https_call() { # host port fingerprint token path body [timeout-seconds]
    local call_timeout="${7:-15}"
    SMART_HOST="$1" SMART_PORT="$2" SMART_FP="$3" SMART_TOKEN="$4" SMART_PATH="$5" SMART_BODY="$6" SMART_TIMEOUT="$call_timeout" python3 - <<'PY'
import hashlib,http.client,json,os,ssl,sys
host=os.environ['SMART_HOST']; port=int(os.environ['SMART_PORT']); expected=os.environ['SMART_FP'].lower().replace(':','')
timeout=max(3,min(240,int(os.environ.get('SMART_TIMEOUT','15'))))
ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
try:
    c=http.client.HTTPSConnection(host,port,timeout=timeout,context=ctx)
    c.connect()
    cert=c.sock.getpeercert(binary_form=True)
    got=hashlib.sha256(cert).hexdigest()
    if got != expected:
        print(json.dumps({'ok':False,'error':'TLS fingerprint mismatch'})); sys.exit(4)
    headers={'Content-Type':'application/json'}
    tok=os.environ.get('SMART_TOKEN','')
    if tok: headers['Authorization']='Bearer '+tok
    c.request('POST',os.environ['SMART_PATH'],body=os.environ.get('SMART_BODY','{}').encode(),headers=headers)
    r=c.getresponse(); data=r.read(131072).decode('utf-8','replace')
    if not data: data=json.dumps({'ok':False,'error':'empty response','status':r.status})
    print(data)
except Exception as e:
    print(json.dumps({'ok':False,'error':str(e)})); sys.exit(5)
PY
}
smart_conf_get() { mt_link_read "$1" "$2" 2>/dev/null; }
smart_peer_load() {
    local f="$SMART_DIR/peer.conf"
    [ -s "$f" ] || return 1
    SMART_F4=$(smart_conf_get "$f" FOREIGN_IPV4); SMART_F6=$(smart_conf_get "$f" FOREIGN_IPV6)
    SMART_PORT=$(smart_conf_get "$f" PORT); SMART_FP=$(smart_conf_get "$f" FINGERPRINT); SMART_TOKEN=$(smart_conf_get "$f" TOKEN)
    mt_valid_ipv4 "$SMART_F4" && mt_valid_port "$SMART_PORT" && [[ "$SMART_FP" =~ ^[0-9a-f]{64}$ && "$SMART_TOKEN" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || return 1
}
smart_agent_call() { # JSON body [timeout-seconds]
    local call_timeout="${2:-15}"
    smart_peer_load || { echo '{"ok":false,"error":"not paired"}'; return 1; }
    smart_https_call "$SMART_F4" "$SMART_PORT" "$SMART_FP" "$SMART_TOKEN" /v1/action "$1" "$call_timeout"
}
SMART_DEP_SOURCE=""

smart_dependency_source_menu() {
    local choice
    [ -n "$SMART_DEP_SOURCE" ] && return 0
    smart_header
    echo -e "\n  ${FR}┌─[ SMART PREREQUISITE DOWNLOAD SOURCE ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}MTunnel GitHub${NC}"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}MTunnel Mirror${NC}"
    echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Official Project GitHubs${NC}"
    echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} Cancel"
    while true; do
        echo -ne "  ${C}Download Source ❯❯ ${NC}"; read -r choice || return 1
        choice="${choice//$'\r'/}"
        case "$choice" in
            1) SMART_DEP_SOURCE=mtunnel; break;;
            2) SMART_DEP_SOURCE=mirror; break;;
            3) SMART_DEP_SOURCE=official; break;;
            0|q|Q|'') return 1;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}";;
        esac
    done
    export SMART_DEP_SOURCE
    echo -e "  ${DIM}● Selected prerequisite source: ${W}${SMART_DEP_SOURCE}${NC}"
}

smart_core_installed_backhaul() { [ -x /usr/local/bin/bh ] || [ -x /usr/bin/bh ]; }
smart_core_installed_rathole() { [ -x /usr/local/bin/rathole ] || [ -x /usr/bin/rathole ]; }

smart_install_tunnel_cores() {
    local src="$1" tool failed=0
    if ! smart_core_installed_backhaul; then
        tool=$(command -v mbackhaul 2>/dev/null || true); [ -n "$tool" ] || tool=/usr/bin/mbackhaul
        [ -x "$tool" ] || { echo -e "  ${R}✖ MBackhaul module is not installed.${NC}"; failed=1; }
        if [ "$failed" -eq 0 ]; then
            echo -e "  ${Y}● Installing Backhaul Core from ${W}$src${NC}..."
            "$tool" --install-core-smart "$src" || failed=1
        fi
    fi
    if ! smart_core_installed_rathole; then
        tool=$(command -v mrathole 2>/dev/null || true); [ -n "$tool" ] || tool=/usr/bin/mrathole
        [ -x "$tool" ] || { echo -e "  ${R}✖ MRathole module is not installed.${NC}"; failed=1; }
        if [ -x "$tool" ]; then
            echo -e "  ${Y}● Installing Rathole Core from ${W}$src${NC}..."
            "$tool" --install-core-smart "$src" || failed=1
        fi
    fi
    smart_core_installed_backhaul || failed=1
    smart_core_installed_rathole || failed=1
    [ "$failed" -eq 0 ]
}

smart_full_package_missing() {
    local name miss=()
    for name in mtunnel mgre mxlan mbackhaul mrathole mpaqet mporter linktest mdoctor mmirror; do
        command -v "$name" >/dev/null 2>&1 || miss+=("$name")
    done
    smart_core_installed_backhaul || miss+=("backhaul-core")
    smart_core_installed_rathole || miss+=("rathole-core")
    for name in python3 openssl iperf3 ping iptables ip ss flock; do
        command -v "$name" >/dev/null 2>&1 || miss+=("$name")
    done
    printf '%s\n' "${miss[@]}"
}

smart_full_package_ready() {
    [ -z "$(smart_full_package_missing)" ]
}

smart_install_full_package() { # github|mirror
    local src="$1" cmd rc
    cmd=$(command -v mtunnel 2>/dev/null || true)
    [ -x "$cmd" ] || { echo -e "  ${R}✖ MTunnel main core is not installed.${NC}"; return 1; }
    case "$src" in
        github) echo -e "  ${C}⟳${NC} ${W}Installing the complete MTunnel package from GitHub...${NC}"; "$cmd" --full-package-github; rc=$?;;
        mirror) echo -e "  ${C}⟳${NC} ${W}Installing the complete MTunnel package from Mirror...${NC}"; "$cmd" --full-package-mirror; rc=$?;;
        *) return 2;;
    esac
    [ "$rc" -eq 0 ] || return "$rc"
    if ! smart_full_package_ready; then
        echo -e "  ${R}✖ Full package finished, but Smart requirements are still incomplete:${NC}"
        smart_full_package_missing | sed 's/^/    - /'
        return 1
    fi
    echo -e "  ${G}✓ Full MTunnel package and Smart prerequisites are ready.${NC}"
}

smart_full_package_gate() {
    local missing choice
    smart_full_package_ready && return 0
    missing=$(smart_full_package_missing | paste -sd ', ' -)
    smart_header
    echo -e "\n  ${FR}┌─[ FULL PACKAGE REQUIRED ]${NC}"
    echo -e "  ${FR}│${NC} ${Y}Before Smart Tunnel can run, install the complete MTunnel package on THIS server.${NC}"
    echo -e "  ${FR}│${NC} ${DIM}Do the same on the other server before pairing.${NC}"
    echo -e "  ${FR}│${NC} ${DIM}Missing: ${W}${missing:-unknown}${NC}"
    echo -e "  ${FR}├─${NC} ${W}A${NC} ${DIM}❯${NC} ${C}Install Full Package from GitHub${NC}"
    echo -e "  ${FR}├─${NC} ${W}B${NC} ${DIM}❯${NC} ${G}Install Full Package from Mirror${NC}"
    echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} Back"
    echo -ne "  ${C}FULL PACKAGE ❯❯ ${NC}"; read -r choice
    case "$choice" in
        a|A) smart_install_full_package github || { smart_pause; return 1; };;
        b|B) smart_install_full_package mirror || { smart_pause; return 1; };;
        *) return 1;;
    esac
    # The full package may have replaced msmart itself. Restart into the freshly installed copy.
    exec /usr/bin/msmart
}

smart_install_system_packages() {
    local missing=("$@")
    [ ${#missing[@]} -eq 0 ] && return 0
    echo -e "  ${Y}● Installing Smart system prerequisites: ${missing[*]}${NC}"
    command -v apt-get >/dev/null 2>&1 || { echo 'Required Smart system packages are missing and apt-get is unavailable.' >&2; return 1; }
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1
}

smart_ensure_agent_dependencies() {
    local missing=() need=0
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    command -v iperf3 >/dev/null 2>&1 || missing+=(iperf3)
    command -v ping >/dev/null 2>&1 || missing+=(iputils-ping)
    command -v iptables >/dev/null 2>&1 || missing+=(iptables)
    smart_core_installed_backhaul || need=1
    smart_core_installed_rathole || need=1
    [ ${#missing[@]} -eq 0 ] && [ "$need" -eq 0 ] && return 0
    smart_dependency_source_menu || return 1
    smart_install_system_packages "${missing[@]}" || return 1
    smart_install_tunnel_cores "$SMART_DEP_SOURCE" || return 1
}

smart_ensure_controller_dependencies() {
    local missing=() need=0
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    command -v iperf3 >/dev/null 2>&1 || missing+=(iperf3)
    command -v ping >/dev/null 2>&1 || missing+=(iputils-ping)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    command -v flock >/dev/null 2>&1 || missing+=(util-linux)
    command -v iptables >/dev/null 2>&1 || missing+=(iptables)
    smart_core_installed_backhaul || need=1
    smart_core_installed_rathole || need=1
    [ ${#missing[@]} -eq 0 ] && [ "$need" -eq 0 ] && return 0
    smart_dependency_source_menu || return 1
    smart_install_system_packages "${missing[@]}" || return 1
    smart_install_tunnel_cores "$SMART_DEP_SOURCE" || return 1
}

smart_install_agent_service() {
    cat > "$AGENT_SERVICE" <<'EOF'
[Unit]
Description=MTunnel Smart Foreign Agent
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/msmart --agent-daemon
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable mtunnel-smart-agent.service >/dev/null 2>&1
}
smart_agent_daemon() {
    exec python3 - "$SMART_DIR" "$AGENT_PORT" "$MODULE_VERSION" "$SMART_API_REV" <<'PY'
import http.server,ssl,json,os,sys,subprocess,secrets,time,hmac,socket,statistics,ipaddress,re,threading,signal,shutil
base=sys.argv[1]; port=int(sys.argv[2]); module_version=sys.argv[3]; api_rev=int(sys.argv[4])
cert=os.path.join(base,'agent.crt'); key=os.path.join(base,'agent.key')

def readf(name):
    try:
        with open(os.path.join(base,name),'r',encoding='utf-8') as f: return f.read().strip()
    except OSError: return ''
def writef(name,value):
    p=os.path.join(base,name); tmp=p+'.tmp'
    with open(tmp,'w',encoding='utf-8') as f: f.write(value+'\n')
    os.chmod(tmp,0o600); os.replace(tmp,p)
def local4():
    try:
        p=subprocess.run(['ip','-4','route','get','1.1.1.1'],capture_output=True,text=True,timeout=2).stdout.split()
        return p[p.index('src')+1] if 'src' in p else 'Unknown'
    except Exception: return 'Unknown'
def local6():
    try:
        parts=subprocess.run(['ip','-6','route','get','2606:4700:4700::1111'],capture_output=True,text=True,timeout=2).stdout.split()
        if 'src' in parts:
            x=parts[parts.index('src')+1].lower()
            if not x.startswith('fe80:'):
                ipaddress.ip_address(x); return x
    except Exception: pass
    try:
        out=subprocess.run(['ip','-6','-o','addr','show','scope','global'],capture_output=True,text=True,timeout=2).stdout
        for line in out.splitlines():
            if any(x in line for x in (' temporary ',' deprecated ',' tentative ')): continue
            parts=line.split()
            if len(parts)>3:
                x=parts[3].split('/')[0].lower()
                if not x.startswith('fe80:'): return x
    except Exception: pass
    return 'Unknown'
def info():
    required=['mgre','mxlan','mbackhaul','mrathole','mpaqet','mporter','linktest','mdoctor','mmirror','python3','iperf3','ping','iptables','ip','ss','flock']
    missing=[x for x in required if shutil.which(x) is None]
    bh=os.path.isfile('/usr/local/bin/bh') or os.path.isfile('/usr/bin/bh')
    rat=os.path.isfile('/usr/local/bin/rathole') or os.path.isfile('/usr/bin/rathole')
    if not bh: missing.append('backhaul-core')
    if not rat: missing.append('rathole-core')
    return {'version':module_version,'api_rev':api_rev,'ipv4':local4(),'ipv6':local6(),
            'backhaul_core':bh,'rathole_core':rat,'iperf3':shutil.which('iperf3') is not None,
            'full_package_ready':not missing,'full_package_missing':','.join(missing)}
def valid_ip(v):
    try: ipaddress.ip_address(v); return True
    except Exception: return False

def ipt(args):
    try:
        return subprocess.run(['iptables',*args],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=3).returncode==0
    except Exception:
        return False

CHAIN='MTUNNEL_SMART'
PAIR_COMMENT='MTUNNEL_SMART_PAIR'
PAIRED_COMMENT='MTUNNEL_SMART_PAIRED'

def ensure_agent_firewall(pair_open=False, controller=None):
    # Put a dedicated gate at the top of INPUT so an earlier generic ACCEPT rule cannot expose the Agent.
    try:
        subprocess.run(['iptables','-N',CHAIN],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=3)
    except Exception:
        return False
    if not ipt(['-L',CHAIN]): return False
    while ipt(['-D','INPUT','-p','tcp','--dport',str(port),'-j',CHAIN]): pass
    if not ipt(['-I','INPUT','1','-p','tcp','--dport',str(port),'-j',CHAIN]): return False
    if not ipt(['-F',CHAIN]): return False
    if pair_open and not ipt(['-A',CHAIN,'-m','comment','--comment',PAIR_COMMENT,'-j','ACCEPT']): return False
    if controller:
        try:
            ip=ipaddress.ip_address(controller)
            if ip.version==4 and not ipt(['-A',CHAIN,'-s',controller,'-m','comment','--comment',PAIRED_COMMENT,'-j','ACCEPT']): return False
        except Exception:
            return False
    return ipt(['-A',CHAIN,'-j','DROP'])

def restore_agent_firewall():
    exp=readf('pair.expires'); pair_open=False
    if exp.isdigit() and int(exp)>=int(time.time()) and readf('pair.secret'):
        pair_open=True
    if not ensure_agent_firewall(pair_open, readf('controller.ipv4')):
        raise SystemExit('MTunnel Smart Agent firewall gate could not be installed')

def restrict_agent_firewall(src):
    # Pairing is reached over Foreign IPv4, so pin the management chain to the actual controller source.
    try:
        ip=ipaddress.ip_address(src)
        if ip.version != 4: return False
    except Exception:
        return False
    if not ensure_agent_firewall(False, src): return False
    writef('controller.ipv4',src)
    return True

def reap_process(proc, seconds=20):
    def _stop():
        if proc.poll() is None:
            try: os.killpg(proc.pid, signal.SIGTERM)
            except Exception: pass
    t=threading.Timer(seconds,_stop); t.daemon=True; t.start()

class Handler(http.server.BaseHTTPRequestHandler):
    server_version='MTunnelSmart/'+module_version
    def log_message(self,*a): return
    def sendj(self,code,obj):
        data=json.dumps(obj,separators=(',',':')).encode()
        self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def body(self):
        try:
            n=int(self.headers.get('Content-Length','0'))
            if n<0 or n>131072: return None
            return json.loads(self.rfile.read(n) or b'{}')
        except Exception: return None
    def authed(self):
        token=readf('session.token')
        got=self.headers.get('Authorization','')
        return bool(token) and hmac.compare_digest(got,'Bearer '+token)
    def do_POST(self):
        data=self.body()
        if data is None: return self.sendj(400,{'ok':False,'error':'invalid json'})
        if self.path=='/v1/pair':
            secret=readf('pair.secret'); exp=readf('pair.expires'); supplied=str(data.get('secret',''))
            if not secret or not exp or not exp.isdigit() or int(exp)<int(time.time()): return self.sendj(403,{'ok':False,'error':'pair code expired'})
            if not hmac.compare_digest(secret,supplied):
                time.sleep(.35); return self.sendj(403,{'ok':False,'error':'pair code rejected'})
            if not restrict_agent_firewall(self.client_address[0]): return self.sendj(500,{'ok':False,'error':'agent firewall pinning failed'})
            token=secrets.token_urlsafe(36); writef('session.token',token)
            for n in ('pair.secret','pair.expires'):
                try: os.remove(os.path.join(base,n))
                except OSError: pass
            out=info(); out.update({'ok':True,'token':token}); return self.sendj(200,out)
        if self.path!='/v1/action': return self.sendj(404,{'ok':False,'error':'not found'})
        if not self.authed(): return self.sendj(403,{'ok':False,'error':'unauthorized'})
        action=str(data.get('action',''))
        if action=='info':
            out=info(); out['ok']=True; return self.sendj(200,out)
        if action=='ping':
            host=str(data.get('host',''))
            if not valid_ip(host): return self.sendj(400,{'ok':False,'error':'invalid ping target'})
            fam='-6' if ipaddress.ip_address(host).version==6 else '-4'
            try:
                p=subprocess.run(['ping',fam,'-c','3','-W','1',host],capture_output=True,text=True,timeout=6)
                text=(p.stdout or '')+'\n'+(p.stderr or '')
                lm=re.search(r'([0-9.]+)% packet loss',text); loss=float(lm.group(1)) if lm else 100.0
                am=re.search(r'=\s*([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)',text); avg=float(am.group(2)) if am else 9999.0
                return self.sendj(200,{'ok':True,'reachable':loss<100.0,'avg_ms':round(avg,2),'loss':loss})
            except Exception as e: return self.sendj(200,{'ok':True,'reachable':False,'avg_ms':9999,'loss':100,'error':str(e)})
        if action=='deploy':
            kind=str(data.get('kind','')); link=str(data.get('link',''))
            mods={'gre':'/usr/bin/mgre','vxlan':'/usr/bin/mxlan','backhaul':'/usr/bin/mbackhaul','rathole':'/usr/bin/mrathole'}
            exe=mods.get(kind)
            if not exe or not os.path.isfile(exe) or not link.startswith('mtunnel://2/'+kind+'/') or len(link)>32768:
                return self.sendj(400,{'ok':False,'error':'invalid deploy request'})
            try:
                p=subprocess.run([exe,'--deploy-peer-stdin'],input=link+'\n',capture_output=True,text=True,timeout=180)
                msg=(p.stdout+'\n'+p.stderr).strip()[-5000:]
                return self.sendj(200 if p.returncode==0 else 500,{'ok':p.returncode==0,'rc':p.returncode,'output':msg})
            except subprocess.TimeoutExpired:
                return self.sendj(504,{'ok':False,'error':'deploy timed out after 180s'})
            except Exception as e: return self.sendj(500,{'ok':False,'error':str(e)})
        if action=='delete':
            kind=str(data.get('kind','')); name=str(data.get('name',''))
            mods={'gre':'/usr/bin/mgre','vxlan':'/usr/bin/mxlan','backhaul':'/usr/bin/mbackhaul','rathole':'/usr/bin/mrathole'}
            exe=mods.get(kind)
            if not exe or not os.path.isfile(exe) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}',name):
                return self.sendj(400,{'ok':False,'error':'invalid delete request'})
            try:
                p=subprocess.run([exe,'--delete-one',name],capture_output=True,text=True,timeout=60)
                msg=(p.stdout+'\n'+p.stderr).strip()[-5000:]
                return self.sendj(200 if p.returncode==0 else 500,{'ok':p.returncode==0,'rc':p.returncode,'output':msg})
            except Exception as e: return self.sendj(500,{'ok':False,'error':str(e)})
        if action=='iperf_start':
            bind=str(data.get('bind','')); p=int(data.get('port',5201) or 5201)
            if not valid_ip(bind) or not (1<=p<=65535): return self.sendj(400,{'ok':False,'error':'invalid iperf bind'})
            if subprocess.run(['sh','-c','command -v iperf3 >/dev/null 2>&1']).returncode: return self.sendj(409,{'ok':False,'error':'iperf3 unavailable'})
            try:
                proc=subprocess.Popen(['iperf3','-s','-1','-B',bind,'-p',str(p)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
                reap_process(proc,20)
                time.sleep(.35)
                if proc.poll() is not None: return self.sendj(500,{'ok':False,'error':'iperf3 server failed to bind'})
                return self.sendj(200,{'ok':True,'pid':proc.pid})
            except Exception as e: return self.sendj(500,{'ok':False,'error':str(e)})
        if action=='tcp_probe':
            host=str(data.get('host','')); p=int(data.get('port',0) or 0); vals=[]; fail=0
            if not valid_ip(host) or not (1<=p<=65535): return self.sendj(400,{'ok':False,'error':'invalid probe target'})
            for _ in range(5):
                t=time.monotonic()
                try:
                    s=socket.create_connection((host,p),timeout=1.5); s.close(); vals.append((time.monotonic()-t)*1000)
                except Exception: fail+=1
                time.sleep(.12)
            return self.sendj(200,{'ok':True,'avg_ms':round(statistics.mean(vals),2) if vals else 9999,'jitter_ms':round(statistics.pstdev(vals),2) if len(vals)>1 else 0,'loss':fail*20})
        return self.sendj(400,{'ok':False,'error':'unsupported action'})
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(certfile=cert,keyfile=key)
class Server(http.server.ThreadingHTTPServer):
    allow_reuse_address=True
    daemon_threads=True
    request_queue_size=32
    gate=threading.BoundedSemaphore(32)
    def get_request(self):
        sock,addr=super().get_request()
        sock.settimeout(8)
        try:
            return ctx.wrap_socket(sock,server_side=True,do_handshake_on_connect=False),addr
        except Exception:
            sock.close(); raise
    def process_request(self,request,client_address):
        if not self.gate.acquire(blocking=False):
            try: request.close()
            except Exception: pass
            return
        try: super().process_request(request,client_address)
        except Exception:
            self.gate.release(); raise
    def process_request_thread(self,request,client_address):
        try:
            request.settimeout(8)
            request.do_handshake()
            super().process_request_thread(request,client_address)
        except Exception:
            try: request.close()
            except Exception: pass
        finally:
            self.gate.release()
restore_agent_firewall()
srv=Server(('0.0.0.0',port),Handler)
srv.serve_forever()
PY
}
smart_pair_window_cleanup() {
    local exp now chain=MTUNNEL_SMART
    exp=$(cat "$SMART_DIR/pair.expires" 2>/dev/null || true); now=$(date +%s)
    if [[ "$exp" =~ ^[0-9]+$ ]] && [ "$exp" -gt "$now" ]; then return 0; fi
    rm -f "$SMART_DIR/pair.secret" "$SMART_DIR/pair.expires"
    if command -v iptables >/dev/null 2>&1; then
        while iptables -D "$chain" -m comment --comment MTUNNEL_SMART_PAIR -j ACCEPT 2>/dev/null; do :; done
        iptables -C "$chain" -j DROP >/dev/null 2>&1 || iptables -A "$chain" -j DROP >/dev/null 2>&1 || true
    fi
}
smart_foreign_setup() {
    smart_header
    echo -e "\n  ${FR}┌─[ PREREQUISITES / FOREIGN AGENT ]${NC}"
    echo -e "  ${FR}│${NC} ${W}Open Smart Tunnel on the Iran server too.${NC}"
    echo -e "  ${FR}│${NC} ${DIM}This server becomes the Foreign Agent. After pairing, management is done from Iran.${NC}"
    echo -e "  ${FR}└────────────────────────────────────────────────────────────${NC}\n"
    smart_full_package_ready || { echo -e "  ${R}✖ Full MTunnel package is incomplete on Foreign. Use Update & Local Install → A/B first.${NC}"; smart_pause; return 1; }
    local ip4 ip6 secret expires fp code
    ip4=$(smart_local_ipv4); ip6=$(smart_local_ipv6)
    if [ ! -s "$SMART_DIR/agent.crt" ] || [ ! -s "$SMART_DIR/agent.key" ]; then
        echo -e "  ${C}●${NC} Creating Agent TLS identity..."
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -subj '/CN=MTunnel-Smart-Agent' -keyout "$SMART_DIR/agent.key" -out "$SMART_DIR/agent.crt" >/dev/null 2>&1 || { echo 'TLS certificate generation failed.' >&2; smart_pause; return 1; }
        chmod 600 "$SMART_DIR/agent.key" "$SMART_DIR/agent.crt"
    fi
    fp=$(openssl x509 -in "$SMART_DIR/agent.crt" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || { echo 'Could not fingerprint Agent certificate.' >&2; smart_pause; return 1; }
    secret=$(smart_random_hex 32); expires=$(($(date +%s)+900))
    printf '%s\n' "$secret" > "$SMART_DIR/pair.secret"; printf '%s\n' "$expires" > "$SMART_DIR/pair.expires"
    chmod 600 "$SMART_DIR/pair.secret" "$SMART_DIR/pair.expires"
    # Keep the current controller session alive until a new controller completes pairing.
    smart_install_agent_service || { echo 'Could not install Agent service.' >&2; smart_pause; return 1; }
    systemctl restart mtunnel-smart-agent.service || { echo 'Could not start Agent service.' >&2; smart_pause; return 1; }
    # The Agent rebuilds its dedicated INPUT gate on startup. During the 15-minute pair window
    # that chain allows pairing; after pairing it accepts only the pinned Iran IPv4 and drops the rest.
    # Broad access is temporary: successful pairing pins the rule to the Iran source IP.
    if command -v systemd-run >/dev/null 2>&1 && systemd-run --quiet --collect --unit="mtunnel-smart-pair-window-$(date +%s)" --on-active=16m "$INSTALL_PATH" --pair-window-cleanup >/dev/null 2>&1; then
        :
    else
        nohup sh -c 'sleep 960; exec /usr/bin/msmart --pair-window-cleanup' >/dev/null 2>&1 &
    fi
    code=$(smart_pair_encode "$ip6" "$AGENT_PORT" "$fp" "$secret" "$expires") || { smart_pause; return 1; }
    smart_header
    echo -e "\n  ${G}Foreign Agent is ready ✓${NC}\n"
    echo -e "  ${DIM}IPv4:${NC} ${W}$ip4${NC}"
    echo -e "  ${DIM}IPv6:${NC} ${W}$ip6${NC}"
    echo -e "  ${DIM}Agent Port:${NC} ${W}$AGENT_PORT${NC}"
    echo -e "  ${DIM}Pair Code expires in 15 minutes.${NC}\n"
    mt_link_box "$code"
    mt_clipboard_copy "$code" >/dev/null 2>&1 || true
    echo -e "\n  ${Y}On the Iran server enter only:${NC} ${W}Foreign IPv4 + Pair Code${NC}"
    echo -e "  ${DIM}IPv6 is already embedded in the Pair Code.${NC}"
    smart_pause
}
smart_pair_controller() {
    smart_header
    smart_full_package_ready || { echo -e "  ${R}✖ Full MTunnel package is not ready on Iran. Use Update & Local Install → A/B first.${NC}"; smart_pause; return 1; }
    echo -e "\n  ${FR}┌─[ IRAN CONTROLLER PAIRING ]${NC}"
    echo -e "  ${FR}│${NC} ${DIM}The Foreign server must already be in Smart Tunnel → Foreign Server.${NC}"
    echo -e "  ${FR}└────────────────────────────────────────────────────────────${NC}\n"
    local foreign4 code response ok token rv4 rv6 v api
    while true; do echo -ne "  ${C}●${NC} ${W}Foreign IPv4: ${NC}"; read -r foreign4; foreign4="${foreign4// /}"; mt_valid_ipv4 "$foreign4" && break; echo -e "  ${R}✖ Invalid IPv4.${NC}"; done
    echo -ne "  ${C}●${NC} ${W}Pair Code: ${NC}"; read -r code
    smart_pair_decode "$code" || { echo -e "\n  ${R}✖ Invalid or expired Pair Code.${NC}"; smart_pause; return 1; }
    echo -e "\n  ${C}⟳${NC} Connecting to pinned Foreign Agent..."
    response=$(smart_https_call "$foreign4" "$PAIR_PORT" "$PAIR_FP" '' /v1/pair "{\"secret\":\"$PAIR_SECRET\"}") || true
    ok=$(smart_json_field "$response" ok)
    if [ "$ok" != 1 ]; then echo -e "  ${R}✖ Pairing failed:${NC} $(smart_json_field "$response" error)"; smart_pause; return 1; fi
    token=$(smart_json_field "$response" token); rv4=$(smart_json_field "$response" ipv4); rv6=$(smart_json_field "$response" ipv6); v=$(smart_json_field "$response" version); api=$(smart_json_field "$response" api_rev)
    [ "$api" = "$SMART_API_REV" ] || { echo -e "  ${R}✖ Foreign Agent API is incompatible (remote: ${api:-unknown}, required: $SMART_API_REV). Update Foreign MSmart and generate a new Pair Code.${NC}"; smart_pause; return 1; }
    [ "$(smart_json_field "$response" full_package_ready)" = 1 ] || { echo -e "  ${R}✖ Foreign full package is incomplete:${NC} $(smart_json_field "$response" full_package_missing)"; echo -e "  ${Y}Run Smart → Update & Local Install → A/B on Foreign, then generate a new Pair Code.${NC}"; smart_pause; return 1; }
    [[ "$token" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || { echo 'Agent returned an invalid session token.' >&2; smart_pause; return 1; }
    if [ "$PAIR_IP6" != Unknown ] && [ "$rv6" != Unknown ] && [ "$PAIR_IP6" != "$rv6" ]; then
        echo -e "  ${R}✖ Foreign IPv6 changed since Pair Code generation. Generate a new Pair Code.${NC}"; smart_pause; return 1
    fi
    [ "$rv6" != Unknown ] || rv6="$PAIR_IP6"
    cat > "$SMART_DIR/peer.conf" <<EOF
FOREIGN_IPV4=$foreign4
FOREIGN_IPV6=$rv6
PORT=$PAIR_PORT
FINGERPRINT=$PAIR_FP
TOKEN=$token
AGENT_VERSION=$v
AGENT_API=$api
PAIRED_AT=$(date +%s)
EOF
    chmod 600 "$SMART_DIR/peer.conf"
    smart_header
    echo -e "\n  ${G}✓ Servers paired successfully${NC}\n"
    echo -e "  ${DIM}Foreign IPv4:${NC} ${W}$foreign4${NC}"
    echo -e "  ${DIM}Foreign IPv6:${NC} ${W}$rv6${NC}"
    echo -e "  ${DIM}Agent version:${NC} ${W}${v:-unknown}${NC} ${DIM}(API ${api})${NC}"
    [ "$v" = "$MODULE_VERSION" ] || echo -e "  ${Y}⚠ Module versions differ, but Smart API is compatible (Iran $MODULE_VERSION / Foreign ${v:-unknown}).${NC}"
    echo -e "\n  ${G}From now on all Smart Tunnel management is done on the Iran server.${NC}"
    smart_pause
}
smart_info() {
    smart_header
    if ! smart_peer_load; then echo -e "\n  ${Y}● This server is not paired as an Iran Controller.${NC}"; smart_pause; return; fi
    local l4 l6 response ok
    l4=$(smart_local_ipv4); l6=$(smart_local_ipv6); response=$(smart_agent_call '{"action":"info"}' || true); ok=$(smart_json_field "$response" ok)
    echo -e "\n  ${FR}┌─[ SMART PEER STATUS ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}Iran IPv4${NC}       ${DIM}❯${NC} ${C}$l4${NC}"
    echo -e "  ${FR}├─${NC} ${W}Iran IPv6${NC}       ${DIM}❯${NC} ${C}$l6${NC}"
    echo -e "  ${FR}├─${NC} ${W}Foreign IPv4${NC}    ${DIM}❯${NC} ${C}$SMART_F4${NC}"
    echo -e "  ${FR}├─${NC} ${W}Foreign IPv6${NC}    ${DIM}❯${NC} ${C}${SMART_F6:-Unknown}${NC}"
    echo -e "  ${FR}├─${NC} ${W}Agent${NC}           ${DIM}❯${NC} $([ "$ok" = 1 ] && echo -e "${G}ONLINE${NC}" || echo -e "${R}OFFLINE${NC}")"
    echo -e "  ${FR}└────────────────────────────────────────────────────────────${NC}"
    [ "$ok" = 1 ] || echo -e "  ${R}$(smart_json_field "$response" error)${NC}"
    smart_pause
}
smart_local_ping_probe() { # host -> reachable|avg|loss
    local host="$1" out line loss avg cmd=(ping -4 -c 3 -W 1)
    [[ "$host" == *:* ]] && cmd=(ping -6 -c 3 -W 1)
    out=$("${cmd[@]}" "$host" 2>/dev/null || true)
    loss=$(grep -oE '[0-9]+(\.[0-9]+)?% packet loss' <<< "$out" | head -1 | cut -d% -f1); loss="${loss:-100}"
    line=$(grep -E '(^|=)[[:space:]]*[0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+' <<< "$out" | tail -1)
    if [ -n "$line" ]; then IFS=/ read -r _ avg _ _ _ <<< "${line#*= }"; else avg=9999; fi
    if awk -v l="$loss" 'BEGIN{exit !(l<100)}'; then printf '1|%s|%s\n' "${avg:-9999}" "$loss"; else printf '0|9999|%s\n' "$loss"; fi
}
smart_remote_ping_probe() { # host -> reachable|avg|loss
    local host="$1" body resp ok reachable avg loss
    body=$(H="$host" python3 - <<'PY'
import json,os; print(json.dumps({'action':'ping','host':os.environ['H']},separators=(',',':')))
PY
)
    resp=$(smart_agent_call "$body" || true); ok=$(smart_json_field "$resp" ok)
    if [ "$ok" = 1 ]; then
        reachable=$(smart_json_field "$resp" reachable); avg=$(smart_json_field "$resp" avg_ms); loss=$(smart_json_field "$resp" loss)
        [ "$reachable" = 1 ] && printf '1|%s|%s\n' "${avg:-9999}" "${loss:-100}" || printf '0|9999|%s\n' "${loss:-100}"
    else printf '0|9999|100\n'; fi
}
smart_reachability_matrix() { # local4 local6 foreign4 foreign6
    local l4="$1" l6="$2" f4="$3" f6="$4" ans
    SMART_I_TO_F4=0; SMART_F_TO_I4=0; SMART_I_TO_F6=0; SMART_F_TO_I6=0
    SMART_I_TO_F4_AVG=9999; SMART_F_TO_I4_AVG=9999; SMART_I_TO_F6_AVG=9999; SMART_F_TO_I6_AVG=9999
    smart_header
    echo -e "\n  ${FR}┌─[ REACHABILITY CHECK ]${NC}"
    echo -ne "  ${C}●${NC} ${W}Run bidirectional IPv4/IPv6 ping checks now? [Y/n]: ${NC}"; read -r ans
    case "${ans,,}" in n|no)
        mt_valid_ipv4 "$l4" && mt_valid_ipv4 "$f4" && { SMART_I_TO_F4=1; SMART_F_TO_I4=1; }
        mt_valid_ipv6 "$l6" && mt_valid_ipv6 "$f6" && { SMART_I_TO_F6=1; SMART_F_TO_I6=1; }
        ;;
    *)
        if mt_valid_ipv4 "$l4" && mt_valid_ipv4 "$f4"; then
            IFS='|' read -r SMART_I_TO_F4 SMART_I_TO_F4_AVG _ <<< "$(smart_local_ping_probe "$f4")"
            IFS='|' read -r SMART_F_TO_I4 SMART_F_TO_I4_AVG _ <<< "$(smart_remote_ping_probe "$l4")"
        fi
        if mt_valid_ipv6 "$l6" && mt_valid_ipv6 "$f6"; then
            IFS='|' read -r SMART_I_TO_F6 SMART_I_TO_F6_AVG _ <<< "$(smart_local_ping_probe "$f6")"
            IFS='|' read -r SMART_F_TO_I6 SMART_F_TO_I6_AVG _ <<< "$(smart_remote_ping_probe "$l6")"
        fi
        ;;
    esac
    smart_header
    echo -e "\n  ${FR}┌─[ REACHABILITY REPORT ]${NC}"
    printf '  %b├─%b %-30s %b%s%b\n' "$FR" "$NC" "Iran IPv4 → Foreign IPv4" "$([ "$SMART_I_TO_F4" = 1 ] && printf "$G" || printf "$R")" "$([ "$SMART_I_TO_F4" = 1 ] && echo "OK  ${SMART_I_TO_F4_AVG}ms" || echo BLOCKED)" "$NC"
    printf '  %b├─%b %-30s %b%s%b\n' "$FR" "$NC" "Foreign IPv4 → Iran IPv4" "$([ "$SMART_F_TO_I4" = 1 ] && printf "$G" || printf "$R")" "$([ "$SMART_F_TO_I4" = 1 ] && echo "OK  ${SMART_F_TO_I4_AVG}ms" || echo BLOCKED)" "$NC"
    printf '  %b├─%b %-30s %b%s%b\n' "$FR" "$NC" "Iran IPv6 → Foreign IPv6" "$([ "$SMART_I_TO_F6" = 1 ] && printf "$G" || printf "$R")" "$([ "$SMART_I_TO_F6" = 1 ] && echo "OK  ${SMART_I_TO_F6_AVG}ms" || echo BLOCKED)" "$NC"
    printf '  %b└─%b %-30s %b%s%b\n' "$FR" "$NC" "Foreign IPv6 → Iran IPv6" "$([ "$SMART_F_TO_I6" = 1 ] && printf "$G" || printf "$R")" "$([ "$SMART_F_TO_I6" = 1 ] && echo "OK  ${SMART_F_TO_I6_AVG}ms" || echo BLOCKED)" "$NC"
    echo -e "\n  ${DIM}Unavailable paths are removed from the tunnel list automatically.${NC}"
    smart_pause
}
smart_candidate_lines() { # l4 l6 f4 f6 local_bh remote_bh local_rat remote_rat i2f4 f2i4 i2f6 f2i6
    local l4="$1" l6="$2" f4="$3" f6="$4" lbh="$5" rbh="$6" lrat="$7" rrat="$8" i2f4="${9:-1}" f2i4="${10:-1}" i2f6="${11:-1}" f2i6="${12:-1}"
    if mt_valid_ipv4 "$l4" && mt_valid_ipv4 "$f4" && [ "$i2f4" = 1 ] && [ "$f2i4" = 1 ]; then
        printf '%s\n' \
          '1|mGRE IPv4 + 5 vIPs|gre|ipv4|v4↔v4' \
          '2|mGRE 6to4 + 5 vIPs|gre|6to4|v4↔v4' \
          '3|mGRE IPIP4→4 + 5 vIPs|gre|ipip4to4|v4↔v4' \
          '6|VXLAN IPv4 + 5 vIPs|vxlan|ipv4|v4↔v4'
    fi
    if mt_valid_ipv6 "$l6" && mt_valid_ipv6 "$f6" && [ "$i2f6" = 1 ] && [ "$f2i6" = 1 ]; then
        printf '%s\n' \
          '4|mGRE6 + 5 vIPs|gre|gre6|v6↔v6' \
          '5|mGRE IPIP4→6 + 5 vIPs|gre|ipip4to6|v6↔v6' \
          '7|VXLAN IPv6 + 5 vIPs|vxlan|ipv6|v6↔v6'
    fi
    if [ "$lbh" = 1 ] && [ "$rbh" = 1 ]; then
        if mt_valid_ipv4 "$l4" && [ "$f2i4" = 1 ]; then
            printf '%s\n' '8|Backhaul TCPMUX IPv4|backhaul|tcpmux|Foreign→Iran v4' '9|Backhaul WSMUX IPv4|backhaul|wsmux|Foreign→Iran v4'
        fi
        if mt_valid_ipv6 "$l6" && [ "$f2i6" = 1 ]; then
            printf '%s\n' '10|Backhaul TCPMUX IPv6|backhaul|tcpmux|Foreign→Iran v6' '11|Backhaul WSMUX IPv6|backhaul|wsmux|Foreign→Iran v6'
        fi
    fi
    if [ "$lrat" = 1 ] && [ "$rrat" = 1 ]; then
        mt_valid_ipv4 "$l4" && [ "$f2i4" = 1 ] && printf '%s\n' '12|Rathole IPv4|rathole|tcp|Foreign→Iran v4'
        mt_valid_ipv6 "$l6" && [ "$f2i6" = 1 ] && printf '%s\n' '13|Rathole IPv6|rathole|tcp|Foreign→Iran v6'
    fi
}
smart_unique_fabric_ids() { # avail ids -> keep at most one mGRE-family and one VXLAN tunnel
    local avail="$1" ids="$2" out='' id kind seen_gre=0 seen_vxlan=0
    for id in ${ids//,/ }; do
        kind=$(awk -F'|' -v x="$id" '$1==x{print $3;exit}' <<< "$avail")
        [ -n "$kind" ] || continue
        case "$kind" in
            gre) [ "$seen_gre" -eq 0 ] || continue; seen_gre=1;;
            vxlan) [ "$seen_vxlan" -eq 0 ] || continue; seen_vxlan=1;;
        esac
        out+="${out:+,}$id"
    done
    printf '%s' "$out"
}
smart_all_ids() { # all compatible, but Smart owns one mGRE + one VXLAN fabric per group
    local avail="$1" ids
    ids=$(awk -F'|' '{printf "%s%s",sep,$1;sep=","}' <<< "$avail")
    smart_unique_fabric_ids "$avail" "$ids"
}
smart_recommended_ids() {
    local avail="$1" out='' pref kind seen_gre=0 seen_vxlan=0 count=0
    for pref in 1 4 3 5 2 6 7 8 11 12 13 9 10; do
        kind=$(awk -F'|' -v x="$pref" '$1==x{print $3;exit}' <<< "$avail")
        [ -n "$kind" ] || continue
        case "$kind" in
            gre) [ "$seen_gre" -eq 0 ] || continue; seen_gre=1;;
            vxlan) [ "$seen_vxlan" -eq 0 ] || continue; seen_vxlan=1;;
        esac
        out+="${out:+,}$pref"; count=$((count+1))
        [ "$count" -ge 8 ] && break
    done
    printf '%s' "$out"
}
smart_validate_service_ports() {
    local s="${1// /}" p; local -A seen=(); local -a _sp=(); SMART_SERVICE_PORTS=''
    [ -z "$s" ] && return 1
    [[ "$s" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
    IFS=, read -ra _sp <<< "$s"
    [ ${#_sp[@]} -le 32 ] || return 1
    for p in "${_sp[@]}"; do
        mt_valid_port "$p" || return 1
        p=$((10#$p))
        [ -z "${seen[$p]:-}" ] || return 1
        if ss -lntH 2>/dev/null | awk -v want="$p" '{n=split($4,a,":"); if (a[n]==want) found=1} END{exit !found}'; then return 1; fi
        seen[$p]=1
        SMART_SERVICE_PORTS+="${SMART_SERVICE_PORTS:+,}$p"
    done
}
smart_pick_port() { # base [excluded-comma-list]; prints free tcp port
    local base="$1" excluded="${2:-}" p i
    for ((i=0;i<500;i++)); do
        p=$((base+i)); [ "$p" -le 65000 ] || p=$((20000+i))
        [[ ",${excluded}," == *",${p},"* ]] && continue
        if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$p$"; then printf '%s' "$p"; return 0; fi
    done
    return 1
}
smart_network_links() { # kind proto base secret id core corev6 l4 l6 f4 f6 => outputs local|remote|remote_inner|local_name|remote_name
    local kind="$1" proto="$2" base="$3" secret="$4" id="$5" core="$6" corev6="$7" l4="$8" l6="$9"; shift 9
    local f4="$1" f6="$2" a b expires hostl hostr l_in6='' r_in6='' pfx lpfx rpfx local_name remote_name
    expires=$(($(date +%s)+3600)); a=$(mktemp /root/mtunnel/tmp/smart-link-a.XXXXXX) || return 1; b=$(mktemp /root/mtunnel/tmp/smart-link-b.XXXXXX) || { rm -f "$a"; return 1; }
    if [[ "$proto" =~ ^(gre6|ipip4to6|ipip6to6|ipv6)$ ]]; then hostl="$f6"; hostr="$l6"; else hostl="$f4"; hostr="$l4"; fi
    if [ "$proto" = 6to4 ]; then
        pfx=$(smart_sha "${secret}_MHDesign"); pfx="fd${pfx:0:2}:${pfx:2:4}:${pfx:6:4}:${pfx:10:4}"; l_in6="${pfx}::1"; r_in6="${pfx}::2"
    fi
    for side in local remote; do
        if [ "$side" = local ]; then
            cat > "$a" <<EOF
ROLE=1
NAME=$base
HOST=$hostl
EXPIRES=$expires
PROTO=$proto
TUN_SECRET=$secret
SYNC_KEY=$secret
CORE_SUBNET=$core
CORE_V6=$corev6
MAX_IPS=5
CUSTOM_MTU=
ENCRYPT=0
LOCAL_PUB=$l4
REMOTE_PUB=$f4
LOCAL_PUB6=$l6
REMOTE_PUB6=$f6
LOCAL_IP6=$l_in6
REMOTE_IP6=$r_in6
REMOTE_V4=$f4
EOF
            [ "$kind" = gre ] && echo "TUN_ID=$id" >> "$a" || echo "VNI_ID=$id" >> "$a"
        else
            cat > "$b" <<EOF
ROLE=2
NAME=$base
HOST=$hostr
EXPIRES=$expires
PROTO=$proto
TUN_SECRET=$secret
SYNC_KEY=$secret
CORE_SUBNET=$core
CORE_V6=$corev6
MAX_IPS=5
CUSTOM_MTU=
ENCRYPT=0
LOCAL_PUB=$f4
REMOTE_PUB=$l4
LOCAL_PUB6=$f6
REMOTE_PUB6=$l6
LOCAL_IP6=$r_in6
REMOTE_IP6=$l_in6
REMOTE_V4=$l4
EOF
            [ "$kind" = gre ] && echo "TUN_ID=$id" >> "$b" || echo "VNI_ID=$id" >> "$b"
        fi
    done
    local L R inner
    L=$(smart_encode_peer_link "$kind" "$a"); R=$(smart_encode_peer_link "$kind" "$b"); rm -f "$a" "$b"
    if [ "$kind" = vxlan ]; then local_name="vx_$base"; remote_name="vx_$base"; inner="${core}.2"
    else
        case "$proto" in 6to4|gre6) lpfx=g6ir; rpfx=g6kh;; ipip4to4) lpfx=i4ir; rpfx=i4kh;; ipip4to6) lpfx=i46i; rpfx=i46k;; ipip6to6) lpfx=i66i; rpfx=i66k;; *) lpfx=greir; rpfx=grekh;; esac
        local_name="${lpfx}${base}"; remote_name="${rpfx}${base}"; [ "$proto" = ipip6to6 ] && inner="${corev6}::2" || inner="${core}.2"
    fi
    printf '%s|%s|%s|%s|%s\n' "$L" "$R" "$inner" "$local_name" "$remote_name"
}
smart_backhaul_links() { # transport path base token linkport ports l4 l6 f4 f6
    local tr="$1" path="$2" base="$3" token="$4" linkport="$5" ports="$6" l4="$7" l6="$8" f4="$9"; shift 9
    local f6="$1" iran foreign bind expires a b L R
    if [[ "$path" == *v6* ]]; then iran="$l6"; foreign="$f6"; bind=::; else iran="$l4"; foreign="$f4"; bind=0.0.0.0; fi
    expires=$(($(date +%s)+3600)); a=$(mktemp /root/mtunnel/tmp/smart-bh-a.XXXXXX) || return 1; b=$(mktemp /root/mtunnel/tmp/smart-bh-b.XXXXXX) || { rm -f "$a"; return 1; }
    cat > "$a" <<EOF
ROLE=1
NAME=$base
HOST=$foreign
EXPIRES=$expires
TOKEN=$token
LINK_PORT=$linkport
TRANSPORT=$tr
PORTS=$ports
ENABLE_UDP=false
BIND_HOST=$bind
EOF
    cat > "$b" <<EOF
ROLE=2
NAME=$base
HOST=$iran
EXPIRES=$expires
TOKEN=$token
LINK_PORT=$linkport
TRANSPORT=$tr
PORTS=$ports
ENABLE_UDP=false
BIND_HOST=$bind
EOF
    L=$(smart_encode_peer_link backhaul "$a"); R=$(smart_encode_peer_link backhaul "$b"); rm -f "$a" "$b"
    printf '%s|%s|%s|%s\n' "$L" "$R" "bh_$base" "bh_$base"
}
smart_rathole_links() { # path base token linkport benchport services l4 l6 f4 f6
    local path="$1" base="$2" token="$3" linkport="$4" benchport="$5" services="$6" l4="$7" l6="$8" f4="$9"; shift 9
    local f6="$1"
    local iran foreign bind expires a b L R remote_ports
    remote_ports="$benchport${services:+,$services}"
    if [[ "$path" == *v6* ]]; then iran="$l6"; foreign="$f6"; bind=::; else iran="$l4"; foreign="$f4"; bind=0.0.0.0; fi
    expires=$(($(date +%s)+3600)); a=$(mktemp /root/mtunnel/tmp/smart-rat-a.XXXXXX) || return 1; b=$(mktemp /root/mtunnel/tmp/smart-rat-b.XXXXXX) || { rm -f "$a"; return 1; }
    cat > "$a" <<EOF
ROLE=1
NAME=$base
HOST=$foreign
EXPIRES=$expires
TOKEN=$token
LINK_PORT=$linkport
TCP_PORTS=$benchport
UDP_PORTS=
BIND_HOST=$bind
EOF
    cat > "$b" <<EOF
ROLE=2
NAME=$base
HOST=$iran
EXPIRES=$expires
TOKEN=$token
LINK_PORT=$linkport
TCP_PORTS=$remote_ports
UDP_PORTS=
BIND_HOST=$bind
EOF
    L=$(smart_encode_peer_link rathole "$a"); R=$(smart_encode_peer_link rathole "$b"); rm -f "$a" "$b"
    printf '%s|%s|%s|%s\n' "$L" "$R" "$base" "$base"
}
smart_deploy_remote() { # kind link
    local body response
    body=$(K="$1" L="$2" python3 - <<'PY'
import json,os; print(json.dumps({'action':'deploy','kind':os.environ['K'],'link':os.environ['L']},separators=(',',':')))
PY
)
    response=$(smart_agent_call "$body" 210 || true)
    [ "$(smart_json_field "$response" ok)" = 1 ] || { echo "$(smart_json_field "$response" output)$(smart_json_field "$response" error)" >&2; return 1; }
}
smart_deploy_local() { # kind link
    case "$1" in
        gre) printf '%s\n' "$2" | /usr/bin/mgre --deploy-peer-stdin;;
        vxlan) printf '%s\n' "$2" | /usr/bin/mxlan --deploy-peer-stdin;;
        backhaul) printf '%s\n' "$2" | /usr/bin/mbackhaul --deploy-peer-stdin;;
        rathole) printf '%s\n' "$2" | /usr/bin/mrathole --deploy-peer-stdin;;
        *) return 1;;
    esac
}
smart_delete_remote() { # kind name
    local body response
    body=$(K="$1" N="$2" python3 - <<'PY'
import json,os; print(json.dumps({'action':'delete','kind':os.environ['K'],'name':os.environ['N']},separators=(',',':')))
PY
)
    response=$(smart_agent_call "$body" 75 || true)
    [ "$(smart_json_field "$response" ok)" = 1 ]
}
smart_delete_local() { # kind name
    case "$1" in
        gre) /usr/bin/mgre --delete-one "$2";;
        vxlan) /usr/bin/mxlan --delete-one "$2";;
        backhaul) /usr/bin/mbackhaul --delete-one "$2";;
        rathole) /usr/bin/mrathole --delete-one "$2";;
        *) return 1;;
    esac
}
smart_ping_stats() { # host [count] -> avg|loss|jitter
    local host="$1" count="${2:-5}" out line loss avg jit _min _max _rest cmd
    [[ "$count" =~ ^[1-9][0-9]?$ ]] || count=5
    cmd=(ping -c "$count" -W 1)
    [[ "$host" == *:* ]] && cmd=(ping -6 -c "$count" -W 1)
    out=$("${cmd[@]}" "$host" 2>/dev/null || true)
    loss=$(grep -oE '[0-9]+(\.[0-9]+)?% packet loss' <<< "$out" | head -1 | cut -d% -f1); loss="${loss:-100}"
    line=$(grep -E '(^|=)[[:space:]]*[0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+' <<< "$out" | tail -1)
    if [ -n "$line" ]; then
        IFS=/ read -r _min avg _max jit _rest <<< "${line#*= }"
        jit="${jit%% *}"
    else avg=9999; jit=9999; fi
    [[ "$avg" =~ ^[0-9]+([.][0-9]+)?$ ]] || avg=9999
    [[ "$jit" =~ ^[0-9]+([.][0-9]+)?$ ]] || jit=9999
    printf '%s|%s|%s\n' "$avg" "$loss" "$jit"
}
smart_iperf_speed() { # target direction -> Mbps; prepares server on foreign
    local target="$1" reverse="$2" body resp out
    command -v iperf3 >/dev/null 2>&1 || { echo 0; return; }
    body=$(B="$target" P="$IPERF_PORT" python3 - <<'PY'
import json,os; print(json.dumps({'action':'iperf_start','bind':os.environ['B'],'port':int(os.environ['P'])},separators=(',',':')))
PY
)
    resp=$(smart_agent_call "$body" || true); [ "$(smart_json_field "$resp" ok)" = 1 ] || { echo 0; return; }
    sleep .2
    local -a args=(-c "$target" -p "$IPERF_PORT" -t 4 -O 1 -J)
    [ "$reverse" = reverse ] && args+=(-R)
    out=$(timeout 15 iperf3 "${args[@]}" 2>/dev/null || true)
    IPERF_JSON="$out" python3 - <<'PY'
import json,os
try:
 d=json.loads(os.environ.get('IPERF_JSON','{}')); e=d.get('end',{}); x=e.get('sum_received') or e.get('sum') or {}; print(round(float(x.get('bits_per_second',0))/1e6,1))
except Exception: print(0)
PY
}
smart_iperf_speed_rathole() { # local mapped port direction; Foreign iperf binds same port
    local port="$1" reverse="$2" body resp out
    command -v iperf3 >/dev/null 2>&1 || { echo 0; return; }
    body=$(P="$port" python3 - <<'PY'
import json,os; print(json.dumps({'action':'iperf_start','bind':'127.0.0.1','port':int(os.environ['P'])},separators=(',',':')))
PY
)
    resp=$(smart_agent_call "$body" || true); [ "$(smart_json_field "$resp" ok)" = 1 ] || { echo 0; return; }
    sleep .2
    local -a args=(-c 127.0.0.1 -p "$port" -t 4 -O 1 -J); [ "$reverse" = reverse ] && args+=(-R)
    out=$(timeout 15 iperf3 "${args[@]}" 2>/dev/null || true)
    IPERF_JSON="$out" python3 - <<'PY'
import json,os
try:
 d=json.loads(os.environ.get('IPERF_JSON','{}')); e=d.get('end',{}); x=e.get('sum_received') or e.get('sum') or {}; print(round(float(x.get('bits_per_second',0))/1e6,1))
except Exception: print(0)
PY
}
smart_score() { # avg loss jitter up down maxspeed
    python3 - "$@" <<'PY'
import sys
lat,loss,jit,up,down,maxs=map(float,sys.argv[1:7]); speed=(up+down)/2
reli=max(0,100-loss*8); lats=max(0,100-min(lat,500)/5); jits=max(0,100-min(jit,100)); spd=0 if maxs<=0 else min(100,speed/maxs*100)
print(round(reli*.35+lats*.25+jits*.15+spd*.25,1))
PY
}
smart_hysteresis_order() { # groupdir ranking-file; keeps the active path stable unless it fails or a challenger wins 3 checks
    local gd="$1" rank="$2" sf="$gd/switch.state" current='' challenger='' streak=0 last=0 now top active_score top_score active_status tmp
    [ -s "$rank" ] || return 0
    now=$(date +%s)
    if [ -s "$sf" ]; then IFS='|' read -r current challenger streak last < "$sf" || true; fi
    [[ "$streak" =~ ^[0-9]+$ ]] || streak=0; [[ "$last" =~ ^[0-9]+$ ]] || last=0
    top=$(awk -F'|' '$10=="UP"{print $1;exit}' "$rank")
    if [ -z "$top" ]; then
        : > "$gd/active.state"; printf '||0|%s\n' "$last" > "$sf"; chmod 600 "$sf" "$gd/active.state"; return 0
    fi
    active_status=$(awk -F'|' -v i="$current" '$1==i{print $10;exit}' "$rank")
    if [ -z "$current" ] || [ "$active_status" != UP ]; then
        current="$top"; challenger=''; streak=0; last="$now"
    elif [ "$top" = "$current" ]; then
        challenger=''; streak=0
    else
        active_score=$(awk -F'|' -v i="$current" '$1==i && $10=="UP"{print $16;exit}' "$rank")
        top_score=$(awk -F'|' -v i="$top" '$1==i && $10=="UP"{print $16;exit}' "$rank")
        if [ $((now-last)) -ge 60 ] && awk -v t="${top_score:-0}" -v a="${active_score:-0}" 'BEGIN{exit !(t>=a+8)}'; then
            if [ "$challenger" = "$top" ]; then streak=$((streak+1)); else challenger="$top"; streak=1; fi
            if [ "$streak" -ge 3 ]; then current="$top"; challenger=''; streak=0; last="$now"; fi
        else
            challenger=''; streak=0
        fi
    fi
    tmp="$gd/.ranking.priority"
    awk -F'|' -v i="$current" '$1==i{print;next}{rest[++n]=$0} END{for(j=1;j<=n;j++)print rest[j]}' "$rank" > "$tmp" && mv -f "$tmp" "$rank"
    printf '%s|%s|%s|%s\n' "$current" "$challenger" "$streak" "$last" > "$sf"
    awk -F'|' -v i="$current" '$1==i{print $1"|"$2"|"$16;exit}' "$rank" > "$gd/active.state"
    chmod 600 "$sf" "$gd/active.state" "$rank" 2>/dev/null || true
}

smart_backhaul_service_spec() { # benchmark-port service-ports
    local bench="$1" services="$2" p out="${bench}=127.0.0.1:${IPERF_PORT}"
    local -a _svc=()
    [ -z "$services" ] || { IFS=, read -ra _svc <<< "$services"; for p in "${_svc[@]}"; do out+=",${p}=127.0.0.1:${p}"; done; }
    printf '%s' "$out"
}
smart_forward_one() { # groupdir candidate-id on|off
    local gd="$1" want="$2" mode="$3" services line id label kind proto path name inner linkp benchp status spec ports
    services=$(smart_conf_get "$gd/group.conf" SERVICE_PORTS)
    line=$(awk -F'|' -v i="$want" '$1==i{print;exit}' "$gd/candidates.tsv")
    [ -n "$line" ] || return 1
    IFS='|' read -r id label kind proto path name inner linkp benchp status <<< "$line"
    case "$kind" in
        gre)
            /usr/bin/mgre --smart-forward "$name" "$services" "$mode" >/dev/null
            ;;
        vxlan)
            /usr/bin/mxlan --smart-forward "$name" "$services" "$mode" >/dev/null
            ;;
        rathole)
            ports="$benchp"; [ "$mode" != on ] || ports+="${services:+,$services}"
            /usr/bin/mrathole --smart-ports "$name" "$ports" >/dev/null
            ;;
        backhaul)
            if [ "$mode" = on ]; then spec=$(smart_backhaul_service_spec "$benchp" "$services"); else spec=$(smart_backhaul_service_spec "$benchp" ''); fi
            /usr/bin/mbackhaul --smart-ports "$name" "$spec" >/dev/null
            ;;
        *) return 1;;
    esac
}
smart_apply_active_forwarding() { # groupdir ranking-file
    local gd="$1" rank="$2" state="$gd/forwarding.state" current previous='' current_kind='' previous_kind=''
    current=$(cut -d'|' -f1 "$gd/active.state" 2>/dev/null || true)
    [ -s "$state" ] && previous=$(cat "$state" 2>/dev/null || true)
    [ "$current" != "$previous" ] || return 0
    if [ -z "$current" ]; then
        [ -z "$previous" ] || smart_forward_one "$gd" "$previous" off || true
        : > "$state"; chmod 600 "$state"; return 0
    fi
    current_kind=$(awk -F'|' -v i="$current" '$1==i{print $3;exit}' "$gd/candidates.tsv")
    [ -z "$previous" ] || previous_kind=$(awk -F'|' -v i="$previous" '$1==i{print $3;exit}' "$gd/candidates.tsv")
    # Native proxy engines cannot bind the same public ports simultaneously. All other transitions are make-before-break.
    if [ -n "$previous" ] && [[ "$current_kind" =~ ^(rathole|backhaul)$ ]] && [[ "$previous_kind" =~ ^(rathole|backhaul)$ ]]; then
        smart_forward_one "$gd" "$previous" off || true
        if ! smart_forward_one "$gd" "$current" on; then
            smart_forward_one "$gd" "$previous" on >/dev/null 2>&1 || true
            return 1
        fi
    else
        if ! smart_forward_one "$gd" "$current" on; then return 1; fi
        [ -z "$previous" ] || smart_forward_one "$gd" "$previous" off || true
    fi
    printf '%s\n' "$current" > "$state"; chmod 600 "$state"
}
smart_benchmark_group_locked() { # groupdir; caller owns the process-level lock
    local gd="$1" cand="$gd/candidates.tsv" out="$gd/ranking.tsv" tmp="$gd/.bench.tmp" id label kind proto path name inner linkp benchp status lat loss jit up down score maxs=0 stats target target_port body resp
    [ -s "$cand" ] || return 1
    : > "$tmp"
    echo -e "\n  ${C}Starting benchmark (sequential; no simultaneous speed tests)...${NC}"
    while IFS='|' read -r id label kind proto path name inner linkp benchp status; do
        [ "$status" = UP ] || { printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|DOWN|9999|100|9999|0|0|0\n' "$id" "$label" "$kind" "$proto" "$path" "$name" "$inner" "$linkp" "$benchp" >> "$tmp"; continue; }
        echo -e "  ${DIM}[$id]${NC} ${W}$label${NC}"
        if [ "$kind" = backhaul ] || [ "$kind" = rathole ]; then
            body=$(H="$(smart_local_ipv4)" P="$linkp" python3 - <<'PY'
import json,os; print(json.dumps({'action':'tcp_probe','host':os.environ['H'],'port':int(os.environ['P'])},separators=(',',':')))
PY
)
            [[ "$path" != *v6* ]] || body=$(H="$(smart_local_ipv6)" P="$linkp" python3 - <<'PY'
import json,os; print(json.dumps({'action':'tcp_probe','host':os.environ['H'],'port':int(os.environ['P'])},separators=(',',':')))
PY
)
            resp=$(smart_agent_call "$body" || true); lat=$(smart_json_field "$resp" avg_ms); loss=$(smart_json_field "$resp" loss); jit=$(smart_json_field "$resp" jitter_ms); target=127.0.0.1; target_port="$benchp"
            if [ "$kind" = backhaul ]; then
                # Foreign loopback:5201 is remapped by Backhaul to this unique local benchmark port.
                up=$(smart_iperf_speed_backhaul "$benchp" normal); down=$(smart_iperf_speed_backhaul "$benchp" reverse)
            else
                # Rathole exposes the same benchmark port on both ends.
                up=$(smart_iperf_speed_rathole "$benchp" normal); down=$(smart_iperf_speed_rathole "$benchp" reverse)
            fi
        else
            stats=$(smart_ping_stats "$inner"); IFS='|' read -r lat loss jit <<< "$stats"; target="$inner"
            up=$(smart_iperf_speed "$inner" normal); down=$(smart_iperf_speed "$inner" reverse)
        fi
        lat=${lat:-9999}; loss=${loss:-100}; jit=${jit:-9999}; up=${up:-0}; down=${down:-0}
        status=UP
        if awk -v u="$up" -v d="$down" 'BEGIN{exit !(u<=0 && d<=0)}'; then status=DOWN; fi
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|0\n' "$id" "$label" "$kind" "$proto" "$path" "$name" "$inner" "$linkp" "$benchp" "$status" "$lat" "$loss" "$jit" "$up" "$down" >> "$tmp"
    done < "$cand"
    # recompute max speed robustly after all samples
    maxs=$(awk -F'|' 'BEGIN{m=0}$10=="UP"{s=($14+$15)/2;if(s>m)m=s}END{print m}' "$tmp")
    : > "$out"
    while IFS='|' read -r id label kind proto path name inner linkp benchp status lat loss jit up down _; do
        if [ "$status" = UP ]; then score=$(smart_score "$lat" "$loss" "$jit" "$up" "$down" "$maxs"); else score=0; fi
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$id" "$label" "$kind" "$proto" "$path" "$name" "$inner" "$linkp" "$benchp" "$status" "$lat" "$loss" "$jit" "$up" "$down" "$score" >> "$out"
    done < "$tmp"
    rm -f "$tmp"
    sort -t'|' -k16,16nr "$out" -o "$out"
    awk -F'|' '{print $1"|"$11"|"$16}' "$out" > "$gd/.baseline.tmp" && mv -f "$gd/.baseline.tmp" "$gd/baseline.tsv"
    chmod 600 "$gd/baseline.tsv" 2>/dev/null || true
    smart_hysteresis_order "$gd" "$out"
    local forward_rc=0
    smart_apply_active_forwarding "$gd" "$out" || forward_rc=$?
    rm -f "$gd/.rebench.pending" 2>/dev/null || true
    return "$forward_rc"
}
smart_benchmark_group() { # groupdir; use flock --close so children never inherit the lock fd
    local gd="$1" gid
    [ -d "$gd" ] || return 1
    gid=$(basename "$gd"); [[ "$gid" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 1
    flock -x -w 300 -o "$gd/.smart.lock" "$INSTALL_PATH" --benchmark-group "$gid"
}
smart_iperf_speed_backhaul() { # local mapped port direction
    local port="$1" reverse="$2" body resp out
    command -v iperf3 >/dev/null 2>&1 || { echo 0; return; }
    body=$(P="$IPERF_PORT" python3 - <<'PY'
import json,os; print(json.dumps({'action':'iperf_start','bind':'127.0.0.1','port':int(os.environ['P'])},separators=(',',':')))
PY
)
    resp=$(smart_agent_call "$body" || true); [ "$(smart_json_field "$resp" ok)" = 1 ] || { echo 0; return; }
    sleep .2
    local -a args=(-c 127.0.0.1 -p "$port" -t 4 -O 1 -J); [ "$reverse" = reverse ] && args+=(-R)
    out=$(timeout 15 iperf3 "${args[@]}" 2>/dev/null || true)
    IPERF_JSON="$out" python3 - <<'PY'
import json,os
try:
 d=json.loads(os.environ.get('IPERF_JSON','{}')); e=d.get('end',{}); x=e.get('sum_received') or e.get('sum') or {}; print(round(float(x.get('bits_per_second',0))/1e6,1))
except Exception: print(0)
PY
}
smart_show_ranking_file() {
    local f="$1" rank=0 id label kind proto path name inner linkp benchp status lat loss jit up down score
    [ -s "$f" ] || { echo -e "  ${Y}● No benchmark result yet.${NC}"; return 1; }
    echo -e "\n  ${FR}┌─[ SMART TUNNEL RANKING ]${NC}"
    printf '  %-3s %-27s %-8s %-8s %-8s %-9s %-9s %-7s\n' '#' 'Tunnel' 'Path' 'Ping' 'Loss' 'Up Mbps' 'Dn Mbps' 'Score'
    while IFS='|' read -r id label kind proto path name inner linkp benchp status lat loss jit up down score; do
        rank=$((rank+1)); printf '  %-3s %-27.27s %-8s %-8s %-8s %-9s %-9s %-7s\n' "$rank" "$label" "$path" "${lat}ms" "${loss}%" "$up" "$down" "$score"
    done < "$f"
}
smart_create_group() {
    smart_peer_load || { echo -e "  ${R}✖ Pair the Foreign server first.${NC}"; smart_pause; return 1; }
    smart_full_package_ready || { echo -e "  ${R}✖ Full MTunnel package is incomplete on Iran. Use Update & Local Install → A/B first.${NC}"; smart_pause; return 1; }
    local l4 l6 response ok f6 lbh=0 rbh=0 lrat=0 rrat=0 avail choice ids services gid gd rec id line label kind proto path base secret hash num core corev6 links local_link remote_link inner lname rname linkport benchport ports status
    l4=$(smart_local_ipv4); l6=$(smart_local_ipv6); response=$(smart_agent_call '{"action":"info"}' || true); ok=$(smart_json_field "$response" ok)
    [ "$ok" = 1 ] || { echo -e "  ${R}✖ Foreign Agent is offline: $(smart_json_field "$response" error)${NC}"; smart_pause; return 1; }
    [ "$(smart_json_field "$response" full_package_ready)" = 1 ] || { echo -e "  ${R}✖ Foreign full package is incomplete: $(smart_json_field "$response" full_package_missing)${NC}"; echo -e "  ${Y}Install Full Package A/B on Foreign before building tunnels.${NC}"; smart_pause; return 1; }
    f6=$(smart_json_field "$response" ipv6); [ "$f6" != Unknown ] || f6="$SMART_F6"
    if { [ -x /usr/local/bin/bh ] || [ -x /usr/bin/bh ]; }; then lbh=1; fi
    if { [ -x /usr/local/bin/rathole ] || [ -x /usr/bin/rathole ]; }; then lrat=1; fi
    rbh=$(smart_json_field "$response" backhaul_core); [ "$rbh" = 1 ] || rbh=0
    rrat=$(smart_json_field "$response" rathole_core); [ "$rrat" = 1 ] || rrat=0
    smart_reachability_matrix "$l4" "$l6" "$SMART_F4" "$f6"
    avail=$(smart_candidate_lines "$l4" "$l6" "$SMART_F4" "$f6" "$lbh" "$rbh" "$lrat" "$rrat" "$SMART_I_TO_F4" "$SMART_F_TO_I4" "$SMART_I_TO_F6" "$SMART_F_TO_I6")
    [ -n "$avail" ] || { echo -e "  ${R}✖ No compatible IPv4/IPv6 tunnel candidates found.${NC}"; smart_pause; return 1; }
    smart_header
    echo -e "\n  ${FR}┌─[ CREATE SMART TUNNEL GROUP ]${NC}"
    echo -e "  ${FR}├─${NC} Iran IPv4:    ${W}$l4${NC}"
    echo -e "  ${FR}├─${NC} Iran IPv6:    ${W}$l6${NC}"
    echo -e "  ${FR}├─${NC} Foreign IPv4: ${W}$SMART_F4${NC}"
    echo -e "  ${FR}├─${NC} Foreign IPv6: ${W}$f6${NC}"
    echo -e "  ${FR}│${NC}"
    while IFS='|' read -r id label kind proto path; do printf '  %b├─%b %b%-2s%b %b❯%b %-30s %b%s%b\n' "$FR" "$NC" "$W" "$id" "$NC" "$DIM" "$NC" "$label" "$DIM" "$path" "$NC"; done <<< "$avail"
    rec=$(smart_recommended_ids "$avail")
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${DIM}Fabric rule: max 1 mGRE + max 1 VXLAN; each one has 5 vIPs.${NC}"
    echo -e "  ${FR}│${NC}\n  ${FR}├─${NC} ${W}r${NC} ${DIM}❯${NC} ${G}Recommended set${NC} ${DIM}[$rec]${NC}"
    echo -e "  ${FR}├─${NC} ${W}a${NC} ${DIM}❯${NC} ${Y}Build all compatible${NC}"
    echo -e "  ${FR}└─${NC} ${W}m${NC} ${DIM}❯${NC} Manual IDs ${DIM}(example: 1,4,7,12)${NC}\n"
    echo -ne "  ${C}Select tunnel set [r]: ${NC}"; read -r choice; choice="${choice:-r}"
    case "$choice" in
        r|R) ids="$rec";; a|A) ids=$(smart_all_ids "$avail");;
        m|M) echo -ne "  ${C}IDs: ${NC}"; read -r ids;; *) ids="$choice";;
    esac
    ids="${ids// /}"; [[ "$ids" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo -e "  ${R}✖ Invalid selection.${NC}"; smart_pause; return 1; }
    for id in ${ids//,/ }; do awk -F'|' -v x="$id" '$1==x{f=1} END{exit !f}' <<< "$avail" || { echo -e "  ${R}✖ Candidate $id is not available.${NC}"; smart_pause; return 1; }; done
    local requested_ids="$ids"; ids=$(smart_unique_fabric_ids "$avail" "$ids")
    if [ "$ids" != "$requested_ids" ]; then
        echo -e "  ${Y}● Smart keeps one mGRE and one VXLAN fabric per group; each fabric carries 5 virtual IPs.${NC}"
        echo -e "  ${DIM}Selected fabric set: $ids${NC}"
    fi
    while true; do
        echo -ne "
  ${C}●${NC} ${W}Service TCP ports [example: 443,8443,2053]: ${NC}"; read -r services
        smart_validate_service_ports "$services" && { services="$SMART_SERVICE_PORTS"; break; }
        echo -e "  ${R}✖ Enter one or more comma-separated TCP ports.${NC}"
    done
    gid="sg$(date +%m%d%H%M)-$(smart_random_hex 2)"; gd="$GROUP_DIR/$gid"; mkdir -p "$gd"; chmod 700 "$gd"
    cat > "$gd/group.conf" <<EOF
GROUP_ID=$gid
CREATED_AT=$(date +%s)
SERVICE_PORTS=$services
IRAN_IPV4=$l4
IRAN_IPV6=$l6
FOREIGN_IPV4=$SMART_F4
FOREIGN_IPV6=$f6
IRAN_TO_FOREIGN_V4=$SMART_I_TO_F4
FOREIGN_TO_IRAN_V4=$SMART_F_TO_I4
IRAN_TO_FOREIGN_V6=$SMART_I_TO_F6
FOREIGN_TO_IRAN_V6=$SMART_F_TO_I6
WATCHDOG=1
EOF
    : > "$gd/candidates.tsv"; : > "$gd/names.tsv"
    echo -e "\n  ${C}Creating selected tunnels on Foreign + Iran...${NC}"
    for id in ${ids//,/ }; do
        line=$(awk -F'|' -v x="$id" '$1==x{print;exit}' <<< "$avail"); IFS='|' read -r id label kind proto path <<< "$line"
        secret=$(smart_random_hex 16); hash=$(smart_sha "$gid:$id:$secret"); base="s${id}${hash:0:5}"; num=$((16#${hash:0:6})); [ "$num" -gt 0 ] || num=1
        corev6="fd${hash:0:2}:${hash:2:4}:${hash:6:4}:${hash:10:4}"
        linkport=''; benchport=''; inner=''; lname=''; rname=''; ports=''; status=DOWN
        if [ "$kind" = vxlan ]; then core=$(mt_legacy_core_subnet "$num" vxlan); else core=$(mt_legacy_core_subnet "$num" gre); fi
        echo -e "  ${DIM}[$id]${NC} ${W}$label${NC}"
        if [ "$kind" = rathole ]; then
            linkport=$(smart_pick_port $((30000 + id*17)) "$services") || true; benchport=$(smart_pick_port $((38000 + id*17)) "$services") || true
            [ -n "$linkport" ] && [ -n "$benchport" ] || { echo -e "      ${R}✖ No free port${NC}"; printf '%s|%s|%s|%s|%s|%s|||%s|DOWN\n' "$id" "$label" "$kind" "$proto" "$path" "$base" "$benchport" >> "$gd/candidates.tsv"; continue; }
            links=$(smart_rathole_links "$path" "$base" "$secret" "$linkport" "$benchport" "$services" "$l4" "$l6" "$SMART_F4" "$f6") || true
            IFS='|' read -r local_link remote_link lname rname <<< "$links"
        elif [ "$kind" = backhaul ]; then
            linkport=$(smart_pick_port $((28000 + id*17)) "$services") || true; benchport=$(smart_pick_port $((36000 + id*17)) "$services") || true
            [ -n "$linkport" ] && [ -n "$benchport" ] || { echo -e "      ${R}✖ No free port${NC}"; printf '%s|%s|%s|%s|%s|%s|||%s|DOWN\n' "$id" "$label" "$kind" "$proto" "$path" "bh_$base" "$benchport" >> "$gd/candidates.tsv"; continue; }
            ports="${benchport}=127.0.0.1:${IPERF_PORT}"
            links=$(smart_backhaul_links "$proto" "$path" "$base" "$secret" "$linkport" "$ports" "$l4" "$l6" "$SMART_F4" "$f6") || true
            IFS='|' read -r local_link remote_link lname rname <<< "$links"
        else
            links=$(smart_network_links "$kind" "$proto" "$base" "$secret" "$num" "$core" "$corev6" "$l4" "$l6" "$SMART_F4" "$f6") || true
            IFS='|' read -r local_link remote_link inner lname rname <<< "$links"
        fi
        [ -z "$lname" ] || [ -z "$rname" ] || printf '%s|%s|%s|%s\n' "$id" "$kind" "$lname" "$rname" >> "$gd/names.tsv"
        if [ -z "$remote_link" ] || ! smart_deploy_remote "$kind" "$remote_link"; then
            echo -e "      ${R}✖ Foreign side failed${NC}"
        else
            echo -e "      ${G}✓ Foreign side${NC}"
            if smart_deploy_local "$kind" "$local_link" >/dev/null 2>&1; then
                status=UP; echo -e "      ${G}✓ Iran side${NC}"
            else
                echo -e "      ${R}✖ Iran side failed — rolling back Foreign side${NC}"
                [ -z "$rname" ] || smart_delete_remote "$kind" "$rname" >/dev/null 2>&1 || true
            fi
        fi
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$id" "$label" "$kind" "$proto" "$path" "$lname" "$inner" "$linkport" "$benchport" "$status" >> "$gd/candidates.tsv"
    done
    local bench_rc=0
    smart_benchmark_group "$gd" || bench_rc=$?
    smart_install_watchdog
    smart_header; smart_show_ranking_file "$gd/ranking.tsv"
    if [ "$bench_rc" -eq 0 ]; then
        echo -e "\n  ${G}✓ Smart forwarding active for TCP ports: ${services}${NC}"
        echo -e "  ${DIM}GRE/VXLAN: 5-vIP iptables load-balance | Rathole/Backhaul: native forwarder${NC}"
    else
        echo -e "\n  ${Y}⚠ Ranking completed, but the active tunnel forwarder could not be enabled.${NC}"
    fi
    echo -e "  ${DIM}Group: $gid${NC}"
    smart_pause
}
smart_install_watchdog() {
    cat > "$WATCH_SERVICE" <<'EOF'
[Unit]
Description=MTunnel Smart lightweight health ranking
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/msmart --watchdog-once
EOF
    cat > "$WATCH_TIMER" <<'EOF'
[Unit]
Description=MTunnel Smart health timer

[Timer]
OnBootSec=20s
OnUnitActiveSec=10s
AccuracySec=2s
Unit=mtunnel-smart-watchdog.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload >/dev/null 2>&1; systemctl enable --now mtunnel-smart-watchdog.timer >/dev/null 2>&1 || true
}
smart_schedule_rebenchmark() { # groupdir
    local gd="$1" gid unit
    [ -d "$gd" ] || return 1
    gid=$(basename "$gd"); [[ "$gid" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 1
    ( set -o noclobber; : > "$gd/.rebench.pending" ) 2>/dev/null || return 0
    chmod 600 "$gd/.rebench.pending" 2>/dev/null || true
    unit="mtunnel-smart-rebench-${gid}-$(date +%s)"
    if command -v systemd-run >/dev/null 2>&1 && systemd-run --quiet --collect --unit="$unit" --on-active=30s "$INSTALL_PATH" --benchmark-group "$gid" >/dev/null 2>&1; then
        return 0
    fi
    nohup sh -c 'sleep 30; exec "$1" --benchmark-group "$2"' sh "$INSTALL_PATH" "$gid" >/dev/null 2>&1 &
}
smart_recovery_score() { # latency loss jitter -> provisional health-only score, capped below a fully benchmarked candidate
    python3 - "$1" "$2" "$3" <<'PY'
import sys
lat,loss,jit=map(float,sys.argv[1:4])
score=55.0-min(lat,500.0)*0.05-loss*1.2-max(0.0,jit-10.0)*0.08
print(round(max(5.0,min(55.0,score)),1))
PY
}
smart_watchdog_group_locked() { # gid; caller owns process-level flock --close
    local gid="$1" gd="$GROUP_DIR/$1" f baseline tmp id label kind proto path name inner linkp benchp status blat loss jit up down current_score base_score live_score pstat unit loss_now jit_now lat base_lat needs_rebench=0
    [[ "$gid" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 1
    [ -d "$gd" ] || return 0
    [ "$(smart_conf_get "$gd/group.conf" WATCHDOG)" = 1 ] || return 0
    f="$gd/ranking.tsv"; baseline="$gd/baseline.tsv"; [ -s "$f" ] || return 0
    tmp="$gd/.ranking.live"; : > "$tmp"
    while IFS='|' read -r id label kind proto path name inner linkp benchp status blat loss jit up down current_score; do
        base_lat=$(awk -F'|' -v i="$id" '$1==i{print $2;exit}' "$baseline" 2>/dev/null || true)
        base_score=$(awk -F'|' -v i="$id" '$1==i{print $3;exit}' "$baseline" 2>/dev/null || true)
        [[ "$base_lat" =~ ^[0-9]+([.][0-9]+)?$ ]] || base_lat="$blat"
        [[ "$base_score" =~ ^[0-9]+([.][0-9]+)?$ ]] || base_score="$current_score"
        status=DOWN; live_score=0
        if [ "$kind" = backhaul ] || [ "$kind" = rathole ]; then
            unit="mbackhaul@$name"; [ "$kind" = rathole ] && unit="mrathole@$name"
            if systemctl is-active --quiet "$unit" 2>/dev/null && ss -tn state established 2>/dev/null | grep -Eq ":${linkp}([[:space:]]|$)"; then
                status=UP
                if awk -v b="${base_score:-0}" 'BEGIN{exit !(b<=0)}'; then
                    live_score=40; needs_rebench=1
                else
                    live_score="$base_score"
                fi
            fi
        else
            pstat=$(smart_ping_stats "$inner" 2); IFS='|' read -r lat loss_now jit_now <<< "$pstat"
            if awk -v l="$loss_now" 'BEGIN{exit !(l<100)}'; then
                status=UP
                if awk -v b="${base_score:-0}" 'BEGIN{exit !(b<=0)}'; then
                    live_score=$(smart_recovery_score "$lat" "$loss_now" "$jit_now"); needs_rebench=1
                else
                    live_score=$(python3 - "$base_score" "$base_lat" "$lat" "$loss_now" "$jit_now" <<'PY'
import sys
base,old,now,loss,jit=map(float,sys.argv[1:]); penalty=max(0,now-old)*.18+loss*1.5+max(0,jit-10)*.08; print(round(max(0,base-penalty),1))
PY
)
                fi
                blat="$lat"; loss="$loss_now"; jit="$jit_now"
            fi
        fi
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$id" "$label" "$kind" "$proto" "$path" "$name" "$inner" "$linkp" "$benchp" "$status" "$blat" "$loss" "$jit" "$up" "$down" "$live_score" >> "$tmp"
    done < "$f"
    sort -t'|' -k10,10r -k16,16nr "$tmp" -o "$tmp"; mv -f "$tmp" "$f"; chmod 600 "$f"
    smart_hysteresis_order "$gd" "$f"
    smart_apply_active_forwarding "$gd" "$f" || true
    [ "$needs_rebench" -eq 0 ] || smart_schedule_rebenchmark "$gd" || true
}
smart_watchdog_once() {
    smart_peer_load || return 0
    local gd gid
    for gd in "$GROUP_DIR"/*; do
        [ -d "$gd" ] || continue
        gid=$(basename "$gd")
        [ "$(smart_conf_get "$gd/group.conf" WATCHDOG)" = 1 ] || continue
        flock -n -o "$gd/.smart.lock" "$INSTALL_PATH" --watchdog-group "$gid" >/dev/null 2>&1 || true
    done
}
smart_conf_set() { # file key value (atomic)
    local file="$1" key="$2" value="$3" tmp
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 1
    [ -f "$file" ] || return 1
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    awk -v k="$key" -v v="$value" 'BEGIN{done=0} index($0,k"=")==1 {if(!done){print k"="v;done=1} next} {print} END{if(!done)print k"="v}' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    mv -f "$tmp" "$file"
}
smart_group_dirs() {
    local gd
    for gd in "$GROUP_DIR"/*; do [ -d "$gd" ] && printf '%s\n' "$gd"; done
}
smart_select_group() { # sets SMART_SELECTED_GD / SMART_SELECTED_GID
    local -a groups=(); local gd i sel
    while IFS= read -r gd; do [ -n "$gd" ] && groups+=("$gd"); done < <(smart_group_dirs)
    [ ${#groups[@]} -gt 0 ] || { echo -e "\n  ${Y}● No Smart groups.${NC}"; return 1; }
    echo -e "\n  ${FR}┌─[ SELECT SMART GROUP ]${NC}"
    for i in "${!groups[@]}"; do
        local gid active ports count
        gid=$(basename "${groups[$i]}")
        active=$(cut -d'|' -f2 "${groups[$i]}/active.state" 2>/dev/null || true); [ -n "$active" ] || active='OFF'
        ports=$(smart_conf_get "${groups[$i]}/group.conf" SERVICE_PORTS); count=0
        [ -n "$ports" ] && count=$(awk -F, '{print NF}' <<< "$ports")
        printf '  %b├─%b %b%-2s%b %b❯%b %-22s %bActive:%b %-22s %bPorts:%b %s\n' "$FR" "$NC" "$W" "$((i+1))" "$NC" "$DIM" "$NC" "$gid" "$DIM" "$NC" "$active" "$DIM" "$NC" "$count"
    done
    echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} Back"
    echo -ne "  ${C}Select group ❯❯ ${NC}"; read -r sel
    [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#groups[@]} ] || return 1
    SMART_SELECTED_GD="${groups[$((sel-1))]}"; SMART_SELECTED_GID=$(basename "$SMART_SELECTED_GD")
    return 0
}
smart_list_groups() {
    mt_workspace_screen; smart_header
    local gd found=0 gid active aid alabel ascore ports candidates up down
    echo -e "\n  ${FR}┌─[ SMART GROUPS ]${NC}"
    for gd in "$GROUP_DIR"/*; do
        [ -d "$gd" ] || continue; found=1; gid=$(basename "$gd")
        active=$(cat "$gd/active.state" 2>/dev/null || true); IFS='|' read -r aid alabel ascore <<< "$active"
        ports=$(smart_conf_get "$gd/group.conf" SERVICE_PORTS); candidates=$(awk 'END{print NR+0}' "$gd/candidates.tsv" 2>/dev/null || echo 0)
        up=$(awk -F'|' '$10=="UP"{n++} END{print n+0}' "$gd/ranking.tsv" 2>/dev/null || echo 0); down=$((candidates-up)); [ "$down" -ge 0 ] || down=0
        echo -e "  ${FR}├─${NC} ${W}${gid}${NC}"
        echo -e "  ${FR}│${NC}   ${DIM}Active${NC}  ${G}${alabel:-OFF}${NC} ${DIM}${ascore:+(score $ascore)}${NC}"
        echo -e "  ${FR}│${NC}   ${DIM}Tunnels${NC} ${W}${candidates}${NC} ${DIM}(UP ${up} / DOWN ${down})${NC}"
        echo -e "  ${FR}│${NC}   ${DIM}Ports${NC}   ${C}${ports:--}${NC}"
    done
    [ "$found" = 1 ] || echo -e "  ${FR}├─${NC} ${DIM}No Smart groups created.${NC}"
    echo -e "  ${FR}└────────────────────────────────────────────────────────────────────${NC}"
    smart_pause
}
smart_list_tunnels() {
    mt_workspace_screen; smart_header
    local gd gid found=0 line id label kind proto path name inner linkp benchp status score active_id
    echo -e "\n  ${FR}┌─[ SMART TUNNELS ]${NC}"
    for gd in "$GROUP_DIR"/*; do
        [ -d "$gd" ] || continue; found=1; gid=$(basename "$gd"); active_id=$(cut -d'|' -f1 "$gd/active.state" 2>/dev/null || true)
        echo -e "  ${FR}├─${NC} ${W}${gid}${NC}"
        if [ -s "$gd/candidates.tsv" ]; then
            while IFS='|' read -r id label kind proto path name inner linkp benchp status; do
                score=$(awk -F'|' -v i="$id" '$1==i{print $16;exit}' "$gd/ranking.tsv" 2>/dev/null || true)
                local ranked_status; ranked_status=$(awk -F'|' -v i="$id" '$1==i{print $10;exit}' "$gd/ranking.tsv" 2>/dev/null || true); [ -z "$ranked_status" ] || status="$ranked_status"
                [ "$id" = "$active_id" ] && printf '  %b│%b   %b★ %-3s%b %-29s %b%-8s%b %-13s %bscore:%b %s\n' "$FR" "$NC" "$G" "$id" "$NC" "$label" "$C" "${status:-?}" "$NC" "$path" "$DIM" "$NC" "${score:--}" || printf '  %b│%b     %-3s %-29s %b%-8s%b %-13s %bscore:%b %s\n' "$FR" "$NC" "$id" "$label" "$DIM" "${status:-?}" "$NC" "$path" "$DIM" "$NC" "${score:--}"
            done < "$gd/candidates.tsv"
        else
            echo -e "  ${FR}│${NC}   ${DIM}No tunnels.${NC}"
        fi
    done
    [ "$found" = 1 ] || echo -e "  ${FR}├─${NC} ${DIM}No Smart groups created.${NC}"
    echo -e "  ${FR}└────────────────────────────────────────────────────────────────────${NC}"
    smart_pause
}
smart_list_ports() {
    mt_workspace_screen; smart_header
    local gd gid ports active
    echo -e "\n  ${FR}┌─[ SMART PORTS ]${NC}"
    local found=0
    for gd in "$GROUP_DIR"/*; do
        [ -d "$gd" ] || continue; found=1; gid=$(basename "$gd"); ports=$(smart_conf_get "$gd/group.conf" SERVICE_PORTS); active=$(cut -d'|' -f2 "$gd/active.state" 2>/dev/null || true)
        echo -e "  ${FR}├─${NC} ${W}${gid}${NC} ${DIM}→ Active:${NC} ${G}${active:-OFF}${NC}"
        echo -e "  ${FR}│${NC}   ${C}TCP${NC} ${DIM}❯${NC} ${W}${ports:--}${NC}"
    done
    [ "$found" = 1 ] || echo -e "  ${FR}├─${NC} ${DIM}No Smart groups created.${NC}"
    echo -e "  ${FR}└────────────────────────────────────────────────────────────────────${NC}"
    smart_pause
}
smart_ports_parse_basic() { # input -> SMART_EDIT_PORTS
    local s="${1// /}" p; local -A seen=(); local -a arr=(); SMART_EDIT_PORTS=''
    [ -n "$s" ] || return 1; [[ "$s" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
    IFS=, read -ra arr <<< "$s"
    for p in "${arr[@]}"; do mt_valid_port "$p" || return 1; p=$((10#$p)); [ -z "${seen[$p]:-}" ] || continue; seen[$p]=1; SMART_EDIT_PORTS+="${SMART_EDIT_PORTS:+,}$p"; done
}
smart_refresh_group_ports() { # groupdir
    local gd="$1" active
    active=$(cat "$gd/forwarding.state" 2>/dev/null || true); [ -n "$active" ] || active=$(cut -d'|' -f1 "$gd/active.state" 2>/dev/null || true)
    [ -z "$active" ] || smart_forward_one "$gd" "$active" on
}
smart_add_ports() {
    mt_workspace_screen; smart_header; smart_select_group || { smart_pause; return; }
    local gd="$SMART_SELECTED_GD" current add p merged
    current=$(smart_conf_get "$gd/group.conf" SERVICE_PORTS)
    echo -e "\n  ${FR}┌─[ ADD PORTS — ${SMART_SELECTED_GID} ]${NC}"
    echo -e "  ${FR}├─${NC} Current: ${W}${current:--}${NC}"
    echo -ne "  ${FR}└─${NC} ${C}TCP ports to add (comma-separated): ${NC}"; read -r add
    smart_ports_parse_basic "$add" || { echo -e "  ${R}✖ Invalid ports.${NC}"; smart_pause; return; }
    add="$SMART_EDIT_PORTS"; merged="$current"
    for p in ${add//,/ }; do
        [[ ",$current," == *",$p,"* ]] && continue
        if ss -lntH 2>/dev/null | awk -v want="$p" '{n=split($4,a,":"); if(a[n]==want) found=1} END{exit !found}'; then echo -e "  ${R}✖ Port $p is already in use by another listener.${NC}"; smart_pause; return; fi
        merged+="${merged:+,}$p"
    done
    [ "$merged" != "$current" ] || { echo -e "  ${Y}● No new ports to add.${NC}"; smart_pause; return; }
    smart_conf_set "$gd/group.conf" SERVICE_PORTS "$merged" || { echo -e "  ${R}✖ Could not save ports.${NC}"; smart_pause; return; }
    if ! smart_refresh_group_ports "$gd"; then smart_conf_set "$gd/group.conf" SERVICE_PORTS "$current" >/dev/null 2>&1 || true; smart_refresh_group_ports "$gd" >/dev/null 2>&1 || true; echo -e "  ${R}✖ Forwarder rejected the new port set; rolled back.${NC}"; smart_pause; return; fi
    echo -e "  ${G}✔ Ports updated:${NC} ${W}$merged${NC}"; smart_pause
}
smart_remove_ports() {
    mt_workspace_screen; smart_header; smart_select_group || { smart_pause; return; }
    local gd="$SMART_SELECTED_GD" current rem p out='' count=0
    current=$(smart_conf_get "$gd/group.conf" SERVICE_PORTS); [ -n "$current" ] || { echo -e "  ${Y}● This group has no service ports.${NC}"; smart_pause; return; }
    echo -e "\n  ${FR}┌─[ REMOVE PORTS — ${SMART_SELECTED_GID} ]${NC}"
    echo -e "  ${FR}├─${NC} Current: ${W}$current${NC}"
    echo -ne "  ${FR}└─${NC} ${C}TCP ports to remove (comma-separated): ${NC}"; read -r rem
    smart_ports_parse_basic "$rem" || { echo -e "  ${R}✖ Invalid ports.${NC}"; smart_pause; return; }; rem="$SMART_EDIT_PORTS"
    for p in ${current//,/ }; do [[ ",$rem," == *",$p,"* ]] && continue; out+="${out:+,}$p"; count=$((count+1)); done
    [ "$out" != "$current" ] || { echo -e "  ${Y}● None of those ports belong to this group.${NC}"; smart_pause; return; }
    [ "$count" -gt 0 ] || { echo -e "  ${R}✖ A Smart group must keep at least one service port. Delete the group if you want to remove everything.${NC}"; smart_pause; return; }
    smart_conf_set "$gd/group.conf" SERVICE_PORTS "$out" || { echo -e "  ${R}✖ Could not save ports.${NC}"; smart_pause; return; }
    if ! smart_refresh_group_ports "$gd"; then smart_conf_set "$gd/group.conf" SERVICE_PORTS "$current" >/dev/null 2>&1 || true; smart_refresh_group_ports "$gd" >/dev/null 2>&1 || true; echo -e "  ${R}✖ Forwarder rejected the new port set; rolled back.${NC}"; smart_pause; return; fi
    echo -e "  ${G}✔ Ports updated:${NC} ${W}$out${NC}"; smart_pause
}
smart_delete_tunnel_locked() { # gid candidate-id
    local gid="$1" tid="$2" gd="$GROUP_DIR/$1" row kind lname rname active failed=0 tmp f
    [[ "$gid" =~ ^[A-Za-z0-9_.-]{1,64}$ && "$tid" =~ ^[0-9]+$ ]] || return 2
    [ -d "$gd" ] || return 0
    row=$(awk -F'|' -v i="$tid" '$1==i{print;exit}' "$gd/candidates.tsv" 2>/dev/null); [ -n "$row" ] || return 0
    kind=$(awk -F'|' -v i="$tid" '$1==i{print $2;exit}' "$gd/names.tsv" 2>/dev/null)
    lname=$(awk -F'|' -v i="$tid" '$1==i{print $3;exit}' "$gd/names.tsv" 2>/dev/null)
    rname=$(awk -F'|' -v i="$tid" '$1==i{print $4;exit}' "$gd/names.tsv" 2>/dev/null)
    if [ -z "$kind" ]; then IFS='|' read -r _ _ kind _ _ lname _ <<< "$row"; rname="$lname"; fi
    active=$(cat "$gd/forwarding.state" 2>/dev/null || true)
    if [ "$active" = "$tid" ]; then smart_forward_one "$gd" "$tid" off >/dev/null 2>&1 || true; : > "$gd/forwarding.state"; fi
    [ -z "$rname" ] || smart_delete_remote "$kind" "$rname" >/dev/null 2>&1 || failed=1
    [ -z "$lname" ] || smart_delete_local "$kind" "$lname" >/dev/null 2>&1 || failed=1
    [ "$failed" -eq 0 ] || return 1
    for f in candidates.tsv names.tsv ranking.tsv baseline.tsv; do
        [ -f "$gd/$f" ] || continue; tmp="$gd/.${f}.tmp.$$"; awk -F'|' -v i="$tid" '$1!=i' "$gd/$f" > "$tmp" && mv -f "$tmp" "$gd/$f"; chmod 600 "$gd/$f" 2>/dev/null || true
    done
    rm -f "$gd/hysteresis.state" "$gd/active.state"
    if [ -s "$gd/ranking.tsv" ]; then smart_hysteresis_order "$gd" "$gd/ranking.tsv"; smart_apply_active_forwarding "$gd" "$gd/ranking.tsv" || true
    else : > "$gd/active.state"; : > "$gd/forwarding.state"; fi
    return 0
}
smart_delete_tunnel_menu() {
    mt_workspace_screen; smart_header; smart_select_group || { smart_pause; return; }
    local gd="$SMART_SELECTED_GD" gid="$SMART_SELECTED_GID" active_id id label kind proto path name inner linkp benchp status sel confirm
    [ -s "$gd/candidates.tsv" ] || { echo -e "  ${Y}● No tunnels in this group.${NC}"; smart_pause; return; }
    active_id=$(cut -d'|' -f1 "$gd/active.state" 2>/dev/null || true)
    echo -e "\n  ${FR}┌─[ DELETE TUNNEL — ${gid} ]${NC}"
    while IFS='|' read -r id label kind proto path name inner linkp benchp status; do
        if [ "$id" = "$active_id" ]; then echo -e "  ${FR}├─${NC} ${R}${id}${NC} ${DIM}❯${NC} ${W}${label}${NC} ${G}[ACTIVE]${NC}"
        else echo -e "  ${FR}├─${NC} ${W}${id}${NC} ${DIM}❯${NC} ${label}"; fi
    done < "$gd/candidates.tsv"
    echo -ne "  ${FR}└─${NC} ${C}Tunnel ID to delete: ${NC}"; read -r sel
    [[ "$sel" =~ ^[0-9]+$ ]] && awk -F'|' -v i="$sel" '$1==i{f=1} END{exit !f}' "$gd/candidates.tsv" || { echo -e "  ${R}✖ Invalid tunnel ID.${NC}"; smart_pause; return; }
    echo -ne "  ${R}Type DELETE to remove this tunnel from Iran + Foreign: ${NC}"; read -r confirm; [ "$confirm" = DELETE ] || return
    if flock -x -w 45 -o "$gd/.smart.lock" "$INSTALL_PATH" --delete-tunnel "$gid" "$sel"; then echo -e "  ${G}✔ Tunnel deleted.${NC}"; else echo -e "  ${R}✖ Delete failed; group state was retained for retry.${NC}"; fi
    smart_pause
}
smart_delete_group_menu() {
    mt_workspace_screen; smart_header; smart_select_group || { smart_pause; return; }
    local confirm gd="$SMART_SELECTED_GD" gid="$SMART_SELECTED_GID"
    echo -e "\n  ${R}┌─[ DELETE SMART GROUP ]${NC}"
    echo -e "  ${R}├─${NC} Group: ${W}$gid${NC}"
    echo -e "  ${R}├─${NC} This removes every tunnel in the group from Iran + Foreign."
    echo -ne "  ${R}└─${NC} Type ${W}DELETE${NC}${R} to continue: ${NC}"; read -r confirm; [ "$confirm" = DELETE ] || return
    if flock -x -w 60 -o "$gd/.smart.lock" "$INSTALL_PATH" --delete-group "$gid"; then echo -e "  ${G}✔ Smart group deleted.${NC}"; else echo -e "  ${R}✖ Cleanup did not finish. State was retained so you can retry.${NC}"; fi
    smart_pause
}
smart_manage_menu() {
    local opt
    while true; do
        mt_workspace_screen; smart_header
        mt_workspace_group 'GROUPS & TUNNELS' first
        mt_workspace_row 1 'List Groups' "$C"
        mt_workspace_row 2 'List Tunnels' "$G"
        mt_workspace_row 3 'Delete Tunnel' "$R"
        mt_workspace_row 4 'Delete Group' "$R"
        mt_workspace_footer 'Back to MSmart'
        echo -ne "  ${C}MANAGE ❯❯ ${NC}"; read -r opt
        case "$opt" in 1) smart_list_groups;; 2) smart_list_tunnels;; 3) smart_delete_tunnel_menu;; 4) smart_delete_group_menu;; 0|q|Q) break;; *) sleep 1;; esac
    done
}
smart_ports_menu() {
    local opt
    while true; do
        mt_workspace_screen; smart_header
        mt_workspace_group 'PORTS & FORWARDING' first
        mt_workspace_row 1 'List Group Ports' "$C"
        mt_workspace_row 2 'Add TCP Ports' "$G"
        mt_workspace_row 3 'Remove TCP Ports' "$R"
        mt_workspace_footer 'Back to MSmart'
        echo -ne "  ${C}PORTS ❯❯ ${NC}"; read -r opt
        case "$opt" in 1) smart_list_ports;; 2) smart_add_ports;; 3) smart_remove_ports;; 0|q|Q) break;; *) sleep 1;; esac
    done
}

smart_benchmark_menu() {
    smart_header
    local -a groups=(); local gd i sel
    for gd in "$GROUP_DIR"/*; do [ -d "$gd" ] && groups+=("$gd"); done
    [ ${#groups[@]} -gt 0 ] || { echo -e "\n  ${Y}● No Smart groups.${NC}"; smart_pause; return; }
    echo -e "\n  ${FR}┌─[ BENCHMARK / RANKING ]${NC}"
    for i in "${!groups[@]}"; do echo -e "  ${FR}├─${NC} ${W}$((i+1))${NC} ${DIM}❯${NC} $(basename "${groups[$i]}")"; done
    echo -ne "  ${C}Select: ${NC}"; read -r sel
    [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#groups[@]} ] || return
    gd="${groups[$((sel-1))]}"; smart_benchmark_group "$gd"; smart_header; smart_show_ranking_file "$gd/ranking.tsv"; smart_pause
}
smart_prerequisites_screen() {
    smart_header
    echo -e "\n  ${FR}┌─[ PREREQUISITES ]${NC}"
    echo -e "  ${FR}│${NC} ${W}Please open this same Smart Tunnel menu on both servers.${NC}"
    echo -e "  ${FR}│${NC} ${Y}0. FIRST install the complete MTunnel package on BOTH servers.${NC}"
    echo -e "  ${FR}│${NC}    ${DIM}Update & Local Install → ${W}A${NC}${DIM} (GitHub) or ${W}B${NC}${DIM} (Mirror).${NC}"
    echo -e "  ${FR}│${NC}    ${DIM}This installs all tunnel scripts, engines/cores and prerequisite packages before Smart starts.${NC}"
    echo -e "  ${FR}│${NC} 1. Choose the role of each server below."
    echo -e "  ${FR}│${NC} 2. Foreign generates the ${M}Pair Code${NC}."
    echo -e "  ${FR}│${NC} 3. Iran asks only for ${W}Foreign IPv4 + Pair Code${NC}."
    echo -e "  ${FR}│${NC} ${DIM}The Pair Code carries Foreign IPv6, Agent port, TLS fingerprint and a one-time secret.${NC}"
    echo -e "  ${FR}│${NC} ${DIM}After pairing, all Smart management is performed from Iran; Foreign stays automatic.${NC}"
    echo -e "  ${FR}└────────────────────────────────────────────────────────────${NC}"
    [ "${1:-}" = nopause ] || smart_pause
}
smart_setup_flow() {
    local role
    smart_prerequisites_screen nopause
    smart_full_package_gate || { smart_pause; return 1; }
    echo -e "\n  ${FR}┌─[ SERVER ROLE ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Iran Server / Controller${NC}"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Foreign Server / Agent${NC}"
    echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} Back"
    echo -ne "  ${C}Role ❯❯ ${NC}"; read -r role
    case "$role" in
        1) smart_pair_controller;;
        2) smart_foreign_setup;;
        *) return 0;;
    esac
}
render_msmart_menu() {
    mt_workspace_screen
    smart_header
    mt_workspace_group 'PROVISION & PAIR' first
    mt_workspace_row 1 'Prerequisites & Pair Setup' "$Y"
    mt_workspace_row 2 'Create Smart Tunnel Group' "$G"
    mt_workspace_group 'EDIT & MANAGE'
    mt_workspace_row 3 'Groups & Tunnels' "$C"
    mt_workspace_row 4 'Ports & Forwarding' "$G"
    mt_workspace_group 'MONITOR & SYSTEM'
    mt_workspace_row 5 'Benchmark / Ranking' "$M"
    mt_workspace_row 6 'Peer Status' "$C"
    mt_workspace_row 7 'Update & Local Install' "$G" "$(smart_update_badge)"
    mt_workspace_footer 'Return to Main Core'
}
smart_menu() {
    local opt
    while true; do
        render_msmart_menu
        echo -ne "  ${C}MSMART ❯❯ ${NC}"; read -r opt
        case "$opt" in
            1) smart_setup_flow;;
            2) smart_create_group;;
            3) smart_manage_menu;;
            4) smart_ports_menu;;
            5) smart_benchmark_menu;;
            6) smart_info;;
            7) smart_update_menu;;
            0|q|Q) break;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1;;
        esac
    done
}


smart_delete_group_locked() { # gid; retain state if either side cannot be cleaned
    local gid="$1" gd="$GROUP_DIR/$1" active id kind lname rname failed=0
    [[ "$gid" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 2
    [ -d "$gd" ] || return 0
    active=$(cat "$gd/forwarding.state" 2>/dev/null || true)
    [ -z "$active" ] || smart_forward_one "$gd" "$active" off >/dev/null 2>&1 || failed=1
    if [ -s "$gd/names.tsv" ]; then
        while IFS='|' read -r id kind lname rname; do
            [ -z "$rname" ] || smart_delete_remote "$kind" "$rname" >/dev/null 2>&1 || failed=1
            [ -z "$lname" ] || smart_delete_local "$kind" "$lname" >/dev/null 2>&1 || failed=1
        done < "$gd/names.tsv"
    elif [ -s "$gd/candidates.tsv" ]; then
        while IFS='|' read -r id _ kind _ _ lname _; do
            [ -z "$lname" ] || smart_delete_local "$kind" "$lname" >/dev/null 2>&1 || failed=1
        done < "$gd/candidates.tsv"
    fi
    if [ "$failed" -eq 0 ]; then
        rm -rf -- "$gd"
        return 0
    fi
    printf '%s\n' "$(date +%s)" > "$gd/delete.pending"
    chmod 600 "$gd/delete.pending" 2>/dev/null || true
    return 1
}
smart_delete_groups() {
    local gd gid failed=0 left=0
    systemctl disable --now mtunnel-smart-watchdog.timer >/dev/null 2>&1 || true
    for gd in "$GROUP_DIR"/*; do
        [ -d "$gd" ] || continue
        gid=$(basename "$gd")
        flock -x -w 30 -o "$gd/.smart.lock" "$INSTALL_PATH" --delete-group "$gid" >/dev/null 2>&1 || failed=1
    done
    for gd in "$GROUP_DIR"/*; do [ -d "$gd" ] && { left=1; break; }; done
    if [ "$left" -eq 0 ]; then
        rm -f "$WATCH_SERVICE" "$WATCH_TIMER"
        mkdir -p "$GROUP_DIR"; chmod 700 "$GROUP_DIR" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if [ "$failed" -ne 0 ]; then
        echo 'Warning: some Smart group state was retained because cleanup failed on Iran or Foreign. Re-run delete after connectivity is restored.' >&2
        return 1
    fi
    return 0
}
case "${1:-}" in
    --benchmark-group) [[ "${2:-}" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || exit 2; smart_benchmark_group_locked "$GROUP_DIR/$2"; exit $?;;
    --watchdog-group) smart_peer_load || exit 0; smart_watchdog_group_locked "${2:-}"; exit $?;;
    --delete-tunnel) smart_delete_tunnel_locked "${2:-}" "${3:-}"; exit $?;;
    --delete-group) smart_delete_group_locked "${2:-}"; exit $?;;
    --delete-groups) smart_delete_groups; exit $?;;
    --pair-window-cleanup) smart_pair_window_cleanup; exit $?;;
    --agent-daemon) smart_agent_daemon; exit $?;;
    --watchdog-once) smart_watchdog_once; exit $?;;
    --version|-V) echo "MTunnel Smart $MODULE_VERSION build $MODULE_BUILD"; exit 0;;
    --pair-decode) smart_pair_decode "${2:-}" && printf 'IPv6=%s\nPort=%s\nFingerprint=%s\nExpires=%s\n' "$PAIR_IP6" "$PAIR_PORT" "$PAIR_FP" "$PAIR_EXPIRES"; exit $?;;
    --help|-h) echo 'Usage: msmart [--version|--agent-daemon|--watchdog-once|--benchmark-group GID|--delete-tunnel GID ID|--delete-groups|--pair-window-cleanup]'; exit 0;;
esac
smart_menu
