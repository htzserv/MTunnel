#!/bin/bash
# --- MDesign Modular Core (minterface.sh) | Interface Mapper v12.0.2 ---
# [Features: Refined Spacing | Async Background Checker | Minimal OTA Badges]

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











B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/minterface"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

INTERFACE_SCOPE=all
if [ "${1:-}" == --scope ]; then
    mt_valid_scope "${2:-}" || { echo 'Invalid tunnel scope.' >&2; exit 1; }
    INTERFACE_SCOPE="$2"
fi
RETURN_LABEL='Return to Main Core'
[ "${INTERFACE_SCOPE}" == all ] || RETURN_LABEL='Return to Tunnel Menu'

mkdir -p "$LOCAL_DIR/packages" "$LOCAL_DIR/tools" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    mt_install_files 755 "$0" "$INSTALL_PATH" || { echo "Cannot install module." >&2; exit 1; }
fi

# --- ASYNC BACKGROUND UPDATE CHECKER ---
check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tools/minterface.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tools/minterface.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO-  --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO-  --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.minterface_remote_ver"
}
check_update_bg &
# ---------------------------------------

self_update_module() {
    local src_opt custom_url dl_url tmp_file confirm
    local rel_path="tools/minterface.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.minterface_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.minterface_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA Update (MInterface Module) ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ AUTOMATIC MIRRORS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${gh_text}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MANUAL OVERRIDES ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Offline Editor)${NC}"
    echo -e "  ${DIM}│${NC}"
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
        echo -e "\n  ${C}⟳${NC} ${W}Downloading Update...${NC}"
        if ! mt_download "$dl_url" "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Download failed. Installed module preserved.${NC}"; return 1; fi
    fi
    sed -i 's/\r$//' "$tmp_file"
    if ! mt_validate_script "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Invalid Bash module. Installed module preserved.${NC}"; return 1; fi
    local new_ver; new_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$tmp_file")
    if mt_is_newer_version "$MODULE_VERSION" "$new_ver"; then rm -f "$tmp_file"; echo -e "  ${Y}● Downloaded module is older; update refused.${NC}"; return 1; fi
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
    exec "$INSTALL_PATH" "$@"
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

get_configs() {
    local root="${MTUNNEL_TEST_ROOT:-}/etc" conf scope="${INTERFACE_SCOPE:-all}"
    local -a paths=()
    case "$scope" in
        gre) paths=("$root"/mgre/tunnels/*.conf);;
        vxlan) paths=("$root"/mgre/vxlan/*.conf);;
        rathole) paths=("$root"/mrathole/tunnels/*/meta.conf);;
        backhaul) paths=("$root"/mbackhaul/*.meta);;
        paqet) paths=("$root"/paqet/*.meta);;
        all) paths=("$root"/mgre/tunnels/*.conf "$root"/mgre/vxlan/*.conf "$root"/mrathole/tunnels/*/meta.conf "$root"/mbackhaul/*.meta "$root"/paqet/*.meta);;
        *) return 1;;
    esac
    for conf in "${paths[@]}"; do [ ! -f "$conf" ] || printf '%s\n' "$conf"; done
    return 0
}
detect_server_role() {
    local conf role seen1=0 seen2=0
    while IFS= read -r conf; do
        role=$(mt_config_value TYPE "$conf")
        [ -n "$role" ] || role=$(mt_config_value ROLE "$conf")
        case "$conf" in */paqet/*.meta) if [ "$role" == 1 ]; then role=2; elif [ "$role" == 2 ]; then role=1; fi;; esac
        [ "$role" != 1 ] || seen1=1; [ "$role" != 2 ] || seen2=1
    done < <(get_configs)
    if [ "$seen1$seen2" == 11 ]; then echo -e "${Y}Mixed (Access + Gateway)${NC}"
    elif [ "$seen1" == 1 ]; then echo -e "${G}IRAN (Access Node)${NC}"
    elif [ "$seen2" == 1 ]; then echo -e "${M}KHAREJ (Gateway Node)${NC}"
    else echo -e "${DIM}Unknown (No Tunnels)${NC}"; fi
}

draw_header() {
    local s_ip=$(get_local_ip); local role=$(detect_server_role)
    clear; echo ""
    local str1=" MDesign Interface Matrix v${MODULE_VERSION} "
    local str2=" IP: $s_ip "
    local configs=($(get_configs)); local raw_role
    raw_role=$(printf '%s' "$role" | sed $'s/\033\\[[0-9;]*m//g')
    local str3=" ROLE: $raw_role "
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} ))
    local pad_len=$(( 96 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} ROLE:${NC} ${role}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

print_row_2col() {
    local l_raw="$1"; local l_col="$2"; local r_raw="$3"; local r_col="$4"
    if [ "${#r_raw}" -gt 63 ]; then r_raw="${r_raw:0:60}..."; r_col="${W}${r_raw}${NC}"; fi
    local l_spaces=$(printf '%*s' "$(( 28 - ${#l_raw} ))" "")
    local r_spaces=$(printf '%*s' "$(( 63 - ${#r_raw} ))" "")
    echo -e "  ${B}│${NC} ${l_col}${l_spaces} ${B}│${NC} ${r_col}${r_spaces} ${B}│${NC}"
}

render_application_blueprint() {
    local conf="$1" kind name unit role remote port listen ports proto status
    case "$conf" in
        */mrathole/tunnels/*/meta.conf) kind=rathole; name=$(basename "$(dirname "$conf")");;
        */mbackhaul/*.meta) kind=backhaul; name=$(basename "$conf" .meta);;
        */paqet/*.meta) kind=paqet; name=$(basename "$conf" .meta);;
        *) return 1;;
    esac
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    case "$kind" in rathole) unit="mrathole@$name";; backhaul) unit="mbackhaul@$name";; paqet) unit="mpaqet@$name";; esac
    role=$(mt_config_value TYPE "$conf"); [ -n "$role" ] || role=$(mt_config_value ROLE "$conf")
    remote=$(mt_config_value REMOTE_IP "$conf")
    port=$(mt_config_value LINK_PORT "$conf"); [ -n "$port" ] || port=$(mt_config_value TUN_PORT "$conf")
    listen=$(mt_config_value BIND_HOST "$conf"); listen="${listen:-0.0.0.0}"
    proto=$(mt_config_value TRANSPORT "$conf")
    [ -n "$proto" ] || { [ "$kind" != paqet ] && proto=TCP || proto='Raw KCP'; }
    ports=$(mt_config_value PORTS "$conf")
    [ -n "$ports" ] || ports="TCP:$(mt_config_value TCP_PORTS "$conf") UDP:$(mt_config_value UDP_PORTS "$conf")"
    status=OFFLINE; systemctl is-active --quiet "$unit" 2>/dev/null && status=ACTIVE
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    print_row_2col 'Tunnel' "${C}Tunnel${NC}" "$name ($kind)" "${W}$name ($kind)${NC}"
    print_row_2col 'Service' "${DIM}Service${NC}" "$unit: $status" "${W}$unit: $status${NC}"
    print_row_2col 'Transport' "${DIM}Transport${NC}" "$proto" "${W}$proto${NC}"
    if [ "$role" == 1 ]; then
        listen=$(mt_hostport "$listen" "$port")
        print_row_2col 'Listen Address' "${DIM}Listen Address${NC}" "$listen" "${G}$listen${NC}"
    else
        remote=$(mt_hostport "$remote" "$port")
        print_row_2col 'Remote Endpoint' "${DIM}Remote Endpoint${NC}" "$remote" "${Y}$remote${NC}"
    fi
    print_row_2col 'Port Mappings' "${DIM}Port Mappings${NC}" "$ports" "${W}$ports${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────╯${NC}\n"
}

render_matrix() {
    local configs=($(get_configs))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No network blueprints configured.${NC}"; sleep 2; return; fi

    echo -e "\n  ${Y}● Active Network Interface Blueprint:${NC}"
    for conf in "${configs[@]}"; do
        case "$conf" in
            */mrathole/tunnels/*/meta.conf|*/mbackhaul/*.meta|*/paqet/*.meta)
                render_application_blueprint "$conf"; continue;;
        esac
        mt_validate_conf "$conf" || continue
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; CORE_V6=""; LOCAL_PUB6=""; REMOTE_PUB6=""; FAB_PROTO="ipv4"; FWD_TCP=""; FWD_UDP=""; LOCAL_IP6=""; REMOTE_IP6=""; VNI_ID=""; BR_NAME=""; source "$conf"
        local is_vx=false; local t_name="$T_NAME"
        
        if [ -n "$BR_NAME" ]; then is_vx=true; t_name="$BR_NAME"; fi

        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        [ -n "$VNI_ID" ] && c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        
        mt_tunnel_addresses || continue; lip="$MT_CORE_LOCAL"; tip="$MT_CORE_PEER"
        local proto_lbl="${TUN_PROTO^^} Engine"; local title_color="${C}"
        [[ "$TUN_PROTO" == "6to4" ]] && { proto_lbl="6to4 IP6GRE Engine"; title_color="${M}"; }
        [[ "$is_vx" == true ]] && { proto_lbl="VXLAN L2 Bridge"; title_color="${M}"; }

        local stat_raw="● DOWN"; local stat_color="${R}"; local sys_uptime="Offline"
        local state=$(cat /sys/class/net/$t_name/operstate 2>/dev/null)
        if ip link show "$t_name" >/dev/null 2>&1 && [[ "$state" == "up" || "$state" == "unknown" ]]; then
            stat_raw="● UP  "; stat_color="${G}"
            local created=$(stat -c %Y "/sys/class/net/$t_name" 2>/dev/null)
            if [ -n "$created" ]; then
                local diff=$(($(date +%s) - created))
                local d=$((diff / 86400)); local h=$(( (diff % 86400) / 3600 )); local m=$(( (diff % 3600) / 60 ))
                sys_uptime=""; [ "$d" -gt 0 ] && sys_uptime="${d}d "; [ "$h" -gt 0 ] && sys_uptime="${sys_uptime}${h}h "; sys_uptime="${sys_uptime}${m}m"
            fi
        fi

        local link_raw="○ OFFLINE"; local link_color="${R}"
        ping -c 1 -W 1 "$tip" >/dev/null 2>&1 && { link_raw="● ONLINE "; link_color="${G}"; }

        local h_ports="" mapped=''
        if command -v jq >/dev/null 2>&1 && [ -f /etc/mporter/state.json ]; then
            mapped=$(jq -r --arg iface "$t_name" '[.mappings[]? | select(.interface==$iface) | (.engine+":"+(.port|tostring))] | unique | join(",")' /etc/mporter/state.json)
        fi
        [ -z "$FWD_TCP$FWD_UDP" ] || h_ports="Tunnel TCP:${FWD_TCP:-none} UDP:${FWD_UDP:-none}"
        [ -z "$mapped" ] || h_ports="${h_ports:+$h_ports | }Porter:$mapped"
        [ -z "$h_ports" ] && h_ports="None"
        [ ${#h_ports} -gt 50 ] && h_ports="${h_ports:0:47}..."

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_part="▼ Interface: $t_name"
        local right_part="State: $stat_raw   Link: $link_raw   Uptime: $sys_uptime"
        local spaces=$(printf '%*s' "$(( 94 - ${#left_part} - ${#right_part} ))" "")
        echo -e "  ${B}│${NC} ${title_color}▼ Interface: ${W}$t_name${NC}${spaces}${DIM}State: ${stat_color}${stat_raw}${NC}   ${DIM}Link: ${link_color}${link_raw}${NC}   ${DIM}Uptime: ${W}${sys_uptime}${NC} ${B}│${NC}"
        echo -e "  ${B}├──────────────────────────────┬─────────────────────────────────────────────────────────────────┤${NC}"
        print_row_2col "Tunnel Infrastructure" "${C}Tunnel Infrastructure${NC}" "$proto_lbl" "${W}$proto_lbl${NC}"
        
        local l_pub=${MT_LOCAL_PUBLIC:-Unknown}; local r_pub=${MT_REMOTE_PUBLIC:-Unknown}
        if [ $(( ${#l_pub} + ${#r_pub} + 17 )) -gt 63 ]; then
            print_row_2col "Public Endpoint IPs" "${DIM}Public Endpoint IPs${NC}" "Local: $l_pub" "${DIM}Local:${NC} ${W}$l_pub${NC}"
            print_row_2col "" "" "Remote: $r_pub" "${DIM}Remote:${NC} ${W}$r_pub${NC}"
        else
            print_row_2col "Public Endpoint IPs" "${DIM}Public Endpoint IPs${NC}" "Local: $l_pub   Remote: $r_pub" "${DIM}Local:${NC} ${W}$l_pub${NC}   ${DIM}Remote:${NC} ${W}$r_pub${NC}"
        fi
        echo -e "  ${B}├──────────────────────────────┼─────────────────────────────────────────────────────────────────┤${NC}"
        if [ $(( ${#lip} + ${#tip} + 17 )) -gt 63 ]; then
            print_row_2col "Core IP Network" "${DIM}Core IP Network${NC}" "Local: $lip" "${DIM}Local:${NC} ${W}$lip${NC}"
            print_row_2col "" "" "Remote: $tip" "${DIM}Remote:${NC} ${W}$tip${NC}"
        else
            print_row_2col "Core IP Network" "${DIM}Core IP Network${NC}" "Local: $lip   Remote: $tip" "${DIM}Local:${NC} ${G}$lip${NC}   ${DIM}Remote:${NC} ${Y}$tip${NC}"
        fi
        print_row_2col "Active Port Mappings" "${Y}Active Port Mappings${NC}" "$h_ports" "${W}$h_ports${NC}"
        
        if [[ "$TUN_PROTO" == "6to4" ]]; then
            echo -e "  ${B}├──────────────────────────────┼─────────────────────────────────────────────────────────────────┤${NC}"
            print_row_2col "Native IPv6 Allocation" "${DIM}Native IPv6 Allocation${NC}" "Local IPv6 : $LOCAL_IP6" "${DIM}Local IPv6 :${NC} $LOCAL_IP6"
            print_row_2col "" "" "Remote IPv6: $REMOTE_IP6" "${DIM}Remote IPv6:${NC} $REMOTE_IP6"
        fi
        echo -e "  ${B}╰──────────────────────────────┴─────────────────────────────────────────────────────────────────╯${NC}\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

while true; do
    badge=""
    if [ -f "$SECURE_TMP/.minterface_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.minterface_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && mt_is_newer_version "$rv" "$MODULE_VERSION"; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_header
    echo -e "  ${DIM}● Tunnel Scope: ${W}${INTERFACE_SCOPE^^}${NC}"
    echo -e "\n  ${DIM}┌─[ INTERFACE MATRIX ACTIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Render Active Network Blueprint${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}OTA Update${NC}${badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}${RETURN_LABEL}${NC}\n"

    echo -ne "  ${C}MINTERFACE ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r ')

    case $opt in
        1) render_matrix ;;
        2) self_update_module ;;
        0) break ;;
        *) echo -e "  ${R}● Invalid option!${NC}"; sleep 1 ;;
    esac
done
