#!/bin/bash
# --- MPaqet Modular Core (mpaqet.sh) | Raw Packet Tunnel Engine v12.0.3 ---
# [Features: Unified Flat Menu | First-Run Prompt | Port Collision Check | Signal-Safe Menu | Full Uninstaller]

MODULE_VERSION="13.0.0"

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
INSTALL_PATH="/usr/bin/mpaqet"
CONF_DIR="/etc/paqet"
SERVICE_DIR="/etc/systemd/system"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mpaqet" ] && rm -f "/usr/local/bin/mpaqet" 2>/dev/null

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null
rm -f "$SECURE_TMP/.mpaqet_in_menu" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    mt_install_files 755 "$0" "$INSTALL_PATH" || { echo "Cannot install module." >&2; exit 1; }
fi

is_newer_version() {   # is_newer_version REMOTE LOCAL -> true only if REMOTE > LOCAL
    [ -n "$1" ] && [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

is_valid_host() {
    mt_valid_host "$1" && [[ "$1" != *:* ]]
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

    touch "$SECURE_TMP/.mpaqet_in_menu"
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

    rm -f "$SECURE_TMP/.mpaqet_in_menu" 2>/dev/null
    printf -v "$__resultvar" '%s' "$buffer"
}

check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tunnels/mpaqet.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tunnels/mpaqet.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO-  --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO-  --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mpaqet_remote_ver"
}

update_watcher_loop() {
    while true; do
        check_update_bg
        if [ -f "$SECURE_TMP/.mpaqet_in_menu" ]; then
            kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
        fi
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
if [[ "${1:-}" != --* ]]; then update_watcher_loop & fi
WATCHER_PID=$!
trap 'kill "$WATCHER_PID" 2>/dev/null; rm -f "$SECURE_TMP/.mpaqet_in_menu" 2>/dev/null' EXIT

self_update_module() {
    local src_opt custom_url dl_url tmp_file confirm
    local rel_path="tunnels/mpaqet.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mpaqet_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mpaqet_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ "$remote_v" != "Unknown" ] && is_newer_version "$remote_v" "$MODULE_VERSION"; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA Update (MPaqet Engine) ]${NC}"
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

is_paqet_core_valid() {
    local candidate
    for candidate in /usr/local/bin/paqet /usr/bin/paqet; do
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

install_core_from_source() {
    local src_choice="$1" arch target dl_url kind=url
    arch=$(uname -m)
    case "$arch" in x86_64) target=amd64;; aarch64|arm64) target=arm64;; *) echo -e "  ${R}✖ Unsupported CPU architecture.${NC}"; return 1;; esac
    case "$src_choice" in
        1|2)
            local asset="paqet-linux-${target}-v1.0.0-alpha.21.tar.gz"
            dl_url="https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.21/$asset"
            [ "$src_choice" != 2 ] || dl_url="https://c107328.parspack.net/c107328/MTunnel/packages/$asset"
            ;;
        3) echo -ne "  ${C}● Enter Direct Link: ${NC}"; read -r dl_url; [ -n "$dl_url" ] || return 0;;
        4) dl_url="$LOCAL_DIR/packages/paqet"; kind=local;;
        *) return 0;;
    esac
    echo -e "  ${DIM}● Preparing MPaqet Core...${NC}"
    if mt_update_core "paqet" "mpaqet" "$dl_url" "$kind" "${EXPECTED_SHA256:-}"; then
        echo -e "  ${G}✔ MPaqet Core installed successfully.${NC}"
        echo -e "  ${DIM}● Previously active tunnels restarted.${NC}"
    else
        echo -e "  ${R}✖ Core update failed. Previous installation preserved.${NC}" >&2
        return 1
    fi
}

menu_install_core() {
    echo -e "\n  ${DIM}┌─[ INSTALL / UPDATE PAQET CORE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/paqet)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r\n ')

    [[ "$src_choice" =~ ^[1-4]$ ]] && install_core_from_source "$src_choice"
}

check_first_run_core() {
    if ! is_paqet_core_valid; then
        local first_prompt_flag="$CONF_DIR/.core_prompted"
        if [ ! -f "$first_prompt_flag" ]; then
            touch "$first_prompt_flag"
            clear
            echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${B}│${NC}   ${R}● Paqet Core binary is NOT installed on this machine!${NC}                   ${B}│${NC}"
            echo -e "  ${B}│${NC}   ${W}Would you like to install the Core binary now?${NC}                           ${B}│${NC}"
            echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
            echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
            echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages/paqet)${NC}"
            echo -e "  ${DIM}│${NC}"
            echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Skip for now${NC}\n"
            echo -ne "  ${C}Select Source ❯❯ ${NC}"; read init_opt
            init_opt=$(echo "$init_opt" | tr -d '\r ')
            if [[ "$init_opt" =~ ^[1-4]$ ]]; then
                install_core_from_source "$init_opt"
            fi
        fi
    fi
}

resolve_paqet_route() {
    local target="$1" route next_hop mac
    if ! mt_valid_ipv4 "$target"; then
        target=$(getent ahostsv4 "$target" 2>/dev/null | awk 'NR==1{print $1}')
        mt_valid_ipv4 "$target" || return 1
    fi
    route=$(ip -4 route get "$target" 2>/dev/null) || return 1
    PQ_ROUTE_IFACE=$(awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}' <<< "$route")
    PQ_ROUTE_SRC=$(awk '{for(i=1;i<NF;i++)if($i=="src"){print $(i+1);exit}}' <<< "$route")
    next_hop=$(awk '{for(i=1;i<NF;i++)if($i=="via"){print $(i+1);exit}}' <<< "$route")
    next_hop="${next_hop:-$target}"
    [ -n "$PQ_ROUTE_IFACE" ] && mt_valid_ipv4 "$PQ_ROUTE_SRC" || return 1
    mac=$(ip -4 neigh show to "$next_hop" dev "$PQ_ROUTE_IFACE" 2>/dev/null | awk '$0!~/FAILED|INCOMPLETE/{for(i=1;i<NF;i++)if($i=="lladdr"){print $(i+1);exit}}')
    if [ -z "$mac" ]; then
        ping -I "$PQ_ROUTE_IFACE" -c 1 -W 1 "$next_hop" >/dev/null 2>&1 || true
        mac=$(ip -4 neigh show to "$next_hop" dev "$PQ_ROUTE_IFACE" 2>/dev/null | awk '$0!~/FAILED|INCOMPLETE/{for(i=1;i<NF;i++)if($i=="lladdr"){print $(i+1);exit}}')
    fi
    if [[ ! "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ || "$mac" == 00:00:00:00:00:00 ]]; then
        echo -ne "  ${C}●${NC} ${W}MAC of next hop $next_hop on $PQ_ROUTE_IFACE: ${NC}"; read -r mac
    fi
    [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ && "$mac" != 00:00:00:00:00:00 ]] || return 1
    PQ_ROUTE_MAC="$mac"; PQ_ROUTE_TARGET="$target"
}

paqet_port_available() {
    local port="$1" skip="${2:-}" conf role link ports
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        [ "$(basename "$conf" .meta)" != "$skip" ] || continue
        role=$(sed -n 's/^ROLE=//p' "$conf")
        link=$(sed -n 's/^TUN_PORT=//p' "$conf")
        ports=$(sed -n 's/^TCP_PORTS=//p' "$conf")
        if [ "$role" == 1 ] && [ "$link" == "$port" ]; then return 1; fi
        mt_list_has_port "$ports" "$port" && return 1
    done
    return 0
}

validate_paqet_ports() {
    local list="$1" skip="${2:-}" owned='' p; local -a parts=()
    [ -z "$skip" ] || owned=$(sed -n 's/^TCP_PORTS=//p' "$CONF_DIR/$skip.meta" 2>/dev/null)
    [ -n "$list" ] && mt_validate_port_list "$list" 1 tcp "$owned" || return 1
    IFS=, read -ra parts <<< "$list"
    for p in "${parts[@]}"; do paqet_port_available "$p" "$skip" || return 1; done
}

setup_paqet_counters() {
    local name="$1"; local l_port="$2"
    iptables -t mangle -C INPUT -p tcp --dport "$l_port" -m comment --comment "MPAQET_RX_${name}" >/dev/null 2>&1 || iptables -t mangle -A INPUT -p tcp --dport "$l_port" -m comment --comment "MPAQET_RX_${name}" 2>/dev/null
    iptables -t mangle -C OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_TX_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -p tcp --sport "$l_port" -m comment --comment "MPAQET_TX_${name}" 2>/dev/null
    
    iptables -t raw -C PREROUTING -p tcp --dport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" >/dev/null 2>&1 || iptables -t raw -A PREROUTING -p tcp --dport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" 2>/dev/null
    iptables -t raw -C OUTPUT -p tcp --sport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" >/dev/null 2>&1 || iptables -t raw -A OUTPUT -p tcp --sport "$l_port" -j NOTRACK -m comment --comment "MPAQET_RAW_${name}" 2>/dev/null
    
    iptables -t mangle -C OUTPUT -p tcp --sport "$l_port" --tcp-flags RST RST -j DROP -m comment --comment "MPAQET_RST_${name}" >/dev/null 2>&1 || iptables -t mangle -A OUTPUT -p tcp --sport "$l_port" --tcp-flags RST RST -j DROP -m comment --comment "MPAQET_RST_${name}" 2>/dev/null
}

clean_paqet_counters() {
    local name="$1"
    local chain rulenum
    rm -f "$SECURE_TMP/.mpaqet_link_${name}" "$SECURE_TMP/.mpaqet_peer_${name}" 2>/dev/null
    for chain in INPUT OUTPUT; do
        while read -r rulenum; do
            [ -n "$rulenum" ] && iptables -t mangle -D "$chain" "$rulenum" 2>/dev/null
        done < <(iptables -t mangle -L "$chain" -n --line-numbers 2>/dev/null | grep -E "MPAQET_(RX|TX|RST|PEER|LINK)_${name}( |\*/)" | awk '{print $1}' | tac)
    done
    for chain in PREROUTING OUTPUT; do
        while read -r rulenum; do
            [ -n "$rulenum" ] && iptables -t raw -D "$chain" "$rulenum" 2>/dev/null
        done < <(iptables -t raw -L "$chain" -n --line-numbers 2>/dev/null | grep -E "MPAQET_RAW_${name}( |\*/)" | awk '{print $1}' | tac)
    done
}

zero_paqet_counters() {
    local name="$1" table chain tag num
    if [ -z "$name" ]; then
        local conf
        for conf in "$CONF_DIR"/*.meta; do [ -f "$conf" ] && zero_paqet_counters "$(basename "$conf" .meta)"; done
        return 0
    fi
    for table in mangle raw; do
        for chain in INPUT OUTPUT PREROUTING; do
            for tag in RX TX RAW RST PEER LINK; do
                while read -r num; do [ -n "$num" ] && iptables -w 5 -t "$table" -Z "$chain" "$num"; done < <(mt_tagged_rules iptables "$table" "$chain" "MPAQET_${tag}_${name}")
            done
        done
    done
}

# Extra iptables rules used only for detection (never drop or alter traffic):
#   server: xt_recent list of sources hitting the tunnel port  -> client IP
#   client: counter of packets coming from the server port      -> link liveness
setup_paqet_probe() {
    local name="$1" meta="$CONF_DIR/${name}.meta" role port
    [ -f "$meta" ] || return 0
    role=$(grep -m1 '^ROLE=' "$meta" | cut -d'=' -f2 | tr -d '"\r ')
    port=$(grep -m1 '^TUN_PORT=' "$meta" | cut -d'=' -f2 | tr -d '"\r ')
    [[ "$port" =~ ^[0-9]+$ ]] || return 0
    if [ "$role" = "1" ]; then
        iptables -t mangle -C INPUT -p tcp --dport "$port" -m recent --set --name "mpq_${name}" --rsource -m comment --comment "MPAQET_PEER_${name}" >/dev/null 2>&1 || \
        iptables -t mangle -A INPUT -p tcp --dport "$port" -m recent --set --name "mpq_${name}" --rsource -m comment --comment "MPAQET_PEER_${name}" >/dev/null 2>&1
    else
        iptables -t mangle -C INPUT -p tcp --sport "$port" -m comment --comment "MPAQET_LINK_${name}" >/dev/null 2>&1 || \
        iptables -t mangle -A INPUT -p tcp --sport "$port" -m comment --comment "MPAQET_LINK_${name}" >/dev/null 2>&1
    fi
    return 0
}

if [[ "$1" == "--apply" ]]; then
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        t_name=$(basename "$conf" .meta)
        ROLE=""; TUN_PORT=""; TCP_PORTS=""; source "$conf" 2>/dev/null
        
        if [ "$ROLE" == "1" ]; then
            setup_paqet_counters "$t_name" "$TUN_PORT"
        else
            if [ -n "$TCP_PORTS" ]; then
                IFS=',' read -ra P_ARR <<< "$TCP_PORTS"
                for p_clean in "${P_ARR[@]}"; do
                    if mt_valid_port "$p_clean"; then
                        setup_paqet_counters "$t_name" "$p_clean"
                    fi
                done
            fi
        fi
        setup_paqet_probe "$t_name"
    done
    exit 0
fi

get_paqet_rx() {
    local data; data=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null)
    mt_counter_sum "$data" "MPAQET_RX_$1"
}

get_paqet_tx() {
    local data; data=$(iptables -t mangle -L OUTPUT -v -n -x 2>/dev/null)
    mt_counter_sum "$data" "MPAQET_TX_$1"
}

# ================================================================
# KCP PROFILE ENGINE - official Paqet core, no custom binary, no python
# ================================================================
KCP_PROFILE="FAST"
KCP_MODE="fast"
KCP_CONN=2
KCP_MTU=1350
KCP_RCVWND=1024
KCP_SNDWND=1024
KCP_SMUXBUF=4194304
KCP_STREAMBUF=2097152
KCP_PCAP_SOCKBUF=8388608
KCP_TCPBUF=8192
KCP_UDPBUF=4096
KCP_NODELAY=1
KCP_WDELAY=false
KCP_ACKNODELAY=true
KCP_INTERVAL=20
KCP_RESEND=2
KCP_NOCONGESTION=1

cpu_cores() { local n; n=$(nproc 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || n=1; echo "$n"; }
cap_at() { local v="$1" m="$2"; [ "$v" -gt "$m" ] && v="$m"; echo "$v"; }

# CPU cost of a raw-packet KCP tunnel is per PACKET, not per megabit, and every extra conn adds a
# session (timers, buffers, crypto). So the profiles below (a) batch writes/acks (wdelay=true,
# acknodelay=false => fewer small packets), (b) keep conn close to the CPU core count of THIS machine
# and (c) never touch the MTU (KCP_MTU empty = keep the tunnel's current MTU, clamped to the NIC).
# They are written as explicit KCP values (mode "manual"), so every number really takes effect.
# smuxbuf follows the rule from the paqet tuning guide: >= 2 x streambuf x conn.
profile_defaults() {
    local profile="${1^^}" role="${2:-client}" cores
    cores=$(cpu_cores)
    KCP_PROFILE="$profile"; KCP_MTU=""
    KCP_MODE=manual; KCP_NODELAY=0; KCP_WDELAY=true; KCP_ACKNODELAY=false
    KCP_INTERVAL=30; KCP_RESEND=2; KCP_NOCONGESTION=1
    KCP_RCVWND=1024; KCP_SNDWND=1024; KCP_STREAMBUF=2097152
    KCP_PCAP_SOCKBUF=8388608; KCP_TCPBUF=8192; KCP_UDPBUF=4096
    case "$profile" in
        ECO)      KCP_CONN=1; KCP_INTERVAL=50 ;;
        BALANCED) KCP_CONN=$(cap_at "$cores" 2) ;;
        SPEED)    KCP_CONN=$(cap_at "$cores" 4); KCP_NODELAY=1; KCP_INTERVAL=20
                  KCP_RCVWND=2048; KCP_SNDWND=2048; KCP_STREAMBUF=4194304; KCP_PCAP_SOCKBUF=16777216; KCP_TCPBUF=16384; KCP_UDPBUF=8192 ;;
        LATENCY)  KCP_CONN=$(cap_at "$cores" 2); KCP_NODELAY=1; KCP_INTERVAL=10; KCP_WDELAY=false; KCP_ACKNODELAY=true ;;
        # EXTREME: 300+ Mbit on 4+ cores. conn follows the cores (max 8), windows 4096, and buffers sized as in
        # the paqet tuning guide (streambuf 8MB, smuxbuf = 2 x stream x conn: 64MB at 4 conn, 128MB at 8).
        EXTREME)  KCP_CONN=$(cap_at "$cores" 8); [ "$KCP_CONN" -lt 2 ] && KCP_CONN=2
                  KCP_NODELAY=1; KCP_INTERVAL=20; KCP_RCVWND=4096; KCP_SNDWND=4096
                  KCP_STREAMBUF=8388608; KCP_PCAP_SOCKBUF=33554432; KCP_TCPBUF=65536; KCP_UDPBUF=16384 ;;
        # classic paqet built-in modes (only the four kcptun timers change)
        NORMAL)   KCP_MODE=normal; KCP_CONN=1; KCP_RCVWND=512; KCP_SNDWND=512
                  [ "$role" = "server" ] && { KCP_RCVWND=1024; KCP_SNDWND=1024; } ;;
        FAST)     KCP_MODE=fast;  KCP_CONN=$(cap_at "$cores" 2) ;;
        FAST2)    KCP_MODE=fast2; KCP_CONN=$(cap_at "$cores" 4) ;;
        FAST3)    KCP_MODE=fast3; KCP_CONN=$(cap_at "$cores" 4); KCP_PCAP_SOCKBUF=16777216 ;;
        MANUAL|CUSTOM) KCP_MODE=manual; KCP_CONN=$(cap_at "$cores" 2) ;;
        *) profile_defaults BALANCED "$role"; return 0 ;;
    esac
    KCP_SMUXBUF=$((KCP_STREAMBUF * 2 * KCP_CONN))
    return 0
}

kcp_nic_mtu() {
    local iface; iface=$(get_yaml_value interface "$1")
    [ -n "$iface" ] && cat "${SYS_NET_DIR:-/sys/class/net}/$iface/mtu" 2>/dev/null
}
# Highest KCP MTU the network interface can carry (NIC MTU minus IP/TCP headers and a safety margin).
kcp_mtu_cap() {
    local nic c; nic=$(kcp_nic_mtu "$1")
    [[ "$nic" =~ ^[0-9]+$ ]] || return 0
    c=$((nic - 100)); [ "$c" -lt 576 ] && c=576
    echo "$c"
}

get_yaml_value() {
    local key="$1" file="$2"
    awk -v k="$key" '$1 == k":" {gsub(/"/,"",$2); print $2; exit}' "$file" 2>/dev/null
}

get_tunnel_profile() {
    local t_name="$1" meta="$CONF_DIR/${t_name}.meta" yaml="$CONF_DIR/${t_name}.yaml" p mode
    [ -f "$meta" ] && p=$(grep -m1 '^PROFILE=' "$meta" | cut -d'=' -f2 | tr -d '\r" ')
    if [ -z "$p" ] && [ -f "$yaml" ]; then
        mode=$(get_yaml_value mode "$yaml")
        case "$mode" in normal) p=NORMAL;; fast) p=FAST;; fast2) p=FAST2;; fast3) p=FAST3;; manual) p=MANUAL;; *) p=CUSTOM;; esac
    fi
    echo "${p:-CUSTOM}"
}

set_meta_profile() {
    local t_name="$1" profile="$2" meta="$CONF_DIR/${t_name}.meta"
    [ ! -f "$meta" ] && return 0
    if grep -q '^PROFILE=' "$meta"; then sed -i "s/^PROFILE=.*/PROFILE=$profile/" "$meta"; else echo "PROFILE=$profile" >> "$meta"; fi
}

# A hand edit (MTU / conn) of a preset makes it a custom profile, so the label never lies.
mark_profile_custom() {
    local t_name="$1"
    case "$(get_tunnel_profile "$t_name")" in ECO|BALANCED|SPEED|LATENCY|EXTREME|NORMAL|FAST|FAST2|FAST3) set_meta_profile "$t_name" CUSTOM ;; esac
}

ask_int() {   # ask_int VAR "label" default min max
    local __v="$1" label="$2" def="$3" min="$4" max="$5" ans
    while true; do
        read -rp "  ${label} [${def}] (${min}-${max}): " ans || return 1
        ans="${ans:-$def}"
        if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge "$min" ] && [ "$ans" -le "$max" ]; then
            printf -v "$__v" '%s' "$ans"; return 0
        fi
        echo -e "  ${R}✖ Enter a whole number between ${min} and ${max}.${NC}"
    done
}

ask_bool() {  # ask_bool VAR "label" default(true|false)
    local __v="$1" label="$2" def="$3" ans
    while true; do
        read -rp "  ${label} [${def}] (true/false): " ans || return 1
        ans="${ans:-$def}"; ans="${ans,,}"
        if [ "$ans" = "true" ] || [ "$ans" = "false" ]; then printf -v "$__v" '%s' "$ans"; return 0; fi
        echo -e "  ${R}✖ Type true or false.${NC}"
    done
}

choose_kcp_profile() {
    local role="$1" current="${2:-BALANCED}" choice sub cores
    cores=$(cpu_cores)
    mt_workspace_screen
    echo -e "\n  ${B}╭──────────────────────── KCP PROFILE ────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}CPU-aware presets. MTU is never changed by a profile.${NC}"
    echo -e "  ${B}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC} ${G}1${NC}) ECO         lowest CPU: 1 conn, slow timers, batched"
    echo -e "  ${B}│${NC} ${C}2${NC}) BALANCED    default: up to 2 conn, batched writes/acks"
    echo -e "  ${B}│${NC} ${Y}3${NC}) SPEED       up to 4 conn, window 2048, fast timers"
    echo -e "  ${B}│${NC} ${M}4${NC}) LOW-LATENCY fastest timers, immediate flush (more CPU)"
    echo -e "  ${B}│${NC} ${W}5${NC}) MANUAL      every KCP value by hand (validated)"
    echo -e "  ${B}│${NC} ${W}6${NC}) CLASSIC     paqet built-in normal / fast / fast2 / fast3"
    echo -e "  ${B}│${NC} ${R}7${NC}) EXTREME     300+ Mbit: needs 4+ cores and 2GB+ RAM, window 4096"
    echo -e "  ${B}│${NC} ${DIM}Current: ${current}   |   CPU cores on this server: ${cores}${NC}"
    echo -e "  ${B}╰─────────────────────────────────────────────────────────────╯${NC}"
    echo -e "  ${DIM}Apply the profile on BOTH servers. conn is capped by this server's cores.${NC}"
    echo -ne "  ${C}Profile ❯❯ ${NC}"; read choice
    case "$choice" in
        1) profile_defaults ECO "$role";;
        2) profile_defaults BALANCED "$role";;
        3) profile_defaults SPEED "$role";;
        4) profile_defaults LATENCY "$role";;
        6)
            echo -ne "  ${C}1) normal  2) fast  3) fast2  4) fast3  ❯❯ ${NC}"; read sub
            case "$sub" in 1) profile_defaults NORMAL "$role";; 2) profile_defaults FAST "$role";;
                           3) profile_defaults FAST2 "$role";; 4) profile_defaults FAST3 "$role";; *) return 1;; esac ;;
        5)
            profile_defaults MANUAL "$role"
            ask_int  KCP_NODELAY      "nodelay (0=off 1=on)"        0        0 1 || return 1
            ask_bool KCP_WDELAY       "wdelay (true = batch writes, less CPU)"   true  || return 1
            ask_bool KCP_ACKNODELAY   "acknodelay (false = batch acks, less CPU)" false || return 1
            ask_int  KCP_INTERVAL     "interval ms"                  30       10 5000 || return 1
            ask_int  KCP_RESEND       "resend"                       2         0 2 || return 1
            ask_int  KCP_NOCONGESTION "nocongestion (0=off 1=on)"    1         0 1 || return 1
            local mtu_in
            read -rp "  MTU (Enter = keep current) (576-1500): " mtu_in || return 1
            if [ -n "$mtu_in" ]; then
                if [[ "$mtu_in" =~ ^[0-9]+$ ]] && [ "$mtu_in" -ge 576 ] && [ "$mtu_in" -le 1500 ]; then KCP_MTU="$mtu_in"
                else echo -e "  ${R}✖ Invalid MTU - keeping the current one.${NC}"; fi
            fi
            ask_int  KCP_RCVWND       "Receive window"               1024    128 32768 || return 1
            ask_int  KCP_SNDWND       "Send window"                  1024    128 32768 || return 1
            ask_int  KCP_CONN         "Connections (about = CPU cores)" "$KCP_CONN" 1 32 || return 1
            ask_int  KCP_STREAMBUF    "Stream buffer"                2097152 65536 134217728 || return 1
            KCP_SMUXBUF=$((KCP_STREAMBUF * 2 * KCP_CONN))
            ask_int  KCP_SMUXBUF      "SMUX buffer (>= 2 x stream x conn)" "$KCP_SMUXBUF" 65536 268435456 || return 1
            ask_int  KCP_PCAP_SOCKBUF "PCAP sockbuf"                 8388608 65536 268435456 || return 1
            ask_int  KCP_TCPBUF       "TCP buffer"                   8192     1024 1048576 || return 1
            ask_int  KCP_UDPBUF       "UDP buffer"                   4096     1024 1048576 || return 1
            KCP_PROFILE=MANUAL
            ;;
        7)
            if [ "$cores" -lt 4 ]; then
                echo -e "  ${Y}⚠ This server has only ${cores} core(s). EXTREME is meant for 4+ cores; SPEED is safer here.${NC}"
                local go; read -rp "  Use EXTREME anyway? [y/N]: " go
                [[ "${go,,}" == "y" ]] || return 1
            fi
            profile_defaults EXTREME "$role" ;;
        *) return 1;;
    esac
    return 0
}

# Rewrites conn/tcpbuf/udpbuf, network.pcap.sockbuf and the whole kcp: block from the KCP_* globals.
# Pure awk (no python). Unknown keys inside kcp:/pcap: (dshard, pshard, smuxkalive ...) are kept.
# The result is read back and verified; on any failure the original file is left untouched and 1 is returned.
write_kcp_settings() {
    local yaml="$1" key="$2" block="$3"
    local tmp="${yaml}.kcp.new" bak="$SECURE_TMP/$(basename "$yaml").bak"

    if [ ! -f "$yaml" ] || [ -z "$key" ] || [ -z "$block" ]; then
        echo -e "  ${R}✖ Config, key or cipher not found - nothing was changed.${NC}"; return 1
    fi
    cp -f "$yaml" "$bak" 2>/dev/null

    # MTU: a preset never overrides it (empty = keep); anything above the NIC limit is lowered.
    local cur_mtu cap
    cur_mtu=$(get_yaml_value mtu "$yaml"); [[ "$cur_mtu" =~ ^[0-9]+$ ]] || cur_mtu=1350
    [ -z "$KCP_MTU" ] && KCP_MTU="$cur_mtu"
    cap=$(kcp_mtu_cap "$yaml")
    if [ -n "$cap" ] && [ "$KCP_MTU" -gt "$cap" ]; then
        echo -e "  ${Y}⚠ MTU ${KCP_MTU} is above what this interface can send (NIC MTU $(kcp_nic_mtu "$yaml")); using ${cap}.${NC}"
        KCP_MTU="$cap"
    fi

    awk -v mode="$KCP_MODE" -v conn="$KCP_CONN" -v mtu="$KCP_MTU" -v rcv="$KCP_RCVWND" -v snd="$KCP_SNDWND" \
        -v smux="$KCP_SMUXBUF" -v stream="$KCP_STREAMBUF" -v pcap="$KCP_PCAP_SOCKBUF" \
        -v tcpbuf="$KCP_TCPBUF" -v udpbuf="$KCP_UDPBUF" -v nodelay="$KCP_NODELAY" -v wdelay="$KCP_WDELAY" \
        -v ack="$KCP_ACKNODELAY" -v interval="$KCP_INTERVAL" -v resend="$KCP_RESEND" -v nc="$KCP_NOCONGESTION" \
        -v key="$key" -v block="$block" '
    BEGIN {
        n = split("key mode block mtu rcvwnd sndwnd smuxbuf streambuf nodelay wdelay acknodelay interval resend nocongestion", m, " ")
        for (i = 1; i <= n; i++) managed[m[i]] = 1
        sec = ""; in_drop = 0
    }
    function emit_network() {
        print "  pcap:"; print "    sockbuf: " pcap
        printf "%s", pcap_extra
    }
    function emit_transport() {
        print "  conn: " conn; print "  tcpbuf: " tcpbuf; print "  udpbuf: " udpbuf
        print "  kcp:"
        print "    key: \"" key "\""; print "    mode: \"" mode "\""; print "    block: \"" block "\""
        print "    mtu: " mtu; print "    rcvwnd: " rcv; print "    sndwnd: " snd
        print "    smuxbuf: " smux; print "    streambuf: " stream
        if (mode == "manual") {
            print "    nodelay: " nodelay; print "    wdelay: " wdelay; print "    acknodelay: " ack
            print "    interval: " interval; print "    resend: " resend; print "    nocongestion: " nc
        }
        printf "%s", kcp_extra
    }
    function leave_section() {
        if (sec == "network") emit_network()
        else if (sec == "transport") emit_transport()
        sec = ""; in_drop = 0
    }
    {
        line = $0
        if (line ~ /^[A-Za-z_]/) {
            leave_section()
            name = line; sub(/:.*/, "", name)
            if (name == "network" || name == "transport") { sec = name; seen[name] = 1 }
            print line; next
        }
        if (sec == "network" || sec == "transport") {
            if (line ~ /^  [A-Za-z_]/) {
                child = line; sub(/^  /, "", child); sub(/:.*/, "", child)
                if (sec == "network" && child == "pcap") { in_drop = 1; drop_child = child; next }
                if (sec == "transport" && (child == "conn" || child == "tcpbuf" || child == "udpbuf" || child == "kcp")) { in_drop = 1; drop_child = child; next }
                in_drop = 0; print line; next
            }
            if (in_drop) {
                if (line ~ /^    [A-Za-z_]/) {
                    ck = line; sub(/^    /, "", ck); sub(/:.*/, "", ck)
                    if (sec == "network" && drop_child == "pcap") {
                        if (ck != "sockbuf") pcap_extra = pcap_extra line "\n"
                    } else if (sec == "transport" && drop_child == "kcp") {
                        if (!(ck in managed)) kcp_extra = kcp_extra line "\n"
                    }
                }
                next
            }
        }
        print line
    }
    END {
        leave_section()
        if (!seen["network"] || !seen["transport"]) exit 2
    }' "$yaml" > "$tmp" 2>/dev/null
    local rc=$?

    local ok=1
    [ "$rc" -eq 0 ] && [ -s "$tmp" ] && grep -q '^role:' "$tmp" || ok=0
    if [ "$ok" -eq 1 ]; then
        [ "$(get_yaml_value mode "$tmp")"    = "$KCP_MODE" ]        || ok=0
        [ "$(get_yaml_value conn "$tmp")"    = "$KCP_CONN" ]        || ok=0
        [ "$(get_yaml_value mtu "$tmp")"     = "$KCP_MTU" ]         || ok=0
        [ "$(get_yaml_value rcvwnd "$tmp")"  = "$KCP_RCVWND" ]      || ok=0
        [ "$(get_yaml_value sndwnd "$tmp")"  = "$KCP_SNDWND" ]      || ok=0
        [ "$(get_yaml_value sockbuf "$tmp")" = "$KCP_PCAP_SOCKBUF" ] || ok=0
        [ "$(get_yaml_value key "$tmp")"     = "$key" ]             || ok=0
        [ "$(get_yaml_value block "$tmp")"   = "$block" ]           || ok=0
        if [ "$KCP_MODE" = "manual" ]; then
            [ "$(get_yaml_value interval "$tmp")" = "$KCP_INTERVAL" ] || ok=0
            [ "$(get_yaml_value nodelay "$tmp")"  = "$KCP_NODELAY" ]  || ok=0
        elif grep -qE '^    (nodelay|interval|resend|nocongestion|wdelay|acknodelay):' "$tmp"; then
            ok=0
        fi
    fi

    if [ "$ok" -ne 1 ]; then
        rm -f "$tmp"
        echo -e "  ${R}✖ Could not write the profile safely - config left unchanged (backup: $bak).${NC}"
        return 1
    fi
    mv -f "$tmp" "$yaml"
    return 0
}


# ================================================================
# CONNECTION / PEER DETECTION
# paqet talks through raw sockets, so the kernel has no TCP session and `ss ... ESTAB`
# is always empty. Liveness is measured from iptables packet counters instead:
#   server -> packets arriving on the tunnel port (MPAQET_RX_<name>)
#   client -> packets arriving FROM the server port (MPAQET_LINK_<name>, created by setup_paqet_probe)
# ONLINE means that counter grew since the previous sample.
# ================================================================
get_link_pkts() {
    local name="$1" role="$2" tag out
    if [ "$role" = "1" ]; then tag="MPAQET_RX_${name} */"; else tag="MPAQET_LINK_${name} */"; fi
    out=$(iptables -t mangle -L INPUT -v -n -x 2>/dev/null | grep -F "$tag")
    if [ -z "$out" ]; then
        [ "$role" != "1" ] && setup_paqet_probe "$name"
        echo 0; return 0
    fi
    echo "$out" | awk '{s+=$1} END {print s+0}'
}

# Fallback only (first sample / counters were zeroed): last connection event in the service log.
log_link_verdict() {
    local last
    last=$(journalctl -u "mpaqet@${1}" -n 200 --no-pager 2>/dev/null | grep -Ei 'established|connection lost|retrying|failed to connect|connection closed|broken pipe' | tail -n 1)
    echo "$last" | grep -qi 'established' && echo "ONLINE"
    return 0
}

# Client IP as seen by the server: the xt_recent list filled by the MPAQET_PEER rule.
# The busiest source in the last interval wins (scanner noise sends few packets); the list is
# cleared after each read and the last answer is cached.
get_server_peer_ip() {
    local name="$1" dir="${XT_RECENT_DIR:-/proc/net/xt_recent}" f cache best
    f="$dir/mpq_${name}"; cache="$SECURE_TMP/.mpaqet_peer_${name}"
    [ -e "$f" ] || setup_paqet_probe "$name"
    if [ -r "$f" ]; then
        best=$(awk '
            { ip = ""; p = 0; ls = 0
              for (i = 1; i <= NF; i++) {
                  if ($i ~ /^src=/) ip = substr($i, 5)
                  if ($i == "oldest_pkt:") p = i
                  if ($i == "last_seen:") ls = $(i + 1)
              }
              if (ip == "" || p == 0) next
              n = NF - (p + 1)
              if (n > bn || (n == bn && ls + 0 > bl + 0)) { bn = n; bl = ls; bip = ip }
            }
            END { if (bip != "") print bip }' "$f" 2>/dev/null)
        if [[ "$best" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
            echo "$best" > "$cache"
            echo / > "$f" 2>/dev/null
        fi
    fi
    [ -s "$cache" ] && cat "$cache"
    return 0
}

# Known failure modes are read from the service log of the last 45 seconds:
#   "send: Message too large"  -> MTU above what the NIC can send  (state MTU-ERR)
#   5+ other [ERROR] lines     -> streams failing                  (state ERRORS)
apply_log_health() {
    local name="$1" v="$2" log mtu_n err_n
    log=$(journalctl -u "mpaqet@${name}" --since "45 seconds ago" --no-pager 2>/dev/null)
    mtu_n=$(printf '%s\n' "$log" | grep -c 'Message too large')
    err_n=$(printf '%s\n' "$log" | grep -c '\[ERROR\]')
    if [ "$mtu_n" -ge 3 ]; then echo "MTU-ERR"; elif [ "$err_n" -ge 5 ]; then echo "ERRORS"; else echo "$v"; fi
}

check_paqet_connection() {
    local t_name="$1" known_active="${2:-0}"
    local meta="$CONF_DIR/${t_name}.meta"
    [ ! -f "$meta" ] && { echo "OFFLINE"; return; }
    if [ "$known_active" != "1" ] && ! systemctl is-active --quiet "mpaqet@${t_name}" 2>/dev/null; then echo "OFFLINE"; return; fi

    local ROLE idle sf now cur p_pk="" p_ts="" p_v="" age verdict
    ROLE=$(grep -m1 '^ROLE=' "$meta" | cut -d'=' -f2 | tr -d '"\r ')
    idle="CONNECTING"; [ "$ROLE" = "1" ] && idle="WAITING"
    sf="$SECURE_TMP/.mpaqet_link_${t_name}"
    now=$(date +%s); cur=$(get_link_pkts "$t_name" "$ROLE")
    [ -f "$sf" ] && read -r p_pk p_ts p_v < "$sf"

    if [[ "$p_pk" =~ ^[0-9]+$ && "$p_ts" =~ ^[0-9]+$ ]]; then
        age=$((now - p_ts))
        if [ "$age" -lt 3 ] && [ -n "$p_v" ]; then echo "$p_v"; return; fi
        if [ "$age" -le 180 ] && [ "$cur" -ge "$p_pk" ]; then
            if [ "$cur" -gt "$p_pk" ]; then verdict="ONLINE"; else verdict="$idle"; fi
            verdict=$(apply_log_health "$t_name" "$verdict")
            echo "$cur $now $verdict" > "$sf"; echo "$verdict"; return
        fi
    fi
    verdict=$(log_link_verdict "$t_name"); verdict="${verdict:-$idle}"
    verdict=$(apply_log_health "$t_name" "$verdict")
    echo "$cur $now $verdict" > "$sf"; echo "$verdict"
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
        local tcp_rtt=$(ss -nti | grep -A 1 "$target_ip" | grep -oP 'rtt:\K[0-9.]+' | head -n 1)
        if [ -n "$tcp_rtt" ]; then
            local rounded_rtt=$(echo "$tcp_rtt" | awk '{print int($1+0.5)}')
            echo "${rounded_rtt}ms*"
            return
        fi
    fi

    if [ -n "$port" ] && [[ "$port" =~ ^[0-9]+$ ]]; then
        local start_ts=$(date +%s%3N 2>/dev/null)
        if timeout 1 bash -c "</dev/tcp/$target_ip/$port" 2>/dev/null; then
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

draw_header() {
    local s_ip=$(get_local_ip); local total_tunnels=0; local online_tunnels=0; local active_t=0; local mtu_err_t=0; local err_t=0
    local t_names=() units=()
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            local t_name=$(basename "$conf" .meta)
            t_names+=("$t_name"); units+=("mpaqet@$t_name")
        fi
    done
    total_tunnels=${#t_names[@]}
    if [ "$total_tunnels" -gt 0 ]; then
        local states=() i=0
        while IFS= read -r st_line; do states+=("$st_line"); done < <(systemctl is-active "${units[@]}" 2>/dev/null)
        for t_name in "${t_names[@]}"; do
            if [ "${states[$i]}" == "active" ]; then
                ((active_t++))
                local st=$(check_paqet_connection "$t_name" "1")
                [ "$st" == "ONLINE" ] && ((online_tunnels++))
                [ "$st" == "MTU-ERR" ] && ((mtu_err_t++))
                [ "$st" == "ERRORS" ] && ((err_t++))
            fi
            ((i++))
        done
    fi
    
    local core_color="${R}"; local core_raw="Not Installed"
    if is_paqet_core_valid; then
        core_color="${G}"; core_raw="Installed"
    fi

    local act_color="${DIM}"; local act_text="0/0"
    if [ "$total_tunnels" -gt 0 ]; then
        act_text="${active_t}/${total_tunnels}"
        if [ "$active_t" -eq "$total_tunnels" ]; then act_color="${G}"
        elif [ "$active_t" -gt 0 ]; then act_color="${Y}"
        else act_color="${R}"; fi
    fi

    local stat_color="${R}"; local stat_icon="○"; local stat_text="STOPPED"
    if [ "$active_t" -gt 0 ]; then
        if [ "$mtu_err_t" -gt 0 ]; then
            stat_color="${R}"; stat_icon="✖"; stat_text="MTU ERROR"
        elif [ "$err_t" -gt 0 ]; then
            stat_color="${R}"; stat_icon="✖"; stat_text="ERRORS"
        elif [ "$online_tunnels" -eq "$active_t" ]; then 
            stat_color="${G}"; stat_icon="●"; stat_text="CONNECTED"
        elif [ "$online_tunnels" -gt 0 ]; then 
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
                local srv_peer=$(get_server_peer_ip "$(basename "$conf" .meta)")
                if [ -n "$srv_peer" ]; then
                    peer_ip="$srv_peer"
                    break
                fi
            fi
        fi
    done

    local g_color="${DIM}"; local g_text="N/A"
    if [ -n "$peer_ip" ]; then
        local ping_cache="$SECURE_TMP/.mpaqet_ping_cache"
        local ping_lock="$SECURE_TMP/.mpaqet_ping_lock"
        local now=$(date +%s)
        local cache_ts=0; [ -f "$ping_cache" ] && cache_ts=$(stat -c %Y "$ping_cache" 2>/dev/null || echo 0)
        local cache_age=$(( now - cache_ts ))

        if [ -f "$ping_cache" ] && [ "$cache_age" -lt 15 ]; then
            local p_val=$(cat "$ping_cache" 2>/dev/null)
            if [[ "$p_val" != "Timeout" && "$p_val" != "N/A" ]]; then
                local p_int=$(echo "$p_val" | tr -dc '0-9')
                if [ -z "$p_int" ]; then p_int=0; fi
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
                if [ -f "$SECURE_TMP/.mpaqet_in_menu" ]; then
                    kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
                fi
            ) &
        fi
    else
        g_color="${DIM}"; g_text="Waiting"
        [ "$online_tunnels" -gt 0 ] && g_text="N/A"
    fi

    local title=" MPaqet Engine v${MODULE_VERSION} "
    local full_str=" │${title}│ IP: ${s_ip} │ Core: ${core_raw} │ Peer Ping: ${g_text} │ ACTIVE: ${act_text} │ STATUS: ${stat_icon} ${stat_text} "
    local pad_len=$(( 126 - ${#full_str} ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    clear; echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${title}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${B}│${NC}${DIM} Core:${NC} ${core_color}${core_raw}${NC} ${B}│${NC}${DIM} Peer Ping:${NC} ${g_color}${g_text}${NC} ${B}│${NC}${DIM} ACTIVE:${NC} ${act_color}${act_text}${NC} ${B}│${NC}${DIM} STATUS:${NC} ${stat_color}${stat_icon} ${stat_text}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

setup_systemd_service() {
    local changed=false
    local tmp_srv="$SECURE_TMP/mpaqet_tpl.service"
    local tmp_app="$SECURE_TMP/mpaqet_apply.service"

    cat <<'EOF' > "$tmp_srv"
[Unit]
Description=MPaqet Raw Packet Tunnel (%i)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/paqet run -c /etc/paqet/%i.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    cat <<'EOF' > "$tmp_app"
[Unit]
Description=MPaqet Boot Restorer
After=network.target

[Service]
ExecStart=/usr/bin/mpaqet --apply
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    if ! cmp -s "$tmp_srv" "/etc/systemd/system/mpaqet@.service" 2>/dev/null; then
        mv -f "$tmp_srv" "/etc/systemd/system/mpaqet@.service"
        changed=true
    else
        rm -f "$tmp_srv"
    fi

    if ! cmp -s "$tmp_app" "/etc/systemd/system/mpaqet-apply.service" 2>/dev/null; then
        mv -f "$tmp_app" "/etc/systemd/system/mpaqet-apply.service"
        changed=true
    else
        rm -f "$tmp_app"
    fi

    if [ "$changed" = true ]; then
        systemctl daemon-reload
        systemctl enable mpaqet-apply.service >/dev/null 2>&1
    fi
}

show_tunnel_registry() {
    draw_header
    echo -e "\n  ${Y}● Tunnels Info And Specs:${NC}"
    local count=0
    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        ROLE=""; TUN_PORT=""; REMOTE_IP=""; TCP_PORTS=""
        source "$conf" 2>/dev/null
        
        local yaml_f="$CONF_DIR/${t_name}.yaml"
        [ ! -f "$yaml_f" ] && continue
        
        local key=$(grep "key:" "$yaml_f" | awk -F'"' '{print $2}')
        local mode=$(grep "mode:" "$yaml_f" | awk -F'"' '{print $2}')
        local block=$(grep "block:" "$yaml_f" | awk -F'"' '{print $2}')
        local mtu=$(grep "mtu:" "$yaml_f" | awk '{print $2}')
        local conn_c=$(grep "conn:" "$yaml_f" | head -1 | awk '{print $2}')
        
        local role_text=$([ "$ROLE" == "1" ] && echo "KHAREJ (Server)" || echo "IRAN (Client)")
        local ping_val="N/A"
        local connected_peer=""

        if [ "$ROLE" == "2" ] && [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "0.0.0.0" ]; then
            ping_val=$(get_peer_ping "$REMOTE_IP" "$TUN_PORT")
            connected_peer="$REMOTE_IP"
        elif [ "$ROLE" == "1" ]; then
            local p_ip=$(get_server_peer_ip "$t_name")
            if [ -n "$p_ip" ]; then
                ping_val=$(get_peer_ping "$p_ip" "$TUN_PORT")
                connected_peer="$p_ip"
            else
                ping_val="N/A"
            fi
        fi

        local peer_text=$([ "$ROLE" == "1" ] && echo "Listening on :${TUN_PORT}" || echo "${REMOTE_IP}:${TUN_PORT}")
        if [ "$ROLE" == "1" ] && [ -n "$connected_peer" ]; then
            peer_text="${connected_peer}:${TUN_PORT} (Active)"
        fi

        local st=$(check_paqet_connection "$t_name")
        local stat_icon="○"; local stat_text="OFFLINE"; local stat_color="${R}"
        if [ "$st" == "ONLINE" ]; then stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}";
        elif [ "$st" == "WAITING" ]; then stat_icon="◎"; stat_text="WAITING CLIENT"; stat_color="${Y}";
        elif [ "$st" == "CONNECTING" ]; then stat_icon="◎"; stat_text="CONNECTING..."; stat_color="${Y}";
        elif [ "$st" == "MTU-ERR" ]; then stat_icon="✖"; stat_text="MTU ERROR"; stat_color="${R}";
        elif [ "$st" == "ERRORS" ]; then stat_icon="✖"; stat_text="ERRORS"; stat_color="${R}"; fi

        local rx=$(get_paqet_rx "$t_name"); local tx=$(get_paqet_tx "$t_name")

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

        local l3="Secret Key   : ${key}"; local r3="Crypto: ${block^^}"
        local pad3=$(( 122 - ${#l3} - ${#r3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${Y}Secret Key   :${NC} ${W}${key}${NC}${sp3}${DIM}Crypto:${NC} ${C}${block^^}${NC} ${B}│${NC}"

        local l4="Traffic Usage: RX $(format_total $rx) / TX $(format_total $tx)"; local r4="Mode: ${mode^^} | MTU: ${mtu} | Conn: ${conn_c}"
        local pad4=$(( 122 - ${#l4} - ${#r4} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Traffic Usage:${NC} ${G}RX $(format_total $rx)${NC} ${DIM}/${NC} ${Y}TX $(format_total $tx)${NC}${sp4}${DIM}${r4}${NC} ${B}│${NC}"
        
        if [ "$ROLE" == "2" ]; then
            local p_str="${TCP_PORTS:0:100}"
            [ ${#TCP_PORTS} -gt 100 ] && p_str="${p_str}..."
            local l5="Port Mappings: ${p_str}"
            local pad5=$(( 122 - ${#l5} )); [ "$pad5" -lt 0 ] && pad5=0; local sp5=$(printf '%*s' "$pad5" "")
            echo -e "  ${B}│${NC} ${DIM}Port Mappings:${NC} ${Y}${p_str}${NC}${sp5} ${B}│${NC}"
        fi
        
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯\n"
        ((count++))
    done
    if [ "$count" -eq 0 ]; then echo -e "  ${R}● No tunnels configured yet!${NC}\n"; fi
    if [ "${1:-}" != --no-pause ]; then
        echo -ne "  ${DIM}Press Enter to return...${NC}"; read dummy
    fi
}

show_live_radar() {
    tput civis; clear
    declare -A rx_old tx_old sample_old

    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        rx_old[$t_name]=$(get_paqet_rx "$t_name")
        sample_old[$t_name]=$(mt_milliseconds)
        tx_old[$t_name]=$(get_paqet_tx "$t_name")
    done

    while true; do
        printf "\033[H"; draw_header
        echo -e "\n  ${DIM}┌─[ PAQET TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${B}╭──────────────────┬────────────┬──────────────┬──────────────┬──────────────┬──────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "TUNNEL NAME" "STATUS" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL RX" "∑ TOTAL TX"
        echo -e "  ${B}├──────────────────┼────────────┼──────────────┼──────────────┼──────────────┼──────────────┤${NC}"

        local count=0
        for conf in "$CONF_DIR"/*.meta; do
            [ ! -f "$conf" ] && continue
            local t_name=$(basename "$conf" .meta)
            local st=$(check_paqet_connection "$t_name")
            local st_color="${R}"; local st_text="OFFLINE"
            if [ "$st" == "ONLINE" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING";
            elif [ "$st" == "MTU-ERR" ]; then st_color="${R}"; st_text="MTU ERROR";
            elif [ "$st" == "ERRORS" ]; then st_color="${R}"; st_text="ERRORS"; fi

            local r_new=$(get_paqet_rx "$t_name"); local t_new=$(get_paqet_tx "$t_name")
            local r_prev=${rx_old[$t_name]:-$r_new}; local t_prev=${tx_old[$t_name]:-$t_new}
            local now_ms=$(mt_milliseconds) ms_diff; ms_diff=$((now_ms-${sample_old[$t_name]:-$now_ms}))
            local rx_s=$(mt_rate "$r_new" "$r_prev" "$ms_diff"); local tx_s=$(mt_rate "$t_new" "$t_prev" "$ms_diff")
            sample_old[$t_name]=$now_ms
            [ "$rx_s" -lt 0 ] && rx_s=0; [ "$tx_s" -lt 0 ] && tx_s=0
            rx_old[$t_name]=$r_new; tx_old[$t_name]=$t_new

            local c_rx="${DIM}"; [ "$rx_s" -gt 0 ] && c_rx="${G}"
            local c_tx="${DIM}"; [ "$tx_s" -gt 0 ] && c_tx="${Y}"

            printf "  ${B}│${NC} ${W}%-16s${NC} ${B}│${NC} %b%-10s%b ${B}│${NC} %b%-12s%b ${B}│${NC} %b%-12s%b ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC}\n" "$t_name" "$st_color" "$st_text" "$NC" "$c_rx" "$(format_speed $rx_s)" "$NC" "$c_tx" "$(format_speed $tx_s)" "$NC" "$(format_total $r_new)" "$(format_total $t_new)"
            ((count++))
        done

        if [ "$count" -eq 0 ]; then
            printf "  ${B}│${NC} ${DIM}%-86s${NC} ${B}│${NC}\n" "  No active Paqet tunnels configured."
        fi
        echo -e "  ${B}╰──────────────────┴────────────┴──────────────┴──────────────┴──────────────┴──────────────╯${NC}"
        printf "\033[J"
        mt_monitor_wait 1 || break
    done
    tput cnorm
}

select_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.yaml 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; fi

    echo -e "\n  ${B}╭────────────────── Select Tunnel to Manage ─────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .yaml)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r')
    mt_valid_index "$t_idx" "${#configs[@]}" || return 1
    t_idx=$((10#$t_idx))

    SELECTED_TUN="${configs[$t_idx]}"
    return 0
}

uninstall_mpaqet() {
    clear
    echo -e "\n  ${R}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${R}│${NC}   ${R}⚠ WARNING: COMPLETE PURGE & UNINSTALLATION OF MPAQET${NC}                   ${R}│${NC}"
    echo -e "  ${R}│${NC}   This will permanently stop and delete:                                   ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All active Paqet tunnels & systemd units                               ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All YAML configurations & metadata in /etc/paqet                       ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All raw & mangle iptables counters                                    ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● Paqet core binary (/usr/local/bin/paqet) & mpaqet module               ${R}│${NC}"
    echo -e "  ${R}╰────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    
    echo -ne "  ${Y}Are you sure you want to proceed? Type '${R}yes${Y}' to confirm: ${NC}"; read confirm
    confirm=$(echo "$confirm" | tr -d '\r ')
    
    if [ "$confirm" != "yes" ]; then
        echo -e "  ${G}● Uninstallation cancelled.${NC}"; sleep 1.5; return
    fi

    echo -e "\n  ${DIM}● [1/5] Stopping services & killing processes...${NC}"
    systemctl stop mpaqet@* mpaqet-apply.service 2>/dev/null
    systemctl disable mpaqet@* mpaqet-apply.service 2>/dev/null
    killall -9 paqet 2>/dev/null

    echo -e "  ${DIM}● [2/5] Purging raw & mangle iptables rules...${NC}"
    for tbl in mangle raw; do
        iptables -t $tbl -S 2>/dev/null | grep -E "MPAQET_" | sed 's/^-A /-D /' | while read -r r; do
            iptables -t $tbl $r 2>/dev/null
        done
    done

    echo -e "  ${DIM}● [3/5] Removing systemd unit files...${NC}"
    rm -f /etc/systemd/system/mpaqet@.service /etc/systemd/system/mpaqet-apply.service
    systemctl daemon-reload 2>/dev/null

    echo -e "  ${DIM}● [4/5] Deleting configurations & core binary...${NC}"
    rm -rf /etc/paqet "$SECURE_TMP/.mpaqet"* /usr/local/bin/paqet /usr/bin/paqet

    echo -e "  ${DIM}● [5/5] Removing mpaqet wrapper script...${NC}"
    rm -f "$INSTALL_PATH" 2>/dev/null
    [ -f "$0" ] && rm -f "$0" 2>/dev/null

    echo -e "\n  ${G}✔ MPaqet ecosystem has been completely eradicated from this system.${NC}\n"
    exit 0
}

check_first_run_core
setup_systemd_service

show_tunnels_info() {
    mt_tunnels_info_menu paqet draw_header show_tunnel_registry show_tunnel_logs
}

show_tunnel_logs() {
    select_tunnel || return 0
    local t_name int_trap
    t_name=$(basename "$SELECTED_TUN" .yaml)
    draw_header
    echo -e "\n  ${DIM}● Live logs for ${W}${t_name}${NC} ${DIM}(Ctrl+C to return)${NC}\n"
    int_trap=$(trap -p INT)
    trap ':' INT
    journalctl -u "mpaqet@${t_name}" -n 50 -f
    if [ -n "$int_trap" ]; then eval "$int_trap"; else trap - INT; fi
}

# BEGIN MTUNNEL WORKSPACE V13
# Embedded in each module: no external library or sourced setup-link code.
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
mt_link_encode() {
    mt_link_validate || return 1
    local raw encoded checksum key
    raw=$(for key in "${!MT_LINK_DATA[@]}"; do printf '%s=%s\n' "$key" "${MT_LINK_DATA[$key]}"; done | LC_ALL=C sort)
    encoded=$(printf '%s' "$raw" | base64 -w0 | tr '+/' '-_' | tr -d '=')
    checksum=$(printf '%s' "1/$MT_KIND/$encoded" | sha256sum); checksum="${checksum%% *}"
    printf 'mtunnel://1/%s/%s.%s\n' "$MT_KIND" "$encoded" "$checksum"
}
mt_link_decode() {
    local link="$1" rest kind encoded checksum actual raw padded canonical key val
    link="${link//$'\r'/}"
    link="${link#"${link%%[![:space:]]*}"}"; link="${link%"${link##*[![:space:]]}"}"
    declare -gA MT_LINK_DATA=()
    [ "${#link}" -le 32768 ] && [[ "$link" == mtunnel://1/* ]] || return 1
    rest="${link#mtunnel://1/}"; kind="${rest%%/*}"; rest="${rest#*/}"
    [[ "$kind" =~ ^(gre|vxlan|backhaul|rathole|paqet)$ ]] || return 1
    [ "$kind" = "$MT_KIND" ] || { echo "This link is for $kind, not $MT_KIND." >&2; return 1; }
    encoded="${rest%.*}"; checksum="${rest##*.}"
    [[ "$encoded" =~ ^[A-Za-z0-9_-]+$ && "$checksum" =~ ^[a-f0-9]{64}$ ]] || return 1
    actual=$(printf '%s' "1/$kind/$encoded" | sha256sum); [ "${actual%% *}" = "$checksum" ] || { echo 'Setup link checksum failed.' >&2; return 1; }
    padded=$(printf '%s' "$encoded" | tr '_-' '/+'); case $((${#padded}%4)) in 2) padded+='==';; 3) padded+='=';; 1) return 1;; esac
    raw=$(printf '%s' "$padded" | base64 -d 2>/dev/null) || return 1
    canonical=$(printf '%s' "$raw" | base64 -w0 | tr '+/' '-_' | tr -d '=')
    [ "$canonical" = "$encoded" ] || return 1 # rejects NULs/noncanonical/trailing newlines
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
        [[ ! -v MT_LINK_DATA[$key] ]] || return 1
        mt_link_field_valid "$key" "$val" || return 1
        MT_LINK_DATA[$key]="$val"
    done <<< "$raw"
    mt_link_validate
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
        read -r -p "  This server's reachable public IP/hostname [$host]: " dest || return 1
        host="${dest:-$host}"
        mt_valid_host "$host" && [[ "$host" != 0.0.0.0 && "$host" != :: ]] || { echo 'Enter a reachable endpoint.' >&2; return 1; }
        MT_LINK_DATA[HOST]="$host"
        if [ "$MT_KIND" = backhaul ] && [ "$role" = 2 ]; then
            read -r -p '  Peer server port mappings (e.g. 443=127.0.0.1:443): ' dest || return 1
            validate_bh_ports "$dest" 0 || return 1; MT_LINK_DATA[PORTS]="$dest"
        elif [ "$MT_KIND" = paqet ] && [ "$role" = 1 ]; then
            read -r -p '  Peer client forwarded TCP ports (e.g. 443,8080): ' dest || return 1
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
    read -r -p '  Generate a setup link for the peer now? [Y/n]: ' ans || return 0
    case "${ans,,}" in n|no) return 0;; esac
    mt_link_export "$1"
}
mt_link_import() {
    local link ans name
    mt_workspace_screen
    read -r -p '  Paste Peer Setup Link (q: back): ' link || return 1
    [ "$link" != q ] || return 0
    mt_link_decode "$link" || { echo -e "  ${R}✖ Invalid / expired link. No changes made.${NC}"; mt_workspace_pause; return 1; }
    echo -e "\n  ${DIM}┌─[ PEER SETUP PREVIEW ]${NC}"
    printf '  Module: %s | Role: %s | Peer: %s\n' "$MT_KIND" "${MT_LINK_DATA[ROLE]}" "${MT_LINK_DATA[HOST]}"
    printf '  Link port: %s | Transport: %s | vIPs: %s\n' "${MT_LINK_DATA[LINK_PORT]:--}" "${MT_LINK_DATA[TRANSPORT]:-${MT_LINK_DATA[PROTO]:-KCP/TCP}}" "${MT_LINK_DATA[MAX_IPS]:--}"
    printf '  TCP ports: %s | UDP ports: %s\n' "${MT_LINK_DATA[TCP_PORTS]:-${MT_LINK_DATA[PORTS]:--}}" "${MT_LINK_DATA[UDP_PORTS]:--}"
    echo -e "  ${DIM}└─ Secret is hidden. Existing tunnels will not be overwritten.${NC}"
    read -r -p "  Local tunnel name/suffix [${MT_LINK_DATA[NAME]}]: " name || return 1
    name="${name:-${MT_LINK_DATA[NAME]}}"
    mt_link_field_valid NAME "$name" || { echo 'Invalid name.' >&2; return 1; }
    MT_LINK_DATA[NAME]="$name"
    read -r -p '  Create this peer tunnel? [y/N]: ' ans || return 1
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
    read -r -p '  Create internal Virtual IPs for this tunnel? [y/N/q]: ' ans || return 1
    case "${ans,,}" in q) return 1;; n|no|'') return 0;; y|yes) ;; *) echo 'Type y, n or q.' >&2; mt_workspace_vip; return $?;; esac
    while true; do
        read -r -p '  Virtual IP pair count [1] (1-64, q: back): ' count || return 1
        [ "$count" != q ] || return 1; count="${count:-1}"
        if mt_link_uint "$count" 1 64; then MT_NEW_VIP_COUNT=$((10#$count)); return 0; fi
        echo 'Enter a number between 1 and 64.'
    done
}
mt_workspace_backup() {
    local dest
    mt_workspace_screen
    read -r -p "  Backup file [$LOCAL_DIR/backups/$MT_KIND-$(date +%Y%m%d-%H%M%S).tar.gz]: " dest || return 1
    dest="${dest:-$LOCAL_DIR/backups/$MT_KIND-$(date +%Y%m%d-%H%M%S).tar.gz}"
    mkdir -p "$(dirname "$dest")" || return 1
    [ ! -e "$dest" ] || { echo 'File already exists; choose another path.' >&2; return 1; }
    (umask 077; tar -czf "$dest" -C "$(dirname "$CONF_DIR")" "$(basename "$CONF_DIR")") && echo "  Backup saved: $dest"
    mt_workspace_pause
}
# END MTUNNEL WORKSPACE V13

mt_link_paqet_values() {
    local yaml="$1" key val source
    for key in MODE CONN MTU RCVWND SNDWND SMUXBUF STREAMBUF TCPBUF UDPBUF NODELAY WDELAY ACKNODELAY INTERVAL RESEND NOCONGESTION DSHARD PSHARD SMUXKALIVE; do
        source="${key,,}"; val=$(get_yaml_value "$source" "$yaml")
        [ -z "$val" ] || MT_LINK_DATA[KCP_$key]="$val"
    done
    val=$(get_yaml_value sockbuf "$yaml"); MT_LINK_DATA[KCP_PCAP_SOCKBUF]="${val:-8388608}"
    # Older minimal configurations rely on the engine defaults, rather than explicit buffers/windows.
    : "${MT_LINK_DATA[KCP_CONN]:=4}" "${MT_LINK_DATA[KCP_MTU]:=1350}" "${MT_LINK_DATA[KCP_RCVWND]:=1024}" "${MT_LINK_DATA[KCP_SNDWND]:=1024}"
    : "${MT_LINK_DATA[KCP_SMUXBUF]:=16777216}" "${MT_LINK_DATA[KCP_STREAMBUF]:=2097152}" "${MT_LINK_DATA[KCP_TCPBUF]:=8192}" "${MT_LINK_DATA[KCP_UDPBUF]:=4096}"
    if [ "${MT_LINK_DATA[KCP_MODE]}" = manual ]; then
        : "${MT_LINK_DATA[KCP_NODELAY]:=0}" "${MT_LINK_DATA[KCP_WDELAY]:=true}" "${MT_LINK_DATA[KCP_ACKNODELAY]:=false}" "${MT_LINK_DATA[KCP_INTERVAL]:=30}" "${MT_LINK_DATA[KCP_RESEND]:=2}" "${MT_LINK_DATA[KCP_NOCONGESTION]:=1}"
    fi
}
mt_link_deploy_locked() {
    mt_link_validate || return 1
    local name="pq_${MT_LINK_DATA[NAME]#pq_}" role="${MT_LINK_DATA[ROLE]}" port="${MT_LINK_DATA[LINK_PORT]}" host="${MT_LINK_DATA[HOST]}" key="${MT_LINK_DATA[TOKEN]}" block="${MT_LINK_DATA[BLOCK]}" target p variable yaml meta tmp unit
    yaml="$CONF_DIR/$name.yaml"; meta="$CONF_DIR/$name.meta"; unit="mpaqet@$name"
    [ ! -e "$yaml" ] && [ ! -e "$meta" ] || { echo 'Tunnel already exists; nothing overwritten.' >&2; return 1; }
    [ "$role" != 1 ] || { ! mt_port_busy "$port" && paqet_port_available "$port"; } || return 1
    if [ "$role" = 2 ]; then
        validate_paqet_ports "${MT_LINK_DATA[TCP_PORTS]}" || return 1
        mt_list_has_port "${MT_LINK_DATA[TCP_PORTS]}" "$port" && { echo 'A forwarded port matches the link port.' >&2; return 1; }
        target="$host"
    else target=1.1.1.1; fi
    resolve_paqet_route "$target" || { echo 'Cannot resolve the IPv4 route / gateway MAC.' >&2; return 1; }
    [[ "$PQ_ROUTE_IFACE" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    tmp=$(mktemp "$SECURE_TMP/peer-paqet.XXXXXX") || return 1
    {
        printf 'role: "%s"\nlog:\n  level: "info"\n' "$([ "$role" = 1 ] && echo server || echo client)"
        if [ "$role" = 1 ]; then printf 'listen:\n  addr: ":%s"\n' "$port"
        else
            printf 'forward:\n'
            IFS=, read -ra MT_PQ_PORTS <<< "${MT_LINK_DATA[TCP_PORTS]}"
            for p in "${MT_PQ_PORTS[@]}"; do printf '  - listen: "0.0.0.0:%s"\n    target: "127.0.0.1:%s"\n    protocol: "tcp"\n' "$p" "$p"; done
            printf 'server:\n  addr: "%s:%s"\n' "$PQ_ROUTE_TARGET" "$port"
        fi
        printf 'network:\n  interface: "%s"\n  ipv4:\n    addr: "%s:%s"\n    router_mac: "%s"\n  tcp:\n    local_flag: ["PA"]\n' "$PQ_ROUTE_IFACE" "$PQ_ROUTE_SRC" "$([ "$role" = 1 ] && echo "$port" || echo 0)" "$PQ_ROUTE_MAC"
        [ "$role" != 2 ] || printf '    remote_flag: ["PA"]\n'
        printf 'transport:\n  protocol: "kcp"\n  kcp:\n    key: "%s"\n    block: "%s"\n    mode: "%s"\n    mtu: %s\n' "$key" "$block" "${MT_LINK_DATA[KCP_MODE]}" "${MT_LINK_DATA[KCP_MTU]}"
        for variable in DSHARD PSHARD SMUXKALIVE; do
            [ -z "${MT_LINK_DATA[KCP_$variable]:-}" ] || printf '    %s: %s\n' "${variable,,}" "${MT_LINK_DATA[KCP_$variable]}"
        done
    } > "$tmp"
    # Copy only validated scalar settings into the existing KCP writer.
    for variable in MODE CONN MTU RCVWND SNDWND SMUXBUF STREAMBUF PCAP_SOCKBUF TCPBUF UDPBUF NODELAY WDELAY ACKNODELAY INTERVAL RESEND NOCONGESTION; do
        printf -v "KCP_$variable" '%s' "${MT_LINK_DATA[KCP_$variable]:-}"
    done
    if [ "$KCP_MODE" = manual ]; then
        for variable in NODELAY WDELAY ACKNODELAY INTERVAL RESEND NOCONGESTION; do
            mt_link_field_valid "KCP_$variable" "${MT_LINK_DATA[KCP_$variable]:-}" || { rm -f "$tmp"; return 1; }
        done
    fi
    if ! write_kcp_settings "$tmp" "$key" "$block"; then rm -f "$tmp"; return 1; fi
    (umask 077; set -o noclobber; cat "$tmp" > "$yaml") 2>/dev/null || { rm -f "$tmp"; return 1; }; rm -f "$tmp"
    {
        printf 'ROLE=%s\nTUN_PORT=%s\nREMOTE_IP=%s\nTCP_PORTS=%s\nPROFILE=%s\n' "$role" "$port" "$host" "${MT_LINK_DATA[TCP_PORTS]}" "${MT_LINK_DATA[PROFILE]}"
    } > "$meta"; chmod 600 "$meta"
    if [ "$role" = 1 ]; then setup_paqet_counters "$name" "$port"
    else
        for p in "${MT_PQ_PORTS[@]}"; do setup_paqet_counters "$name" "$p"; done
        setup_paqet_probe "$name" "$PQ_ROUTE_TARGET" "$port"
    fi
    if ! systemctl restart "$unit" || ! mt_workspace_service_ready "$unit"; then
        journalctl -u "$unit" -n 8 --no-pager >&2; systemctl stop "$unit"; clean_paqet_counters "$name"; rm -f "$yaml" "$meta"; return 1
    fi
    systemctl enable "$unit" >/dev/null 2>&1
}
mt_workspace_service_ready() {
    local attempt
    for attempt in 1 2 3 4; do sleep .4; systemctl is-active --quiet "$1" || return 1; done
}
mt_workspace_health() {
    mt_link_select || return 1
    local name; name=$(basename "$MT_LINK_CONF" .meta)
    mt_workspace_screen
    systemctl status "mpaqet@$name" --no-pager -l
    journalctl -u "mpaqet@$name" -n 12 --no-pager
    echo '  Paqet uses raw packets. A TCP connect probe cannot verify the raw link.'
    echo '  Use Live Monitor for packet activity and test an actual forwarded application from the peer.'
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
    local rv file="$SECURE_TMP/.mpaqet_remote_ver"
    [ -f "$file" ] || return 0
    rv=$(tr -d '\r\n ' < "$file")
    if mt_is_newer_version "$rv" "$MODULE_VERSION"; then
        printf ' %b(Update Available: v%s)%b' "$Y" "$rv" "$NC"
    fi
    return 0
}
MT_KIND=paqet; MT_HEADER=draw_header; MT_SECTION=""
mt_workspace_route() {
    local section="$1"
    case "$section" in
        1) MT_SECTION=1; mt_workspace_menu "CREATE TUNNEL" "1|Manual Server Setup (Kharej)|1|${G}" "2|Manual Client Setup (Iran)|2|${C}" "3|Create From Peer Link|97|${G}" "4|Generate Peer Setup Link|98|${M}" || { MT_SECTION=""; return 1; };;
        2) MT_SECTION=2; mt_workspace_menu "EDIT & MANAGE" "1|Secret Key|4|${G}" "2|KCP Profile / Manual Settings|5|${C}" "3|MTU Size|6|${G}" "4|Connection Count|7|${Y}" "5|Encryption|8|${M}" "6|Tunnel Name|10|${W}" "7|Delete Tunnels|3|${R}" || { MT_SECTION=""; return 1; };;
        3) MT_SECTION=3; mt_workspace_menu "FORWARDING" "1|Forwarded TCP Ports (Client)|9|${C}" || { MT_SECTION=""; return 1; };;
        4) MT_SECTION=4; mt_workspace_menu "SYSTEM & SECURITY" "1|Auto Recovery|13|${G}" "2|BBR Settings|14|${G}" "3|Restart & Zero Counters|15|${G}" "4|Check Selected Tunnel|99|${C}" || { MT_SECTION=""; return 1; };;
        7) MT_SECTION=7; mt_workspace_menu "UPDATE AND LOCAL INSTALL" "1|OTA Update / Local Script|17|${G}" "2|Install / Update Engine (Online / Local)|16|${M}" || { MT_SECTION=""; return 1; };;
        5) MT_ACTION=11;;
        6) MT_ACTION=12;;
        8) MT_ACTION=96;;
        9) MT_ACTION=18;;
        0) MT_ACTION=0;;
        *) return 1;;
    esac
}

render_mpaqet_menu() {
    mt_workspace_screen
    mt_workspace_group 'PROVISION & MANAGE' first
    mt_workspace_row 1 'Create Tunnel' "$G"
    mt_workspace_row 2 'Edit & Manage' "$Y"
    mt_workspace_row 3 'Forwarding' "$C"
    mt_workspace_group 'CONFIGURATION & MONITORING'
    mt_workspace_row 4 'System & Security' "$M"
    mt_workspace_row 5 'Tunnels Info And Specs' "$M"
    mt_workspace_row 6 'Live Monitor' "$G"
    mt_workspace_group 'SYSTEM OPERATIONS'
    mt_workspace_row 7 'Update and Local Install' "$G" "$(mt_workspace_update_badge)"
    mt_workspace_row 8 'Backup Configs' "$W"
    mt_workspace_row 9 'Uninstall MPAQET' "$R"
    mt_workspace_footer 'Return to Main Core'
}

while true; do
    if [ -n "$MT_SECTION" ]; then opt="$MT_SECTION"
    else
        render_mpaqet_menu
        read_with_refresh "  ${C}MPAQET ❯❯ ${NC}" opt render_mpaqet_menu || break
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
           echo -e "\n  ${DIM}┌─[ DEPLOY SERVER TUNNEL ]${NC}"
           echo -ne "  ${C}● Tunnel Suffix Name (e.g. srv1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
           if [ -z "$suffix" ]; then echo -e "  ${R}✖ Invalid Name!${NC}"; sleep 1.5; continue; fi
           
           t_name="pq_${suffix}"
           
           if [ -f "$CONF_DIR/${t_name}.yaml" ]; then
               echo -e "  ${R}✖ Tunnel '${t_name}' already exists! Delete it first or use another name.${NC}"; sleep 2; continue
           fi
           
           resolve_paqet_route "1.1.1.1" || { echo 'Cannot determine the route/gateway MAC.' >&2; continue; }
           iface="$PQ_ROUTE_IFACE"; l_ip="$PQ_ROUTE_SRC"; gw_mac="$PQ_ROUTE_MAC"

           while true; do
               echo -ne "  ${C}● Tunnel Listen Port [8888]: ${NC}"; read t_port
               t_port=${t_port//$'\r'/}
               t_port=${t_port:-8888}
               if ! mt_valid_port "$t_port"; then
                   echo -e "  ${R}✖ Invalid port!${NC}"
                   continue
               fi
               if mt_port_busy "$t_port" || ! paqet_port_available "$t_port"; then
                   echo -e "  ${R}Error: Port ${t_port} is already in use by another service!${NC}"
                   continue
               fi
               break
           done
           
           s_key=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
           echo -ne "  ${C}● Secret Key [Default ${s_key}]: ${NC}"; read u_key
           u_key=$(echo "$u_key" | tr -dc 'a-zA-Z0-9_=-')
           key=${u_key:-$s_key}

           choose_kcp_profile "server" "FAST" || continue
           profile_name="$KCP_PROFILE"
           
           > "$CONF_DIR/${t_name}.yaml.tmp"
           cat <<'EOF' > "$CONF_DIR/${t_name}.yaml.tmp"
role: "server"
log:
  level: "info"
listen:
  addr: ":%PORT%"
network:
  interface: "%IFACE%"
  ipv4:
    addr: "%LIP%:%PORT%"
    router_mac: "%MAC%"
  tcp:
    local_flag: ["PA"]
transport:
  protocol: "kcp"
  conn: 4
  kcp:
    key: "%KEY%"
    mode: "fast"
    block: "aes-128-gcm"
    mtu: 1350
EOF
           sed -e "s|%PORT%|${t_port}|g" \
               -e "s|%IFACE%|${iface}|g" \
               -e "s|%LIP%|${l_ip}|g" \
               -e "s|%MAC%|${gw_mac}|g" \
               -e "s|%KEY%|${key}|g" \
               "$CONF_DIR/${t_name}.yaml.tmp" > "$CONF_DIR/${t_name}.yaml"
           rm -f "$CONF_DIR/${t_name}.yaml.tmp"
           if ! write_kcp_settings "$CONF_DIR/${t_name}.yaml" "$key" "aes-128-gcm"; then
               clean_paqet_counters "$t_name"; rm -f "$CONF_DIR/${t_name}.yaml"
               echo -e "  ${R}✖ Tunnel was NOT created (profile could not be written).${NC}"; sleep 2; continue
           fi
           
           echo -e "ROLE=1\nTUN_PORT=$t_port\nREMOTE_IP=0.0.0.0\nTCP_PORTS=\nPROFILE=$profile_name" > "$CONF_DIR/${t_name}.meta"
           
           setup_paqet_counters "$t_name" "$t_port"
           systemctl enable "mpaqet@${t_name}" >/dev/null 2>&1
           systemctl restart "mpaqet@${t_name}"
           
           sleep 1.5
           if systemctl is-active --quiet "mpaqet@${t_name}"; then
               mt_ask_bbr_on_create
               mt_link_offer "$CONF_DIR/$t_name.meta"
               echo -e "\n  ${G}● Paqet Server Tunnel Deployed! Key: ${key}${NC}"; sleep 2
           else
               echo -e "\n  ${R}✖ Failed to start! Checking logs...${NC}"
               journalctl -u "mpaqet@${t_name}" -n 5 --no-pager
               echo -ne "  ${DIM}Press Enter...${NC}"; read dummy
           fi
           ;;
           
        2)
           mt_workspace_screen
           echo -e "\n  ${DIM}┌─[ DEPLOY CLIENT TUNNEL ]${NC}"
           echo -ne "  ${C}● Tunnel Suffix Name (e.g. cl1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
           if [ -z "$suffix" ]; then echo -e "  ${R}✖ Invalid Name!${NC}"; sleep 1.5; continue; fi
           
           t_name="pq_${suffix}"
           
           if [ -f "$CONF_DIR/${t_name}.yaml" ]; then
               echo -e "  ${R}✖ Tunnel '${t_name}' already exists! Delete it first or use another name.${NC}"; sleep 2; continue
           fi
           
           # Resolve the route after the remote IPv4 endpoint is known.

           while true; do
               echo -ne "  ${C}● Remote Kharej Server Host/IP: ${NC}"; read r_ip
               r_ip=$(echo "$r_ip" | tr -d '\r ')
               is_valid_host "$r_ip" && break
               echo -e "  ${R}✖ Invalid Host/IP format!${NC}"
           done
           
           while true; do
               echo -ne "  ${C}● Remote Listen Port [8888]: ${NC}"; read r_port
               r_port=${r_port//$'\r'/}
               r_port=${r_port:-8888}
               if mt_valid_port "$r_port"; then break; else echo -e "  ${R}✖ Invalid port!${NC}"; fi
           done
           
           resolve_paqet_route "$r_ip" || { echo 'Cannot resolve the remote route/gateway MAC.' >&2; continue; }
           iface="$PQ_ROUTE_IFACE"; l_ip="$PQ_ROUTE_SRC"; gw_mac="$PQ_ROUTE_MAC"; r_ip="$PQ_ROUTE_TARGET"

           echo -ne "  ${C}● Secret Key (from Server): ${NC}"; read key
           key=$(echo "$key" | tr -dc 'a-zA-Z0-9_=-')
           
           fwd_ports=""
           while true; do
               echo -ne "  ${C}● Forward Ports (e.g. 443,8080): ${NC}"; read fwd_ports
               fwd_ports=${fwd_ports//$'\r'/}
               if ! validate_paqet_ports "$fwd_ports"; then
                   echo -e "  ${R}Error: Specify valid, unique, available forwarded ports (1-65535)!${NC}"
               else
                   break
               fi
           done
           
           if echo ",$fwd_ports," | grep -q ",$r_port,"; then
               echo -e "  ${R}✖ Loop Error: Forward port cannot match Tunnel port ($r_port)!${NC}"; sleep 2; continue
           fi
           
           choose_kcp_profile "client" "FAST" || continue
           profile_name="$KCP_PROFILE"
           
           > "$CONF_DIR/${t_name}.yaml.tmp"
           cat <<'EOF' > "$CONF_DIR/${t_name}.yaml.tmp"
role: "client"
log:
  level: "info"
forward:
EOF
           IFS=',' read -ra P_ARR <<< "$fwd_ports"
           meta_ports=""
           for p_raw in "${P_ARR[@]}"; do
               p_clean=$(echo "$p_raw" | tr -dc '0-9')
               if [ -n "$p_clean" ] && [ "$p_clean" -le 65535 ]; then
                   echo "  - listen: \"0.0.0.0:$p_clean\"" >> "$CONF_DIR/${t_name}.yaml.tmp"
                   echo "    target: \"127.0.0.1:$p_clean\"" >> "$CONF_DIR/${t_name}.yaml.tmp"
                   echo "    protocol: \"tcp\"" >> "$CONF_DIR/${t_name}.yaml.tmp"
                   setup_paqet_counters "$t_name" "$p_clean"
                   meta_ports="${meta_ports}${p_clean},"
               fi
           done
           
           cat <<'EOF' >> "$CONF_DIR/${t_name}.yaml.tmp"
network:
  interface: "%IFACE%"
  ipv4:
    addr: "%LIP%:0"
    router_mac: "%MAC%"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
server:
  addr: "%RIP%:%RPORT%"
transport:
  protocol: "kcp"
  conn: 4
  kcp:
    key: "%KEY%"
    mode: "fast"
    block: "aes-128-gcm"
    mtu: 1350
EOF
           sed -e "s|%IFACE%|${iface}|g" \
               -e "s|%LIP%|${l_ip}|g" \
               -e "s|%MAC%|${gw_mac}|g" \
               -e "s|%RIP%|${r_ip}|g" \
               -e "s|%RPORT%|${r_port}|g" \
               -e "s|%KEY%|${key}|g" \
               "$CONF_DIR/${t_name}.yaml.tmp" > "$CONF_DIR/${t_name}.yaml"
           rm -f "$CONF_DIR/${t_name}.yaml.tmp"
           if ! write_kcp_settings "$CONF_DIR/${t_name}.yaml" "$key" "aes-128-gcm"; then
               clean_paqet_counters "$t_name"; rm -f "$CONF_DIR/${t_name}.yaml"
               echo -e "  ${R}✖ Tunnel was NOT created (profile could not be written).${NC}"; sleep 2; continue
           fi

           echo -e "ROLE=2\nTUN_PORT=$r_port\nREMOTE_IP=$r_ip\nTCP_PORTS=${meta_ports%,}\nPROFILE=$profile_name" > "$CONF_DIR/${t_name}.meta"

           systemctl enable "mpaqet@${t_name}" >/dev/null 2>&1
           systemctl restart "mpaqet@${t_name}"
           
           sleep 1.5
           if systemctl is-active --quiet "mpaqet@${t_name}"; then
               mt_ask_bbr_on_create
               mt_link_offer "$CONF_DIR/$t_name.meta"
               echo -e "\n  ${G}● Paqet Client Tunnel Deployed!${NC}"; sleep 2
           else
               echo -e "\n  ${R}✖ Failed to start! Checking logs...${NC}"
               journalctl -u "mpaqet@${t_name}" -n 5 --no-pager
               echo -ne "  ${DIM}Press Enter...${NC}"; read dummy
           fi
           ;;

        3)
           configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Delete ─────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}Index (or 'all' / 'q'): ${NC}"; read del_idx
           del_idx=$(echo "$del_idx" | tr -d '\r ')
           
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do
                   t_name=$(basename "$conf" .meta)
                   systemctl stop "mpaqet@${t_name}" 2>/dev/null; systemctl disable "mpaqet@${t_name}" 2>/dev/null
                   clean_paqet_counters "$t_name"
                   rm -f "$conf" "$CONF_DIR/${t_name}.yaml"
               done
               echo -e "  ${G}● All Tunnels Purged!${NC}"; sleep 1.5
           elif [[ "$del_idx" =~ ^[0-9]+$ ]] && [[ -n "${configs[$del_idx]}" ]]; then
               t_name=$(basename "${configs[$del_idx]}" .meta)
               systemctl stop "mpaqet@${t_name}" 2>/dev/null; systemctl disable "mpaqet@${t_name}" 2>/dev/null
               clean_paqet_counters "$t_name"
               rm -f "${configs[$del_idx]}" "$CONF_DIR/${t_name}.yaml"
               echo -e "  ${G}● Purged!${NC}"; sleep 1.5
           fi ;;

        4|5|6|7|8|9|10)
           select_tunnel || continue
           sel_cfg="$SELECTED_TUN"
           old_tname=$(basename "$sel_cfg" .yaml)

           if [[ "$opt" == "4" ]]; then
               curr_key=$(grep "key:" "$sel_cfg" | awk -F'"' '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New Secret Key [Current: ${Y}${curr_key}${W}]: ${NC}"; read n_k
               n_k=$(echo "$n_k" | tr -dc 'a-zA-Z0-9_=-')
               if [ -n "$n_k" ]; then
                   sed -i "s|key:.*|key: \"$n_k\"|" "$sel_cfg"
                   echo -e "  ${G}✔ Secret Key updated.${NC}"
               else
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi

           elif [[ "$opt" == "5" ]]; then
               curr_profile=$(get_tunnel_profile "$old_tname")
               role_name="client"
               [ "$(grep -m1 '^ROLE=' "$CONF_DIR/${old_tname}.meta" | cut -d'=' -f2)" = "1" ] && role_name="server"
               if choose_kcp_profile "$role_name" "$curr_profile"; then
                   if ! write_kcp_settings "$sel_cfg" "$(get_yaml_value key "$sel_cfg")" "$(get_yaml_value block "$sel_cfg")"; then
                       sleep 2; continue
                   fi
                   set_meta_profile "$old_tname" "$KCP_PROFILE"
                   echo -e "  ${G}✔ ${KCP_PROFILE} profile applied and verified in YAML. Apply the same profile on the other server.${NC}"
               else
                   echo -e "  ${Y}● Profile change cancelled.${NC}"
                   continue
               fi

           elif [[ "$opt" == "6" ]]; then
               curr_mtu=$(grep "mtu:" "$sel_cfg" | awk '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New MTU Size [576-1500] [Current: ${Y}${curr_mtu}${W}]: ${NC}"; read n_mtu
               n_mtu=$(echo "$n_mtu" | tr -dc '0-9')
               if [ -z "$n_mtu" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if [ "$n_mtu" -lt 576 ] || [ "$n_mtu" -gt 1500 ]; then 
                   echo -e "  ${R}✖ MTU must be between 576 and 1500!${NC}"; sleep 1.5; continue
               fi
               nic_cap=$(kcp_mtu_cap "$sel_cfg")
               if [ -n "$nic_cap" ] && [ "$n_mtu" -gt "$nic_cap" ]; then
                   echo -e "  ${Y}⚠ This interface can only send ${nic_cap}; using ${nic_cap}.${NC}"; n_mtu="$nic_cap"
               fi
               sed -i "s|mtu:.*|mtu: $n_mtu|" "$sel_cfg"
               mark_profile_custom "$old_tname"
               echo -e "  ${G}✔ MTU updated.${NC}"

           elif [[ "$opt" == "7" ]]; then
               curr_conn=$(grep "conn:" "$sel_cfg" | head -1 | awk '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New Connections Count [1-32] [Current: ${Y}${curr_conn}${W}]: ${NC}"; read n_c
               n_c=$(echo "$n_c" | tr -dc '0-9')
               if [ -z "$n_c" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if [ "$n_c" -lt 1 ] || [ "$n_c" -gt 32 ]; then 
                   echo -e "  ${R}✖ Connections must be between 1 and 32!${NC}"; sleep 1.5; continue
               fi
               sed -i "s|conn:.*|conn: $n_c|" "$sel_cfg"
               mark_profile_custom "$old_tname"
               echo -e "  ${G}✔ Connection count updated.${NC}"

           elif [[ "$opt" == "8" ]]; then
               curr_block=$(grep "block:" "$sel_cfg" | awk -F'"' '{print $2}')
               echo -ne "  ${C}●${NC} ${W}New Encryption Block [aes-128-gcm|aes-256|none] [Current: ${Y}${curr_block}${W}]: ${NC}"; read n_b
               n_b=$(echo "$n_b" | tr -dc 'a-zA-Z0-9-')
               if [ -z "$n_b" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if [[ "$n_b" =~ ^(aes-128-gcm|aes-256|none)$ ]]; then
                   sed -i "s|block:.*|block: \"$n_b\"|" "$sel_cfg"
                   echo -e "  ${G}✔ Encryption Block updated.${NC}"
               else
                   echo -e "  ${R}✖ Invalid Encryption!${NC}"; sleep 1.5; continue
               fi

           elif [[ "$opt" == "9" ]]; then
               is_client=false
               if grep -qi 'role: *"client"' "$sel_cfg"; then
                   is_client=true
               fi

               if [ "$is_client" != true ]; then
                   echo -e "  ${R}✖ Error: Forwarded ports can only be configured on Client tunnels!${NC}"
                   sleep 2; continue
               fi

               meta_file="$CONF_DIR/${old_tname}.meta"
               curr_ports=""
               [ -f "$meta_file" ] && curr_ports=$(grep -m1 "^TCP_PORTS=" "$meta_file" | cut -d'=' -f2 | tr -d '"')
               if [ -z "$curr_ports" ]; then
                   curr_ports=$(grep "listen:" "$sel_cfg" | awk -F':' '{print $NF}' | tr -d '"' | tr '\n' ',' | sed 's/,$//')
               fi

               t_tun_port=""
               [ -f "$meta_file" ] && t_tun_port=$(grep -m1 "^TUN_PORT=" "$meta_file" | cut -d'=' -f2 | tr -d '"')

               echo -ne "  ${C}●${NC} ${W}New Forward Ports [Current: ${Y}${curr_ports}${W}] (e.g. 443,8080): ${NC}"; read n_ports
               n_ports=$(echo "$n_ports" | tr -d '\r ' )
               if [ -z "$n_ports" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi

               validate_paqet_ports "$n_ports" "$old_tname" || { echo 'Invalid or conflicting port list.' >&2; sleep 1; continue; }
               if [ -n "$t_tun_port" ] && echo ",$n_ports," | grep -q ",$t_tun_port,"; then
                   echo -e "  ${R}✖ Loop Error: Forward port cannot match Tunnel port ($t_tun_port)!${NC}"
                   sleep 2; continue
               fi

               tmp_yaml="$SECURE_TMP/${old_tname}.yaml.tmp"
               new_meta_ports=""
               
               {
                   sed -n '1,/^forward:/p' "$sel_cfg"
                   IFS=',' read -ra P_ARR <<< "$n_ports"
                   for p_raw in "${P_ARR[@]}"; do
                       p_clean=$(echo "$p_raw" | tr -dc '0-9')
                       if mt_valid_port "$p_clean"; then
                           echo "  - listen: \"0.0.0.0:$p_clean\""
                           echo "    target: \"127.0.0.1:$p_clean\""
                           echo "    protocol: \"tcp\""
                           new_meta_ports="${new_meta_ports}${p_clean},"
                       fi
                   done
                   sed -n '/^network:/,$p' "$sel_cfg"
               } > "$tmp_yaml"

               if [ -z "$new_meta_ports" ]; then
                   echo -e "  ${R}✖ Invalid port list! Must specify at least one valid port.${NC}"
                   rm -f "$tmp_yaml"; sleep 2; continue
               fi

               if [ -s "$tmp_yaml" ] && grep -q "role:" "$tmp_yaml"; then
                   clean_paqet_counters "$old_tname"
                   mv -f "$tmp_yaml" "$sel_cfg"

                   new_meta_ports="${new_meta_ports%,}"
                   IFS=',' read -ra NP_ARR <<< "$new_meta_ports"
                   for p_clean in "${NP_ARR[@]}"; do
                       setup_paqet_counters "$old_tname" "$p_clean"
                   done

                   if [ -f "$meta_file" ]; then
                       if grep -q "^TCP_PORTS=" "$meta_file"; then
                           sed -i "s|^TCP_PORTS=.*|TCP_PORTS=$new_meta_ports|" "$meta_file"
                       else
                           echo "TCP_PORTS=$new_meta_ports" >> "$meta_file"
                       fi
                   fi
                   echo -e "  ${G}✔ Forwarded ports updated successfully.${NC}"
               else
                   rm -f "$tmp_yaml"
                   echo -e "  ${R}✖ Failed to update YAML configuration.${NC}"
                   sleep 2; continue
               fi

           elif [[ "$opt" == "10" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Tunnel Suffix (Current: ${Y}${old_tname#pq_}${W}): ${NC}"; read new_suffix
               new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
               if [ -n "$new_suffix" ]; then
                   new_t_name="pq_${new_suffix}"
                   if [ -f "$CONF_DIR/${new_t_name}.yaml" ]; then
                       echo -e "  ${R}● Error: Tunnel [${new_t_name}] already exists!${NC}"; sleep 1.5; continue
                   fi
                   
                   systemctl stop "mpaqet@${old_tname}" 2>/dev/null; systemctl disable "mpaqet@${old_tname}" 2>/dev/null
                   clean_paqet_counters "$old_tname"
                   
                   mv "$sel_cfg" "$CONF_DIR/${new_t_name}.yaml"
                   mv "$CONF_DIR/${old_tname}.meta" "$CONF_DIR/${new_t_name}.meta" 2>/dev/null
                   
                   ROLE=""; TUN_PORT=""; TCP_PORTS=""; source "$CONF_DIR/${new_t_name}.meta" 2>/dev/null
                   if [ "$ROLE" == "1" ]; then
                       setup_paqet_counters "$new_t_name" "$TUN_PORT"
                   else
                       if [ -n "$TCP_PORTS" ]; then
                           IFS=',' read -ra P_ARR <<< "$TCP_PORTS"
                           for p_clean in "${P_ARR[@]}"; do
                               if mt_valid_port "$p_clean"; then
                                   setup_paqet_counters "$new_t_name" "$p_clean"
                               fi
                           done
                       fi
                   fi
                   
                   old_tname="$new_t_name"
                   systemctl enable "mpaqet@${old_tname}" >/dev/null 2>&1
                   echo -e "  ${G}● Tunnel successfully renamed to: ${new_t_name}${NC}"
               else
                   echo -e "  ${Y}● Rename cancelled.${NC}"; sleep 1; continue
               fi
           fi

           systemctl restart "mpaqet@${old_tname}" 2>/dev/null
           sleep 1.5
           if systemctl is-active --quiet "mpaqet@${old_tname}"; then
               echo -e "  ${G}✔ Tunnel updated and restarted successfully.${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Tunnel failed to start. Please check logs!${NC}"; sleep 2
           fi
           ;;

        11) show_tunnels_info ;;
        15) zero_paqet_counters; systemctl restart mpaqet@* 2>/dev/null; echo -e "  ${G}● Services restarted and traffic counters zeroed.${NC}"; sleep 1.5 ;;
        16) menu_install_core ;;
        17) self_update_module ;;
        18) uninstall_mpaqet ;;
        13) mt_run_tool mhealer --scope paqet ;;
        14) mt_run_tool mbbr --from-tunnel ;;
        12) show_live_radar ;;
        0) break ;;
    esac
done
