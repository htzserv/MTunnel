#!/bin/bash
# MTunnel Smart — paired Iran controller / Foreign agent, multi-tunnel benchmark and failover (v1.5.5).
MODULE_VERSION="1.5.5"
MODULE_BUILD="2026102806"
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
FOREIGN_GROUP_DIR="$SMART_DIR/foreign-groups"
AGENT_PORT=29876
IPERF_PORT=5201
AGENT_SERVICE=/etc/systemd/system/mtunnel-smart-agent.service
WATCH_SERVICE=/etc/systemd/system/mtunnel-smart-watchdog.service
WATCH_TIMER=/etc/systemd/system/mtunnel-smart-watchdog.timer
SECURE_TMP=/root/mtunnel/tmp
INSTALL_PATH=/usr/bin/msmart
UPDATE_CHECK_INTERVAL=600
# Find the unpacked/local MTunnel bundle so Smart can use its bundled engines/ and prereqs/ first.
SMART_LOCAL_ROOT=""
SMART_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || true)
for _smart_root in "$SMART_SCRIPT_DIR/.." /root/mtunnel; do
    [ -n "$_smart_root" ] || continue
    if [ -s "$_smart_root/prereqs/manifest.txt" ] || compgen -G "$_smart_root/prereqs/*.deb" >/dev/null || \
       [ -s "$_smart_root/engines/manifest.txt" ] || compgen -G "$_smart_root/engines/*" >/dev/null; then
        SMART_LOCAL_ROOT=$(cd -- "$_smart_root" && pwd -P 2>/dev/null || true)
        [ -n "$SMART_LOCAL_ROOT" ] && break
    fi
done
unset _smart_root SMART_SCRIPT_DIR
mkdir -p "$SMART_DIR" "$GROUP_DIR" "$FOREIGN_GROUP_DIR" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SMART_DIR" "$GROUP_DIR" "$FOREIGN_GROUP_DIR" "$SECURE_TMP" 2>/dev/null

SMART_UPD_GH="$SECURE_TMP/.msmart_update_github"
SMART_UPD_MIR="$SECURE_TMP/.msmart_update_mirror"
SMART_UPD_LOCK="$SECURE_TMP/.msmart_update.lock"
SMART_UPD_REFRESH_AGE=90

smart_set_conf_var() {
    local file="$1" key="$2" val="$3"
    [ -f "$file" ] || return 1
    ( umask 077; grep -v "^${key}=" "$file" > "${file}.tmp" 2>/dev/null || true; printf '%s=%s\n' "$key" "$val" >> "${file}.tmp" ) || return 1
    mv -f "${file}.tmp" "$file" && chmod 600 "$file" 2>/dev/null
}

smart_pick_index() {
    local in="$1" cnt="$2"
    [[ "$in" =~ ^[0-9]+$ ]] && [ "$in" -ge 1 ] && [ "$in" -le "$cnt" ] || return 1
    echo $((in - 1))
}

# Display name of a group (GROUP_NAME from group.conf, falls back to the directory id).
smart_group_label() { # groupdir
    local n
    n=$(sed -n 's/^GROUP_NAME=//p' "$1/group.conf" 2>/dev/null | head -n1)
    printf '%s' "${n:-$(basename "$1")}"
}

# Short tunnel name for display: "VXLAN IPv4 + 5 vIPs" -> "VXLAN 4-4", "Rathole IPv6" -> "Rathole 6".
smart_short_label() {
    local l="${1/ + 5 vIPs/}"
    case "$l" in
        mGRE\ IPv4|VXLAN\ IPv4) l="${l% IPv4} 4-4";;
        mGRE\ IPv6|VXLAN\ IPv6) l="${l% IPv6} 6-6";;
        *\ IPv4) l="${l% IPv4} 4";;
        *\ IPv6) l="${l% IPv6} 6";;
    esac
    printf '%s' "$l"
}

# Ask the operator for a unique group name. Sets SMART_GROUP_NAME.
smart_prompt_group_name() {
    local n gd existing dup
    while true; do
        echo -ne "\n  ${C}●${NC} ${W}Group name [A-Z a-z 0-9 _ . - | max 24 | Enter = auto]: ${NC}"; read -r n
        n="${n//$'\r'/}"; n="${n// /}"
        [ -n "$n" ] || n="Group-$(date +%H%M%S)"
        [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,23}$ ]] || { echo -e "  ${R}✖ Invalid name (letters, digits, _ . - only; max 24).${NC}"; continue; }
        dup=0
        for gd in "$GROUP_DIR"/*; do
            [ -d "$gd" ] || continue
            existing=$(sed -n 's/^GROUP_NAME=//p' "$gd/group.conf" 2>/dev/null | head -n1)
            [ "${existing,,}" != "${n,,}" ] || dup=1
        done
        [ "$dup" -eq 0 ] || { echo -e "  ${R}✖ A group with this name already exists.${NC}"; continue; }
        SMART_GROUP_NAME="$n"; return 0
    done
}

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
    local gd groups=0 tunnels=0 paired='UNPAIRED' pair_col="$Y" agent='OFF' agent_col="$DIM"
    local watchdog='OFF' watchdog_col="$DIM" ports=0 peer4='---' active='' label='' score='' svc count=0 tcnt=0
    local primary_gid='' primary_label='' primary_score='' primary_state=0
    local row_count=0 r_gid r_label r_score r_state r_ping r_loss r_id f_ping f_loss
    MT_HDR_ROWS=''
    if [ -s "$SMART_DIR/peer.conf" ]; then
        paired='PAIRED'; pair_col="$G"
        peer4=$(mt_link_read "$SMART_DIR/peer.conf" FOREIGN_IPV4 2>/dev/null || true)
        [ -n "$peer4" ] || peer4='---'
    elif [ -s "$SMART_DIR/controller.ipv4" ]; then
        # Foreign side: the Agent pinned its controller (Iran) after a successful pairing.
        paired='PAIRED'; pair_col="$G"
        peer4=$(head -n1 "$SMART_DIR/controller.ipv4" 2>/dev/null || true)
        [ -n "$peer4" ] || peer4='---'
    fi
    if systemctl is-active --quiet mtunnel-smart-agent.service 2>/dev/null; then agent='ON'; agent_col="$G"; fi
    if systemctl is-active --quiet mtunnel-smart-watchdog.timer 2>/dev/null; then watchdog='ON'; watchdog_col="$G"; fi
    # Iran: real groups live in $GROUP_DIR. Foreign: the Iran controller mirrors group state into $FOREIGN_GROUP_DIR.
    for gd in "$GROUP_DIR"/* "$FOREIGN_GROUP_DIR"/*; do
        [ -d "$gd" ] || continue
        groups=$((groups+1))
        if [ -s "$gd/candidates.tsv" ]; then
            tcnt=$(wc -l < "$gd/candidates.tsv" 2>/dev/null || echo 0)
            [[ "$tcnt" =~ ^[0-9]+$ ]] && tunnels=$((tunnels+tcnt))
        fi
        svc=$(mt_link_read "$gd/group.conf" SERVICE_PORTS 2>/dev/null || true)
        if [ -n "$svc" ]; then
            count=$(awk -F, '{print NF}' <<< "$svc" 2>/dev/null || echo 0)
            [[ "$count" =~ ^[0-9]+$ ]] && ports=$((ports+count))
        fi
        active=$(cat "$gd/active.state" 2>/dev/null || true)
        label=''; score=''; r_id=''; f_ping=''; f_loss=''
        IFS='|' read -r r_id label score f_ping f_loss <<< "$active" || true
        r_gid=$(smart_group_label "$gd"); r_label="${label:-OFF}"; r_label="$(smart_short_label "$r_label")"; r_score="${score:-DOWN}"
        r_state=0; [ -n "$label" ] && r_state=1
        r_ping='---'; r_loss='---'
        if [ -n "$r_id" ] && [ -s "$gd/ranking.tsv" ]; then
            IFS='|' read -r r_ping r_loss <<< "$(awk -F'|' -v i="$r_id" '$1==i{print $11"ms|"$12;exit}' "$gd/ranking.tsv" 2>/dev/null)"
            [ -n "$r_ping" ] || r_ping='---'
            [ -n "$r_loss" ] || r_loss='---'
        elif [ -n "$f_ping" ]; then
            r_ping="${f_ping}ms"; r_loss="${f_loss:----}"
        fi
        if [ "$row_count" -lt 3 ]; then
            row_count=$((row_count+1))
            MT_HDR_ROWS+="${r_state}|${r_gid:0:14}|SMART|${peer4}|${r_label:0:12}|${r_ping}|${r_loss}|${r_score}|T:${svc:0:9}"$'\n'
        fi
        if [ -z "$primary_gid" ] || { [ "$primary_state" -eq 0 ] && [ -n "$label" ]; }; then
            primary_gid="$r_gid"; primary_label="$r_label"; primary_score="$r_score"
            primary_state="$r_state"
        fi
    done
    SMART_HDR_GROUPS="$groups"; SMART_HDR_TUNNELS="$tunnels"; SMART_HDR_ACTIVE="${primary_label:-OFF}"
    SMART_HDR_PAIRED="$paired"; SMART_HDR_PAIR_COL="$pair_col"
    SMART_HDR_AGENT="$agent"; SMART_HDR_AGENT_COL="$agent_col"; SMART_HDR_WATCHDOG="$watchdog"; SMART_HDR_WATCHDOG_COL="$watchdog_col"
    SMART_HDR_PORTS="$ports"
}

smart_header() {
    smart_header_state
    MT_HDR_EMPTY_TEXT="No Smart groups are configured on this host."
    local group_col="$DIM"; [ "$SMART_HDR_GROUPS" -gt 0 ] 2>/dev/null && group_col="$G"
    local tun_col="$DIM"; [ "$SMART_HDR_TUNNELS" -gt 0 ] 2>/dev/null && tun_col="$C"
    mt_hdr_draw "MSmart Core v${MODULE_VERSION}" \
        "Groups|${SMART_HDR_GROUPS}|${group_col}" \
        "Tunnels|${SMART_HDR_TUNNELS}|${tun_col}" \
        "Active|${SMART_HDR_ACTIVE:-OFF}|$([ "${SMART_HDR_ACTIVE:-OFF}" != OFF ] && printf '%s' "$G" || printf '%s' "$DIM")" \
        "Pair|${SMART_HDR_PAIRED}|${SMART_HDR_PAIR_COL}" \
        "Ports|${SMART_HDR_PORTS}|${Y}"
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
smart_update_source_plain() { # state-file label -> plain text, no ANSI escapes
    local file="$1" label="$2" st rv rb ts suffix
    [ -s "$file" ] || { printf '%s: checking...' "$label"; return; }
    IFS='|' read -r st rv rb ts < "$file"
    if [ "$st" != ok ]; then printf '%s: unavailable' "$label"; return; fi
    if smart_meta_newer "$rv" "${rb:-0}"; then
        suffix="v${MODULE_VERSION}"
        [ "${MODULE_BUILD:-0}" -gt 0 ] 2>/dev/null && suffix+=" b${MODULE_BUILD}"
        suffix+=" -> v${rv}"
        [ "${rb:-0}" -gt 0 ] 2>/dev/null && suffix+=" b${rb}"
        printf '%s: %s • UPDATE AVAILABLE' "$label" "$suffix"
    else
        suffix="v${rv}"
        [ "${rb:-0}" -gt 0 ] 2>/dev/null && suffix+=" b${rb}"
        printf '%s: %s • current' "$label" "$suffix"
    fi
}

smart_update_source_color() { # state-file
    local file="$1" st rv rb ts
    [ -s "$file" ] || { printf '%s' "$DIM"; return; }
    IFS='|' read -r st rv rb ts < "$file"
    [ "$st" = ok ] || { printf '%s' "$R"; return; }
    if smart_meta_newer "$rv" "${rb:-0}"; then printf '%s' "$Y"; else printf '%s' "$G"; fi
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
    local opt gh_txt mi_txt gh_col mi_col
    smart_update_refresh_now
    while true; do
        smart_header
        gh_txt=$(smart_update_source_plain "$SMART_UPD_GH" GitHub)
        mi_txt=$(smart_update_source_plain "$SMART_UPD_MIR" Mirror)
        gh_col=$(smart_update_source_color "$SMART_UPD_GH")
        mi_col=$(smart_update_source_color "$SMART_UPD_MIR")

        echo -e "\n  ${FR}┌─[ UPDATE & LOCAL INSTALL ]${NC}"
        echo -e "  ${FR}│${NC} ${DIM}Local:${NC} ${W}v${MODULE_VERSION}${NC} ${DIM}• build ${MODULE_BUILD}${NC}"
        echo -e "  ${FR}│${NC} ${gh_col}${gh_txt}${NC}"
        echo -e "  ${FR}│${NC} ${mi_col}${mi_txt}${NC}"
        echo -e "  ${FR}│${NC}"
        echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Update MSmart from GitHub${NC}"
        echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Update MSmart from Mirror${NC}"
        echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Install MSmart from Direct Link${NC}"
        echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Paste MSmart Code Manually${NC}"
        echo -e "  ${FR}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${W}Install Local msmart.sh${NC}"
        echo -e "  ${FR}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${C}Refresh Update Status${NC}"
        echo -e "  ${FR}│${NC}"
        echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Smart Menu${NC}"
        echo -ne "\n  ${C}MSMART UPDATE ❯❯ ${NC}"; read -r opt
        opt="${opt// /}"; opt="${opt//$'\\r'/}"
        case "$opt" in
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

# Mirror the state of one group (name, ports, tunnels, active tunnel) to the Foreign agent so
# the Foreign header can show it. Best-effort: failures never break the caller.
smart_sync_foreign_state() { # groupdir [delete]
    local gd="$1" mode="${2:-}" gid body
    gid=$(basename "$gd"); [[ "$gid" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 0
    smart_peer_load || return 0
    body=$(GD="$gd" GID="$gid" MODE="$mode" python3 - <<'PY'
import json,os
gd=os.environ['GD']; gid=os.environ['GID']
d={'action':'group_state','gid':gid}
if os.environ.get('MODE')=='delete':
    d['delete']=True
else:
    conf={}
    try:
        for l in open(gd+'/group.conf'):
            if '=' in l:
                k,v=l.rstrip('\n').split('=',1); conf[k]=v
    except OSError: pass
    d['name']=conf.get('GROUP_NAME') or gid
    d['ports']=conf.get('SERVICE_PORTS','')
    rn={}
    try:
        for l in open(gd+'/names.tsv'):
            f=l.rstrip('\n').split('|')
            if len(f)>=4: rn[f[0]]=f[3]
    except OSError: pass
    t=[]
    try:
        for l in open(gd+'/candidates.tsv'):
            f=l.rstrip('\n').split('|')
            if len(f)>=10: t.append({'id':f[0],'label':f[1],'kind':f[2],'name':rn.get(f[0],f[5]),'status':f[9]})
    except OSError: pass
    d['tunnels']=t
    a={}
    try:
        f=open(gd+'/active.state').read().strip().split('|')
        if len(f)>=2 and f[1]:
            a={'id':f[0],'label':f[1],'score':f[2] if len(f)>2 else ''}
            try:
                for l in open(gd+'/ranking.tsv'):
                    r=l.rstrip('\n').split('|')
                    if len(r)>=12 and r[0]==f[0]:
                        a['ping']=r[10]; a['loss']=r[11]; break
            except OSError: pass
    except OSError: pass
    d['active']=a
print(json.dumps(d,separators=(',',':')))
PY
)
    [ -n "$body" ] || return 0
    smart_agent_call "$body" 8 >/dev/null 2>&1 || true
}
# Same as above but at most once per 60s per group (used by the 10s watchdog; also back-fills old groups).
smart_sync_foreign_throttled() { # groupdir
    local gd="$1" f="$1/.foreign.sync" now last=0
    now=$(date +%s)
    [ -s "$f" ] && last=$(cat "$f" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    [ $((now-last)) -ge 60 ] || return 0
    printf '%s\n' "$now" > "$f"; chmod 600 "$f" 2>/dev/null || true
    smart_sync_foreign_state "$gd"
}
SMART_DEP_SOURCE=""

smart_dependency_source_menu() {
    local choice
    SMART_DEP_SOURCE=""
    smart_header
    echo -e "\n  ${FR}┌─[ SMART PREREQUISITE SOURCE ]${NC}"
    echo -e "  ${FR}│${NC} ${DIM}Only Smart-required engines and prerequisite packages are installed.${NC}"
    echo -e "  ${FR}│${NC} ${DIM}Local files are tried first when available; otherwise use a remote source.${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Local MTunnel Bundle${NC} ${DIM}(engines/ + prereqs/, if present)${NC}"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}MTunnel GitHub${NC} ${DIM}(engines/ + prereqs/)${NC}"
    echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}MTunnel Mirror${NC} ${DIM}(engines/ + prereqs/)${NC}"
    echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Official Sources${NC} ${DIM}(engine releases + OS packages)${NC}"
    echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} Back"
    while true; do
        echo -ne "  ${C}Prerequisite Source ❯❯ ${NC}"; read -r choice || return 1
        choice="${choice//$'\r'/}"
        case "$choice" in
            1) SMART_DEP_SOURCE=local; break;;
            2) SMART_DEP_SOURCE=mtunnel; break;;
            3) SMART_DEP_SOURCE=mirror; break;;
            4) SMART_DEP_SOURCE=official; break;;
            0|q|Q|'') return 1;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}";;
        esac
    done
    export SMART_DEP_SOURCE
}

# The MTunnel Backhaul modules write configs for Backhaul v0.7.2. A different major version (for example
# v2.x) starts but rejects those configs ("neither server nor client configuration is properly set").
SMART_BH_EXPECT="0.7.2"
smart_bh_bin() { local b; for b in /usr/local/bin/bh /usr/bin/bh; do [ -x "$b" ] && { printf '%s' "$b"; return 0; }; done; return 1; }
smart_bh_version() { # prints x.y.z reported by "bh -v"; empty when it cannot be determined
    local b out
    b=$(smart_bh_bin) || return 0
    out=$(timeout 3 "$b" -v 2>&1 </dev/null | head -n 3) || true
    [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
}
# Installed AND not a known-wrong version (an undeterminable version is not blocked).
smart_core_installed_backhaul() { local v; smart_bh_bin >/dev/null || return 1; v=$(smart_bh_version); [ -z "$v" ] || [ "$v" = "$SMART_BH_EXPECT" ]; }
smart_core_installed_rathole() { [ -x /usr/local/bin/rathole ] || [ -x /usr/bin/rathole ]; }

smart_modules_missing() {
    local n
    for n in mgre mxlan mbackhaul mrathole; do
        command -v "$n" >/dev/null 2>&1 || printf '%s\n' "$n"
    done
}

smart_runtime_missing() {
    local miss=() n
    for n in python3 openssl iperf3 ping iptables ip ss flock gzip base64 sha256sum; do
        command -v "$n" >/dev/null 2>&1 || miss+=("$n")
    done
    { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; } || miss+=(curl-or-wget)
    if ! smart_core_installed_backhaul; then
        if smart_bh_bin >/dev/null; then miss+=("backhaul-core(need-${SMART_BH_EXPECT},found-$(smart_bh_version))"); else miss+=("backhaul-core"); fi
    fi
    smart_core_installed_rathole || miss+=("rathole-core")
    printf '%s\n' "${miss[@]}"
}

smart_prereqs_ready() {
    [ -z "$(smart_modules_missing)" ] && [ -z "$(smart_runtime_missing)" ]
}

smart_repo_base() {
    case "$1" in
        local) [ -n "$SMART_LOCAL_ROOT" ] || return 1; printf '%s\n' "$SMART_LOCAL_ROOT";;
        mtunnel) printf '%s\n' "$MTUNNEL_GITHUB_BASE";;
        mirror) printf '%s\n' "$MTUNNEL_MIRROR_BASE";;
        *) return 1;;
    esac
}

smart_sha256_file() { # file -> SHA-256 using any available local implementation
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$file" <<'PYHASH'
import hashlib, sys
h=hashlib.sha256()
with open(sys.argv[1], 'rb') as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b''):
        h.update(chunk)
print(h.hexdigest())
PYHASH
    else
        return 1
    fi
}

smart_repo_manifest() { # base sub out
    local base="$1" sub="$2" out="$3" tmp line hash name n=0 file source_manifest
    tmp=$(mktemp "$SECURE_TMP/.smart-manifest.XXXXXX") || return 1
    if [ -d "$base" ]; then
        # The main installer caches package files under /root/mtunnel but may not cache
        # manifest.txt. Use the bundled manifest when present; otherwise hash the local files.
        source_manifest="$base/$sub/manifest.txt"
        if [ -r "$source_manifest" ]; then
            cp -f -- "$source_manifest" "$tmp" || { rm -f "$tmp"; return 1; }
        else
            : > "$tmp"
            for file in "$base/$sub"/*; do
                [ -f "$file" ] || continue
                name="${file##*/}"
                [ "$name" != manifest.txt ] || continue
                [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]] || continue
                case "$sub" in
                    engines) [[ "$name" != *.deb ]] || continue;;
                    prereqs) [[ "$name" == *.deb ]] || continue;;
                    *) continue;;
                esac
                hash=$(smart_sha256_file "$file" 2>/dev/null || true)
                if [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
                    printf '%s  %s\n' "$hash" "$name" >> "$tmp"
                else
                    # Local cache bootstrap can precede installation of coreutils/openssl/python3.
                    printf '%s\n' "$name" >> "$tmp"
                fi
            done
        fi
    else
        mt_download "$(mt_cb_url "${base%/}/${sub}/manifest.txt")" "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
    fi
    : > "$out"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*($|#) ]] && continue
        if [[ "$line" =~ ^([0-9a-fA-F]{64})[[:space:]]+\*?([^[:space:]]+)[[:space:]]*$ ]]; then
            hash="${BASH_REMATCH[1],,}"; name="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
            hash='-'; name="${BASH_REMATCH[1]}"
        else
            continue
        fi
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]] || continue
        case "$sub" in
            engines) [[ "$name" != *.deb ]] || continue;;
            prereqs) [[ "$name" == *.deb ]] || continue;;
            *) continue;;
        esac
        printf '%s|%s\n' "$hash" "$name" >> "$out"; n=$((n+1))
    done < "$tmp"
    rm -f "$tmp"
    [ "$n" -gt 0 ]
}

smart_repo_manifest_name() { # manifest regex
    local mf="$1" re="$2"
    awk -F'|' -v r="$re" '$2 ~ r {print $2}' "$mf" 2>/dev/null | sort -V | tail -n1
}

smart_prereq_manifest_name() { # manifest package-prefix architecture; only select known Ubuntu release builds
    local mf="$1" prefix="$2" arch="$3" os_id os_version name candidate=""
    os_id=$(awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null)
    os_version=$(awk -F= '$1=="VERSION_ID" {gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null)
    [ "$os_id" = ubuntu ] || return 1
    while IFS='|' read -r _ name; do
        [[ "$name" =~ ^${prefix}_.*_(${arch}|all)\.deb$ ]] || continue
        case "$os_version:$prefix" in
            24.04:python3) continue;;
            24.04:openssl) [[ "$name" == openssl_3.0.* ]] || continue;;
            24.04:iperf3) [[ "$name" == iperf3_3.16-* ]] || continue;;
            24.04:libiperf0) [[ "$name" == libiperf0_3.16-* ]] || continue;;
            24.04:iputils-ping) [[ "$name" == iputils-ping_33a20240117-* ]] || continue;;
            24.04:iptables) [[ "$name" == iptables_1.8.10-* ]] || continue;;
            24.04:iproute2) [[ "$name" == iproute2_6.1.* ]] || continue;;
            24.04:util-linux) [[ "$name" == util-linux_2.39.* ]] || continue;;
            24.04:gzip) [[ "$name" == gzip_1.12-* ]] || continue;;
            24.04:curl) [[ "$name" == curl_8.5.* ]] || continue;;
            26.04:python3) [[ "$name" == python3_3.14* ]] || continue;;
            26.04:openssl) [[ "$name" == openssl_3.5.* ]] || continue;;
            26.04:iperf3) [[ "$name" == iperf3_3.20-* ]] || continue;;
            26.04:libiperf0) [[ "$name" == libiperf0_3.20-* ]] || continue;;
            26.04:iputils-ping) [[ "$name" == iputils-ping_33a20250605-* ]] || continue;;
            26.04:iptables) [[ "$name" == iptables_1.8.11-* ]] || continue;;
            26.04:iproute2) [[ "$name" == iproute2_6.19.* ]] || continue;;
            26.04:util-linux) [[ "$name" == util-linux_2.41.* ]] || continue;;
            26.04:gzip) [[ "$name" == gzip_1.14-* ]] || continue;;
            26.04:curl) [[ "$name" == curl_8.18.* ]] || continue;;
            *) continue;;
        esac
        candidate="$name"
    done < <(sort -t'|' -k2,2V "$mf" 2>/dev/null)
    [ -n "$candidate" ] || return 1
    printf '%s' "$candidate"
}

smart_repo_download_item() { # base sub name manifest dest
    local base="$1" sub="$2" name="$3" mf="$4" dest="$5" hash got
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]] || return 1
    hash=$(awk -F'|' -v n="$name" '$2==n{print $1;exit}' "$mf")
    [ -n "$hash" ] || return 1
    if [ -d "$base" ]; then
        [ -s "$base/$sub/$name" ] && cp -f -- "$base/$sub/$name" "$dest" || return 1
    else
        mt_download "$(mt_cb_url "${base%/}/${sub}/$name")" "$dest" || return 1
    fi
    if [ "$hash" != '-' ]; then
        got=$(smart_sha256_file "$dest" 2>/dev/null || true)
        if [ -z "$got" ] && [ -d "$base" ]; then
            echo "Warning: no local SHA-256 utility; trusting the local bundle copy for $name." >&2
        elif [ "$got" != "$hash" ]; then
            rm -f "$dest"; echo "Checksum mismatch or unavailable SHA-256 verifier: $name" >&2; return 1
        fi
    fi
    return 0
}

smart_engine_assets() { # echoes backhaul_asset|rathole_asset
    local bh rh
    case "$(uname -m)" in
        x86_64) bh='backhaul_linux_amd64.tar.gz'; rh='rathole-x86_64-unknown-linux-gnu.zip';;
        aarch64|arm64) bh='backhaul_linux_arm64.tar.gz'; rh='rathole-aarch64-unknown-linux-musl.zip';;
        *) return 1;;
    esac
    printf '%s|%s\n' "$bh" "$rh"
}

smart_install_engines_from_repo() { # local|mtunnel|mirror
    local src="$1" base mf stage assets bh_asset rh_asset bh_name rh_name rc=0
    base=$(smart_repo_base "$src") || return 1
    mf=$(mktemp "$SECURE_TMP/.smart-engines-mf.XXXXXX") || return 1
    smart_repo_manifest "$base" engines "$mf" || { rm -f "$mf"; echo -e "  ${R}✖ engines/manifest.txt is missing or invalid at the selected source.${NC}"; return 1; }
    assets=$(smart_engine_assets) || { rm -f "$mf"; echo -e "  ${R}✖ Unsupported CPU architecture.${NC}"; return 1; }
    IFS='|' read -r bh_asset rh_asset <<< "$assets"
    stage=$(mktemp -d "$SECURE_TMP/smart-engines.XXXXXX") || { rm -f "$mf"; return 1; }

    if ! smart_core_installed_backhaul; then
        bh_name=$(smart_repo_manifest_name "$mf" "^${bh_asset}$")
        if [ -z "$bh_name" ] && [ "$(uname -m)" = x86_64 ]; then bh_name=$(smart_repo_manifest_name "$mf" '^bh$'); fi
        if [ -z "$bh_name" ]; then
            echo -e "  ${R}✖ Required Backhaul engine is not present in engines/.${NC}"; rc=1
        else
            echo -e "  ${C}⟳${NC} ${W}Backhaul:${NC} engines/${bh_name}"
            if smart_repo_download_item "$base" engines "$bh_name" "$mf" "$stage/$bh_name" && mt_update_core bh mbackhaul "$stage/$bh_name" local; then
                if smart_core_installed_backhaul; then
                    echo -e "  ${G}✔ Backhaul Core ready (v$(smart_bh_version)).${NC}"
                else
                    echo -e "  ${R}✖ Installed bh is v$(smart_bh_version) but v${SMART_BH_EXPECT} is required: engines/${bh_name} at this source is the wrong version. Fix that file or use Official Sources.${NC}"; rc=1
                fi
            else
                echo -e "  ${R}✖ Backhaul Core install failed.${NC}"; rc=1
            fi
        fi
    else
        echo -e "  ${G}✔ Backhaul Core already installed.${NC}"
    fi

    if ! smart_core_installed_rathole; then
        rh_name=$(smart_repo_manifest_name "$mf" "^${rh_asset}$")
        if [ -z "$rh_name" ] && [ "$(uname -m)" = x86_64 ]; then rh_name=$(smart_repo_manifest_name "$mf" '^rathole$'); fi
        if [ -z "$rh_name" ]; then
            echo -e "  ${R}✖ Required Rathole engine is not present in engines/.${NC}"; rc=1
        else
            echo -e "  ${C}⟳${NC} ${W}Rathole:${NC} engines/${rh_name}"
            if smart_repo_download_item "$base" engines "$rh_name" "$mf" "$stage/$rh_name" && mt_update_core rathole mrathole "$stage/$rh_name" local; then
                echo -e "  ${G}✔ Rathole Core ready.${NC}"
            else
                echo -e "  ${R}✖ Rathole Core install failed.${NC}"; rc=1
            fi
        fi
    else
        echo -e "  ${G}✔ Rathole Core already installed.${NC}"
    fi
    rm -rf "$stage"; rm -f "$mf"
    return "$rc"
}

smart_missing_package_prefixes() {
    local out=()
    command -v python3 >/dev/null 2>&1 || out+=(python3)
    command -v openssl >/dev/null 2>&1 || out+=(openssl)
    if ! command -v iperf3 >/dev/null 2>&1; then out+=(libiperf0 iperf3); fi
    command -v ping >/dev/null 2>&1 || out+=(iputils-ping)
    command -v iptables >/dev/null 2>&1 || out+=(iptables)
    { command -v ip >/dev/null 2>&1 && command -v ss >/dev/null 2>&1; } || out+=(iproute2)
    command -v flock >/dev/null 2>&1 || out+=(util-linux)
    command -v gzip >/dev/null 2>&1 || out+=(gzip)
    { command -v base64 >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; } || out+=(coreutils)
    { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; } || out+=(curl)
    # An empty array must print nothing: printf with no arguments still emits one empty line,
    # which made callers see a single empty package name.
    [ "${#out[@]}" -eq 0 ] || printf '%s\n' "${out[@]}"
}

smart_install_prereq_debs_from_repo() { # local|mtunnel|mirror
    local src="$1" base mf stage arch prefix name pkg_arch rc=0
    local -a prefixes=() debs=()
    mapfile -t prefixes < <(smart_missing_package_prefixes)
    [ ${#prefixes[@]} -gt 0 ] || { echo -e "  ${G}✔ System prerequisites already installed.${NC}"; return 0; }
    command -v dpkg >/dev/null 2>&1 && command -v dpkg-deb >/dev/null 2>&1 || { echo -e "  ${R}✖ dpkg/dpkg-deb is required to install prereqs/*.deb.${NC}"; return 1; }
    base=$(smart_repo_base "$src") || return 1
    mf=$(mktemp "$SECURE_TMP/.smart-prereqs-mf.XXXXXX") || return 1
    smart_repo_manifest "$base" prereqs "$mf" || { rm -f "$mf"; echo -e "  ${R}✖ prereqs/manifest.txt is missing or invalid at the selected source.${NC}"; return 1; }
    stage=$(mktemp -d "$SECURE_TMP/smart-prereqs.XXXXXX") || { rm -f "$mf"; return 1; }
    arch=$(dpkg --print-architecture 2>/dev/null || true)
    [ -n "$arch" ] || arch=amd64
    for prefix in "${prefixes[@]}"; do
        name=$(smart_prereq_manifest_name "$mf" "$prefix" "$arch")
        if [ -z "$name" ]; then
            echo -e "  ${Y}⚠ No bundled package matching this Ubuntu release for ${prefix}; will need Official Sources.${NC}"; rc=1; continue
        fi
        echo -e "  ${C}⟳${NC} ${W}${prefix}:${NC} prereqs/${name}"
        if smart_repo_download_item "$base" prereqs "$name" "$mf" "$stage/$name" && dpkg-deb --info "$stage/$name" >/dev/null 2>&1; then
            pkg_arch=$(dpkg-deb -f "$stage/$name" Architecture 2>/dev/null || true)
            if [ "$pkg_arch" = "$arch" ] || [ "$pkg_arch" = all ]; then
                debs+=("$stage/$name")
            else
                echo -e "  ${R}✖ Wrong package architecture in ${name}: ${pkg_arch:-unknown} (server: ${arch}).${NC}"; rc=1
            fi
        else
            echo -e "  ${R}✖ Invalid or failed prerequisite: ${name}${NC}"; rc=1
        fi
    done
    if [ ${#debs[@]} -gt 0 ]; then
        echo -e "  ${Y}● Installing selected prerequisite packages...${NC}"
        if ! DEBIAN_FRONTEND=noninteractive dpkg -i --force-confdef --force-confold "${debs[@]}" >/dev/null 2>&1; then
            rc=1
            if command -v apt-get >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -f -y -qq >/dev/null 2>&1 || true
            fi
        fi
    fi
    rm -rf "$stage"; rm -f "$mf"
    return "$rc"
}

smart_install_official_prereqs() {
    local missing=() assets bh_asset rh_asset tmp rc=0
    mapfile -t missing < <(smart_missing_package_prefixes)
    if [ ${#missing[@]} -gt 0 ]; then
        command -v apt-get >/dev/null 2>&1 || { echo -e "  ${R}✖ apt-get is unavailable for Official Sources.${NC}"; return 1; }
        local -a pkgs=(); local p
        for p in "${missing[@]}"; do
            case "$p" in libiperf0) pkgs+=(libiperf0);; *) pkgs+=("$p");; esac
        done
        echo -e "  ${Y}● Installing OS prerequisites from the distribution repositories...${NC}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1 || rc=1
    fi
    assets=$(smart_engine_assets) || return 1; IFS='|' read -r bh_asset rh_asset <<< "$assets"
    if ! smart_core_installed_backhaul; then
        tmp=$(mktemp "$SECURE_TMP/backhaul.XXXXXX") || return 1
        echo -e "  ${C}⟳${NC} ${W}Backhaul:${NC} official GitHub release"
        if mt_download "https://github.com/Musixal/Backhaul/releases/download/v0.7.2/$bh_asset" "$tmp" && mt_update_core bh mbackhaul "$tmp" local; then
            smart_core_installed_backhaul || { echo -e "  ${R}✖ Installed bh is v$(smart_bh_version), expected v${SMART_BH_EXPECT}.${NC}"; rc=1; }
        else rc=1; fi
        rm -f "$tmp"
    fi
    if ! smart_core_installed_rathole; then
        tmp=$(mktemp "$SECURE_TMP/rathole.XXXXXX") || return 1
        echo -e "  ${C}⟳${NC} ${W}Rathole:${NC} official GitHub release"
        if mt_download "https://github.com/rathole-org/rathole/releases/download/v0.5.0/$rh_asset" "$tmp" && mt_update_core rathole mrathole "$tmp" local; then :; else rc=1; fi
        rm -f "$tmp"
    fi
    return "$rc"
}

smart_install_smart_prerequisites() { # local|mtunnel|mirror|official
    local src="$1" mods rc=0
    mods=$(smart_modules_missing | paste -sd ', ' -)
    if [ -n "$mods" ]; then
        echo -e "  ${R}✖ Required tunnel modules are missing: ${W}$mods${NC}"
        echo -e "  ${DIM}Prerequisites does not download scripts. Install/update the MTunnel script bundle first.${NC}"
        return 1
    fi
    case "$src" in
        local|mtunnel|mirror)
            smart_install_prereq_debs_from_repo "$src" || rc=1
            smart_install_engines_from_repo "$src" || rc=1
            ;;
        official)
            smart_install_official_prereqs || rc=1
            ;;
        *) return 2;;
    esac
    if smart_prereqs_ready; then
        echo -e "\n  ${G}✓ Smart prerequisites are ready.${NC}"
        return 0
    fi
    echo -e "\n  ${R}✖ Some Smart requirements are still missing:${NC}"
    smart_runtime_missing | sed 's/^/    - /'
    return 1
}

smart_ensure_agent_dependencies() {
    smart_prereqs_ready && return 0
    echo -e "  ${R}✖ Smart prerequisites are incomplete. Open option 1: Install Prerequisites.${NC}"
    return 1
}

smart_ensure_controller_dependencies() {
    smart_prereqs_ready && return 0
    echo -e "  ${R}✖ Smart prerequisites are incomplete. Open option 1: Install Prerequisites.${NC}"
    return 1
}

# When the user opens Smart from the main menu, automatically prepare missing requirements.
# Prefer the local bundle/cache first, then remote MTunnel sources, and finally distro APT.
smart_auto_prepare_dependencies() {
    local src mods
    smart_prereqs_ready && return 0
    echo -e "\n  ${Y}● Smart requirements are missing; preparing them automatically...${NC}"
    mods=$(smart_modules_missing | paste -sd ', ' -)
    if [ -n "$mods" ]; then
        echo -e "  ${R}✖ Required tunnel modules are missing: ${W}$mods${NC}"
        echo -e "  ${DIM}Install/sync the complete MTunnel script bundle first. The Smart menu will still open.${NC}"
        return 1
    fi
    if [ -n "$SMART_LOCAL_ROOT" ]; then
        echo -e "  ${C}⟳${NC} ${W}Trying local bundle:${NC} $SMART_LOCAL_ROOT"
        smart_install_smart_prerequisites local && return 0
    fi
    for src in mtunnel mirror; do
        echo -e "  ${C}⟳${NC} ${W}Trying ${src} source for missing Smart requirements...${NC}"
        smart_install_smart_prerequisites "$src" && return 0
    done
    echo -e "  ${C}⟳${NC} ${W}Falling back to official OS repositories and engine releases...${NC}"
    smart_install_smart_prerequisites official && return 0
    echo -e "  ${R}✖ Automatic setup could not satisfy every Smart requirement. Use option 1 to retry or inspect the messages above.${NC}"
    return 1
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
    required=['mgre','mxlan','mbackhaul','mrathole','python3','openssl','iperf3','ping','iptables','ip','ss','flock','gzip','base64','sha256sum']
    missing=[x for x in required if shutil.which(x) is None]
    bp=None; bv=''
    for p in ('/usr/local/bin/bh','/usr/bin/bh'):
        if os.path.isfile(p) and os.access(p,os.X_OK):
            bp=p
            try:
                o=subprocess.run([p,'-v'],capture_output=True,text=True,timeout=3,stdin=subprocess.DEVNULL)
                m=re.search(r'(\d+\.\d+\.\d+)',(o.stdout or '')+(o.stderr or ''))
                bv=m.group(1) if m else ''
            except Exception: bv=''
            break
    # Backhaul v0.7.2 is required; a different known version rejects the generated configs.
    bh=bp is not None and bv in ('','0.7.2')
    rat=os.path.isfile('/usr/local/bin/rathole') or os.path.isfile('/usr/bin/rathole')
    if bp is None: missing.append('backhaul-core')
    elif not bh: missing.append('backhaul-core(need-0.7.2,found-%s)'%bv)
    if not rat: missing.append('rathole-core')
    return {'version':module_version,'api_rev':api_rev,'ipv4':local4(),'ipv6':local6(),
            'backhaul_core':bh,'backhaul_version':bv,'rathole_core':rat,'iperf3':shutil.which('iperf3') is not None,
            'smart_ready':not missing,'smart_missing':','.join(missing),
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
        return bool(token) and hmac.compare_digest(got.encode('utf-8','surrogatepass'),('Bearer '+token).encode('utf-8','surrogatepass'))
    def do_POST(self):
        data=self.body()
        if data is None: return self.sendj(400,{'ok':False,'error':'invalid json'})
        if self.path=='/v1/pair':
            secret=readf('pair.secret'); exp=readf('pair.expires'); supplied=str(data.get('secret',''))
            if not secret or not exp or not exp.isdigit() or int(exp)<int(time.time()): return self.sendj(403,{'ok':False,'error':'pair code expired'})
            if not hmac.compare_digest(secret.encode('utf-8','surrogatepass'),supplied.encode('utf-8','surrogatepass')):
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
        if action=='smart_ports':
            kind=str(data.get('kind','')); name=str(data.get('name','')); ports=str(data.get('ports',''))
            mods={'backhaul':'/usr/bin/mbackhaul','rathole':'/usr/bin/mrathole'}
            exe=mods.get(kind)
            if not exe or not os.path.isfile(exe) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}',name) or not re.fullmatch(r'[0-9A-Za-z_.,:=-]{1,2048}',ports):
                return self.sendj(400,{'ok':False,'error':'invalid smart_ports request'})
            try:
                p=subprocess.run([exe,'--smart-ports',name,ports],capture_output=True,text=True,timeout=60)
                msg=(p.stdout+'\n'+p.stderr).strip()[-5000:]
                return self.sendj(200 if p.returncode==0 else 500,{'ok':p.returncode==0,'rc':p.returncode,'output':msg})
            except Exception as e: return self.sendj(500,{'ok':False,'error':str(e)})
        if action=='group_state':
            # Iran controller mirrors group metadata here so the Foreign header can show it.
            gid=str(data.get('gid',''))
            if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}',gid) or gid in ('.','..'):
                return self.sendj(400,{'ok':False,'error':'invalid group id'})
            gdir=os.path.join(base,'foreign-groups',gid)
            if data.get('delete'):
                shutil.rmtree(gdir,ignore_errors=True); return self.sendj(200,{'ok':True})
            def clean(v,n=48): return ''.join(c for c in str(v) if c.isprintable() and c not in '|=\\')[:n]
            ports=str(data.get('ports',''))
            if not re.fullmatch(r'[0-9,]{0,300}',ports): ports=''
            try:
                os.makedirs(gdir,mode=0o700,exist_ok=True)
                def put(n,txt):
                    p=os.path.join(gdir,n); t=p+'.tmp'
                    with open(t,'w',encoding='utf-8') as f: f.write(txt)
                    os.chmod(t,0o600); os.replace(t,p)
                put('group.conf','GROUP_ID=%s\nGROUP_NAME=%s\nSERVICE_PORTS=%s\n'%(gid,clean(data.get('name',gid),32),ports))
                rows=[]
                for t in (data.get('tunnels') or [])[:32]:
                    if isinstance(t,dict): rows.append('|'.join(clean(t.get(k,''),40) for k in ('id','label','kind','name','status')))
                put('candidates.tsv','\n'.join(rows)+('\n' if rows else ''))
                a=data.get('active') or {}
                if isinstance(a,dict) and a.get('label'):
                    put('active.state','%s\n'%'|'.join(clean(a.get(k,''),40) for k in ('id','label','score','ping','loss')))
                else:
                    put('active.state','')
                return self.sendj(200,{'ok':True})
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
    echo -e "\n  ${FR}┌─[ FOREIGN AGENT: CREATE PAIR CODE ]${NC}"
    echo -e "  ${FR}│${NC} ${W}Run this on the Foreign server.${NC}"
    echo -e "  ${FR}│${NC} ${DIM}This server becomes the Foreign Agent. After pairing, management is done from Iran.${NC}"
    echo -e "  ${FR}│${NC} ${DIM}Prerequisites must be installed first (option 1).${NC}"
    echo -e "  ${FR}└────────────────────────────────────────────────────────────${NC}\n"
    smart_prereqs_ready || { echo -e "  ${R}✖ Smart prerequisites are incomplete on Foreign. Run option 1 first.${NC}"; smart_pause; return 1; }
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
    smart_install_agent_service || { echo 'Could not install Agent service.' >&2; smart_pause; return 1; }
    systemctl restart mtunnel-smart-agent.service || { echo 'Could not start Agent service.' >&2; smart_pause; return 1; }
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
    echo -e "\n  ${Y}On the Iran server choose option 3 and enter only:${NC} ${W}Foreign IPv4 + Pair Code${NC}"
    echo -e "  ${DIM}IPv6 is already embedded in the Pair Code.${NC}"
    smart_pause
}
smart_pair_controller() {
    smart_header
    smart_prereqs_ready || { echo -e "  ${R}✖ Smart prerequisites are incomplete on Iran. Run option 1 first.${NC}"; smart_pause; return 1; }
    echo -e "\n  ${FR}┌─[ IRAN CONTROLLER PAIRING ]${NC}"
    echo -e "  ${FR}│${NC} ${DIM}On the Foreign server run option 2 (Create Pair Code) first.${NC}"
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
    [ "$(smart_json_field "$response" smart_ready)" = 1 ] || { echo -e "  ${R}✖ Foreign Smart prerequisites are incomplete:${NC} $(smart_json_field "$response" smart_missing)"; echo -e "  ${Y}Run option 1 on Foreign, install prerequisites, then generate a new Pair Code.${NC}"; smart_pause; return 1; }
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
    sleep 1.5
    return 0
}
smart_info() {
    smart_header
    if ! smart_peer_load; then echo -e "\n  ${Y}● This server is not paired as an Iran Controller.${NC}"; smart_pause; return; fi
    local l4 l6 response ok r_ver r_api
    l4=$(smart_local_ipv4); l6=$(smart_local_ipv6); response=$(smart_agent_call '{"action":"info"}' || true); ok=$(smart_json_field "$response" ok)
    r_ver=$(smart_json_field "$response" version); r_api=$(smart_json_field "$response" api_rev)
    echo -e "\n  ${FR}╔════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${FR}║${NC} ${C}▼ SMART PEER & CONTROLLER STATUS${NC}                                                           ${FR}║${NC}"
    echo -e "  ${FR}╠════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    printf "  ${FR}║${NC} ${W}%-18s${NC} ${DIM}❯${NC} ${C}%-69s${NC} ${FR}║${NC}\n" "Iran IPv4" "$l4"
    printf "  ${FR}║${NC} ${W}%-18s${NC} ${DIM}❯${NC} ${C}%-69s${NC} ${FR}║${NC}\n" "Iran IPv6" "$l6"
    printf "  ${FR}║${NC} ${W}%-18s${NC} ${DIM}❯${NC} ${C}%-69s${NC} ${FR}║${NC}\n" "Foreign IPv4" "$SMART_F4"
    printf "  ${FR}║${NC} ${W}%-18s${NC} ${DIM}❯${NC} ${C}%-69s${NC} ${FR}║${NC}\n" "Foreign IPv6" "${SMART_F6:-Unknown}"
    printf "  ${FR}║${NC} ${W}%-18s${NC} ${DIM}❯${NC} ${Y}%-69s${NC} ${FR}║${NC}\n" "Agent Port" "$SMART_PORT"
    printf "  ${FR}║${NC} ${W}%-18s${NC} ${DIM}❯${NC} %b%-69s%b ${FR}║${NC}\n" "Agent Status" "$([ "$ok" = 1 ] && printf "$G" || printf "$R")" "$([ "$ok" = 1 ] && echo "ONLINE (v${r_ver:-?} • API ${r_api:-?})" || echo "OFFLINE")" "$NC"
    echo -e "  ${FR}╚════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    [ "$ok" = 1 ] || echo -e "  ${R}✖ Error: $(smart_json_field "$response" error)${NC}"
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
          '1|mGRE IPv4|gre|ipv4|v4↔v4' \
          '2|mGRE 6to4|gre|6to4|v4↔v4' \
          '3|mGRE IPIP4→4|gre|ipip4to4|v4↔v4' \
          '6|VXLAN IPv4|vxlan|ipv4|v4↔v4'
    fi
    if mt_valid_ipv6 "$l6" && mt_valid_ipv6 "$f6" && [ "$i2f6" = 1 ] && [ "$f2i6" = 1 ]; then
        printf '%s\n' \
          '4|mGRE6|gre|gre6|v6↔v6' \
          '5|mGRE IPIP4→6|gre|ipip4to6|v6↔v6' \
          '7|VXLAN IPv6|vxlan|ipv6|v6↔v6'
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
smart_all_ids() {
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
smart_validate_service_ports() { # ports [ignore_listening_flag]
    local s="${1// /}" ignore_listen="${2:-0}" p; local -A seen=(); local -a _sp=(); SMART_SERVICE_PORTS=''
    [ -z "$s" ] && return 1
    [[ "$s" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
    IFS=, read -ra _sp <<< "$s"
    [ ${#_sp[@]} -le 32 ] || return 1
    for p in "${_sp[@]}"; do
        mt_valid_port "$p" || return 1
        p=$((10#$p))
        [ -z "${seen[$p]:-}" ] || return 1
        if [ "$ignore_listen" != 1 ]; then
            if ss -lntH 2>/dev/null | awk -v want="$p" '{n=split($4,a,":"); if (a[n]==want) found=1} END{exit !found}'; then return 1; fi
        fi
        seen[$p]=1
        SMART_SERVICE_PORTS+="${SMART_SERVICE_PORTS:+,}$p"
    done
}
smart_merge_csv_ports() { # existing_csv add_csv
    local cur="$1" add="$2" p out=''
    local -A seen=()
    for p in ${cur//,/ } ${add//,/ }; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        p=$((10#$p))
        mt_valid_port "$p" || continue
        [ -z "${seen[$p]:-}" ] || continue
        seen[$p]=1
        out+="${out:+,}$p"
    done
    printf '%s' "$out"
}
smart_remove_csv_ports() { # existing_csv rem_csv
    local cur="$1" rem="$2" p out=''
    local -A drop=()
    for p in ${rem//,/ }; do
        [[ "$p" =~ ^[0-9]+$ ]] && drop[$((10#$p))]=1
    done
    for p in ${cur//,/ }; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        p=$((10#$p))
        [ -z "${drop[$p]:-}" ] || continue
        out+="${out:+,}$p"
    done
    printf '%s' "$out"
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
    # VXLAN has no IPv6 core subnet; the shared link validator rejects CORE_V6 for vxlan.
    [ "$kind" != vxlan ] || sed -i '/^CORE_V6=/d' "$a" "$b"
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
smart_remote_smart_ports() { # kind name ports
    local body response
    body=$(K="$1" N="$2" P="$3" python3 - <<'PY'
import json,os; print(json.dumps({'action':'smart_ports','kind':os.environ['K'],'name':os.environ['N'],'ports':os.environ['P']},separators=(',',':')))
PY
)
    response=$(smart_agent_call "$body" 60 || true)
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
    local gd="$1" rank="$2"
    local sf="$gd/switch.state" current='' challenger='' streak=0 last=0 now top active_score top_score active_status tmp
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
smart_apply_active_forwarding_core() { # groupdir ranking-file
    local gd="$1" rank="$2"
    local state="$gd/forwarding.state" current previous='' current_kind='' previous_kind=''
    current=$(cut -d'|' -f1 "$gd/active.state" 2>/dev/null || true)
    [ -s "$state" ] && previous=$(cat "$state" 2>/dev/null || true)
    [ "$current" != "$previous" ] || return 0
    if [ -z "$current" ]; then
        [ -z "$previous" ] || smart_forward_one "$gd" "$previous" off || true
        : > "$state"; chmod 600 "$state"; return 0
    fi
    current_kind=$(awk -F'|' -v i="$current" '$1==i{print $3;exit}' "$gd/candidates.tsv")
    [ -z "$previous" ] || previous_kind=$(awk -F'|' -v i="$previous" '$1==i{print $3;exit}' "$gd/candidates.tsv")
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
# Wrapper: when the active tunnel changes, push the new state to the Foreign header mirror.
smart_apply_active_forwarding() { # groupdir ranking-file
    local gd="$1" before after rc=0
    before=$(cat "$gd/forwarding.state" 2>/dev/null || true)
    smart_apply_active_forwarding_core "$@" || rc=$?
    after=$(cat "$gd/forwarding.state" 2>/dev/null || true)
    [ "$before" = "$after" ] || smart_sync_foreign_state "$gd"
    return "$rc"
}
smart_benchmark_group_locked() { # groupdir; caller owns the process-level lock
    local gd="$1"
    local cand="$gd/candidates.tsv" out="$gd/ranking.tsv" tmp="$gd/.bench.tmp" id label kind proto path name inner linkp benchp status lat loss jit up down score maxs=0 stats target target_port body resp
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
                up=$(smart_iperf_speed_backhaul "$benchp" normal); down=$(smart_iperf_speed_backhaul "$benchp" reverse)
            else
                up=$(smart_iperf_speed_rathole "$benchp" normal); down=$(smart_iperf_speed_rathole "$benchp" reverse)
            fi
        else
            stats=$(smart_ping_stats "$inner"); IFS='|' read -r lat loss jit <<< "$stats"; target="$inner"
            up=$(smart_iperf_speed "$inner" normal); down=$(smart_iperf_speed "$inner" reverse)
        fi
        lat=${lat:-9999}; loss=${loss:-100}; jit=${jit:-9999}; up=${up:-0}; down=${down:-0}
        # UP/DOWN is decided by reachability (ping / TCP probe). A failed iperf3 run only lowers the score;
        # it must not mark a working tunnel DOWN (which left the group with no active tunnel).
        status=UP
        if awk -v l="$lat" -v s="$loss" -v u="$up" -v d="$down" 'BEGIN{exit !((l>=9999 || s>=100) && u<=0 && d<=0)}'; then status=DOWN; fi
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|0\n' "$id" "$label" "$kind" "$proto" "$path" "$name" "$inner" "$linkp" "$benchp" "$status" "$lat" "$loss" "$jit" "$up" "$down" >> "$tmp"
    done < "$cand"
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
smart_rank_color() { # value mode(low|high) good warn -> prints G / Y / R color code
    local c
    c=$(awk -v v="${1:-0}" -v m="$2" -v g="$3" -v w="$4" 'BEGIN{
        if (m=="low") r=(v<=g)?0:((v<=w)?1:2); else r=(v>=g)?0:((v>=w)?1:2); print r}')
    case "$c" in 0) printf '%s' "$G";; 1) printf '%s' "$Y";; *) printf '%s' "$R";; esac
}
smart_show_ranking_file() { # ranking.tsv; plain colored list (no table)
    local f="$1" n=0 act_id id label kind proto path name inner linkp benchp status lat loss jit up down score
    local lat_txt lat_col loss_col up_col dn_col sc_col st_col mark
    [ -s "$f" ] || { echo -e "  ${Y}● No benchmark result yet.${NC}"; return 1; }
    act_id=$(cut -d'|' -f1 "$(dirname "$f")/active.state" 2>/dev/null || true)
    echo -e "\n  ${FR}▼ SMART TUNNEL RANKING${NC}  ${DIM}(ms · loss · ↑upload ↓download Mbps · score)${NC}\n"
    while IFS='|' read -r id label kind proto path name inner linkp benchp status lat loss jit up down score; do
        n=$((n+1)); label="$(smart_short_label "$label")"
        lat="${lat:-9999}"; loss="${loss:-100}"; up="${up:-0}"; down="${down:-0}"; score="${score:-0}"
        if awk -v l="$lat" 'BEGIN{exit !(l>=9999)}'; then
            lat_txt='---'; lat_col="$DIM"
        else
            lat_txt="$(printf "%.1f" "$lat")ms"; lat_col=$(smart_rank_color "$lat" low 80 200)
        fi
        loss_col=$(smart_rank_color "$loss" low 0 5)
        up_col=$(smart_rank_color "$up" high 50 10)
        dn_col=$(smart_rank_color "$down" high 50 10)
        sc_col=$(smart_rank_color "$score" high 70 40)
        if [ "$status" = UP ]; then st_col="$G"; else st_col="$R"; sc_col="$R"; fi
        mark=' '; [ "$id" = "$act_id" ] && [ "$status" = UP ] && mark='★'
        printf "  ${Y}%-2s${NC} ${G}%s${NC} ${W}%-24.24s${NC} %b%-9s${NC} ${DIM}loss${NC} %b%-5s${NC} ${DIM}↑${NC}%b%-7s${NC} ${DIM}↓${NC}%b%-8s${NC} ${DIM}score${NC} %b%-5s${NC} %b%s${NC}\n" \
            "$n" "$mark" "$label" "$lat_col" "$lat_txt" "$loss_col" "${loss}%" "$up_col" "$up" "$dn_col" "$down" "$sc_col" "$score" "$st_col" "$status"
    done < "$f"
    echo
}
smart_create_group() {
    smart_peer_load || { echo -e "  ${R}✖ Pair the Foreign server first (option 2 on Foreign, option 3 on Iran).${NC}"; smart_pause; return 1; }
    smart_prereqs_ready || { echo -e "  ${R}✖ Smart prerequisites are incomplete on Iran. Run option 1 first.${NC}"; smart_pause; return 1; }
    local l4 l6 response ok f6 lbh=0 rbh=0 lrat=0 rrat=0 avail choice ids services gid gd rec id line label kind proto path base secret hash num core corev6 links local_link remote_link inner lname rname linkport benchport ports status dep_out
    l4=$(smart_local_ipv4); l6=$(smart_local_ipv6); response=$(smart_agent_call '{"action":"info"}' || true); ok=$(smart_json_field "$response" ok)
    [ "$ok" = 1 ] || { echo -e "  ${R}✖ Foreign Agent is offline: $(smart_json_field "$response" error)${NC}"; smart_pause; return 1; }
    [ "$(smart_json_field "$response" smart_ready)" = 1 ] || { echo -e "  ${R}✖ Foreign Smart prerequisites are incomplete: $(smart_json_field "$response" smart_missing)${NC}"; echo -e "  ${Y}Run option 1 on Foreign before building tunnels.${NC}"; smart_pause; return 1; }
    f6=$(smart_json_field "$response" ipv6); [ "$f6" != Unknown ] || f6="$SMART_F6"
    if smart_core_installed_backhaul; then lbh=1; fi
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
    smart_prompt_group_name; local gname="$SMART_GROUP_NAME"
    while true; do
        echo -ne "\n  ${C}●${NC} ${W}Service TCP ports [example: 443,8443,2053]: ${NC}"; read -r services
        smart_validate_service_ports "$services" && { services="$SMART_SERVICE_PORTS"; break; }
        echo -e "  ${R}✖ Enter one or more comma-separated free TCP ports.${NC}"
    done
    gid="sg$(date +%m%d%H%M)-$(smart_random_hex 2)"; gd="$GROUP_DIR/$gid"; mkdir -p "$gd"; chmod 700 "$gd"
    cat > "$gd/group.conf" <<EOF
GROUP_ID=$gid
GROUP_NAME=$gname
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
    chmod 600 "$gd/group.conf"
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
            if dep_out=$(smart_deploy_local "$kind" "$local_link" 2>&1); then
                status=UP; echo -e "      ${G}✓ Iran side${NC}"
            else
                echo -e "      ${R}✖ Iran side failed — rolling back Foreign side${NC}"
                printf '%s\n' "$dep_out" | tail -n 6 | sed 's/^/      /' >&2
                [ -z "$rname" ] || smart_delete_remote "$kind" "$rname" >/dev/null 2>&1 || true
            fi
        fi
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$id" "$label" "$kind" "$proto" "$path" "$lname" "$inner" "$linkport" "$benchport" "$status" >> "$gd/candidates.tsv"
    done
    local bench_rc=0
    smart_benchmark_group "$gd" || bench_rc=$?
    smart_install_watchdog
    smart_sync_foreign_state "$gd"
    smart_header; smart_show_ranking_file "$gd/ranking.tsv"
    if [ "$bench_rc" -eq 0 ]; then
        echo -e "\n  ${G}✓ Smart forwarding active for TCP ports: ${services}${NC}"
        echo -e "  ${DIM}GRE/VXLAN: 5-vIP iptables load-balance | Rathole/Backhaul: native forwarder${NC}"
    else
        echo -e "\n  ${Y}⚠ Ranking completed, but the active tunnel forwarder could not be enabled.${NC}"
    fi
    echo -e "  ${DIM}Group: $gname ($gid)${NC}"
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
smart_recovery_score() { # latency loss jitter -> provisional health-only score
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
        if [ -s "$gd/delete-tunnel.${id}.pending" ]; then
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|DOWN|%s|%s|%s|%s|%s|0\n' "$id" "$label" "$kind" "$proto" "$path" "$name" "$inner" "$linkp" "$benchp" "$blat" "$loss" "$jit" "$up" "$down" >> "$tmp"
            continue
        fi
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
    smart_sync_foreign_throttled "$gd" || true
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

# ======================================================================
# [ GRE-STYLE INTERACTIVE SELECTORS, LISTS, PORT MANAGER & DELETION ]
# ======================================================================
smart_select_group_interactive() {
    smart_header
    local -a groups=()
    local gd i sel idx gid active_lbl svc tcnt
    for gd in "$GROUP_DIR"/*; do [ -d "$gd" ] && groups+=("$gd"); done
    [ ${#groups[@]} -gt 0 ] || { echo -e "\n  ${R}● No Smart groups configured yet!${NC}"; sleep 1.5; return 1; }

    if [ ${#groups[@]} -eq 1 ]; then
        SELECTED_GROUP_DIR="${groups[0]}"
        return 0
    fi

    echo -e "\n  ${FR}╔═══════════════════════════════ Select Smart Tunnel Group ══════════════════════════════════╗${NC}"
    for i in "${!groups[@]}"; do
        gid=$(smart_group_label "${groups[$i]}")
        active_lbl=$(cut -d'|' -f2 "${groups[$i]}/active.state" 2>/dev/null || true)
        active_lbl="$(smart_short_label "$active_lbl")"
        svc=$(smart_conf_get "${groups[$i]}/group.conf" SERVICE_PORTS)
        tcnt=$(wc -l < "${groups[$i]}/candidates.tsv" 2>/dev/null || echo 0)
        printf "  ${FR}║${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-18.18s${NC} ${DIM}| Active:${NC} ${G}%-20.20s${NC} ${DIM}| Tunnels:${NC} ${C}%-2s${NC} ${DIM}| Ports:${NC} ${Y}%-14.14s${NC} ${FR}║${NC}\n" "$((i+1))" "$gid" "${active_lbl:-OFF}" "$tcnt" "${svc:-None}"
    done
    echo -e "  ${FR}╚════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Group [1-${#groups[@]}] or 'q': ${NC}"; read -r sel
    sel="${sel// /}"; sel="${sel//$'\r'/}"
    [[ "$sel" == "q" || "$sel" == "Q" || -z "$sel" ]] && return 1
    if idx=$(smart_pick_index "$sel" "${#groups[@]}"); then
        SELECTED_GROUP_DIR="${groups[$idx]}"
        return 0
    fi
    echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1
    return 1
}

smart_list_overview() {
    smart_header
    local -a groups=()
    local gd gid svc ir4 kh4 ir6 kh6 wd active_line act_id act_lbl act_score
    local id label kind proto path name inner linkp benchp status lat loss jit up down score
    for gd in "$GROUP_DIR"/*; do [ -d "$gd" ] && groups+=("$gd"); done
    if [ ${#groups[@]} -eq 0 ]; then
        echo -e "\n  ${R}● No Smart groups configured yet!${NC}"
        smart_pause
        return
    fi

    echo -e "\n  ${Y}● Smart Groups, Tunnels & Ports Overview:${NC}"
    for gd in "${groups[@]}"; do
        gid=$(smart_group_label "$gd")
        svc=$(smart_conf_get "$gd/group.conf" SERVICE_PORTS)
        ir4=$(smart_conf_get "$gd/group.conf" IRAN_IPV4)
        kh4=$(smart_conf_get "$gd/group.conf" FOREIGN_IPV4)
        ir6=$(smart_conf_get "$gd/group.conf" IRAN_IPV6)
        kh6=$(smart_conf_get "$gd/group.conf" FOREIGN_IPV6)
        wd=$(smart_conf_get "$gd/group.conf" WATCHDOG)
        active_line=$(cat "$gd/active.state" 2>/dev/null || true)
        IFS='|' read -r act_id act_lbl act_score <<< "$active_line"; act_lbl="$(smart_short_label "$act_lbl")"

        local left_p="▼ Group: ${gid}"
        local right_p="Watchdog: $([ "$wd" = 1 ] && echo ON || echo OFF)"
        local pad=$(( 90 - 9 - ${#gid} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0
        local sp; sp=$(printf '%*s' "$pad" "")

        echo -e "  ${FR}╔════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${FR}║${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${FR}║${NC}"
        echo -e "  ${FR}╠════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"

        local act_str="${act_lbl:-OFF} (Score: ${act_score:-0})"
        local ep4_str="${ir4:-?} -> ${kh4:-?}"
        local l1="Active Tunnel: ${act_str:0:32}"
        local r1="IPv4 Path: ${ep4_str:0:32}"
        local pad1=$(( 90 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0
        local sp1; sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${FR}║${NC} ${G}Active Tunnel:${NC} ${W}${act_str:0:32}${NC}${sp1}${DIM}IPv4 Path:${NC} ${W}${ep4_str:0:32}${NC} ${FR}║${NC}"

        local ports_str="${svc:-None}"
        local l2="Service Ports: ${ports_str:0:74}"
        local pad2=$(( 90 - ${#l2} )); [ "$pad2" -lt 0 ] && pad2=0
        local sp2; sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${FR}║${NC} ${Y}Service Ports:${NC} ${W}${ports_str:0:74}${NC}${sp2} ${FR}║${NC}"

        echo -e "  ${FR}╠════╦═══════════════════════════╦════════════════╦══════════════╦════════╦══════════╦═══════╣${NC}"
        printf "  ${FR}║${NC} ${DIM}%-2s${NC} ${FR}║${NC} ${DIM}%-25s${NC} ${FR}║${NC} ${DIM}%-14s${NC} ${FR}║${NC} ${DIM}%-12s${NC} ${FR}║${NC} ${DIM}%-6s${NC} ${FR}║${NC} ${DIM}%-8s${NC} ${FR}║${NC} ${DIM}%-5s${NC} ${FR}║${NC}\n" "ID" "TUNNEL TYPE" "IFACE / UNIT" "TARGET/PORT" "PING" "UP/DN" "STATE"
        echo -e "  ${FR}╠════╬═══════════════════════════╬════════════════╬══════════════╬════════╬══════════╬═══════╣${NC}"

        local source_file="$gd/ranking.tsv"
        [ -s "$source_file" ] || source_file="$gd/candidates.tsv"
        if [ -s "$source_file" ]; then
            while IFS='|' read -r id label kind proto path name inner linkp benchp status lat loss jit up down score; do
                local endpoint_disp="${inner:-}"
                [ -n "$endpoint_disp" ] || endpoint_disp="L:${linkp:-?}"
                local lat_disp="${lat:+${lat}ms}"; [ -z "$lat" ] && lat_disp="---"
                local spd_disp="${up:-0}/${down:-0}"
                local st_col="$G" st_txt="$status"
                [ "$status" = UP ] || st_col="$R"
                local lbl_disp="$(smart_short_label "$label")"
                if [ "$id" = "$act_id" ]; then
                    lbl_disp="★ $label"
                    st_txt="ACTV"
                    st_col="$G"
                fi
                printf "  ${FR}║${NC} ${Y}%-2s${NC} ${FR}║${NC} ${W}%-25.25s${NC} ${FR}║${NC} ${C}%-14.14s${NC} ${FR}║${NC} ${DIM}%-12.12s${NC} ${FR}║${NC} ${Y}%-6.6s${NC} ${FR}║${NC} %-8.8s ${FR}║${NC} %b%-5.5s%b ${FR}║${NC}\n" \
                    "$id" "$lbl_disp" "${name:----}" "$endpoint_disp" "$lat_disp" "$spd_disp" "$st_col" "$st_txt" "$NC"
            done < "$source_file"
        else
            printf "  ${FR}║${NC} ${DIM}%-90s${NC} ${FR}║${NC}\n" "No tunnels remain in this group."
        fi
        echo -e "  ${FR}╚════╩═══════════════════════════╩════════════════╩══════════════╩════════╩══════════╩═══════╝${NC}\n"
    done
    smart_pause
}

smart_sync_group_ports_locked() { # gid new_ports_csv; caller owns .smart.lock
    local gid="$1" new_ports="$2" gd="$GROUP_DIR/$1" old_ports active_id id label kind proto path name inner linkp benchp status rname p
    local active_was_on=0 rollback_failed=0 i
    local -a rollback_names=() rollback_specs=()
    [[ "$gid" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 2
    [ -d "$gd" ] && [ -s "$gd/group.conf" ] || return 2
    if [ -n "$new_ports" ]; then
        smart_validate_service_ports "$new_ports" 1 || return 2
        new_ports="$SMART_SERVICE_PORTS"
    else
        new_ports=''
    fi
    old_ports=$(smart_conf_get "$gd/group.conf" SERVICE_PORTS)
    [ "$new_ports" != "$old_ports" ] || return 0

    # Only newly-added ports must be free; existing ports may be held by the current active forwarder.
    for p in ${new_ports//,/ }; do
        [[ ",${old_ports}," == *",${p},"* ]] && continue
        if ss -lntH 2>/dev/null | awk -v want="$p" '{n=split($4,a,":"); if (a[n]==want) found=1} END{exit !found}'; then
            echo "Port $p is already listening on this server." >&2
            return 3
        fi
    done

    active_id=$(cut -d'|' -f1 "$gd/active.state" 2>/dev/null || true)
    if [ -n "$active_id" ]; then
        smart_forward_one "$gd" "$active_id" off || { echo 'Could not safely disable current forwarding.' >&2; return 1; }
        active_was_on=1
    fi

    # Rathole's Foreign-side client must receive the same port set. Track every successful
    # remote update so the transaction can be rolled back if a later step fails.
    if [ -s "$gd/candidates.tsv" ]; then
        while IFS='|' read -r id label kind proto path name inner linkp benchp status; do
            [ "$kind" = rathole ] || continue
            rname=$(awk -F'|' -v i="$id" '$1==i{print $4;exit}' "$gd/names.tsv" 2>/dev/null || true)
            [ -n "$rname" ] || rname="$name"
            local old_spec="$benchp${old_ports:+,$old_ports}"
            local new_spec="$benchp${new_ports:+,$new_ports}"
            if ! smart_remote_smart_ports rathole "$rname" "$new_spec"; then
                echo "Foreign Rathole port sync failed for $rname; rolling back." >&2
                for ((i=${#rollback_names[@]}-1; i>=0; i--)); do
                    smart_remote_smart_ports rathole "${rollback_names[$i]}" "${rollback_specs[$i]}" >/dev/null 2>&1 || rollback_failed=1
                done
                [ "$active_was_on" -eq 0 ] || smart_forward_one "$gd" "$active_id" on >/dev/null 2>&1 || rollback_failed=1
                [ "$rollback_failed" -eq 0 ] || echo 'Warning: port rollback was incomplete; retry after peer connectivity is restored.' >&2
                return 1
            fi
            rollback_names+=("$rname"); rollback_specs+=("$old_spec")
        done < "$gd/candidates.tsv"
    fi

    if ! smart_set_conf_var "$gd/group.conf" SERVICE_PORTS "$new_ports"; then
        for ((i=${#rollback_names[@]}-1; i>=0; i--)); do
            smart_remote_smart_ports rathole "${rollback_names[$i]}" "${rollback_specs[$i]}" >/dev/null 2>&1 || rollback_failed=1
        done
        [ "$active_was_on" -eq 0 ] || smart_forward_one "$gd" "$active_id" on >/dev/null 2>&1 || rollback_failed=1
        echo 'Could not save the new service-port set; rolled back.' >&2
        return 1
    fi

    if [ "$active_was_on" -eq 1 ] && ! smart_forward_one "$gd" "$active_id" on; then
        smart_set_conf_var "$gd/group.conf" SERVICE_PORTS "$old_ports" >/dev/null 2>&1 || rollback_failed=1
        for ((i=${#rollback_names[@]}-1; i>=0; i--)); do
            smart_remote_smart_ports rathole "${rollback_names[$i]}" "${rollback_specs[$i]}" >/dev/null 2>&1 || rollback_failed=1
        done
        smart_forward_one "$gd" "$active_id" on >/dev/null 2>&1 || rollback_failed=1
        echo 'New port forwarding could not be activated; previous port set restored.' >&2
        [ "$rollback_failed" -eq 0 ] || echo 'Warning: rollback was incomplete; inspect the active tunnel before retrying.' >&2
        return 1
    fi
    smart_sync_foreign_state "$gd"
    return 0
}

smart_sync_group_ports() { # groupdir new_ports_csv; serialize against watchdog/benchmark/delete
    local gd="$1" new_ports="$2" gid
    [ -d "$gd" ] || return 1
    gid=$(basename "$gd"); [[ "$gid" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 2
    flock -x -w 120 -o "$gd/.smart.lock" "$INSTALL_PATH" --sync-ports "$gid" "$new_ports"
}

smart_manage_ports() {
    smart_select_group_interactive || return
    local gd="$SELECTED_GROUP_DIR" gid
    gid=$(smart_group_label "$gd")
    local pf_opt cur_ports in_ports merged_ports active_lbl

    while true; do
        cur_ports=$(smart_conf_get "$gd/group.conf" SERVICE_PORTS)
        active_lbl=$(cut -d'|' -f2 "$gd/active.state" 2>/dev/null || true)
        active_lbl="$(smart_short_label "$active_lbl")"
        smart_header
        echo -e "\n  ${FR}┌─[ SMART PORT MANAGER: ${W}${gid}${DIM} ]${NC}"
        echo -e "  ${FR}│${NC} ${DIM}Current TCP Ports:${NC} ${Y}${cur_ports:-None}${NC}"
        echo -e "  ${FR}│${NC} ${DIM}Active Tunnel    :${NC} ${G}${active_lbl:-OFF}${NC}"
        echo -e "  ${FR}│${NC}"
        echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add New Ports (Keep Existing)${NC}"
        echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Delete / Remove Specific Ports${NC}"
        echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Replace All Ports (Overwrite)${NC}"
        echo -e "  ${FR}│${NC}"
        echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"; read -r pf_opt
        pf_opt="${pf_opt// /}"; pf_opt="${pf_opt//$'\r'/}"

        case "$pf_opt" in
            1)
                echo -ne "  ${C}●${NC} ${W}Add TCP Ports (e.g. 8080,2083) [Enter to cancel]: ${NC}"; read -r in_ports
                in_ports="${in_ports// /}"; [ -n "$in_ports" ] || continue
                if ! smart_validate_service_ports "$in_ports" 0; then
                    echo -e "  ${R}✖ Invalid port(s) or port is already bound by another service.${NC}"; sleep 1.8; continue
                fi
                merged_ports=$(smart_merge_csv_ports "$cur_ports" "$SMART_SERVICE_PORTS")
                echo -e "  ${C}⟳${NC} Updating group ports and syncing active forwarder..."
                if smart_sync_group_ports "$gd" "$merged_ports"; then
                    echo -e "  ${G}✔ Ports added. Active TCP Ports: ${merged_ports}${NC}"
                else
                    echo -e "  ${Y}⚠ Ports saved (${merged_ports}), but active forwarder reported a warning.${NC}"
                fi
                sleep 1.8
                ;;
            2)
                [ -n "$cur_ports" ] || { echo -e "  ${Y}● No ports to remove.${NC}"; sleep 1.5; continue; }
                echo -ne "  ${C}●${NC} ${W}Remove TCP Ports (Current: ${Y}${cur_ports}${W}): ${NC}"; read -r in_ports
                in_ports="${in_ports// /}"; [ -n "$in_ports" ] || continue
                merged_ports=$(smart_remove_csv_ports "$cur_ports" "$in_ports")
                echo -e "  ${C}⟳${NC} Removing selected ports and syncing active forwarder..."
                if smart_sync_group_ports "$gd" "$merged_ports"; then
                    echo -e "  ${G}✔ Ports removed. Remaining TCP Ports: ${merged_ports:-None}${NC}"
                else
                    echo -e "  ${Y}⚠ Ports updated (${merged_ports}), but active forwarder reported a warning.${NC}"
                fi
                sleep 1.8
                ;;
            3)
                echo -ne "  ${C}●${NC} ${W}New TCP Ports (Current: ${Y}${cur_ports:-None}${W}): ${NC}"; read -r in_ports
                in_ports="${in_ports// /}"; [ -n "$in_ports" ] || continue
                if ! smart_validate_service_ports "$in_ports" 1; then
                    echo -e "  ${R}✖ Invalid TCP port list.${NC}"; sleep 1.8; continue
                fi
                merged_ports="$SMART_SERVICE_PORTS"
                echo -e "  ${C}⟳${NC} Replacing ports and syncing active forwarder..."
                if smart_sync_group_ports "$gd" "$merged_ports"; then
                    echo -e "  ${G}✔ Ports replaced. Active TCP Ports: ${merged_ports}${NC}"
                else
                    echo -e "  ${Y}⚠ Ports replaced (${merged_ports}), but active forwarder reported a warning.${NC}"
                fi
                sleep 1.8
                ;;
            0|q|Q) return 0 ;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1 ;;
        esac
    done
}

smart_mark_tunnel_delete_pending() { # groupdir candidate-id remote-ok local-ok
    local gd="$1" target_id="$2" rok="$3" lok="$4" f tmp
    for f in candidates.tsv ranking.tsv; do
        [ -s "$gd/$f" ] || continue
        tmp="$gd/.${f}.delete.$$"
        awk -F'|' -v OFS='|' -v i="$target_id" '
            $1==i { $10="DOWN"; if (NF>=16) $16=0 }
            { print }
        ' "$gd/$f" > "$tmp" && mv -f "$tmp" "$gd/$f"
        chmod 600 "$gd/$f" 2>/dev/null || true
    done
    printf 'id=%s\ntime=%s\nremote_ok=%s\nlocal_ok=%s\n' "$target_id" "$(date +%s)" "$rok" "$lok" > "$gd/delete-tunnel.${target_id}.pending"
    chmod 600 "$gd/delete-tunnel.${target_id}.pending" 2>/dev/null || true
}

smart_delete_single_tunnel_locked() { # gid candidate_id; caller owns .smart.lock
    local gid="$1" target_id="$2" gd="$GROUP_DIR/$1"
    local active_id id label kind proto path lname inner linkp benchp status rname cand_line name_line
    local remote_ok=1 local_ok=1 was_active=0 f tmp
    [[ "$gid" =~ ^[A-Za-z0-9_.-]{1,64}$ && "$target_id" =~ ^[0-9]+$ ]] || return 2
    [ -d "$gd" ] && [ -s "$gd/candidates.tsv" ] || return 1
    cand_line=$(awk -F'|' -v i="$target_id" '$1==i{print;exit}' "$gd/candidates.tsv" 2>/dev/null || true)
    [ -n "$cand_line" ] || return 0
    IFS='|' read -r id label kind proto path lname inner linkp benchp status <<< "$cand_line"
    name_line=$(awk -F'|' -v i="$target_id" '$1==i{print;exit}' "$gd/names.tsv" 2>/dev/null || true)
    if [ -n "$name_line" ]; then IFS='|' read -r _ _ lname rname <<< "$name_line"; else rname="$lname"; fi

    active_id=$(cut -d'|' -f1 "$gd/active.state" 2>/dev/null || true)
    if [ "$target_id" = "$active_id" ]; then
        was_active=1
        smart_forward_one "$gd" "$target_id" off || { echo 'Could not disable the active tunnel before deletion.' >&2; return 1; }
        : > "$gd/active.state"; : > "$gd/forwarding.state"
    fi

    [ -z "$rname" ] || smart_delete_remote "$kind" "$rname" >/dev/null 2>&1 || remote_ok=0
    [ -z "$lname" ] || smart_delete_local "$kind" "$lname" >/dev/null 2>&1 || local_ok=0

    if [ "$remote_ok" -eq 1 ] && [ "$local_ok" -eq 1 ]; then
        for f in candidates.tsv names.tsv ranking.tsv baseline.tsv; do
            [ -e "$gd/$f" ] || continue
            tmp="$gd/.${f}.delete.$$"
            awk -F'|' -v i="$target_id" '$1!=i' "$gd/$f" > "$tmp" && mv -f "$tmp" "$gd/$f"
            chmod 600 "$gd/$f" 2>/dev/null || true
        done
        rm -f "$gd/delete-tunnel.${target_id}.pending"
    else
        smart_mark_tunnel_delete_pending "$gd" "$target_id" "$remote_ok" "$local_ok"
        echo "Tunnel cleanup is incomplete (Foreign=$remote_ok Iran=$local_ok); state retained for retry." >&2
    fi

    # If the deleted/partially-deleted tunnel was active, keep it out of service and fail over.
    if [ "$was_active" -eq 1 ]; then
        if [ -s "$gd/ranking.tsv" ]; then
            smart_hysteresis_order "$gd" "$gd/ranking.tsv"
            smart_apply_active_forwarding "$gd" "$gd/ranking.tsv" >/dev/null 2>&1 || true
        else
            : > "$gd/switch.state"
        fi
    fi
    smart_sync_foreign_state "$gd"
    [ "$remote_ok" -eq 1 ] && [ "$local_ok" -eq 1 ]
}

smart_delete_single_tunnel() { # groupdir candidate_id; serialize against watchdog/benchmark/ports
    local gd="$1" target_id="$2" gid
    [ -d "$gd" ] || return 1
    gid=$(basename "$gd"); [[ "$gid" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 2
    flock -x -w 120 -o "$gd/.smart.lock" "$INSTALL_PATH" --delete-tunnel "$gid" "$target_id"
}

smart_menu_delete_tunnels() {
    smart_select_group_interactive || return
    local gd="$SELECTED_GROUP_DIR" gid
    gid=$(smart_group_label "$gd")

    while true; do
        smart_header
        if [ ! -s "$gd/candidates.tsv" ]; then
            echo -e "\n  ${Y}● No tunnels left in group [${gid}].${NC}"
            echo -ne "  ${Y}Delete the empty group [${gid}] as well? (y/n): ${NC}"; read -r ans
            if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
                smart_sync_foreign_state "$gd" delete
                rm -rf -- "$gd"
                echo -e "  ${G}✔ Empty group [${gid}] removed.${NC}"
                sleep 1.5
            fi
            return
        fi

        local active_id; active_id=$(cut -d'|' -f1 "$gd/active.state" 2>/dev/null || true)
        local -a c_ids=() c_labels=() c_names=()
        local n=0 id label kind proto path name inner linkp benchp status sel confirm idx

        echo -e "\n  ${R}┌─[ DELETE TUNNELS IN GROUP: ${W}${gid}${R} ]${NC}"
        while IFS='|' read -r id label kind proto path name inner linkp benchp status; do
            n=$((n+1))
            c_ids+=("$id"); c_labels+=("$(smart_short_label "$label")"); c_names+=("$name")
            local act_tag=""
            [ "$id" = "$active_id" ] && act_tag=" ${G}[ACTIVE]${NC}"
            [ -s "$gd/delete-tunnel.${id}.pending" ] && act_tag+=" ${Y}[DELETE PENDING]${NC}"
            local st_col="$G"; [ "$status" = UP ] || st_col="$R"
            echo -e "  ${W}${n}${NC} ${DIM}❯${NC} ${Y}${name}${NC} ${DIM}|${NC} ${C}$(smart_short_label "$label")${NC} ${DIM}(${path})${NC} ${DIM}|${NC} ${st_col}${status}${NC}${act_tag}"
        done < "$gd/candidates.tsv"
        echo -e "  ${W}a${NC} ${DIM}❯${NC} Delete ALL tunnels in this group"
        echo -e "  ${W}q${NC} ${DIM}❯${NC} Back"
        echo -ne "\n  ${C}Select tunnel to delete ❯❯ ${NC}"; read -r sel
        sel="${sel// /}"; sel="${sel//$'\r'/}"
        [[ "$sel" == "q" || "$sel" == "Q" || -z "$sel" ]] && return

        if [[ "$sel" == "a" || "$sel" == "A" ]]; then
            echo -ne "  ${R}Delete ALL ${n} tunnels in group [${gid}]? Type 'yes' to confirm: ${NC}"; read -r confirm
            [ "$confirm" == "yes" ] || continue
            local del_fail=0
            for id in "${c_ids[@]}"; do
                smart_delete_single_tunnel "$gd" "$id" || del_fail=1
            done
            if [ "$del_fail" -eq 0 ]; then
                echo -e "  ${G}✔ All tunnels in group [${gid}] deleted.${NC}"
            else
                echo -e "  ${Y}⚠ Some tunnel cleanup is pending. Retry Delete Tunnels after peer connectivity is restored.${NC}"
            fi
            sleep 1.5
            continue
        fi

        idx=$(smart_pick_index "$sel" "$n") || { echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1; continue; }
        local target_id="${c_ids[$idx]}"
        local target_lbl="${c_labels[$idx]}"
        local target_name="${c_names[$idx]}"
        echo -ne "  ${R}Delete tunnel [${target_name} - ${target_lbl}]? Type 'yes' to confirm: ${NC}"; read -r confirm
        [ "$confirm" == "yes" ] || continue
        if smart_delete_single_tunnel "$gd" "$target_id"; then
            echo -e "  ${G}✔ Tunnel [${target_name}] deleted successfully.${NC}"
        else
            echo -e "  ${Y}⚠ Tunnel [${target_name}] cleanup is pending; it has been removed from active service and will not be selected by Watchdog.${NC}"
        fi
        sleep 1.5
    done
}

smart_menu_delete_groups() {
    while true; do
        smart_header
        local -a groups=()
        local gd gid glabel n=0 active_lbl svc tcnt sel confirm idx
        for gd in "$GROUP_DIR"/*; do [ -d "$gd" ] && groups+=("$gd"); done
        if [ ${#groups[@]} -eq 0 ]; then
            echo -e "\n  ${Y}● No Smart groups configured.${NC}\n"
            smart_pause
            return
        fi

        echo -e "\n  ${R}┌─[ DELETE SMART GROUPS ]${NC}"
        for gd in "${groups[@]}"; do
            n=$((n+1))
            glabel=$(smart_group_label "$gd")
            active_lbl=$(cut -d'|' -f2 "$gd/active.state" 2>/dev/null || true)
            active_lbl="$(smart_short_label "$active_lbl")"
            svc=$(smart_conf_get "$gd/group.conf" SERVICE_PORTS)
            tcnt=$(wc -l < "$gd/candidates.tsv" 2>/dev/null || echo 0)
            echo -e "  ${W}${n}${NC} ${DIM}❯${NC} ${Y}${glabel}${NC} ${DIM}| Active:${NC} ${G}${active_lbl:-OFF}${NC} ${DIM}| Tunnels:${NC} ${C}${tcnt}${NC} ${DIM}| Ports:${NC} ${W}${svc:-None}${NC}"
        done
        echo -e "  ${W}a${NC} ${DIM}❯${NC} Delete ALL Smart groups"
        echo -e "  ${W}q${NC} ${DIM}❯${NC} Back"
        echo -ne "\n  ${C}Select group to delete ❯❯ ${NC}"; read -r sel
        sel="${sel// /}"; sel="${sel//$'\r'/}"
        [[ "$sel" == "q" || "$sel" == "Q" || -z "$sel" ]] && return

        if [[ "$sel" == "a" || "$sel" == "A" ]]; then
            echo -ne "  ${R}Delete ALL ${n} Smart groups and their tunnels on Iran & Foreign? Type 'yes' to confirm: ${NC}"; read -r confirm
            [ "$confirm" == "yes" ] || continue
            echo -e "  ${C}⟳${NC} Deleting all Smart groups and cleaning up both servers..."
            if smart_delete_groups; then
                echo -e "  ${G}✔ All ${n} Smart groups deleted successfully.${NC}"
            else
                echo -e "  ${Y}⚠ Some group state was retained because remote cleanup could not complete.${NC}"
            fi
            sleep 1.8
            continue
        fi

        idx=$(smart_pick_index "$sel" "$n") || { echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1; continue; }
        gd="${groups[$idx]}"
        gid=$(basename "$gd")
        glabel=$(smart_group_label "$gd")
        echo -ne "  ${R}Delete group [${glabel}] and all its tunnels? Type 'yes' to confirm: ${NC}"; read -r confirm
        [ "$confirm" == "yes" ] || continue
        echo -e "  ${C}⟳${NC} Deleting group [${glabel}] on Foreign & Iran..."
        if flock -x -w 60 -o "$gd/.smart.lock" "$INSTALL_PATH" --delete-group "$gid"; then
            echo -e "  ${G}✔ Group [${glabel}] deleted successfully.${NC}"
        else
            echo -e "  ${Y}⚠ Cleanup had warnings on Foreign or Iran. Check connectivity and retry if needed.${NC}"
        fi
        # Disable watchdog timer if no groups remain
        local left=0
        for gd in "$GROUP_DIR"/*; do [ -d "$gd" ] && { left=1; break; }; done
        if [ "$left" -eq 0 ]; then
            systemctl disable --now mtunnel-smart-watchdog.timer >/dev/null 2>&1 || true
            rm -f "$WATCH_SERVICE" "$WATCH_TIMER"
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        sleep 1.8
    done
}

smart_benchmark_menu() {
    smart_select_group_interactive || return
    local gd="$SELECTED_GROUP_DIR"
    smart_benchmark_group "$gd"
    smart_header
    smart_show_ranking_file "$gd/ranking.tsv"
    smart_pause
}
smart_prerequisites_screen() {
    smart_header
    echo -e "\n  ${FR}┌─[ INSTALL PREREQUISITES ]${NC}"
    echo -e "  ${FR}│${NC} ${W}Run this option on BOTH Iran and Foreign before pairing.${NC}"
    echo -e "  ${FR}│${NC} ${DIM}Smart installs only what it needs:${NC}"
    echo -e "  ${FR}│${NC}   ${C}engines/${NC}  ${DIM}→ Backhaul + Rathole engine for this CPU${NC}"
    echo -e "  ${FR}│${NC}   ${C}prereqs/${NC}  ${DIM}→ only missing Smart system packages${NC}"
    echo -e "  ${FR}│${NC} ${DIM}No tunnel scripts or unrelated engines are downloaded here.${NC}"
    echo -e "  ${FR}└────────────────────────────────────────────────────────────${NC}"
}

# Option 1: prerequisites only (no pairing).
smart_prereq_menu() {
    smart_prerequisites_screen
    if smart_prereqs_ready; then
        echo -e "\n  ${G}✔ All Smart prerequisites are already installed on this server.${NC}"
        smart_pause; return 0
    fi
    smart_dependency_source_menu || return 0
    echo -e "\n  ${C}⟳${NC} ${W}Checking and installing Smart prerequisites...${NC}"
    smart_install_smart_prerequisites "$SMART_DEP_SOURCE"
    smart_pause
}

# Option 3 (Iran): enter Foreign IPv4 + Pair Code, then continue straight into group creation.
smart_iran_pair_and_group() {
    local ans
    if smart_peer_load; then
        echo -ne "\n  ${Y}Already paired with ${SMART_F4}. Pair again with a new Pair Code? [y/N]: ${NC}"; read -r ans
        case "${ans,,}" in y|yes) smart_pair_controller || return 1;; esac
    else
        smart_pair_controller || return 1
    fi
    echo -e "\n  ${C}⟳${NC} ${W}Continuing to group creation...${NC}"; sleep 1
    smart_create_group
}

smart_menu() {
    local opt
    while true; do
        smart_header
        echo -e "\n  ${FR}┌─[ PROVISION & MANAGE ]${NC}"
        echo -e "  ${FR}│${NC}"
        echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${Y}Install Prerequisites${NC} ${DIM}(Iran + Foreign)${NC}"
        echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Foreign: Create Pair Code${NC}"
        echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Iran: Enter Pair Code & Create Group${NC}"
        echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Create Another Smart Group${NC}"
        echo -e "  ${FR}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Groups, Tunnels & Ports${NC}"
        echo -e "  ${FR}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Ports & Forwarding${NC}"
        echo -e "  ${FR}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${M}Benchmark & Ranking${NC}"
        echo -e "  ${FR}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${W}Peer & Agent Status${NC}"
        echo -e "  ${FR}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${G}Update & Local Install${NC}$(smart_update_badge)"
        echo -e "  ${FR}├─${NC} ${W}10${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC}"
        echo -e "  ${FR}└─${NC} ${W}11${NC} ${DIM}❯${NC} ${R}Delete Smart Groups${NC}"
        echo -e "  ${FR}────────────────────────────${NC}"
        echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}"
        echo -ne "\n  ${C}MSMART ❯❯ ${NC}"; read -r opt
        opt="${opt// /}"; opt="${opt//$'\\r'/}"
        case "$opt" in
            1) smart_prereq_menu;;
            2) smart_foreign_setup;;
            3) smart_iran_pair_and_group;;
            4) smart_create_group;;
            5) smart_list_overview;;
            6) smart_manage_ports;;
            7) smart_benchmark_menu;;
            8) smart_info;;
            9) smart_update_menu;;
            10) smart_menu_delete_tunnels;;
            11) smart_menu_delete_groups;;
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
        smart_sync_foreign_state "$gd" delete
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
    --sync-ports) smart_sync_group_ports_locked "${2:-}" "${3:-}"; exit $?;;
    --delete-tunnel) smart_delete_single_tunnel_locked "${2:-}" "${3:-}"; exit $?;;
    --delete-group) smart_delete_group_locked "${2:-}"; exit $?;;
    --delete-groups) smart_delete_groups; exit $?;;
    --pair-window-cleanup) smart_pair_window_cleanup; exit $?;;
    --agent-daemon) smart_agent_daemon; exit $?;;
    --watchdog-once) smart_watchdog_once; exit $?;;
    --version|-V) echo "MTunnel Smart $MODULE_VERSION build $MODULE_BUILD"; exit 0;;
    --pair-decode) smart_pair_decode "${2:-}" && printf 'IPv6=%s\nPort=%s\nFingerprint=%s\nExpires=%s\n' "$PAIR_IP6" "$PAIR_PORT" "$PAIR_FP" "$PAIR_EXPIRES"; exit $?;;
    --help|-h) echo 'Usage: msmart [--version|--agent-daemon|--watchdog-once|--benchmark-group GID|--delete-group GID|--delete-groups|--pair-window-cleanup]'; exit 0;;
esac
if [ "$#" -eq 0 ]; then
    smart_auto_prepare_dependencies || true
fi
smart_menu
