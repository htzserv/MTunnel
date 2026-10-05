#!/bin/bash
# --- MBackhaul Modular Core (mbackhaul.sh) | MDesign Ecosystem v2.6.0 ---
# [Features: Leak-Free Updater | Strict Port Guard | Universal Download | Port Collision Check]

MODULE_VERSION="2.6.0"

# BEGIN MTUNNEL SHARED HELPERS
# Shared helpers embedded in standalone modules by maintenance/embed_helpers.py.
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
    echo '  Server listen: 1) IPv4  2) IPv6  3) Specific IP'
    read -r -p '  Select [1]: ' choice
    case "${choice:-1}" in
        1) MT_BIND_HOST='0.0.0.0';;
        2) MT_BIND_HOST='::';;
        3) read -r -p '  Listen IP: ' host
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
        curl -fSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 --retry 2 -o "$tmp" "$url" && rc=0
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

mt_verify_manifest() {
    local root="$1" digest path actual count=0
    [ -s "$root/SHA256SUMS" ] || return 1
    while read -r digest path; do
        [[ "$digest" =~ ^[0-9a-fA-F]{64}$ && "$path" =~ ^[A-Za-z0-9_./-]+$ ]] || return 1
        case "/$path/" in *'/../'*|//* ) return 1;; esac
        [ -f "$root/$path" ] && [ ! -L "$root/$path" ] || return 1
        actual=$(sha256sum "$root/$path" | cut -d' ' -f1)
        [ "$actual" == "${digest,,}" ] || { echo "Checksum mismatch: $path" >&2; return 1; }
        ((count+=1))
    done < "$root/SHA256SUMS"
    [ "$count" -gt 0 ]
}

mt_manifest_hash() {
    awk -v path="$2" '$2==path {print $1;exit}' "$1/SHA256SUMS"
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

# END MTUNNEL SHARED HELPERS
if [ "$EUID" != 0 ]; then echo "Run MTunnel with sudo." >&2; exit 1; fi





B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mbackhaul"
CONF_DIR="/etc/mbackhaul/tunnels"
CERT_DIR="/etc/mbackhaul/certs"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mbackhaul" ] && rm -f "/usr/local/bin/mbackhaul" 2>/dev/null

mkdir -p "$CONF_DIR" "$CERT_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null
rm -f "$SECURE_TMP/.mbackhaul_in_menu" 2>/dev/null

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

validate_bh_ports() {
    local list="$1" check="${2:-0}" owned="${3:-}" raw lhs rhs port start end host owned_port
    local -a items=(); local -A seen=()
    [ -z "$list" ] && return 0
    [[ "$list" != *, && "$list" != ,* && "$list" != *,,* ]] || return 1
    IFS=, read -ra items <<< "$list"
    for raw in "${items[@]}"; do
        raw="${raw// /}"; lhs="${raw%%=*}"; rhs=''
        if [[ "$raw" == *=* ]]; then
            rhs="${raw#*=}"; [[ "$rhs" != *=* && -n "$rhs" ]] || return 1
            if [[ "$rhs" == *:* ]]; then
                host="${rhs%:*}"; port="${rhs##*:}"
                # v0.7.2 supports an IPv6 tunnel link, but its forwarded-destination parser is IPv4/domain only.
                mt_valid_host "$host" && [[ "$host" != *:* ]] && mt_valid_port "$port" || return 1
            else mt_valid_port "$rhs" || return 1; fi
        fi
        if [[ "$lhs" == *:* ]]; then
            host="${lhs%:*}"; port="${lhs##*:}"
            mt_valid_ipv4 "$host" || mt_valid_ipv6 "$host" || return 1
            start="$port"; end="$port"
        elif [[ "$lhs" == *-* ]]; then start="${lhs%-*}"; end="${lhs#*-}"
        else start="$lhs"; end="$lhs"; fi
        mt_valid_port "$start" && mt_valid_port "$end" && ((10#$start <= 10#$end)) || return 1
        for ((port=10#$start;port<=10#$end;port++)); do
            [ -z "${seen[$port]:-}" ] || return 1; seen[$port]=1
            owned_port=0
            if [ -n "$owned" ]; then
                local old old_l old_s old_e; local -a old_items=()
                IFS=, read -ra old_items <<< "$owned"
                for old in "${old_items[@]}"; do
                    old_l="${old%%=*}"; old_l="${old_l##*:}"
                    old_s="${old_l%-*}"; old_e="${old_l#*-}"
                    mt_valid_port "$old_s" && mt_valid_port "$old_e" && ((port>=10#$old_s && port<=10#$old_e)) && owned_port=1
                done
            fi
            if [ "$check" == 1 ] && [ "$owned_port" == 0 ] && mt_port_busy "$port"; then
                echo "Port $port is already in use." >&2; return 1
            fi
        done
    done
}

MAIN_PID=$$
NEED_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1

UPDATE_CHECK_INTERVAL=60

read_with_refresh() {
    local prompt="$1"
    local __resultvar="$2"
    local redraw_func="$3"
    local buffer=""
    local char rc

    touch "$SECURE_TMP/.mbackhaul_in_menu"
    echo -ne "$prompt"

    while true; do
        if [ "$NEED_REFRESH" = true ]; then
            NEED_REFRESH=false
            if [ -n "$redraw_func" ]; then
                "$redraw_func"
            fi
            echo -ne "$prompt$buffer"
        fi

        IFS= read -rsn1 -t 0.3 char
        rc=$?

        if [ $rc -ne 0 ]; then
            continue
        fi

        if [[ -z "$char" ]]; then
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

    rm -f "$SECURE_TMP/.mbackhaul_in_menu" 2>/dev/null
    printf -v "$__resultvar" '%s' "$buffer"
}

check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tunnels/mbackhaul.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tunnels/mbackhaul.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO-  --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO-  --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mbackhaul_remote_ver"
}

update_watcher_loop() {
    while true; do
        check_update_bg
        if [ -f "$SECURE_TMP/.mbackhaul_in_menu" ]; then
            kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        fi
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
if [[ "${1:-}" != --* ]]; then update_watcher_loop & fi
WATCHER_PID=$!
trap 'kill "$WATCHER_PID" 2>/dev/null; rm -f "$SECURE_TMP/.mbackhaul_in_menu" 2>/dev/null' EXIT

self_update_module() {
    local rel_path="tunnels/mbackhaul.sh" src_opt custom_url dl_url tmp_file confirm
    echo '  Update: 1) GitHub  2) Mirror  3) HTTPS link  4) Paste in editor  0) Cancel'
    read -r -p '  Select: ' src_opt
    [[ "$src_opt" =~ ^[1-4]$ ]] || return 0
    tmp_file=$(mktemp "$SECURE_TMP/update.XXXXXX") || return 1
    if [ "$src_opt" == 4 ]; then
        if command -v nano >/dev/null 2>&1; then nano "$tmp_file"
        elif command -v vi >/dev/null 2>&1; then vi "$tmp_file"
        else rm -f "$tmp_file"; echo 'No editor available.'; return 1; fi
    else
        case "$src_opt" in
            1) dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path";;
            2) dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path";;
            3) read -r -p '  HTTPS link: ' dl_url;;
        esac
        if ! mt_download "$dl_url" "$tmp_file"; then rm -f "$tmp_file"; echo 'Download failed; installed module preserved.'; return 1; fi
    fi
    sed -i 's/\r$//' "$tmp_file"
    if ! mt_validate_script "$tmp_file"; then rm -f "$tmp_file"; echo 'Invalid Bash module; installed module preserved.'; return 1; fi
    local new_ver; new_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$tmp_file")
    if mt_is_newer_version "$MODULE_VERSION" "$new_ver"; then rm -f "$tmp_file"; echo 'Downloaded module is older; update refused.'; return 1; fi
    read -r -p "  Install v$new_ver (current $MODULE_VERSION)? [y/N]: " confirm
    [[ "${confirm,,}" == y || "${confirm,,}" == yes ]] || { rm -f "$tmp_file"; return 0; }
    if ! mt_install_script "$tmp_file" "$rel_path" "$INSTALL_PATH" "$0"; then
        rm -f "$tmp_file"; echo 'Update failed; previous module preserved.'; return 1
    fi
    rm -f "$tmp_file"
    exec "$INSTALL_PATH" "$@"
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

is_bh_core_valid() {
    local candidate
    for candidate in /usr/local/bin/bh /usr/bin/bh; do
        [ -x "$candidate" ] && mt_valid_elf "$candidate" && return 0
    done
    return 1
}

format_speed() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B/s"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B/s"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB/s"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB/s\", $bytes/1048576}"
    else awk "BEGIN {printf \"%.2f GB/s\", $bytes/1073741824}"; fi
}

format_total() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B"; return; fi
    if [ "$bytes" -lt 1024 ]; then echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -lt 1099511627776 ]; then awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    else awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"; fi
}

apply_bbr_optimization() {
    return 0  # BBR is managed explicitly by mbbr.
}

generate_ssl_cert() {
    if [[ ! -f "$CERT_DIR/wssmux.crt" ]] || [[ ! -f "$CERT_DIR/wssmux.key" ]]; then
        openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/wssmux.key" \
            -out "$CERT_DIR/wssmux.crt" -days 3650 -nodes \
            -subj "/CN=mdesign-backhaul" \
            -addext "subjectAltName=DNS:mdesign-backhaul,IP:127.0.0.1" >/dev/null 2>&1
    fi
}

install_core_from_source() {
    local src_choice="$1" arch target dl_url kind=url
    arch=$(uname -m)
    case "$arch" in x86_64) target=amd64;; aarch64|arm64) target=arm64;; *) echo 'Unsupported CPU architecture.'; return 1;; esac
    case "$src_choice" in
        1|2)
            local asset="backhaul_linux_${target}.tar.gz"
            dl_url="https://github.com/Musixal/Backhaul/releases/download/v0.7.2/$asset"
            [ "$src_choice" != 2 ] || dl_url="https://c107328.parspack.net/c107328/MTunnel/packages/$asset"
            ;;
        3) read -r -p '  HTTPS binary/archive URL: ' dl_url; [ -n "$dl_url" ] || return 0;;
        4) dl_url="$LOCAL_DIR/packages/bh"; kind=local;;
        *) return 0;;
    esac
    if mt_update_core "bh" "mbackhaul" "$dl_url" "$kind" "${EXPECTED_SHA256:-}"; then
        echo 'Core installed; previously active tunnels restarted.'
    else
        echo 'Core update failed; previous installation preserved.' >&2
        return 1
    fi
}

menu_install_core() {
    echo -e "\n  ${DIM}┌─[ INSTALL / UPDATE BACKHAUL CORE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/bh)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r')

    [[ "$src_choice" =~ ^[1-4]$ ]] && install_core_from_source "$src_choice"
}

check_first_run_core() {
    if ! is_bh_core_valid; then
        local first_prompt_flag="$CONF_DIR/.core_prompted"
        if [ ! -f "$first_prompt_flag" ]; then
            touch "$first_prompt_flag"
            clear
            echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${B}│${NC}   ${R}● Backhaul Core binary is NOT installed on this machine!${NC}                 ${B}│${NC}"
            echo -e "  ${B}│${NC}   ${W}Would you like to install the Core binary now?${NC}                           ${B}│${NC}"
            echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
            echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
            echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/bh)${NC}"
            echo -e "  ${DIM}│${NC}"
            echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Skip for now${NC}\n"
            echo -ne "  ${C}Select Source ❯❯ ${NC}"; read init_opt
            init_opt=$(echo "$init_opt" | tr -d '\r')
            if [[ "$init_opt" =~ ^[1-4]$ ]]; then
                install_core_from_source "$init_opt"
            fi
        fi
    fi
}

setup_bh_counters() {
    mt_setup_counter_pair MBH "$1" "$2" "$3" "$4" "${5:-0.0.0.0}"
}

clean_bh_counters() {
    local bin chain direction
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        for direction in RX TX; do
            for chain in INPUT OUTPUT; do mt_delete_tagged_rules "$bin" mangle "$chain" "MBH_${direction}_$1"; done
        done
    done
}

zero_bh_counters() {
    local bin chain direction num
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        for chain in INPUT OUTPUT; do
            for direction in RX TX; do
                while read -r num; do [ -n "$num" ] && "$bin" -w 5 -t mangle -Z "$chain" "$num"; done < <(mt_tagged_rules "$bin" mangle "$chain" "MBH_${direction}_$1")
            done
        done
    done
}

if [[ "$1" == "--apply" ]]; then
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        t_name=$(basename "$conf" .meta)
        ROLE=""; TUN_PORT=""; REMOTE_IP=""; BIND_HOST="0.0.0.0"; source "$conf" 2>/dev/null
        setup_bh_counters "$t_name" "$TUN_PORT" "$REMOTE_IP" "$ROLE" "$BIND_HOST"
    done
    exit 0
fi

get_bh_rx() {
    local data; data=$({ iptables -t mangle -L INPUT -v -n -x; ip6tables -t mangle -L INPUT -v -n -x; } 2>/dev/null)
    mt_counter_sum "$data" "MBH_RX_$1"
}

get_bh_tx() {
    local data; data=$({ iptables -t mangle -L OUTPUT -v -n -x; ip6tables -t mangle -L OUTPUT -v -n -x; } 2>/dev/null)
    mt_counter_sum "$data" "MBH_TX_$1"
}

check_bh_connection() {
    local t_name="$1"
    local known_active="$2"
    local meta="$CONF_DIR/${t_name}.meta"
    [ ! -f "$meta" ] && { echo "OFFLINE"; return; }
    
    ROLE=""; TUN_PORT=""; REMOTE_IP=""; source "$meta" 2>/dev/null
    if [ "$known_active" != "1" ] && ! systemctl is-active --quiet "mbackhaul@${t_name}" 2>/dev/null; then echo "OFFLINE"; return; fi

    if [ "$ROLE" == "1" ]; then
        if ss -tn src ":$TUN_PORT" 2>/dev/null | grep -qE "^ESTAB"; then echo "ONLINE"; else echo "WAITING"; fi
    else
        if ss -tn dst ":$TUN_PORT" 2>/dev/null | grep -qE "^ESTAB"; then echo "ONLINE"; else echo "CONNECTING"; fi
    fi
}

get_peer_ping() {
    local target_ip=$(echo "$1" | tr -d ' \n\r')
    local port=$(echo "$2" | tr -d ' \n\r')
    if [ -z "$target_ip" ] || [ "$target_ip" == "0.0.0.0" ]; then echo "N/A"; return; fi
    
    local ping_res=$(timeout 2 ping -c 1 -W 1 "$target_ip" 2>/dev/null)
    if echo "$ping_res" | grep -q "time="; then
        local ping_val=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+' | awk '{print int($1+0.5)}')
        echo "${ping_val}ms"
        return
    fi
    
    if command -v ss >/dev/null 2>&1; then
        local tcp_rtt=$(ss -nti 2>/dev/null | grep -A 1 "$target_ip" | grep -oP 'rtt:\K[0-9.]+' | head -n 1)
        if [ -n "$tcp_rtt" ]; then
            local rounded_rtt=$(echo "$tcp_rtt" | awk '{print int($1+0.5)}')
            echo "${rounded_rtt}ms*"
            return
        fi
    fi

    if [ -n "$port" ] && [[ "$port" =~ ^[0-9]+$ ]]; then
        local start_ts=$(date +%s%3N 2>/dev/null)
        if mt_tcp_probe "$target_ip" "$port"; then
            local end_ts=$(date +%s%3N 2>/dev/null)
            if [[ "$start_ts" =~ ^[0-9]+$ ]] && [[ "$end_ts" =~ ^[0-9]+$ ]]; then
                local t_rtt=$((end_ts - start_ts))
                [ "$t_rtt" -le 0 ] && t_rtt=1
                echo "${t_rtt}ms*"
                return
            fi
        fi
    fi

    echo "Timeout"
}

bh_port_lines() {
    local list="$1" bind="$2" raw lhs rhs start end port mapped output=''
    local -a items=()
    [ -n "$list" ] || { printf ''; return 0; }
    IFS=, read -ra items <<< "$list"
    for raw in "${items[@]}"; do
        raw="${raw// /}"; lhs="${raw%%=*}"; rhs=''
        [[ "$raw" != *=* ]] || rhs="${raw#*=}"
        if [[ "$lhs" == *:* ]]; then
            mapped="$raw"
            [ -n "$rhs" ] || mapped="$lhs=127.0.0.1:${lhs##*:}"
            output+="${output:+, }\"$mapped\""
        else
            start="${lhs%-*}"; end="${lhs#*-}"
            for ((port=10#$start;port<=10#$end;port++)); do
                mapped="$(mt_hostport "$bind" "$port")=${rhs:-127.0.0.1:$port}"
                output+="${output:+, }\"$mapped\""
            done
        fi
    done
    printf '%s' "$output"
}

write_bh_config() {
    local name="$(echo "$1" | tr -d '\r\n')"
    local role="$(echo "$2" | tr -d '\r\n')"
    local transport="$(echo "$3" | tr -d '\r\n')"
    local port="$(echo "$4" | tr -d '\r\n')"
    local r_ip="$(echo "$5" | tr -d '\r\n')"
    local token="$(echo "$6" | tr -d '\r\n' | sed 's/"/\\"/g')"
    local ports_str="$(echo "$7" | tr -d '\r\n')"
    local enable_udp="$(echo "$8" | tr -d '\r\n')"

    [ -z "$role" ] && role="1"
    [ -z "$transport" ] && transport="tcp"
    [ -z "$port" ] && port="8443"
    [ -z "$token" ] && token="mdesign_token"
    [ -z "$enable_udp" ] && enable_udp="true"

    local bind_host="${9:-}" BIND_HOST='0.0.0.0' work final_toml final_meta
    if [ -f "$CONF_DIR/${name}.meta" ]; then
        BIND_HOST=$(sed -n 's/^BIND_HOST=//p' "$CONF_DIR/${name}.meta")
    fi
    bind_host=$(mt_normalize_host "${bind_host:-${BIND_HOST:-0.0.0.0}}")
    mt_valid_ipv4 "$bind_host" || mt_valid_ipv6 "$bind_host" || return 1
    mt_valid_port "$port" && [[ "$role" =~ ^[12]$ ]] || return 1
    [ "$role" != 2 ] || mt_valid_host "$r_ip" || return 1
    validate_bh_ports "$ports_str" 0 || return 1
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ && "$transport" =~ ^(tcp|tcpmux|ws|wss|wsmux|wssmux)$ && "$enable_udp" =~ ^(true|false)$ ]] || return 1
    [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    work=$(mktemp -d "$SECURE_TMP/bh-config.XXXXXX") || return 1
    final_toml="$CONF_DIR/${name}.toml"; final_meta="$CONF_DIR/${name}.meta"
    local toml="$work/config.toml" meta="$work/meta"

    echo "ROLE=$role" > "$meta"
    echo "BIND_HOST=$bind_host" >> "$meta"
    echo "TRANSPORT=$transport" >> "$meta"
    echo "TUN_PORT=$port" >> "$meta"
    echo "REMOTE_IP=$r_ip" >> "$meta"
    echo "TOKEN=$token" >> "$meta"
    echo "PORTS=$ports_str" >> "$meta"
    echo "ENABLE_UDP=$enable_udp" >> "$meta"

    > "$toml"

    if [ "$role" == "1" ]; then
        echo "[server]" >> "$toml"
        echo "bind_addr = \"$(mt_hostport "$bind_host" "$port")\"" >> "$toml"
        echo "transport = \"${transport}\"" >> "$toml"
        echo "accept_udp = ${enable_udp}" >> "$toml"
        echo "token = \"${token}\"" >> "$toml"
        echo "keepalive_period = 75" >> "$toml"
        echo "nodelay = true" >> "$toml"
        echo "heartbeat = 40" >> "$toml"
        echo "channel_size = 4096" >> "$toml"
        
        if [ "$transport" != "tcp" ]; then
            echo "mux_con = 8" >> "$toml"
            echo "mux_version = 1" >> "$toml"
            echo "mux_framesize = 32768" >> "$toml"
            echo "mux_recievebuffer = 4194304" >> "$toml"
            echo "mux_streambuffer = 65536" >> "$toml"
        fi
        
        if [ "$transport" == "tcp" ] || [ "$transport" == "tcpmux" ]; then
            echo "mss = 1360" >> "$toml"
            echo "so_rcvbuf = 4194304" >> "$toml"
            echo "so_sndbuf = 4194304" >> "$toml"
        fi
        
        if [ "$transport" == "wssmux" ]; then
            generate_ssl_cert
            echo "tls_cert = \"${CERT_DIR}/wssmux.crt\"" >> "$toml"
            echo "tls_key = \"${CERT_DIR}/wssmux.key\"" >> "$toml"
        fi
        
        echo "sniffer = false" >> "$toml"
        echo "web_port = 0" >> "$toml"
        echo "log_level = \"info\"" >> "$toml"
        
        local port_lines; port_lines=$(bh_port_lines "$ports_str" "$bind_host") || { rm -rf "$work"; return 1; }
        echo "ports = [ ${port_lines} ]" >> "$toml"

    else
        echo "[client]" >> "$toml"
        echo "remote_addr = \"$(mt_hostport "$r_ip" "$port")\"" >> "$toml"
        if [ "$transport" == "wsmux" ] || [ "$transport" == "wssmux" ]; then
            echo "edge_ip = \"\"" >> "$toml"
        fi
        echo "transport = \"${transport}\"" >> "$toml"
        echo "token = \"${token}\"" >> "$toml"
        echo "connection_pool = 8" >> "$toml"
        echo "aggressive_pool = false" >> "$toml"
        echo "keepalive_period = 75" >> "$toml"
        echo "nodelay = true" >> "$toml"
        echo "retry_interval = 3" >> "$toml"
        echo "dial_timeout = 10" >> "$toml"
        
        if [ "$transport" != "tcp" ]; then
            echo "mux_version = 1" >> "$toml"
            echo "mux_framesize = 32768" >> "$toml"
            echo "mux_recievebuffer = 4194304" >> "$toml"
            echo "mux_streambuffer = 65536" >> "$toml"
        fi
        
        if [ "$transport" == "tcp" ] || [ "$transport" == "tcpmux" ]; then
            echo "mss = 1360" >> "$toml"
            echo "so_rcvbuf = 4194304" >> "$toml"
            echo "so_sndbuf = 4194304" >> "$toml"
        fi
        
        echo "sniffer = false" >> "$toml"
        echo "web_port = 0" >> "$toml"
        echo "log_level = \"info\"" >> "$toml"
    fi

    mt_install_files 600 "$meta" "$final_meta" "$toml" "$final_toml" || { rm -rf "$work"; return 1; }
    rm -rf "$work"
    clean_bh_counters "$name"
    setup_bh_counters "$name" "$port" "$r_ip" "$role" "$bind_host"
    return 0
}

setup_systemd_service() {
    local changed=false
    local tmp_srv="$SECURE_TMP/mbackhaul_tpl.service"
    local tmp_app="$SECURE_TMP/mbackhaul_apply.service"

    cat <<'EOF' > "$tmp_srv"
[Unit]
Description=MBackhaul Multi-Multiplexer (%i)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/bh -c /etc/mbackhaul/tunnels/%i.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    cat <<'EOF' > "$tmp_app"
[Unit]
Description=MBackhaul Boot Restorer
After=network.target

[Service]
ExecStart=/usr/bin/mbackhaul --apply
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    if ! cmp -s "$tmp_srv" "/etc/systemd/system/mbackhaul@.service" 2>/dev/null; then
        mv -f "$tmp_srv" "/etc/systemd/system/mbackhaul@.service"
        changed=true
    else
        rm -f "$tmp_srv"
    fi

    if ! cmp -s "$tmp_app" "/etc/systemd/system/mbackhaul-apply.service" 2>/dev/null; then
        mv -f "$tmp_app" "/etc/systemd/system/mbackhaul-apply.service"
        changed=true
    else
        rm -f "$tmp_app"
    fi

    if [ "$changed" = true ]; then
        systemctl daemon-reload
        systemctl enable mbackhaul-apply.service >/dev/null 2>&1
    fi
}

draw_header() {
    local s_ip=$(get_local_ip); local total_t=0; local active_t=0; local online_t=0
    local t_names=() units=()
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            local t_name=$(basename "$conf" .meta)
            t_names+=("$t_name"); units+=("mbackhaul@$t_name")
        fi
    done
    total_t=${#t_names[@]}
    if [ "$total_t" -gt 0 ]; then
        local states=() i=0
        while IFS= read -r st_line; do states+=("$st_line"); done < <(systemctl is-active "${units[@]}" 2>/dev/null)
        for t_name in "${t_names[@]}"; do
            if [ "${states[$i]}" == "active" ]; then
                ((active_t++))
                local st=$(check_bh_connection "$t_name" "1")
                [ "$st" == "ONLINE" ] && ((online_t++))
            fi
            ((i++))
        done
    fi

    local core_color="${R}"; local core_raw="Not Installed"
    if is_bh_core_valid; then
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
        else 
            stat_color="${Y}"; stat_icon="◎"; stat_text="WAITING"
        fi
    fi

    local peer_ip=""
    local tmp_port=""
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            local tmp_role=$(grep "^ROLE=" "$conf" | cut -d'=' -f2)
            local tmp_remote=$(grep "^REMOTE_IP=" "$conf" | cut -d'=' -f2)
            tmp_port=$(grep "^TUN_PORT=" "$conf" | cut -d'=' -f2)
            
            if [ -n "$tmp_remote" ] && [ "$tmp_remote" != "0.0.0.0" ]; then
                peer_ip="$tmp_remote"
                break
            elif [ "$tmp_role" == "1" ]; then
                local conn=$(ss -tn src ":$tmp_port" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
                if [ -n "$conn" ]; then
                    peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                    break
                fi
            fi
        fi
    done

    local g_color="${DIM}"; local g_text="N/A"
    if [ -n "$peer_ip" ]; then
        local ping_cache="$SECURE_TMP/.mbackhaul_ping_cache"
        local ping_lock="$SECURE_TMP/.mbackhaul_ping_lock"
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
                bg_val=$(get_peer_ping "$peer_ip" "$tmp_port")
                echo "$bg_val" > "$ping_cache"
                rm -f "$ping_lock"
                if [ -f "$SECURE_TMP/.mbackhaul_in_menu" ]; then
                    kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
                fi
            ) &
        fi
    else
        g_color="${DIM}"; g_text="Waiting"
    fi

    # رفع ایراد ۳: محاسبه دقیق طول متن خالص و پدینگ هدر
    local title=" MBackhaul Engine v${MODULE_VERSION} "
    local plain_content=" │${title}│ IP: ${s_ip} │ Core: ${core_raw} │ Peer Ping: ${g_text} │ ACTIVE: ${act_text} │ STATUS: ${stat_icon} ${stat_text} "
    local pad_len=$(( 124 - ${#plain_content} ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${title}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${B}│${NC}${DIM} Core:${NC} ${core_color}${core_raw}${NC} ${B}│${NC}${DIM} Peer Ping:${NC} ${g_color}${g_text}${NC} ${B}│${NC}${DIM} ACTIVE:${NC} ${act_color}${act_text}${NC} ${B}│${NC}${DIM} STATUS:${NC} ${stat_color}${stat_icon} ${stat_text}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_tunnel_registry() {
    draw_header
    echo -e "\n  ${Y}● Deployed Backhaul Tunnels Registry:${NC}"
    local count=0
    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; ENABLE_UDP=""; BIND_HOST="0.0.0.0"
        source "$conf" 2>/dev/null
        
        local role_text=$([ "$ROLE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local ping_val="N/A"
        local connected_peer=""

        if [ "$ROLE" == "2" ] && [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "0.0.0.0" ]; then
            ping_val=$(get_peer_ping "$REMOTE_IP" "$TUN_PORT")
            connected_peer="$REMOTE_IP"
        elif [ "$ROLE" == "1" ]; then
            local conn=$(ss -tn src ":$TUN_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
            if [ -n "$conn" ]; then
                local p_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                ping_val=$(get_peer_ping "$p_ip" "$TUN_PORT")
                connected_peer="$p_ip"
            else
                ping_val="Waiting"
            fi
        fi

        local peer_text=$([ "$ROLE" == "1" ] && echo "Listening on :${TUN_PORT}" || echo "${REMOTE_IP}:${TUN_PORT}")
        if [ "$ROLE" == "1" ] && [ -n "$connected_peer" ]; then
            peer_text="${connected_peer}:${TUN_PORT} (Active)"
        fi

        local st=$(check_bh_connection "$t_name")
        local stat_icon="○"; local stat_text="OFFLINE"; local stat_color="${R}"
        if [ "$st" == "ONLINE" ]; then stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}";
        elif [ "$st" == "WAITING" ]; then stat_icon="◎"; stat_text="WAITING CLIENT"; stat_color="${Y}";
        elif [ "$st" == "CONNECTING" ]; then stat_icon="◎"; stat_text="CONNECTING..."; stat_color="${Y}"; fi

        local rx=$(get_bh_rx "$t_name"); local tx=$(get_bh_tx "$t_name")

        local proto_display="${C}${TRANSPORT^^}${NC}"
        if [ "$ROLE" == "1" ]; then
            local udp_status="Enabled"; [ "$ENABLE_UDP" == "false" ] && udp_status="Disabled"
            proto_display="${C}${TRANSPORT^^}${NC} ${DIM}(UDP: ${G}${udp_status}${DIM})${NC}"
        fi

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_p="▼ Tunnel: $t_name"; local right_p="Role: $role_text"
        local pad=$(( 122 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        local l1="Link Port    : ${TUN_PORT}"; local r1="Latency: ${ping_val}"
        local pad1=$(( 122 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Link Port    :${NC} ${W}${TUN_PORT}${NC}${sp1}${DIM}Latency:${NC} ${Y}${ping_val}${NC} ${B}│${NC}"
        
        local l2="Peer Target  : ${peer_text}"; local r2="Link State: ${stat_icon} ${stat_text}"
        local clean_r2=$(echo -e "$r2" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
        local pad2=$(( 122 - ${#l2} - ${#clean_r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}Peer Target  :${NC} ${W}${peer_text}${NC}${sp2}${DIM}Link State:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${B}│${NC}"

        local l3="Auth Token   : ${TOKEN}"
        local raw_r3="Protocol: ${TRANSPORT^^}"
        [ "$ROLE" == "1" ] && raw_r3="Protocol: ${TRANSPORT^^} (UDP: ${udp_status})"
        local pad3=$(( 122 - ${#l3} - ${#raw_r3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${Y}Auth Token   :${NC} ${W}${TOKEN}${NC}${sp3}${DIM}Protocol:${NC} ${proto_display} ${B}│${NC}"

        local l4="Traffic Usage: RX $(format_total $rx) / TX $(format_total $tx)"
        local pad4=$(( 122 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Traffic Usage:${NC} ${G}RX $(format_total $rx)${NC} ${DIM}/${NC} ${Y}TX $(format_total $tx)${NC}${sp4} ${B}│${NC}"
        
        if [ "$ROLE" == "1" ]; then
            local p_str="${PORTS:0:100}"
            [ ${#PORTS} -gt 100 ] && p_str="${p_str}..."
            local l5="Port Mappings: ${p_str}"
            local pad5=$(( 122 - ${#l5} )); [ "$pad5" -lt 0 ] && pad5=0; local sp5=$(printf '%*s' "$pad5" "")
            echo -e "  ${B}│${NC} ${DIM}Port Mappings:${NC} ${Y}${p_str}${NC}${sp5} ${B}│${NC}"
        fi
        
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯\n"
        ((count++))
    done
    if [ "$count" -eq 0 ]; then echo -e "  ${R}● No tunnels configured yet!${NC}\n"; fi
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
}

show_live_radar() {
    tput civis; clear
    declare -A rx_old tx_old sample_old

    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        source "$conf" 2>/dev/null
        setup_bh_counters "$t_name" "$TUN_PORT" "$REMOTE_IP" "$ROLE" "$BIND_HOST"
        rx_old[$t_name]=$(get_bh_rx "$t_name")
        sample_old[$t_name]=$(mt_milliseconds)
        tx_old[$t_name]=$(get_bh_tx "$t_name")
    done

    while true; do
        printf "\033[H"; draw_header
        echo -e "\n  ${DIM}┌─[ BACKHAUL TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────────┬────────────────┬──────────────────┬──────────────────┬────────────────────┬────────────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} ${W}%-14s${NC} ${B}│${NC} ${C}%-16s${NC} ${B}│${NC} ${M}%-16s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL RX" "∑ TOTAL TX"
        echo -e "  ${B}├──────────────────────┼────────────────┼──────────────────┼──────────────────┼────────────────────┼────────────────────┤${NC}"

        local count=0
        for conf in "$CONF_DIR"/*.meta; do
            [ ! -f "$conf" ] && continue
            local t_name=$(basename "$conf" .meta)
            local st=$(check_bh_connection "$t_name")
            local st_color="${R}"; local st_text="OFFLINE"
            if [ "$st" == "ONLINE" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING"; fi

            local r_new=$(get_bh_rx "$t_name"); local t_new=$(get_bh_tx "$t_name")
            local r_prev=${rx_old[$t_name]:-$r_new}; local t_prev=${tx_old[$t_name]:-$t_new}
            local now_ms=$(mt_milliseconds) ms_diff; ms_diff=$((now_ms-${sample_old[$t_name]:-$now_ms}))
            local rx_s=$(mt_rate "$r_new" "$r_prev" "$ms_diff"); local tx_s=$(mt_rate "$t_new" "$t_prev" "$ms_diff")
            sample_old[$t_name]=$now_ms
            [ "$rx_s" -lt 0 ] && rx_s=0; [ "$tx_s" -lt 0 ] && tx_s=0
            rx_old[$t_name]=$r_new; tx_old[$t_name]=$t_new

            local c_rx="${DIM}"; [ "$rx_s" -gt 0 ] && c_rx="${G}"
            local c_tx="${DIM}"; [ "$tx_s" -gt 0 ] && c_tx="${Y}"

            printf "  ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} %b%-14s%b ${B}│${NC} %b%-16s%b ${B}│${NC} %b%-16s%b ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC} ${DIM}%-18s${NC} ${B}│${NC}\n" "$t_name" "$st_color" "$st_text" "$NC" "$c_rx" "$(format_speed $rx_s)" "$NC" "$c_tx" "$(format_speed $tx_s)" "$NC" "$(format_total $r_new)" "$(format_total $t_new)"
            ((count++))
        done

        if [ "$count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-120s${NC} ${B}│${NC}\n" "  No active Backhaul tunnels configured."
        fi
        echo -e "  ${B}╰──────────────────────┴────────────────┴──────────────────┴──────────────────┴────────────────────┴────────────────────╯${NC}"
        printf "\033[J"
        read -t 1 -n 1 -s key; if [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\e' ]]; then break; fi
    done
    tput cnorm
}

manage_cron() {
    local t_name="$1"
    local cron_script="$CONF_DIR/${t_name}_restart.sh"
    
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
        [[ ! "$interval" =~ ^[0-9]+$ ]] && echo -e "  ${R}Invalid interval!${NC}" && sleep 1.5 && return
        
        echo "#!/bin/bash" > "$cron_script"
        echo "systemctl kill -s SIGKILL mbackhaul@${t_name}" >> "$cron_script"
        echo "systemctl restart mbackhaul@${t_name}" >> "$cron_script"
        chmod +x "$cron_script"
        
        if command -v crontab >/dev/null 2>&1; then
            local cron_tmp="$SECURE_TMP/crontab.$$"
            crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
            echo "0 */${interval} * * * $cron_script #mbackhaul@${t_name}" >> "$cron_tmp"
            crontab "$cron_tmp"; rm -f "$cron_tmp"
            echo -e "  ${G}✔ Cronjob added: Tunnel will restart every ${interval} hours.${NC}"; sleep 2
        else
            echo -e "  ${R}✖ Crontab utility is missing on this system.${NC}"; sleep 2
        fi
    elif [[ "$cr_opt" == "2" ]]; then
        if command -v crontab >/dev/null 2>&1; then
            local cron_tmp="$SECURE_TMP/crontab.$$"
            crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
            crontab "$cron_tmp"; rm -f "$cron_tmp"
        fi
        rm -f "$cron_script"
        echo -e "  ${G}✔ Cronjob removed.${NC}"; sleep 1.5
    fi
}

uninstall_mbackhaul() {
    clear
    echo -e "\n  ${R}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${R}│${NC}   ${R}⚠ WARNING: COMPLETE PURGE & UNINSTALLATION OF MBACKHAUL${NC}                 ${R}│${NC}"
    echo -e "  ${R}│${NC}   This will permanently stop and delete:                                   ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All active Backhaul tunnels & systemd units                            ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All configurations, metadata & SSL certificates                        ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All iptables traffic counters & crontabs                               ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● Backhaul core binaries (/usr/local/bin/bh) & mbackhaul module          ${R}│${NC}"
    echo -e "  ${R}╰────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    
    echo -ne "  ${Y}Are you sure you want to proceed? Type '${R}yes${Y}' to confirm: ${NC}"; read confirm
    confirm=$(echo "$confirm" | tr -d '\r ')
    
    if [ "$confirm" != "yes" ]; then
        echo -e "  ${G}● Uninstallation cancelled.${NC}"; sleep 1.5; return
    fi

    echo -e "\n  ${DIM}● [1/6] Stopping services & killing processes...${NC}"
    systemctl stop mbackhaul@* mbackhaul-apply.service 2>/dev/null
    systemctl disable mbackhaul@* mbackhaul-apply.service 2>/dev/null
    killall -9 bh 2>/dev/null

    echo -e "  ${DIM}● [2/6] Purging iptables traffic counters...${NC}"
    local bin chain direction
    for bin in iptables ip6tables; do
        for chain in INPUT OUTPUT; do
            for direction in RX TX; do mt_delete_tagged_rules "$bin" mangle "$chain" "MBH_${direction}_" prefix; done
        done
    done

    echo -e "  ${DIM}● [3/6] Purging scheduled auto-restart cronjobs...${NC}"
    if command -v crontab >/dev/null 2>&1; then
        local cron_tmp="$SECURE_TMP/crontab.$$"
        crontab -l 2>/dev/null | grep -v "mbackhaul@" > "$cron_tmp"
        crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
    fi

    echo -e "  ${DIM}● [4/6] Removing systemd unit files...${NC}"
    rm -f /etc/systemd/system/mbackhaul@.service /etc/systemd/system/mbackhaul-apply.service
    systemctl daemon-reload 2>/dev/null

    echo -e "  ${DIM}● [5/6] Deleting configs, certificates & core binary...${NC}"
    rm -rf /etc/mbackhaul "$SECURE_TMP/.mbackhaul"* /usr/local/bin/bh /usr/bin/bh

    echo -e "  ${DIM}● [6/6] Removing mbackhaul wrapper script...${NC}"
    rm -f "$INSTALL_PATH" 2>/dev/null
    [ -f "$0" ] && rm -f "$0" 2>/dev/null

    echo -e "\n  ${G}✔ MBackhaul ecosystem has been completely eradicated from this system.${NC}\n"
    exit 0
}

select_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; fi
    
    echo -e "\n  ${B}╭────────────────── Select Tunnel to Manage ─────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r')
    mt_valid_index "$t_idx" "${#configs[@]}" || return 1
    t_idx=$((10#$t_idx))
    
    SELECTED_TUN="${configs[$t_idx]}"
    return 0
}

check_first_run_core
apply_bbr_optimization
setup_systemd_service

render_mbackhaul_menu() {
    badge=""
    if [ -f "$SECURE_TMP/.mbackhaul_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.mbackhaul_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && mt_is_newer_version "$rv" "$MODULE_VERSION"; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_header
    echo -e "\n  ${DIM}┌─[ DEPLOYMENT & DESTRUCTION ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Deploy New Backhaul Tunnel${NC} ${DIM}(TCP / MUX / WSS)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Delete Tunnels${NC} ${DIM}(Specific / ALL)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Edit Remote Host / IP Address${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Edit Port Mappings${NC} ${DIM}(Iran Server)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Change Transport Protocol${NC} ${DIM}(Hot-Swap)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Edit Auth Token (Secret)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${C}Edit Tunnel Link Port${NC} ${DIM}(Connection Port)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Toggle UDP Support${NC} ${DIM}(Iran Server)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${W}Rename Tunnel Interface${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & DETAILS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${C}Live Traffic & Bandwidth Radar${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${W}View Tunnels Registry & Settings${NC}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${DIM}View Live Service Logs${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC}${DIM}❯${NC} ${Y}Anti-Freeze Cronjob Manager${NC}"
    echo -e "  ${DIM}├─${NC} ${W}14${NC}${DIM}❯${NC} ${G}Restart Service & Zero Counters${NC}"
    echo -e "  ${DIM}├─${NC} ${W}15${NC}${DIM}❯${NC} ${M}Install / Update Core Binary${NC}"
    echo -e "  ${DIM}├─${NC} ${W}16${NC}${DIM}❯${NC} ${G}Instant OTA Update (Sync Module)${NC}${badge}"
    echo -e "  ${DIM}├─${NC} ${W}17${NC}${DIM}❯${NC} ${R}Uninstall MBackhaul${NC} ${DIM}(Purge All)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo "  18 ❯ Edit Server Listen IPv4/IPv6"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}

while true; do
    render_mbackhaul_menu
    read_with_refresh "  ${C}MBACKHAUL ❯❯ ${NC}" opt render_mbackhaul_menu
    opt=$(echo "$opt" | tr -d '\r')
    
    case $opt in
        1) 
           echo -e "\n  ${DIM}┌─[ DEPLOY NEW TUNNEL ]${NC}"
           while true; do 
               echo -ne "  ${C}●${NC} ${W}Role [1: IRAN (Server) | 2: KHAREJ (Client) | q: Back]: ${NC}"; read s_type
               s_type=$(echo "$s_type" | tr -d '\r')
               [[ "$s_type" =~ ^[12q]$ ]] && break
           done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do
               echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}TCP${NC} | ${W}2${NC} ${DIM}❯${NC} ${C}TCPMUX${NC} | ${W}3${NC} ${DIM}❯${NC} ${M}WSMUX${NC} | ${W}4${NC} ${DIM}❯${NC} ${G}WSSMUX (TLS)${NC}"
               echo -ne "  ${C}● Transport Protocol [1-4]: ${NC}"; read tr_choice
               tr_choice=$(echo "$tr_choice" | tr -d '\r')
               [[ "$tr_choice" =~ ^[1-4]$ ]] && break
           done
           
           tr_val="tcp"
           case $tr_choice in 1) tr_val="tcp" ;; 2) tr_val="tcpmux" ;; 3) tr_val="wsmux" ;; 4) tr_val="wssmux" ;; esac
           
           echo -ne "  ${C}● Tunnel Suffix Name (e.g. bh1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
           t_name="bh_${suffix}"
           
           def_p=8443; [ "$tr_val" == "tcpmux" ] && def_p=9443; [ "$tr_val" == "wssmux" ] && def_p=9743
           while true; do
               echo -ne "  ${C}● Tunnel Link Port [Default ${def_p}]: ${NC}"; read t_port
               t_port=${t_port//$'\r'/}
               t_port=${t_port:-$def_p}
               
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
           
           bind_host="0.0.0.0"
           if [ "$s_type" == 1 ]; then mt_ask_bind_host || continue; bind_host="$MT_BIND_HOST"; fi
           r_ip="0.0.0.0"
           if [ "$s_type" == "2" ]; then
               while true; do
                   echo -ne "  ${C}● Iran Server Host/IP: ${NC}"; read r_ip
                   r_ip=$(mt_normalize_host "${r_ip//$'\r'/}")
                   is_valid_host "$r_ip" && break
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"
               done
           fi
           
           gen_tok=$(head -c 8 /dev/urandom | xxd -p)
           echo -ne "  ${C}● Auth Token [Default ${gen_tok}]: ${NC}"; read u_tok
           u_tok=$(echo "$u_tok" | tr -dc 'a-zA-Z0-9_-')
           tok=${u_tok:-$gen_tok}

           u_udp="true"
           fwd_ports=""
           if [ "$s_type" == "1" ]; then
               echo -ne "  ${C}●${NC} ${W}Enable UDP Support (Gaming/VoIP/DNS)? [Y/n] (Default: Y): ${NC}"; read enable_udp
               enable_udp=$(echo "$enable_udp" | tr -d '\r ')
               [[ "${enable_udp,,}" =~ ^(n|no)$ ]] && u_udp="false" || u_udp="true"

               # رفع باگ ۲: اعتبارسنجی دقیق پورت‌های فوروارد سرور ایران
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Forward Ports (e.g. 443=127.0.0.1:443): ${NC}"; read fwd_ports
                   fwd_ports=$(echo "$fwd_ports" | tr -d '\r')
                   validate_bh_ports "$fwd_ports" "1" && break
               done
           fi
           
           write_bh_config "$t_name" "$s_type" "$tr_val" "$t_port" "$r_ip" "$tok" "$fwd_ports" "$u_udp" "$bind_host" || continue
           systemctl enable "mbackhaul@${t_name}" >/dev/null 2>&1
           systemctl restart "mbackhaul@${t_name}"
           echo -e "  ${G}● Backhaul Tunnel Deployed Successfully!${NC}"; sleep 2 ;;
           
        2)
           configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Delete ─────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}Index (or 'all' / 'q'): ${NC}"; read del_idx
           del_idx=$(echo "$del_idx" | tr -d '\r')
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do
                   t_name=$(basename "$conf" .meta)
                   systemctl stop mbackhaul@$t_name 2>/dev/null; systemctl disable mbackhaul@$t_name 2>/dev/null
                   clean_bh_counters "$t_name"
                   if command -v crontab >/dev/null 2>&1; then
                       cron_tmp="$SECURE_TMP/crontab.$$"
                       crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
                       crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
                   fi
                   rm -f "$conf" "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${t_name}_restart.sh"
               done
               echo -e "  ${G}All Tunnels Purged!${NC}"; sleep 1.5
           elif mt_valid_index "$del_idx" "${#configs[@]}"; then
               del_idx=$((10#$del_idx))
               t_name=$(basename "${configs[$del_idx]}" .meta)
               systemctl stop mbackhaul@$t_name 2>/dev/null; systemctl disable mbackhaul@$t_name 2>/dev/null
               clean_bh_counters "$t_name"
               if command -v crontab >/dev/null 2>&1; then
                   cron_tmp="$SECURE_TMP/crontab.$$"
                   crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
                   crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
               fi
               rm -f "${configs[$del_idx]}" "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${t_name}_restart.sh"
               echo -e "  ${G}Tunnel Purged!${NC}"; sleep 1.5
           fi ;;
           
        3|4|5|6|7|8|9|13|14|18)
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN" .meta)
           ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; ENABLE_UDP=""; BIND_HOST="0.0.0.0"
           source "$SELECTED_TUN" 2>/dev/null
           [ -z "$ENABLE_UDP" ] && ENABLE_UDP="true"
           
           if [[ "$opt" == "3" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Remote Host/IP (Current: ${REMOTE_IP}): ${NC}"; read n_ip
               n_ip=$(mt_normalize_host "${n_ip//$'\r'/}")
               if [ -z "$n_ip" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if ! is_valid_host "$n_ip"; then
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"; sleep 1.5; continue
               fi
               clean_bh_counters "$t_name"
               REMOTE_IP="$n_ip"
               
           elif [[ "$opt" == "4" ]]; then
               if [ "$ROLE" == "1" ]; then
                   while true; do
                       echo -ne "  ${C}●${NC} ${W}New Port Mappings (e.g. 443=127.0.0.1:443) [Current: ${PORTS:-None}]: ${NC}"; read n_ports
                       n_ports=$(echo "$n_ports" | tr -d '\r')
                       if [ -z "$n_ports" ]; then
                           echo -e "  ${Y}● No changes made.${NC}"; break
                       fi
                       validate_bh_ports "$n_ports" "1" "$PORTS" && { PORTS="$n_ports"; break; }
                   done
                   [ -z "$n_ports" ] && continue
               else
                   echo -e "  ${Y}● Client role doesn't use port mappings.${NC}"; sleep 1.5; continue
               fi
               
           elif [[ "$opt" == "5" ]]; then
               echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}TCP${NC} | ${W}2${NC} ${DIM}❯${NC} ${C}TCPMUX${NC} | ${W}3${NC} ${DIM}❯${NC} ${M}WSMUX${NC} | ${W}4${NC} ${DIM}❯${NC} ${G}WSSMUX (TLS)${NC}"
               echo -ne "  ${C}● Select New Transport [1-4]: ${NC}"; read tr_choice
               tr_choice=$(echo "$tr_choice" | tr -d '\r')
               if [[ ! "$tr_choice" =~ ^[1-4]$ ]]; then
                   echo -e "  ${R}Invalid option.${NC}"; sleep 1; continue
               fi
               
               if [ "$tr_choice" == "1" ]; then TRANSPORT="tcp"
               elif [ "$tr_choice" == "2" ]; then TRANSPORT="tcpmux"
               elif [ "$tr_choice" == "3" ]; then TRANSPORT="wsmux"
               elif [ "$tr_choice" == "4" ]; then TRANSPORT="wssmux"; fi
               
               echo -e "  ${Y}⚠ Target protocol changed to ${TRANSPORT^^}. Make sure to update the peer!${NC}"
               clean_bh_counters "$t_name"

           elif [[ "$opt" == "6" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Auth Token / Secret [Current: ${Y}${TOKEN}${W}]: ${NC}"; read n_tok
               n_tok=$(echo "$n_tok" | tr -dc 'a-zA-Z0-9_-')
               if [ -z "$n_tok" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               TOKEN="$n_tok"
               echo -e "  ${G}✔ Auth Token updated to: ${TOKEN}${NC}"

           elif [[ "$opt" == "7" ]]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Enter New Link Port [Current: ${Y}${TUN_PORT}${W}]: ${NC}"; read n_tun_port
                   n_tun_port=${n_tun_port//$'\r'/}
                   if [ -z "$n_tun_port" ]; then
                       echo -e "  ${Y}● No changes made.${NC}"; break
                   fi
                   if ! mt_valid_port "$n_tun_port"; then
                       echo -e "  ${R}Error: Port must be between 1 and 65535!${NC}"; continue
                   fi
                   if [ "$n_tun_port" != "$TUN_PORT" ] && ss -tuln 2>/dev/null | grep -qE ":${n_tun_port}\s"; then
                       echo -e "  ${R}Error: Port ${n_tun_port} is already in use!${NC}"; continue
                   fi
                   clean_bh_counters "$t_name"
                   TUN_PORT="$n_tun_port"
                   echo -e "  ${G}✔ Link Port updated to ${n_tun_port}.${NC}"
                   break
               done
               [ -z "$n_tun_port" ] && continue

           elif [[ "$opt" == "8" ]]; then
               if [ "$ROLE" == "1" ]; then
                   if [ "$ENABLE_UDP" == "true" ]; then
                       ENABLE_UDP="false"
                       echo -e "  ${Y}● UDP forwarding Disabled.${NC}"
                   else
                       ENABLE_UDP="true"
                       echo -e "  ${G}✔ UDP forwarding Enabled.${NC}"
                   fi
               else
                   echo -e "  ${Y}● UDP toggle is configured on the Server (Iran) side.${NC}"; sleep 1.5; continue
               fi
               
           elif [[ "$opt" == "9" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Tunnel Suffix Name (Current: ${Y}${t_name#bh_}${W}): ${NC}"; read new_suffix
               new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
               if [ -n "$new_suffix" ]; then
                   new_t_name="bh_${new_suffix}"
                   if [ -f "$CONF_DIR/${new_t_name}.meta" ]; then
                       echo -e "  ${R}● Error: Tunnel name [${new_t_name}] already exists!${NC}"; sleep 1.5; continue
                   fi
                   
                   systemctl stop mbackhaul@$t_name 2>/dev/null; systemctl disable mbackhaul@$t_name 2>/dev/null
                   clean_bh_counters "$t_name"
                   
                   if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "mbackhaul@${t_name}"; then
                       cron_tmp="$SECURE_TMP/crontab.$$"
                       crontab -l | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
                       crontab "$cron_tmp"; rm -f "$cron_tmp"
                       rm -f "$CONF_DIR/${t_name}_restart.sh"
                   fi

                   mv "$CONF_DIR/${t_name}.meta" "$CONF_DIR/${new_t_name}.meta" 2>/dev/null
                   mv "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${new_t_name}.toml" 2>/dev/null
                   
                   t_name="$new_t_name"
                   systemctl enable mbackhaul@$t_name >/dev/null 2>&1
                   echo -e "  ${G}● Tunnel successfully renamed to: ${new_t_name}${NC}"
               else
                   echo -e "  ${Y}● Rename cancelled.${NC}"; sleep 1; continue
               fi
               
           elif [[ "$opt" == "13" ]]; then
               manage_cron "$t_name"; continue
               
           elif [[ "$opt" == "18" ]]; then
               [ "$ROLE" == 1 ] || continue
               mt_ask_bind_host || continue; BIND_HOST="$MT_BIND_HOST"

           elif [[ "$opt" == "14" ]]; then
               zero_bh_counters "$t_name"
           fi
           
           write_bh_config "$t_name" "$ROLE" "$TRANSPORT" "$TUN_PORT" "$REMOTE_IP" "$TOKEN" "$PORTS" "$ENABLE_UDP" "$BIND_HOST" || continue
           systemctl restart mbackhaul@$t_name
           if systemctl is-active --quiet mbackhaul@$t_name; then
               echo -e "  ${G}✔ Tunnel updated and service restarted successfully.${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Tunnel failed to start. Please check logs!${NC}"; sleep 2
           fi
           ;;
           
        10) show_live_radar ;;
        11) show_tunnel_registry ;;
        12) 
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN" .meta)
           journalctl -u mbackhaul@$t_name -n 50 -f; continue
           ;;
           
        15) menu_install_core ;;
        16) self_update_module ;;
        17) uninstall_mbackhaul ;;
        0) break ;;
    esac
done
