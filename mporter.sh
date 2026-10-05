#!/bin/bash
# --- MDesign Modular Core (mporter.sh) | MPorter Manager v12.0.2 ---
# [Features: State Controller | Smart Loadbalancing | Failover | L4 Health | Safe OBFS | BBR/MSS Optimized]
#
# v12.0.2 changelog (IPv6 awareness, in sync with mgre 6.4 / mxlan 2.2)
#  - IPv6 targets everywhere: HAProxy / Gost / Realm / Kernel NAT (ip6tables) / OBFS / health probes
#  - New tunnel interface families recognised: GRE6 / 6to4 (g6*), IPIP4>4 (i4*), IPIP4>6 (i46*), IPIP6>6 (i66*), VXLAN over IPv6
#  - Peer discovery understands IPv6 cores (ipip6to6 CORE_V6, 6to4 inner peer, ip -6 neighbours)
#  - Header shows the host's IPv6, target columns widened for IPv6 addresses
#
# v11.1 changelog (bugfix release over v10.0.0)
#  - Added missing edit_mapping (menu 5): remove single port / disable OBFS / add ports
#  - Headless flags (--health-scan, --purge-ip, ...) no longer run installer/update side effects
#  - OBFS runner is never executed in the foreground (menu no longer hangs) -> systemctl restart
#  - Purge now really finds HAProxy / Realm / Gost / KernelNAT entries (exact IP match, no regex dots)
#  - HAProxy: explicit "mode tcp", Debian default http config replaced on install, validate+rollback on every change
#  - Loadbalance keeps existing pools, never duplicates frontends, managed markers are never eaten by purge
#  - Auto-distribute really round-robins peers; OBFS uses the exact same target as the mapping
#  - OBFS works for Kernel NAT (PREROUTING redirect), HAProxy OBFS listener bound to 127.0.0.1
#  - State: locked writes, reconcile keeps interface/pool/obfs metadata, orphan detection fixed
#  - Peer discovery keeps priority order and only accepts peers routed via the selected interface
#  - MSS clamp persisted and re-applied on boot / by watchdog
#  - No more dpkg lock deletion, no apt killed by timeouts, TLS verification on downloads, binary self-test
#  - Input validation for IPs, hosts and ports (no command injection into generated scripts)
#  - Tunnel .conf files are parsed, never sourced
#  - Wipe/Nuclear clean state, FORWARD rules, helper scripts; UI border fixes

MODULE_VERSION="12.0.2"

# BEGIN MTUNNEL SHARED HELPERS
# Internal helpers; each distributed script contains its own copy.
# Sourcing this file performs no network, filesystem, or service operations.

mt_normalize_host() {
    local host="$1"
    if [[ "$host" == \[*\] ]]; then host="${host:1:${#host}-2}"; fi
    printf '%s' "$host"
}

mt_valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

mt_valid_ipv4() {
    local part; local -a octets=()
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -ra octets <<< "$1"
    for part in "${octets[@]}"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] && ((10#$part <= 255)) || return 1
    done
}

mt_valid_ipv6() {
    local ip tail group rest count=0 extra=0
    ip=$(mt_normalize_host "$1")
    if [[ "$ip" == *%* ]]; then
        [[ "${ip#*%}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
        ip="${ip%%\%*}"
    fi
    [[ "$ip" == *:* ]] || return 1
    if [[ "$ip" == *.* ]]; then
        tail="${ip##*:}"; mt_valid_ipv4 "$tail" || return 1
        ip="${ip%:*}:0:0"
    fi
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" != *:::* ]] || return 1
    [[ "$ip" != :* || "$ip" == ::* ]] || return 1
    [[ "$ip" != *: || "$ip" == *:: ]] || return 1
    rest="${ip/::/}"
    [[ "$rest" != *::* ]] || return 1
    if [[ "$ip" != *::* ]]; then
        [[ "$ip" != :* && "$ip" != *: ]] || return 1
    fi
    local -a groups=()
    IFS=: read -ra groups <<< "$ip"
    for group in "${groups[@]}"; do
        [ -z "$group" ] && continue
        [[ "$group" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        ((count+=1))
    done
    if [[ "$ip" == *::* ]]; then ((count < 8)); else ((count == 8)); fi
}

mt_valid_host() {
    local host label
    host=$(mt_normalize_host "$1")
    [[ "$1" != \[*\] ]] || [[ "$host" == *:* ]] || return 1
    [ -n "$host" ] && [ "${#host}" -le 253 ] || return 1
    if [[ "$host" == *:* ]]; then mt_valid_ipv6 "$host"; return; fi
    if [[ "$host" =~ ^[0-9.]+$ ]]; then mt_valid_ipv4 "$host"; return; fi
    host="${host%.}"
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ && "$host" != *..* ]] || return 1
    local -a labels=()
    IFS=. read -ra labels <<< "$host"
    for label in "${labels[@]}"; do
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] && [ "${#label}" -le 63 ] || return 1
    done
}

mt_hostport() {
    local host; host=$(mt_normalize_host "$1")
    if [[ "$host" == *:* ]]; then printf '[%s]:%s' "$host" "$2"; else printf '%s:%s' "$host" "$2"; fi
}

mt_valid_index() {
    [[ "$1" =~ ^[0-9]{1,8}$ ]] && ((10#$1 < $2))
}

mt_is_newer_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$2" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]
}

mt_ask_bind_host() {
    local choice host
    echo -e "\n  ${DIM}┌─[ SERVER LISTEN ADDRESS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}IPv4${NC} ${DIM}(0.0.0.0)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}IPv6${NC} ${DIM}(::)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Specific IP${NC}"
    echo -ne "  ${C}Select Address [1] ❯❯ ${NC}"; read -r choice
    case "${choice:-1}" in
        1) MT_BIND_HOST='0.0.0.0';;
        2) MT_BIND_HOST='::';;
        3) echo -ne "  ${C}●${NC} ${W}Listen IP: ${NC}"; read -r host
           host=$(mt_normalize_host "$host")
           mt_valid_ipv4 "$host" || mt_valid_ipv6 "$host" || return 1
           MT_BIND_HOST="$host";;
        *) return 1;;
    esac
}

mt_tcp_probe() {
    local host; host=$(mt_normalize_host "$1")
    mt_valid_host "$host" && mt_valid_port "$2" || return 1
    timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$2" 2>/dev/null
}

mt_list_has_port() {
    local item; local -a parts=()
    IFS=, read -ra parts <<< "$1"
    for item in "${parts[@]}"; do
        [[ "$item" == *"="* ]] && item="${item%%=*}"
        [[ "$item" == *:* ]] && item="${item##*:}"
        mt_valid_port "$item" && ((10#$item == 10#$2)) && return 0
    done
    return 1
}

mt_port_busy() {
    local port="$1" proto="${2:-both}" opts='-Hln'
    mt_valid_port "$port" || return 1
    case "$proto" in tcp) opts+='t';; udp) opts+='u';; *) opts+='tu';; esac
    ss "$opts" 2>/dev/null | awk -v p="$((10#$port))" '
        { for (i=1;i<=NF;i++) if ($i ~ /:[0-9]+$/) {n=$i;sub(/^.*:/,"",n);if(n+0==p) found=1;break} }
        END {exit !found}'
}

mt_validate_port_list() {
    local list="$1" check="$2" proto="${3:-both}" owned="${4:-}" item
    local -A seen=(); local -a parts=()
    [ -z "$list" ] && return 0
    [[ "$list" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
    IFS=, read -ra parts <<< "$list"
    for item in "${parts[@]}"; do
        mt_valid_port "$item" || return 1
        item=$((10#$item)); [ -z "${seen[$item]:-}" ] || return 1; seen[$item]=1
        if [ "$check" == 1 ] && ! mt_list_has_port "$owned" "$item" && mt_port_busy "$item" "$proto"; then return 1; fi
    done
}

mt_validate_script() {
    local file="$1" version
    [ -s "$file" ] && head -n 1 "$file" | grep -qE '^#!(/bin/bash|/usr/bin/env bash)$' || return 1
    bash -n "$file" || return 1
    version=$(sed -n 's/^MODULE_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$file")
    [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}

mt_download() {
    local url="$1" dest="$2" expected="${3:-}" tmp rc=1
    [[ "$url" == https://* ]] || { echo 'Download requires HTTPS.' >&2; return 1; }
    tmp=$(mktemp "${dest}.download.XXXXXX") || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 --retry 2 -o "$tmp" "$url" && rc=0
    elif command -v wget >/dev/null 2>&1; then
        wget -q --https-only --timeout=30 --tries=2 -O "$tmp" "$url" && rc=0
    fi
    if [ "$rc" != 0 ] || [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
    if [ -n "$expected" ]; then
        [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] && [ "$(sha256sum "$tmp" | cut -d' ' -f1)" == "${expected,,}" ] || { rm -f "$tmp"; return 1; }
    fi
    mv -f "$tmp" "$dest"
}

# Stage all destinations first. Roll back every committed file if a rename fails.
mt_install_files() {
    local mode="$1"; shift
    local src dest stage backup i j rc=0
    local -a stages=() backups=() destinations=() existed=()
    [ "$(( $# % 2 ))" == 0 ] || return 1
    while [ "$#" -gt 0 ]; do
        src="$1"; dest="$2"; shift 2
        mkdir -p "$(dirname "$dest")" || { rc=1; break; }
        stage=$(mktemp "${dest}.stage.XXXXXX") || { rc=1; break; }
        stages+=("$stage"); destinations+=("$dest"); backups+=(""); existed+=(0)
        i=$((${#stages[@]}-1))
        if ! cat "$src" > "$stage" || ! chmod "$mode" "$stage"; then rc=1; break; fi
        if [ -e "$dest" ] || [ -L "$dest" ]; then
            backup=$(mktemp "${dest}.rollback.XXXXXX") || { rc=1; break; }
            backups[$i]="$backup"; existed[$i]=1
            rm -f "$backup"
            if ! cp -p --no-dereference "$dest" "$backup"; then rc=1; break; fi
        fi
    done
    if [ "$rc" == 0 ]; then
        for i in "${!destinations[@]}"; do
            if ! mv -f "${stages[$i]}" "${destinations[$i]}"; then
                rc=1
                for ((j=i-1;j>=0;j--)); do
                    if [ "${existed[$j]}" == 1 ]; then mv -f "${backups[$j]}" "${destinations[$j]}"; else rm -f "${destinations[$j]}"; fi
                done
                break
            fi
        done
    fi
    for stage in "${stages[@]}" "${backups[@]}"; do [ -n "$stage" ] && rm -f "$stage"; done
    return "$rc"
}

mt_install_script() {
    local candidate="$1" rel="$2" target="$3" current="${4:-}"; local -a files=()
    mt_validate_script "$candidate" || return 1
    if mt_validate_script "$target" 2>/dev/null; then
        local current_version new_version
        current_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$target")
        new_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$candidate")
        if mt_is_newer_version "$current_version" "$new_version"; then echo 'Refusing to replace a newer installed module.' >&2; return 1; fi
    fi
    files+=("$candidate" "$target")
    [ "$LOCAL_DIR/$rel" == "$target" ] || files+=("$candidate" "$LOCAL_DIR/$rel")
    if [ -f "$current" ] && [ "$(readlink -f "$current")" != "$(readlink -f "$target")" ] && [ "$current" != "$LOCAL_DIR/$rel" ]; then files+=("$candidate" "$current"); fi
    mt_install_files 755 "${files[@]}"
}

mt_valid_elf() {
    local file="$1" machine arch
    [ -f "$file" ] && [ "$(wc -c < "$file")" -gt 4096 ] || return 1
    [ "$(od -An -tx1 -N4 "$file" | tr -d ' \n')" == 7f454c46 ] || return 1
    machine=$(od -An -tu2 -j18 -N2 "$file" | tr -d ' \n'); arch=$(uname -m)
    case "$arch:$machine" in x86_64:62|aarch64:183|arm64:183|armv7l:40|i686:3) return 0;; esac
    return 1
}

mt_extract_archive() {
    local archive="$1" dest="$2" list entry
    list=$(mktemp "$dest/.entries.XXXXXX") || return 1
    if tar -tzf "$archive" > "$list" 2>/dev/null; then
        while IFS= read -r entry; do
            case "/$entry/" in *'/../'*|*'/./../'*|//*|*'\\'*) rm -f "$list"; return 1;; esac
        done < "$list"
        # Reject symlinks, hard links and devices before extraction.
        if tar -tvzf "$archive" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit !bad}'; then rm -f "$list"; return 1; fi
        rm -f "$list"
        tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$dest"
    elif command -v unzip >/dev/null 2>&1 && unzip -Z1 "$archive" > "$list" 2>/dev/null; then
        while IFS= read -r entry; do
            case "/$entry/" in *'/../'*|//*|*'\\'*|*':'*) rm -f "$list"; return 1;; esac
        done < "$list"
        if unzip -Z -l "$archive" | awk '$1 ~ /^[lbcps]/ {bad=1} END {exit !bad}'; then rm -f "$list"; return 1; fi
        rm -f "$list"; unzip -q "$archive" -d "$dest"
    else rm -f "$list"; return 1; fi
}

mt_counter_sum() {
    awk -v tag="$2" '{for(i=1;i<=NF;i++) if($i==tag){sum+=$2;break}} END {printf "%.0f\n",sum}' <<< "$1"
}

mt_setup_counter_pair() {
    local prefix="$1" name="$2" port="$3" remote="$4" role="$5" bind="${6:-0.0.0.0}" bin addr family
    local -a addresses=() input=() output=()
    mt_valid_port "$port" || return 1
    if [ "$role" == 1 ]; then
        input=(--dport "$port"); output=(--sport "$port")
        if [[ "$bind" == *:* ]]; then addresses=('::'); else addresses=('0.0.0.0'); fi
    else
        remote=$(mt_normalize_host "$remote")
        mt_valid_host "$remote" || return 1
        if mt_valid_ipv4 "$remote" || mt_valid_ipv6 "$remote"; then addresses=("$remote")
        else mapfile -t addresses < <({ getent ahostsv4 "$remote"; getent ahostsv6 "$remote"; } 2>/dev/null | awk '{print $1}' | sort -u); fi
    fi
    # IPv6 wildcard sockets may also accept IPv4 on Linux; count both families.
    if [ "$role" == 1 ] && [ "$bind" == '::' ]; then addresses+=('0.0.0.0'); fi
    for addr in "${addresses[@]}"; do
        bin=iptables; [[ "$addr" == *:* ]] && bin=ip6tables
        command -v "$bin" >/dev/null 2>&1 || continue
        if [ "$role" != 1 ]; then input=(-s "$addr" --sport "$port"); output=(-d "$addr" --dport "$port"); fi
        "$bin" -w 5 -t mangle -C INPUT -p tcp "${input[@]}" -m comment --comment "${prefix}_RX_${name}" 2>/dev/null ||
            "$bin" -w 5 -t mangle -A INPUT -p tcp "${input[@]}" -m comment --comment "${prefix}_RX_${name}" || return 1
        "$bin" -w 5 -t mangle -C OUTPUT -p tcp "${output[@]}" -m comment --comment "${prefix}_TX_${name}" 2>/dev/null ||
            "$bin" -w 5 -t mangle -A OUTPUT -p tcp "${output[@]}" -m comment --comment "${prefix}_TX_${name}" || return 1
    done
}

mt_tagged_rules() {
    local bin="$1" table="$2" chain="$3" tag="$4" match="${5:-exact}"
    "$bin" -t "$table" -L "$chain" -n --line-numbers 2>/dev/null |
        awk -v tag="$tag" -v m="$match" '$1 ~ /^[0-9]+$/ {
            if(m=="substring" && index($0,tag)) {print $1;next}
            for(i=1;i<=NF;i++) if($i==tag || (m=="prefix" && index($i,tag)==1)){print $1;break}
        }' | sort -rn
}

mt_delete_tagged_rules() {
    local bin="$1" table="$2" chain="$3" tag="$4" match="${5:-exact}" num
    while read -r num; do [ -n "$num" ] && "$bin" -w 5 -t "$table" -D "$chain" "$num" || return 1; done < <(mt_tagged_rules "$bin" "$table" "$chain" "$tag" "$match")
    return 0
}

mt_milliseconds() { awk '{printf "%.0f\n", $1*1000}' /proc/uptime; }
mt_rate() { local delta=$(($1-$2)); [ "$delta" -lt 0 ] && delta=0; local ms="$3"; [ "$ms" -gt 0 ] || ms=1; echo "$((delta*1000/ms))"; }

mt_tunnel_addresses() {
    local subnet
    MT_LOCAL_PUBLIC="${LOCAL_PUB:-}"; MT_REMOTE_PUBLIC="${REMOTE_PUB:-}"
    case "${TUN_PROTO:-ipv4}" in gre6|ipip4to6|ipip6to6) MT_LOCAL_PUBLIC="${LOCAL_PUB6:-${LOCAL_IP6:-}}"; MT_REMOTE_PUBLIC="${REMOTE_PUB6:-${REMOTE_IP6:-}}";; esac
    if [ "${FAB_PROTO:-ipv4}" == ipv6 ]; then MT_LOCAL_PUBLIC="${LOCAL_PUB6:-}"; MT_REMOTE_PUBLIC="${REMOTE_PUB6:-}"; fi
    if [ "${TUN_PROTO:-}" == ipip6to6 ]; then
        [ -n "${CORE_V6:-}" ] || return 1
        if [ "${TYPE:-}" == 1 ]; then MT_CORE_LOCAL="${CORE_V6}::1"; MT_CORE_PEER="${CORE_V6}::2"
        else MT_CORE_LOCAL="${CORE_V6}::2"; MT_CORE_PEER="${CORE_V6}::1"; fi
    else
        subnet="${CORE_SUBNET:-10.76.${TUN_ID:-}}"
        [ -z "${VNI_ID:-}" ] || subnet="${CORE_SUBNET:-10.88.$VNI_ID}"
        if [ "${TYPE:-}" == 1 ]; then MT_CORE_LOCAL="${subnet}.1"; MT_CORE_PEER="${subnet}.2"
        else MT_CORE_LOCAL="${subnet}.2"; MT_CORE_PEER="${subnet}.1"; fi
    fi
    mt_valid_ipv4 "$MT_CORE_PEER" || mt_valid_ipv6 "$MT_CORE_PEER"
}

mt_validate_conf() {
    local file="$1" line key value
    [ -s "$file" ] && bash -n "$file" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^[A-Z][A-Z0-9_]*= ]] || return 1
        key="${line%%=*}"; value="${line#*=}"
        case "$key" in TYPE|LOCAL_PUB|REMOTE_PUB|LOCAL_PUB6|REMOTE_PUB6|MAX_IPS|SYNC_KEY|TUN_SECRET|T_NAME|TUN_ID|CORE_SUBNET|CORE_V6|TUN_PROTO|LOCAL_IP6|REMOTE_IP6|REMOTE_V4|FWD_TCP|FWD_UDP|LB_MODE|CUSTOM_MTU|ENCRYPT|VNI_ID|BR_NAME|VX_NAME|FAB_PROTO) ;; *) return 1;; esac
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
        [[ "$value" =~ ^[A-Za-z0-9_:./=,+%-]*$ ]] || return 1
    done < "$file"
}

mt_stage_backup() {
    local archive="$1" subdir="$2" stage conf found=0
    stage=$(mktemp -d "$SECURE_TMP/restore.XXXXXX") || return 1
    if ! mt_extract_archive "$archive" "$stage" || [ ! -d "$stage/$subdir" ]; then rm -rf "$stage"; return 1; fi
    while IFS= read -r conf; do
        case "$conf" in "$stage/$subdir/"*.conf) ;; *) rm -rf "$stage"; return 1;; esac
        if [ "$(dirname "$conf")" != "$stage/$subdir" ] || ! mt_validate_conf "$conf"; then rm -rf "$stage"; return 1; fi
        found=1
    done < <(find "$stage" -type f)
    [ "$found" == 1 ] || { rm -rf "$stage"; return 1; }
    printf '%s\n' "$stage"
}

# Keep the running executable until the candidate has been downloaded and checked.
mt_update_core() {
    local name="$1" unit_prefix="$2" source="$3" kind="${4:-url}" expected="${5:-}" work candidate item unit failed=0 had_old=0
    local target="${MTUNNEL_TEST_ROOT:-}/usr/local/bin/$name" alias="${MTUNNEL_TEST_ROOT:-}/usr/bin/$name"; local -a active=()
    work=$(mktemp -d "$SECURE_TMP/core.XXXXXX") || return 1
    if [ "$kind" == local ]; then
        cp "$source" "$work/download" || { rm -rf "$work"; return 1; }
    else
        mt_download "$source" "$work/download" "$expected" || { rm -rf "$work"; return 1; }
    fi
    candidate="$work/download"
    if ! mt_valid_elf "$candidate"; then
        mkdir "$work/extracted"
        mt_extract_archive "$candidate" "$work/extracted" || { rm -rf "$work"; return 1; }
        candidate=''
        while IFS= read -r item; do
            if mt_valid_elf "$item"; then
                [ -z "$candidate" ] || { echo 'Archive contains multiple candidate executables.' >&2; rm -rf "$work"; return 1; }
                candidate="$item"
            fi
        done < <(find "$work/extracted" -type f -name "*$name*")
        if [ "$name" == bh ] && [ -z "$candidate" ]; then
            item="$work/extracted/backhaul"; mt_valid_elf "$item" && candidate="$item"
        fi
        [ -n "$candidate" ] || { rm -rf "$work"; return 1; }
    fi
    if [ ! -f "$target" ] && [ -f "$alias" ]; then
        mkdir -p "$(dirname "$target")" && cp -pL "$alias" "$target" || { rm -rf "$work"; return 1; }
    fi
    if [ -f "$target" ]; then cp -pL "$target" "$work/previous" || { rm -rf "$work"; return 1; }; had_old=1; fi
    mapfile -t active < <(systemctl list-units --type=service --state=active --no-legend --plain "${unit_prefix}@*.service" "${unit_prefix}.service" 2>/dev/null | awk '{print $1}')
    if ! mt_install_files 755 "$candidate" "$target" "$candidate" "$alias"; then rm -rf "$work"; return 1; fi
    for unit in "${active[@]}"; do
        systemctl restart "$unit" && systemctl is-active --quiet "$unit" || failed=1
    done
    if [ "$failed" == 1 ]; then
        if [ "$had_old" == 1 ]; then
            mt_install_files 755 "$work/previous" "$target" "$work/previous" "$alias" || echo 'Failed to restore the previous core!' >&2
            for unit in "${active[@]}"; do systemctl restart "$unit"; done
        else rm -f "$target" "$alias"; fi
        rm -rf "$work"; return 1
    fi
    rm -rf "$work"
}

# A backup must have a coherent network identity before any live teardown.
mt_validate_tunnel_conf() {
    local conf="$1" kind="$2"
    local TYPE='' T_NAME='' VX_NAME='' BR_NAME='' TUN_ID='' VNI_ID='' CORE_SUBNET='' CORE_V6='' TUN_PROTO=ipv4 FAB_PROTO=ipv4 LOCAL_PUB='' REMOTE_PUB='' LOCAL_PUB6='' REMOTE_PUB6='' LOCAL_IP6='' REMOTE_IP6='' CUSTOM_MTU='' MAX_IPS=0 ENCRYPT=0 TUN_SECRET='' SYNC_KEY='' FWD_TCP='' FWD_UDP=''
    mt_validate_conf "$conf" || return 1
    source "$conf"
    [[ "$TYPE" =~ ^[12]$ && "$MAX_IPS" =~ ^[0-9]{1,4}$ && "$ENCRYPT" =~ ^[01]$ ]] || return 1
    [ -z "$CUSTOM_MTU" ] || { [[ "$CUSTOM_MTU" =~ ^[0-9]{3,5}$ ]] && ((10#$CUSTOM_MTU >= 512 && 10#$CUSTOM_MTU <= 65535)); } || return 1
    if [ "$kind" == gre ]; then
        [[ "$T_NAME" =~ ^[A-Za-z0-9_.-]{1,15}$ && "$TUN_ID" =~ ^[0-9]{1,9}$ && "$TUN_PROTO" =~ ^(ipv4|6to4|gre6|ipip4to4|ipip4to6|ipip6to6)$ ]] || return 1
        case "$TUN_PROTO" in
            gre6|ipip4to6|ipip6to6) mt_valid_ipv6 "${LOCAL_PUB6:-$LOCAL_IP6}" && mt_valid_ipv6 "${REMOTE_PUB6:-$REMOTE_IP6}" || return 1;;
            *) mt_valid_ipv4 "$LOCAL_PUB" && mt_valid_ipv4 "$REMOTE_PUB" || return 1;;
        esac
        if [ "$TUN_PROTO" == ipip6to6 ]; then mt_valid_ipv6 "$CORE_V6::1" || return 1
        else mt_valid_ipv4 "$CORE_SUBNET.1" || return 1; fi
        if [ "$TUN_PROTO" == 6to4 ]; then mt_valid_ipv6 "$LOCAL_IP6" && mt_valid_ipv6 "$REMOTE_IP6" || return 1; fi
    else
        [[ "$VX_NAME" =~ ^[A-Za-z0-9_.-]{1,15}$ && "$BR_NAME" =~ ^[A-Za-z0-9_.-]{1,15}$ && "$VNI_ID" =~ ^[0-9]{1,8}$ && "$FAB_PROTO" =~ ^(ipv4|ipv6)$ ]] && ((10#$VNI_ID >= 1 && 10#$VNI_ID <= 16777215)) || return 1
        mt_valid_ipv4 "$CORE_SUBNET.1" || return 1
        if [ "$FAB_PROTO" == ipv6 ]; then mt_valid_ipv6 "$LOCAL_PUB6" && mt_valid_ipv6 "$REMOTE_PUB6" || return 1
        else mt_valid_ipv4 "$LOCAL_PUB" && mt_valid_ipv4 "$REMOTE_PUB" || return 1; fi
    fi
    mt_validate_port_list "$FWD_TCP" 0 tcp && mt_validate_port_list "$FWD_UDP" 0 udp || return 1
    [ "$ENCRYPT" != 1 ] || [[ "${TUN_SECRET:-$SYNC_KEY}" =~ ^[A-Za-z0-9_=-]+$ ]]
}

mt_valid_scope() {
    case "$1" in all|gre|vxlan|rathole|backhaul|paqet) return 0;; *) return 1;; esac
}

mt_run_tool() {
    local name="$1" path; shift
    case "$name" in mbbr|minterface|mhealer) ;; *) return 1;; esac
    for path in "${MTUNNEL_TEST_ROOT:-}/usr/bin/$name" "${LOCAL_DIR:-/root/mtunnel}/tools/$name.sh"; do
        if [ -f "$path" ] && mt_validate_script "$path"; then
            bash "$path" "$@"
            return $?
        fi
    done
    echo -e "  ${R}✖ ${name} is missing. Use Update and Local Install to install all scripts.${NC}" >&2
    return 1
}

mt_ask_bbr_on_create() {
    local answer
    echo -e "\n  ${DIM}● BBR changes TCP congestion control for the entire server.${NC}"
    echo -ne "  ${C}●${NC} ${W}Enable BBR now? [y/N]: ${NC}"
    read -r answer || answer=''
    case "${answer,,}" in
        y|yes)
            mt_run_tool mbbr --enable || echo -e "  ${Y}● BBR could not be enabled; the tunnel configuration is retained.${NC}" >&2;;
        *) ;;
    esac
    return 0
}

mt_render_tunnel_tools() {
    local iface="$1" healer="$2" bbr="$3" recovery_label='Autonomous Tunnel Healer'
    case "${4:-}" in gre|vxlan) recovery_label='Watchdog & Tunnel Healer';; esac
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ TUNNEL TOOLS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}${iface}${NC}${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC}"
    echo -e "  ${DIM}├─${NC} ${W}${healer}${NC}${DIM}❯${NC} ${G}${recovery_label}${NC}"
    echo -e "  ${DIM}├─${NC} ${W}${bbr}${NC}${DIM}❯${NC} ${G}TCP BBR Accelerator${NC} ${DIM}(Entire Server)${NC}"
}

mt_menu_tunnel_recovery() {
    local kind="$1" header="$2" choice
    case "$kind" in gre|vxlan) ;; *) return 1;; esac
    while true; do
        "$header"
        echo -e "\n  ${DIM}┌─[ WATCHDOG & TUNNEL HEALER ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Watchdog: Auto-Heal + LB Health${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Autonomous Tunnel Healer${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Menu${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"
        read -r choice || return 0
        case "${choice//$'\r'/}" in
            1) menu_watchdog;;
            2) mt_run_tool mhealer --scope "$kind";;
            0|q|Q) return 0;;
        esac
    done
}

mt_config_value() {
    local key="$1" file="$2" value
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    value=$(sed -n "s/^${key}=//p" "$file" | head -n 1)
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
    printf '%s' "$value"
}

# END MTUNNEL SHARED HELPERS
if [ "$EUID" != 0 ]; then echo "Run MTunnel with sudo." >&2; exit 1; fi











B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mporter"
SERVICE_FILE="/etc/systemd/system/mporter.service"
H_CONF="/etc/haproxy/haproxy.cfg"
G_CONF="/etc/gost/config.json"
R_CONF="/etc/realm/config.json"
OBFS_DIR="/etc/mporter/obfs_rules"
IPT_DIR="/etc/mporter/iptables_core"
IPT_CONF="$IPT_DIR/rules.sh"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
STATE_DIR="/etc/mporter"
STATE_FILE="$STATE_DIR/state.json"
MSS_FILE="$STATE_DIR/mss_ifaces"
HEALTH_FILE="/run/mporter-backends.tsv"
LOCK_FILE="/var/lock/mporter-state.lock"
LB_MARKER="# === MPORTER_V10_MANAGED ==="
LB_END_MARKER="# === MPORTER_V10_MANAGED_END ==="
WATCHDOG_SERVICE="mporter-watchdog.service"
WATCHDOG_SCRIPT="/usr/local/bin/mporter-watchdog.sh"
APT_OPTS=(-o Acquire::ForceIPv4=true -o DPkg::Lock::Timeout=180 -y -q)

MP_HEADLESS=false
case "${1:-}" in --health-scan|--state-sync|--purge-ip|--cleanup-orphans|--boot-apply) MP_HEADLESS=true ;; esac

if [ "$(id -u)" -ne 0 ] && [ "${MPORTER_LIB:-0}" != "1" ]; then echo "MPorter must be run as root."; exit 1; fi

mkdir -p "$LOCAL_DIR/packages" /etc/haproxy /var/lib/haproxy /etc/gost /etc/realm "$OBFS_DIR" "$IPT_DIR" "$STATE_DIR" /usr/local/bin "$SECURE_TMP" /var/lock 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null
touch "$IPT_CONF" 2>/dev/null; chmod +x "$IPT_CONF" 2>/dev/null

if [ "$MP_HEADLESS" = false ] && [ -f "$0" ] && [ "$(readlink -f "$0")" != "$(readlink -f "$INSTALL_PATH" 2>/dev/null)" ]; then
    if bash -n "$0" 2>/dev/null; then
        cp -f "$0" "$INSTALL_PATH.new.$$" 2>/dev/null && chmod +x "$INSTALL_PATH.new.$$" && mv -f "$INSTALL_PATH.new.$$" "$INSTALL_PATH" 2>/dev/null
        rm -f "$INSTALL_PATH.new.$$" 2>/dev/null
    fi
fi

# ==========================================================
# Generic helpers
# ==========================================================

mp_tmp() { mktemp "$SECURE_TMP/${1:-mp}.XXXXXX"; }

valid_ipv4() {
    local ip="$1" o a b c d
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    for o in "$a" "$b" "$c" "$d"; do [ "$((10#$o))" -le 255 ] 2>/dev/null || return 1; done
    return 0
}

valid_ipv6() {
    local ip="${1,,}" g n=0 f=0 dbl=0 rest
    local -a parts
    [ -n "$ip" ] && [ "${#ip}" -le 39 ] || return 1
    [[ "$ip" =~ ^[0-9a-f:]+$ ]] || return 1
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" == *:::* ]] && return 1
    if [[ "$ip" == *::* ]]; then rest="${ip#*::}"; [[ "$rest" == *::* ]] && return 1; dbl=1; fi
    [[ "$ip" == :* && "$ip" != ::* ]] && return 1
    [[ "$ip" == *: && "$ip" != *:: ]] && return 1
    IFS=':' read -ra parts <<< "$ip"
    for g in "${parts[@]}"; do
        f=$((f+1)); [ -z "$g" ] && continue
        [ "${#g}" -le 4 ] || return 1
        n=$((n+1))
    done
    if [ "$dbl" -eq 1 ]; then [ "$n" -le 7 ] || return 1; else { [ "$n" -eq 8 ] && [ "$f" -eq 8 ]; } || return 1; fi
    return 0
}
# IPv4 or IPv6 literal
valid_ip() { valid_ipv4 "$1" || valid_ipv6 "$1"; }
is_v6() { [[ "$1" == *:* ]]; }
# Usable as a forwarding target (not link-local / unspecified / multicast)
valid_target_ip() {
    valid_ipv4 "$1" && return 0
    valid_ipv6 "$1" || return 1
    case "${1,,}" in ::|fe8*|fe9*|fea*|feb*|ff*) return 1 ;; esac
    return 0
}
# host:port in the notation every engine understands ([v6]:port for IPv6)
hostport() { if is_v6 "$1"; then printf '[%s]:%s' "$1" "$2"; else printf '%s:%s' "$1" "$2"; fi; }
# HAProxy server address (v6 needs the ipv6@ prefix; port is the text after the last colon)
hap_addr() { if is_v6 "$1"; then printf 'ipv6@%s:%s' "$1" "$2"; else printf '%s:%s' "$1" "$2"; fi; }
# iptables binary for a target address
ipt_bin_for() { if is_v6 "$1"; then echo ip6tables; else echo iptables; fi; }

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]; }

valid_host() {
    valid_ip "$1" && return 0
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62})(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}))+$ ]]
}

valid_iface() { [[ "$1" =~ ^[A-Za-z0-9_.@:-]{1,32}$ ]]; }

parse_ports() {
    printf '%s\n' "$1" | tr -c '0-9\n' ' ' | tr ' ' '\n' | grep -E '^[0-9]{1,5}$' | awk '{n=$1+0} n>=1 && n<=65535 {print n}' | sort -un | xargs
}

ip_to_int() { local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d )); }
int_to_ip() { local n="$1"; printf '%d.%d.%d.%d' $((n>>24&255)) $((n>>16&255)) $((n>>8&255)) $((n&255)); }
ip_in_cidr() {
    local ip="$1" net="${2%/*}" pre="${2#*/}" mask
    valid_ipv4 "$ip" && valid_ipv4 "$net" && [[ "$pre" =~ ^[0-9]+$ ]] && [ "$pre" -le 32 ] || return 1
    [ "$pre" -eq 0 ] && return 0
    mask=$(( (0xFFFFFFFF << (32-pre)) & 0xFFFFFFFF ))
    [ $(( $(ip_to_int "$ip") & mask )) -eq $(( $(ip_to_int "$net") & mask )) ]
}

route_dev() { local fam=-4; is_v6 "$1" && fam=-6; ip $fam route get "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}'; }

# Safe KEY=VALUE reader. Tunnel configs are parsed, never sourced.
read_conf_value() {
    local file="$1" key="$2" line
    line=$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null) || return 1
    line="${line#*=}"; line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    line="${line#\"}"; line="${line%\"}"; line="${line#\'}"; line="${line%\'}"
    printf '%s' "$line"
}

tunnel_conf_files() {
    local c
    for c in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf /etc/ml2tp/tunnels/*.conf /etc/mhysteria/tunnels/*.conf; do
        [ -f "$c" ] && echo "$c"
    done
}

tunnel_conf_for_iface() {
    local c
    while read -r c; do
        if [ "$(read_conf_value "$c" T_NAME)" = "$1" ] || [ "$(read_conf_value "$c" BR_NAME)" = "$1" ]; then echo "$c"; return 0; fi
    done < <(tunnel_conf_files)
    return 1
}

tunnel_ifaces() {
    local c v n
    while read -r c; do
        for v in T_NAME BR_NAME; do
            n=$(read_conf_value "$c" "$v")
            valid_iface "$n" && ip link show "$n" >/dev/null 2>&1 && echo "$n"
        done
    done < <(tunnel_conf_files) | awk 'NF && !seen[$0]++'
}

# Core-NAT forwards defined by MDesign GRE/VXLAN tunnel files: "port|ip|TUN"
tunnel_ext_entries() {
    local conf t fwd sub tid vid tip p
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf; do
        [ -f "$conf" ] || continue
        t=$(read_conf_value "$conf" TYPE); [ "$t" = "1" ] || continue
        fwd="$(read_conf_value "$conf" FWD_TCP),$(read_conf_value "$conf" FWD_UDP)"
        sub=$(read_conf_value "$conf" CORE_SUBNET); tid=$(read_conf_value "$conf" TUN_ID); vid=$(read_conf_value "$conf" VNI_ID)
        tip=""
        if [[ "$tid" =~ ^[0-9]+$ ]]; then tip="${sub:-10.76.${tid}}.2"
        elif [[ "$vid" =~ ^[0-9]+$ ]]; then tip="${sub:-10.88.${vid}}.2"; fi
        valid_ipv4 "$tip" || continue
        for p in $(parse_ports "$fwd"); do echo "$p|$tip|TUN"; done
    done
}

unit_exists() { [ -f "/etc/systemd/system/$1.service" ] || [ -f "/lib/systemd/system/$1.service" ] || [ -f "/usr/lib/systemd/system/$1.service" ]; }

setup_mporter_service() {
    local tmp_srv; tmp_srv=$(mp_tmp srv) || return 0
    cat <<EOF_SRV > "$tmp_srv"
[Unit]
Description=MPorter Port Forwarding Master Service
After=network-online.target haproxy.service gost.service realm.service mporter-iptables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH --boot-apply

[Install]
WantedBy=multi-user.target
EOF_SRV
    if ! cmp -s "$tmp_srv" "$SERVICE_FILE" 2>/dev/null; then
        chmod 644 "$tmp_srv"; mv -f "$tmp_srv" "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable mporter.service >/dev/null 2>&1
    else
        rm -f "$tmp_srv"
    fi
    systemctl is-active --quiet mporter.service 2>/dev/null || systemctl start mporter.service >/dev/null 2>&1
}

ensure_jq() {
    if command -v jq >/dev/null 2>&1 && jq -n 'null' >/dev/null 2>&1; then return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get update "${APT_OPTS[@]}" >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" jq >/dev/null 2>&1
    command -v jq >/dev/null 2>&1 && jq -n 'null' >/dev/null 2>&1
}

download_file() {
    mt_download "$1" "$2"
}

check_update_bg() {
    local cache="$SECURE_TMP/.mporter_remote_ver"
    if [ -f "$cache" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) )) -lt 3600 ]; then return 0; fi
    local cb="?t=$(date +%s)" remote_ver="" url tmp
    tmp=$(mp_tmp ver) || return 0
    for url in "https://raw.githubusercontent.com/htzserv/MTunnel/main/mporter.sh${cb}" "https://c107328.parspack.net/c107328/MTunnel/mporter.sh${cb}"; do
        if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 3 --max-time 6 -o "$tmp" "$url" 2>/dev/null
        else wget -q --timeout=6 -O "$tmp" "$url" 2>/dev/null; fi
        remote_ver=$(grep -m1 '^MODULE_VERSION=' "$tmp" 2>/dev/null | cut -d'"' -f2 | tr -cd '0-9A-Za-z.-')
        [ -n "$remote_ver" ] && break
    done
    rm -f "$tmp"
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$cache"
}

self_update_module() {
    local src_opt custom_url dl_url tmp_file confirm
    local rel_path="mporter.sh" cb="?t=$(date +%s)" remote_v="Unknown"
    [ -f "$SECURE_TMP/.mporter_remote_ver" ] && remote_v=$(tr -d '\r\n ' < "$SECURE_TMP/.mporter_remote_ver")

    clear; echo -e "\n  ${DIM}┌─[ OTA Update (Script Only) ]${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        echo -e "  ${DIM}├─${NC} ${Y}Update Available: v${MODULE_VERSION} ➔ v${remote_v}${NC}"
    else
        echo -e "  ${DIM}├─${NC} ${DIM}Current Version: v${MODULE_VERSION}${NC}"
    fi
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Server${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Offline Editor)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r src_opt

    [[ "$src_opt" =~ ^[1-4]$ ]] || return 0
    tmp_file=$(mktemp "$SECURE_TMP/update.XXXXXX") || return 1
    if [ "$src_opt" == 4 ]; then
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste your code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
            nano "$tmp_file"
        elif command -v vi >/dev/null 2>&1; then vi "$tmp_file"
        else rm -f "$tmp_file"; echo -e "  ${R}✖ No text editor (nano/vi) found!${NC}"; return 1; fi
    else
        case "$src_opt" in
            1) dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path";;
            2) dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path";;
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read -r dl_url;;
        esac
        echo -e "\n  ${C}⟳${NC} ${W}Downloading MPorter Update...${NC}"
        if ! mt_download "$dl_url" "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Download failed. Installed module preserved.${NC}"; return 1; fi
    fi
    sed -i 's/\r$//' "$tmp_file"
    if ! mt_validate_script "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Invalid Bash module. Installed module preserved.${NC}"; return 1; fi
    local new_ver; new_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$tmp_file")
    if mt_is_newer_version "$MODULE_VERSION" "$new_ver"; then rm -f "$tmp_file"; echo -e "  ${Y}● Downloaded module is older; update refused.${NC}"; return 1; fi
    local sum; sum=$(sha256sum "$tmp_file" | awk '{print $1}')
        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}SHA256          :${NC} ${DIM}${sum}${NC}"
        echo -ne "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}"; read -r confirm
    [[ "${confirm,,}" == y || "${confirm,,}" == yes ]] || { rm -f "$tmp_file"; return 0; }
    if ! mt_install_script "$tmp_file" "$rel_path" "$INSTALL_PATH" "$0"; then
        rm -f "$tmp_file"; echo -e "  ${R}✖ Update failed. Previous module preserved.${NC}"; return 1
    fi
    rm -f "$tmp_file"
    echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
    [ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null || true
    exec "$INSTALL_PATH" "$@"
}

get_local_ip() {
    local ip; ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip:-Unknown}"
}

# Stable global IPv6 of this host (skips temporary/deprecated addresses); empty if none
get_local_ipv6() {
    local ip
    ip=$(ip -6 -o addr show scope global 2>/dev/null | grep -v -E 'temporary|deprecated|tentative' | awk '{print $4}' | cut -d/ -f1 | head -n 1)
    [ -z "$ip" ] && ip=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    echo "${ip,,}"
}

# IPv6 forwarding is only switched on when an IPv6 target is really mapped. Enabling it makes the kernel ignore
# router advertisements, so accept_ra=2 is set first on the uplink(s) or the host could lose its IPv6 default route.
enable_v6_forwarding() {
    [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)" = "1" ] && return 0
    local dif cf="/etc/sysctl.d/99-mporter-ipv6.conf" lines=""
    for dif in $(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | sort -u); do
        sysctl -w "net.ipv6.conf.${dif}.accept_ra=2" >/dev/null 2>&1
        lines+="net.ipv6.conf.${dif}.accept_ra=2"$'\n'
    done
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    { printf '%s' "$lines"; echo "net.ipv6.conf.all.forwarding=1"; } > "$cf" 2>/dev/null
}

# Never kills the worker (killing apt/dpkg mid-install breaks the system). It only waits.
draw_progress_bar() {
    local pid=$1 text=$2 width=28 timeout_s=${3:-40} start_ts rc
    start_ts=$(date +%s)
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( $(date +%s) - start_ts ))
        local progress=$(( elapsed * 95 / timeout_s ))
        [ "$progress" -lt 1 ] && progress=1; [ "$progress" -gt 99 ] && progress=99
        local filled=$(( progress * width / 100 )); local empty=$(( width - filled ))
        local bar; bar=$(printf "%${filled}s" "" | tr ' ' '#'); local empty_bar; empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')
        printf "\r  ${C}⟳${NC} ${W}%-26s${NC} ${B}[${G}%s${DIM}%s${B}]${NC} ${C}%3d%%${NC}" "$text" "$bar" "$empty_bar" "$progress"
        sleep 0.2
    done
    wait "$pid" 2>/dev/null; rc=$?
    local bar; bar=$(printf "%${width}s" "" | tr ' ' '#')
    if [ "$rc" -eq 0 ]; then
        printf "\r  ${G}✔${NC} ${W}%-26s${NC} ${B}[${G}%s${B}]${NC} ${G}100%%${NC}\n" "$text" "$bar"
    else
        printf "\r  ${Y}⚠${NC} ${W}%-26s${NC} ${Y}[ finished with warnings (rc=%s) ]${NC}\n" "$text" "$rc"
    fi
    tput cnorm 2>/dev/null || true
    return "$rc"
}

# ==========================================================
# State layer (all writes locked + atomic)
# ==========================================================

state_init() {
    mkdir -p "$STATE_DIR" "$SECURE_TMP" || return 1
    command -v jq >/dev/null 2>&1 || return 1
    state_lock || return 1
    local tmp rc=0
    if [ ! -s "$STATE_FILE" ] || ! jq -e '.version == 1 and (.mappings|type=="array") and (.backends|type=="array") and (.pools|type=="array")' "$STATE_FILE" >/dev/null 2>&1; then
        tmp=$(mktemp "$STATE_DIR/.state-init.XXXXXX") || { state_unlock; return 1; }
        printf '{"version":1,"updated_at":"%s","mappings":[],"backends":[],"pools":[]}\n' "$(date -Is)" > "$tmp"
        [ ! -s "$STATE_FILE" ] || cp -p "$STATE_FILE" "$STATE_FILE.invalid.$(date +%s)"
        chmod 600 "$tmp" && mv -f "$tmp" "$STATE_FILE" || rc=1
        rm -f "$tmp"
    fi
    chmod 600 "$STATE_FILE" || rc=1
    state_unlock
    return "$rc"
}

state_lock() { exec 9>"$LOCK_FILE" || return 1; flock -w 20 -x 9 || { exec 9>&-; return 1; }; }
state_unlock() { flock -u 9 2>/dev/null || true; exec 9>&- 2>/dev/null || true; }

# state_apply [jq args...] <filter>
state_apply() {
    state_init || return 1
    local tmp rc=1
    tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
    state_lock || { rm -f "$tmp"; return 1; }
    if jq "$@" "$STATE_FILE" > "$tmp" 2>/dev/null && jq -e '.version' "$tmp" >/dev/null 2>&1; then
        chmod 600 "$tmp" && mv -f "$tmp" "$STATE_FILE" && rc=0
    fi
    rm -f "$tmp"; state_unlock
    return $rc
}

state_remove_target() {
    state_apply --arg t "$1" --arg now "$(date -Is)" '.mappings=[.mappings[]|select(.target_ip != $t)] | .backends=[.backends[]|select(.target_ip != $t)] | .pools=[.pools[] | .targets |= map(select(.ip != $t)) | select((.targets|length)>0)] | .updated_at=$now'
}

state_remove_port() {
    state_apply --argjson p "$1" --arg now "$(date -Is)" '.mappings=[.mappings[]|select(.port != $p)] | .pools=[.pools[] | .ports -= [$p] | select((.ports|length)>0)] | .updated_at=$now'
}

# All live mappings from engine configs: "port|target_ip|target_port|ENGINE" (target may be IPv4 or IPv6)
collect_mappings() {
    if [ -f "$H_CONF" ]; then
        awk '/^[^ \t#]/ {b=""}
             /^backend[ \t]+bk_[0-9]+[ \t]*$/ {b=$2; sub(/^bk_/,"",b); next}
             b!="" && $1=="server" {
                 a=$3; sub(/^ipv[46]@/,"",a)
                 k=match(a, /:[0-9]+$/); if (!k) next
                 ip=substr(a,1,k-1); rp=substr(a,k+1); gsub(/\[|\]/,"",ip)
                 if ((ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || ip ~ /^[0-9a-fA-F:]+$/ && index(ip,":")>0) && rp ~ /^[0-9]+$/) print b"|"tolower(ip)"|"rp"|HAP" }' "$H_CONF" 2>/dev/null
    fi
    if command -v jq >/dev/null 2>&1; then
        [ -f "$G_CONF" ] && jq -r '.ServeNodes[]? | strings | capture("^tcp://[^/]*:(?<p>[0-9]+)/(?<ip>\\[[0-9a-fA-F:]+\\]|[0-9.]+):(?<rp>[0-9]+)") | "\(.p)|\(.ip|gsub("[\\[\\]]";"")|ascii_downcase)|\(.rp)|GST"' "$G_CONF" 2>/dev/null
        [ -f "$R_CONF" ] && jq -r '.endpoints[]? | select(.listen and .remote) | (.listen|tostring|split(":")|last) as $p | (.remote|tostring|capture("^\\[?(?<ip>[^\\]]+?)\\]?:(?<rp>[0-9]+)$")) as $r | "\($p)|\($r.ip|ascii_downcase)|\($r.rp)|RLM"' "$R_CONF" 2>/dev/null
    fi
    [ -f "$IPT_CONF" ] && grep -E -- '-A PREROUTING' "$IPT_CONF" 2>/dev/null | sed -nE 's/.*--dport ([0-9]+) .*MPORTER_NAT_([0-9a-fA-F:.]+)\\?".*--to-destination \[?[0-9a-fA-F:.]+\]?:([0-9]+).*/\1|\2|\3|IPT/p'
}

# OBFS targets "ip|port" (v11 tags + legacy v10 lines)
obfs_targets() {
    [ -f "$OBFS_DIR/nat.sh" ] || return 0
    grep -oE '# MP_OBFS ip=[0-9a-fA-F:.]+ port=[0-9]+' "$OBFS_DIR/nat.sh" 2>/dev/null | sed -E 's/# MP_OBFS ip=([0-9a-fA-F:.]+) port=([0-9]+)/\1|\2/'
    grep -E -- '-A OUTPUT -d [0-9.]+ -p tcp --dport [0-9]+ .*MPORTER_OBFS' "$OBFS_DIR/nat.sh" 2>/dev/null | grep -v 'MP_OBFS ip=' | sed -nE 's/.*-d ([0-9.]+) -p tcp --dport ([0-9]+) .*/\1|\2/p'
}

state_reconcile() {
    ensure_jq >/dev/null 2>&1 || return 1
    state_init || return 1
    local found obfs
    found=$(collect_mappings | awk -F'|' '$2 != "127.0.0.1" && $2 != "::1"' | jq -Rn '[inputs | split("|") | select(length==4) | {port:(.[0]|tonumber), target_ip:.[1], target_port:(.[2]|tonumber), engine:.[3]}]' 2>/dev/null)
    [ -n "$found" ] || found='[]'
    obfs=$(obfs_targets | jq -Rn '[inputs | split("|") | select(length==2) | {ip:.[0], port:(.[1]|tonumber)}]' 2>/dev/null)
    [ -n "$obfs" ] || obfs='[]'
    state_apply --arg now "$(date -Is)" --argjson found "$found" --argjson obfs "$obfs" '
      (.mappings // []) as $old
      | ($found | group_by(.engine + ":" + (.port|tostring)) | map(if length > 1 then map(.mode="LOADBALANCE") else map(.mode="DIRECT") end) | add // []) as $cur
      | .mappings = [ $cur[] | . as $m
          | ((first($old[] | select(.port==$m.port and .engine==$m.engine and .target_ip==$m.target_ip))) // {}) as $o
          | $m + {interface: ($o.interface // ""), pool: ($o.pool // ""),
                  obfs: any($obfs[]; .ip==$m.target_ip and .port==$m.target_port), updated_at: $now}
          | if .engine=="HAP" and (($o.mode // "")=="FAILOVER" or ($o.mode // "")=="LOADBALANCE") then .mode=$o.mode else . end ]
      | .backends = (.backends // []) | .pools = (.pools // []) | .version = 1 | .updated_at = $now'
}

# Records the interface of each mapping. An interface that has disappeared is KEPT
# (that is the evidence used by --cleanup-orphans), never overwritten by the default route.
state_sync_interface_metadata() {
    state_init || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local updates="" idx ip old dev upd
    while IFS=$'\t' read -r idx ip old; do
        [ -n "$idx" ] || continue
        if [ -n "$old" ] && [ "$old" != "unknown" ] && ! ip link show "$old" >/dev/null 2>&1; then continue; fi
        dev=$(route_dev "$ip"); [ -n "$dev" ] || dev="unknown"
        [ "$dev" = "$old" ] && continue
        updates+="$idx"$'\t'"$dev"$'\n'
    done < <(jq -r '.mappings | to_entries[] | [(.key|tostring), .value.target_ip, (.value.interface // "")] | @tsv' "$STATE_FILE" 2>/dev/null)
    [ -n "$updates" ] || return 0
    upd=$(printf '%s' "$updates" | jq -Rn '[inputs | split("\t") | select(length==2) | {k:(.[0]|tonumber), v:.[1]}]')
    state_apply --argjson u "$upd" --arg now "$(date -Is)" 'reduce $u[] as $x (.; if .mappings[$x.k] then .mappings[$x.k].interface = $x.v | .mappings[$x.k].updated_at = $now else . end) | .updated_at = $now'
}

# Priority: explicit tunnel metadata -> kernel neighbour -> /30,/31 peer inference.
# Order is preserved (no sort), and only peers routed through the interface are accepted.
# Optional $2 = local IP on the interface: restrict to peers of that address (same family / v4 subnet).
# IPv6 cores (ipip6to6 CORE_V6, 6to4 inner peer) come from the tunnel metadata; underlay (outer) addresses are never returned.
discover_peer_ips() {
    local iface="$1" want_local="${2:-}" conf var val cidr out=() own=() own6=() subnet="" fam_only=""
    mapfile -t own < <(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}')
    mapfile -t own6 < <(ip -o -6 addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}')
    if [ -n "$want_local" ]; then
        if is_v6 "$want_local"; then fam_only=6; else
            fam_only=4
            for cidr in "${own[@]}"; do [ "${cidr%/*}" = "$want_local" ] && subnet="$cidr"; done
        fi
    fi
    local tproto tcore tkind
    while read -r conf; do
        [ "$(read_conf_value "$conf" T_NAME)" = "$iface" ] || [ "$(read_conf_value "$conf" BR_NAME)" = "$iface" ] || continue
        for var in PEER_IP PEER_ADDR PEER_ADDRESS CORE_PEER_IP TUNNEL_PEER_IP REMOTE_IP REMOTE_ADDR REMOTE_ADDRESS REMOTE ENDPOINT ENDPOINT_IP; do
            val=$(read_conf_value "$conf" "$var"); valid_ipv4 "$val" && out+=("$val")
        done
        # VXLAN has an explicit .1/.2 core pair on a /24; never infer unrelated /24 neighbours.
        if [ "$(read_conf_value "$conf" BR_NAME)" == "$iface" ]; then
            tcore=$(read_conf_value "$conf" CORE_SUBNET); tkind=$(read_conf_value "$conf" TYPE)
            if [ "$tkind" == 1 ]; then val="${tcore}.2"; elif [ "$tkind" == 2 ]; then val="${tcore}.1"; else val=''; fi
            valid_ipv4 "$val" && out+=("$val")
        fi
        # mgre: inner IPv6 peer of 6to4 and the deterministic ::1/::2 pair of ipip6to6
        val=$(read_conf_value "$conf" REMOTE_IP6); valid_ipv6 "$val" && out+=("${val,,}")
        tproto=$(read_conf_value "$conf" TUN_PROTO); tcore=$(read_conf_value "$conf" CORE_V6); tkind=$(read_conf_value "$conf" TYPE)
        if [ "$tproto" = "ipip6to6" ] && [ -n "$tcore" ]; then
            if [ "$tkind" = "1" ]; then val="${tcore}::2"; else val="${tcore}::1"; fi
            valid_ipv6 "$val" && out+=("${val,,}")
        fi
    done < <(tunnel_conf_files)
    while read -r val; do valid_ipv4 "$val" && out+=("$val"); done < <(ip -4 neigh show dev "$iface" 2>/dev/null | awk '$0 !~ /FAILED|INCOMPLETE/ {print $1}')
    while read -r val; do valid_target_ip "$val" && is_v6 "$val" && out+=("${val,,}"); done < <(ip -6 neigh show dev "$iface" 2>/dev/null | awk '$0 !~ /FAILED|INCOMPLETE/ {print $1}')
    for cidr in "${own[@]}"; do
        [ -n "$subnet" ] && [ "$cidr" != "$subnet" ] && continue
        local pre="${cidr#*/}" n base
        n=$(ip_to_int "${cidr%/*}")
        if [ "$pre" = "30" ]; then
            base=$(( n & 0xFFFFFFFC ))
            if [ $((n-base)) -eq 1 ]; then out+=("$(int_to_ip $((base+2)))"); elif [ $((n-base)) -eq 2 ]; then out+=("$(int_to_ip $((base+1)))"); fi
        elif [ "$pre" = "31" ]; then
            out+=("$(int_to_ip $(( n ^ 1 )))")
        fi
    done
    local p c skip
    for p in "${out[@]}"; do
        skip=false
        [ "$fam_only" = "4" ] && is_v6 "$p" && continue
        [ "$fam_only" = "6" ] && ! is_v6 "$p" && continue
        for c in "${own[@]}" "${own6[@]}"; do [ "${c%/*}" = "$p" ] && skip=true; done
        $skip && continue
        if ! is_v6 "$p"; then [ -n "$subnet" ] && ! ip_in_cidr "$p" "$subnet" && continue; fi
        [ "$(route_dev "$p")" = "$iface" ] || continue
        echo "$p"
    done | awk 'NF && !seen[$0]++'
}

port_listening() { ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]$1\$"; }

# Prints which engine/process owns local port $1 (empty = free)
port_owner() {
    local p="$1"
    if [ -f "$H_CONF" ] && grep -qE "^frontend[[:space:]]+ft_${p}[[:space:]]*$" "$H_CONF" 2>/dev/null; then echo "HAProxy"; return 0; fi
    if command -v jq >/dev/null 2>&1; then
        [ -f "$G_CONF" ] && jq -e --arg p "tcp://:$p/" '[.ServeNodes[]? | strings | select(startswith($p))] | length > 0' "$G_CONF" >/dev/null 2>&1 && { echo "Gost"; return 0; }
        [ -f "$R_CONF" ] && jq -e --arg l "0.0.0.0:$p" '[.endpoints[]? | select(.listen == $l)] | length > 0' "$R_CONF" >/dev/null 2>&1 && { echo "Realm"; return 0; }
    fi
    grep -qE -- "-A PREROUTING .*--dport $p .*MPORTER_NAT_" "$IPT_CONF" 2>/dev/null && { echo "KernelNAT"; return 0; }
    port_listening "$p" && { echo "OS/System"; return 0; }
    return 1
}

find_free_local_port() {
    local base=$((30000 + $1)) p
    [ "$base" -gt 65000 ] && base=$((20000 + $1 % 10000))
    for p in $(seq "$base" 65535) $(seq 20000 "$base"); do
        port_listening "$p" && continue
        grep -qsE "lport=$p |--to-ports $p( |$)|:$p/" "$OBFS_DIR/nat.sh" "$OBFS_DIR/gost.sh" 2>/dev/null && continue
        port_owner "$p" >/dev/null && continue
        echo "$p"; return 0
    done
    return 1
}

# ==========================================================
# HAProxy helpers (validate -> commit -> reload -> rollback)
# ==========================================================

hap_base_config() {
    cat <<'EOF_HAP'
global
    maxconn 500000
    daemon
defaults
    mode tcp
    timeout connect 5s
    timeout client 1h
    timeout server 1h
frontend dummy_check
    bind 127.0.0.1:9999
    default_backend dummy_back
backend dummy_back
EOF_HAP
}

ensure_haproxy_base() {
    [ -f "$H_CONF" ] || return 0
    if ! grep -qE '^[[:space:]]+timeout[[:space:]]+client' "$H_CONF" 2>/dev/null; then
        sed -i '/^defaults/a\    timeout connect 5s\n    timeout client 1h\n    timeout server 1h' "$H_CONF" 2>/dev/null
    fi
}

haproxy_test_config() { haproxy -c -f "${1:-$H_CONF}" >/dev/null 2>&1; }

haproxy_reload_safe() {
    command -v haproxy >/dev/null 2>&1 || return 1
    haproxy_test_config || return 1
    systemctl reload haproxy >/dev/null 2>&1 || systemctl restart haproxy >/dev/null 2>&1
    sleep 0.5
    systemctl is-active --quiet haproxy
}

# Removes whole frontend ft_P / backend bk_P sections for every port in $1 from file $2 (stdout).
# A section ends at the next non-indented line, so markers / comments are never swallowed.
hap_strip_ports() {
    awk -v plist="$1" 'BEGIN{n=split(plist,a," "); for(i=1;i<=n;i++) want[a[i]]=1; skip=0}
        /^(frontend|backend)[ \t]+(ft|bk)_[0-9]+[ \t]*$/ { nm=$2; sub(/^(ft|bk)_/,"",nm); if (nm in want) {skip=1; next} skip=0; print; next }
        /^[^ \t]/ { skip=0 }
        skip { next }
        { print }' "$2"
}

hap_remove_server() { # port ip file -> stdout
    awk -v p="$1" -v ip="$2" '/^[^ \t]/ { inb = ($0 ~ ("^backend[ \t]+bk_" p "[ \t]*$")) }
        inb && $1=="server" { x=$3; sub(/^ipv[46]@/,"",x); sub(/:[0-9]+$/,"",x); gsub(/\[|\]/,"",x); if (tolower(x)==ip) next }
        { print }' "$3"
}

hap_server_count() { # port file
    awk -v p="$1" '/^[^ \t]/ { inb = ($0 ~ ("^backend[ \t]+bk_" p "[ \t]*$")) } inb && $1=="server" {c++} END{print c+0}' "$2"
}

# hap_commit <candidate file>: validate, backup, install, reload, rollback on failure.
hap_commit() {
    local new="$1" backup
    if command -v haproxy >/dev/null 2>&1 && ! haproxy_test_config "$new"; then
        echo -e "  ${R}✖ HAProxy rejected the new configuration. Nothing changed.${NC}"
        haproxy -c -f "$new" 2>&1 | grep -iE 'alert|error' | head -n 3 | sed 's/^/    /'
        rm -f "$new"; return 1
    fi
    backup="$H_CONF.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "$H_CONF" "$backup" 2>/dev/null
    cat "$new" > "$H_CONF"; rm -f "$new"
    if command -v haproxy >/dev/null 2>&1 && ! haproxy_reload_safe; then
        echo -e "  ${R}✖ HAProxy reload failed, restoring last known-good configuration.${NC}"
        cat "$backup" > "$H_CONF"; haproxy_reload_safe >/dev/null 2>&1
        return 1
    fi
    ls -1t "$H_CONF".bak.* "$H_CONF".v10.*.bak 2>/dev/null | tail -n +11 | xargs -r rm -f
    return 0
}

# json_engine_commit <conf> <candidate> <service>: install candidate, restart, rollback if the service dies.
json_engine_commit() {
    local file="$1" new="$2" svc="$3" bak
    jq -e 'type=="object"' "$new" >/dev/null 2>&1 || { rm -f "$new"; return 1; }
    bak=$(mp_tmp bak) || return 1
    cp -f "$file" "$bak" 2>/dev/null; cat "$new" > "$file"; rm -f "$new"
    systemctl restart "$svc" >/dev/null 2>&1; sleep 1
    if systemctl is-active --quiet "$svc"; then rm -f "$bak"; return 0; fi
    cat "$bak" > "$file"; rm -f "$bak"; systemctl restart "$svc" >/dev/null 2>&1
    return 1
}

json_edit() { # file filter [jq args...] : in-place, validated
    local file="$1" filter="$2" tmp; shift 2
    [ -f "$file" ] || return 0
    tmp=$(mp_tmp json) || return 1
    if jq "$@" "$filter" "$file" > "$tmp" 2>/dev/null && jq -e 'type=="object"' "$tmp" >/dev/null 2>&1; then cat "$tmp" > "$file"; fi
    rm -f "$tmp"
}

# ==========================================================
# MSS / OBFS / iptables helpers
# ==========================================================

apply_scoped_mss() {
    local iface="$1" record="${2:-true}" tag chain
    valid_iface "$iface" || return 0
    tag="MPORTER_MSS_${iface//[^a-zA-Z0-9_]/_}"
    if [ "$record" = true ]; then grep -qxF "$iface" "$MSS_FILE" 2>/dev/null || echo "$iface" >> "$MSS_FILE"; fi
    ip link show "$iface" >/dev/null 2>&1 || return 0
    for chain in OUTPUT FORWARD; do
        iptables -t mangle -C "$chain" -o "$iface" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "$tag" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A "$chain" -o "$iface" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "$tag" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        command -v ip6tables >/dev/null 2>&1 || continue
        ip6tables -t mangle -C "$chain" -o "$iface" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "$tag" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        ip6tables -t mangle -A "$chain" -o "$iface" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "$tag" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    done
}

mss_reapply_all() {
    [ -f "$MSS_FILE" ] || return 0
    local i; while read -r i; do [ -n "$i" ] && apply_scoped_mss "$i" false; done < "$MSS_FILE"
}

ipt_flush_tag() {
    local bin
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        mt_delete_tagged_rules "$bin" "$1" "$2" "$3" substring
    done
}

obfs_flush_rules() {
    ipt_flush_tag nat OUTPUT MPORTER_OBFS; ipt_flush_tag nat PREROUTING MPORTER_OBFS
    ipt_flush_tag mangle OUTPUT OBFS_CNT_TX_; ipt_flush_tag mangle INPUT OBFS_CNT_RX_
}

obfs_reload() {
    if unit_exists mporter-obfs; then systemctl restart mporter-obfs >/dev/null 2>&1; else obfs_flush_rules; fi
}

# obfs_filter ip|port <value>: drop OBFS lines for a target IP or a local port (v11 tags + legacy lines)
obfs_filter() {
    local mode="$1" val="$2" f tmp
    for f in "$OBFS_DIR/nat.sh" "$OBFS_DIR/gost.sh"; do
        [ -f "$f" ] || continue
        tmp=$(mp_tmp obfs) || return 1
        awk -v mode="$mode" -v v="$val" '
            function has(s) { return index($0, s) > 0 }
            function ends(s) { return length($0) >= length(s) && substr($0, length($0)-length(s)+1) == s }
            { drop=0
              if (mode=="ip") { if (has(" ip=" v " ") || has("-d " v " ") || has("-s " v " ") || has("/" v ":") || ends("_" v)) drop=1 }
              else            { if (has(" port=" v " ") || has("--dport " v " ") || has(":" v " -F ")) drop=1 }
              if (!drop) print }' "$f" > "$tmp" && cat "$tmp" > "$f"
        rm -f "$tmp"
    done
    # drop traffic counters of targets that have no OBFS port left
    f="$OBFS_DIR/nat.sh"
    if [ -f "$f" ]; then
        tmp=$(mp_tmp obfs) || return 1
        awk 'NR==FNR { if (match($0, /MP_OBFS ip=[0-9a-fA-F:.]+ /)) live[substr($0, RSTART+11, RLENGTH-12)]=1; next }
             { if (match($0, /MP_CNT ip=[0-9a-fA-F:.]+ /)) { s=substr($0, RSTART+10, RLENGTH-11); if (!(s in live)) next } print }' "$f" "$f" > "$tmp" && cat "$tmp" > "$f"
        rm -f "$tmp"
    fi
}

ipt_conf_filter() { # awk condition on $0 with vars ip/p ; removes matching lines from IPT_CONF
    [ -f "$IPT_CONF" ] || return 0
    local tmp; tmp=$(mp_tmp ipt) || return 1
    awk -v ip="$1" -v p="$2" '
        { tagged = (ip != "" && index($0, "\"MPORTER_NAT_" ip "\"") > 0) || (ip == "" && index($0, "MPORTER_NAT_") > 0)
          portm  = (p == "" || index($0, "--dport " p " ") > 0 || index($0, "--sport " p " ") > 0)
          if (tagged && portm) next; print }' "$IPT_CONF" > "$tmp" && cat "$tmp" > "$IPT_CONF"
    rm -f "$tmp"
}

restart_all_engines() {
    [ -f "$H_CONF" ] && command -v haproxy >/dev/null 2>&1 && haproxy_reload_safe >/dev/null 2>&1
    unit_exists gost && systemctl restart gost >/dev/null 2>&1
    unit_exists realm && systemctl restart realm >/dev/null 2>&1
    unit_exists mporter-iptables && systemctl restart mporter-iptables >/dev/null 2>&1
    setup_mporter_service
    obfs_reload
}

# ==========================================================
# Purge
# ==========================================================

purge_ip_core() {
    local ip="$1" p
    ip="${ip,,}"
    valid_ip "$ip" || return 1
    ensure_jq >/dev/null 2>&1 || true
    if [ -f "$H_CONF" ]; then
        local hports; hports=$(collect_mappings | awk -F'|' -v ip="$ip" '$4=="HAP" && $2==ip {print $1}' | sort -un | xargs)
        if [ -n "$hports" ]; then
            local tmp empty=""; tmp=$(mp_tmp hap); cp -f "$H_CONF" "$tmp"
            for p in $hports; do
                hap_remove_server "$p" "$ip" "$tmp" > "$tmp.n" && mv -f "$tmp.n" "$tmp"
                [ "$(hap_server_count "$p" "$tmp")" -eq 0 ] && empty+="$p "
            done
            [ -n "$empty" ] && { hap_strip_ports "$empty" "$tmp" > "$tmp.n" && mv -f "$tmp.n" "$tmp"; }
            hap_commit "$tmp" >/dev/null || true
        fi
    fi
    if command -v jq >/dev/null 2>&1; then
        json_edit "$G_CONF" '.ServeNodes = [.ServeNodes[]? | select((((capture("^tcp://[^/]*/(?<ip>\\[[0-9a-fA-F:]+\\]|[0-9.]+):") | .ip | gsub("[\\[\\]]";"") | ascii_downcase)) // "") != $ip)]' --arg ip "$ip"
        json_edit "$R_CONF" '.endpoints = [.endpoints[]? | select((((.remote // "")|tostring|sub("\\]?:[0-9]+$";"")|sub("^\\[";"")|ascii_downcase)) != $ip)]' --arg ip "$ip"
    fi
    ipt_conf_filter "$ip" ""
    obfs_filter ip "$ip"
    state_remove_target "$ip" >/dev/null 2>&1 || true
}

purge_port_core() {
    local p="$1"
    valid_port "$p" || return 1
    ensure_jq >/dev/null 2>&1 || true
    if [ -f "$H_CONF" ] && grep -qE "^(frontend|backend)[[:space:]]+(ft|bk)_${p}[[:space:]]*$" "$H_CONF"; then
        local tmp; tmp=$(mp_tmp hap); hap_strip_ports "$p" "$H_CONF" > "$tmp"; hap_commit "$tmp" >/dev/null || true
    fi
    if command -v jq >/dev/null 2>&1; then
        json_edit "$G_CONF" '.ServeNodes = [.ServeNodes[]? | select(startswith("tcp://:" + $p + "/") | not)]' --arg p "$p"
        json_edit "$R_CONF" '.endpoints = [.endpoints[]? | select(.listen != ("0.0.0.0:" + $p))]' --arg p "$p"
    fi
    ipt_conf_filter "" "$p"
    obfs_filter port "$p"
    state_remove_port "$p" >/dev/null 2>&1 || true
}

# ==========================================================
# Runners / services
# ==========================================================

build_iptables_runner() {
    cat <<'EOF_IPT' > /usr/local/bin/mporter-iptables.sh
#!/bin/bash
for bin in iptables ip6tables; do
    command -v "$bin" >/dev/null 2>&1 || continue
    for spec in "nat PREROUTING" "nat POSTROUTING" "filter FORWARD"; do
        set -- $spec
        "$bin" -t "$1" -L "$2" -n --line-numbers 2>/dev/null | awk -v tag="MPORTER_NAT_" '$1~/^[0-9]+$/ && index($0,tag){print $1}' | sort -rn | while read -r num; do "$bin" -w 5 -t "$1" -D "$2" "$num"; done
    done
done
[ -f /etc/mporter/iptables_core/rules.sh ] && source /etc/mporter/iptables_core/rules.sh 2>/dev/null
exit 0
EOF_IPT
    chmod +x /usr/local/bin/mporter-iptables.sh
    cat <<'EOF_SRV_IPT' > /etc/systemd/system/mporter-iptables.service
[Unit]
Description=MPorter Kernel NAT Engine
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/mporter-iptables.sh
ExecReload=/usr/local/bin/mporter-iptables.sh
[Install]
WantedBy=multi-user.target
EOF_SRV_IPT
    systemctl daemon-reload; systemctl enable mporter-iptables >/dev/null 2>&1; systemctl restart mporter-iptables >/dev/null 2>&1
    setup_mporter_service
}

build_obfs_runner() {
    cat <<'EOF_OBFS' > /usr/local/bin/mporter-obfs.sh
#!/bin/bash
flush() { local bin; for bin in iptables ip6tables; do command -v "$bin" >/dev/null 2>&1 || continue; "$bin" -t "$1" -L "$2" -n --line-numbers 2>/dev/null | awk -v tag="$3" '$1~/^[0-9]+$/ && index($0,tag){print $1}' | sort -rn | while read -r num; do "$bin" -w 5 -t "$1" -D "$2" "$num"; done; done; }
flush nat OUTPUT MPORTER_OBFS; flush nat PREROUTING MPORTER_OBFS
flush mangle OUTPUT OBFS_CNT_TX_; flush mangle INPUT OBFS_CNT_RX_
[ "${1:-}" = "--flush" ] && exit 0
# v11: no global TCPMSS here; MSS is scoped per tunnel interface by mporter --boot-apply.
[ -f /etc/mporter/obfs_rules/nat.sh ] && source /etc/mporter/obfs_rules/nat.sh 2>/dev/null
[ -f /etc/mporter/obfs_rules/gost.sh ] && source /etc/mporter/obfs_rules/gost.sh 2>/dev/null
if [ -n "$(jobs -p)" ]; then wait; else exec sleep infinity; fi
EOF_OBFS
    chmod +x /usr/local/bin/mporter-obfs.sh
    cat <<'EOF_SRV' > /etc/systemd/system/mporter-obfs.service
[Unit]
Description=MPorter OBFS Stealth Engine
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mporter-obfs.sh
ExecStopPost=/usr/local/bin/mporter-obfs.sh --flush
Restart=always
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF_SRV
    systemctl daemon-reload; systemctl enable mporter-obfs >/dev/null 2>&1; systemctl restart mporter-obfs >/dev/null 2>&1
    setup_mporter_service
}

verify_sha256() { # file expected(optional)
    [ -z "${2:-}" ] && return 0
    [ "$(sha256sum "$1" 2>/dev/null | awk '{print $1}')" = "$2" ]
}

# Optional pinning: export MPORTER_GOST_SHA256=<sha of the .gz> / MPORTER_REALM_SHA256=<sha of the .tar.gz>
download_gost_binary() {
    local target_bin="/usr/local/bin/gost" url gz raw
    if [ -x "$target_bin" ] && "$target_bin" -V >/dev/null 2>&1; then return 0; fi
    [ "$(uname -m)" = "x86_64" ] || { echo "gost: only the linux-amd64 build is mirrored" >&2; return 1; }
    local mirrors=("https://c107328.parspack.net/c107328/MTunnel/gost-linux-amd64-2.11.5.gz"
                   "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"
                   "https://ghproxy.net/https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz")
    for url in "${mirrors[@]}"; do
        gz=$(mp_tmp gostgz) || return 1; raw="$gz.bin"
        if download_file "$url" "$gz" && [ -s "$gz" ] && gzip -t "$gz" 2>/dev/null && verify_sha256 "$gz" "${MPORTER_GOST_SHA256:-}"; then
            gzip -dc "$gz" > "$raw" 2>/dev/null && chmod +x "$raw"
            if "$raw" -V >/dev/null 2>&1; then mv -f "$raw" "$target_bin"; rm -f "$gz"; return 0; fi
        fi
        rm -f "$gz" "$raw"
    done
    return 1
}

download_realm_binary() {
    local target_bin="/usr/local/bin/realm" url dl dir bin
    if [ -x "$target_bin" ] && "$target_bin" --version >/dev/null 2>&1; then return 0; fi
    [ "$(uname -m)" = "x86_64" ] || { echo "realm: only the x86_64 build is mirrored" >&2; return 1; }
    for url in "https://c107328.parspack.net/c107328/MTunnel/realm.tar.gz" \
               "https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"; do
        dl=$(mp_tmp realmtgz) || return 1; dir=$(mktemp -d "$SECURE_TMP/realm.XXXXXX")
        if download_file "$url" "$dl" && [ -s "$dl" ] && verify_sha256 "$dl" "${MPORTER_REALM_SHA256:-}" && tar -xzf "$dl" -C "$dir" 2>/dev/null; then
            bin=$(find "$dir" -type f -name realm | head -n1)
            if [ -n "$bin" ] && chmod +x "$bin" && "$bin" --version >/dev/null 2>&1; then
                mv -f "$bin" "$target_bin"; rm -rf "$dl" "$dir"; return 0
            fi
        fi
        rm -rf "$dl" "$dir"
    done
    return 1
}

install_core_engines() {
    clear; echo -e "\n  ${DIM}┌─[ ENGINE SELECTION (Select Cores to Install) ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy Engine Only${NC} ${DIM}(Load Balancer / Stable)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost Engine Only${NC} ${DIM}(TLS/WS Obfuscator)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Realm Engine Only${NC} ${DIM}(High-Performance / Rust)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Iptables NAT Engine Only${NC} ${DIM}(Raw Speed)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Install ALL Engines (Quad-Core)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Option ❯❯ ${NC}"; read -r eng_opt
    [[ "$eng_opt" =~ ^[1-5]$ ]] || return

    echo -e "\n  ${DIM}┌─[ INITIALIZING INSTALLATION ]${NC}"
    (
        sysctl -w fs.file-max=2000000 >/dev/null 2>&1
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        modprobe tcp_bbr >/dev/null 2>&1
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
        sed -i '/^[[:space:]]*net.ipv4.ip_forward/d; /^[[:space:]]*net.core.default_qdisc/d; /^[[:space:]]*net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
        printf '%s\n' "net.ipv4.ip_forward=1" "net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        # Never delete dpkg locks: wait for them instead (DPkg::Lock::Timeout).
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get update "${APT_OPTS[@]}" >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" jq curl wget gzip iptables tar iproute2 >/dev/null 2>&1
    ) &
    draw_progress_bar $! "Resolving Dependencies" 90

    if [[ "$eng_opt" == "5" || "$eng_opt" == "1" ]]; then
        (
            mkdir -p /etc/haproxy /var/lib/haproxy 2>/dev/null
            DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" -o Dpkg::Options::=--force-confold haproxy >/dev/null 2>&1 || exit 1
            # The Debian package ships an HTTP-mode config: replace it unless it already holds MPorter mappings.
            if [ ! -s "$H_CONF" ] || ! grep -qE '^(frontend|backend)[[:space:]]+(ft|bk)_[0-9]+' "$H_CONF"; then
                [ -s "$H_CONF" ] && cp -f "$H_CONF" "$H_CONF.orig.$(date +%s)"
                hap_base_config > "$H_CONF"
            fi
            ensure_haproxy_base
            haproxy_test_config || exit 2
            systemctl daemon-reload >/dev/null 2>&1; systemctl enable haproxy >/dev/null 2>&1; systemctl restart haproxy >/dev/null 2>&1
            systemctl is-active --quiet haproxy
        ) &
        draw_progress_bar $! "Deploying HAProxy Engine" 70
    fi

    if [[ "$eng_opt" == "5" || "$eng_opt" == "2" ]]; then
        (
            download_gost_binary || exit 1
            mkdir -p /etc/gost 2>/dev/null
            if [ ! -f "$G_CONF" ] || ! jq -e 'type=="object"' "$G_CONF" >/dev/null 2>&1; then echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"; fi
            cat <<EOF_GST > /etc/systemd/system/gost.service
[Unit]
Description=GO Simple Tunnel (MPorter Core)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C /etc/gost/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF_GST
            systemctl daemon-reload >/dev/null 2>&1; systemctl enable gost >/dev/null 2>&1; systemctl restart gost >/dev/null 2>&1 || true
        ) &
        draw_progress_bar $! "Deploying Gost Engine" 100
    fi

    if [[ "$eng_opt" == "5" || "$eng_opt" == "3" ]]; then
        (
            download_realm_binary || exit 1
            mkdir -p /etc/realm 2>/dev/null
            if [ ! -f "$R_CONF" ] || ! jq -e 'type=="object"' "$R_CONF" >/dev/null 2>&1; then echo '{"network": {"no_tcp_delay": true}, "endpoints": []}' > "$R_CONF"; fi
            cat <<EOF_RLM > /etc/systemd/system/realm.service
[Unit]
Description=Realm High-Performance Port Forwarder
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF_RLM
            systemctl daemon-reload >/dev/null 2>&1; systemctl enable realm >/dev/null 2>&1; systemctl restart realm >/dev/null 2>&1 || true
        ) &
        draw_progress_bar $! "Deploying Realm Engine" 80
    fi

    if [[ "$eng_opt" == "5" || "$eng_opt" == "4" ]]; then
        (
            command -v iptables >/dev/null 2>&1 || exit 1
            mkdir -p "$IPT_DIR" 2>/dev/null; touch "$IPT_CONF" 2>/dev/null; chmod +x "$IPT_CONF" 2>/dev/null
            build_iptables_runner
        ) &
        draw_progress_bar $! "Deploying Kernel NAT Engine" 25
    fi

    setup_mporter_service
    echo -e "  ${DIM}└──────────────────────────────────────────────────────────┘${NC}\n"; sleep 1
}

# ==========================================================
# Health
# ==========================================================

health_probe() {
    local ip="$1" port="$2" timeout_s="${3:-2}"
    valid_ip "$ip" && valid_port "$port" || return 2
    timeout "$timeout_s" bash -c "</dev/tcp/$ip/$port" >/dev/null 2>&1
}

health_check_backend() {
    local iface="$1" ip="$2" port="$3" fail_limit="${4:-2}" fail=0 n=1
    while [ "$n" -le "$fail_limit" ]; do
        if health_probe "$ip" "$port" 2; then echo "$iface|$ip|$port|UP|$((n-1))|$(date +%s)"; return 0; fi
        fail=$n; n=$((n+1)); [ "$n" -le "$fail_limit" ] && sleep 0.2
    done
    if [ -n "$iface" ] && ! ip link show "$iface" >/dev/null 2>&1; then
        echo "$iface|$ip|$port|INTERFACE_REMOVED|$fail|$(date +%s)"
    else
        echo "${iface:-?}|$ip|$port|DOWN|$fail|$(date +%s)"
    fi
    return 1
}

# Read-only scan (no config/state rewrites). Output is written atomically.
health_scan() {
    mss_reapply_all >/dev/null 2>&1 || true
    local tmp p ip rp eng iface
    tmp=$(mktemp /run/.mporter-health.XXXXXX) || return 1
    while IFS='|' read -r p ip rp eng; do
        iface=""
        if command -v jq >/dev/null 2>&1 && [ -s "$STATE_FILE" ]; then
            iface=$(jq -r --arg ip "$ip" --argjson p "$p" 'first(.mappings[]? | select(.engine=="HAP" and .target_ip==$ip and .port==$p) | .interface) // ""' "$STATE_FILE" 2>/dev/null)
        fi
        [ -z "$iface" ] || [ "$iface" = "unknown" ] && iface=$(route_dev "$ip")
        health_check_backend "$iface" "$ip" "$rp" 2 >> "$tmp"
    done < <(collect_mappings | awk -F'|' '$4=="HAP" && $2!="127.0.0.1" && $2!="::1"')
    chmod 644 "$tmp"; mv -f "$tmp" "$HEALTH_FILE"
}

show_health_matrix() {
    draw_header
    echo -e "\n  ${DIM}┌─[ BACKEND HEALTH MATRIX ]${NC}"
    printf "  ${B}│${NC} ${W}%-18s %-26s %-7s %-18s %-6s${NC}\n" "INTERFACE" "TARGET" "PORT" "STATE" "FAILS"
    echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────${NC}"
    if [ ! -s "$HEALTH_FILE" ]; then health_scan >/dev/null 2>&1; fi
    if [ -s "$HEALTH_FILE" ]; then
        local iface ip port state fails ts sc
        while IFS='|' read -r iface ip port state fails ts; do
            case "$state" in UP) sc="$G";; DOWN) sc="$R";; INTERFACE_REMOVED) sc="$Y";; *) sc="$DIM";; esac
            printf "  ${B}│${NC} %-18s %-26s %-7s ${sc}%-18s${NC} %-6s\n" "${iface:-?}" "$ip" "$port" "$state" "$fails"
        done < "$HEALTH_FILE"
    else
        echo -e "  ${DIM}│  No HAProxy backends discovered.${NC}"
    fi
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read -r _
}

# ==========================================================
# Dashboard
# ==========================================================

get_iface_info() {
    local target_ip=$1 iface subnet
    iface=$(route_dev "$target_ip")
    if [ -z "$iface" ] || [ "$iface" == "lo" ]; then
        local check_iface=""
        if is_v6 "$target_ip"; then
            subnet="${target_ip%::*}::"
            check_iface=$(ip -o -6 addr show scope global 2>/dev/null | awk -v s="$subnet" 'index(tolower($4), s)==1 && $2!="lo" {print $2; exit}')
        else
            subnet="$(echo "$target_ip" | cut -d'.' -f1-3)."
            check_iface=$(ip -o -4 addr show 2>/dev/null | awk -v s="$subnet" 'index($4, s)==1 && $2!="lo" {print $2; exit}')
        fi
        [ -n "$check_iface" ] && iface="$check_iface"
    fi
    local t_type="System" t_name="$iface" conf proto=""
    # mgre tunnels: protocol comes from the tunnel file, so GRE6 / 6to4 / IPIP variants are labelled exactly
    if [ -n "$iface" ] && conf=$(tunnel_conf_for_iface "$iface") && [ "$(read_conf_value "$conf" T_NAME)" = "$iface" ]; then
        proto=$(read_conf_value "$conf" TUN_PROTO)
    fi
    if [ -n "$proto" ]; then
        case "$proto" in
            6to4) t_type="6to4" ;; gre6) t_type="GRE6" ;; ipip4to4) t_type="IPIP4>4" ;;
            ipip4to6) t_type="IPIP4>6" ;; ipip6to6) t_type="IPIP6>6" ;; *) t_type="GRE" ;;
        esac
        t_name="$iface"
        local pf; for pf in gre6ir gre6kh g6ir g6kh greir grekh i46i i46k i66i i66k i4ir i4kh; do
            if [[ "$iface" == "$pf"* ]]; then t_name="${iface#"$pf"}"; break; fi
        done
    elif [[ "$iface" == greir* ]]; then t_type="GRE"; t_name="${iface#greir}"
    elif [[ "$iface" == grekh* ]]; then t_type="GRE"; t_name="${iface#grekh}"
    elif [[ "$iface" == g6ir* || "$iface" == g6kh* ]]; then t_type="GRE6"; t_name="${iface#g6ir}"; t_name="${t_name#g6kh}"
    elif [[ "$iface" == i4ir* || "$iface" == i4kh* ]]; then t_type="IPIP4>4"; t_name="${iface#i4ir}"; t_name="${t_name#i4kh}"
    elif [[ "$iface" == i46i* || "$iface" == i46k* ]]; then t_type="IPIP4>6"; t_name="${iface#i46i}"; t_name="${t_name#i46k}"
    elif [[ "$iface" == i66i* || "$iface" == i66k* ]]; then t_type="IPIP6>6"; t_name="${iface#i66i}"; t_name="${t_name#i66k}"
    elif [[ "$iface" == vx_* || "$iface" == br_* ]]; then t_type="VXLAN"; t_name="${iface#vx_}"; t_name="${t_name#br_}"
    elif [[ "$iface" == bh_* ]]; then t_type="BACKHAUL"; t_name="${iface#bh_}"
    elif [[ "$iface" == rh_* || "$iface" == rt_* ]]; then t_type="RATHOLE"; t_name="${iface#rh_}"; t_name="${t_name#rt_}"
    elif [[ "$iface" == l2tp_* ]]; then t_type="L2TP"; t_name="${iface#l2tp_}"
    elif [[ "$iface" == hys_* ]]; then t_type="HYSTERIA"; t_name="${iface#hys_}"
    elif [[ "$target_ip" == 127.* || "$target_ip" == "::1" ]]; then t_type="Local"; t_name="Loopback"
    else [ -z "$t_name" ] && t_name="Unknown"; fi
    echo "${t_type}|${t_name}"
}

format_engine() {
    local raw="$1" e_list=() res="" i
    [[ "$raw" == *"HAP"* ]] && e_list+=("${C}HAProxy${NC}")
    [[ "$raw" == *"GST"* ]] && e_list+=("${M}Gost${NC}")
    [[ "$raw" == *"RLM"* ]] && e_list+=("${G}Realm${NC}")
    [[ "$raw" == *"IPT"* ]] && e_list+=("${Y}KernelNAT${NC}")
    [[ "$raw" == *"TUN"* ]] && e_list+=("${B}CoreNAT${NC}")
    for ((i=0; i<${#e_list[@]}; i++)); do
        res+="${e_list[$i]}"; [ $i -lt $(( ${#e_list[@]} - 1 )) ] && res+=" ${DIM}/${NC} "
    done
    echo "$res"
}

# "port|ip|ENGINE" for every mapping incl. tunnel Core-NAT, loopback excluded
all_mapping_rows() {
    { collect_mappings | awk -F'|' '{print $1"|"$2"|"$4}'; tunnel_ext_entries; } | awk -F'|' 'NF==3 && $2 !~ /^127\./ && $2 != "::1"' | sort -u
}

get_stats() {
    local server_ip server_ip6; server_ip=$(get_local_ip); server_ip6=$(get_local_ipv6)
    local hap_stat raw_hap gst_stat raw_gst rlm_stat raw_rlm ipt_stat raw_ipt
    if systemctl is-active --quiet haproxy; then hap_stat="${C}●${NC}"; raw_hap="●"; else hap_stat="${DIM}○${NC}"; raw_hap="○"; fi
    if systemctl is-active --quiet gost; then gst_stat="${M}●${NC}"; raw_gst="●"; else gst_stat="${DIM}○${NC}"; raw_gst="○"; fi
    if systemctl is-active --quiet realm; then rlm_stat="${G}●${NC}"; raw_rlm="●"; else rlm_stat="${DIM}○${NC}"; raw_rlm="○"; fi
    if systemctl is-active --quiet mporter-iptables; then ipt_stat="${Y}●${NC}"; raw_ipt="●"; else ipt_stat="${DIM}○${NC}"; raw_ipt="○"; fi

    MP_ROWS=$(all_mapping_rows)
    local total_ports=0 mapped_ips=0
    if [ -n "$MP_ROWS" ]; then
        total_ports=$(printf '%s\n' "$MP_ROWS" | awk -F'|' '{print $1"|"$3}' | sort -u | wc -l)
        mapped_ips=$(printf '%s\n' "$MP_ROWS" | cut -d'|' -f2 | sort -u | wc -l)
    fi
    local ip_status="${DIM}NONE${NC}" raw_ip="NONE"
    if [ "$mapped_ips" -gt 0 ]; then ip_status="${G}${mapped_ips} ACTIVE${NC}"; raw_ip="${mapped_ips} ACTIVE"; fi

    STATS_SERVER_IP="$server_ip" STATS_SERVER_IP6="$server_ip6" STATS_TOTAL_PORTS="$total_ports" STATS_RAW_HAP="$raw_hap" STATS_RAW_RLM="$raw_rlm" STATS_RAW_GST="$raw_gst" STATS_RAW_IPT="$raw_ipt" STATS_RAW_IP="$raw_ip"
    STATS_HAP_STAT="$hap_stat" STATS_RLM_STAT="$rlm_stat" STATS_GST_STAT="$gst_stat" STATS_IPT_STAT="$ipt_stat" STATS_IP_STATUS="$ip_status"
}

draw_header() {
    get_stats; clear; echo ""
    local raw_text=" MPorter v${MODULE_VERSION} │ IP: ${STATS_SERVER_IP} │ HAP:${STATS_RAW_HAP} RLM:${STATS_RAW_RLM} GST:${STATS_RAW_GST} IPT:${STATS_RAW_IPT} │ IPs: ${STATS_RAW_IP} │ Pts: ${STATS_TOTAL_PORTS} "
    local pad_len=$(( 106 - ${#raw_text} )); (( pad_len < 0 )) && pad_len=0
    local padding; padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MPorter v${MODULE_VERSION}${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${STATS_SERVER_IP}${NC} ${B}│${NC} ${DIM}HAP:${NC} ${STATS_HAP_STAT} ${DIM}RLM:${NC} ${STATS_RLM_STAT} ${DIM}GST:${NC} ${STATS_GST_STAT} ${DIM}IPT:${NC} ${STATS_IPT_STAT} ${B}│${NC} ${DIM}IPs:${NC} ${STATS_IP_STATUS} ${B}│${NC} ${DIM}Pts:${NC} ${G}${STATS_TOTAL_PORTS}${NC}${padding}${B}│${NC}"
    if [ -n "${STATS_SERVER_IP6:-}" ]; then
        local raw6=" IPv6: ${STATS_SERVER_IP6} │ IPv6 targets: HAP/GST/RLM/IPT " pad6
        pad6=$(( 106 - ${#raw6} )); (( pad6 < 0 )) && pad6=0
        echo -e "  ${B}│${NC} ${DIM}IPv6:${NC} ${W}${STATS_SERVER_IP6}${NC} ${B}│${NC} ${DIM}IPv6 targets:${NC} ${G}HAP/GST/RLM/IPT${NC}$(printf '%*s' "$pad6" "")${B}│${NC}"
    fi
    echo -e "  ${B}├──────────────┬──────────┬────────────────────────────┬──────────────────────┬────────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-8s${NC} ${B}│${NC} ${W}%-26s${NC} ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} ${W}%-26s${NC} ${B}│${NC}\n" "TUNNEL NAME" "TYPE" "TARGET NETWORK IPs" "ENGINES" "DISTRIBUTION"
    echo -e "  ${B}├──────────────┼──────────┼────────────────────────────┼──────────────────────┼────────────────────────────┤${NC}"

    local ip_port_counts=""
    [ -n "$MP_ROWS" ] && ip_port_counts=$(printf '%s\n' "$MP_ROWS" | awk -F'|' '{
        k=$2; key=$1"|"$3; if (!(key SUBSEP k in seen)) { seen[key SUBSEP k]=1; a[k]++ }
        if (eng[k]=="") eng[k]=$3; else if (index(eng[k], $3)==0) eng[k]=eng[k] "/" $3
    } END {for (i in a) print i"|"a[i]"|"eng[i]}')
    local obfs_ips; obfs_ips=$(obfs_targets | cut -d'|' -f1 | sort -u)

    if [ -z "$ip_port_counts" ]; then
        printf "  ${B}│${NC} ${DIM}%-104s${NC} ${B}│${NC}\n" "  No active mappings. Ready to route strictly."
    else
        declare -A iface_ips_arr iface_ports_arr iface_eng_arr iface_obfs
        local ip count engs e iface_info
        while IFS='|' read -r ip count engs; do
            [ -n "$ip" ] || continue
            iface_info=$(get_iface_info "$ip")
            iface_ips_arr["$iface_info"]+="$ip "; iface_ports_arr["$iface_info"]=$(( ${iface_ports_arr["$iface_info"]:-0} + count ))
            grep -qxF "$ip" <<< "$obfs_ips" && iface_obfs["$iface_info"]=1
            IFS='/' read -ra eng_list <<< "$engs"
            for e in "${eng_list[@]}"; do [[ "${iface_eng_arr["$iface_info"]:-}" == *"$e"* ]] || iface_eng_arr["$iface_info"]+="$e/"; done
        done <<< "$ip_port_counts"

        while IFS= read -r iface_info; do
            [ -n "$iface_info" ] || continue
            local t_type="${iface_info%%|*}" t_name="${iface_info##*|}" clean_name
            clean_name="$t_name"; [ ${#clean_name} -gt 12 ] && clean_name="${clean_name:0:9}..."
            local ips; read -ra ips <<< "${iface_ips_arr["$iface_info"]}"
            mapfile -t ips < <(printf '%s\n' "${ips[@]}" | sort -V)
            local total_p=${iface_ports_arr["$iface_info"]} display_ips="${ips[0]}"
            if [ ${#ips[@]} -gt 2 ]; then display_ips="${ips[0]}, ${ips[1]}, ..."
            elif [ ${#ips[@]} -eq 2 ]; then display_ips="${ips[0]}, ${ips[1]}"; fi
            [ ${#display_ips} -gt 26 ] && display_ips="${display_ips:0:23}..."
            local disp_eng clean_eng pad_eng; disp_eng=$(format_engine "${iface_eng_arr["$iface_info"]}")
            clean_eng=$(echo -e "$disp_eng" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            pad_eng=$(printf '%*s' "$(( 20 - ${#clean_eng} ))" "")
            local obfs_indicator=""; [ -n "${iface_obfs["$iface_info"]:-}" ] && obfs_indicator="${M}[OBFS]${NC}"
            local fwd_dist="${Y}${total_p} Ports${NC} ${obfs_indicator}" clean_fwd pad
            clean_fwd=$(echo -e "$fwd_dist" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            pad=$(printf '%*s' "$(( 26 - ${#clean_fwd} ))" "")
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-8s${NC} ${B}│${NC} ${G}%-26s${NC} ${B}│${NC} %b%s ${B}│${NC} %b%s ${B}│${NC}\n" "$clean_name" "$t_type" "$display_ips" "$disp_eng" "$pad_eng" "$fwd_dist" "$pad"
        done < <(printf '%s\n' "${!iface_ips_arr[@]}" | sort)
    fi
    echo -e "  ${B}╰──────────────┴──────────┴────────────────────────────┴──────────────────────┴────────────────────────────╯${NC}"
}

engine_ready() {
    case "$1" in
        1) command -v haproxy >/dev/null 2>&1 && [ -f "$H_CONF" ] ;;
        2) [ -x /usr/local/bin/gost ] && [ -f "$G_CONF" ] && ensure_jq ;;
        3) [ -x /usr/local/bin/realm ] && [ -f "$R_CONF" ] && ensure_jq ;;
        4) command -v iptables >/dev/null 2>&1 && [ -x /usr/local/bin/mporter-iptables.sh ] ;;
        *) return 1 ;;
    esac
}

# ==========================================================
# Strict 1-to-1 mapping
# ==========================================================

smart_map() {
    draw_header
    echo -e "\n  ${DIM}┌─[ STRICT FORWARDING ENGINE (1-to-1) ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC} ${DIM}(Load Balancer / Stable)${NC}"
    echo -e "  ${DIM}│${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC} ${DIM}(TLS/WS Obfuscator)${NC}"
    echo -e "  ${DIM}│${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Realm${NC} ${DIM}(High-Performance / Rust)${NC}"
    echo -e "  ${DIM}│${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Iptables Kernel NAT${NC} ${DIM}(Raw Speed / 0% CPU)${NC}"
    echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; local fwd_engine; read -r fwd_engine
    fwd_engine="${fwd_engine//[^0-9]/}"
    [[ "$fwd_engine" =~ ^[1-4]$ ]] || { echo -e "  ${R}● Invalid engine!${NC}"; sleep 1; return; }
    engine_ready "$fwd_engine" || { echo -e "  ${R}● This engine is not installed yet. Run option 1 (Install) first.${NC}"; sleep 2; return; }

    local gre_ifs=(); mapfile -t gre_ifs < <(tunnel_ifaces)
    local target_ip="" selected_if="Manual" is_auto_all=false auto_peers=() if_choice ip_choice custom_target

    if [ ${#gre_ifs[@]} -eq 0 ]; then
        echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read -r target_ip
    else
        echo -e "\n  ${B}╭────────────────── Available Interfaces ────────────────────╮${NC}"
        local i; for i in "${!gre_ifs[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-52s${NC} ${B}│${NC}\n" "$i" "${gre_ifs[$i]}"; done
        echo -e "  ${B}├──────────────────────────────────────────────────────────────┤${NC}"
        printf "  ${B}│${NC}  ${Y}m${NC} ${C}❯${NC} ${M}%-52s${NC} ${B}│${NC}\n" "Manual IP Entry (Bypass Interfaces)"
        echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
        echo -ne "  ${C}●${NC} ${W}Select Interface (0-$(( ${#gre_ifs[@]} - 1 )) or 'm'): ${NC}"; read -r if_choice
        if_choice="${if_choice//[^0-9mM]/}"
        if [[ "$if_choice" =~ ^[mM]$ ]]; then
            echo -ne "\n  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read -r target_ip
        elif [[ "$if_choice" =~ ^[0-9]+$ ]] && [ -n "${gre_ifs[$if_choice]:-}" ]; then
            selected_if="${gre_ifs[$if_choice]}"
            local map_ips=(); mapfile -t map_ips < <({ ip -o -4 addr show dev "$selected_if" 2>/dev/null; ip -o -6 addr show dev "$selected_if" scope global 2>/dev/null; } | awk '{print $4}' | cut -d/ -f1)
            if [ ${#map_ips[@]} -eq 0 ]; then
                echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read -r target_ip
            else
                echo -e "\n  ${B}╭────────────────── IPs on ${selected_if} ──────────────────╮${NC}"
                for i in "${!map_ips[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${G}%-50s${NC} ${B}│${NC}\n" "$i" "${map_ips[$i]}"; done
                echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
                echo -ne "  ${C}●${NC} ${W}Select EXACT Index (0-$(( ${#map_ips[@]} - 1 ))) or 'a' for Auto-Distribute: ${NC}"; read -r ip_choice
                ip_choice="${ip_choice//[^0-9aA]/}"
                if [[ "$ip_choice" =~ ^[aA]$ ]]; then
                    is_auto_all=true
                    mapfile -t auto_peers < <(discover_peer_ips "$selected_if")
                    [ ${#auto_peers[@]} -gt 0 ] || { echo -e "  ${R}● No peers discovered for auto-distribution.${NC}"; sleep 1.5; return; }
                    echo -e "  ${G}✔ Peers:${NC} ${auto_peers[*]}"
                elif [[ "$ip_choice" =~ ^[0-9]+$ ]] && [ -n "${map_ips[$ip_choice]:-}" ]; then
                    local calc_target; calc_target="$(discover_peer_ips "$selected_if" "${map_ips[$ip_choice]}" | head -n1)"
                    if [ -n "$calc_target" ]; then
                        echo -ne "\n  ${C}●${NC} ${W}Confirm Target IP [${calc_target}]: ${NC}"; read -r custom_target
                        target_ip="${custom_target:-$calc_target}"
                    else
                        echo -e "  ${Y}⚠ Could not safely discover the tunnel peer.${NC}"
                        echo -ne "  ${C}●${NC} ${W}Enter Target IP manually: ${NC}"; read -r target_ip
                    fi
                else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            fi
        else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
    fi

    target_ip="${target_ip//[[:space:]]/}"; target_ip="${target_ip#[}"; target_ip="${target_ip%]}"; target_ip="${target_ip,,}"
    if [ "$is_auto_all" = false ] && ! valid_target_ip "$target_ip"; then echo -e "  ${R}● Invalid IP format! (IPv4 or global/ULA IPv6; link-local is not allowed)${NC}"; sleep 1.5; return; fi

    local raw_ports clean_ports
    echo -ne "\n  ${C}●${NC} ${W}Enter Exact Local Ports (e.g. 80,443): ${NC}"; read -r raw_ports
    clean_ports=$(parse_ports "$raw_ports")
    [ -n "$clean_ports" ] || { echo -e "  ${R}● No valid ports (1-65535).${NC}"; sleep 1.5; return; }

    echo -e "\n  ${Y}● Applying Strict 1-to-1 Mappings...${NC}"
    echo -e "  ${B}╭──────────────┬─────────┬────────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "Local Port" "Engine" "Target IP"
    echo -e "  ${B}├──────────────┼─────────┼────────────────────────────────────────────┤${NC}"

    declare -A map_target=()
    local mapped_ports=() work="" ipt_add="" port_idx=0 p t owner eng_name
    case "$fwd_engine" in
        1) work=$(mp_tmp hap); cp -f "$H_CONF" "$work"; eng_name="HAProxy" ;;
        2) work=$(mp_tmp gost); cp -f "$G_CONF" "$work"; eng_name="Gost" ;;
        3) work=$(mp_tmp realm); cp -f "$R_CONF" "$work"; eng_name="Realm" ;;
        4) eng_name="Iptable" ;;
    esac

    for p in $clean_ports; do
        t="$target_ip"
        [ "$is_auto_all" = true ] && t="${auto_peers[$((port_idx % ${#auto_peers[@]}))]}"
        owner=$(port_owner "$p")
        if [ -n "$owner" ]; then printf "  ${B}│${NC} ${R}%-12s${NC} ${B}│${NC} ${DIM}%-7s${NC} ${B}│${NC} ${DIM}%-42s${NC} ${B}│${NC}\n" "$p" "-" "Skipped ($owner)"; continue; fi
        case "$fwd_engine" in
            1) printf '%s\n' "frontend ft_$p" "    mode tcp" "    bind *:$p" "    default_backend bk_$p" "backend bk_$p" "    mode tcp" "    server srv_$p $(hap_addr "$t" "$p") check inter 5s" >> "$work" ;;
            2) jq --arg node "tcp://:$p/$(hostport "$t" "$p")" '.ServeNodes = ((.ServeNodes // []) + [$node])' "$work" > "$work.n" && mv -f "$work.n" "$work" ;;
            3) jq --arg lp "0.0.0.0:$p" --arg rp "$(hostport "$t" "$p")" '.endpoints = ((.endpoints // []) + [{listen:$lp, remote:$rp}])' "$work" > "$work.n" && mv -f "$work.n" "$work" ;;
            4) local ipb; ipb=$(ipt_bin_for "$t")
               ipt_add+="$ipb -t nat -A PREROUTING -p tcp --dport $p -m addrtype --dst-type LOCAL -m comment --comment \"MPORTER_NAT_$t\" -j DNAT --to-destination $(hostport "$t" "$p")"$'\n'
               ipt_add+="$ipb -t nat -A POSTROUTING -d $t -p tcp --dport $p -m comment --comment \"MPORTER_NAT_$t\" -j MASQUERADE"$'\n'
               ipt_add+="$ipb -I FORWARD -d $t -p tcp --dport $p -m comment --comment \"MPORTER_NAT_$t\" -j ACCEPT"$'\n'
               ipt_add+="$ipb -I FORWARD -s $t -p tcp --sport $p -m comment --comment \"MPORTER_NAT_$t\" -j ACCEPT"$'\n'
               if is_v6 "$t"; then enable_v6_forwarding; command -v ip6tables >/dev/null 2>&1 || echo -e "  ${Y}⚠ ip6tables not found: IPv6 Kernel NAT rule for $t will not apply.${NC}"; fi ;;
        esac
        map_target[$p]="$t"; mapped_ports+=("$p")
        printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${C}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "$eng_name" "$t"
        port_idx=$((port_idx + 1))
    done
    echo -e "  ${B}╰──────────────┴─────────┴────────────────────────────────────────────╯${NC}"

    if [ ${#mapped_ports[@]} -eq 0 ]; then
        rm -f "$work" 2>/dev/null; echo -ne "\n  ${Y}● Nothing to apply. Press Enter...${NC}"; read -r _; return
    fi

    local ok=true
    case "$fwd_engine" in
        1) hap_commit "$work" || ok=false ;;
        2) json_engine_commit "$G_CONF" "$work" gost || ok=false ;;
        3) json_engine_commit "$R_CONF" "$work" realm || ok=false ;;
        4) printf '%s' "$ipt_add" >> "$IPT_CONF"; systemctl restart mporter-iptables >/dev/null 2>&1 || ok=false ;;
    esac
    if [ "$ok" = false ]; then
        echo -e "  ${R}✖ Engine failed to apply the change; previous configuration restored.${NC}"
        echo -ne "  ${DIM}Press Enter...${NC}"; read -r _; return
    fi
    setup_mporter_service

    if [ "$fwd_engine" == "1" ] || [ "$fwd_engine" == "4" ]; then
        local enable_obfs; echo -ne "\n  ${C}●${NC} ${W}Enable Strict OBFS Stealth for these ports? (y/n): ${NC}"; read -r enable_obfs
        if [[ "${enable_obfs,,}" == "y" ]]; then obfs_setup "$fwd_engine" "$selected_if" map_target "${mapped_ports[@]}"; fi
    fi

    state_reconcile >/dev/null 2>&1 || true
    state_sync_interface_metadata >/dev/null 2>&1 || true
    [ "$selected_if" != "Manual" ] && apply_scoped_mss "$selected_if"
    echo -ne "\n  ${G}● Success! Press Enter...${NC}"; read -r _
}

# obfs_setup <engine 1|4> <iface|Manual> <assoc-array-name port->target> <ports...>
obfs_setup() {
    local engine="$1" selected_if="$2"; local -n _targets="$3"; shift 3
    if ! [ -x /usr/local/bin/gost ]; then
        echo -e "  ${C}⟳${NC} ${W}OBFS needs the gost binary, installing...${NC}"
        download_gost_binary || { echo -e "  ${R}✖ gost download failed; OBFS skipped.${NC}"; return 1; }
    fi
    local remote_pub="" conf stealth_port t_proto method
    if [ "$selected_if" != "Manual" ] && conf=$(tunnel_conf_for_iface "$selected_if"); then remote_pub=$(read_conf_value "$conf" REMOTE_PUB)
        valid_host "$remote_pub" || remote_pub=$(read_conf_value "$conf" REMOTE_PUB6)   # IPv6 underlay (mgre/mxlan)
    fi
    if valid_host "$remote_pub"; then
        echo -e "  ${G}✔ Auto-detected Kharej IP: ${remote_pub}${NC}"
    else
        echo -ne "  ${C}●${NC} ${W}Enter Kharej Server PUBLIC IP / host: ${NC}"; read -r remote_pub; remote_pub="${remote_pub//[[:space:]]/}"; remote_pub="${remote_pub#[}"; remote_pub="${remote_pub%]}"
    fi
    valid_host "$remote_pub" || { echo -e "  ${R}✖ Invalid host; OBFS skipped.${NC}"; return 1; }
    echo -ne "  ${C}●${NC} ${W}Enter Kharej Stealth Port (Target Receiver): ${NC}"; read -r stealth_port
    valid_port "$stealth_port" || { echo -e "  ${R}✖ Invalid port; OBFS skipped.${NC}"; return 1; }
    echo -ne "  ${C}●${NC} ${W}Select Protocol [1: mTLS | 2: mWS | 3: mWSS] (Default 1): ${NC}"; read -r t_proto
    method="relay+mtls"; [ "$t_proto" == "2" ] && method="relay+mws"; [ "$t_proto" == "3" ] && method="relay+mwss"

    mkdir -p "$OBFS_DIR"; touch "$OBFS_DIR/nat.sh" "$OBFS_DIR/gost.sh"
    local ctag="${selected_if//[^a-zA-Z0-9_]/_}" p t lport tag
    local ipb loop_l rfhp
    rfhp=$(hostport "$remote_pub" "$stealth_port")
    for p in "$@"; do
        t="${_targets[$p]}"; valid_target_ip "$t" || continue
        ipb=$(ipt_bin_for "$t"); loop_l="127.0.0.1"; is_v6 "$t" && loop_l="[::1]"
        lport=$(find_free_local_port "$p") || { echo -e "  ${R}● No free OBFS local port for $p; skipping.${NC}"; continue; }
        tag="# MP_OBFS ip=$t port=$p lport=$lport "
        if [ "$engine" = "1" ]; then
            # HAProxy dials target:p locally -> nat OUTPUT -> gost on loopback
            echo "$ipb -t nat -A OUTPUT -d $t -p tcp --dport $p -m comment --comment \"MPORTER_OBFS_${lport}\" -j REDIRECT --to-ports $lport 2>/dev/null $tag" >> "$OBFS_DIR/nat.sh"
            echo "/usr/local/bin/gost -L tcp://$loop_l:$lport/$(hostport "$t" "$p") -F $method://$rfhp & $tag" >> "$OBFS_DIR/gost.sh"
        else
            # Kernel NAT traffic never reaches nat OUTPUT: catch it in PREROUTING before the DNAT rule
            echo "$ipb -t nat -I PREROUTING 1 -p tcp --dport $p -m addrtype --dst-type LOCAL -m comment --comment \"MPORTER_OBFS_${lport}\" -j REDIRECT --to-ports $lport 2>/dev/null $tag" >> "$OBFS_DIR/nat.sh"
            echo "/usr/local/bin/gost -L tcp://:$lport/$(hostport "$t" "$p") -F $method://$rfhp & $tag" >> "$OBFS_DIR/gost.sh"
        fi
        if ! grep -qF "# MP_CNT ip=$t " "$OBFS_DIR/nat.sh"; then
            echo "$ipb -t mangle -A OUTPUT -d $t -m comment --comment \"OBFS_CNT_TX_${ctag}\" 2>/dev/null # MP_CNT ip=$t iface=$ctag " >> "$OBFS_DIR/nat.sh"
            echo "$ipb -t mangle -A INPUT -s $t -m comment --comment \"OBFS_CNT_RX_${ctag}\" 2>/dev/null # MP_CNT ip=$t iface=$ctag " >> "$OBFS_DIR/nat.sh"
        fi
        echo -e "  ${M}● OBFS${NC} $p ➔ $t ${DIM}(local $lport, $method://$rfhp)${NC}"
    done
    build_obfs_runner; echo -e "\n  ${G}● OBFS Stealth Layer configured dynamically!${NC}"
}

# ==========================================================
# Smart Loadbalance (keeps other pools, never duplicates frontends)
# ==========================================================

smart_loadbalance() {
    draw_header
    echo -e "\n  ${DIM}┌─[ SMART LOADBALANCE v11 ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}Architecture:${NC} ${C}HAProxy L4${NC} ${DIM}+${NC} ${G}central state${NC} ${DIM}+${NC} ${M}health monitor${NC}"
    echo -e "  ${DIM}│${NC} ${DIM}Backend DOWN never deletes the mapping. Existing pools on other ports are kept.${NC}\n"
    engine_ready 1 || { echo -e "  ${R}● HAProxy is not installed. Run option 1 (Install) first.${NC}"; sleep 2; return; }

    local raw_ports clean_ports
    echo -ne "  ${C}●${NC} ${W}Ports (e.g. 443,8443): ${NC}"; read -r raw_ports
    clean_ports=$(parse_ports "$raw_ports")
    [ -n "$clean_ports" ] || { echo -e "  ${R}● Invalid port list.${NC}"; sleep 1.5; return; }

    local active_ifs=(); mapfile -t active_ifs < <(tunnel_ifaces)
    [ ${#active_ifs[@]} -gt 0 ] || { echo -e "  ${R}● No active MDesign interfaces found.${NC}"; sleep 2; return; }

    echo -e "  ${B}╭──────────────────── Interfaces ─────────────────────╮${NC}"
    local i; for i in "${!active_ifs[@]}"; do printf "  ${B}│${NC} ${Y}%2d${NC} ${C}❯${NC} %-49s ${B}│${NC}\n" "$i" "${active_ifs[$i]}"; done
    echo -e "  ${B}╰──────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}Select Interface ❯❯ ${NC}"; read -r i
    [[ "$i" =~ ^[0-9]+$ ]] && [ -n "${active_ifs[$i]:-}" ] || { echo -e "  ${R}● Invalid selection.${NC}"; sleep 1.5; return; }
    local selected_if="${active_ifs[$i]}"

    echo -e "\n  ${C}⟳${NC} ${W}Discovering peer addresses from tunnel metadata / neighbour cache...${NC}"
    local peer_ips=(); mapfile -t peer_ips < <(discover_peer_ips "$selected_if")
    if [ ${#peer_ips[@]} -eq 0 ]; then
        echo -e "  ${R}● No peer IP could be resolved safely.${NC}"
        echo -e "  ${DIM}  v11 refuses blind .1/.2 guessing except for verified /30 and /31 links.${NC}"
        sleep 2.5; return
    fi

    echo -e "\n  ${B}╭──────────────────── Discovered Peers ─────────────────╮${NC}"
    for i in "${!peer_ips[@]}"; do printf "  ${B}│${NC} ${Y}%2d${NC} ${C}❯${NC} ${G}%-50s${NC} ${B}│${NC}\n" "$i" "${peer_ips[$i]}"; done
    echo -e "  ${B}╰───────────────────────────────────────────────────────╯${NC}"
    local peer_count; echo -ne "  ${C}How many peers to use? [1-${#peer_ips[@]}, a=all] ❯❯ ${NC}"; read -r peer_count
    local selected_peers=()
    if [[ "$peer_count" == "a" || "$peer_count" == "A" ]]; then selected_peers=("${peer_ips[@]}")
    elif [[ "$peer_count" =~ ^[0-9]+$ ]] && [ "$peer_count" -ge 1 ] && [ "$peer_count" -le "${#peer_ips[@]}" ]; then selected_peers=("${peer_ips[@]:0:peer_count}")
    else echo -e "  ${R}● Invalid peer count.${NC}"; sleep 1.5; return; fi

    local lb_mode balance mode
    echo -ne "  ${C}●${NC} ${W}HAProxy distribution [1 leastconn / 2 roundrobin / 3 first-up failover] (default 1): ${NC}"; read -r lb_mode
    case "$lb_mode" in 2) balance="roundrobin"; mode="LOADBALANCE";; 3) balance="first"; mode="FAILOVER";; *) balance="leastconn"; mode="LOADBALANCE";; esac

    echo -e "\n  ${C}●${NC} ${W}Preparing atomic HAProxy configuration...${NC}"
    ensure_haproxy_base
    local final_ports=() replaced=() p owner
    for p in $clean_ports; do
        owner=$(port_owner "$p")
        if [ "$owner" = "HAProxy" ]; then replaced+=("$p")
        elif [ -n "$owner" ]; then echo -e "  ${Y}⚠${NC} Port $p is already used by ${owner}; skipped."; continue; fi
        final_ports+=("$p")
    done
    [ ${#final_ports[@]} -gt 0 ] || { echo -e "  ${R}● No usable ports left.${NC}"; sleep 2; return; }
    [ ${#replaced[@]} -gt 0 ] && echo -e "  ${Y}⚠${NC} Existing HAProxy mapping(s) on ${replaced[*]} will be replaced by this pool."

    local base block out
    base=$(mp_tmp hapbase); block=$(mp_tmp hapblock); out=$(mp_tmp hapout)
    hap_strip_ports "${final_ports[*]}" "$H_CONF" > "$base"
    for p in "${final_ports[@]}"; do
        printf '%s\n' "frontend ft_$p" "    mode tcp" "    bind *:$p" "    default_backend bk_$p" "backend bk_$p" "    mode tcp" "    balance $balance" >> "$block"
        local srv_idx=1 target
        for target in "${selected_peers[@]}"; do
            echo "    server srv_${p}_${srv_idx} $(hap_addr "$target" "$p") check inter 3s fall 2 rise 2 observe layer4 error-limit 3 on-error mark-down" >> "$block"
            srv_idx=$((srv_idx + 1))
        done
    done
    if grep -qxF "$LB_MARKER" "$base"; then
        grep -qxF "$LB_END_MARKER" "$base" || echo "$LB_END_MARKER" >> "$base"   # repair v10 damage
        awk -v e="$LB_END_MARKER" -v bf="$block" '$0==e { while ((getline l < bf) > 0) print l; close(bf) } { print }' "$base" > "$out"
    else
        { cat "$base"; echo "$LB_MARKER"; echo "# Managed by MPorter (pools are added/replaced per port)"; cat "$block"; echo "$LB_END_MARKER"; } > "$out"
    fi
    rm -f "$base" "$block"
    hap_commit "$out" || { sleep 2.5; return; }

    state_reconcile >/dev/null 2>&1 || true
    state_sync_interface_metadata >/dev/null 2>&1 || true
    apply_scoped_mss "$selected_if"
    if command -v jq >/dev/null 2>&1; then
        local targets_json ports_json pool_id="${selected_if}:$(IFS=,; echo "${final_ports[*]}")"
        targets_json=$(printf '%s\n' "${selected_peers[@]}" | jq -R '{ip:.}' | jq -s .)
        ports_json=$(printf '%s\n' "${final_ports[@]}" | jq -s 'map(tonumber)')
        state_apply --argjson ports "$ports_json" --arg iface "$selected_if" --arg balance "$balance" --arg mode "$mode" --arg pid "$pool_id" --argjson targets "$targets_json" --arg now "$(date -Is)" '
            .pools = ([.pools[] | .ports -= $ports | select((.ports|length) > 0)] + [{id:$pid, interface:$iface, ports:$ports, balance:$balance, mode:$mode, targets:$targets, updated_at:$now}])
          | .mappings |= map(if .engine=="HAP" and ((.port) as $x | $ports | index([$x])) != null then .interface=$iface | .mode=$mode | .pool=$pid | .updated_at=$now else . end)
          | .updated_at = $now' >/dev/null 2>&1
    fi

    echo -e "\n  ${G}✔ Loadbalance pool applied safely.${NC}"
    echo -e "  ${DIM}Interface : $selected_if${NC}"
    echo -e "  ${DIM}Ports     : ${final_ports[*]}${NC}"
    echo -e "  ${DIM}Peers     : ${selected_peers[*]}${NC}"
    echo -e "  ${DIM}Strategy  : $balance / $mode${NC}"
    local hc; echo -ne "\n  ${G}● Health-check these backends now? (y/n) ❯❯ ${NC}"; read -r hc
    [[ "${hc,,}" == "y" ]] && health_scan
    echo -ne "\n  ${G}● Done. Press Enter...${NC}"; read -r _
}

# ==========================================================
# Matrix view
# ==========================================================

show_table() {
    draw_header; echo -e "\n  ${Y}● Detailed IP -> Port Matrix:${NC}"
    echo -e "  ${B}├──────────────┬──────────┬────────────────────────────┬──────────────────────────┬────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-8s${NC} ${B}│${NC} ${W}%-26s${NC} ${B}│${NC} ${W}%-24s${NC} ${B}│${NC} ${W}%-22s${NC} ${B}│${NC}\n" "TUNNEL NAME" "TYPE" "TARGET IP" "FORWARD ENGINE" "FORWARDED PORTS"
    echo -e "  ${B}├──────────────┼──────────┼────────────────────────────┼──────────────────────────┼────────────────────────┤${NC}"

    if [ -z "$MP_ROWS" ]; then
        printf "  ${B}│${NC} ${DIM}%-104s${NC} ${B}│${NC}\n" "  No active mappings. Ready to route strictly."
    else
        declare -A ip_ports_arr ip_eng_arr obfs_set
        local p_num d_ip eng o
        while IFS='|' read -r p_num d_ip eng; do
            [ -n "$d_ip" ] || continue
            ip_ports_arr["$d_ip"]+="$p_num "
            [[ "${ip_eng_arr["$d_ip"]:-}" == *"$eng"* ]] || ip_eng_arr["$d_ip"]+="$eng/"
        done <<< "$MP_ROWS"
        while IFS= read -r o; do [ -n "$o" ] && obfs_set["$o"]=1; done < <(obfs_targets)

        while IFS= read -r d_ip; do
            [ -n "$d_ip" ] || continue
            local iface_info t_type t_name clean_name disp_eng clean_eng pad_eng display_ports="" clean_str pad p
            iface_info=$(get_iface_info "$d_ip"); t_type="${iface_info%%|*}"; t_name="${iface_info##*|}"
            clean_name="$t_name"; [ ${#clean_name} -gt 12 ] && clean_name="${clean_name:0:9}..."
            disp_eng=$(format_engine "${ip_eng_arr[$d_ip]}")
            clean_eng=$(echo -e "$disp_eng" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            pad_eng=$(printf '%*s' "$(( 24 - ${#clean_eng} ))" "")
            for p in $(printf '%s\n' ${ip_ports_arr[$d_ip]} | sort -un); do
                if [ -n "${obfs_set["$d_ip|$p"]:-}" ]; then display_ports+="${M}${p}*(OBFS)${Y}, "; else display_ports+="${p}, "; fi
            done
            display_ports="${display_ports%, }"; clean_str=$(echo -e "$display_ports" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            if [ ${#clean_str} -gt 22 ]; then display_ports="${clean_str:0:19}..."; clean_str="$display_ports"; fi
            pad=$(printf '%*s' "$((22 - ${#clean_str}))" "")
            local show_ip="$d_ip"; [ ${#show_ip} -gt 26 ] && show_ip="${show_ip:0:23}..."
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-8s${NC} ${B}│${NC} ${G}%-26s${NC} ${B}│${NC} %b%s ${B}│${NC} ${Y}%b%s${NC} ${B}│${NC}\n" "$clean_name" "$t_type" "$show_ip" "$disp_eng" "$pad_eng" "$display_ports" "$pad"
        done < <(printf '%s\n' "${!ip_ports_arr[@]}" | sort -V)
    fi
    echo -e "  ${B}╰──────────────┴──────────┴────────────────────────────┴──────────────────────────┴────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read -r _
}

# ==========================================================
# Edit mappings (was missing in v10)
# ==========================================================

edit_mapping() {
    draw_header
    echo -e "\n  ${DIM}┌─[ EDIT MAPPINGS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add Port Mappings${NC} ${DIM}(Strict 1-to-1 wizard)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Remove a Single Local Port${NC} ${DIM}(all engines)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Disable OBFS on a Port${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    local e_opt idx; echo -ne "  ${C}Select ❯❯ ${NC}"; read -r e_opt
    case "$e_opt" in
        1) smart_map ;;
        2)
            local rows=(); mapfile -t rows < <(collect_mappings | awk -F'|' '$2 !~ /^127\./ && $2 != "::1" {print $1"|"$4}' | sort -u | awk -F'|' '{a[$1]=a[$1] (a[$1]?"/":"") $2} END {for (k in a) print k"|"a[k]}' | sort -t'|' -k1,1n)
            [ ${#rows[@]} -gt 0 ] || { echo -e "  ${R}● No MPorter mappings found.${NC}"; sleep 1.5; return; }
            echo -e "\n  ${B}╭────────────── Local Ports ──────────────╮${NC}"
            local i; for i in "${!rows[@]}"; do printf "  ${B}│${NC}  ${Y}%02d${NC} ${C}❯${NC} ${W}%-7s${NC} ${DIM}%-24s${NC} ${B}│${NC}\n" "$i" "${rows[$i]%%|*}" "${rows[$i]#*|}"; done
            echo -e "  ${B}╰─────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}Select Index ❯❯ ${NC}"; read -r idx; idx="${idx//[^0-9]/}"
            [ -n "$idx" ] && [ -n "${rows[$idx]:-}" ] || { echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; }
            local port="${rows[$idx]%%|*}" confirm
            echo -ne "  ${Y}● Remove local port $port from every engine? (y/n): ${NC}"; read -r confirm
            if [[ "${confirm,,}" == "y" ]]; then
                purge_port_core "$port"; restart_all_engines
                echo -e "  ${G}● Port $port removed.${NC}"; sleep 1.5
            fi ;;
        3)
            local orows=(); mapfile -t orows < <(obfs_targets | sort -u)
            [ ${#orows[@]} -gt 0 ] || { echo -e "  ${R}● No OBFS ports configured.${NC}"; sleep 1.5; return; }
            local i; for i in "${!orows[@]}"; do printf "  ${Y}%02d${NC} ${C}❯${NC} port ${W}%s${NC} ➔ %s\n" "$i" "${orows[$i]#*|}" "${orows[$i]%%|*}"; done
            echo -ne "  ${C}Select Index ❯❯ ${NC}"; read -r idx; idx="${idx//[^0-9]/}"
            [ -n "$idx" ] && [ -n "${orows[$idx]:-}" ] || { echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; }
            obfs_filter port "${orows[$idx]#*|}"; obfs_reload; state_reconcile >/dev/null 2>&1
            echo -e "  ${G}● OBFS disabled on port ${orows[$idx]#*|} (mapping kept).${NC}"; sleep 1.5 ;;
        *) return ;;
    esac
}

# ==========================================================
# Purge menu
# ==========================================================

purge_menu() {
    draw_header; echo -e "\n  ${DIM}┌─[ DELETE & PURGE MAPPINGS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${Y}Purge Specific Interface${NC} ${DIM}(Removes all IPs on an interface)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Purge Specific Target IP${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Wipe ALL Mappings Globally${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    local p_opt idx confirm; echo -ne "  ${C}Select ❯❯ ${NC}"; read -r p_opt; p_opt="${p_opt//[^0-3]/}"

    local all_ips; all_ips=$(collect_mappings | cut -d'|' -f2 | grep -v -E '^(127\.|::1$)' | sort -uV)

    case $p_opt in
        1)
            [ -n "$all_ips" ] || { echo -e "  ${R}● No active mappings found!${NC}"; sleep 2; return; }
            declare -A iface_ips; local ip ifc_info i=0 iface_list=()
            for ip in $all_ips; do ifc_info=$(get_iface_info "$ip"); iface_ips["$ifc_info"]+="$ip "; done
            echo -e "\n  ${B}╭────────────────── Select Interface to Purge ─────────────────╮${NC}"
            while IFS= read -r ifc_info; do
                [ -n "$ifc_info" ] || continue
                iface_list[$i]="$ifc_info"; local ip_arr; read -ra ip_arr <<< "${iface_ips[$ifc_info]}"
                local disp_name="${ifc_info##*|} [${ifc_info%%|*}]" raw_str pad sp
                raw_str=$(printf "  %02d ❯ %-22s (Contains %-2d IPs)" "$i" "$disp_name" "${#ip_arr[@]}"); pad=$(( 58 - ${#raw_str} )); [ "$pad" -lt 0 ] && pad=0; sp=$(printf '%*s' "$pad" "")
                printf "  ${B}│${NC}  ${Y}%02d${NC} ${C}❯${NC} ${W}%-22s${NC} ${DIM}(Contains %-2d IPs)${NC}%s${B}│${NC}\n" "$i" "$disp_name" "${#ip_arr[@]}" "$sp"
                i=$((i + 1))
            done < <(printf '%s\n' "${!iface_ips[@]}" | sort)
            echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}Select Index ❯❯ ${NC}"; read -r idx; idx="${idx//[^0-9]/}"
            local selected_ifc_info="${iface_list[${idx:-x}]:-}"
            [ -n "$selected_ifc_info" ] || { echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; }
            local t_name="${selected_ifc_info##*|}"
            echo -ne "  ${Y}● Deep Purge ALL IPs on $t_name? (y/n): ${NC}"; read -r confirm
            if [[ "${confirm,,}" == "y" ]]; then
                for ip in ${iface_ips[$selected_ifc_info]}; do purge_ip_core "$ip"; done
                restart_all_engines
                echo -e "  ${G}● Interface $t_name purged successfully!${NC}"; sleep 1.5
            fi ;;
        2)
            [ -n "$all_ips" ] || { echo -e "  ${R}● No active mappings found!${NC}"; sleep 2; return; }
            local ip_arr; read -ra ip_arr <<< "$(echo $all_ips)"
            echo -e "\n  ${B}╭────────────────── Select Target IP to Purge ─────────────────╮${NC}"
            local i; for i in "${!ip_arr[@]}"; do
                local ifc_info disp_name raw_str pad sp
                ifc_info=$(get_iface_info "${ip_arr[$i]}"); disp_name="${ifc_info##*|} [${ifc_info%%|*}]"
                raw_str=$(printf "  %02d ❯ %-26s (%s)" "$i" "${ip_arr[$i]}" "$disp_name"); pad=$(( 58 - ${#raw_str} )); [ "$pad" -lt 0 ] && pad=0; sp=$(printf '%*s' "$pad" "")
                printf "  ${B}│${NC}  ${Y}%02d${NC} ${C}❯${NC} ${W}%-26s${NC} ${DIM}(%s)${NC}%s${B}│${NC}\n" "$i" "${ip_arr[$i]}" "$disp_name" "$sp"
            done
            echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}Select Index ❯❯ ${NC}"; read -r idx; idx="${idx//[^0-9]/}"
            local target_ip="${ip_arr[${idx:-x}]:-}"
            [ -n "$target_ip" ] || { echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; }
            echo -ne "  ${Y}● Purge every mapping to $target_ip? (y/n): ${NC}"; read -r confirm
            if [[ "${confirm,,}" == "y" ]]; then
                purge_ip_core "$target_ip"; restart_all_engines
                echo -e "  ${G}● IP $target_ip purged successfully!${NC}"; sleep 1.5
            fi ;;
        3)
            echo -ne "  ${R}● Wipe all active mappings globally? (y/n) ❯❯ ${NC}"; read -r confirm
            if [[ "${confirm,,}" == "y" ]]; then
                if [ -f "$H_CONF" ]; then local t; t=$(mp_tmp hap); hap_base_config > "$t"; hap_commit "$t" >/dev/null || hap_base_config > "$H_CONF"; fi
                [ -f "$G_CONF" ] && echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"
                [ -f "$R_CONF" ] && echo '{"network": {"no_tcp_delay": true}, "endpoints": []}' > "$R_CONF"
                : > "$IPT_CONF"; rm -f "$OBFS_DIR/nat.sh" "$OBFS_DIR/gost.sh"
                rm -f "$STATE_FILE"; state_init >/dev/null 2>&1
                restart_all_engines
                echo -e "  ${G}● All global mappings wiped. Core configs preserved.${NC}"; sleep 1.5
            fi ;;
        *) return ;;
    esac
}

# ==========================================================
# Watchdog / restart
# ==========================================================

setup_watchdog() {
    cat > "$WATCHDOG_SCRIPT" <<'EOF_WD'
#!/bin/bash
set -u
while true; do
    /usr/bin/mporter --health-scan >/dev/null 2>&1 || true
    sleep 15
done
EOF_WD
    chmod +x "$WATCHDOG_SCRIPT"
    cat > "/etc/systemd/system/$WATCHDOG_SERVICE" <<EOF_WDS
[Unit]
Description=MPorter v11 Backend Health Watchdog
After=network.target haproxy.service
Wants=haproxy.service

[Service]
Type=simple
ExecStart=$WATCHDOG_SCRIPT
Restart=always
RestartSec=5
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF_WDS
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable "$WATCHDOG_SERVICE" >/dev/null 2>&1
    systemctl restart "$WATCHDOG_SERVICE" >/dev/null 2>&1
}

smart_watchdog_menu() {
    draw_header
    local wd_stat="${R}OFFLINE${NC}" wd_opt
    systemctl is-active --quiet "$WATCHDOG_SERVICE" 2>/dev/null && wd_stat="${G}ACTIVE${NC} ${DIM}(15s health scan)${NC}"
    echo -e "\n  ${DIM}┌─[ SMART HEALTH WATCHDOG v11 ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}Status:${NC} $wd_stat"
    echo -e "  ${DIM}│${NC} ${G}UP${NC} = reachable  ${R}DOWN${NC} = backend failed  ${Y}INTERFACE_REMOVED${NC} = tunnel device missing"
    echo -e "  ${DIM}│${NC} Backend failure ${R}never deletes${NC} a mapping. MSS clamps are re-applied when tunnels return.\n"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Enable / Restart Health Watchdog${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Disable Health Watchdog${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Run Health Scan Now${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}View Backend Matrix${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} Cancel\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read -r wd_opt
    case "$wd_opt" in
        1) setup_watchdog; echo -e "  ${G}● Health watchdog enabled.${NC}"; sleep 1.5;;
        2) systemctl stop "$WATCHDOG_SERVICE" 2>/dev/null; systemctl disable "$WATCHDOG_SERVICE" 2>/dev/null; echo -e "  ${Y}● Health watchdog disabled.${NC}"; sleep 1.5;;
        3) health_scan; echo -e "  ${G}● Health scan completed.${NC}"; sleep 1.5;;
        4) show_health_matrix;;
    esac
}

hap_restart_safe() {
    command -v haproxy >/dev/null 2>&1 || return 1
    haproxy_test_config || { echo -e "  ${R}✖ haproxy.cfg is invalid; refusing to restart (running instance kept).${NC}"; return 1; }
    systemctl restart haproxy 2>/dev/null
}

manual_restart() {
    draw_header
    echo -e "\n  ${DIM}┌─[ RESTART SERVICES ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Restart HAProxy Engine${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Restart Gost Engine${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Restart Realm Engine${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Restart Kernel NAT Engine${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${G}Restart ALL Engines${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    local r_opt; echo -ne "  ${C}Select ❯❯ ${NC}"; read -r r_opt; r_opt="${r_opt//[^0-5]/}"; echo ""
    case $r_opt in
        1) hap_restart_safe && echo -e "  ${G}● HAProxy restarted successfully.${NC}" ;;
        2) systemctl restart gost 2>/dev/null; echo -e "  ${G}● Gost restarted.${NC}" ;;
        3) systemctl restart realm 2>/dev/null; echo -e "  ${G}● Realm restarted.${NC}" ;;
        4) systemctl restart mporter-iptables 2>/dev/null; echo -e "  ${G}● Kernel NAT restarted.${NC}" ;;
        5) hap_restart_safe; unit_exists gost && systemctl restart gost 2>/dev/null; unit_exists realm && systemctl restart realm 2>/dev/null
           unit_exists mporter-iptables && systemctl restart mporter-iptables 2>/dev/null; obfs_reload; echo -e "  ${G}● All engines restarted.${NC}" ;;
        0) return ;; *) echo -e "  ${R}● Invalid selection!${NC}" ;;
    esac
    setup_mporter_service
    sleep 1.5
}

nuclear_wipe() {
    local u
    for u in haproxy gost realm mporter-obfs mporter-iptables mporter-watchdog mporter; do systemctl stop "$u" 2>/dev/null; systemctl disable "$u" 2>/dev/null; done
    DEBIAN_FRONTEND=noninteractive apt-get purge "${APT_OPTS[@]}" haproxy >/dev/null 2>&1
    obfs_flush_rules
    ipt_flush_tag nat PREROUTING MPORTER_NAT_; ipt_flush_tag nat POSTROUTING MPORTER_NAT_; ipt_flush_tag filter FORWARD MPORTER_NAT_
    ipt_flush_tag mangle OUTPUT MPORTER_MSS_; ipt_flush_tag mangle FORWARD MPORTER_MSS_
    rm -f /etc/sysctl.d/99-mporter-ipv6.conf
    rm -rf /etc/haproxy /var/lib/haproxy /usr/local/bin/gost /etc/gost /usr/local/bin/realm /etc/realm "$OBFS_DIR" "$IPT_DIR" "$STATE_DIR" "$SECURE_TMP" "$HEALTH_FILE" \
           /etc/systemd/system/gost.service /etc/systemd/system/realm.service /etc/systemd/system/mporter-obfs.service /etc/systemd/system/mporter-iptables.service \
           "/etc/systemd/system/$WATCHDOG_SERVICE" "$SERVICE_FILE" /usr/local/bin/mporter-obfs.sh /usr/local/bin/mporter-iptables.sh "$WATCHDOG_SCRIPT" "$INSTALL_PATH"
    systemctl daemon-reload
    # sysctl (ip_forward/BBR) is intentionally left in place: MDesign tunnels depend on it.
}

# ==========================================================
# Headless entry points (no installer / update side effects)
# ==========================================================

case "${1:-}" in
    --health-scan) health_scan; exit 0 ;;
    --boot-apply)  mss_reapply_all; exit 0 ;;
    --state-sync)  state_reconcile; rc=$?; state_sync_interface_metadata; exit $rc ;;
    --purge-ip)
        valid_ip "${2:-}" || { echo "usage: mporter --purge-ip <IPv4|IPv6>"; exit 1; }
        purge_ip_core "$2"; restart_all_engines; exit 0 ;;
    --cleanup-orphans)
        # Only removes mappings whose recorded interface is truly gone.
        state_reconcile >/dev/null 2>&1 || true
        state_sync_interface_metadata >/dev/null 2>&1 || true
        if command -v jq >/dev/null 2>&1 && [ -s "$STATE_FILE" ]; then
            mapfile -t orphan_ips < <(jq -r '.mappings[]? | select(.interface != "" and .interface != "unknown") | [.target_ip, .interface] | @tsv' "$STATE_FILE" 2>/dev/null | \
                while IFS=$'\t' read -r ip iface; do ip link show "$iface" >/dev/null 2>&1 || echo "$ip"; done | sort -u)
            for ip in "${orphan_ips[@]}"; do [ -n "$ip" ] && purge_ip_core "$ip"; done
            [ ${#orphan_ips[@]} -gt 0 ] && restart_all_engines
        fi
        exit 0 ;;
esac

[ "${MPORTER_LIB:-0}" = "1" ] && return 0 2>/dev/null

# ==========================================================
# Interactive main
# ==========================================================

setup_mporter_service
check_update_bg >/dev/null 2>&1 &
state_init >/dev/null 2>&1 || true
ensure_haproxy_base >/dev/null 2>&1 || true

while true; do
    badge=""
    if [ -f "$SECURE_TMP/.mporter_remote_ver" ]; then
        rv=$(tr -d '\r\n ' < "$SECURE_TMP/.mporter_remote_ver")
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && mt_is_newer_version "$rv" "$MODULE_VERSION"; then badge=" ${Y}(Update Available ➔ v${rv})${NC}"; fi
    fi

    draw_header
    echo -e "\n  ${DIM}┌─[ DEPLOYMENT & DESTRUCTION ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Install & Configure Quad-Core System${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Uninstall Engines & Purge (Nuclear Wipe)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Add Port Mappings (Strict 1-to-1)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Smart Loadbalance (Multi-IP / Failover / Health)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Edit Mappings (Add/Del/OBFS)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Delete & Purge Mappings (By Interface/IP/All)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & DETAILS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${M}View IP -> Port Matrix${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${W}Smart Health Watchdog (Safe Monitoring)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${C}Manual Restart Services${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC} ${DIM}❯${NC} ${G}OTA Update${NC}${badge}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC} ${DIM}❯${NC} ${M}Backend Health Matrix (Live)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Workspace${NC}\n"

    opt=""; echo -ne "  ${C}MPorter ❯❯ ${NC}"; read -r -t 30 opt; opt="${opt//[^0-9]/}"
    case $opt in
        1) install_core_engines ;;
        2) echo -ne "  ${R}● Nuclear Wipe? (y/n) ❯❯ ${NC}"; read -r confirm
           if [[ "${confirm,,}" == "y" ]]; then nuclear_wipe; echo -e "  ${G}● Erased from system completely.${NC}"; sleep 1; exit 0; fi ;;
        3) smart_map ;;
        4) smart_loadbalance ;;
        5) edit_mapping ;;
        6) purge_menu ;;
        7) show_table ;;
        8) smart_watchdog_menu ;;
        9) manual_restart ;;
        10) self_update_module ;;
        11) show_health_matrix ;;
        0) clear; exit 0 ;;
    esac
done
