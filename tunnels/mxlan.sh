#!/bin/bash
# --- MXLAN Layer-2 Fabric (mxlan.sh) | MDesign Core v12.0.3 ---
# [v2.4.1: Header rows = name ➔ local IPv4 ➔ remote IPv4 [TYPE] (VXLAN / VXLAN6 told apart) | IPv6 2nd header line removed
#          | optional "Remote Server IPv4" (REMOTE_V4) in setup + Edit IPs | Live in-place header refresh (ping/loss/uptime, no full-screen redraw)
#          | Update badge repaints the menu live without erasing typed text | Background signals can no longer interrupt/erase prompt input]
# [v2.2.0: IPv6 underlay (VXLAN over IPv6) | IPv6-aware header (2nd line) | ip6tables peer Guard | IPv6 ESP | IPv6 path-MTU probe | manual MTU menu]
# [v2.0.0: Quote-safe iptables cleanup | Safe pickers | Cross-tool subnet guard | SSH-safe DNAT | MSS clamp
#          | IPsec ESP | Firewall Guard (UDP 4789) | Watchdog + LB health | MTU manager | Traffic | Backup | CLI]
# [Features: Symmetric Telemetry Header | Compact Peer Link | Integer Ping | Pinned Header | MPorter Launcher]

MODULE_VERSION="13.5.0"

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
        case "$key" in TYPE|LOCAL_PUB|REMOTE_PUB|LOCAL_PUB6|REMOTE_PUB6|MAX_IPS|SYNC_KEY|TUN_SECRET|T_NAME|TUN_ID|CORE_SUBNET|CORE_V6|TUN_PROTO|LOCAL_IP6|REMOTE_IP6|REMOTE_V4|FWD_TCP|FWD_UDP|FWD_TARGETS|LB_MODE|CUSTOM_MTU|ENCRYPT|VNI_ID|BR_NAME|VX_NAME|FAB_PROTO) ;; *) return 1;; esac
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
        [[ "$value" =~ ^[A-Za-z0-9_:./=,+%-]*$ ]] || return 1
        [ "$key" != FWD_TARGETS ] || mt_valid_fwd_targets "$value" || return 1
    done < "$file"
}

mt_valid_fwd_targets() {
    local spec="$1" ip
    [[ -z "$spec" || "$spec" == all ]] && return 0
    [[ "$spec" =~ ^[0-9.]+(,[0-9.]+)*$ ]] || return 1
    local -a ips=()
    IFS=',' read -ra ips <<< "$spec"
    for ip in "${ips[@]}"; do mt_valid_ipv4 "$ip" || return 1; done
}

mt_fwd_candidates() {
    local core="$1" key="$2" max="${3:-0}" type="$4" pair ip seen="|$1|"
    mt_valid_ipv4 "$core" && [[ "$max" =~ ^[0-9]{1,3}$ && "$type" == 1 ]] && ((10#$max <= 64)) || return 1
    max=$((10#$max))
    printf '%s\n' "$core"
    while read -r pair; do
        ip="${pair#* }"
        mt_valid_ipv4 "$ip" || continue
        [[ "$seen" == *"|$ip|"* ]] && continue
        seen+="$ip|"; printf '%s\n' "$ip"
    done < <(vip_targets "$key" "$max" "$type")
}

mt_fwd_selected() {
    local spec="$1" lb="$2"; shift 2
    local available ip seen='|' found=0
    available=$(mt_fwd_candidates "$@") || return 1
    mt_valid_fwd_targets "$spec" || return 1
    if [ -z "$spec" ]; then
        if [ "$lb" == 1 ]; then spec=all
        else printf '%s\n' "$available" | head -n 1; return 0; fi
    fi
    if [ "$spec" == all ]; then printf '%s\n' "$available"; return 0; fi
    local -a chosen=()
    IFS=',' read -ra chosen <<< "$spec"
    for ip in "${chosen[@]}"; do
        if grep -qxF "$ip" <<< "$available" && [[ "$seen" != *"|$ip|"* ]]; then
            seen+="$ip|"; printf '%s\n' "$ip"; found=1
        fi
    done
    # Never substitute an unselected core/vIP when selected addresses disappear.
    [ "$found" == 1 ]
}

mt_parse_fwd_choice() {
    local choice="${1//$'\r'/}" item idx ip seen='|' result=''; shift
    local -a available=("$@") parts=()
    choice="${choice// /}"
    MT_FWD_CHOICE=''
    case "${choice,,}" in '') return 2;; q) return 2;; all|a|'*') MT_FWD_CHOICE=all; return 0;; esac
    [[ "$choice" =~ ^[0-9.]+(,[0-9.]+)*$ ]] || return 1
    IFS=',' read -ra parts <<< "$choice"
    for item in "${parts[@]}"; do
        if [[ "$item" == *.* ]]; then
            mt_valid_ipv4 "$item" || return 1
            ip="$item"
            printf '%s\n' "${available[@]}" | grep -qxF "$ip" || return 1
        else
            [[ "$item" =~ ^[0-9]{1,3}$ ]] && ((10#$item >= 1 && 10#$item <= ${#available[@]})) || return 1
            idx=$((10#$item-1)); ip="${available[$idx]}"
        fi
        [[ "$seen" == *"|$ip|"* ]] && continue
        seen+="$ip|"; result+="${result:+,}$ip"
    done
    [ -n "$result" ] || return 1
    MT_FWD_CHOICE="$result"
}

mt_save_fwd_selection() {
    local file="$1" spec="$2" lb="$3" tmp rc=1
    mt_validate_conf "$file" && mt_valid_fwd_targets "$spec" && [[ "$lb" =~ ^[01]$ ]] || return 1
    tmp=$(mktemp "${file}.targets.XXXXXX") || return 1
    if awk '!/^FWD_TARGETS=/ && !/^LB_MODE=/' "$file" > "$tmp" &&
       printf 'FWD_TARGETS=%s\nLB_MODE=%s\n' "$spec" "$lb" >> "$tmp" &&
       mt_validate_conf "$tmp" && mt_install_files 600 "$tmp" "$file"; then rc=0; fi
    rm -f "$tmp"
    return "$rc"
}

mt_choose_fwd_targets() {
    local file="$1"; shift
    local candidates selected choice rc spec lb count ip i label mark
    candidates=$(mt_fwd_candidates "$@") || return 1
    spec=$(mt_config_value FWD_TARGETS "$file"); lb=$(mt_config_value LB_MODE "$file")
    selected=$(mt_fwd_selected "$spec" "$lb" "$@") || selected=''
    local -a available=()
    mapfile -t available <<< "$candidates"
    while true; do
        echo -e "\n  ${DIM}┌─[ FORWARDING & LOAD BALANCER TARGETS ]${NC}"
        echo -e "  ${DIM}│${NC}"
        for ((i=0; i<${#available[@]}; i++)); do
            ip="${available[$i]}"; label=vIP; [ "$i" != 0 ] || label='Core Peer'
            mark=''; grep -qxF "$ip" <<< "$selected" && mark=' [Selected]'
            printf '  %b├─%b %b%-2s%b%b❯%b %b%s%b %b(%s)%s%b\n' "$DIM" "$NC" "$W" "$((i+1))" "$NC" "$DIM" "$NC" "$C" "$ip" "$NC" "$DIM" "$label" "$mark" "$NC"
        done
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}a${NC} ${DIM}❯${NC} ${G}All IPs (Core Peer + All vIPs)${NC}"
        echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel / Keep Current${NC}\n"
        echo -ne "  ${C}●${NC} ${W}Select IP(s) [e.g. 2 or 2,3 | a: all | Enter: keep]: ${NC}"
        read -r choice || return 2
        if mt_parse_fwd_choice "$choice" "${available[@]}"; then rc=0; else rc=$?; fi
        [ "$rc" != 2 ] || return 2
        if [ "$rc" != 0 ]; then echo -e "  ${R}✖ Select valid entries from this tunnel.${NC}"; continue; fi
        spec="$MT_FWD_CHOICE"; count=0
        if [ "$spec" == all ]; then count=${#available[@]}
        else local -a chosen=(); IFS=',' read -ra chosen <<< "$spec"; count=${#chosen[@]}; fi
        lb=0; [ "$count" -le 1 ] || lb=1
        mt_save_fwd_selection "$file" "$spec" "$lb" || return 1
        echo -e "  ${G}✔ Selected ${count} IP(s); $([ "$lb" == 1 ] && echo 'load balancing enabled' || echo 'direct forwarding enabled').${NC}"
        return 0
    done
}

mt_fwd_target_summary() {
    local spec="$1" lb="$2" item count=0
    if [ -z "$spec" ]; then
        if [ "$lb" == 1 ]; then echo 'All IPs (Legacy)'; else echo 'Core Peer (Legacy)'; fi
    elif [ "$spec" == all ]; then
        if [ "$lb" == 1 ]; then echo 'All IPs (Core Peer + vIPs)'; else echo 'Core Peer (Direct)'; fi
    else
        local -a ips=(); IFS=',' read -ra ips <<< "$spec"; count=${#ips[@]}
        if [ "$lb" != 1 ]; then echo "${ips[0]} (Direct)"
        elif [ "$count" == 1 ]; then echo "${ips[0]}"
        else echo "Selected Pool (${count} IPs)"; fi
    fi
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

mt_render_tunnel_system_tools() {
    local healer="$1" bbr="$2"
    echo -e "  ${DIM}├─${NC} ${W}${healer}${NC}${DIM}❯${NC} ${G}Autonomous Tunnel Healer${NC}"
    echo -e "  ${DIM}├─${NC} ${W}${bbr}${NC}${DIM}❯${NC} ${G}TCP BBR Accelerator${NC} ${DIM}(Entire Server)${NC}"
}

mt_monitor_wait() {
    local key='' rc=0
    read -r -t "$1" -n 1 -s key || rc=$?
    case "$key" in q|Q|$'\e') return 1;; esac
    [ "$rc" -ne 1 ]
}

mt_tunnels_info_menu() {
    local kind="$1" header="$2" details="$3" extra_view="$4" choice rc
    local extra_label='Live Service Logs'
    mt_valid_scope "$kind" && [ "$kind" != all ] || return 1
    case "$kind" in gre|vxlan) extra_label='Live Traffic Monitor (RX/TX Rate)';; esac
    while true; do
        "$details" --no-pause
        echo -e "\n  ${DIM}┌─[ DETAILS ACTIONS ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}${extra_label}${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Menu${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"
        rc=0
        read -r choice || rc=$?
        [ "$rc" -le 128 ] || continue
        [ "$rc" -eq 0 ] || return 0
        case "${choice//$'\r'/}" in
            1) mt_run_tool minterface --scope "$kind" --render;;
            2) "$extra_view";;
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
INSTALL_PATH="/usr/bin/mxlan"
CONF_DIR="/etc/mgre/vxlan"
SERVICE_FILE="/etc/systemd/system/mxlan.service"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mxlan" ] && rm -f "/usr/local/bin/mxlan" 2>/dev/null

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

# ======================================================================
# [ v-next ] Shared Hardening Helpers (validation, iptables, guard, xfrm)
# ======================================================================
MT_ROOT_CONF="/etc/mgre"
GUARD_FLAG="$MT_ROOT_CONF/.mxlan_guard"
WD_SERVICE="/etc/systemd/system/mxlan-watchdog.service"
WD_TIMER="/etc/systemd/system/mxlan-watchdog.timer"
WD_LOG="/var/log/mxlan-watchdog.log"
BACKUP_DIR="$LOCAL_DIR/backups"

is_uint()  { [[ "$1" =~ ^[0-9]+$ ]]; }
is_ipv4()  {
    local ip="$1" x; local -a o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra o <<< "$ip"
    for x in "${o[@]}"; do [ "$((10#$x))" -le 255 ] || return 1; done
    return 0
}
is_subnet3() {
    local s="$1" x; local -a o
    [[ "$s" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra o <<< "$s"
    for x in "${o[@]}"; do [ "$((10#$x))" -le 255 ] || return 1; done
    return 0
}


# Strict-enough IPv6 literal check (no zone ids, no embedded IPv4)
is_ipv6() {
    local ip="$1" g n=0 f=0 dbl=0 rest
    local -a parts
    [ -n "$ip" ] && [ "${#ip}" -le 39 ] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" == *:::* ]] && return 1
    if [[ "$ip" == *::* ]]; then
        rest="${ip#*::}"; [[ "$rest" == *::* ]] && return 1
        dbl=1
    fi
    [[ "$ip" == :* && "$ip" != ::* ]] && return 1
    [[ "$ip" == *: && "$ip" != *:: ]] && return 1
    IFS=':' read -ra parts <<< "$ip"
    for g in "${parts[@]}"; do
        f=$((f+1))
        [ -z "$g" ] && continue
        [ "${#g}" -le 4 ] || return 1
        n=$((n+1))
    done
    if [ "$dbl" -eq 1 ]; then
        [ "$n" -le 7 ] || return 1
    else
        { [ "$n" -eq 8 ] && [ "$f" -eq 8 ]; } || return 1
    fi
    return 0
}
# IPv6 usable as a tunnel endpoint (rejects ::, ::1, link-local fe80::/10, multicast)
is_global_ipv6() {
    local ip="${1,,}"
    is_ipv6 "$ip" || return 1
    case "$ip" in ::|::1|fe8*|fe9*|fea*|feb*|ff*) return 1 ;; esac
    return 0
}

# Safe single-variable write into a flat conf (adds the key if missing)
set_conf_var() {
    local file="$1" key="$2" val="$3"
    [ -f "$file" ] || return 1
    grep -v "^${key}=" "$file" > "${file}.tmp" 2>/dev/null
    echo "${key}=${val}" >> "${file}.tmp"
    mv -f "${file}.tmp" "$file"; chmod 600 "$file" 2>/dev/null
}

# Pick an item from a list safely. Usage: pick_index "<input>" <count>  -> echoes zero-based idx
pick_index() {
    local in="$1" cnt="$2"
    is_uint "$in" || return 1
    [ "$in" -ge 1 ] && [ "$in" -le "$cnt" ] || return 1
    echo $((in - 1))
}

# Delete all rules carrying an exact comment tag (quote-safe, fixes rule leaks)
ipt_delete_tagged() {
    mt_delete_tagged_rules "${IPT_BIN:-iptables}" "$1" "$2" "$3"
}

# Cross-tool subnet collision check (MGRE + MXLAN + live routes)
subnet_in_use() {
    local sub="$1" exclude="$2" f
    for f in "$MT_ROOT_CONF"/tunnels/*.conf "$MT_ROOT_CONF"/vxlan/*.conf; do
        [ -f "$f" ] || continue
        [ -n "$exclude" ] && [ "$(readlink -f "$f")" == "$(readlink -f "$exclude")" ] && continue
        grep -q "^CORE_SUBNET=${sub}$" "$f" 2>/dev/null && return 0
    done
    ip -4 route show 2>/dev/null | grep -qE "^${sub//./\\.}\.[0-9]+(/| )" && return 0
    return 1
}

get_ssh_ports() {
    local p
    p=$(ss -tlnpH 2>/dev/null | grep -w 'sshd' | awk '{print $4}' | sed 's/.*://' | sort -u | tr '\n' ' ')
    echo "${p:-22}"
}

# Clean a port list (supports ranges a:b). For TCP it refuses to hijack the SSH port.
sanitize_ports() {
    local raw="$1" proto="$2" out="" item a b s skip
    local ssh_ports; ssh_ports=$(get_ssh_ports)
    raw=$(echo "$raw" | tr -dc '0-9,:')
    local IFS=','
    for item in $raw; do
        [ -z "$item" ] && continue
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
            a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
            { [ "$a" -lt 1 ] || [ "$b" -gt 65535 ] || [ "$a" -ge "$b" ]; } && { echo -e "  ${Y}● Skipped invalid range: $item${NC}" >&2; continue; }
            item="${a}:${b}"
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            a=$((10#$item)); b=$a
            { [ "$a" -lt 1 ] || [ "$a" -gt 65535 ]; } && { echo -e "  ${Y}● Skipped invalid port: $item${NC}" >&2; continue; }
            item="$a"
        else
            echo -e "  ${Y}● Skipped invalid entry: $item${NC}" >&2; continue
        fi
        skip=0
        if [ "$proto" == "tcp" ]; then
            IFS=' '
            for s in $ssh_ports; do
                if [ "$s" -ge "$a" ] && [ "$s" -le "$b" ]; then skip=1; fi
            done
            IFS=','
            [ "$skip" -eq 1 ] && { echo -e "  ${R}● Refused '$item': it contains this server's SSH port (lock-out protection).${NC}" >&2; continue; }
        fi
        out+="${item},"
    done
    echo "${out%,}"
}

# Derive vIP pair targets exactly like the original engine (keeps peer compatibility)
vip_targets() {
    local key="$1" max="$2" type="$3" i hash rs o1 o2 o3
    [[ "$max" =~ ^[0-9]{1,3}$ ]] && ((10#$max <= 64)) || return 1
    max=$((10#$max))
    for ((i=0; i<max; i++)); do
        hash=$(echo "${key}_${i}" | sha256sum)
        rs=$(( 0x${hash:0:2} % 3 ))
        if [[ "$rs" == "0" ]]; then o1="10"; o2=$(( (0x${hash:2:2} % 254) + 1 ))
        elif [[ "$rs" == "1" ]]; then o1="172"; o2=$(( (0x${hash:2:2} % 16) + 16 ))
        else o1="192"; o2="168"; fi
        o3=$(( (0x${hash:4:2} % 254) + 1 ))
        if [ "$type" == "1" ]; then echo "$o1.$o2.$o3.1 $o1.$o2.$o3.2"; else echo "$o1.$o2.$o3.2 $o1.$o2.$o3.1"; fi
    done
}

# NAT / Load-Balancer builder. DNAT only hits traffic addressed to THIS host and never traffic coming from the tunnel itself.
build_fwd_rules() {
    local tag="$1" tif="$2" tcp="$3" udp="$4" lb="$5" deadf="$6"; shift 6
    local -a targets=("$@") live=()
    local t proto list p idx n rem dst
    [ "${#targets[@]}" -gt 0 ] || return 1
    for t in "${targets[@]}"; do mt_valid_ipv4 "$t" || return 1; done
    if [[ "$lb" == "1" ]]; then
        for t in "${targets[@]}"; do
            if [ -s "$deadf" ] && grep -qxF "$t" "$deadf"; then continue; fi
            live+=("$t")
        done
        [ ${#live[@]} -eq 0 ] && live=("${targets[0]}")
    else
        live=("${targets[0]}")
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    n=${#live[@]}
    for proto in tcp udp; do
        list="$tcp"; [ "$proto" == "udp" ] && list="$udp"
        [ -z "$list" ] && continue
        local -a PARR=()
        IFS=',' read -ra PARR <<< "$list"
        for p in "${PARR[@]}"; do
            p=$(echo "$p" | tr -dc '0-9:'); [ -z "$p" ] && continue
            for ((idx=0; idx<n; idx++)); do
                dst="${live[$idx]}"; rem=$((n - idx))
                if [ "$rem" -gt 1 ]; then
                    iptables -t nat -A PREROUTING ! -i "$tif" -m addrtype --dst-type LOCAL -p "$proto" -m "$proto" --dport "$p" -m statistic --mode nth --every "$rem" --packet 0 -m comment --comment "$tag" -j DNAT --to-destination "$dst" 2>/dev/null
                else
                    iptables -t nat -A PREROUTING ! -i "$tif" -m addrtype --dst-type LOCAL -p "$proto" -m "$proto" --dport "$p" -m comment --comment "$tag" -j DNAT --to-destination "$dst" 2>/dev/null
                fi
                iptables -t nat -A POSTROUTING -o "$tif" -p "$proto" -m "$proto" -d "$dst" --dport "$p" -m comment --comment "$tag" -j MASQUERADE 2>/dev/null
                iptables -t filter -A FORWARD -o "$tif" -p "$proto" -d "$dst" --dport "$p" -m comment --comment "$tag" -j ACCEPT 2>/dev/null
            done
        done
    done
}

# ---- IPsec (ESP transport) encryption, keys derived from the Master Token on both peers ----
xfrm_state_file() { echo "$SECURE_TMP/.mxlan_xfrm_$1"; }

xfrm_clear() {
    local name="$1" sf line; local -a command=()
    sf=$(xfrm_state_file "$name"); [ -f "$sf" ] || return 0
    while IFS= read -r line; do
        read -ra command <<< "$line"
        [[ "${command[0]:-}" == ip && "${command[1]:-}" == xfrm && "${command[3]:-}" == delete ]] || continue
        "${command[@]}" >/dev/null 2>&1
    done < "$sf"
    rm -f "$sf"
}

# Usage: xfrm_apply <name> <type 1|2> <local> <remote> <token> <selector...>
xfrm_apply() {
    local name="$1" type="$2" lip="$3" rip="$4" tok="$5"; shift 5
    local -a selectors=("$@")
    [[ "$tok" =~ ^[A-Za-z0-9_=-]+$ && "$type" =~ ^[12]$ ]] || return 1
    mt_valid_ipv4 "$lip" || mt_valid_ipv6 "$lip" || return 1
    mt_valid_ipv4 "$rip" || mt_valid_ipv6 "$rip" || return 1
    local plen=32
    if [[ "$lip" == *:* ]]; then
        plen=128
        [ -n "$(ip -6 -o addr show to "$lip" 2>/dev/null)" ] || return 1
    else ip -4 addr show 2>/dev/null | grep -qF "inet $lip/" || return 1; fi
    local h ab ba reqid ek_ab ak_ab ek_ba ak_ba spi_out spi_in ek_out ak_out ek_in ak_in sf pending
    h=$(printf '%s' "mtun_esp_${tok}" | sha256sum)
    ab=$(printf '0x%08x' "$((16#${h:0:7}+256))"); ba=$(printf '0x%08x' "$((16#${h:8:7}+256))"); reqid=$((16#${h:16:6}+1))
    ek_ab=$(printf '%s' "enc_ab_${tok}" | sha256sum | cut -c1-64); ak_ab=$(printf '%s' "auth_ab_${tok}" | sha256sum | cut -c1-64)
    ek_ba=$(printf '%s' "enc_ba_${tok}" | sha256sum | cut -c1-64); ak_ba=$(printf '%s' "auth_ba_${tok}" | sha256sum | cut -c1-64)
    if [ "$type" == 1 ]; then spi_out=$ab; ek_out=$ek_ab; ak_out=$ak_ab; spi_in=$ba; ek_in=$ek_ba; ak_in=$ak_ba
    else spi_out=$ba; ek_out=$ek_ba; ak_out=$ak_ba; spi_in=$ab; ek_in=$ek_ab; ak_in=$ak_ab; fi
    xfrm_clear "$name"
    sf=$(xfrm_state_file "$name"); pending=$(mktemp "$SECURE_TMP/xfrm.XXXXXX") || return 1
    local failed=0 line
    if ip xfrm state add src "$lip" dst "$rip" proto esp spi "$spi_out" reqid "$reqid" mode transport replay-window 0 auth-trunc 'hmac(sha256)' "0x$ak_out" 128 enc 'cbc(aes)' "0x$ek_out"; then
        echo "ip xfrm state delete src $lip dst $rip proto esp spi $spi_out" >> "$pending"
    else failed=1; fi
    if [ "$failed" == 0 ] && ip xfrm state add src "$rip" dst "$lip" proto esp spi "$spi_in" reqid "$reqid" mode transport replay-window 0 auth-trunc 'hmac(sha256)' "0x$ak_in" 128 enc 'cbc(aes)' "0x$ek_in"; then
        echo "ip xfrm state delete src $rip dst $lip proto esp spi $spi_in" >> "$pending"
    else failed=1; fi
    if [ "$failed" == 0 ] && ip xfrm policy add src "$lip/$plen" dst "$rip/$plen" "${selectors[@]}" dir out tmpl src "$lip" dst "$rip" proto esp reqid "$reqid" mode transport; then
        printf '%s ' ip xfrm policy delete src "$lip/$plen" dst "$rip/$plen" "${selectors[@]}" dir out >> "$pending"; echo >> "$pending"
    else failed=1; fi
    if [ "$failed" == 0 ] && ip xfrm policy add src "$rip/$plen" dst "$lip/$plen" "${selectors[@]}" dir in tmpl src "$rip" dst "$lip" proto esp reqid "$reqid" mode transport; then
        printf '%s ' ip xfrm policy delete src "$rip/$plen" dst "$lip/$plen" "${selectors[@]}" dir in >> "$pending"; echo >> "$pending"
    else failed=1; fi
    if [ "$failed" != 0 ]; then
        local -a command=()
        while IFS= read -r line; do read -ra command <<< "$line"; "${command[@]}" >/dev/null 2>&1; done < "$pending"
        rm -f "$pending" "$sf"; echo "IPsec setup failed for $name; partial states removed." >&2; return 1
    fi
    chmod 600 "$pending" && mv -f "$pending" "$sf"
}

human_rate() {
    local b="$1"
    awk -v b="$b" 'BEGIN { bits=b*8; if (bits>=1e9) printf "%.2f Gbps", bits/1e9; else if (bits>=1e6) printf "%.2f Mbps", bits/1e6; else if (bits>=1e3) printf "%.1f Kbps", bits/1e3; else printf "%d bps", bits }'
}
human_bytes() {
    awk -v b="$1" 'BEGIN { split("B KB MB GB TB",u," "); i=1; while (b>=1024 && i<5) { b/=1024; i++ } printf "%.1f %s", b, u[i] }'
}

# ---- Watchdog (systemd timer) ----
wd_log() { echo "[$(date '+%F %T')] $*" >> "$WD_LOG"; }

watchdog_enable() {
    cat > "$WD_SERVICE" <<EOS
[Unit]
Description=MXLAN Watchdog (auto-heal & LB health)
After=network-online.target
[Service]
Type=oneshot
ExecStart=$INSTALL_PATH --watchdog
EOS
    cat > "$WD_TIMER" <<EOS
[Unit]
Description=MXLAN Watchdog Timer
[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOS
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now mxlan-watchdog.timer >/dev/null 2>&1
}
watchdog_disable() {
    systemctl disable --now mxlan-watchdog.timer >/dev/null 2>&1
    rm -f "$WD_SERVICE" "$WD_TIMER"
    systemctl daemon-reload 2>/dev/null
}
watchdog_is_on() { systemctl is-active --quiet mxlan-watchdog.timer 2>/dev/null; }

# ---- Backup / Restore ----
backup_configs() {
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    local f; f=$(mktemp "$BACKUP_DIR/mxlan-$(date +%Y%m%d-%H%M%S)-XXXXXX.tgz") || return 1
    tar czf "$f" -C "$(dirname "$CONF_DIR")" "$(basename "$CONF_DIR")" 2>/dev/null && chmod 600 "$f" && echo "$f"
}
# ======================================================================

MX_MTU_MIN=900
MX_MTU_MAX=1450          # IPv4 underlay: 1500 - 50
MX_MTU_MAX6=1430         # IPv6 underlay: 1500 - 70

# ---- IPv4 / IPv6 underlay helpers ----
mx_is_v6() { [ "${FAB_PROTO:-ipv4}" == "ipv6" ]; }
mx_overhead() { [ "$1" == "ipv6" ] && echo 70 || echo 50; }
mx_mtu_max()  { [ "$1" == "ipv6" ] && echo "$MX_MTU_MAX6" || echo "$MX_MTU_MAX"; }
mx_proto_tag() { [ "$1" == "ipv6" ] && echo "VXLAN6" || echo "VXLAN"; }

# Outer (underlay) endpoints of the currently sourced conf -> EP_L EP_R EP_V6
mx_endpoints() {
    if mx_is_v6; then EP_V6=1; EP_L="$LOCAL_PUB6"; EP_R="$REMOTE_PUB6"
    else EP_V6=0; EP_L="$LOCAL_PUB"; EP_R="$REMOTE_PUB"; fi
}

# Stable global IPv6 of this host (skips privacy/temporary addresses)
get_local_ipv6() {
    local ip
    ip=$(ip -6 -o addr show scope global 2>/dev/null | grep -v -E 'temporary|deprecated|tentative' | awk '{print $4}' | cut -d/ -f1 | head -n 1)
    [ -z "$ip" ] && ip=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    echo "${ip,,}"
}
# Valid core subnet even for legacy confs without CORE_SUBNET (old fallback broke for VNI > 255)
mx_core_sub() {
    if [ -n "$CORE_SUBNET" ]; then echo "$CORE_SUBNET"
    elif is_uint "$VNI_ID" && [ "$VNI_ID" -le 255 ]; then echo "10.88.$VNI_ID"
    else echo "10.88.$(( (${VNI_ID:-0} % 254) + 1 ))"; fi
}


if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    mt_install_files 755 "$0" "$INSTALL_PATH" || { echo "Cannot install module." >&2; exit 1; }
fi

MAIN_PID=$$
NEED_REFRESH=false
trap '' SIGUSR1   # ignored: a signal must never interrupt typing in any prompt

UPDATE_CHECK_INTERVAL=30
PING_CHECK_INTERVAL=5

# Live header: repaint ONLY the header box in place (cursor saved/restored, nothing else touched).
# LIVE_HEADER_FUNC = header function, LIVE_ROWS = number of lines printed above the prompt line.
LIVE_HEADER_FUNC=""
LIVE_ROWS=0
LIVE_HEADER_INTERVAL=2
LIVE_MENU_FUNC=""        # menu renderer: redrawn (typed text kept) when the watcher finds a new remote version
LIVE_FRAME_FILE=""
LIVE_VER_FILE="$SECURE_TMP/.mxlan_remote_ver"

live_header_tick() {
    [ -n "$LIVE_HEADER_FUNC" ] || return 0
    local rows frame
    rows=$(stty size 2>/dev/null | awk '{print $1}'); [ -z "$rows" ] && rows="${LINES:-24}"
    # page taller than the terminal -> header already scrolled off-screen, never paint over the menu
    [ "$LIVE_ROWS" -ge "$rows" ] && return 0
    frame=$(HEADER_LIVE=1 "$LIVE_HEADER_FUNC")
    printf '\e7\e[%dA\r%s\e8' "$LIVE_ROWS" "$frame"
}

read_with_refresh() {
    local prompt="$1"
    local __resultvar="$2"
    local buffer=""
    local char rc now last_refresh upd_seen="" upd_cur=""
    printf -v last_refresh '%(%s)T' -1
    [ -f "$LIVE_VER_FILE" ] && read -r upd_seen < "$LIVE_VER_FILE"

    echo -ne "$prompt"

    while true; do
        printf -v now '%(%s)T' -1
        if [ $((now - last_refresh)) -ge "$LIVE_HEADER_INTERVAL" ]; then
            last_refresh=$now
            live_header_tick
        fi

        # new version found by the background watcher -> repaint the menu so the update badge shows live
        upd_cur=""; [ -f "$LIVE_VER_FILE" ] && read -r upd_cur < "$LIVE_VER_FILE"
        if [ "$upd_cur" != "$upd_seen" ]; then
            upd_seen="$upd_cur"
            if [ -n "$LIVE_MENU_FUNC" ] && [ -n "$LIVE_FRAME_FILE" ]; then
                "$LIVE_MENU_FUNC" > "$LIVE_FRAME_FILE"; cat "$LIVE_FRAME_FILE"
                LIVE_ROWS=$(( $(wc -l < "$LIVE_FRAME_FILE") ))
                echo -ne "$prompt$buffer"
            fi
        fi

        IFS= read -rsn1 -t 0.2 char
        rc=$?

        if [ $rc -ne 0 ]; then
            continue
        fi

        if [[ -z "$char" || "$char" == $'\n' || "$char" == $'\r' ]]; then
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

    printf -v "$__resultvar" '%s' "$buffer"
}

fetch_remote_version() {
    local url="$1" payload version=""
    if command -v curl >/dev/null 2>&1; then
        payload=$(curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 8 "$url" 2>/dev/null) || return 1
    elif command -v wget >/dev/null 2>&1; then
        payload=$(wget -qO- --header="Cache-Control: no-cache" --timeout=8 "$url" 2>/dev/null) || return 1
    else
        return 1
    fi
    version=$(printf '%s\n' "$payload" | sed -n 's/^MODULE_VERSION="\([^" ]*\)".*/\1/p' | head -n 1)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || return 1
    printf '%s\n' "$version"
}

check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tunnels/mxlan.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tunnels/mxlan.sh${cb}"
    local gh_ver="" mirror_ver=""

    gh_ver=$(fetch_remote_version "$raw_url")
    mirror_ver=$(fetch_remote_version "$mirror_url")
    [ -n "$gh_ver" ] && printf '%s\n' "$gh_ver" > "$SECURE_TMP/.mxlan_remote_ver_github"
    [ -n "$mirror_ver" ] && printf '%s\n' "$mirror_ver" > "$SECURE_TMP/.mxlan_remote_ver_mirror"
    local latest_ver=""
    latest_ver=$(printf '%s\n' "$gh_ver" "$mirror_ver" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' | sort -V | tail -n 1)
    if [ -n "$latest_ver" ]; then
        printf '%s\n' "$latest_ver" > "$SECURE_TMP/.mxlan_remote_ver"
    fi
}


update_watcher_loop() {
    while true; do
        check_update_bg
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
if [[ "$1" != --* ]]; then
    update_watcher_loop &
    WATCHER_PID=$!
fi

check_ping_bg() {
    local count=0
    local conf TYPE VX_NAME CORE_SUBNET VNI_ID c_sub tip res loss avg
    > "$SECURE_TMP/.mxlan_stats_cache.tmp"
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; VX_NAME=""; CORE_SUBNET=""; VNI_ID=""; source "$conf" 2>/dev/null
        [ -z "$VX_NAME" ] && continue
        
        ((count++))
        [ "$count" -gt 3 ] && break

        c_sub="$(mx_core_sub)"
        tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        res=$(timeout 2 ping -c 3 -i 0.2 -W 1 "$tip" 2>/dev/null)
        loss=$(echo "$res" | grep -oP '[0-9]+(?=% packet loss)')
        [ -z "$loss" ] && loss="100"
        
        avg="---"
        if echo "$res" | grep -q "min/avg/max"; then
            avg=$(echo "$res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
            if [ -n "$avg" ]; then
                avg=$(awk -v v="$avg" 'BEGIN {printf "%.0f", v}')
                avg="${avg}ms"
            fi
        fi
        echo "${VX_NAME}|${avg}|${loss}" >> "$SECURE_TMP/.mxlan_stats_cache.tmp"
    done
    mv -f "$SECURE_TMP/.mxlan_stats_cache.tmp" "$SECURE_TMP/.mxlan_stats_cache" 2>/dev/null
}

ping_watcher_loop() {
    while true; do
        check_ping_bg
        sleep "$PING_CHECK_INTERVAL"
    done
}
if [[ "$1" != --* ]]; then
    ping_watcher_loop &
    PING_WATCHER_PID=$!
fi

trap 'kill "$WATCHER_PID" "$PING_WATCHER_PID" 2>/dev/null' EXIT

get_local_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

get_pure_vx_name() {
    local pure="${1#vx_}"
    echo "${pure:-$1}"
}

get_iface_uptime() {
    local iface="$1"
    if [ ! -d "/sys/class/net/$iface" ] || [ "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" == "down" ]; then
        echo "DOWN"
        return
    fi
    local sys_uptime if_sec delta d h m
    sys_uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    if_sec=$(ip -s -d link show "$iface" 2>/dev/null | grep -oP 'trans_start \K[0-9]+')
    delta=0
    if [ -n "$if_sec" ] && [ "$if_sec" -gt 0 ]; then
        delta=$(( (sys_uptime * 100 - if_sec) / 100 ))
        [ "$delta" -lt 0 ] && delta=0
    else
        local created now
        created=$(stat -c %Y "/sys/class/net/$iface" 2>/dev/null)
        now=$(date +%s)
        delta=$(( now - created ))
        [ "$delta" -lt 0 ] && delta=0
    fi
    d=$(( delta / 86400 )); h=$(( (delta % 86400) / 3600 )); m=$(( (delta % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
    else printf "%dm" "$m"; fi
}

draw_mxlan_header() {
    local s_ip active_fabrics=0 conf
    s_ip=$(get_local_ip)
    s_ip="${s_ip:0:25}"
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue
        VX_NAME=""; source "$conf" 2>/dev/null
        if ip link show "$VX_NAME" >/dev/null 2>&1 && [ "$(cat "/sys/class/net/$VX_NAME/operstate" 2>/dev/null)" != "down" ]; then
            ((active_fabrics++))
        fi
    done

    [ -z "$HEADER_LIVE" ] && clear
    echo ""
    local border
    local BOXW=125 extra tw
    extra=$(( BOXW - 117 )); tw=$(( 24 + extra ))
    printf -v border '%*s' "$BOXW" ''
    border="${border// /─}"

    echo -e "  ${B}╭${border}╮${NC}"
    printf "  ${B}│${NC} ${W}%-34.34s${NC} ${B}│${NC} ${DIM}Local:${NC} ${W}%-25.25s${NC} ${B}│${NC} ${DIM}Active Fabrics:${NC} ${M}%-3.3s${NC}%-${tw}.${tw}s ${B}│${NC}\n" \
        "MXLAN Core v${MODULE_VERSION}" "$s_ip" "$active_fabrics" ""
    echo -e "  ${B}├${border}┤${NC}"

    local shown=0
    local TYPE REMOTE_PUB VX_NAME BR_NAME CORE_SUBNET VNI_ID FWD_TCP FWD_UDP MAX_IPS TUN_SECRET pure_name vip_stat vip_col
    local FAB_PROTO LOCAL_PUB LOCAL_PUB6 REMOTE_PUB6 REMOTE_V4 local_txt peer_txt tag_txt proto_tag
    local live_ping live_loss cached_entry loss_disp loss_col fwd_str if_uptime stat_icon stat_col fwd_col sec_disp
    local len_name len_rem pad_peer sp_peer
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; REMOTE_PUB=""; VX_NAME=""; BR_NAME=""; CORE_SUBNET=""; VNI_ID=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; TUN_SECRET=""; FAB_PROTO="ipv4"; LOCAL_PUB=""; LOCAL_PUB6=""; REMOTE_PUB6=""; REMOTE_V4=""; source "$conf" 2>/dev/null
        [ -z "$VX_NAME" ] && continue
        ((shown++))
        [ "$shown" -gt 3 ] && break

        pure_name=$(get_pure_vx_name "$VX_NAME")
        pure_name="${pure_name:0:10}"
        proto_tag=$(mx_proto_tag "$FAB_PROTO")
        if mx_is_v6; then
            # IPv6 underlay: show the peer's IPv4 (same look as IPv4 fabrics); tag only if no IPv4 was stored
            if is_ipv4 "$REMOTE_V4"; then peer_txt="${REMOTE_V4:0:18}"; else peer_txt="---"; fi
        else peer_txt="${REMOTE_PUB:0:18}"; fi

        len_name=${#pure_name}
        tag_txt="[${proto_tag}]"
        # Local IPv4: the tunnel's own IPv4 endpoint, or this host's primary IPv4 for IPv6-underlay tunnels
        local_txt="${LOCAL_PUB:0:15}"
        [ -z "$local_txt" ] && local_txt="${s_ip:0:15}"
        [ -z "$local_txt" ] && local_txt="---"
        [ -z "$peer_txt" ] && peer_txt="---"
        # row = name ➔ local ➔ remote [TYPE]; the second arrow and spaces count as 5 columns
        len_rem=$(( ${#local_txt} + 3 + ${#peer_txt} + 1 + ${#tag_txt} ))
        pad_peer=$(( 38 + extra - (len_name + len_rem) ))
        if [ "$pad_peer" -lt 0 ]; then
            # too wide: shorten the name (never below 3 chars), then clamp
            len_name=$(( len_name + pad_peer )); [ "$len_name" -lt 3 ] && len_name=3
            pure_name="${pure_name:0:len_name}"
            pad_peer=$(( 38 + extra - (len_name + len_rem) )); [ "$pad_peer" -lt 0 ] && pad_peer=0
        fi
        sp_peer=$(printf '%*s' "$pad_peer" "")

        vip_stat="OFF"; vip_col="${DIM}"
        if [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null; then
            vip_stat="+${MAX_IPS}"
            vip_col="${G}"
        fi
        vip_stat="${vip_stat:0:5}"

        live_ping="---"; live_loss=""
        if [ -f "$SECURE_TMP/.mxlan_stats_cache" ]; then
            cached_entry=$(grep "^${VX_NAME}|" "$SECURE_TMP/.mxlan_stats_cache" 2>/dev/null | head -n1)
            if [ -n "$cached_entry" ]; then
                live_ping=$(echo "$cached_entry" | cut -d'|' -f2)
                live_loss=$(echo "$cached_entry" | cut -d'|' -f3)
            fi
        fi
        live_ping="${live_ping:0:4}"

        loss_disp="---"; loss_col="${DIM}"
        if [ "$live_loss" != "---" ] && [ -n "$live_loss" ]; then
            loss_disp="${live_loss}%"
            if [ "$live_loss" -eq 0 ] 2>/dev/null; then loss_col="${G}"
            elif [ "$live_loss" -lt 30 ] 2>/dev/null; then loss_col="${Y}"
            else loss_col="${R}"; fi
        fi
        loss_disp="${loss_disp:0:4}"

        fwd_str="OFF"
        if [ "$TYPE" == "1" ]; then
            if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
            elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:2}"
            elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:2}"
            fi
        else
            fwd_str="GW"
        fi
        fwd_str="${fwd_str:0:5}"

        if_uptime=$(get_iface_uptime "$VX_NAME")
        stat_icon="●"; stat_col="${G}"
        if [ "$if_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi
        if_uptime="${if_uptime:0:6}"

        fwd_col="${DIM}"; [ "$fwd_str" != "OFF" ] && fwd_col="${C}"

        sec_disp="${TUN_SECRET:0:5}"
        [ -z "$sec_disp" ] && sec_disp="---"
        sec_disp="${sec_disp:0:5}"

        printf "  ${B}│${NC} %b%s%b ${W}%s${NC} ${DIM}➔${NC} ${Y}%s${NC} ${DIM}➔${NC} ${Y}%s${NC} ${C}%s${NC}%s ${B}│${NC} ${DIM}vIP:${NC}%b%-5.5s%b ${B}│${NC} ${DIM}Ping:${NC}${Y}%-4.4s${NC} ${B}│${NC} ${DIM}Loss:${NC}%b%-4.4s%b ${B}│${NC} ${DIM}Up:${NC}${W}%-6.6s${NC} ${B}│${NC} ${DIM}FWD:${NC}%b%-5.5s%b ${B}│${NC} ${DIM}Sec:${NC}${M}%-5.5s${NC} ${B}│${NC}\n" \
            "$stat_col" "$stat_icon" "$NC" "$pure_name" "$local_txt" "$peer_txt" "$tag_txt" "$sp_peer" "$vip_col" "$vip_stat" "$NC" "$live_ping" "$loss_col" "$loss_disp" "$NC" "$if_uptime" "$fwd_col" "$fwd_str" "$NC" "$sec_disp"

    done

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}● %-$((111+extra)).$((111+extra))s${NC}  ${B}│${NC}\n" "No active fabrics configured on this host."
    fi
    echo -e "  ${B}╰${border}╯${NC}"
}

self_update_module() {
    local src_opt custom_url dl_url tmp_file confirm
    local rel_path="tunnels/mxlan.sh"
    local cb="?t=$(date +%s)"
    
    local gh_ver="Unknown" mirror_ver="Unknown"
    [ -f "$SECURE_TMP/.mxlan_remote_ver_github" ] && gh_ver=$(tr -d '\r\n ' < "$SECURE_TMP/.mxlan_remote_ver_github")
    [ -f "$SECURE_TMP/.mxlan_remote_ver_mirror" ] && mirror_ver=$(tr -d '\r\n ' < "$SECURE_TMP/.mxlan_remote_ver_mirror")

    local gh_text="${C}Official GitHub Server${NC}"
    local mirror_text="${G}ParsPack Iranian Mirror${NC}"
    if [ "$gh_ver" != "Unknown" ]; then
        if [ "$gh_ver" != "$MODULE_VERSION" ]; then gh_text+="    ${Y}(v${MODULE_VERSION} ➔ v${gh_ver})${NC}"
        else gh_text+="    ${DIM}(v${gh_ver})${NC}"; fi
    else gh_text+="    ${DIM}(version unavailable)${NC}"; fi
    if [ "$mirror_ver" != "Unknown" ]; then
        if [ "$mirror_ver" != "$MODULE_VERSION" ]; then mirror_text+="    ${Y}(v${MODULE_VERSION} ➔ v${mirror_ver})${NC}"
        else mirror_text+="    ${DIM}(v${mirror_ver})${NC}"; fi
    else mirror_text+="    ${DIM}(version unavailable)${NC}"; fi

    draw_mxlan_header
    echo -e "\n  ${DIM}┌─[ OTA Update (MXLAN Fabric) ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ AUTOMATIC MIRRORS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${gh_text}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${mirror_text} ${DIM}(c107328.parspack.net)${NC}"
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
        
    [[ "${confirm,,}" == y || "${confirm,,}" == yes ]] || { echo -e "  ${Y}● Update cancelled.${NC}"; rm -f "$tmp_file"; return 0; }
    if ! mt_install_script "$tmp_file" "$rel_path" "$INSTALL_PATH" "$0"; then
        rm -f "$tmp_file"; echo -e "  ${R}✖ Update failed. Previous module preserved.${NC}"; return 1
    fi
    rm -f "$tmp_file"
    echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
    [ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null || true
    exec "$INSTALL_PATH" "$@"
}

merge_ports() {
    local current="$1"; local add="$2"
    local -a result=(); local IFS=','
    local -a cur_arr=($current); local -a add_arr=($add)
    local p e found out=""
    for p in "${cur_arr[@]}"; do [ -n "$p" ] && result+=("$p"); done
    for p in "${add_arr[@]}"; do
        [ -z "$p" ] && continue
        found=0
        for e in "${result[@]}"; do [ "$e" == "$p" ] && found=1 && break; done
        [ "$found" -eq 0 ] && result+=("$p")
    done
    for p in "${result[@]}"; do out+="${p},"; done
    echo "${out%,}"
}

remove_ports() {
    local current="$1"; local rem="$2"
    [ -z "$rem" ] && { echo "$current"; return; }
    local IFS=','
    local -a cur_arr=($current); local -a rem_arr=($rem)
    local out="" p r skip
    for p in "${cur_arr[@]}"; do
        [ -z "$p" ] && continue
        skip=0
        for r in "${rem_arr[@]}"; do [ "$p" == "$r" ] && skip=1 && break; done
        [ "$skip" -eq 0 ] && out+="${p},"
    done
    echo "${out%,}"
}

apply_fabric() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    local TYPE="" LOCAL_PUB="" REMOTE_PUB="" MAX_IPS="0" SYNC_KEY="" TUN_SECRET="" T_NAME="" TUN_ID="" CORE_SUBNET="" TUN_PROTO="ipv4" VNI_ID="" BR_NAME="" VX_NAME="" FWD_TCP="" FWD_UDP="" LB_MODE="0" CUSTOM_MTU="" ENCRYPT="0" LOCAL_PUB6="" REMOTE_PUB6="" FAB_PROTO="ipv4"
    source "$conf" 2>/dev/null
    [ -z "$VX_NAME" ] || [ -z "$BR_NAME" ] && return
    mx_endpoints

    local c_sub; c_sub=$(mx_core_sub)
    local local_br_ip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")

    clean_fwd_rules "$VX_NAME"; clean_mss_rules "$VX_NAME"
    [ "$ENCRYPT" != 1 ] || ip link set "$VX_NAME" down 2>/dev/null
    xfrm_clear "$VX_NAME"

    local has_local=0 eth_iface=""
    if [ "$EP_V6" -eq 1 ]; then
        [ -n "$EP_L" ] && [ -n "$(ip -6 -o addr show to "$EP_L" 2>/dev/null)" ] && has_local=1
        [ "$has_local" == "1" ] && eth_iface=$(ip -6 -o addr show to "$EP_L" 2>/dev/null | awk '{print $2; exit}')
        [ -z "$eth_iface" ] && eth_iface=$(ip -6 route get "$EP_R" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        [ -z "$eth_iface" ] && eth_iface=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    else
        [ -n "$EP_L" ] && ip -4 addr show 2>/dev/null | grep -qF "inet $EP_L/" && has_local=1
        [ "$has_local" == "1" ] && eth_iface=$(ip -o -4 addr show 2>/dev/null | awk -v t="$EP_L" '{split($4,a,"/"); if (a[1]==t) {print $2; exit}}')
        [ -z "$eth_iface" ] && eth_iface=$(ip route get "$EP_R" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        [ -z "$eth_iface" ] && eth_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    fi

    local layout="$VNI_ID|$EP_L|$EP_R|$BR_NAME|$eth_iface" layout_file="$SECURE_TMP/.mxlan_layout_$VX_NAME" keep_vx=0
    if [ -f "$layout_file" ] && [ "$(cat "$layout_file")" == "$layout" ] && ip link show "$VX_NAME" >/dev/null 2>&1; then keep_vx=1; fi
    if [ "$keep_vx" == 0 ]; then ip link del "$VX_NAME" >/dev/null 2>&1; fi

    local fab_max; fab_max=$(mx_mtu_max "$FAB_PROTO")
    local eff_mtu="$CUSTOM_MTU"
    if ! is_uint "$eff_mtu"; then eff_mtu=$fab_max; [ "$ENCRYPT" == "1" ] && eff_mtu=$((fab_max - 64)); fi
    [ "$ENCRYPT" != 1 ] || fab_max=$((fab_max-64))
    [ "$eff_mtu" -lt "$MX_MTU_MIN" ] && eff_mtu=$MX_MTU_MIN
    [ "$eff_mtu" -gt "$fab_max" ] && eff_mtu=$fab_max

    ip link show "$BR_NAME" >/dev/null 2>&1 || ip link add "$BR_NAME" type bridge || return 1
    ip link set dev "$BR_NAME" mtu "$eff_mtu" 2>/dev/null
    ip link set "$BR_NAME" up 2>/dev/null

    local -a vx_args=(type vxlan id "$VNI_ID")
    [ -n "$eth_iface" ] && vx_args+=(dev "$eth_iface")
    vx_args+=(remote "$EP_R")
    [ "$has_local" == "1" ] && vx_args+=(local "$EP_L")
    vx_args+=(dstport 4789)
    if [ "$keep_vx" == 0 ]; then ip link add "$VX_NAME" "${vx_args[@]}" || return 1; fi
    printf '%s\n' "$layout" > "$layout_file"

    ip link set dev "$VX_NAME" mtu "$eff_mtu" 2>/dev/null
    ip link set "$VX_NAME" master "$BR_NAME" 2>/dev/null
    [ "$ENCRYPT" == 1 ] || ip link set "$VX_NAME" up || return 1
    ip link set dev "$BR_NAME" mtu "$eff_mtu" 2>/dev/null
    local core_file="$SECURE_TMP/.mxlan_core_$BR_NAME" old_core
    old_core=$(cat "$core_file" 2>/dev/null || true)
    if [ -n "$old_core" ] && [ "$old_core" != "${local_br_ip}/24" ] && mt_valid_ipv4 "${old_core%/*}" && [[ "$old_core" == */24 ]]; then
        ip -4 addr del "$old_core" dev "$BR_NAME" 2>/dev/null || true
    fi
    ip addr replace "${local_br_ip}/24" dev "$BR_NAME" || return 1
    printf '%s\n' "${local_br_ip}/24" > "$core_file"
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$BR_NAME" -m comment --comment "MXLAN_MSS_$VX_NAME" -j TCPMSS --set-mss $((eff_mtu - 40)) 2>/dev/null

    if [ "$ENCRYPT" == "1" ]; then
        if ! xfrm_apply "$VX_NAME" "$TYPE" "$EP_L" "$EP_R" "$TUN_SECRET" proto udp dport 4789; then
            ip link set "$VX_NAME" down; echo "Requested encryption failed; $VX_NAME stopped." >&2; return 1
        fi
    fi

    ip link set "$VX_NAME" up || return 1

    if is_uint "$MAX_IPS" && [ "$MAX_IPS" -gt 0 ]; then
        local nip tip clash
        while read -r nip tip; do
            [ -z "$nip" ] && continue
            ip -4 addr show dev "$BR_NAME" 2>/dev/null | grep -qF "inet $nip/" && continue
            clash=$(ip -4 route show match "$nip" 2>/dev/null | grep -v '^default' | grep -v "dev $BR_NAME")
            if [ -n "$clash" ]; then echo "  [vIP] $nip skipped: overlaps existing route ($clash)" >&2; continue; fi
            ip addr add "$nip/30" dev "$BR_NAME" label "${BR_NAME}:m" 2>/dev/null
        done < <(vip_targets "$SYNC_KEY" "$MAX_IPS" "$TYPE")
    fi

    mxlan_apply_fwd "$conf"
    rebuild_guard
}

apply_all_fabrics() {
    local conf rc=0
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        apply_fabric "$conf" || rc=1
    done
    return "$rc"
}

select_fabric_interactive() {
    draw_mxlan_header
    local configs=("$CONF_DIR"/*.conf)
    [ ! -e "${configs[0]}" ] && { echo -e "\n  ${R}● No fabrics configured yet!${NC}"; sleep 1.5; return 1; }
    if [ ${#configs[@]} -eq 1 ]; then SELECTED_CONF="${configs[0]}"; return 0; fi
    echo -e "\n  ${B}╭────────────────── Select Target Fabric ───────────────────╮${NC}"
    local i
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3.3s${NC} ${C}❯${NC} ${W}%-50.50s${NC}  ${B}│${NC}\n" "$((i+1))" "$(basename "${configs[$i]}" .conf)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Fabric [1-${#configs[@]}] or 'q': ${NC}"; read -r t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r ')
    [[ "$t_idx" == "q" || -z "$t_idx" ]] && return 1
    local z
    if z=$(pick_index "$t_idx" "${#configs[@]}"); then SELECTED_CONF="${configs[$z]}"; return 0; fi
    echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1
    return 1
}

manage_port_forwarding() {
    local target_conf="$1"
    local TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET VX_NAME TUN_ID CORE_SUBNET VNI_ID TUN_PROTO LOCAL_IP6 REMOTE_IP6 FWD_TCP FWD_UDP LB_MODE FWD_TARGETS=''
    source "$target_conf" 2>/dev/null

    if [ "$TYPE" != "1" ]; then
        echo -e "\n  ${Y}● Port Forwarding & Load Balancer is only available on IRAN (Access) role!${NC}"
        sleep 2
        return
    fi

    local pf_opt add_tcp add_udp m_tcp m_udp rm_tcp rm_udp new_tcp new_udp new_lb
    while true; do
        FWD_TARGETS=''; LB_MODE=0; source "$target_conf" 2>/dev/null
        draw_mxlan_header
        echo -e "\n  ${DIM}┌─[ PORT FORWARDING MANAGER: ${W}${VX_NAME}${DIM} ]${NC}"
        echo -e "  ${DIM}│${NC} ${DIM}Current TCP:${NC} ${Y}${FWD_TCP:-None}${NC}"
        echo -e "  ${DIM}│${NC} ${DIM}Current UDP:${NC} ${C}${FWD_UDP:-None}${NC}"
        echo -e "  ${DIM}│${NC} ${DIM}Load Balancer:${NC} $([ "$LB_MODE" == "1" ] && echo -e "${G}ON${NC}" || echo -e "${DIM}OFF${NC}")"
        echo -e "  ${DIM}│${NC} ${DIM}Target IPs:${NC} ${W}$(mt_fwd_target_summary "$FWD_TARGETS" "$LB_MODE")${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add New Ports (Keep Existing)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Remove Specific Ports${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Replace All Ports (Overwrite)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Toggle Load Balancer (Selected IPs)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Select Target IP(s) (Single / Multiple / All)${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"; read -r pf_opt

        case $pf_opt in
            1)
                echo -ne "  ${C}●${NC} ${W}Add TCP Ports (e.g. 8080,9090 or 10000:10100) [Enter to skip]: ${NC}"; read -r add_tcp
                echo -ne "  ${C}●${NC} ${W}Add UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read -r add_udp
                add_tcp=$(sanitize_ports "$add_tcp" tcp)
                add_udp=$(sanitize_ports "$add_udp" udp)
                m_tcp=$(merge_ports "$FWD_TCP" "$add_tcp")
                m_udp=$(merge_ports "$FWD_UDP" "$add_udp")
                grep -v "^FWD_TCP=" "$target_conf" | grep -v "^FWD_UDP=" > "${target_conf}.tmp"
                echo "FWD_TCP=$m_tcp" >> "${target_conf}.tmp"
                echo "FWD_UDP=$m_udp" >> "${target_conf}.tmp"
                mv "${target_conf}.tmp" "$target_conf"
                FWD_TCP="$m_tcp"; FWD_UDP="$m_udp"
                if [ -z "$FWD_TARGETS" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then mt_choose_fwd_targets "$target_conf" "$(mx_core_sub).2" "$SYNC_KEY" "$MAX_IPS" "$TYPE" || true; fi
                apply_fabric "$target_conf"
                echo -e "  ${G}● Ports added. TCP: ${FWD_TCP:-None} | UDP: ${FWD_UDP:-None}${NC}"; sleep 1.8
                ;;
            2)
                echo -ne "  ${C}●${NC} ${W}Remove TCP Ports (e.g. 8080,9090) [Enter to skip]: ${NC}"; read -r rm_tcp
                echo -ne "  ${C}●${NC} ${W}Remove UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read -r rm_udp
                rm_tcp=$(echo "$rm_tcp" | tr -dc '0-9,:')
                rm_udp=$(echo "$rm_udp" | tr -dc '0-9,:')
                m_tcp=$(remove_ports "$FWD_TCP" "$rm_tcp")
                m_udp=$(remove_ports "$FWD_UDP" "$rm_udp")
                grep -v "^FWD_TCP=" "$target_conf" | grep -v "^FWD_UDP=" > "${target_conf}.tmp"
                echo "FWD_TCP=$m_tcp" >> "${target_conf}.tmp"
                echo "FWD_UDP=$m_udp" >> "${target_conf}.tmp"
                mv "${target_conf}.tmp" "$target_conf"
                FWD_TCP="$m_tcp"; FWD_UDP="$m_udp"
                apply_fabric "$target_conf"
                echo -e "  ${G}● Ports removed. TCP: ${FWD_TCP:-None} | UDP: ${FWD_UDP:-None}${NC}"; sleep 1.8
                ;;
            3)
                echo -ne "  ${C}●${NC} ${W}New TCP Ports (Current: ${Y}${FWD_TCP:-None}${W}): ${NC}"; read -r new_tcp
                echo -ne "  ${C}●${NC} ${W}New UDP Ports (Current: ${C}${FWD_UDP:-None}${W}): ${NC}"; read -r new_udp
                new_tcp=$(sanitize_ports "$new_tcp" tcp)
                new_udp=$(sanitize_ports "$new_udp" udp)
                grep -v "^FWD_TCP=" "$target_conf" | grep -v "^FWD_UDP=" > "${target_conf}.tmp"
                echo "FWD_TCP=$new_tcp" >> "${target_conf}.tmp"
                echo "FWD_UDP=$new_udp" >> "${target_conf}.tmp"
                mv "${target_conf}.tmp" "$target_conf"
                FWD_TCP="$new_tcp"; FWD_UDP="$new_udp"
                if [ -z "$FWD_TARGETS" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then mt_choose_fwd_targets "$target_conf" "$(mx_core_sub).2" "$SYNC_KEY" "$MAX_IPS" "$TYPE" || true; fi
                apply_fabric "$target_conf"
                echo -e "  ${G}● Ports replaced. TCP: ${new_tcp:-None} | UDP: ${new_udp:-None}${NC}"; sleep 1.8
                ;;
            4)
                if [ "$LB_MODE" == 1 ]; then
                    set_conf_var "$target_conf" LB_MODE 0 || continue
                    mxlan_apply_fwd "$target_conf"
                    echo -e "  ${G}● Load Balancer disabled; using the first selected IP.${NC}"
                elif mt_choose_fwd_targets "$target_conf" "$(mx_core_sub).2" "$SYNC_KEY" "$MAX_IPS" "$TYPE"; then
                    mxlan_apply_fwd "$target_conf"
                fi
                sleep 1.5
                ;;
            5)
                if mt_choose_fwd_targets "$target_conf" "$(mx_core_sub).2" "$SYNC_KEY" "$MAX_IPS" "$TYPE"; then mxlan_apply_fwd "$target_conf"; fi
                ;;
            0) break ;;
        esac
    done
}

show_fabric_details() {
    draw_mxlan_header
    local configs=("$CONF_DIR"/*.conf)
    [ ! -e "${configs[0]}" ] && { echo -e "\n  ${R}● No fabrics configured yet!${NC}"; sleep 1.5; return; }

    echo -e "\n  ${Y}● Tunnels Info And Specs:${NC}"
    local conf TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET VNI_ID BR_NAME VX_NAME CORE_SUBNET LOCAL_PUB6 REMOTE_PUB6 FAB_PROTO
    local c_sub lip tip t_role t_sec left_p right_p pad sp l1 r1 pad1 sp1 l2 r2 pad2 sp2 l3 pad3 sp3 l4 pad4 sp4
    for conf in "${configs[@]}"; do
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; CORE_SUBNET=""; LOCAL_PUB6=""; REMOTE_PUB6=""; FAB_PROTO="ipv4"; source "$conf" 2>/dev/null
        mx_endpoints
        c_sub="$(mx_core_sub)"
        lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access)" || echo "KHAREJ (Gateway)")
        t_sec="${TUN_SECRET:-[ NOT SET ]}"

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        left_p="▼ Fabric: ${VX_NAME:0:20} (${BR_NAME:0:20})"; right_p="Role: $t_role"
        pad=$(( 90 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"

        l1="Master Token : ${t_sec:0:25}"; r1="Network VNI : ${VNI_ID:0:15}"
        pad1=$(( 90 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Master Token :${NC} ${W}${t_sec:0:25}${NC}${sp1}${DIM}Network VNI :${NC} ${Y}${VNI_ID:0:15}${NC} ${B}│${NC}"

        local sync_disp="${SYNC_KEY:-Same As Token}"; sync_disp="${sync_disp:0:25}"
        l2="vIP Sync Key : ${sync_disp}"; r2="Virtual IPs : ${MAX_IPS} active"
        pad2=$(( 90 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}vIP Sync Key :${NC} ${W}${sync_disp}${NC}${sp2}${DIM}Virtual IPs :${NC} ${G}${MAX_IPS} active${NC} ${B}│${NC}"

        l3="Public IPs   : ${EP_L:0:39} -> ${EP_R:0:39}"
        pad3=$(( 90 - ${#l3} )); [ "$pad3" -lt 0 ] && pad3=0; sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${DIM}Public IPs   :${NC} ${W}${EP_L:0:39}${NC} ${DIM}->${NC} ${W}${EP_R:0:39}${NC}${sp3} ${B}│${NC}"
        local l5="Underlay     : $(mx_proto_tag "$FAB_PROTO") ($([ "$FAB_PROTO" == "ipv6" ] && echo IPv6 || echo IPv4)) | MTU limit $(mx_mtu_max "$FAB_PROTO")" pad5 sp5
        pad5=$(( 90 - ${#l5} )); [ "$pad5" -lt 0 ] && pad5=0; sp5=$(printf '%*s' "$pad5" "")
        echo -e "  ${B}│${NC} ${DIM}Underlay     :${NC} ${C}$(mx_proto_tag "$FAB_PROTO")${NC} ${DIM}($([ "$FAB_PROTO" == "ipv6" ] && echo IPv6 || echo IPv4)) | MTU limit $(mx_mtu_max "$FAB_PROTO")${NC}${sp5} ${B}│${NC}"

        l4="Core Subnet  : ${c_sub}.x (${lip} -> ${tip})"
        pad4=$(( 90 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Core Subnet  :${NC} ${G}${c_sub}.x${NC} ${DIM}(${lip} -> ${tip})${NC}${sp4} ${B}│${NC}"

        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯\n"
    done
    if [ "${1:-}" != --no-pause ]; then
        echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r dummy
    fi
}

show_mxlan_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    local conf TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY CORE_SUBNET VNI_ID BR_NAME VX_NAME FWD_TCP FWD_UDP LB_MODE LOCAL_PUB6 REMOTE_PUB6 FAB_PROTO
    local v_ips title_txt raw_l1 pad1 sp1 eval_l1 disp_tcp disp_udp lb_txt raw_l2 pad2 sp2 lb_stat eval_l2
    local c_sub main_tip main_lip ping_res lat lat_raw lat_color stat_icon stat_text stat_color m_icon total_v idx lip base_ip last tip v_icon

    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; CORE_SUBNET=""; VNI_ID=""; BR_NAME=""; VX_NAME=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; LOCAL_PUB6=""; REMOTE_PUB6=""; FAB_PROTO="ipv4"; source "$conf" 2>/dev/null
        mx_endpoints
        mapfile -t v_ips < <(ip -4 addr show dev "$BR_NAME" label "${BR_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

        title_txt="${VX_NAME}/${BR_NAME}"
        raw_l1=" ▼ ${title_txt} | PUB: ${EP_L} -> ${EP_R}"
        pad1=$(( 92 - ${#raw_l1} )); [ "$pad1" -lt 0 ] && pad1=0; sp1=$(printf '%*s' "$pad1" "")
        eval_l1=$(printf " %b▼ %s%b ${DIM}| PUB: ${W}%s ${DIM}→${W} %s${NC}" "${M}" "${title_txt}" "${NC}" "${EP_L}" "${EP_R}")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC}${eval_l1}${sp1}${B}│${NC}"

        if [ "$TYPE" == "1" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then
            disp_tcp="${FWD_TCP:-0}"; [ ${#disp_tcp} -gt 30 ] && disp_tcp="${disp_tcp:0:27}..."
            disp_udp="${FWD_UDP:-0}"; [ ${#disp_udp} -gt 30 ] && disp_udp="${disp_udp:0:27}..."
            lb_txt="OFF"; [ "$LB_MODE" == "1" ] && lb_txt="ON"
            raw_l2="   ↳ NAT: T:[${disp_tcp}] U:[${disp_udp}] LB:[${lb_txt}]"
            pad2=$(( 92 - ${#raw_l2} )); [ "$pad2" -lt 0 ] && pad2=0; sp2=$(printf '%*s' "$pad2" "")
            lb_stat=$([ "$LB_MODE" == "1" ] && echo -e "${G}ON${NC}" || echo -e "${DIM}OFF${NC}")
            eval_l2="   ${DIM}↳ NAT:${NC} ${Y}T:[${disp_tcp}]${NC} ${C}U:[${disp_udp}]${NC} ${DIM}LB:[${lb_stat}${DIM}]${NC}"
            echo -e "  ${B}│${NC}${eval_l2}${sp2}${B}│${NC}"
        fi

        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} ${DIM}%-12.12s${NC} ${B}│${NC} ${DIM}%-12.12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        c_sub="$(mx_core_sub)"
        main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        main_lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")

        ping_res=$(timeout 2 ping -c 1 -W 1 "$main_tip" 2>/dev/null)
        if echo "$ping_res" | grep -q "time="; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
            lat_int=$(awk -v v="$lat" 'BEGIN {printf "%.0f", v}')
            lat_raw="${lat_int}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi

        m_icon="├─"; [ ${#v_ips[@]} -eq 0 ] && m_icon="└─"
        main_lip="${main_lip:0:18}"; main_tip="${main_tip:0:18}"
        printf "  ${B}│${NC} ${W}%s %-15.15s${NC} ${B}│${NC} ${W}%-18.18s${NC} ${B}│${NC} ${W}%-18.18s${NC} ${B}│${NC} %b%-12.12s%b ${B}│${NC} %b%s %-10.10s%b ${B}│${NC}\n" "${m_icon}" "Bridge IP" "$main_lip" "$main_tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"

        total_v=${#v_ips[@]}
        for ((idx=0; idx<total_v; idx++)); do
            lip="${v_ips[$idx]}"; base_ip=$(echo "$lip" | cut -d'.' -f1-3); last=$(echo "$lip" | cut -d'.' -f4); tip="$base_ip.$([ "$last" == "1" ] && echo "2" || echo "1")"
            ping_res=$(timeout 2 ping -c 1 -W 1 "$tip" 2>/dev/null)
            if echo "$ping_res" | grep -q "time="; then
                lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
                lat_int=$(awk -v v="$lat" 'BEGIN {printf "%.0f", v}')
                lat_raw="${lat_int}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
            else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
            v_icon="│  ├─"; [ $idx -eq $((total_v - 1)) ] && v_icon="│  └─"
            lip="${lip:0:18}"; tip="${tip:0:18}"
            printf "  ${B}│${NC} ${DIM}%s %-12.12s${NC} ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} %b%-12.12s%b ${B}│${NC} %b%s %-10.10s%b ${B}│${NC}\n" "${v_icon}" "vIP" "$lip" "$tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        done
        echo -e "  ${B}╰────────────────────┴────────────────────┴────────────────────┴──────────────┴──────────────╯${NC}\n"
    done
}

uninstall_mxlan() {
    draw_mxlan_header
    echo -e "\n  ${R}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${R}│${NC}   ${R}⚠ WARNING: COMPLETE PURGE & UNINSTALLATION OF MXLAN${NC}                     ${R}│${NC}"
    echo -e "  ${R}│${NC}   This will permanently stop and delete:                                   ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All active VXLAN interfaces and Bridge attachments                    ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All configurations & metadata in /etc/mgre/vxlan                       ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All iptables NAT, FORWARD, and Load Balancer rules                     ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● MXLAN systemd service & executable wrapper                             ${R}│${NC}"
    echo -e "  ${R}╰────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    
    local confirm conf VX_NAME BR_NAME
    echo -ne "  ${Y}Are you sure you want to proceed? Type '${R}yes${Y}' to confirm: ${NC}"; read -r confirm
    confirm=$(echo "$confirm" | tr -d '\r ')
    
    if [ "$confirm" != "yes" ]; then
        echo -e "  ${G}● Uninstallation cancelled.${NC}"; sleep 1.5; return
    fi

    echo -e "\n  ${DIM}● [1/4] Stopping services and removing VXLAN interfaces...${NC}"
    systemctl stop mxlan.service 2>/dev/null
    systemctl disable mxlan.service 2>/dev/null

    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        teardown_fabric "$conf"
    done
    watchdog_disable
    rm -f "$GUARD_FLAG"; rebuild_guard

    echo -e "  ${DIM}● [2/4] Removing systemd unit files...${NC}"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null

    echo -e "  ${DIM}● [3/4] Deleting configurations & temporary files...${NC}"
    rm -rf "$CONF_DIR" "$SECURE_TMP/.mxlan"* "$WD_LOG"

    echo -e "  ${DIM}● [4/4] Removing mxlan executable script...${NC}"
    rm -f "$INSTALL_PATH" 2>/dev/null
    [ -f "$0" ] && rm -f "$0" 2>/dev/null

    echo -e "\n  ${G}✔ MXLAN ecosystem has been completely eradicated.${NC}\n"
    exit 0
}

setup_service() {
    local tmp_srv="$SECURE_TMP/mxlan_tpl.service"
    cat <<EOF > "$tmp_srv"
[Unit]
Description=MXLAN Multi-Fabric Service
Wants=network-online.target
After=network-online.target
[Service]
ExecStart=/usr/bin/mxlan --apply
Type=oneshot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    if ! cmp -s "$tmp_srv" "$SERVICE_FILE" 2>/dev/null; then
        mv -f "$tmp_srv" "$SERVICE_FILE"
        systemctl daemon-reload && systemctl enable mxlan.service >/dev/null 2>&1
    else
        rm -f "$tmp_srv"
    fi
}


# ======================================================================
# [ v-next ] MXLAN specific engine pieces
# ======================================================================
clean_fwd_rules() {
    local t="$1"; [ -z "$t" ] && return
    ipt_delete_tagged nat PREROUTING "MXLAN_FWD_${t}"
    ipt_delete_tagged nat POSTROUTING "MXLAN_FWD_${t}"
    ipt_delete_tagged filter FORWARD "MXLAN_FWD_${t}"
}
clean_mss_rules() {
    local t="$1"; [ -z "$t" ] && return
    ipt_delete_tagged mangle FORWARD "MXLAN_MSS_${t}"
}

mxlan_apply_fwd() {
    local conf="$1"
    local TYPE="" VX_NAME="" CORE_SUBNET="" VNI_ID="" BR_NAME="" MAX_IPS="0" SYNC_KEY="" FWD_TCP="" FWD_UDP="" LB_MODE="0" FWD_TARGETS=''
    source "$conf" 2>/dev/null
    clean_fwd_rules "$VX_NAME"
    [ "$TYPE" == "1" ] || return 0
    [ -n "$FWD_TCP" ] && FWD_TCP=$(sanitize_ports "$FWD_TCP" tcp 2>/dev/null)
    [ -z "$FWD_TCP" ] && [ -z "$FWD_UDP" ] && return 0
    local pool
    pool=$(mt_fwd_selected "$FWD_TARGETS" "$LB_MODE" "$(mx_core_sub).2" "$SYNC_KEY" "$MAX_IPS" "$TYPE") || { echo "No selected forwarding targets remain for $VX_NAME. Select Target IP(s) again." >&2; return 1; }
    local -a targets=()
    mapfile -t targets <<< "$pool"
    build_fwd_rules "MXLAN_FWD_$VX_NAME" "$BR_NAME" "$FWD_TCP" "$FWD_UDP" "$LB_MODE" "$SECURE_TMP/.mxlan_lbdead_${VX_NAME}" "${targets[@]}"
}

teardown_fabric() {
    local conf="$1" VX_NAME="" BR_NAME=""
    source "$conf" 2>/dev/null
    [ -z "$VX_NAME" ] && return
    clean_fwd_rules "$VX_NAME"; clean_mss_rules "$VX_NAME"; xfrm_clear "$VX_NAME"
    ip link del "$VX_NAME" >/dev/null 2>&1; [ -n "$BR_NAME" ] && ip link del "$BR_NAME" >/dev/null 2>&1
    rm -f "$SECURE_TMP/.mxlan_lbdead_${VX_NAME}"
}

rebuild_guard() {
    ipt_delete_tagged filter INPUT "MXLAN_GUARD_HOOK"
    IPT_BIN=ip6tables ipt_delete_tagged filter INPUT "MXLAN_GUARD_HOOK"
    iptables -F MXLAN_GUARD 2>/dev/null
    ip6tables -F MXLAN6_GUARD 2>/dev/null
    if [ ! -f "$GUARD_FLAG" ]; then
        iptables -X MXLAN_GUARD 2>/dev/null
        ip6tables -X MXLAN6_GUARD 2>/dev/null
        return 0
    fi
    local conf REMOTE_PUB REMOTE_PUB6 LOCAL_PUB LOCAL_PUB6 FAB_PROTO peers4=0 peers6=0
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        REMOTE_PUB=""; REMOTE_PUB6=""; LOCAL_PUB=""; LOCAL_PUB6=""; FAB_PROTO="ipv4"; source "$conf" 2>/dev/null
        if mx_is_v6; then
            if is_ipv6 "$REMOTE_PUB6"; then
                [ "$peers6" -eq 0 ] && ip6tables -N MXLAN6_GUARD 2>/dev/null
                ip6tables -A MXLAN6_GUARD -s "$REMOTE_PUB6" -j ACCEPT; peers6=1
            fi
        else
            if is_ipv4 "$REMOTE_PUB"; then
                [ "$peers4" -eq 0 ] && iptables -N MXLAN_GUARD 2>/dev/null
                iptables -A MXLAN_GUARD -s "$REMOTE_PUB" -j ACCEPT; peers4=1
            fi
        fi
    done
    # Hooks exist only for the IP families actually used, so unrelated VXLAN of the other family stays untouched
    if [ "$peers4" -eq 1 ]; then
        iptables -A MXLAN_GUARD -j DROP
        iptables -I INPUT 1 -p udp --dport 4789 -m comment --comment "MXLAN_GUARD_HOOK" -j MXLAN_GUARD
    else
        iptables -X MXLAN_GUARD 2>/dev/null
    fi
    if [ "$peers6" -eq 1 ]; then
        ip6tables -A MXLAN6_GUARD -j DROP
        ip6tables -I INPUT 1 -p udp --dport 4789 -m comment --comment "MXLAN_GUARD_HOOK" -j MXLAN6_GUARD
    else
        ip6tables -X MXLAN6_GUARD 2>/dev/null
    fi
}

mxlan_watchdog() {
    local conf TYPE VX_NAME CORE_SUBNET VNI_ID MAX_IPS SYNC_KEY LB_MODE FWD_TCP FWD_UDP FWD_TARGETS pool tip pair t deadf newdead
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; VX_NAME=""; CORE_SUBNET=""; VNI_ID=""; MAX_IPS="0"; SYNC_KEY=""; LB_MODE="0"; FWD_TCP=""; FWD_UDP=""; FWD_TARGETS=''
        source "$conf" 2>/dev/null
        [ -z "$VX_NAME" ] && continue
        tip=$([ "$TYPE" == "1" ] && echo "$(mx_core_sub).2" || echo "$(mx_core_sub).1")
        if [ ! -d "/sys/class/net/$VX_NAME" ]; then
            wd_log "$VX_NAME: interface missing, re-applying"; apply_fabric "$conf"; continue
        fi
        local failf="$SECURE_TMP/.mxlan_wdfail_${VX_NAME}" fails
        if ! ping -c 3 -i 0.3 -W 2 "$tip" >/dev/null 2>&1; then
            fails=$(( $(cat "$failf" 2>/dev/null || echo 0) + 1 )); echo "$fails" > "$failf"
            if [ "$fails" -ge 2 ]; then
                wd_log "$VX_NAME: peer $tip unreachable ${fails}x, re-applying fabric"; apply_fabric "$conf"; echo 0 > "$failf"
            fi
            continue
        fi
        echo 0 > "$failf"
        if [ "$TYPE" == "1" ] && [ "$LB_MODE" == "1" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then
            deadf="$SECURE_TMP/.mxlan_lbdead_${VX_NAME}"; newdead=""
            pool=$(mt_fwd_selected "$FWD_TARGETS" "$LB_MODE" "$(mx_core_sub).2" "$SYNC_KEY" "$MAX_IPS" "$TYPE") || pool=''
            while read -r t; do
                [ -z "$t" ] && continue
                ping -c 2 -i 0.3 -W 1 "$t" >/dev/null 2>&1 || newdead+="$t"$'\n'
            done <<< "$pool"
            if [ "$(printf '%s' "$newdead")" != "$(cat "$deadf" 2>/dev/null)" ]; then
                printf '%s' "$newdead" > "$deadf"
                wd_log "$VX_NAME: LB pool changed, dead vIPs: $(echo "$newdead" | tr '\n' ' ')"
                mxlan_apply_fwd "$conf"
            fi
        fi
    done
}

mxlan_status_cli() {
    local conf TYPE VX_NAME REMOTE_PUB REMOTE_PUB6 LOCAL_PUB LOCAL_PUB6 FAB_PROTO CORE_SUBNET VNI_ID ENCRYPT tip st lat
    printf "%-16s %-28s %-6s %-8s %-8s %s\n" "FABRIC" "PEER" "ROLE" "LINK" "PING" "ENC"
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; VX_NAME=""; REMOTE_PUB=""; REMOTE_PUB6=""; LOCAL_PUB=""; LOCAL_PUB6=""; FAB_PROTO="ipv4"; CORE_SUBNET=""; VNI_ID=""; ENCRYPT="0"; source "$conf" 2>/dev/null
        mx_endpoints
        tip=$([ "$TYPE" == "1" ] && echo "$(mx_core_sub).2" || echo "$(mx_core_sub).1")
        st=$([ -d "/sys/class/net/$VX_NAME" ] && echo UP || echo DOWN)
        lat=$(ping -c1 -W1 "$tip" 2>/dev/null | grep -oP 'time=\K[0-9.]+'); lat="${lat:+${lat}ms}"
        printf "%-16s %-28s %-6s %-8s %-8s %s\n" "$VX_NAME" "${EP_R:0:28}" "$([ "$TYPE" == "1" ] && echo IR || echo KH)" "$st" "${lat:----}" "$([ "$ENCRYPT" == "1" ] && echo ON || echo OFF)"
    done
}

# ---------------- ADVANCED MENU ACTIONS ----------------
menu_encrypt() {
    select_fabric_interactive || return
    local ENCRYPT="0" VX_NAME="" TYPE="" LOCAL_PUB="" REMOTE_PUB="" LOCAL_PUB6="" REMOTE_PUB6="" FAB_PROTO="ipv4" TUN_SECRET=""; source "$SELECTED_CONF" 2>/dev/null
    draw_mxlan_header
    echo -e "\n  ${DIM}┌─[ IPsec ESP ENCRYPTION: ${W}${VX_NAME}${DIM} ]${NC}"
    echo -e "  ${DIM}│${NC} Status : $([ "$ENCRYPT" == "1" ] && echo -e "${G}ENCRYPTED (AES-256-CBC + HMAC-SHA256)${NC}" || echo -e "${R}PLAINTEXT VXLAN${NC}")"
    echo -e "  ${DIM}│${NC} ${Y}Both peers MUST run the same mode with the same Master Token, or the link drops.${NC}"
    echo -e "  ${DIM}│${NC} ${DIM}Auto MTU shrinks by 64 bytes for ESP overhead.${NC}"
    echo -e "  ${DIM}└─${NC}"
    echo -ne "  ${C}●${NC} ${W}Turn encryption $([ "$ENCRYPT" == "1" ] && echo OFF || echo ON)? (y/n): ${NC}"; read -r ans
    [[ "${ans,,}" == "y" ]] || return
    local nv="1"; [ "$ENCRYPT" == "1" ] && nv="0"
    set_conf_var "$SELECTED_CONF" ENCRYPT "$nv"
    apply_fabric "$SELECTED_CONF"
    if [ "$nv" == "1" ] && [ ! -f "$(xfrm_state_file "$VX_NAME")" ]; then
        echo -e "  ${R}✖ Kernel rejected IPsec setup (missing xfrm/esp modules or local IP not on host). Reverted.${NC}"
        set_conf_var "$SELECTED_CONF" ENCRYPT 0; apply_fabric "$SELECTED_CONF"; sleep 2.5; return
    fi
    echo -e "  ${G}✔ Encryption is now $([ "$nv" == "1" ] && echo ON || echo OFF). Do the same on the peer server.${NC}"; sleep 2
}

menu_guard() {
    draw_mxlan_header
    local on=0; [ -f "$GUARD_FLAG" ] && on=1
    echo -e "\n  ${DIM}┌─[ FIREWALL GUARD (Anti-Spoof / Anti-Injection) ]${NC}"
    echo -e "  ${DIM}│${NC} Status : $([ "$on" == "1" ] && echo -e "${G}ON${NC}" || echo -e "${R}OFF${NC}")"
    echo -e "  ${DIM}│${NC} Accepts VXLAN (UDP 4789, IPv4 + IPv6) ONLY from configured peer IPs: stops L2 frame injection."
    echo -e "  ${DIM}│${NC} ${Y}Note: blocks any other VXLAN endpoints on this host not managed by MXLAN.${NC}"
    echo -e "  ${DIM}└─${NC}"
    echo -ne "  ${C}●${NC} ${W}Turn Guard $([ "$on" == "1" ] && echo OFF || echo ON)? (y/n): ${NC}"; read -r ans
    [[ "${ans,,}" == "y" ]] || return
    if [ "$on" == "1" ]; then rm -f "$GUARD_FLAG"; else mkdir -p "$MT_ROOT_CONF"; touch "$GUARD_FLAG"; fi
    rebuild_guard
    echo -e "  ${G}✔ Firewall Guard $([ "$on" == "1" ] && echo disabled || echo enabled).${NC}"; sleep 1.8
}





menu_manual_mtu() {
    select_fabric_interactive || return 0
    local VX_NAME="" FAB_PROTO="ipv4" CUSTOM_MTU="" ENCRYPT="0" best="" fab_max act
    source "$SELECTED_CONF" 2>/dev/null
    fab_max=$(mx_mtu_max "$FAB_PROTO")
    [ "$ENCRYPT" != 1 ] || fab_max=$((fab_max - 64))
    draw_mxlan_header
    act=$(cat "/sys/class/net/$VX_NAME/mtu" 2>/dev/null)
    echo -e "\n  ${DIM}┌─[ MTU & MSS: ${W}${VX_NAME}${DIM} ]${NC}"
    echo -e "  ${DIM}├─${NC} Live MTU: ${Y}${act:-N/A}${NC}   Saved: ${W}${CUSTOM_MTU:-Default}${NC}"
    echo -ne "  ${C}●${NC} ${W}MTU (${MX_MTU_MIN}-${fab_max}) [Enter: default | q: cancel]: ${NC}"
    read -r best || return 0
    best="${best//$'\r'/}"
    case "$best" in q|Q) return 0;; esac
    if [ -n "$best" ]; then
        if ! [[ "$best" =~ ^[0-9]{1,5}$ ]]; then
            echo -e "  ${R}✖ Invalid MTU.${NC}"; sleep 2; return 0
        fi
        best=$((10#$best))
        if [ "$best" -lt "$MX_MTU_MIN" ] || [ "$best" -gt "$fab_max" ]; then
            echo -e "  ${R}✖ Out of range.${NC}"; sleep 2; return 0
        fi
    fi
    set_conf_var "$SELECTED_CONF" CUSTOM_MTU "$best" || return 1
    apply_fabric "$SELECTED_CONF" || return 1
    echo -e "  ${G}✔ MTU saved: ${best:-Default} (MSS clamp follows automatically).${NC}"
    sleep 2
}

show_traffic_monitor() {
    local -A prx ptx
    local conf VX_NAME rx tx drx dtx first=1 k
    while true; do
        draw_mxlan_header
        echo -e "\n  ${C}Live Traffic (1s refresh | 'q' to exit)${NC}\n"
        printf "  ${DIM}%-16s %-14s %-14s %-12s %-12s${NC}\n" "TUNNEL" "RX RATE" "TX RATE" "RX TOTAL" "TX TOTAL"
        for conf in "$CONF_DIR"/*.conf; do
            [ -f "$conf" ] || continue
            VX_NAME=""; source "$conf" 2>/dev/null
            [ -d "/sys/class/net/$VX_NAME" ] || { printf "  %-16s ${R}%s${NC}\n" "$VX_NAME" "DOWN"; continue; }
            rx=$(cat "/sys/class/net/$VX_NAME/statistics/rx_bytes"); tx=$(cat "/sys/class/net/$VX_NAME/statistics/tx_bytes")
            drx=$(( rx - ${prx[$VX_NAME]:-$rx} )); dtx=$(( tx - ${ptx[$VX_NAME]:-$tx} ))
            prx[$VX_NAME]=$rx; ptx[$VX_NAME]=$tx
            printf "  ${W}%-16s${NC} ${G}%-14s${NC} ${Y}%-14s${NC} %-12s %-12s\n" "$VX_NAME" "$(human_rate $drx)" "$(human_rate $dtx)" "$(human_bytes $rx)" "$(human_bytes $tx)"
        done
        mt_monitor_wait 1 || break
    done
}

restore_validated_backup() {
    local archive="$1" stage conf rollback failed=0
    stage=$(mt_stage_backup "$archive" "vxlan") || return 1
    # Validate tunnel identity/role/endpoints before stopping any live interface.
    for conf in "$stage/vxlan"/*.conf; do
        [ -f "$conf" ] || continue
        if ! mt_validate_tunnel_conf "$conf" vxlan; then rm -rf "$stage"; return 1; fi
    done
    backup_configs >/dev/null || { rm -rf "$stage"; return 1; }
    rollback=$(mktemp -d "${CONF_DIR}.rollback.XXXXXX") || { rm -rf "$stage"; return 1; }
    cp -a "$CONF_DIR/." "$rollback/" || { rm -rf "$stage" "$rollback"; return 1; }
    for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && teardown_fabric "$conf"; done
    rm -f "$CONF_DIR"/*.conf
    cp -a "$stage/vxlan/." "$CONF_DIR/" || failed=1
    [ "$failed" != 0 ] || apply_all_fabrics || failed=1
    if [ "$failed" != 0 ]; then
        for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && teardown_fabric "$conf"; done
        rm -f "$CONF_DIR"/*.conf
        cp -a "$rollback/." "$CONF_DIR/"
        apply_all_fabrics || echo 'Previous configs restored; some interfaces require attention.' >&2
    fi
    rm -rf "$stage" "$rollback"
    return "$failed"
}

menu_backup_restore() {
    draw_mxlan_header
    echo -e "\n  ${DIM}┌─[ BACKUP & RESTORE ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Create Backup${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Restore From Backup${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} Back"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read -r ans
    if [ "$ans" == "1" ]; then
        local f; f=$(backup_configs)
        [ -n "$f" ] && echo -e "  ${G}✔ Saved: ${f}${NC}" || echo -e "  ${R}✖ Backup failed.${NC}"; sleep 2
    elif [ "$ans" == "2" ]; then
        local -a bks=("$BACKUP_DIR"/mxlan-*.tgz)
        [ -e "${bks[0]}" ] || { echo -e "  ${R}● No backups found.${NC}"; sleep 1.5; return; }
        local i; for i in "${!bks[@]}"; do echo -e "  ${Y}$((i+1))${NC} ❯ $(basename "${bks[$i]}")"; done
        echo -ne "  ${C}●${NC} ${W}Pick backup: ${NC}"; read -r sel
        local idx; idx=$(pick_index "$sel" "${#bks[@]}") || return
        echo -ne "  ${R}● Current tunnels will be replaced. Type 'yes': ${NC}"; read -r c; [ "$c" == "yes" ] || return
        restore_validated_backup "${bks[$idx]}" || { echo 'Restore failed; previous configuration retained.' >&2; return 1; }
        echo -e "  ${G}✔ Restored and applied.${NC}"; sleep 2
    fi
}
# ======================================================================

case "$1" in
    --teardown-all) for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && teardown_fabric "$conf"; done; exit 0 ;;
    --apply)    apply_all_fabrics; exit $? ;;
    --apply-one) [[ "${2:-}" =~ ^[A-Za-z0-9_.-]+$ ]] && [ -f "$CONF_DIR/$2.conf" ] || exit 1; apply_fabric "$CONF_DIR/$2.conf"; exit $? ;;
    --watchdog) mxlan_watchdog; exit 0 ;;
    --status|--list) mxlan_status_cli; exit 0 ;;
    --backup)   f=$(backup_configs); [ -n "$f" ] && echo "Backup: $f" || { echo "Backup failed"; exit 1; }; exit 0 ;;
    --guard-on)  mkdir -p "$MT_ROOT_CONF"; touch "$GUARD_FLAG"; rebuild_guard; echo "Guard ON"; exit 0 ;;
    --guard-off) rm -f "$GUARD_FLAG"; rebuild_guard; echo "Guard OFF"; exit 0 ;;
    --help|-h)
        echo "mxlan v$MODULE_VERSION"
        echo "  mxlan                interactive menu"
        echo "  mxlan --apply-one NAME   re-apply one configured tunnel"
        echo "  mxlan --apply        re-apply all fabrics (used by systemd)"
        echo "  mxlan --status       print fabric status table"
        echo "  mxlan --watchdog     run one watchdog cycle"
        echo "  mxlan --backup       backup configs to $BACKUP_DIR"
        echo "  mxlan --guard-on|--guard-off  toggle firewall guard"
        exit 0 ;;
esac

[ ! -f "$SERVICE_FILE" ] && setup_service

update_available_badge() {
    local remote_v=""
    [ -f "$SECURE_TMP/.mxlan_remote_ver" ] && remote_v=$(tr -d '\r\n ' < "$SECURE_TMP/.mxlan_remote_ver")
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && mt_is_newer_version "$remote_v" "$MODULE_VERSION"; then
        printf '  %b' "${Y}(Update Available: v${remote_v})${NC}"
    fi
}

show_tunnels_info() {
    mt_tunnels_info_menu vxlan draw_mxlan_header show_fabric_details show_traffic_monitor
}

show_live_monitor() {
    while true; do
        draw_mxlan_header
        show_mxlan_monitor
        mt_monitor_wait 2 || return 0
    done
}

# BEGIN MTUNNEL WORKSPACE V13
# Embedded in each module: no external library or sourced setup-link code.
mt_ask() { # styled prompt: mt_ask VAR "text"
    local __var="$1"; shift
    printf '  %b●%b %b%s%b ' "$C" "$NC" "$W" "$*" "$NC"
    read -r "$__var"
}
mt_workspace_screen() { "$MT_HEADER"; }
# Keep the stable palette, tree layout and aligned one/two-digit option numbers.
mt_workspace_row() {
    printf '  %b├─%b %b%-2s%b%b❯%b %b%s%b%b\n' \
        "$DIM" "$NC" "$W" "$1" "$NC" "$DIM" "$NC" "${3:-$C}" "$2" "$NC" "${4:-}"
}
mt_workspace_group() {
    if [ "${2:-}" = first ]; then
        printf '\n  %b┌─[ %s ]%b\n' "$DIM" "$1" "$NC"
    else
        printf '  %b│%b\n  %b├─[ %s ]%b\n' "$DIM" "$NC" "$DIM" "$1" "$NC"
    fi
    printf '  %b│%b\n' "$DIM" "$NC"
}
mt_workspace_footer() {
    printf '  %b│%b\n  %b└─%b %b0%b %b❯%b %b%s%b\n\n' \
        "$DIM" "$NC" "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$DIM" "$1" "$NC"
}
mt_workspace_menu() { # title, id|label|action|color ...; sets MT_ACTION
    local title="$1" entry id label action color choice; shift
    while true; do
        mt_workspace_screen
        mt_workspace_group "$title" first
        for entry in "$@"; do
            IFS='|' read -r id label action color <<< "$entry"
            mt_workspace_row "$id" "$label" "$color"
        done
        mt_workspace_footer 'Go Back'
        printf '  %bSelect ❯❯ %b' "$C" "$NC"
        read -r choice || return 1
        case "$choice" in 0|q|Q) return 1;; esac
        for entry in "$@"; do
            IFS='|' read -r id label action color <<< "$entry"
            if [ "$choice" = "$id" ]; then MT_ACTION="$action"; return 0; fi
        done
        echo -e "  ${R}✖ Invalid selection.${NC}"
    done
}
mt_workspace_pause() {
    printf '  %bPress Enter to continue...%b' "$DIM" "$NC"
    read -r _ || true
}
mt_link_encode() {
    mt_link_validate || return 1
    local raw encoded checksum key
    raw=$(for key in "${!MT_LINK_DATA[@]}"; do
            [ "$key" = SYNC_KEY ] && [ "${MT_LINK_DATA[SYNC_KEY]}" = "${MT_LINK_DATA[TUN_SECRET]:-}" ] && continue
            printf '%s=%s\n' "$key" "${MT_LINK_DATA[$key]}"
          done | LC_ALL=C sort)
    encoded=$(printf '%s\n' "$raw" | gzip -9n | base64 -w0 | tr '+/' '-_' | tr -d '=')
    checksum=$(printf '%s' "2/$MT_KIND/$encoded" | sha256sum); checksum="${checksum:0:16}"
    printf 'mtunnel://2/%s/%s.%s\n' "$MT_KIND" "$encoded" "$checksum"
}
mt_link_decode() {
    local link="$1" rest kind encoded checksum actual raw padded canonical key val ver
    link="${link//$'\r'/}"
    link="${link#"${link%%[![:space:]]*}"}"; link="${link%"${link##*[![:space:]]}"}"
    declare -gA MT_LINK_DATA=()
    [ "${#link}" -le 32768 ] || return 1
    case "$link" in
        mtunnel://1/*) ver=1; rest="${link#mtunnel://1/}";;
        mtunnel://2/*) ver=2; rest="${link#mtunnel://2/}";;
        *) return 1;;
    esac
    kind="${rest%%/*}"; rest="${rest#*/}"
    [[ "$kind" =~ ^(gre|vxlan|backhaul|rathole|paqet)$ ]] || return 1
    [ "$kind" = "$MT_KIND" ] || { echo "This link is for $kind, not $MT_KIND." >&2; return 1; }
    encoded="${rest%.*}"; checksum="${rest##*.}"
    [[ "$encoded" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    if [ "$ver" = 1 ]; then
        [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || return 1
        actual=$(printf '%s' "1/$kind/$encoded" | sha256sum); actual="${actual%% *}"
    else
        [[ "$checksum" =~ ^[a-f0-9]{16}$ ]] || return 1
        actual=$(printf '%s' "2/$kind/$encoded" | sha256sum); actual="${actual:0:16}"
    fi
    [ "$actual" = "$checksum" ] || { echo 'Setup link checksum failed.' >&2; return 1; }
    padded=$(printf '%s' "$encoded" | tr '_-' '/+'); case $((${#padded}%4)) in 2) padded+='==';; 3) padded+='=';; 1) return 1;; esac
    if [ "$ver" = 1 ]; then
        raw=$(printf '%s' "$padded" | base64 -d 2>/dev/null) || return 1
        canonical=$(printf '%s' "$raw" | base64 -w0 | tr '+/' '-_' | tr -d '=')
        [ "$canonical" = "$encoded" ] || return 1 # rejects NULs/noncanonical/trailing newlines
    else
        raw=$(printf '%s' "$padded" | base64 -d 2>/dev/null | gunzip 2>/dev/null) || return 1
    fi
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
        [[ ! -v MT_LINK_DATA[$key] ]] || return 1
        mt_link_field_valid "$key" "$val" || return 1
        MT_LINK_DATA[$key]="$val"
    done <<< "$raw"
    # v2 links omit SYNC_KEY when it equals the tunnel secret; restore it here.
    if [ "$ver" = 2 ] && [[ ! -v MT_LINK_DATA[SYNC_KEY] ]] && [[ -v MT_LINK_DATA[TUN_SECRET] ]]; then MT_LINK_DATA[SYNC_KEY]="${MT_LINK_DATA[TUN_SECRET]}"; fi
    mt_link_validate
}
mt_link_read() { # read flat metadata as data, never source it
    local value
    value=$(awk -v k="$2" 'index($0,k"=")==1 {sub(/^[^=]*=/,"");print;exit}' "$1")
    printf '%s' "$value"
}
mt_link_uint() { [[ "$1" =~ ^[0-9]{1,10}$ ]] && ((10#$1 >= $2 && 10#$1 <= $3)); }
mt_link_ports() {
    local spec="$1" p; local -a a=(); local -A seen=()
    [ -z "$spec" ] && return 0
    [[ "$spec" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
    IFS=, read -ra a <<< "$spec"
    [ "${#a[@]}" -le 128 ] || return 1
    for p in "${a[@]}"; do mt_valid_port "$p" || return 1; p=$((10#$p)); [[ ! -v seen[$p] ]] || return 1; seen[$p]=1; done
}
mt_link_field_valid() {
    local key="$1" val="$2" safe='^[][A-Za-z0-9_:.,=-]*$'
    # Reject whitespace, control bytes, shell syntax, quotes, paths and unknown keys.
    [ "${#val}" -le 4096 ] && [[ "$val" =~ $safe ]] || return 1
    case "$key" in
        ROLE) [[ "$val" =~ ^[12]$ ]];;
        NAME) [[ "$val" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]];;
        BIND_HOST) [[ "$val" = 0.0.0.0 || "$val" = :: ]];;
        EXPIRES) mt_link_uint "$val" 1 9999999999;;
        CORE_V6) [ -z "$val" ] || mt_valid_ipv6 "$val::1";;
        HOST|LOCAL_PUB|REMOTE_PUB|LOCAL_PUB6|REMOTE_PUB6|LOCAL_IP6|REMOTE_IP6|REMOTE_V4)
            [ -z "$val" ] || mt_valid_host "$val";;
        TOKEN|TUN_SECRET|SYNC_KEY) [[ "$val" =~ ^[A-Za-z0-9_=-]{1,256}$ ]];;
        LINK_PORT) mt_valid_port "$val";;
        TCP_PORTS|UDP_PORTS) mt_link_ports "$val";;
        TRANSPORT) [[ "$val" =~ ^(tcp|tcpmux|ws|wss|wsmux|wssmux|udp)$ ]];;
        PORTS) return 0;;
        ENABLE_UDP|ADV_AGGRESSIVE|ADV_NODELAY|ADV_PROXY|KCP_WDELAY|KCP_ACKNODELAY) [[ "$val" =~ ^(true|false)$ ]];;
        PROTO) [[ "$val" =~ ^(ipv4|ipv6|6to4|gre6|ipip4to4|ipip4to6|ipip6to6)$ ]];;
        CORE_SUBNET) mt_valid_ipv4 "$val.1";;
        TUN_ID) mt_link_uint "$val" 0 16777215;;
        VNI_ID) mt_link_uint "$val" 1 16777215;;
        MAX_IPS) mt_link_uint "$val" 0 64;;
        CUSTOM_MTU) [ -z "$val" ] || mt_link_uint "$val" 512 9000;;
        ENCRYPT) [[ "$val" =~ ^[01]$ ]];;
        ADV_LOG) [[ "$val" =~ ^(trace|debug|info|warn|error)$ ]];;
        ADV_KEEPALIVE|ADV_HEARTBEAT|ADV_CHANNEL|ADV_POOL|ADV_RETRY|ADV_DIAL|ADV_MUX_CON|ADV_MUX_VERSION|ADV_MUX_FRAME|ADV_MUX_RECEIVE|ADV_MUX_STREAM|ADV_MTU|ADV_MSS|ADV_RCVBUF|ADV_SNDBUF) mt_link_uint "$val" 0 1073741824;;
        PROFILE) [[ "$val" =~ ^(ECO|BALANCED|SPEED|LATENCY|EXTREME|NORMAL|FAST|FAST2|FAST3|MANUAL|CUSTOM)$ ]];;
        BLOCK) [[ "$val" =~ ^(aes-128-gcm|aes|aes-128|aes-192|aes-256|salsa20|blowfish|twofish|cast5|3des|tea|xtea|xor|sm4|none)$ ]];;
        KCP_MODE) [[ "$val" =~ ^(normal|fast|fast2|fast3|manual)$ ]];;
        KCP_CONN) mt_link_uint "$val" 1 32;;
        KCP_MTU) mt_link_uint "$val" 576 1500;;
        KCP_NODELAY|KCP_NOCONGESTION) [[ "$val" =~ ^[01]$ ]];;
        KCP_RESEND) mt_link_uint "$val" 0 2;;
        KCP_INTERVAL) mt_link_uint "$val" 10 5000;;
        KCP_RCVWND|KCP_SNDWND) mt_link_uint "$val" 128 32768;;
        KCP_STREAMBUF|KCP_SMUXBUF|KCP_PCAP_SOCKBUF) mt_link_uint "$val" 65536 268435456;;
        KCP_TCPBUF|KCP_UDPBUF) mt_link_uint "$val" 1024 1048576;;
        KCP_DSHARD|KCP_PSHARD|KCP_SMUXKALIVE) mt_link_uint "$val" 0 65535;;
        *) return 1;;
    esac
}
mt_link_validate() {
    local key required
    [[ "$MT_KIND" =~ ^(gre|vxlan|backhaul|rathole|paqet)$ ]] || return 1
    local allowed=' ROLE NAME HOST EXPIRES '
    case "$MT_KIND" in
        gre) allowed+=' PROTO TUN_SECRET SYNC_KEY CORE_SUBNET CORE_V6 TUN_ID MAX_IPS CUSTOM_MTU ENCRYPT LOCAL_PUB REMOTE_PUB LOCAL_PUB6 REMOTE_PUB6 LOCAL_IP6 REMOTE_IP6 REMOTE_V4 ';;
        vxlan) allowed+=' PROTO TUN_SECRET SYNC_KEY CORE_SUBNET VNI_ID MAX_IPS CUSTOM_MTU ENCRYPT LOCAL_PUB REMOTE_PUB LOCAL_PUB6 REMOTE_PUB6 LOCAL_IP6 REMOTE_IP6 REMOTE_V4 ';;
        backhaul) allowed+=' TOKEN LINK_PORT TRANSPORT PORTS ENABLE_UDP BIND_HOST ADV_KEEPALIVE ADV_HEARTBEAT ADV_CHANNEL ADV_POOL ADV_RETRY ADV_DIAL ADV_AGGRESSIVE ADV_NODELAY ADV_LOG ADV_MUX_CON ADV_MUX_VERSION ADV_MUX_FRAME ADV_MUX_RECEIVE ADV_MUX_STREAM ADV_MTU ADV_MSS ADV_RCVBUF ADV_SNDBUF ADV_PROXY ';;
        rathole) allowed+=' TOKEN LINK_PORT TCP_PORTS UDP_PORTS BIND_HOST ';;
        paqet) allowed+=' TOKEN LINK_PORT TCP_PORTS PROFILE BLOCK KCP_MODE KCP_CONN KCP_MTU KCP_RCVWND KCP_SNDWND KCP_SMUXBUF KCP_STREAMBUF KCP_PCAP_SOCKBUF KCP_TCPBUF KCP_UDPBUF KCP_NODELAY KCP_WDELAY KCP_ACKNODELAY KCP_INTERVAL KCP_RESEND KCP_NOCONGESTION KCP_DSHARD KCP_PSHARD KCP_SMUXKALIVE ';;
    esac
    for key in "${!MT_LINK_DATA[@]}"; do
        [[ "$allowed" == *" $key "* ]] || { echo "Unexpected $MT_KIND field: $key" >&2; return 1; }
    done
    for key in "${!MT_LINK_DATA[@]}"; do mt_link_field_valid "$key" "${MT_LINK_DATA[$key]}" || { echo "Invalid setup field: $key" >&2; return 1; }; done
    required='ROLE NAME HOST EXPIRES'
    case "$MT_KIND" in
        gre) required+=' PROTO TUN_SECRET CORE_SUBNET TUN_ID MAX_IPS ENCRYPT';;
        vxlan) required+=' PROTO TUN_SECRET CORE_SUBNET VNI_ID MAX_IPS ENCRYPT';;
        backhaul) required+=' TOKEN LINK_PORT TRANSPORT PORTS ENABLE_UDP';;
        rathole) required+=' TOKEN LINK_PORT TCP_PORTS UDP_PORTS';;
        paqet) required+=' TOKEN LINK_PORT TCP_PORTS PROFILE BLOCK KCP_MODE KCP_CONN KCP_MTU KCP_RCVWND KCP_SNDWND KCP_SMUXBUF KCP_STREAMBUF KCP_PCAP_SOCKBUF KCP_TCPBUF KCP_UDPBUF';;
    esac
    for key in $required; do [[ -v MT_LINK_DATA[$key] ]] || { echo "Missing setup field: $key" >&2; return 1; }; done
    [ -n "${MT_LINK_DATA[HOST]}" ] && mt_valid_host "${MT_LINK_DATA[HOST]}" || return 1
    ((10#${MT_LINK_DATA[EXPIRES]} >= $(date +%s))) || { echo 'Setup link has expired; generate a new link.' >&2; return 1; }
    return 0
}
mt_link_select() {
    case "$MT_KIND" in
        gre) select_tunnel_interactive || return 1; MT_LINK_CONF="$SELECTED_CONF";;
        vxlan) select_fabric_interactive || return 1; MT_LINK_CONF="$SELECTED_CONF";;
        backhaul) select_tunnel || return 1; MT_LINK_CONF="$SELECTED_TUN";;
        rathole) select_tunnel || return 1; MT_LINK_CONF="$SELECTED_TUN/meta.conf";;
        paqet) select_tunnel || return 1; MT_LINK_CONF="${SELECTED_TUN%.yaml}.meta";;
    esac
    [ -f "$MT_LINK_CONF" ]
}
mt_link_export() {
    local conf="${1:-}" host name role key ttl link dest
    [ -n "$conf" ] || { mt_link_select || return 1; conf="$MT_LINK_CONF"; }
    [ -f "$conf" ] || return 1
    declare -gA MT_LINK_DATA=()
    case "$MT_KIND" in
        rathole) name=$(basename "$(dirname "$conf")"); role=$(mt_link_read "$conf" TYPE);;
        gre|vxlan) name=$(basename "$conf" .conf); role=$(mt_link_read "$conf" TYPE);;
        *) name=$(basename "$conf" .meta); role=$(mt_link_read "$conf" ROLE);;
    esac
    [[ "$role" =~ ^[12]$ ]] || return 1
    MT_LINK_DATA[ROLE]=$((3-role)); MT_LINK_DATA[NAME]="$name"
    MT_LINK_DATA[EXPIRES]=$(($(date +%s)+604800))
    case "$MT_KIND" in
        gre|vxlan)
            for key in TUN_SECRET SYNC_KEY CORE_SUBNET CORE_V6 TUN_ID VNI_ID MAX_IPS CUSTOM_MTU ENCRYPT; do
                case "$MT_KIND:$key" in gre:VNI_ID|vxlan:TUN_ID|vxlan:CORE_V6) continue;; esac
                MT_LINK_DATA[$key]=$(mt_link_read "$conf" "$key")
            done
            MT_LINK_DATA[SYNC_KEY]="${MT_LINK_DATA[SYNC_KEY]:-${MT_LINK_DATA[TUN_SECRET]}}"
            if [ "$MT_KIND" = gre ]; then MT_LINK_DATA[PROTO]=$(mt_link_read "$conf" TUN_PROTO); else MT_LINK_DATA[PROTO]=$(mt_link_read "$conf" FAB_PROTO); fi
            MT_LINK_DATA[PROTO]="${MT_LINK_DATA[PROTO]:-ipv4}"
            MT_LINK_DATA[ENCRYPT]="${MT_LINK_DATA[ENCRYPT]:-0}"
            for key in LOCAL_PUB LOCAL_PUB6 LOCAL_IP6; do
                dest="REMOTE${key#LOCAL}"; MT_LINK_DATA[$dest]=$(mt_link_read "$conf" "$key"); MT_LINK_DATA[$key]=$(mt_link_read "$conf" "$dest")
            done
            MT_LINK_DATA[HOST]="${MT_LINK_DATA[REMOTE_PUB6]:-${MT_LINK_DATA[REMOTE_PUB]}}"
            ;;
        backhaul)
            for key in TOKEN TRANSPORT PORTS ENABLE_UDP; do MT_LINK_DATA[$key]=$(mt_link_read "$conf" "$key"); done
            MT_LINK_DATA[LINK_PORT]=$(mt_link_read "$conf" TUN_PORT)
            # Machine-local TLS paths and client CDN overrides are deliberately not exported.
            while IFS='=' read -r key host; do
                case "$key" in ADV_TLS_CERT|ADV_TLS_KEY|ADV_EDGE) continue;; ADV_*) MT_LINK_DATA[$key]="$host";; esac
            done < "$conf"
            ;;
        rathole)
            for key in TOKEN LINK_PORT TCP_PORTS UDP_PORTS; do MT_LINK_DATA[$key]=$(mt_link_read "$conf" "$key"); done;;
        paqet)
            MT_LINK_DATA[LINK_PORT]=$(mt_link_read "$conf" TUN_PORT)
            MT_LINK_DATA[TCP_PORTS]=$(mt_link_read "$conf" TCP_PORTS)
            MT_LINK_DATA[PROFILE]=$(get_tunnel_profile "$name")
            MT_LINK_DATA[TOKEN]=$(get_yaml_value key "$CONF_DIR/$name.yaml")
            MT_LINK_DATA[BLOCK]=$(get_yaml_value block "$CONF_DIR/$name.yaml")
            mt_link_paqet_values "$CONF_DIR/$name.yaml" || return 1;;
    esac
    if [[ "$MT_KIND" == backhaul || "$MT_KIND" == rathole ]]; then
        host=$(mt_link_read "$conf" REMOTE_IP)
        MT_LINK_DATA[BIND_HOST]=0.0.0.0
        [[ "$host" != *:* ]] || MT_LINK_DATA[BIND_HOST]=::
    fi
    if [[ "$MT_KIND" != gre && "$MT_KIND" != vxlan ]]; then
        host=$(get_local_ip)
        mt_ask dest "This server's reachable public IP/hostname [$host]: " || return 1
        host="${dest:-$host}"
        mt_valid_host "$host" && [[ "$host" != 0.0.0.0 && "$host" != :: ]] || { echo 'Enter a reachable endpoint.' >&2; return 1; }
        MT_LINK_DATA[HOST]="$host"
        if [ "$MT_KIND" = backhaul ] && [ "$role" = 2 ]; then
            mt_ask dest 'Peer server port mappings (e.g. 443=127.0.0.1:443): ' || return 1
            validate_bh_ports "$dest" 0 || return 1; MT_LINK_DATA[PORTS]="$dest"
        elif [ "$MT_KIND" = paqet ] && [ "$role" = 1 ]; then
            mt_ask dest 'Peer client forwarded TCP ports (e.g. 443,8080): ' || return 1
            mt_link_ports "$dest" && [ -n "$dest" ] || return 1; MT_LINK_DATA[TCP_PORTS]="$dest"
        fi
    fi
    link=$(mt_link_encode) || { echo 'Cannot export these settings safely.' >&2; return 1; }
    echo -e "\n  ${G}● Peer Setup Link (valid for 7 days):${NC}\n$link"
    echo -e "  ${Y}● Contains the tunnel secret. Share privately; this link is not encrypted.${NC}"
    mt_workspace_pause
}
mt_link_offer() {
    local ans
    mt_ask ans 'Generate a setup link for the peer now? [Y/n]: ' || return 0
    case "${ans,,}" in n|no) return 0;; esac
    mt_link_export "$1"
}
mt_link_import() {
    local link ans name
    mt_workspace_screen
    mt_ask link 'Paste Peer Setup Link (q: back): ' || return 1
    [ "$link" != q ] || return 0
    mt_link_decode "$link" || { echo -e "  ${R}✖ Invalid / expired link. No changes made.${NC}"; mt_workspace_pause; return 1; }
    echo -e "\n  ${DIM}┌─[ PEER SETUP PREVIEW ]${NC}"
    echo -e "  ${DIM}│${NC}"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "Module" "$NC" "$DIM" "$NC" "$W" "$MT_KIND" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "Role" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[ROLE]}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "Peer" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[HOST]:--}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "Link port" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[LINK_PORT]:--}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "Transport" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[TRANSPORT]:-${MT_LINK_DATA[PROTO]:-KCP/TCP}}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "TCP ports" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[TCP_PORTS]:-${MT_LINK_DATA[PORTS]:--}}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "UDP ports" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[UDP_PORTS]:--}" "$NC"
    printf '  %b├─%b %b%-11s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "vIPs" "$NC" "$DIM" "$NC" "$W" "${MT_LINK_DATA[MAX_IPS]:--}" "$NC"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}Secret is hidden. Existing tunnels will not be overwritten.${NC}"
    mt_ask name "Local tunnel name/suffix [${MT_LINK_DATA[NAME]}]: " || return 1
    name="${name:-${MT_LINK_DATA[NAME]}}"
    mt_link_field_valid NAME "$name" || { echo 'Invalid name.' >&2; return 1; }
    MT_LINK_DATA[NAME]="$name"
    mt_ask ans 'Is this correct? Create this peer tunnel? [y/N]: ' || return 1
    [[ "${ans,,}" == y || "${ans,,}" == yes ]] || return 0
    if mt_link_deploy; then
        echo -e "  ${G}● Peer configuration created. Check Live Monitor for the peer connection.${NC}"
        mt_ask_bbr_on_create
    else echo -e "  ${R}✖ Creation failed; see the error above.${NC}"; fi
    mt_workspace_pause
}
mt_workspace_vip() {
    local ans count
    MT_NEW_VIP_COUNT=0
    mt_ask ans 'Create internal Virtual IPs for this tunnel? [y/N/q]: ' || return 1
    case "${ans,,}" in q) return 1;; n|no|'') return 0;; y|yes) ;; *) echo 'Type y, n or q.' >&2; mt_workspace_vip; return $?;; esac
    while true; do
        mt_ask count 'Virtual IP pair count [1] (1-64, q: back): ' || return 1
        [ "$count" != q ] || return 1; count="${count:-1}"
        if mt_link_uint "$count" 1 64; then MT_NEW_VIP_COUNT=$((10#$count)); return 0; fi
        echo 'Enter a number between 1 and 64.'
    done
}
mt_workspace_backup() {
    local dest
    mt_workspace_screen
    mt_ask dest "Backup file [$LOCAL_DIR/backups/$MT_KIND-$(date +%Y%m%d-%H%M%S).tar.gz]: " || return 1
    dest="${dest:-$LOCAL_DIR/backups/$MT_KIND-$(date +%Y%m%d-%H%M%S).tar.gz}"
    mkdir -p "$(dirname "$dest")" || return 1
    [ ! -e "$dest" ] || { echo 'File already exists; choose another path.' >&2; return 1; }
    (umask 077; tar -czf "$dest" -C "$(dirname "$CONF_DIR")" "$(basename "$CONF_DIR")") && echo "  Backup saved: $dest"
    mt_workspace_pause
}
# END MTUNNEL WORKSPACE V13

mt_link_deploy_locked() {
    mt_link_validate || return 1
    local name="${MT_LINK_DATA[NAME]}" role="${MT_LINK_DATA[ROLE]}" proto="${MT_LINK_DATA[PROTO]}" conf iface key stage min max def local_addr rc
    name="${name#vx_}"
    if [ "$MT_KIND" = gre ]; then
        # Strip a source interface prefix, then choose the correct prefix for this peer.
        name=$(get_pure_tun_name "$name")
        name="$(mgre_name_prefix "$proto" "$role")$name"; iface="$name"
        [ "${#name}" -le 15 ] && { [ "$proto" != 6to4 ] || [ "${#name}" -le 11 ]; } || { echo 'Interface name is too long.' >&2; return 1; }
    else name="vx_$name"; iface="$name"; [ "${#name}" -le 15 ] || return 1; fi
    conf="$CONF_DIR/$name.conf"
    [ ! -e "$conf" ] && ! ip link show "$iface" >/dev/null 2>&1 || { echo 'Tunnel/interface already exists; nothing overwritten.' >&2; return 1; }
    [ "$MT_KIND" != vxlan ] || ! ip link show "br_${name#vx_}" >/dev/null 2>&1 || return 1
    [ "$MT_KIND" != gre ] || [ "$proto" != ipv6 ] || return 1
    [ "$MT_KIND" != vxlan ] || [[ "$proto" =~ ^(ipv4|ipv6)$ ]] || return 1
    for key in LOCAL_PUB REMOTE_PUB LOCAL_PUB6 REMOTE_PUB6 LOCAL_IP6 REMOTE_IP6; do
        MT_LINK_DATA[$key]="${MT_LINK_DATA[$key]:-}"
    done
    case "$MT_KIND:$proto" in
        gre:gre6|gre:ipip4to6|gre:ipip6to6|vxlan:ipv6)
            is_global_ipv6 "${MT_LINK_DATA[LOCAL_PUB6]}" && is_global_ipv6 "${MT_LINK_DATA[REMOTE_PUB6]}" || return 1
            local_addr="${MT_LINK_DATA[LOCAL_PUB6]}";;
        *) is_ipv4 "${MT_LINK_DATA[LOCAL_PUB]}" && is_ipv4 "${MT_LINK_DATA[REMOTE_PUB]}" || return 1; local_addr="${MT_LINK_DATA[LOCAL_PUB]}";;
    esac
    # Source endpoints may be stale; do not bind an unassigned address on the peer.
    if ! ip -o addr show | awk '{split($4,a,"/");print a[1]}' | grep -Fxq "$local_addr"; then
        echo "Local endpoint $local_addr is not assigned on this server. Correct the source endpoint and regenerate the link." >&2; return 1
    fi
    if subnet_in_use "${MT_LINK_DATA[CORE_SUBNET]}"; then echo 'Core subnet overlaps an existing tunnel/route.' >&2; return 1; fi
    if [ "$MT_KIND" = gre ]; then
        grep -q "^TUN_ID=${MT_LINK_DATA[TUN_ID]}$" "$CONF_DIR"/*.conf 2>/dev/null && { echo 'Tunnel key already in use.' >&2; return 1; }
        read -r min max def <<< "$(mgre_mtu_limits "$proto")"
    else
        grep -q "^VNI_ID=${MT_LINK_DATA[VNI_ID]}$" "$CONF_DIR"/*.conf 2>/dev/null && { echo 'VNI already in use.' >&2; return 1; }
        min=576; max=1450; [ "$proto" != ipv6 ] || max=1430
    fi
    if [ -n "${MT_LINK_DATA[CUSTOM_MTU]:-}" ]; then mt_link_uint "${MT_LINK_DATA[CUSTOM_MTU]}" "$min" "$max" || { echo 'MTU outside protocol limits.' >&2; return 1; }; fi
    # Existing vIP generator uses IPv4 pairs; IPIP6->6 carries only IPv6 payload.
    if [ "$proto" = ipip6to6 ] && [ "${MT_LINK_DATA[MAX_IPS]}" != 0 ]; then echo 'IPv4 vIPs cannot be carried by IPIP6->6.' >&2; return 1; fi
    stage=$(mktemp "$SECURE_TMP/peer-network.XXXXXX") || return 1
    {
        printf 'TYPE=%s\n' "$role"
        for key in LOCAL_PUB REMOTE_PUB LOCAL_PUB6 REMOTE_PUB6 LOCAL_IP6 REMOTE_IP6 TUN_SECRET CORE_SUBNET CORE_V6 MAX_IPS CUSTOM_MTU ENCRYPT; do printf '%s=%s\n' "$key" "${MT_LINK_DATA[$key]:-}"; done
        printf 'SYNC_KEY=%s\nFWD_TCP=\nFWD_UDP=\nLB_MODE=0\n' "${MT_LINK_DATA[SYNC_KEY]:-${MT_LINK_DATA[TUN_SECRET]}}"
        if [ "$MT_KIND" = gre ]; then printf 'T_NAME=%s\nTUN_ID=%s\nTUN_PROTO=%s\n' "$name" "${MT_LINK_DATA[TUN_ID]}" "$proto"
        else printf 'VX_NAME=%s\nBR_NAME=br_%s\nVNI_ID=%s\nFAB_PROTO=%s\n' "$name" "${name#vx_}" "${MT_LINK_DATA[VNI_ID]}" "$proto"; fi
    } > "$stage"
    mt_validate_tunnel_conf "$stage" "$MT_KIND" || { rm -f "$stage"; return 1; }
    # Exclusive publish protects against a second simultaneous setup/import.
    (umask 077; set -o noclobber; cat "$stage" > "$conf") 2>/dev/null || { rm -f "$stage"; return 1; }
    rm -f "$stage"
    if [ "$MT_KIND" = gre ]; then apply_tunnel "$conf"; rc=$?; else apply_fabric "$conf"; rc=$?; fi
    if [ "$rc" != 0 ] || ! ip link show "$iface" >/dev/null 2>&1; then
        if [ "$MT_KIND" = gre ]; then teardown_tunnel "$conf"; else teardown_fabric "$conf"; fi
        rm -f "$conf"; return 1
    fi
    setup_service
}
mt_workspace_health() {
    mt_link_select || return 1
    local conf="$MT_LINK_CONF" proto role sub remote ping_cmd name
    role=$(mt_link_read "$conf" TYPE); sub=$(mt_link_read "$conf" CORE_SUBNET)
    remote="$sub.$((3-role))"; ping_cmd=ping
    if [ "$MT_KIND" = gre ]; then
        proto=$(mt_link_read "$conf" TUN_PROTO); name=$(mt_link_read "$conf" T_NAME)
        if [ "$proto" = ipip6to6 ]; then remote="$(mt_link_read "$conf" CORE_V6)::$((3-role))"; ping_cmd='ping -6'; fi
    else name=$(mt_link_read "$conf" VX_NAME); fi
    mt_workspace_screen
    echo "  Tunnel interface: $name | Inner peer: $remote"
    ip -details link show "$name"
    $ping_cmd -c 3 -W 1 "$remote"
    echo '  Ping verifies the inner peer only when ICMP is permitted.'
    mt_workspace_pause
}

mt_link_deploy() {
    local fd rc
    exec {fd}>"$SECURE_TMP/$MT_KIND-peer-setup.lock" || return 1
    flock -x "$fd" || { exec {fd}>&-; return 1; }
    mt_link_deploy_locked; rc=$?
    exec {fd}>&-
    return "$rc"
}

mt_workspace_auto_backup() {
    local dest module="m$MT_KIND"
    [ "$MT_KIND" != vxlan ] || module=mxlan
    [ "$MT_KIND" != paqet ] || module=mpaqet
    mkdir -p "$LOCAL_DIR/backups" || return 1
    chmod 700 "$LOCAL_DIR/backups"
    dest=$(mktemp "$LOCAL_DIR/backups/$module-before-edit-$(date +%Y%m%d-%H%M%S)-XXXXXX.tgz") || return 1
    if ! tar -czf "$dest" -C "$(dirname "$CONF_DIR")" "$(basename "$CONF_DIR")"; then rm -f "$dest"; return 1; fi
    chmod 600 "$dest"
    printf '  Config restore point: %s\n' "$dest"
}
mt_workspace_update_badge() {
    local rv file="$SECURE_TMP/.mxlan_remote_ver"
    [ -f "$file" ] || return 0
    rv=$(tr -d '\r\n ' < "$file")
    if mt_is_newer_version "$rv" "$MODULE_VERSION"; then
        printf ' %b(Update Available: v%s)%b' "$Y" "$rv" "$NC"
    fi
    return 0
}
MT_KIND=vxlan; MT_HEADER=draw_mxlan_header; MT_SECTION=""
mt_workspace_route() {
    local section="$1"
    case "$section" in
        1) MT_SECTION=1; mt_workspace_menu "CREATE TUNNEL" "1|Manual VXLAN Setup|1|${C}" "2|Create From Peer Link|97|${G}" "3|Generate Peer Setup Link|98|${M}" || { MT_SECTION=""; return 1; };;
        2) MT_SECTION=2; mt_workspace_menu "EDIT & MANAGE" "1|Fabric Name|7|${W}" "2|Public IPs|8|${C}" "3|Token / Secret|9|${M}" "4|Core Subnet|10|${Y}" "5|MTU & MSS|11|${C}" "6|Virtual IP Manager|2|${G}" "7|Delete Fabrics|6|${R}" || { MT_SECTION=""; return 1; };;
        3) MT_SECTION=3; mt_workspace_menu "FORWARDING" "1|Port Forwarding / Selected IPs / Load Balance|4|${G}" "2|MPorter Forwarders|3|${C}" || { MT_SECTION=""; return 1; };;
        4) MT_SECTION=4; mt_workspace_menu "SYSTEM & SECURITY" "1|IPsec Encryption|13|${M}" "2|Firewall Guard|14|${R}" "3|Auto Recovery|15|${G}" "4|BBR Settings|16|${G}" "5|Check Selected Tunnel|99|${C}" || { MT_SECTION=""; return 1; };;
        7) MT_ACTION=17;;
        5) MT_ACTION=5;;
        6) MT_ACTION=12;;
        8) MT_ACTION=18;;
        9) MT_ACTION=19;;
        0) MT_ACTION=0;;
        *) return 1;;
    esac
}

render_mxlan_menu() {
    mt_workspace_screen
    mt_workspace_group 'PROVISION & MANAGE' first
    mt_workspace_row 1 'Create Tunnel' "$C"
    mt_workspace_row 2 'Edit & Manage' "$Y"
    mt_workspace_row 3 'Forwarding' "$G"
    mt_workspace_row 4 'System & Security' "$M"
    mt_workspace_row 5 'Tunnels Info And Specs' "$M"
    mt_workspace_row 6 'Live Monitor' "$W"
    mt_workspace_row 7 'Update and Local Install' "$G" "$(mt_workspace_update_badge)"
    mt_workspace_row 8 'Backup & Restore' "$W"
    mt_workspace_row 9 'Uninstall MXLAN' "$R"
    mt_workspace_footer 'Return to Main Core'
}

while true; do
    if [ -n "$MT_SECTION" ]; then opt="$MT_SECTION"
    else
        render_mxlan_menu > "$SECURE_TMP/.mxlan_frame"
        cat "$SECURE_TMP/.mxlan_frame"
        LIVE_ROWS=$(wc -l < "$SECURE_TMP/.mxlan_frame"); LIVE_HEADER_FUNC="draw_mxlan_header"
        LIVE_MENU_FUNC="render_mxlan_menu"; LIVE_FRAME_FILE="$SECURE_TMP/.mxlan_frame"
        read_with_refresh "  ${C}MXLAN ❯❯ ${NC}" opt || break
        LIVE_HEADER_FUNC=""; LIVE_MENU_FUNC=""
        opt="${opt//$'\r'/}"
    fi
    mt_workspace_route "$opt" || continue
    case "$MT_ACTION" in
        97) mt_link_import; continue;;
        98) mt_link_export; continue;;
        99) mt_workspace_health; continue;;
        96) mt_workspace_menu "BACKUP" "1|Save Config Backup|save|${W}" || continue; mt_workspace_backup; continue;;
    esac
    # Every edit/forwarding action gets a private config restore point first.
    if [[ "$MT_SECTION" == 2 || "$MT_SECTION" == 3 ]]; then
        mt_workspace_auto_backup || { echo 'Could not save the config restore point; operation cancelled.' >&2; mt_workspace_pause; continue; }
    fi
    opt="$MT_ACTION"
    case $opt in
        1) 
           mt_workspace_screen
           draw_mxlan_header
           echo -e "\n  ${DIM}┌─[ VXLAN DEPLOYMENT ]${NC}"
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IR | 2:KH | q:Back]: ${NC}"; read -r s_type; [[ "$s_type" == "q" ]] && break; [[ "$s_type" == "1" || "$s_type" == "2" ]] && break; done
           [[ "$s_type" == "q" ]] && continue

           while true; do echo -ne "  ${C}●${NC} ${W}Underlay IP Family [1:IPv4 | 2:IPv6 | q:Back]: ${NC}"; read -r fam_choice; [[ "$fam_choice" == "q" ]] && break; [[ "$fam_choice" == "1" || "$fam_choice" == "2" ]] && break; done
           [[ "$fam_choice" == "q" ]] && continue
           fab_proto="ipv4"; [[ "$fam_choice" == "2" ]] && fab_proto="ipv6"
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Fabric Suffix Name (e.g. ir, kh): ${NC}"; read -r suffix
               suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
               [[ "$suffix" == "q" ]] && break
               if [ -n "$suffix" ] && [ ${#suffix} -le 12 ]; then break; fi
               [ -n "$suffix" ] && echo -e "  ${R}● Error: max 12 chars (kernel interface limit is 15).${NC}"
           done
           [[ "$suffix" == "q" ]] && continue
           vx_name="vx_${suffix}"; br_name="br_${suffix}"
           
           if [ -f "$CONF_DIR/${vx_name}.conf" ]; then
               echo -e "\n  ${R}● Error: Fabric name [${vx_name}] already exists!${NC}"; sleep 2; continue
           fi

           local_ip=""; local_ip6=""; r_ip=""; r_ip6=""; r_v4=""
           if [ "$fab_proto" == "ipv4" ]; then
               auto_lip=$(get_local_ip)
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Local Public IPv4 [${Y}${auto_lip}${W}]: ${NC}"; read -r custom_ip
                   [[ "$custom_ip" == "q" ]] && break
                   custom_ip=$(echo "$custom_ip" | tr -dc '0-9.')
                   if [ -n "$custom_ip" ] && ! is_ipv4 "$custom_ip"; then echo -e "  ${R}✖ Invalid IPv4 address.${NC}"; continue; fi
                   [ -n "$custom_ip" ] && auto_lip=$custom_ip
                   break
               done
               [[ "$custom_ip" == "q" ]] && continue
               local_ip="$auto_lip"

               while true; do
                   echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IPv4: ${NC}"; read -r r_ip
                   [[ "$r_ip" == "q" ]] && break
                   r_ip=$(echo "$r_ip" | tr -dc '0-9.'); is_ipv4 "$r_ip" && break
                   echo -e "  ${R}✖ Invalid IPv4 address.${NC}"
               done
               [[ "$r_ip" == "q" ]] && continue
           else
               local_ip6="$(get_local_ipv6)"
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Local Public IPv6 [${Y}${local_ip6:-none}${W}]: ${NC}"; read -r custom_ip6
                   [[ "$custom_ip6" == "q" ]] && break
                   custom_ip6=$(echo "$custom_ip6" | tr -dc '0-9a-fA-F:'); custom_ip6="${custom_ip6,,}"
                   if [ -n "$custom_ip6" ]; then
                       is_global_ipv6 "$custom_ip6" && { local_ip6="$custom_ip6"; break; }
                       echo -e "  ${R}✖ Invalid IPv6 address (global/ULA only, no link-local).${NC}"; continue
                   fi
                   is_global_ipv6 "$local_ip6" && break
                   echo -e "  ${R}✖ No usable IPv6 detected on this host. Enter its public IPv6 manually.${NC}"
               done
               [[ "$custom_ip6" == "q" ]] && continue
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IPv6: ${NC}"; read -r r_ip6
                   [[ "$r_ip6" == "q" ]] && break
                   r_ip6=$(echo "$r_ip6" | tr -dc '0-9a-fA-F:'); r_ip6="${r_ip6,,}"
                   is_global_ipv6 "$r_ip6" && break
                   echo -e "  ${R}✖ Invalid IPv6 address.${NC}"
               done
               [[ "$r_ip6" == "q" ]] && continue
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Remote Server IPv4 (for header display, Enter to skip): ${NC}"; read -r r_v4
                   [[ "$r_v4" == "q" ]] && break
                   r_v4=$(echo "$r_v4" | tr -dc '0-9.'); [ -z "$r_v4" ] && break
                   is_ipv4 "$r_v4" && break
                   echo -e "  ${R}✖ Invalid IPv4 address.${NC}"
               done
               [[ "$r_v4" == "q" ]] && continue
           fi

           s_key=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
           echo -ne "  ${C}●${NC} ${M}Master Secret Token [Default ${s_key}]: ${NC}"; read -r u_key
           [[ "$u_key" == "q" ]] && continue
           u_key=$(echo "$u_key" | tr -dc 'a-zA-Z0-9_=-')
           tun_secret=${u_key:-$s_key}

           hash_c=$(echo -n "core_${tun_secret}" | sha256sum)
           vni_id=$(( 16#${hash_c:0:6} ))
           [ "$vni_id" -eq 0 ] && vni_id=1

           class_selector=$(( 16#${hash_c:6:2} % 3 ))
           c1=""; c2=""; c3=""
           if [ "$class_selector" == "0" ]; then c1="10"; c2=$(( (16#${hash_c:8:2} % 254) + 1 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
           elif [ "$class_selector" == "1" ]; then c1="172"; c2=$(( (16#${hash_c:8:2} % 16) + 16 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
           else c1="192"; c2="168"; c3=$(( (16#${hash_c:10:2} % 254) + 1 )); fi
           core_sub="${c1}.${c2}.${c3}"

           if grep -q "^VNI_ID=$vni_id$" "$CONF_DIR"/*.conf 2>/dev/null || subnet_in_use "$core_sub"; then
               echo -e "  ${R}● Collision: subnet ${core_sub}.x or VNI already used (MGRE/MXLAN/system route). Choose a different Token.${NC}"; sleep 2.5; continue
           fi

           cust_mtu=""
           mtu_min=576; mtu_max=1450; [ "$fab_proto" != ipv6 ] || mtu_max=1430
           while true; do
               mt_ask cust_mtu "Manual MTU [$mtu_min-$mtu_max; Enter: protocol default; q: back]: " || break
               [[ "$cust_mtu" == q || -z "$cust_mtu" ]] && break
               mt_link_uint "$cust_mtu" "$mtu_min" "$mtu_max" && break
               echo '  MTU is outside the protocol range.'
           done
           [ "$cust_mtu" != q ] || continue
           mt_workspace_vip || continue
           conf_path="$CONF_DIR/${vx_name}.conf"
           echo -e "TYPE=$s_type\nFAB_PROTO=$fab_proto\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nLOCAL_PUB6=$local_ip6\nREMOTE_PUB6=$r_ip6\nREMOTE_V4=$r_v4\nMAX_IPS=$MT_NEW_VIP_COUNT\nSYNC_KEY=$tun_secret\nTUN_SECRET=$tun_secret\nVX_NAME=$vx_name\nBR_NAME=$br_name\nVNI_ID=$vni_id\nCORE_SUBNET=$core_sub\nFWD_TCP=\nFWD_UDP=\nLB_MODE=0\nCUSTOM_MTU=$cust_mtu" > "$conf_path"
           chmod 600 "$conf_path"
           apply_fabric "$conf_path"

           if ip link show "$vx_name" >/dev/null 2>&1; then
               setup_service
               mt_ask_bbr_on_create
               echo -e "  ${G}● Fabric [${vx_name}] deployed (Underlay: ${fab_proto} | VNI: ${vni_id} | Subnet: ${core_sub}.x | MTU: ${cust_mtu:-Default})${NC}"
               [ "$fab_proto" == "ipv6" ] && echo -e "  ${DIM}● IPv6 underlay: allow UDP 4789 over IPv6 in the firewall on BOTH servers.${NC}"
               remote_tip=$([ "$s_type" == "1" ] && echo "${core_sub}.2" || echo "${core_sub}.1")

               echo -ne "\n  ${C}●${NC} ${W}Run initial ping test to peer now? (y/n): ${NC}"; read -r run_initial_ping
               run_initial_ping=$(echo "$run_initial_ping" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
               if [[ "$run_initial_ping" == "y" || "$run_initial_ping" == "yes" ]]; then
                   echo -e "  ${DIM}┌─[ INITIAL PING TEST TO PEER ]${NC}"
                   echo -e "  ${DIM}│${NC} Pinging ${remote_tip} (4 Packets)..."
                   ping_res=$(ping -c 4 -W 1 "$remote_tip" 2>&1)
                   if echo "$ping_res" | grep -q "time="; then
                       lat=$(echo "$ping_res" | grep -oP 'min/avg/max/mdev = \K[^/]+/[^/]+' | cut -d/ -f2)
                       lat_int=$(awk -v v="$lat" 'BEGIN {printf "%.0f", v}')
                       echo -e "  ${DIM}└─${NC} ${G}SUCCESS!${NC} Average Latency: ${Y}${lat_int}ms${NC}"
                   else
                       echo -e "  ${DIM}└─${NC} ${R}FAILED!${NC} Destination Host Unreachable."
                   fi
               fi

               if [ "$s_type" == "1" ]; then
                   echo -ne "\n  ${C}●${NC} ${W}Do you want to setup Port Forwarding? (y/n): ${NC}"; read -r setup_pf
                   setup_pf=$(echo "$setup_pf" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
                   if [[ "$setup_pf" == "y" || "$setup_pf" == "yes" ]]; then
                       echo -ne "  ${C}●${NC} ${Y}NAT Forward TCP Ports (e.g. 80,443)  [Enter to skip]: ${NC}"; read -r fwd_tcp
                       echo -ne "  ${C}●${NC} ${C}NAT Forward UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read -r fwd_udp
                       fwd_tcp=$(sanitize_ports "$fwd_tcp" tcp)
                       fwd_udp=$(sanitize_ports "$fwd_udp" udp)
                       
                       run_lb="0"
                       grep -v "^FWD_TCP=" "$conf_path" | grep -v "^FWD_UDP=" | grep -v "^LB_MODE=" > "${conf_path}.tmp"
                       echo "FWD_TCP=$fwd_tcp" >> "${conf_path}.tmp"
                       echo "FWD_UDP=$fwd_udp" >> "${conf_path}.tmp"
                       echo "LB_MODE=$run_lb" >> "${conf_path}.tmp"
                       mv "${conf_path}.tmp" "$conf_path"
                       
                       if [ -n "$fwd_tcp" ] || [ -n "$fwd_udp" ]; then
                           mt_choose_fwd_targets "$conf_path" "${core_sub}.2" "$(mt_config_value SYNC_KEY "$conf_path")" "$(mt_config_value MAX_IPS "$conf_path")" "$s_type" || true
                       fi
                       apply_fabric "$conf_path"
                       echo -e "  ${G}● Port Forwarding applied successfully.${NC}"
                   fi
               fi
               mt_link_offer "$conf_path"
               sleep 1.8
           else
               echo -e "\n  ${R}● FATAL ERROR: Kernel rejected fabric creation!${NC}"; rm -f "$conf_path"; sleep 3
           fi ;;

        6)
           draw_mxlan_header
           configs=("$CONF_DIR"/*.conf)
           [ ! -e "${configs[0]}" ] && echo -e "\n  ${R}● No active fabrics to remove!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Fabric to Erase ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3.3s${NC} ${C}❯${NC} ${W}%-50.50s${NC}  ${B}│${NC}\n" "$((i+1))" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter Number [1-${#configs[@]}], 'all', or 'q': ${NC}"; read -r del_idx; del_idx=$(echo "$del_idx" | tr -d '\r ')
           [[ "$del_idx" == "q" || -z "$del_idx" ]] && continue
           if [[ "$del_idx" == "all" ]]; then
               echo -ne "  ${R}● DANGER: Delete ALL fabrics? (y/n): ${NC}"; read -r confirm_all
               if [[ "$confirm_all" == "y" ]]; then
                   for conf in "${configs[@]}"; do
                       teardown_fabric "$conf"; rm -f "$conf"
                   done
                   rebuild_guard
                   echo -e "  ${G}● All fabrics safely purged.${NC}"; sleep 1.5
               fi; continue
           fi
           if d_zero=$(pick_index "$del_idx" "${#configs[@]}"); then
               VX_NAME=""; BR_NAME=""; source "${configs[$d_zero]}" 2>/dev/null
               echo -ne "  ${R}● Delete fabric [${VX_NAME}]? (y/n): ${NC}"; read -r confirm_one
               [[ "${confirm_one,,}" == "y" ]] || continue
               teardown_fabric "${configs[$d_zero]}"; rm -f "${configs[$d_zero]}"; rebuild_guard
               echo -e "  ${G}● Fabric [${VX_NAME}] destroyed.${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Invalid selection. Nothing deleted.${NC}"; sleep 1.5
           fi ;;

        2)
           select_fabric_interactive || continue
           draw_mxlan_header
           VX_NAME=""; MAX_IPS="0"; TUN_SECRET=""; VNI_ID=""; source "$SELECTED_CONF" 2>/dev/null
           echo -e "\n  ${DIM}┌─[ vIP ACTIONS for ${VX_NAME} ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup / Update Virtual IPs${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Purge All Virtual IPs${NC}\n  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
           while true; do echo -ne "  ${C}Select Action ❯❯ ${NC}"; read -r vip_action; [[ "$vip_action" =~ ^[12q]$ ]] && break; done
           [[ "$vip_action" == "q" ]] && continue
           if [[ "$vip_action" == "1" ]]; then
               while true; do echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read -r n; [[ "$n" == "q" ]] && break; if is_uint "$n" && [ "$n" -le 64 ]; then break; fi; echo -e "  ${R}✖ Enter a number between 0 and 64.${NC}"; done
               [[ "$n" == "q" ]] && continue
               
               k="${TUN_SECRET:-key_${VNI_ID}}"
               echo -e "  ${DIM}● Sync Key automatically linked to Master Token.${NC}"
               sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$SELECTED_CONF"
               sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$SELECTED_CONF"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● Virtual IPs synchronized successfully.${NC}"; sleep 1.5
           elif [[ "$vip_action" == "2" ]]; then
               if [[ "$MAX_IPS" == "0" || -z "$MAX_IPS" ]]; then echo -e "  ${Y}● No Virtual IPs found!${NC}"; sleep 1.5; continue; fi
               echo -ne "  ${R}● Delete all ${MAX_IPS} vIPs from [${VX_NAME}]? (y/n): ${NC}"; read -r confirm_vip
               if [[ "$confirm_vip" == "y" ]]; then 
                   sed -i "s/^MAX_IPS=.*/MAX_IPS=0/" "$SELECTED_CONF"
                   apply_fabric "$SELECTED_CONF"
                   echo -e "  ${G}● Virtual IPs purged.${NC}"; sleep 1.5
               fi
           fi ;;

        3)
           if command -v mporter >/dev/null 2>&1; then
               mporter
           elif [ -x "/usr/bin/mporter" ]; then
               /usr/bin/mporter
           elif [ -f "/root/mtunnel/mporter.sh" ]; then
               bash /root/mtunnel/mporter.sh
           else
               echo -e "\n  ${R}✖ MPorter script not found on system!${NC}"; sleep 1.5
           fi ;;

        8)
           select_fabric_interactive || continue
           draw_mxlan_header
           LOCAL_PUB=""; REMOTE_PUB=""; LOCAL_PUB6=""; REMOTE_PUB6=""; REMOTE_V4=""; FAB_PROTO="ipv4"; VX_NAME=""; source "$SELECTED_CONF" 2>/dev/null
           if mx_is_v6; then
               echo -ne "  ${C}●${NC} ${W}New Local Public IPv6 [Current: ${Y}${LOCAL_PUB6}${W}, Enter to skip]: ${NC}"; read -r new_lip6
               echo -ne "  ${C}●${NC} ${W}New Remote Public IPv6 [Current: ${Y}${REMOTE_PUB6}${W}, Enter to skip]: ${NC}"; read -r new_rip6
               echo -ne "  ${C}●${NC} ${W}New Remote Server IPv4 for header [Current: ${Y}${REMOTE_V4}${W}, Enter to skip]: ${NC}"; read -r new_rv4
               new_rv4=$(echo "$new_rv4" | tr -dc '0-9.')
               if [ -n "$new_rv4" ] && ! is_ipv4 "$new_rv4"; then echo -e "  ${R}✖ Invalid IPv4 address. Nothing changed.${NC}"; sleep 2; continue; fi
               new_lip6=$(echo "$new_lip6" | tr -dc '0-9a-fA-F:'); new_lip6="${new_lip6,,}"
               new_rip6=$(echo "$new_rip6" | tr -dc '0-9a-fA-F:'); new_rip6="${new_rip6,,}"
               if { [ -n "$new_lip6" ] && ! is_global_ipv6 "$new_lip6"; } || { [ -n "$new_rip6" ] && ! is_global_ipv6 "$new_rip6"; }; then
                   echo -e "  ${R}✖ Invalid IPv6 address. Nothing changed.${NC}"; sleep 2; continue
               fi
               xfrm_clear "$VX_NAME"
               [ -n "$new_lip6" ] && set_conf_var "$SELECTED_CONF" LOCAL_PUB6 "$new_lip6"
               [ -n "$new_rip6" ] && set_conf_var "$SELECTED_CONF" REMOTE_PUB6 "$new_rip6"
               [ -n "$new_rv4" ] && set_conf_var "$SELECTED_CONF" REMOTE_V4 "$new_rv4"
           else
               echo -ne "  ${C}●${NC} ${W}New Local Public IP [Current: ${Y}${LOCAL_PUB}${W}, Enter to skip]: ${NC}"; read -r new_lip
               echo -ne "  ${C}●${NC} ${W}New Remote Public IP [Current: ${Y}${REMOTE_PUB}${W}, Enter to skip]: ${NC}"; read -r new_rip
               new_lip=$(echo "$new_lip" | tr -dc '0-9.')
               new_rip=$(echo "$new_rip" | tr -dc '0-9.')
               if { [ -n "$new_lip" ] && ! is_ipv4 "$new_lip"; } || { [ -n "$new_rip" ] && ! is_ipv4 "$new_rip"; }; then
                   echo -e "  ${R}✖ Invalid IPv4 address. Nothing changed.${NC}"; sleep 2; continue
               fi
               xfrm_clear "$VX_NAME"
               [ -n "$new_lip" ] && set_conf_var "$SELECTED_CONF" LOCAL_PUB "$new_lip"
               [ -n "$new_rip" ] && set_conf_var "$SELECTED_CONF" REMOTE_PUB "$new_rip"
           fi
           apply_fabric "$SELECTED_CONF"
           echo -e "  ${G}● Public IPs updated and applied.${NC}"; sleep 1.5 ;;

        9)
           select_fabric_interactive || continue
           draw_mxlan_header
           TUN_SECRET=""; VX_NAME=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Master Secret Token (Regenerates VNI & Subnet): ${NC}"; read -r new_tok
           new_tok=$(echo "$new_tok" | tr -dc 'a-zA-Z0-9_=-')
           if [ -n "$new_tok" ]; then
               hash_c=$(echo -n "core_${new_tok}" | sha256sum)
               new_vni=$(( 16#${hash_c:0:6} ))
               [ "$new_vni" -eq 0 ] && new_vni=1

               class_selector=$(( 16#${hash_c:6:2} % 3 ))
               c1=""; c2=""; c3=""
               if [ "$class_selector" == "0" ]; then c1="10"; c2=$(( (16#${hash_c:8:2} % 254) + 1 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
               elif [ "$class_selector" == "1" ]; then c1="172"; c2=$(( (16#${hash_c:8:2} % 16) + 16 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
               else c1="192"; c2="168"; c3=$(( (16#${hash_c:10:2} % 254) + 1 )); fi
               new_core_sub="${c1}.${c2}.${c3}"
               
               if grep -q "^VNI_ID=$new_vni$" "$CONF_DIR"/*.conf 2>/dev/null || subnet_in_use "$new_core_sub" "$SELECTED_CONF"; then
                   echo -e "  ${R}● Collision detected with an existing fabric! Please use a different Token.${NC}"; sleep 2; continue
               fi
               
               sed -i "s/^TUN_SECRET=.*/TUN_SECRET=$new_tok/" "$SELECTED_CONF"
               sed -i "s/^VNI_ID=.*/VNI_ID=$new_vni/" "$SELECTED_CONF"
               sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_core_sub/" "$SELECTED_CONF"
               sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$new_tok/" "$SELECTED_CONF"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● Token updated. VNI: ${new_vni}, Subnet: ${new_core_sub}.x${NC}"; sleep 1.8
           fi ;;

        10)
           select_fabric_interactive || continue
           draw_mxlan_header
           CORE_SUBNET=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Core Subnet Base (e.g. 10.88.5) [Current: ${Y}${CORE_SUBNET}${W}, Enter to skip]: ${NC}"; read -r new_sub
           new_sub=$(echo "$new_sub" | tr -dc '0-9.')
           if [ -n "$new_sub" ] && ! is_subnet3 "$new_sub"; then echo -e "  ${R}✖ Format must be X.Y.Z (e.g. 10.88.5).${NC}"; sleep 2; continue; fi
           if [ -n "$new_sub" ] && subnet_in_use "$new_sub" "$SELECTED_CONF"; then echo -e "  ${R}✖ ${new_sub}.x is already in use.${NC}"; sleep 2; continue; fi
           if [ -n "$new_sub" ]; then
               sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_sub/" "$SELECTED_CONF"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● Subnet base updated to ${new_sub}.x${NC}"; sleep 1.5
           fi ;;

        4)
           select_fabric_interactive || continue
           manage_port_forwarding "$SELECTED_CONF" ;;

        7)
           select_fabric_interactive || continue
           draw_mxlan_header
           VX_NAME=""; BR_NAME=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Fabric Suffix (Current: ${Y}$(get_pure_vx_name "$VX_NAME")${W}, Max 4-5 chars): ${NC}"; read -r new_suffix
           new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
           if [ -n "$new_suffix" ]; then
               new_vx_name="vx_${new_suffix}"; new_br_name="br_${new_suffix}"
               if [ ${#new_suffix} -gt 12 ]; then echo -e "  ${R}● Error: max 12 chars.${NC}"; sleep 1.5; continue; fi
               if [ -f "$CONF_DIR/${new_vx_name}.conf" ]; then
                   echo -e "  ${R}● Error: Fabric [${new_vx_name}] already exists!${NC}"; sleep 1.5; continue
               fi
               teardown_fabric "$SELECTED_CONF"
               sed -i "s/^VX_NAME=.*/VX_NAME=$new_vx_name/" "$SELECTED_CONF"
               sed -i "s/^BR_NAME=.*/BR_NAME=$new_br_name/" "$SELECTED_CONF"
               mv "$SELECTED_CONF" "$CONF_DIR/${new_vx_name}.conf"
               SELECTED_CONF="$CONF_DIR/${new_vx_name}.conf"
               apply_fabric "$SELECTED_CONF"
               echo -e "  ${G}● Fabric successfully renamed to: ${new_vx_name}${NC}"; sleep 1.5
           fi ;;

        5) show_tunnels_info ;;
        17) self_update_module ;;
        19) uninstall_mxlan ;;
        13) menu_encrypt ;;
        14) menu_guard ;;
        15) mt_run_tool mhealer --scope vxlan ;;
        18) menu_backup_restore ;;
        16) mt_run_tool mbbr --from-tunnel ;;
        12) show_live_monitor ;;
        0) break ;;
        11) menu_manual_mtu ;;
    esac
done
