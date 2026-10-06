#!/bin/bash
# --- MDesign Master Core | Central Dashboard v12.0.3 ---
# [Features: Universal Persistent Header | In-Place Live Refresh | Smart Skip-Installed Cache | Fixed 117-Col Matrix]

MODULE_VERSION="12.0.4"

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
    local kind="$1" header="$2" details="$3" live="$4" extra_view="$5" choice rc
    local extra_label='Live Service Logs'
    mt_valid_scope "$kind" && [ "$kind" != all ] || return 1
    case "$kind" in gre|vxlan) extra_label='Live Traffic Monitor (RX/TX Rate)';; esac
    while true; do
        "$header"
        echo -e "\n  ${DIM}┌─[ Tunnels Info And Specs ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${M}Tunnel Details & Settings${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Live Monitor${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}${extra_label}${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Menu${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"
        rc=0
        read -r choice || rc=$?
        [ "$rc" -le 128 ] || continue
        [ "$rc" -eq 0 ] || return 0
        case "${choice//$'\r'/}" in
            1) "$details";;
            2) "$live";;
            3) mt_run_tool minterface --scope "$kind" --render;;
            4) "$extra_view";;
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
MTUNNEL_PATH="/usr/bin/mtunnel"
REPO_ZIP="https://github.com/htzserv/MTunnel/archive/refs/heads/main.zip"
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
MIRROR_SCRIPTS="https://c107328.parspack.net/c107328/MTunnel"
MIRROR_PACKAGES="https://c107328.parspack.net/c107328/MTunnel/packages"
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
    ["mweb"]="tools/mweb.sh"
    ["mstats"]="tools/mstats.sh"
    ["mhealer"]="tools/mhealer.sh"
    ["minterface"]="tools/minterface.sh"
    ["mbbr"]="tools/mbbr.sh"
    ["mdiag"]="tools/mdiag.sh"
    ["mshield"]="tools/mshield.sh"
    ["linktest"]="tools/linktest.sh"
)

ALL_MODULES=("main" "mporter" "mgre" "mxlan" "mrathole" "mbackhaul" "mpaqet" "mweb" "mstats" "mhealer" "minterface" "mbbr" "mdiag" "mshield" "linktest")

ALL_PACKAGES=(
    "bh"
    "rathole"
    "paqet"
    "gost"
    "haproxy"
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

mkdir -p "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$LOCAL_DIR/tools" "$SECURE_TMP" 2>/dev/null
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

UPDATE_CHECK_INTERVAL=30
STATS_CHECK_INTERVAL=5

check_single_module_silent() {
    local mod="$1"
    local rel_path="$2"
    local out_file="$SECURE_TMP/.chk_${mod}"
    rm -f "$out_file"

    local local_file="$LOCAL_DIR/$rel_path"
    [ ! -f "$local_file" ] && [ -f "/usr/bin/$mod" ] && local_file="/usr/bin/$mod"

    local cur_v=""
    [ -f "$local_file" ] && cur_v=$(grep -m1 '^MODULE_VERSION=' "$local_file" | cut -d'"' -f2)
    [ -z "$cur_v" ] && cur_v="0.0.0"

    local cb="?t=$(date +%s%N)"
    local rem_v=""
    if command -v curl >/dev/null 2>&1; then
        rem_v=$(curl -fSL -H "Cache-Control: no-cache" --connect-timeout 2 --max-time 4 "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        rem_v=$(wget -qO-  --header="Cache-Control: no-cache" --timeout=4 "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi

    if [ -n "$rem_v" ] && mt_is_newer_version "$rem_v" "$cur_v"; then
        echo "${mod}:${cur_v}:${rem_v}" > "$out_file"
    fi
}

check_all_updates_round() {
    local pids=()
    for mod in "${!MOD_MAP[@]}"; do
        check_single_module_silent "$mod" "${MOD_MAP[$mod]}" &
        pids+=("$!")
    done
    for p in "${pids[@]}"; do
        wait "$p" 2>/dev/null
    done

    : > "$UPDATE_FILE.new"
    for mod in "${!MOD_MAP[@]}"; do
        local f="$SECURE_TMP/.chk_${mod}"
        [ -s "$f" ] && cat "$f" >> "$UPDATE_FILE.new"
        rm -f "$f"
    done
    mv -f "$UPDATE_FILE.new" "$UPDATE_FILE" 2>/dev/null

    kill -SIGUSR1 "$MAIN_PID" 2>/dev/null
}

update_watcher_loop() {
    while true; do
        check_all_updates_round
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
if [[ "${1:-}" != --* ]]; then update_watcher_loop & fi
WATCHER_PID=$!

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

collect_system_vitals() {
    local sys_target="$SECURE_TMP/.main_sys_stats.tmp"
    
    local cpu_cores=$(nproc 2>/dev/null)
    [ -z "$cpu_cores" ] && cpu_cores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
    [ -z "$cpu_cores" ] && cpu_cores=1

    local cpu_pct=0
    if [ -f "$SECURE_TMP/.cpu_last" ]; then
        read p_idle p_total < "$SECURE_TMP/.cpu_last"
        read _ u n s i io ir st _ < <(grep '^cpu ' /proc/stat 2>/dev/null)
        local cur_idle=$(( i + io ))
        local cur_total=$(( u + n + s + i + io + ir + st ))
        local d_idle=$(( cur_idle - p_idle ))
        local d_total=$(( cur_total - p_total ))
        if [ "$d_total" -gt 0 ]; then
            cpu_pct=$(( (d_total - d_idle) * 100 / d_total ))
            [ "$cpu_pct" -lt 0 ] && cpu_pct=0
            [ "$cpu_pct" -gt 100 ] && cpu_pct=100
        fi
        echo "$cur_idle $cur_total" > "$SECURE_TMP/.cpu_last"
    else
        read _ u n s i io ir st _ < <(grep '^cpu ' /proc/stat 2>/dev/null)
        echo "$(( i + io )) $(( u + n + s + i + io + ir + st ))" > "$SECURE_TMP/.cpu_last"
        cpu_pct=5
    fi

    local r_used="0G" r_total="0G" r_pct=0
    if [ -f /proc/meminfo ]; then
        local mt=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
        local ma=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)
        [ -z "$ma" ] && ma=$(awk '/MemFree/ {print $2}' /proc/meminfo 2>/dev/null)
        if [ -n "$mt" ] && [ "$mt" -gt 0 ] 2>/dev/null; then
            local mu=$(( mt - ma ))
            r_pct=$(( mu * 100 / mt ))
            r_used=$(awk -v v="$mu" 'BEGIN {if(v<1048576) printf "%.0fM", v/1024; else printf "%.1fG", v/1048576}')
            r_total=$(awk -v v="$mt" 'BEGIN {printf "%.1fG", v/1048576}')
        fi
    fi

    local def_dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
    [ -z "$def_dev" ] && def_dev=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n 1)
    
    local rx_speed="0 B/s" tx_speed="0 B/s"
    local now_ts=$(date +%s)
    if [ -n "$def_dev" ] && [ -f "/sys/class/net/$def_dev/statistics/rx_bytes" ]; then
        local cur_rx=$(cat "/sys/class/net/$def_dev/statistics/rx_bytes" 2>/dev/null)
        local cur_tx=$(cat "/sys/class/net/$def_dev/statistics/tx_bytes" 2>/dev/null)
        if [ -f "$SECURE_TMP/.net_last" ]; then
            read p_ts p_rx p_tx < "$SECURE_TMP/.net_last"
            local dt=$(( now_ts - p_ts ))
            if [ "$dt" -gt 0 ]; then
                local drx=$(( (cur_rx - p_rx) / dt ))
                local dtx=$(( (cur_tx - p_tx) / dt ))
                [ "$drx" -lt 0 ] && drx=0
                [ "$dtx" -lt 0 ] && dtx=0
                rx_speed=$(format_bytes_speed "$drx")
                tx_speed=$(format_bytes_speed "$dtx")
            fi
        fi
        echo "$now_ts $cur_rx $cur_tx" > "$SECURE_TMP/.net_last"
    fi

    local v6_status="OFF"
    if ip -6 route show default 2>/dev/null | grep -q default || ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
        v6_status="ON"
    fi

    echo "${cpu_pct}|${cpu_cores}|${r_used}|${r_total}|${r_pct}|${rx_speed}|${tx_speed}|${v6_status}" > "$sys_target"
    mv -f "$sys_target" "$SECURE_TMP/.main_sys_stats" 2>/dev/null
}

collect_active_tunnels_stats() {
    local tmp_target="$SECURE_TMP/.main_tun_stats.tmp"
    > "$tmp_target"
    local count=0

    # 1. GRE
    for conf in /etc/mgre/tunnels/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; REMOTE_PUB=""; CORE_SUBNET=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        
        ip link show "$T_NAME" >/dev/null 2>&1 || continue
        [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" == "down" ] && continue

        local pure="${T_NAME#gre6ir}"; pure="${pure#gre6kh}"; pure="${pure#greir}"; pure="${pure#grekh}"
        local c_sub="${CORE_SUBNET}"
        mt_tunnel_addresses || continue
        local peer_vip="$MT_CORE_PEER"; REMOTE_PUB="$MT_REMOTE_PUBLIC"
        
        local vip_stat="OFF"
        [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null && vip_stat="+${MAX_IPS}"

        local ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_vip" 2>/dev/null)
        local loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
        [ -z "$loss" ] && loss="100"
        local avg="---"
        if echo "$ping_res" | grep -q "min/avg/max"; then
            avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
            if [ -n "$avg" ]; then
                avg=$(awk -v v="$avg" 'BEGIN {printf "%.0f", v}')
                avg="${avg}ms"
            fi
        fi

        local fwd_str="OFF"
        if [ "$TYPE" == "1" ]; then
            if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
            elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:4}"
            elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:4}"
            fi
        else fwd_str="GW"; fi

        echo "GRE|${pure:-$T_NAME}|${REMOTE_PUB}|${vip_stat}|${avg}|${loss}|${T_NAME}|${fwd_str}" >> "$tmp_target"
        ((count++))
        [ "$count" -ge 3 ] && break 2
    done

    # 2. VXLAN
    if [ "$count" -lt 3 ]; then
        for conf in /etc/mgre/vxlan/*.conf; do
            [ -f "$conf" ] || continue
            TYPE=""; VX_NAME=""; TUN_PROTO="ipv4"; CORE_V6=""; LOCAL_PUB6=""; REMOTE_PUB6=""; FAB_PROTO="ipv4"; REMOTE_PUB=""; CORE_SUBNET=""; VNI_ID=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; source "$conf" 2>/dev/null
            [ -z "$VX_NAME" ] && continue

            ip link show "$VX_NAME" >/dev/null 2>&1 || continue
            [ "$(cat /sys/class/net/$VX_NAME/operstate 2>/dev/null)" == "down" ] && continue

            local pure="${VX_NAME#vx_}"
            local c_sub="${CORE_SUBNET:-10.88.${VNI_ID}}"
            mt_tunnel_addresses || continue
            local peer_vip="$MT_CORE_PEER"; REMOTE_PUB="$MT_REMOTE_PUBLIC"

            local vip_stat="OFF"
            [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null && vip_stat="+${MAX_IPS}"

            local ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_vip" 2>/dev/null)
            local loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
            [ -z "$loss" ] && loss="100"
            local avg="---"
            if echo "$ping_res" | grep -q "min/avg/max"; then
                avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
                if [ -n "$avg" ]; then
                    avg=$(awk -v v="$avg" 'BEGIN {printf "%.0f", v}')
                    avg="${avg}ms"
                fi
            fi

            local fwd_str="OFF"
            if [ "$TYPE" == "1" ]; then
                if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
                elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:4}"
                elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:4}"
                fi
            else fwd_str="GW"; fi

            echo "VXLAN|${pure:-$VX_NAME}|${REMOTE_PUB}|${vip_stat}|${avg}|${loss}|${VX_NAME}|${fwd_str}" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi

    # 3. Backhaul
    if [ "$count" -lt 3 ]; then
        for conf in /etc/mbackhaul/tunnels/*.meta; do
            [ -f "$conf" ] || continue
            local t_name=$(basename "$conf" .meta)
            ROLE=""; TUN_PORT=""; REMOTE_IP=""; PORTS=""; source "$conf" 2>/dev/null
            systemctl is-active --quiet "mbackhaul@${t_name}" || continue

            local pure="${t_name#bh_}"
            local peer_ip="$REMOTE_IP"
            if [ "$ROLE" == "1" ]; then
                local conn=$(ss -tn src ":$TUN_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
                peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                [ -z "$peer_ip" ] && peer_ip="Listening"
            fi

            local avg="---" loss="0"
            if [[ "$peer_ip" =~ ^[0-9.]+$ ]]; then
                local ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_ip" 2>/dev/null)
                loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
                [ -z "$loss" ] && loss="100"
                if echo "$ping_res" | grep -q "min/avg/max"; then
                    avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
                    if [ -n "$avg" ]; then
                        avg=$(awk -v v="$avg" 'BEGIN {printf "%.0f", v}')
                        avg="${avg}ms"
                    fi
                fi
            fi

            local fwd_str="OFF"
            [ -n "$PORTS" ] && fwd_str="ACT"
            [ "$ROLE" == "2" ] && fwd_str="CLI"

            echo "BH|${pure:-$t_name}|${peer_ip}|OFF|${avg}|${loss}|bh_${t_name}|${fwd_str}" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi

    # 4. Rathole
    if [ "$count" -lt 3 ]; then
        for d in /etc/mrathole/tunnels/*; do
            [ -d "$d" ] && [ -f "$d/meta.conf" ] || continue
            local t_name=$(basename "$d")
            TYPE=""; LINK_PORT=""; REMOTE_IP=""; TCP_PORTS=""; UDP_PORTS=""; source "$d/meta.conf" 2>/dev/null
            systemctl is-active --quiet "mrathole@${t_name}" || continue

            local peer_ip="$REMOTE_IP"
            if [ "$TYPE" == "1" ]; then
                local conn=$(ss -tn src ":$LINK_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
                peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                [ -z "$peer_ip" ] && peer_ip="Listening"
            fi

            local avg="---" loss="0"
            if [[ "$peer_ip" =~ ^[0-9.]+$ ]]; then
                local ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_ip" 2>/dev/null)
                loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
                [ -z "$loss" ] && loss="100"
                if echo "$ping_res" | grep -q "min/avg/max"; then
                    avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
                    if [ -n "$avg" ]; then
                        avg=$(awk -v v="$avg" 'BEGIN {printf "%.0f", v}')
                        avg="${avg}ms"
                    fi
                fi
            fi

            local fwd_str="OFF"
            [ -n "$TCP_PORTS" ] || [ -n "$UDP_PORTS" ] && fwd_str="ACT"
            [ "$TYPE" == "2" ] && fwd_str="CLI"

            echo "RAT|${t_name}|${peer_ip}|OFF|${avg}|${loss}|rat_${t_name}|${fwd_str}" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi

    # 5. Paqet
    if [ "$count" -lt 3 ]; then
        for conf in /etc/paqet/*.meta; do
            [ -f "$conf" ] || continue
            local t_name=$(basename "$conf" .meta)
            ROLE=""; TUN_PORT=""; REMOTE_IP=""; source "$conf" 2>/dev/null
            systemctl is-active --quiet "mpaqet@${t_name}" || continue

            local pure="${t_name#pq_}"
            local peer_ip="$REMOTE_IP"
            if [ "$ROLE" == "1" ]; then
                local conn=$(ss -tn src ":$TUN_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
                peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
                [ -z "$peer_ip" ] && peer_ip="Listening"
            fi

            local avg="---" loss="0"
            if [[ "$peer_ip" =~ ^[0-9.]+$ ]]; then
                local ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_ip" 2>/dev/null)
                loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
                [ -z "$loss" ] && loss="100"
                if echo "$ping_res" | grep -q "min/avg/max"; then
                    avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
                    if [ -n "$avg" ]; then
                        avg=$(awk -v v="$avg" 'BEGIN {printf "%.0f", v}')
                        avg="${avg}ms"
                    fi
                fi
            fi

            echo "PAQET|${pure:-$t_name}|${peer_ip}|OFF|${avg}|${loss}|pq_${t_name}|RAW" >> "$tmp_target"
            ((count++))
            [ "$count" -ge 3 ] && break 2
        done
    fi

    mv -f "$tmp_target" "$SECURE_TMP/.main_tun_stats" 2>/dev/null
}

stats_watcher_loop() {
    while true; do
        collect_system_vitals
        collect_active_tunnels_stats
        kill -SIGUSR2 "$MAIN_PID" 2>/dev/null
        sleep "$STATS_CHECK_INTERVAL"
    done
}
stats_watcher_loop &
STATS_PID=$!

trap 'kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null' EXIT

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
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

draw_header_lines_only() {
    local s_ip=$(get_local_ip)
    s_ip="${s_ip:0:16}"

    local bbr_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')

    local web_col="${DIM}" web_icon="○" web_text="OFFLINE"
    if systemctl is-active --quiet mweb.service 2>/dev/null; then
        local w_port="1000"
        [ -f "/etc/mweb/web.conf" ] && w_port=$(grep "WEB_PORT" /etc/mweb/web.conf | cut -d= -f2 | tr -d ' ' | tr -d '\r')
        web_col="${G}"; web_icon="●"; web_text="PORT ${w_port}"
    fi

    local porter_col="${DIM}" porter_icon="○" porter_text="OFF"
    if systemctl is-active --quiet mporter.service 2>/dev/null || \
       systemctl is-active --quiet haproxy 2>/dev/null || \
       systemctl is-active --quiet gost 2>/dev/null || \
       systemctl is-active --quiet mporter-iptables 2>/dev/null; then
        porter_col="${G}"; porter_icon="●"; porter_text="ON"
    fi

    local bbr_col="${DIM}" bbr_icon="○" bbr_text="OFF"
    [ "$bbr_cc" == "bbr" ] && { bbr_col="${G}"; bbr_icon="●"; bbr_text="ON"; }

    local cpu_pct=0 cpu_cores=1 r_used="0G" r_total="0G" r_pct=0 rx_speed="0 B/s" tx_speed="0 B/s" v6_status="OFF"
    if [ -f "$SECURE_TMP/.main_sys_stats" ]; then
        IFS='|' read -r cpu_pct cpu_cores r_used r_total r_pct rx_speed tx_speed v6_status < "$SECURE_TMP/.main_sys_stats"
    fi

    local cpu_col="${G}"
    [ "$cpu_pct" -gt 60 ] 2>/dev/null && cpu_col="${Y}"
    [ "$cpu_pct" -gt 85 ] 2>/dev/null && cpu_col="${R}"
    local cpu_str="${cpu_pct}%"

    local core_label="${cpu_cores} Cores"
    [ "$cpu_cores" -eq 1 ] 2>/dev/null && core_label="1 Core"

    local ram_col="${G}"
    [ "$r_pct" -gt 70 ] 2>/dev/null && ram_col="${Y}"
    [ "$r_pct" -gt 88 ] 2>/dev/null && ram_col="${R}"
    local ram_str="${r_used}/${r_total} [${r_pct}%]"

    local rx_col="${DIM}"
    [[ "$rx_speed" != "0 B/s" && -n "$rx_speed" ]] && rx_col="${G}"

    local tx_col="${DIM}"
    [[ "$tx_speed" != "0 B/s" && -n "$tx_speed" ]] && tx_col="${Y}"

    local v6_col="${DIM}" v6_icon="○" v6_text="OFF"
    if [ "$v6_status" == "ON" ]; then
        v6_col="${G}"; v6_icon="●"; v6_text="ON"
    fi

    local border
    printf -v border '%*s' 117 ''
    border="${border// /─}"

    printf "\033[K\n"
    printf "  ${B}╭${border}╮${NC}\033[K\n"
    # Row 1: 31 | 25 | 21 | 18 | 18 = 117 columns
    printf "  ${B}│${NC} ${W}%-29.29s${NC} ${B}│${NC} ${DIM}Local:${NC} ${W}%-16.16s${NC} ${B}│${NC} ${DIM}Web:${NC} %b%s%b %-12.12s ${B}│${NC} ${DIM}Porter:${NC} %b%s%b %-6.6s ${B}│${NC} ${DIM}BBR:${NC} %b%s%b %-9.9s ${B}│${NC}\033[K\n" \
        "MDesign Master Core v${MODULE_VERSION}" "$s_ip" \
        "$web_col" "$web_icon" "$NC" "$web_text" \
        "$porter_col" "$porter_icon" "$NC" "$porter_text" \
        "$bbr_col" "$bbr_icon" "$NC" "$bbr_text"
    printf "  ${B}├${border}┤${NC}\033[K\n"
    # Row 2: 31 | 25 | 21 | 18 | 18 = 117 columns
    printf "  ${B}│${NC} ${DIM}CPU:${NC} %b%-4.4s%b   ${DIM}Cores:${NC} ${W}%-10.10s${NC} ${B}│${NC} ${DIM}RAM:${NC} %b%-18.18s%b ${B}│${NC} ${DIM}Net ▼:${NC} %b%-12.12s%b ${B}│${NC} ${DIM}Net ▲:${NC} %b%-9.9s%b ${B}│${NC} ${DIM}IPv6:${NC} %b%s%b %-8.8s ${B}│${NC}\033[K\n" \
        "$cpu_col" "$cpu_str" "$NC" "$core_label" \
        "$ram_col" "$ram_str" "$NC" \
        "$rx_col" "$rx_speed" "$NC" \
        "$tx_col" "$tx_speed" "$NC" \
        "$v6_col" "$v6_icon" "$NC" "$v6_text"
    printf "  ${B}├${border}┤${NC}\033[K\n"

    local shown=0
    if [ -f "$SECURE_TMP/.main_tun_stats" ]; then
        while IFS='|' read -r t_proto t_name t_remote t_vip t_ping t_loss t_dev t_fwd; do
            [ -z "$t_proto" ] && continue
            ((shown++))
            [ "$shown" -gt 3 ] && break

            local pure_name=$(echo "$t_name" | tr -d ' ')
            [ ${#pure_name} -gt 8 ] && pure_name="${pure_name:0:8}"
            local name_tag="${pure_name} [${t_proto}]"
            [ ${#name_tag} -gt 17 ] && name_tag="${name_tag:0:17}"

            [ ${#t_remote} -gt 16 ] && t_remote="${t_remote:0:16}"

            local if_uptime=$(get_iface_uptime_pure "$t_dev")
            local stat_icon="●"; local stat_col="${G}"
            if [ "$if_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi
            [ ${#if_uptime} -gt 10 ] && if_uptime="${if_uptime:0:10}"

            local fwd_col="${DIM}"; [ "$t_fwd" != "OFF" ] && fwd_col="${C}"
            local fwd_str="${t_fwd:0:9}"

            local vip_col="${DIM}"; [ "$t_vip" != "OFF" ] && vip_col="${G}"
            local vip_stat="${t_vip:0:5}"

            local live_ping="---"
            if [ -n "$t_ping" ] && [ "$t_ping" != "---" ]; then
                local num_p="${t_ping%ms}"
                if [[ "$num_p" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    live_ping=$(awk -v v="$num_p" 'BEGIN {printf "%.0fms", v}')
                else
                    live_ping="$t_ping"
                fi
            fi
            [ ${#live_ping} -gt 5 ] && live_ping="${live_ping:0:5}"

            local loss_col="${DIM}"; local loss_disp="---"
            if [ "$t_loss" != "---" ] && [ -n "$t_loss" ]; then
                loss_disp="${t_loss}%"
                if [ "$t_loss" -eq 0 ] 2>/dev/null; then loss_col="${G}"
                elif [ "$t_loss" -lt 30 ] 2>/dev/null; then loss_col="${Y}"
                else loss_col="${R}"; fi
            fi
            [ ${#loss_disp} -gt 4 ] && loss_disp="${loss_disp:0:4}"

            printf "  ${B}│${NC} %b%s%b ${W}%-17.17s${NC} ${B}│${NC} ${DIM}Peer:${NC} ${Y}%-16.16s${NC} ${B}│${NC} ${DIM}vIP:${NC}%b%-5.5s%b ${B}│${NC} ${DIM}Ping:${NC}${Y}%-5.5s${NC} ${B}│${NC} ${DIM}Loss:${NC}%b%-4.4s%b ${B}│${NC} ${DIM}Up:${NC} ${W}%-10.10s${NC} ${B}│${NC} ${DIM}FWD:${NC} %b%-9.9s%b ${B}│${NC}\033[K\n" \
                "$stat_col" "$stat_icon" "$NC" "$name_tag" "$t_remote" "$vip_col" "$vip_stat" "$NC" "$live_ping" "$loss_col" "$loss_disp" "$NC" "$if_uptime" "$fwd_col" "$fwd_str" "$NC"
        done < "$SECURE_TMP/.main_tun_stats"
    fi

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}● %-111.111s${NC}  ${B}│${NC}\033[K\n" "No active tunnels or fabrics deployed across the ecosystem."
    fi
    printf "  ${B}╰${border}╯${NC}\033[K\n"
}

draw_main_header() {
    clear
    draw_header_lines_only
}

refresh_header_live() {
    tput civis 2>/dev/null || true
    printf "\033[s"      # Save cursor position (ANSI)
    printf "\0337"       # Save cursor position (DEC)
    printf "\033[1;1H"   # Row 1, Col 1
    draw_header_lines_only
    printf "\0338"       # Restore cursor position (DEC)
    printf "\033[u"      # Restore cursor position (ANSI)
    tput cnorm 2>/dev/null || true
}

read_with_refresh() {
    local prompt="$1"
    local __resultvar="$2"
    local redraw_func="$3"
    local buffer=""
    local char rc

    echo -ne "$prompt"

    while true; do
        if [ "$NEED_REFRESH" = true ]; then
            NEED_REFRESH=false
            if [ -n "$redraw_func" ]; then
                "$redraw_func"
            fi
            echo -ne "$prompt$buffer"
        fi

        if [ "$NEED_LIVE_HEADER_REFRESH" = true ]; then
            NEED_LIVE_HEADER_REFRESH=false
            refresh_header_live
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
    if ! mt_download "$base_url/$rel_path" "$tmp" || ! mt_validate_script "$tmp"; then rm -f "$tmp"; return 1; fi
    local installed="/usr/bin/$mod"; [ "$mod" != main ] || installed="$MTUNNEL_PATH"
    local cur new; cur=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$installed" 2>/dev/null); new=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$tmp")
    if mt_is_newer_version "$cur" "$new"; then rm -f "$tmp"; return 1; fi
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
    [ -d "$src_dir" ] || return 1
    for name in bh rathole paqet gost haproxy; do
        source="$src_dir/$name"
        [ "$name" != bh ] || [ -f "$source" ] || source="$src_dir/backhaul"
        [ -f "$source" ] || continue
        mt_valid_elf "$source" || { echo "Invalid/incompatible binary: $source" >&2; rc=1; continue; }
        case "$name" in bh) unit=mbackhaul;; rathole) unit=mrathole;; paqet) unit=mpaqet;; *) unit="$name";; esac
        mt_update_core "$name" "$unit" "$source" local || rc=1
        if [ "$src_dir" != "$LOCAL_DIR/packages" ]; then mt_install_files 755 "$source" "$LOCAL_DIR/packages/$name" || rc=1; fi
    done
    local -a debs=()
    for deb in "$src_dir"/*.deb; do
        [ -f "$deb" ] || continue
        arch=$(dpkg-deb -f "$deb" Architecture 2>/dev/null) || { rc=1; continue; }
        if [ "$arch" != all ] && [ "$arch" != "$(dpkg --print-architecture)" ]; then echo "Wrong package architecture: $deb" >&2; rc=1; continue; fi
        debs+=("$deb")
    done
    if [ "${#debs[@]}" -gt 0 ]; then
        dpkg -i --force-confdef --force-confold "${debs[@]}" || rc=1
        ldconfig || rc=1
    fi
    return "$rc"
}

ensure_module() {
    local mod="$1"
    local rel_path="${MOD_MAP[$mod]}"
    [ -z "$rel_path" ] && rel_path="${mod}.sh"
    local target_file="$LOCAL_DIR/$rel_path"

    mkdir -p "$(dirname "$target_file")" 2>/dev/null

    if [ -s "$target_file" ]; then deploy_cached_module "$mod" && return 0; fi
    if [ -s "/usr/bin/$mod" ]; then
        cp -f "/usr/bin/$mod" "$target_file" 2>/dev/null || true
        chmod 0755 "$target_file" 2>/dev/null || true
        deploy_cached_module "$mod" && return 0
    fi
    if download_file_to_cache "$mod" "$REPO_SCRIPTS"; then deploy_cached_module "$mod" && return 0; fi
    echo -e "  ${R}✗ ${W}${mod}${R} is not available locally and GitHub download failed.${NC}"
    return 1
}

run_mod() { local mod="$1"; ensure_module "$mod" || return 1; "$mod"; }

install_bundle_scripts() {
    local source="$1" mod rel candidate target cur new
    local -a files=()
    [ -d "$source" ] || return 1
    for mod in "${ALL_MODULES[@]}"; do
        rel="${MOD_MAP[$mod]}"; candidate="$source/$rel"; target="/usr/bin/$mod"
        [ "$mod" != main ] || target="$MTUNNEL_PATH"
        mt_validate_script "$candidate" || return 1
        cur=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$target" 2>/dev/null)
        new=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$candidate")
        if mt_is_newer_version "$cur" "$new"; then echo "Refusing downgrade: $mod" >&2; return 1; fi
        files+=("$candidate" "$LOCAL_DIR/$rel" "$candidate" "$target")
    done
    mt_install_files 755 "${files[@]}" || return 1
    if [ "${2:-0}" == 1 ]; then
        local current=0 version
        for mod in "${ALL_MODULES[@]}"; do
            current=$((current+1)); rel="${MOD_MAP[$mod]}"
            version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$source/$rel")
            draw_item_progress "$current" "${#ALL_MODULES[@]}" "$mod" "$version"
        done
    fi
    return 0
}

sync_script_bundle() {
    local base="$1" stage mod rel rc=0
    stage=$(mktemp -d "$SECURE_TMP/sync.XXXXXX") || return 1
    # Stage all scripts and check Bash/version before committing any module.
    for mod in "${ALL_MODULES[@]}"; do
        rel="${MOD_MAP[$mod]}"
        mkdir -p "$(dirname "$stage/$rel")" || { rc=1; break; }
        if ! mt_download "$base/$rel" "$stage/$rel" || ! mt_validate_script "$stage/$rel"; then rc=1; break; fi
    done
    [ "$rc" != 0 ] || install_bundle_scripts "$stage" "${2:-0}" || rc=1
    rm -rf "$stage"
    return "$rc"
}



offline_local_deploy() {
    local source="$1" stage='' bundle rc=0
    [ -n "$source" ] || source="$PWD"
    if [ -f "$source" ]; then
        stage=$(mktemp -d "$SECURE_TMP/offline.XXXXXX") || return 1
        mt_extract_archive "$source" "$stage" || { rm -rf "$stage"; return 1; }
        source="$stage"
    fi
    [ -d "$source" ] || return 1
    bundle=$(find "$source" -maxdepth 3 -type f -name main.sh -printf '%h\n' | head -n 1)
    if [ -n "$bundle" ]; then
        install_bundle_scripts "$bundle" "${2:-0}" || { [ -z "$stage" ] || rm -rf "$stage"; return 1; }
        [ ! -d "$bundle/packages" ] || deploy_binaries_from_dir "$bundle/packages" || rc=1
    else deploy_binaries_from_dir "$source" || rc=1; fi
    [ -z "$stage" ] || rm -rf "$stage"
    return "$rc"
}

fetch_package_group() {
    local base="$1" kind="$2" item file rc=0
    local -a items=()
    if [ "$kind" == cores ]; then items=(bh rathole paqet gost haproxy); else items=("${ALL_PACKAGES[@]}"); fi
    local stage; stage=$(mktemp -d "$SECURE_TMP/packages.XXXXXX") || return 1
    for item in "${items[@]}"; do
        file="$stage/$item"
        if ! mt_download "$base/$item" "$file"; then rc=1; break; fi
        case "$item" in *.deb) dpkg-deb --info "$file" >/dev/null || { rc=1; break; };; *) mt_valid_elf "$file" || { rc=1; break; };; esac
    done
    if [ "$rc" == 0 ]; then
        local -a files=()
        for item in "${items[@]}"; do files+=("$stage/$item" "$LOCAL_DIR/packages/$item"); done
        mt_install_files 755 "${files[@]}" || rc=1
        if [ "$kind" == cores ] && [ "$rc" == 0 ]; then deploy_binaries_from_dir "$stage" || rc=1; fi
    fi
    if [ "$rc" == 0 ] && [ "${3:-0}" == 1 ]; then
        local current=0 version label
        for item in "${items[@]}"; do
            current=$((current+1)); label="$item"; version="${BIN_VERSIONS[$item]:-Core}"
            if [[ "$item" == *.deb ]]; then label="${item%%_*}"; version="${item#*_}"; version="${version%%_*}"; fi
            draw_item_progress "$current" "${#items[@]}" "$label" "$version"
        done
    fi
    rm -rf "$stage"
    return "$rc"
}

render_ota_menu() {
    draw_main_header
    echo -e "\n  ${DIM}┌─[ Update and Local Install ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SCRIPT CORE ENGINE UPDATES ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Sync All Scripts from Official GitHub${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Sync All Scripts from Iranian Mirror (ParsPack)${NC}"

    local main_sub_badge=""
    if [ -f "$UPDATE_FILE" ]; then
        local m_line=$(grep "^main:" "$UPDATE_FILE")
        if [ -n "$m_line" ]; then
            local o_v=$(echo "$m_line" | cut -d: -f2)
            local n_v=$(echo "$m_line" | cut -d: -f3)
            main_sub_badge="  ${Y}(v${o_v} ➔ v${n_v})${NC}"
        fi
    fi
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Update Master Core Dashboard (Main Script Only)${NC}${main_sub_badge}"

    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ BINARY CORES ONLY (BH, RAT, PAQET, GOST, HAPROXY) ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Fetch Binary Cores from Official GitHub${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${G}Fetch Binary Cores from Iranian Mirror${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ FULL PREREQUISITES & DEB PACKAGES ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${C}Fetch All Packages & Prerequisites from GitHub${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${G}Fetch All Packages & Prerequisites from Iranian Mirror${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MANUAL & OVERRIDE METHODS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${Y}Custom Personal Link (.sh Script or ZIP)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${M}Manual Code Paste (Raw Editor)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ LOCAL INSTALL ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${M}Offline Local Install (Directory / ZIP / Archive)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Dashboard${NC}\n"
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
        echo -e "\n  ${DIM}┌─[ MANUAL RAW CODE PASTE (EDITOR) ]${NC}\n  ${DIM}│${NC}"
    else
        echo -e "\n  ${DIM}┌─[ SELECT MODULE TARGET TO OVERWRITE ]${NC}\n  ${DIM}│${NC}"
    fi
    for i in "${!ALL_MODULES[@]}"; do
        branch='├─'; [ "$i" -ne "$((${#ALL_MODULES[@]}-1))" ] || branch='└─'
        echo -e "  ${DIM}${branch}${NC} ${W}$((i+1))${NC} ${DIM}❯${NC} ${C}${ALL_MODULES[$i]}${NC}"
    done
    echo -ne "\n  ${C}${mode} ❯❯ ${NC}"; read -r selection
    [[ "$selection" =~ ^[0-9]{1,2}$ ]] && ((10#$selection>=1 && 10#$selection<=${#ALL_MODULES[@]})) || return 1
    CHOSEN_MODULE="${ALL_MODULES[$((10#$selection-1))]}"
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

show_ota_update_hub() {
    local option base work url file module rel target confirm new_ver current_v kind source_name
    while true; do
        render_ota_menu
        read_with_refresh "  ${C}OTA-HUB ❯❯ ${NC}" option render_ota_menu
        option="${option//[$' \r']/}"
        case "$option" in
            0|'') return 0;;
            1|2)
                draw_main_header
                base="$REPO_SCRIPTS"; source_name='OFFICIAL GITHUB'
                if [ "$option" == 2 ]; then base="$MIRROR_SCRIPTS"; source_name='IRANIAN MIRROR (PARSPACK)'; fi
                echo -e "\n  ${DIM}┌─[ SYNCING ALL SCRIPTS FROM ${source_name} ]${NC}\n"
                if sync_script_bundle "$base" 1; then
                    : > "$UPDATE_FILE"
                    echo -e "\n\n  ${G}● Script sync finished. Press Enter to reload core...${NC}\n"
                    read -r confirm
                    reload_dashboard
                else
                    echo -e "\n  ${R}✖ Script update failed. Previous scripts preserved.${NC}\n" >&2
                fi;;
            3)
                draw_main_header
                echo -e "\n  ${DIM}┌─[ UPDATING MASTER CORE (MAIN.SH) ]${NC}\n"
                if download_file_to_cache main "$REPO_SCRIPTS" && deploy_cached_module main; then
                    new_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$LOCAL_DIR/main.sh")
                    draw_item_progress 1 1 main "$new_ver"
                    echo -e "\n\n  ${G}● Master Core successfully updated! Reloading...${NC}\n"
                    reload_dashboard
                else
                    draw_item_progress 1 1 main '' failed
                    echo -e "\n  ${R}✖ Main update failed. Previous installation preserved.${NC}\n" >&2
                fi;;
            4|5|6|7)
                draw_main_header
                base="$REPO_SCRIPTS/packages"; source_name='OFFICIAL GITHUB'
                if [[ "$option" == 5 || "$option" == 7 ]]; then base="$MIRROR_PACKAGES"; source_name='IRANIAN MIRROR (PARSPACK)'; fi
                kind=cores
                if [[ "$option" == 6 || "$option" == 7 ]]; then
                    kind=all
                    echo -e "\n  ${DIM}┌─[ FETCHING ALL PREREQUISITES & PACKAGES FROM ${source_name} ]${NC}\n"
                else
                    echo -e "\n  ${DIM}┌─[ FETCHING BINARY CORES FROM ${source_name} ]${NC}\n"
                fi
                if fetch_package_group "$base" "$kind" 1; then
                    echo -e "\n\n  ${G}● Package operation completed successfully.${NC}\n"
                else
                    echo -e "\n  ${R}✖ Package operation failed. Check the reported error.${NC}\n" >&2
                fi;;
            8|9)
                work=$(mktemp -d "$SECURE_TMP/manual.XXXXXX") || return 1
                file="$work/input"
                if [ "$option" == 8 ]; then
                    draw_main_header
                    echo -e "\n  ${DIM}┌─[ CUSTOM DIRECT LINK DEPLOYMENT ]${NC}\n"
                    echo -ne "  ${C}●${NC} ${W}Enter Direct (.sh or .zip) URL: ${NC}"; read -r url
                    [ -n "$url" ] || { rm -rf "$work"; continue; }
                    mt_download "$url" "$file" &
                    local pid=$!
                    draw_progress_bar "$pid" 'Downloading Custom Resource'
                    if ! wait "$pid"; then
                        echo -e "\n  ${R}✖ Download failed! Check URL.${NC}\n" >&2
                        rm -rf "$work"; ota_pause; continue
                    fi
                    mkdir "$work/extracted"
                    if mt_extract_archive "$file" "$work/extracted" 2>/dev/null; then
                        if offline_local_deploy "$work/extracted" 1; then
                            echo -e "\n  ${G}✔ Archive extracted and modules deployed successfully!${NC}\n"
                            rm -rf "$work"; reload_dashboard
                        else
                            echo -e "\n  ${R}✖ Bundle deployment failed.${NC}\n" >&2
                        fi
                        rm -rf "$work"; ota_pause; continue
                    fi
                    if ! mt_validate_script "$file" || ! choose_module; then
                        echo -e "\n  ${R}✖ Invalid script or cancelled selection.${NC}\n"
                        rm -rf "$work"; ota_pause; continue
                    fi
                else
                    if ! choose_module EDITOR; then rm -rf "$work"; continue; fi
                    echo -e "\n  ${DIM}● Opening clean editor... Paste your raw code, save (Ctrl+O, Enter) and exit (Ctrl+X).${NC}\n"
                    if command -v nano >/dev/null 2>&1; then nano "$file"
                    elif command -v vi >/dev/null 2>&1; then vi "$file"
                    else echo -e "  ${R}✖ No text editor (nano/vi) found!${NC}"; rm -rf "$work"; ota_pause; continue; fi
                    if ! mt_validate_script "$file"; then
                        echo -e "\n  ${R}✖ Invalid format or empty paste!${NC}\n"
                        rm -rf "$work"; ota_pause; continue
                    fi
                fi
                module="$CHOSEN_MODULE"; rel="${MOD_MAP[$module]}"; target="/usr/bin/$module"
                [ "$module" != main ] || target="$MTUNNEL_PATH"
                new_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$file")
                current_v=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$target" 2>/dev/null)
                draw_main_header
                echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}\n  ${DIM}│${NC}"
                echo -e "  ${DIM}├─${NC} ${W}Target Module   :${NC} ${C}${module}${NC}"
                echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${current_v:-Unknown}${NC}"
                echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
                echo -e "  ${DIM}│${NC}"
                echo -ne "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}"; read -r confirm
                if [[ "${confirm,,}" == y || "${confirm,,}" == yes ]]; then
                    if mt_install_script "$file" "$rel" "$target"; then
                        echo -e "\n  ${G}✔ Module ${module} (v${new_ver}) successfully applied! Rebooting core...${NC}\n"
                        rm -rf "$work"; reload_dashboard
                    else
                        echo -e "\n  ${R}✖ Module install failed. Previous module preserved.${NC}\n" >&2
                    fi
                else
                    echo -e "\n  ${Y}● Manual update cancelled by user.${NC}\n"
                fi
                rm -rf "$work";;
            10) show_local_install; continue;;
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
            local base_url="$MIRROR_PACKAGES"
            local fb_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/packages"
            local src_name="Iranian Mirror (ParsPack)"
            if [ "$src_choice" == "3" ]; then
                base_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/packages"
                fb_url="$MIRROR_PACKAGES"
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
                    mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
                    cp -f "$deb_f" "$LOCAL_DIR/packages/" 2>/dev/null
                    rm -f "$deb_f"
                fi
            done
            apt-get -o DPkg::Lock::Timeout=180 install -f -y -q >/dev/null 2>&1 || true
            ldconfig 2>/dev/null || true
            ;;
        4)
            echo -e "\n  ${DIM}● Checking local packages directory for iperf3 and libiperf...${NC}"
            local found_any=false
            for deb in $(find "$LOCAL_DIR/packages" -type f \( -name "*libiperf*.deb" -o -name "*iperf3*.deb" \) 2>/dev/null | sort -V); do
                if [ -s "$deb" ]; then
                    dpkg -i --force-confdef --force-confold "$deb" >/dev/null 2>&1
                    found_any=true
                fi
            done
            if [ "$found_any" = true ]; then
                apt-get -o DPkg::Lock::Timeout=180 install -f -y -q >/dev/null 2>&1 || true
                ldconfig 2>/dev/null || true
            else
                echo -e "  ${R}✖ No iPerf3 or libiperf .deb packages found in ${LOCAL_DIR}/packages/${NC}"
                sleep 2
                return 1
            fi
            ;;
        5)
            echo -ne "  ${C}● Enter Direct (.deb) Link: ${NC}"; read custom_url
            custom_url=$(echo "$custom_url" | tr -d '\r ')
            if [ -n "$custom_url" ]; then
                echo -e "\n  ${DIM}● Downloading custom package...${NC}"
                local dl_target="$SECURE_TMP/custom_iperf.deb"
                rm -f "$dl_target"
                (
                    if command -v curl >/dev/null 2>&1; then
                        curl -fsSL --connect-timeout 10 --max-time 60 -o "$dl_target" "$custom_url" 2>/dev/null
                    elif command -v wget >/dev/null 2>&1; then
                        wget -q  --header="Cache-Control: no-cache" --timeout=15 -O "$dl_target" "$custom_url" 2>/dev/null
                    fi
                ) &
                local pid=$!
                draw_progress_bar "$pid" "Downloading Custom Package"
                wait "$pid" 2>/dev/null

                if [ -s "$dl_target" ]; then
                    dpkg -i --force-confdef --force-confold "$dl_target" >/dev/null 2>&1
                    apt-get -o DPkg::Lock::Timeout=180 install -f -y -q >/dev/null 2>&1 || true
                    ldconfig 2>/dev/null || true
                    mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
                    cp -f "$dl_target" "$LOCAL_DIR/packages/" 2>/dev/null
                fi
                rm -f "$dl_target"
            fi
            ;;
    esac

    if is_iperf3_valid; then
        echo -e "\n  ${G}✔ iPerf3 and shared libraries verified and functional.${NC}\n"
        sleep 1.5
        return 0
    else
        echo -e "\n  ${R}✖ Installation failed or shared libraries (libiperf.so.0) missing!${NC}\n"
        echo -e "  ${Y}Tip: Run 'apt-get install -y libiperf0 iperf3' or check package dependencies.${NC}\n"
        echo -ne "  ${DIM}Press Enter to return...${NC}\n"; read dummy
        return 1
    fi
}

run_iperf3() {
    if ! is_iperf3_valid; then
        draw_main_header
        echo -e "\n  ${DIM}┌─[ IPERF3 BENCHMARK INSTALLER ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official APT Repository (apt-get install libiperf0 iperf3)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror (.deb Packages)${NC} ${DIM}(c107328.parspack.net)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Official GitHub Packages (.deb)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Custom Direct Link (.deb)${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel / Return to Main Core${NC}\n"
        echo -ne "  ${C}Select Source ❯❯ ${NC}"; read inst_opt
        inst_opt=$(echo "$inst_opt" | tr -d '\r ')

        if [[ "$inst_opt" =~ ^[1-5]$ ]]; then
            install_iperf3_source "$inst_opt" || return 1
        else
            return 0
        fi
    fi

    render_iperf_menu() {
        draw_main_header
        echo -e "\n  ${DIM}┌─[ IPERF3 BANDWIDTH BENCHMARK (Port: 5201 TCP/UDP) ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run as Server (Listener Mode)${NC} ${DIM}(Wait for peer connections)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run as Client (Sender Mode)${NC}   ${DIM}(Push bandwidth stream to server)${NC}"
        echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    }

    while true; do
        render_iperf_menu
        read_with_refresh "  ${C}iPerf3 ❯❯ ${NC}" i_opt render_iperf_menu
        i_opt=$(echo "$i_opt" | tr -d '\r ' )

        case $i_opt in
            1)
                echo -e "\n  ${G}● iPerf3 Server listening on port 5201 (Press Ctrl+C to stop)...${NC}\n"
                iperf3 -s -p 5201
                echo -ne "\n  ${DIM}Press Enter to return...${NC}\n"; read dummy ;;
            2)
                echo -ne "\n  ${C}●${NC} ${W}Enter Target Server IP / Tunnel IP: ${NC}"; read t_ip
                t_ip=$(echo "$t_ip" | tr -d '\r ' )
                [ -z "$t_ip" ] && continue
                echo -ne "  ${C}●${NC} ${W}Test Duration in Seconds [Default 10]: ${NC}"; read t_sec
                t_sec=${t_sec:-10}
                echo -e "\n  ${Y}● Running Benchmark against $t_ip (10s)...${NC}\n"
                iperf3 -c "$t_ip" -p 5201 -t "$t_sec"
                echo -ne "\n  ${DIM}Press Enter to return...${NC}\n"; read dummy ;;
            0) break ;;
        esac
    done
}


module_update_badge() {
    local version
    version=$(awk -F: -v mod="$1" '$1==mod {print $3;exit}' "$UPDATE_FILE" 2>/dev/null)
    [ -z "$version" ] || printf ' %b' "${Y}(Update Available: v${version})${NC}"
    return 0
}

render_main_menu() {
    draw_main_header
    echo -e "\n  ${DIM}┌─[ TUNNEL INFRASTRUCTURE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}GRE / GRE6 / IPIP Tunnel${NC} $(module_update_badge mgre)"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}VXLAN Virtual Mesh Fabric${NC} $(module_update_badge mxlan)"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Rathole Reverse Tunnel${NC} $(module_update_badge mrathole)"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Backhaul Multiplexer${NC} $(module_update_badge mbackhaul)"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Paqet Raw Packet KCP Tunnel${NC} $(module_update_badge mpaqet)"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ ROUTING, MONITORING & BENCHMARK ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Port Forwarding Matrix (Mporter)${NC} $(module_update_badge mporter)"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${B}Bandwidth Radar & Web UI${NC} $(module_update_badge mstats)"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Two-Way Link & Port Filter Scanner (LinkTest)${NC} $(module_update_badge linktest)"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${C}iPerf3 Bandwidth Benchmark${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${G}Update and Local Install${NC} $(module_update_badge main)"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${R}Nuclear Wipe (Uninstall)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}\n"
}

show_local_install() {
    local local_input
    draw_main_header
    echo -e "\n  ${DIM}┌─[ OFFLINE LOCAL INSTALL ]${NC}\n"
    echo -ne "  ${C}●${NC} ${W}Enter local path (Directory, .zip, or .tar.gz) [Enter for current]: ${NC}"; read -r local_input
    draw_main_header
    echo -e "\n  ${DIM}┌─[ INSTALLING FROM LOCAL SOURCE ]${NC}\n"
    if offline_local_deploy "$local_input" 1; then
        echo -e "\n\n  ${G}● Local scripts and available binary packages installed successfully.${NC}\n"
    else echo -e "\n  ${R}✖ Local install failed. Check the reported error.${NC}\n" >&2; fi
    ota_pause
}

while true; do
    render_main_menu
    read_with_refresh "  ${C}CORE ❯❯ ${NC}" opt render_main_menu
    opt=$(echo "$opt" | tr -d '\r ')

    case $opt in
        1) run_mod "mgre" ;;
        2) run_mod "mxlan" ;;
        3) run_mod "mrathole" ;;
        4) run_mod "mbackhaul" ;;
        5) run_mod "mpaqet" ;;
        6) run_mod "mporter" ;;
        7) run_mod "mstats" ;;
        8) run_mod "linktest" ;;
        9) run_iperf3 ;;
        10) show_ota_update_hub ;;
        11)
            draw_main_header
            echo -e "\n  ${R}╭────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${R}│${NC} ${W}MTunnel Nuclear Wipe (Complete Uninstaller)${NC}                  ${R}│${NC}"
            echo -e "  ${R}╰────────────────────────────────────────────────────────────╯${NC}\n"
            echo -e "  ${Y}⚠ Warning: This will stop and remove all tunnels, services,${NC}"
            echo -e "  ${Y}  binary cores (rathole, backhaul, paqet, gost), and configs!${NC}\n"
            echo -ne "  ${R}Type WIPE-MTUNNEL to continue: ${NC}"; read del_confirm
            del_confirm="${del_confirm//[$' \r\n']/}"
            if [[ "$del_confirm" == "WIPE-MTUNNEL" ]]; then
                echo -e "\n  ${C}● Terminating services and wiping files...${NC}"
                
                systemctl stop mhealer.service mgre-watchdog.timer mxlan-watchdog.timer mporter-watchdog.service 2>/dev/null || true
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
                systemctl stop mgre-watchdog.timer mxlan-watchdog.timer mbackhaul-apply.service mrathole-apply.service mpaqet-apply.service mporter-iptables.service mporter-obfs.service gost.service realm.service 2>/dev/null || true
                systemctl disable mgre-watchdog.timer mxlan-watchdog.timer mbackhaul-apply.service mrathole-apply.service mpaqet-apply.service mporter-iptables.service mporter-obfs.service gost.service realm.service 2>/dev/null || true
                rm -f /etc/systemd/system/mgre-watchdog.{service,timer} /etc/systemd/system/mxlan-watchdog.{service,timer} /etc/systemd/system/{mbackhaul,mrathole,mpaqet}-apply.service /etc/systemd/system/mporter-{iptables,obfs}.service
                rm -f /usr/local/bin/mhealer_daemon.sh /usr/local/bin/mporter-{watchdog,iptables,obfs}.sh /etc/mhealer.conf
                rm -f /etc/systemd/system/{gost,realm}.service /var/lock/mporter-state.lock /run/mporter-backends.tsv
                rm -rf /etc/gost /etc/realm
                rm -rf /run/mtunnel-healer
                systemctl stop mgre.service mxlan.service mporter.service mporter-watchdog.service mweb.service mhealer.service mshield.service mbackhaul@* mrathole@* mpaqet@* gost@* 2>/dev/null || true
                systemctl disable mgre.service mxlan.service mporter.service mporter-watchdog.service mweb.service mhealer.service mshield.service mbackhaul@* mrathole@* mpaqet@* gost@* 2>/dev/null || true
                
                rm -f /etc/systemd/system/mgre.service \
                      /etc/systemd/system/mxlan.service \
                      /etc/systemd/system/mporter.service \
                      /etc/systemd/system/mporter-watchdog.service \
                      /etc/systemd/system/mweb.service \
                      /etc/systemd/system/mhealer.service \
                      /etc/systemd/system/mshield.service \
                      /etc/systemd/system/mbackhaul@.service \
                      /etc/systemd/system/mrathole@.service \
                      /etc/systemd/system/mpaqet@.service \
                      /etc/systemd/system/gost@.service 2>/dev/null || true
                systemctl daemon-reload 2>/dev/null || true

                rm -rf /etc/mgre /etc/mporter /etc/mweb /etc/mshield /etc/mstats /etc/mrathole /etc/mbackhaul /etc/paqet /etc/mhealer /etc/minterface /etc/mdiag /etc/linktest /etc/mbbr /root/mtunnel /tmp/custom-unzip.* /tmp/mtunnel-local-deploy.* 2>/dev/null || true

                rm -f /usr/bin/mtunnel /usr/bin/main /usr/bin/mgre /usr/bin/mxlan /usr/bin/mbackhaul /usr/bin/mpaqet /usr/bin/mporter /usr/bin/minterface /usr/bin/mdiag /usr/bin/mshield /usr/bin/mstats /usr/bin/mhealer /usr/bin/mweb /usr/bin/mrathole /usr/bin/mbbr /usr/bin/linktest

                rm -f /usr/local/bin/rathole /usr/local/bin/bh /usr/local/bin/backhaul /usr/local/bin/paqet /usr/local/bin/gost /usr/local/bin/frpc /usr/local/bin/frps /usr/local/bin/haproxy /usr/local/bin/realm /usr/bin/bh /usr/bin/rathole /usr/bin/paqet /usr/local/bin/mtunnel

                kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
                echo -e "\n  ${G}✓ MTunnel ecosystem completely wiped from this system.${NC}\n"; exit 0
            else
                echo -e "\n  ${Y}● Wipe cancelled.${NC}"; sleep 1.5
            fi
            ;;

        0) 
            kill "$WATCHER_PID" "$STATS_PID" 2>/dev/null
            clear; exit 0
            ;;
    esac
done
