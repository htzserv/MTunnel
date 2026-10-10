#!/bin/bash
# --- MBackhaul Modular Core (mbackhaul.sh) | MDesign Ecosystem v12.0.3 ---
# [Features: Leak-Free Updater | Strict Port Guard | Universal Download | Port Collision Check]

MODULE_VERSION="13.0.2"

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
    command -v iptables >/dev/null 2>&1 || missing+=("iptables")
    command -v flock >/dev/null 2>&1 || missing+=("util-linux")
    command -v openssl >/dev/null 2>&1 || missing+=("openssl")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
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
    return 0
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

# Fetch from both official and mirror sources; keep the highest version.
# Unreachable mirrors leave the previous good cache intact.
mt_mbackhaul_remote_version() {
    local url="$1" payload version
    if command -v curl >/dev/null 2>&1; then
        payload=$(curl -fsSL --connect-timeout 3 --max-time 7 "$url" 2>/dev/null) || return 1
    elif command -v wget >/dev/null 2>&1; then
        payload=$(wget -qO- --timeout=7 "$url" 2>/dev/null) || return 1
    else return 1; fi
    version=$(printf '%s\n' "$payload" | sed -n 's/^MODULE_VERSION="\([0-9][0-9.]*\)".*/\1/p' | head -n 1)
    [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
    printf '%s\n' "$version"
}

check_update_bg() {
    local cb="?t=$(date +%s)" gh mirror latest cache="$SECURE_TMP/.mbackhaul_remote_ver"
    gh=$(mt_mbackhaul_remote_version "https://raw.githubusercontent.com/htzserv/MTunnel/main/tunnels/mbackhaul.sh${cb}")
    mirror=$(mt_mbackhaul_remote_version "https://c107328.parspack.net/c107328/MTunnel/tunnels/mbackhaul.sh${cb}")
    latest=$(printf '%s\n' "$gh" "$mirror" | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -n 1)
    [ -n "$latest" ] || return 1
    [ -f "$cache" ] && [ "$(cat "$cache")" = "$latest" ] && return 1
    printf '%s\n' "$latest" > "$cache"
}

update_watcher_loop() {
    while true; do
        if check_update_bg && [ -f "$SECURE_TMP/.mbackhaul_in_menu" ]; then
            kill -SIGUSR1 "$MAIN_PID" 2>/dev/null || true
        fi
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
if [[ "${1:-}" != --* ]]; then update_watcher_loop & fi
WATCHER_PID=$!
trap 'kill "$WATCHER_PID" 2>/dev/null; rm -f "$SECURE_TMP/.mbackhaul_in_menu" 2>/dev/null' EXIT

self_update_module() {
    local src_opt custom_url dl_url tmp_file confirm
    local rel_path="tunnels/mbackhaul.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mbackhaul_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mbackhaul_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA Update (MBackhaul) ]${NC}"
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

bh_select_transport() {
    local choice
    echo -e "\n  ${DIM}┌─[ TRANSPORT PROTOCOL ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}TCP${NC}       ${W}2${NC} ${DIM}❯${NC} ${C}TCPMUX${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}WSMUX${NC}     ${W}4${NC} ${DIM}❯${NC} ${G}WSSMUX (TLS)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}WS${NC}        ${W}6${NC} ${DIM}❯${NC} ${G}WSS (TLS)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${Y}UDP (UDP applications only)${NC}"
    echo -ne "  ${DIM}└─${NC} ${C}Select [1-7 | q: cancel] ❯❯ ${NC}"; read -r choice || return 1
    case "$choice" in
        1) BH_TRANSPORT=tcp;; 2) BH_TRANSPORT=tcpmux;; 3) BH_TRANSPORT=wsmux;;
        4) BH_TRANSPORT=wssmux;; 5) BH_TRANSPORT=ws;; 6) BH_TRANSPORT=wss;;
        7) BH_TRANSPORT=udp;; *) return 1;;
    esac
}

bh_load_options() {
    local meta="$1" override="${2:-}" key value file
    declare -gA BH_OPTS=([KEEPALIVE]=75 [HEARTBEAT]=40 [CHANNEL]=4096 [POOL]=8
        [RETRY]=3 [DIAL]=10 [AGGRESSIVE]=false [NODELAY]=true [LOG]=info
        [MUX_CON]=8 [MUX_VERSION]=1 [MUX_FRAME]=32768 [MUX_RECEIVE]=4194304 [MUX_STREAM]=65536
        [MTU]=0 [MSS]=1360 [RCVBUF]=4194304 [SNDBUF]=4194304 [PROXY]=false
        [EDGE]="" [TLS_CERT]="" [TLS_KEY]="")
    for file in "$meta" "$override"; do
        [ -n "$file" ] && [ -f "$file" ] || continue
        while IFS='=' read -r key value; do
            [[ "$key" == ADV_* ]] || continue; key="${key#ADV_}"
            [[ "$key" =~ ^[A-Z_]+$ ]] && [[ -v BH_OPTS[$key] ]] || return 1
            BH_OPTS[$key]="$value"
        done < "$file"
    done
    bh_validate_options
}

bh_validate_options() {
    local key value min max
    for key in KEEPALIVE HEARTBEAT CHANNEL POOL RETRY DIAL MUX_CON MUX_VERSION MUX_FRAME MUX_RECEIVE MUX_STREAM MTU MSS RCVBUF SNDBUF; do
        value="${BH_OPTS[$key]}"
        [[ "$value" =~ ^[0-9]{1,9}$ ]] || { echo "Invalid $key." >&2; return 1; }
        value=$((10#$value)); BH_OPTS[$key]="$value"
        min=1; max=3600
        case "$key" in
            CHANNEL) max=65536;; POOL|MUX_CON) max=1024;; MUX_VERSION) max=2;;
            MUX_FRAME) min=512; max=65535;; MUX_RECEIVE) min=65536; max=134217728;;
            MUX_STREAM) min=1024; max=134217728;; MTU) min=0; max=9000;; MSS) min=0; max=8960;;
            RCVBUF|SNDBUF) min=0; max=134217728;;
        esac
        ((value>=min && value<=max)) || { echo "$key must be $min-$max." >&2; return 1; }
    done
    ((BH_OPTS[MUX_STREAM]<=BH_OPTS[MUX_RECEIVE])) || { echo 'MUX stream buffer must not exceed receive buffer.' >&2; return 1; }
    ((BH_OPTS[MTU]==0 || BH_OPTS[MTU]>=1280)) || { echo 'Link MTU must be 0 or 1280-9000.' >&2; return 1; }
    ((BH_OPTS[MSS]==0 || BH_OPTS[MSS]>=536)) || { echo 'MSS must be 0 or 536-8960.' >&2; return 1; }
    for key in AGGRESSIVE NODELAY PROXY; do [[ "${BH_OPTS[$key]}" =~ ^(true|false)$ ]] || return 1; done
    [[ "${BH_OPTS[LOG]}" =~ ^(trace|debug|info|warn|error)$ ]] || return 1
    [ -z "${BH_OPTS[EDGE]}" ] || mt_valid_ipv4 "${BH_OPTS[EDGE]}" || mt_valid_ipv6 "${BH_OPTS[EDGE]}" || return 1
    for key in TLS_CERT TLS_KEY; do
        [ -z "${BH_OPTS[$key]}" ] || [[ "${BH_OPTS[$key]}" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    done
    [[ -z "${BH_OPTS[TLS_CERT]}" && -z "${BH_OPTS[TLS_KEY]}" || -n "${BH_OPTS[TLS_CERT]}" && -n "${BH_OPTS[TLS_KEY]}" ]] || return 1
}

bh_ask_option() {
    local key="$1" label="$2" value old="${BH_OPTS[$1]}"
    while true; do
        echo -ne "  ${DIM}├─${NC} ${W}$label [${old:-auto}; Enter: keep; -: auto/empty]${NC} ${C}❯❯ ${NC}"
        read -r value || return 1; value="${value//$'\r'/}"
        [ -n "$value" ] || return 0
        [ "$value" != - ] || { value=""; [[ "$key" != MTU && "$key" != MSS && "$key" != RCVBUF && "$key" != SNDBUF ]] || value=0; }
        BH_OPTS[$key]="$value"
        if bh_validate_options; then return 0; fi
        BH_OPTS[$key]="$old"; echo -e "  ${R}✖ Invalid value; try again.${NC}"
    done
}

bh_advanced_wizard() {
    local name="$1" role="$2" transport="$3" choice key
    bh_load_options "$CONF_DIR/$name.meta" || return 1
    BH_SETTINGS_FILE=""
    echo -e "\n  ${DIM}┌─[ ADVANCED TUNNEL SETTINGS ]${NC}"
    echo -ne "  ${DIM}├─${NC} ${W}Customize settings? [y/N]${NC} ${C}❯❯ ${NC}"; read -r choice || return 1
    if [[ "${choice,,}" == y || "${choice,,}" == yes ]]; then
        bh_ask_option LOG 'Log level (trace/debug/info/warn/error)' || return 1
        if [ "$role" = 1 ]; then
            bh_ask_option CHANNEL 'Pending channel capacity (1-65536)' || return 1
            bh_ask_option HEARTBEAT 'Heartbeat interval (seconds)' || return 1
        else
            bh_ask_option POOL 'Connection pool (1-1024)' || return 1
            bh_ask_option RETRY 'Retry interval (seconds)' || return 1
            if [ "$transport" != udp ]; then
                bh_ask_option DIAL 'Dial timeout (seconds)' || return 1
                bh_ask_option AGGRESSIVE 'Aggressive pool (true/false)' || return 1
            fi
        fi
        [ "$transport" = udp ] || bh_ask_option KEEPALIVE 'TCP keepalive (seconds)' || return 1
        if [[ "$transport" == *mux ]]; then
            echo -e "  ${DIM}├─${NC} ${Y}Use matching MUX version/frame/buffer settings on both peers.${NC}"
            [ "$role" != 1 ] || bh_ask_option MUX_CON 'Streams per MUX connection (1-1024)' || return 1
            bh_ask_option MUX_VERSION 'MUX version (1/2)' || return 1
            bh_ask_option MUX_FRAME 'Maximum MUX frame (bytes, 512-65535)' || return 1
            bh_ask_option MUX_RECEIVE 'MUX receive buffer (bytes)' || return 1
            bh_ask_option MUX_STREAM 'MUX stream buffer (bytes <= receive buffer)' || return 1
        fi
        if [[ "$transport" == tcp || "$transport" == tcpmux ]]; then
            bh_ask_option NODELAY 'TCP_NODELAY (true/false)' || return 1
            echo -e "  ${DIM}├─${NC} ${W}Link MTU derives TCP MSS = MTU - 60 (IPv6-safe); interface MTU is unchanged.${NC}"
            bh_ask_option MTU 'Link MTU (0: use MSS below; 1280-9000)' || return 1
            [ "${BH_OPTS[MTU]}" != 0 ] || bh_ask_option MSS 'TCP MSS (0: kernel default)' || return 1
            bh_ask_option RCVBUF 'Socket receive buffer (bytes; 0: kernel default)' || return 1
            bh_ask_option SNDBUF 'Socket send buffer (bytes; 0: kernel default)' || return 1
        fi
        if [ "$role" = 1 ] && [[ "$transport" == tcp || "$transport" == *mux ]]; then
            echo -e "  ${DIM}├─${NC} ${Y}PROXY protocol requires a compatible service at the destination.${NC}"
            bh_ask_option PROXY 'Send PROXY protocol header (true/false)' || return 1
        fi
        if [ "$role" = 2 ] && [[ "$transport" == ws* ]]; then bh_ask_option EDGE 'Optional WebSocket edge IP' || return 1; fi
        if [ "$role" = 1 ] && [[ "$transport" == wss || "$transport" == wssmux ]]; then
            echo -e "  ${DIM}├─${NC} ${W}TLS paths: leave both empty for a generated certificate.${NC}"
            # Both paths are collected together; validate the pair after collection.
            echo -ne "  ${DIM}├─${NC} ${W}Certificate path [${BH_OPTS[TLS_CERT]:-generated}; -: generated]${NC} ${C}❯❯ ${NC}"; read -r choice || return 1
            if [ "$choice" = - ]; then BH_OPTS[TLS_CERT]=""; BH_OPTS[TLS_KEY]=""
            elif [ -n "$choice" ]; then
                BH_OPTS[TLS_CERT]="$choice"
                echo -ne "  ${DIM}├─${NC} ${W}Private key path${NC} ${C}❯❯ ${NC}"; read -r choice || return 1; BH_OPTS[TLS_KEY]="$choice"
            fi
        fi
    fi
    bh_validate_options || return 1
    BH_SETTINGS_FILE=$(mktemp "$SECURE_TMP/bh-settings.XXXXXX") || return 1
    for key in "${!BH_OPTS[@]}"; do printf 'ADV_%s=%s\n' "$key" "${BH_OPTS[$key]}"; done > "$BH_SETTINGS_FILE"
}

bh_emit_options() {
    local role="$1" transport="$2" key mss="${BH_OPTS[MSS]}"
    printf 'log_level = "%s"\nsniffer = false\nweb_port = 0\n' "${BH_OPTS[LOG]}"
    if [ "$role" = 1 ]; then
        printf 'channel_size = %s\nheartbeat = %s\n' "${BH_OPTS[CHANNEL]}" "${BH_OPTS[HEARTBEAT]}"
    else
        printf 'connection_pool = %s\nretry_interval = %s\n' "${BH_OPTS[POOL]}" "${BH_OPTS[RETRY]}"
        [ "$transport" = udp ] || printf 'dial_timeout = %s\naggressive_pool = %s\n' "${BH_OPTS[DIAL]}" "${BH_OPTS[AGGRESSIVE]}"
        if [[ "$transport" == ws* ]]; then
            local edge="${BH_OPTS[EDGE]}"; [[ "$edge" != *:* ]] || edge="[$edge]"
            printf 'edge_ip = "%s"\n' "$edge"
        fi
    fi
    [ "$transport" = udp ] || printf 'keepalive_period = %s\n' "${BH_OPTS[KEEPALIVE]}"
    if [[ "$transport" == *mux ]]; then
        [ "$role" != 1 ] || printf 'mux_con = %s\n' "${BH_OPTS[MUX_CON]}"
        printf 'mux_version = %s\nmux_framesize = %s\nmux_recievebuffer = %s\nmux_streambuffer = %s\n' "${BH_OPTS[MUX_VERSION]}" "${BH_OPTS[MUX_FRAME]}" "${BH_OPTS[MUX_RECEIVE]}" "${BH_OPTS[MUX_STREAM]}"
    fi
    if [[ "$transport" == tcp || "$transport" == tcpmux ]]; then
        [ "${BH_OPTS[MTU]}" = 0 ] || mss=$((BH_OPTS[MTU]-60))
        printf 'nodelay = %s\nmss = %s\nso_rcvbuf = %s\nso_sndbuf = %s\n' "${BH_OPTS[NODELAY]}" "$mss" "${BH_OPTS[RCVBUF]}" "${BH_OPTS[SNDBUF]}"
    fi
    if [ "$role" = 1 ] && [[ "$transport" == tcp || "$transport" == *mux ]]; then printf 'proxy_protocol = %s\n' "${BH_OPTS[PROXY]}"; fi
}

bh_validate_tls_pair() {
    local cert="$1" key="$2" certpub keypub
    command -v openssl >/dev/null 2>&1 || { echo 'Install openssl for WSS / WSSMUX.' >&2; return 1; }
    [ -f "$cert" ] && [ -f "$key" ] || return 1
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
    certpub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || return 1
    keypub=$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null) || return 1
    [ -n "$certpub" ] && [ "$certpub" = "$keypub" ]
}

bh_service_ready() {
    local unit="$1" i
    for i in 1 2 3 4; do sleep 0.4; systemctl is-active --quiet "$unit" || return 1; done
}

bh_start_screen() {
    clear
    draw_header
}

bh_ensure_download_tools() {
    local need_zip="${1:-0}" missing=() log
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then missing+=(curl); fi
    if [ "$need_zip" = 1 ] && ! command -v unzip >/dev/null 2>&1; then missing+=(unzip); fi
    [ -s /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
    [ "${#missing[@]}" -gt 0 ] || return 0
    command -v apt-get >/dev/null 2>&1 || { echo "Install the missing packages: ${missing[*]}" >&2; return 1; }
    echo -e "  ${DIM}● Installing download prerequisites: ${missing[*]}...${NC}"
    log=$(mktemp "$SECURE_TMP/rh-deps.XXXXXX") || return 1
    apt-get update -q > "$log" 2>&1 || true
    if ! apt-get install -y -q "${missing[@]}" >> "$log" 2>&1; then
        echo 'Download prerequisites could not be installed:' >&2
        tail -n 6 "$log" >&2; rm -f "$log"; return 1
    fi
    rm -f "$log"
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || return 1
    [ "$need_zip" != 1 ] || command -v unzip >/dev/null 2>&1 || return 1
    [ -s /etc/ssl/certs/ca-certificates.crt ] || { echo 'System CA certificate bundle is missing.' >&2; return 1; }
}

bh_download() {
    local url="$1" dest="$2" expected="${3:-}" tmp log tool family rc=1 code permanent=false
    [[ "$url" == https://* ]] || { echo 'Download requires an HTTPS URL.' >&2; return 1; }
    [[ -z "$expected" || "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { echo 'Invalid expected SHA256.' >&2; return 1; }
    tmp=$(mktemp "${dest}.download.XXXXXX") || return 1
    log=$(mktemp "$SECURE_TMP/rh-download.XXXXXX") || { rm -f "$tmp"; return 1; }
    local -a args=()
    for tool in curl wget; do
        command -v "$tool" >/dev/null 2>&1 || continue
        for family in auto ipv4; do
            args=(); [ "$family" != ipv4 ] || args=(-4)
            : > "$tmp"
            echo -e "  ${DIM}● Downloading with $tool ($family)...${NC}"
            if [ "$tool" = curl ]; then
                code=$(curl "${args[@]}" -fsSL --proto '=https' --proto-redir '=https' \
                    --connect-timeout 10 --max-time 120 --retry 1 -w '%{http_code}' -o "$tmp" "$url" 2> "$log"); rc=$?
                if [ "$rc" = 22 ] && [[ "$code" =~ ^(400|401|403|404|410)$ ]]; then permanent=true; fi
            else
                wget "${args[@]}" --https-only --timeout=30 --tries=2 -O "$tmp" "$url" 2> "$log"; rc=$?
                [ "$rc" != 8 ] || permanent=true
            fi
            if [ "$rc" = 0 ] && [ -s "$tmp" ]; then
                if [ -n "$expected" ] && [ "$(sha256sum "$tmp" | cut -d' ' -f1)" != "${expected,,}" ]; then
                    echo 'Downloaded package SHA256 does not match; installation refused.' >&2
                    rm -f "$tmp" "$log"; return 1
                fi
                mv -f "$tmp" "$dest"; rc=$?
                rm -f "$log"; return "$rc"
            fi
            [ "$permanent" != true ] || break
        done
        [ "$permanent" != true ] || break
    done
    echo 'Backhaul download failed:' >&2
    if [ -s "$log" ]; then tail -n 4 "$log" >&2; else echo 'The server returned an empty file or no downloader is available.' >&2; fi
    rm -f "$tmp" "$log"; return 1
}

generate_ssl_cert() {
    command -v openssl >/dev/null 2>&1 || { echo 'Install openssl before using WSS / WSSMUX.' >&2; return 1; }
    if bh_validate_tls_pair "$CERT_DIR/wssmux.crt" "$CERT_DIR/wssmux.key"; then return 0; fi
    local work; work=$(mktemp -d "$SECURE_TMP/bh-cert.XXXXXX") || return 1
    mkdir -p "$CERT_DIR" || { rm -rf "$work"; return 1; }
    if ! openssl req -x509 -newkey rsa:2048 -keyout "$work/key" -out "$work/cert" -days 3650 -nodes \
        -subj "/CN=mdesign-backhaul" -addext "subjectAltName=DNS:mdesign-backhaul,IP:127.0.0.1,IP:::1" >/dev/null 2>&1 || \
        ! bh_validate_tls_pair "$work/cert" "$work/key" || \
        ! mt_install_files 600 "$work/cert" "$CERT_DIR/wssmux.crt" "$work/key" "$CERT_DIR/wssmux.key"; then
        rm -rf "$work"; echo 'TLS certificate generation failed.' >&2; return 1
    fi
    rm -rf "$work"
}

bh_validate_package() {
    local source="$1" stage item count=0
    mt_valid_elf "$source" && return 0
    stage=$(mktemp -d "$SECURE_TMP/rh-validate.XXXXXX") || return 1
    if ! mt_extract_archive "$source" "$stage"; then rm -rf "$stage"; return 1; fi
    while IFS= read -r item; do
        mt_valid_elf "$item" && count=$((count+1))
    done < <(find "$stage" -type f \( -name '*backhaul*' -o -name '*bh*' \))
    rm -rf "$stage"
    [ "$count" = 1 ]
}

install_core_from_source() {
    local src_choice="$1" triplet asset url kind=url source="" work item local_source="" need_zip=0
    triplet=$(case "$(uname -m)" in x86_64) echo amd64;; aarch64|arm64) echo arm64;; *) exit 1;; esac) || { echo -e "  ${R}✖ Unsupported CPU architecture.${NC}"; return 1; }
    asset="backhaul_linux_${triplet}.tar.gz"
    local -a urls=()
    case "$src_choice" in
        1) urls=("https://github.com/Musixal/Backhaul/releases/download/v0.7.2/$asset"); need_zip=0;;
        2)
            urls=("https://c107328.parspack.net/c107328/MTunnel/packages/$asset")
            # The unqualified mirror binary is the bundled x86_64 build only.
            [ "$triplet" != amd64 ] || urls+=("https://c107328.parspack.net/c107328/MTunnel/packages/bh")
            urls+=("https://github.com/Musixal/Backhaul/releases/download/v0.7.2/$asset")
            need_zip=0;;
        3)
            echo -ne "  ${C}● Enter Direct Link: ${NC}"; read -r url || return 0
            url="${url//$'\r'/}"; [ -n "$url" ] || return 0
            [[ "$url" == https://* ]] || { echo 'Use an HTTPS direct link.' >&2; return 1; }
            urls=("$url"); need_zip=0;;
        4)
            kind=local
            for item in "$LOCAL_DIR/packages/bh" "$LOCAL_DIR/packages/backhaul" "$LOCAL_DIR/packages/$asset"; do
                [ -f "$item" ] || continue
                if [[ "$item" != *.tar.gz && "$item" != *.zip ]] && ! mt_valid_elf "$item"; then continue; fi
                source="$item"; break
            done
            [ -n "$source" ] || { echo "No compatible Backhaul binary or $asset found in $LOCAL_DIR/packages." >&2; return 1; }
            [[ "$source" != *.zip ]] || need_zip=1;;
        *) return 0;;
    esac
    # Do not require internet/download utilities for a local binary.
    if [ "$kind" = url ]; then bh_ensure_download_tools "$need_zip" || return 1
    elif [ "$need_zip" = 1 ] && ! command -v unzip >/dev/null 2>&1; then
        echo 'Install unzip to use a local ZIP; an unpacked local binary needs no download tools.' >&2; return 1
    fi
    echo -e "  ${DIM}● Preparing Backhaul Core ($triplet)...${NC}"
    if [ "$kind" = url ]; then
        work=$(mktemp -d "$SECURE_TMP/rh-package.XXXXXX") || return 1
        source=""
        for url in "${urls[@]}"; do
            local source_host="${url#https://}"; source_host="${source_host%%/*}"; source_host="${source_host##*@}"
            echo -e "  ${DIM}● Source: $source_host${NC}"
            if bh_download "$url" "$work/package" "${EXPECTED_SHA256:-}"; then
                if bh_validate_package "$work/package"; then source="$work/package"; break
                else echo 'Downloaded file is not a compatible Backhaul binary/archive.' >&2; fi
            fi
            [ "$url" = "${urls[-1]}" ] || echo -e "  ${Y}● Trying the next download source...${NC}"
        done
        [ -n "$source" ] || { rm -rf "$work"; echo -e "  ${R}✖ Download failed. Previous installation preserved.${NC}" >&2; return 1; }
    fi
    if [ -n "${EXPECTED_SHA256:-}" ]; then
        if ! [[ "$EXPECTED_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || [ "$(sha256sum "$source" | cut -d' ' -f1)" != "${EXPECTED_SHA256,,}" ]; then
            [ -z "$work" ] || rm -rf "$work"
            echo 'Package SHA256 does not match; previous installation preserved.' >&2; return 1
        fi
    fi
    if mt_update_core bh mbackhaul "$source" local "${EXPECTED_SHA256:-}"; then
        [ -z "$work" ] || rm -rf "$work"
        echo -e "  ${G}✔ Backhaul Core installed successfully.${NC}"
        echo -e "  ${DIM}● Previously active tunnels restarted.${NC}"
    else
        [ -z "$work" ] || rm -rf "$work"
        echo -e "  ${R}✖ Package extraction, validation or service restart failed. Previous installation preserved.${NC}" >&2
        return 1
    fi
}

menu_install_core() {
    echo -e "\n  ${DIM}┌─[ INSTALL / UPDATE BACKHAUL CORE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r')

    [[ "$src_choice" =~ ^[1-4]$ ]] && install_core_from_source "$src_choice"
}

check_first_run_core() {
    if ! is_bh_core_valid; then
        local first_prompt_flag="$CONF_DIR/.core_prompted"
        if [ "$(cat "$first_prompt_flag" 2>/dev/null)" != "$MODULE_VERSION" ]; then
            clear
            echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
            echo -e "  ${B}│${NC}   ${R}● Backhaul Core binary is NOT installed on this machine!${NC}                  ${B}│${NC}"
            echo -e "  ${B}│${NC}   ${W}Would you like to install the Core binary now?${NC}                           ${B}│${NC}"
            echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
            echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Release${NC}"
            echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
            echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/packages)${NC}"
            echo -e "  ${DIM}│${NC}"
            echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Skip for now${NC}\n"
            echo -ne "  ${C}Select Source ❯❯ ${NC}"; read init_opt
            init_opt=$(echo "$init_opt" | tr -d '\r')
            if [[ "$init_opt" =~ ^[1-4]$ ]]; then
                if install_core_from_source "$init_opt"; then printf '%s\n' "$MODULE_VERSION" > "$first_prompt_flag"
                else rm -f "$first_prompt_flag"; return 1; fi
            elif [[ "$init_opt" = q || -z "$init_opt" ]]; then
                printf '%s\n' "$MODULE_VERSION" > "$first_prompt_flag"
            else return 1
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

# Backhaul remains the transport; external forwarders use separate local ingress ports.
bh_meta_value() {
    [ -f "$2" ] || return 0
    mt_config_value "$1" "$2"
}

bh_expanded_ports() {
    local list="$1" bind="$2" raw lhs rhs host start end p
    local -a items=(); IFS=, read -ra items <<< "$list"
    for raw in "${items[@]}"; do
        raw="${raw// /}"; lhs="${raw%%=*}"; rhs=""
        [[ "$raw" != *=* ]] || rhs="${raw#*=}"
        host="$bind"
        if [[ "$lhs" == *:* ]]; then
            host=$(mt_normalize_host "${lhs%:*}"); start="${lhs##*:}"; end="$start"
        else start="${lhs%-*}"; end="${lhs#*-}"; fi
        for ((p=10#$start;p<=10#$end;p++)); do
            printf '%s|%s|%s\n' "$p" "$host" "${rhs:-127.0.0.1:$p}"
        done
    done
}

bh_choose_forwarder() {
    local choice current="${1:-backhaul}"
    echo -e "\n  ${DIM}┌─[ FORWARDING ENGINE ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Backhaul (Built-in TCP / UDP)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}iptables (TCP / UDP)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}MPorter (Select its TCP engine separately)${NC}"
    echo -ne "  ${DIM}└─${NC} ${C}Select [Enter: ${current}, q: cancel] ❯❯ ${NC}"
    read -r choice || return 1
    case "${choice//$'\r'/}" in
        1) BH_FORWARDER=backhaul;; 2) BH_FORWARDER=iptables;; 3) BH_FORWARDER=mporter;;
        '') BH_FORWARDER="$current";; *) return 1;;
    esac
}

bh_backend_in_use() {
    local ip rc; ip=$(bh_meta_value BACKEND_IP "$CONF_DIR/$1.meta")
    [[ "$ip" == 127.77.* ]] && [ -x /usr/bin/mporter ] || return 1
    # Older MPorter has no read-only probe; don't accidentally open its menu.
    grep -q '^mp_bh_records()' /usr/bin/mporter || return 0
    /usr/bin/mporter --backhaul-in-use "$ip"; rc=$?
    [ "$rc" != 1 ]
}

bh_prepare_backend() {
    # Called while the config writer holds the allocation lock.
    local name="$1" ports="$2" bind="$3" link_port="$4" conf spec pair public host rhs candidate n ip
    local -a pairs=()
    local old; old=$(bh_meta_value BACKEND_PORTS "$CONF_DIR/$name.meta")
    BH_BACKEND_IP=$(bh_meta_value BACKEND_IP "$CONF_DIR/$name.meta")
    local -A reserved=() old_ports=() ips=() publics=()
    while IFS='|' read -r public host rhs; do publics[$public]=1; done < <(bh_expanded_ports "$ports" "$bind")
    [ "${#publics[@]}" -le 1024 ] || { echo 'External forwarding supports up to 1024 ports per tunnel.' >&2; return 1; }
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        ip=$(bh_meta_value BACKEND_IP "$conf"); [ -z "$ip" ] || ips[$ip]=1
        n=$(bh_meta_value TUN_PORT "$conf"); if mt_valid_port "$n"; then reserved[$n]=1; fi
        while IFS='|' read -r public host rhs; do reserved[$public]=1; done < <(bh_expanded_ports "$(bh_meta_value PORTS "$conf")" "$(bh_meta_value BIND_HOST "$conf")")
        spec=$(bh_meta_value BACKEND_PORTS "$conf")
        IFS=, read -ra pairs <<< "$spec"
        for pair in "${pairs[@]}"; do
            public="${pair%:*}"; n="${pair##*:}"
            mt_valid_port "$public" && mt_valid_port "$n" || continue
            if [ "$conf" = "$CONF_DIR/$name.meta" ]; then old_ports[$public]="$n"; fi
            reserved[$n]=1
        done
    done
    if ! [[ "$BH_BACKEND_IP" =~ ^127\.77\.[0-9]+\.[0-9]+$ ]] || ! mt_valid_ipv4 "$BH_BACKEND_IP"; then
        BH_BACKEND_IP=""
        for ((n=1;n<65535;n++)); do
            ip="127.77.$((n/256)).$((n%256))"
            [ -n "${ips[$ip]:-}" ] || { BH_BACKEND_IP="$ip"; break; }
        done
    fi
    [ -n "$BH_BACKEND_IP" ] || return 1
    BH_BACKEND_PORTS=""; BH_BACKEND_LINES=""; candidate=45000
    BH_BACKEND_BIND=0.0.0.0
    if [ -r /proc/net/if_inet6 ] && grep -q . /proc/net/if_inet6; then BH_BACKEND_BIND=::; fi
    command -v iptables >/dev/null 2>&1 || { echo 'Install iptables before selecting an external forwarder.' >&2; return 1; }
    [ "$BH_BACKEND_BIND" != :: ] || command -v ip6tables >/dev/null 2>&1 || return 1
    while IFS='|' read -r public host rhs; do
        n="${old_ports[$public]:-}"
        if [ -n "$n" ] && { [ "$n" = "$link_port" ] || [ -n "${publics[$n]:-}" ]; }; then
            if bh_backend_in_use "$name"; then
                echo 'An existing backend port conflicts with a requested port. Remove its MPorter mappings first.' >&2; return 1
            fi
            n=""
        fi
        if [ -z "$n" ]; then
            while [ "$candidate" -le 60999 ]; do
                if [ -z "${reserved[$candidate]:-}" ] && [ -z "${publics[$candidate]:-}" ] && [ "$candidate" != "$link_port" ] && ! mt_port_busy "$candidate" any; then break; fi
                candidate=$((candidate+1))
            done
            [ "$candidate" -le 60999 ] || { echo 'No free backend ports in 45000-60999.' >&2; return 1; }
            n="$candidate"; reserved[$n]=1; candidate=$((candidate+1))
        fi
        BH_BACKEND_PORTS+="${BH_BACKEND_PORTS:+,}$public:$n"
        BH_BACKEND_LINES+="${BH_BACKEND_LINES:+, }\"$(mt_hostport "$BH_BACKEND_BIND" "$n")=$rhs\""
    done < <(bh_expanded_ports "$ports" "$bind")
}

bh_show_forwarder() {
    local name="$1" meta="$CONF_DIR/$1.meta" mode ip pair
    mode=$(bh_meta_value FORWARDER "$meta")
    echo -e "  ${DIM}├─${NC} ${W}Forwarder:${NC} ${C}${mode:-backhaul}${NC}"
    [ "$mode" = mporter ] || return 0
    ip=$(bh_meta_value BACKEND_IP "$meta")
    echo -e "  ${DIM}├─${NC} ${W}MPorter Target IP:${NC} ${G}$ip${NC} ${DIM}(this server only)${NC}"
    local -a pairs=(); IFS=, read -ra pairs <<< "$(bh_meta_value BACKEND_PORTS "$meta")"
    for pair in "${pairs[@]}"; do
        printf "  ${DIM}├─${NC} ${W}%-5s${NC} ${DIM}❯${NC} ${G}%s:%s${NC} ${DIM}(TCP)${NC}\n" "${pair%:*}" "$ip" "${pair##*:}"
    done
    echo -e "  ${DIM}└─${NC} ${W}Open MPorter > Add Port Mappings > Backhaul Targets; ports are matched automatically.${NC}"
}

bh_forward_chain() {
    local hash; hash=$(printf '%s' "$1" | sha256sum); printf 'MBHF_%s' "${hash:0:16}"
}

bh_clear_forwarder() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    local chain bin parent table; chain=$(bh_forward_chain "$1")
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        for table in filter nat; do
            if [ "$table" = filter ]; then
                while "$bin" -w 5 -t filter -C INPUT -j "${chain}G" 2>/dev/null; do "$bin" -w 5 -t filter -D INPUT -j "${chain}G" || return 1; done
                "$bin" -w 5 -t filter -F "${chain}G" 2>/dev/null || true
                "$bin" -w 5 -t filter -X "${chain}G" 2>/dev/null || true
            else
                for parent in PREROUTING OUTPUT; do
                    while "$bin" -w 5 -t nat -C "$parent" -j "$chain" 2>/dev/null; do "$bin" -w 5 -t nat -D "$parent" -j "$chain" || return 1; done
                done
                "$bin" -w 5 -t nat -F "$chain" 2>/dev/null || true
                "$bin" -w 5 -t nat -X "$chain" 2>/dev/null || true
            fi
        done
    done
}

bh_apply_forwarder() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    local fd rc
    exec {fd}>"$CONF_DIR/.forwarder-firewall.lock" || return 1
    flock -x "$fd" || { exec {fd}>&-; return 1; }
    bh_apply_forwarder_locked "$1"; rc=$?
    if [ "$rc" != 0 ]; then
        bh_clear_forwarder "$1"
        echo "Backhaul forwarder firewall failed for $1; partial rules removed. Check iptables/ip6tables errors above." >&2
    fi
    exec {fd}>&-
    return "$rc"
}

bh_apply_forwarder_locked() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    local name="$1" meta="$CONF_DIR/$1.meta" mode bind spec pair public private host rhs bin proto chain
    [ -f "$meta" ] || return 1
    mode=$(bh_meta_value FORWARDER "$meta"); mode="${mode:-backhaul}"
    [[ "$mode" =~ ^(backhaul|iptables|mporter)$ ]] || return 1
    bh_clear_forwarder "$name" || return 1
    [ "$mode" != backhaul ] && [ "$(bh_meta_value ROLE "$meta")" = 1 ] || return 0
    bind=$(bh_meta_value BACKEND_BIND "$meta"); [[ "$bind" = :: || "$bind" = 0.0.0.0 ]] || return 1
    spec=$(bh_meta_value BACKEND_PORTS "$meta"); [ -n "$spec" ] || return 1
    local -a pairs=() bins=(iptables) protos=(tcp) match=(); IFS=, read -ra pairs <<< "$spec"
    [ "$bind" != :: ] || bins+=(ip6tables)
    if [ "$(bh_meta_value TRANSPORT "$meta")" = udp ]; then protos=(udp)
    elif [ "$(bh_meta_value TRANSPORT "$meta")" = tcp ] && [ "$(bh_meta_value ENABLE_UDP "$meta")" = true ]; then protos+=(udp); fi
    chain=$(bh_forward_chain "$name")
    for bin in "${bins[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || return 1
        # Guard is installed before the process listens; private ingress is local/DNAT only.
        "$bin" -w 5 -t filter -N "${chain}G" || return 1
        for pair in "${pairs[@]}"; do
            public="${pair%:*}"; private="${pair##*:}"
            mt_valid_port "$public" && mt_valid_port "$private" || return 1
            for proto in "${protos[@]}"; do
                "$bin" -w 5 -t filter -A "${chain}G" -i lo -p "$proto" --dport "$private" -j ACCEPT || return 1
                "$bin" -w 5 -t filter -A "${chain}G" -p "$proto" --dport "$private" -m conntrack --ctstatus DNAT -j ACCEPT || return 1
                "$bin" -w 5 -t filter -A "${chain}G" -p "$proto" --dport "$private" -j DROP || return 1
            done
        done
        "$bin" -w 5 -t filter -I INPUT 1 -j "${chain}G" || return 1
        if [ "$mode" = mporter ]; then
            # The frontend has a public listener too; accept its configured ports
            # before a host firewall's later INPUT drop/reject rules.
            while IFS='|' read -r public host rhs; do
                if [ "$bin" = ip6tables ]; then mt_valid_ipv6 "$host" || continue
                else [ "$host" = :: ] || mt_valid_ipv4 "$host" || continue; fi
                match=(); [[ "$host" = 0.0.0.0 || "$host" = :: ]] || match=(-d "$host")
                "$bin" -w 5 -t filter -A "${chain}G" "${match[@]}" -p tcp --dport "$public" -j ACCEPT || return 1
            done < <(bh_expanded_ports "$(bh_meta_value PORTS "$meta")" "$(bh_meta_value BIND_HOST "$meta")")
            continue
        fi
        "$bin" -w 5 -t nat -N "$chain" || return 1
        while IFS='|' read -r public host rhs; do
            if [ "$bin" = ip6tables ]; then mt_valid_ipv6 "$host" || continue
            else [ "$host" = :: ] || mt_valid_ipv4 "$host" || continue; fi
            private=""
            for pair in "${pairs[@]}"; do [ "${pair%:*}" != "$public" ] || private="${pair##*:}"; done
            mt_valid_port "$private" || return 1
            match=(); [[ "$host" = 0.0.0.0 || "$host" = :: ]] || match=(-d "$host")
            for proto in "${protos[@]}"; do
                "$bin" -w 5 -t nat -A "$chain" "${match[@]}" -p "$proto" --dport "$public" -m addrtype --dst-type LOCAL -j REDIRECT --to-ports "$private" || return 1
            done
        done < <(bh_expanded_ports "$(bh_meta_value PORTS "$meta")" "$(bh_meta_value BIND_HOST "$meta")")
        "$bin" -w 5 -t nat -A PREROUTING -j "$chain" || return 1
        "$bin" -w 5 -t nat -A OUTPUT -j "$chain" || return 1
    done
}

bh_delete_forwarder() {
    local ip; ip=$(bh_meta_value BACKEND_IP "$CONF_DIR/$1.meta")
    if [[ "$ip" == 127.77.* ]] && [ -x /usr/bin/mporter ]; then
        /usr/bin/mporter --purge-ip "$ip" || return 1
        bh_backend_in_use "$1" && { echo 'MPorter still uses this target; deletion cancelled.' >&2; return 1; }
    fi
    bh_clear_forwarder "$1"
}

bh_activate_config() {
    local name="$1" saved rc=0 existing=false
    saved=$(mktemp -d "$SECURE_TMP/bh-rollback.XXXXXX") || return 1
    if [ -f "$CONF_DIR/$name.meta" ] && [ -f "$CONF_DIR/$name.toml" ]; then
        cp -p "$CONF_DIR/$name.meta" "$saved/meta" && cp -p "$CONF_DIR/$name.toml" "$saved/config" || { rm -rf "$saved"; return 1; }
        existing=true
    fi
    if ! write_bh_config "$@"; then rm -rf "$saved"; return 1; fi
    systemctl restart "mbackhaul@$name" && bh_service_ready "mbackhaul@$name" || rc=1
    if [ "$rc" != 0 ]; then journalctl -u "mbackhaul@$name" -n 8 --no-pager >&2; fi
    if [ "$rc" != 0 ] && [ "$existing" = true ]; then
        systemctl stop "mbackhaul@$name" >/dev/null 2>&1 || true
        if mt_install_files 600 "$saved/meta" "$CONF_DIR/$name.meta" "$saved/config" "$CONF_DIR/$name.toml" && systemctl restart "mbackhaul@$name" && systemctl is-active --quiet "mbackhaul@$name"; then
            clean_bh_counters "$name"
            setup_bh_counters "$name" "$(bh_meta_value TUN_PORT "$saved/meta")" "$(bh_meta_value REMOTE_IP "$saved/meta")" "$(bh_meta_value ROLE "$saved/meta")" "$(bh_meta_value BIND_HOST "$saved/meta")"
            echo 'Forwarder failed to start; previous tunnel configuration restored.' >&2
        else
            echo "Rollback failed. Previous configuration is saved in $saved" >&2; return 1
        fi
    fi
    rm -rf "$saved"
    return "$rc"
}

case "${1:-}" in
    --apply-forwarder) bh_apply_forwarder "${2:-}"; exit $?;;
    --clear-forwarder) bh_clear_forwarder "${2:-}"; exit $?;;
esac

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
    local fd rc
    exec {fd}>"$CONF_DIR/.forwarder-allocation.lock" || return 1
    flock -x "$fd" || { exec {fd}>&-; return 1; }
    bh_write_config_locked "$@"; rc=$?
    exec {fd}>&-
    return "$rc"
}

bh_write_config_locked() {
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

    bh_load_options "$CONF_DIR/${name}.meta" "${11:-}" || return 1
    local bind_host="${9:-}" BIND_HOST='0.0.0.0' work final_toml final_meta
    if [ -f "$CONF_DIR/${name}.meta" ]; then
        BIND_HOST=$(sed -n 's/^BIND_HOST=//p' "$CONF_DIR/${name}.meta")
    fi
    bind_host=$(mt_normalize_host "${bind_host:-${BIND_HOST:-0.0.0.0}}")
    mt_valid_ipv4 "$bind_host" || mt_valid_ipv6 "$bind_host" || return 1
    mt_valid_port "$port" && [[ "$role" =~ ^[12]$ ]] || return 1
    [ "$role" != 2 ] || mt_valid_host "$r_ip" || return 1
    validate_bh_ports "$ports_str" 0 || return 1
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ && "$transport" =~ ^(tcp|tcpmux|ws|wss|wsmux|wssmux|udp)$ && "$enable_udp" =~ ^(true|false)$ ]] || return 1
    [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    if [ "${MT_LINK_CREATING:-0}" = 1 ] && { [ -e "$CONF_DIR/${name}.meta" ] || [ -e "$CONF_DIR/${name}.toml" ]; }; then
        echo 'Tunnel appeared during peer creation; nothing overwritten.' >&2; return 1
    fi
    local forwarder="${10:-}" old_forwarder old_ports
    old_forwarder=$(bh_meta_value FORWARDER "$CONF_DIR/${name}.meta")
    forwarder="${forwarder:-${old_forwarder:-backhaul}}"
    [ "$role" = 1 ] || forwarder=backhaul
    [[ "$forwarder" =~ ^(backhaul|iptables|mporter)$ ]] || return 1
    if [ "$transport" = udp ] && [ "$forwarder" = mporter ]; then
        echo 'UDP transport requires Backhaul or iptables forwarding; MPorter targets here are TCP.' >&2; return 1
    fi
    if [ "$transport" = udp ]; then enable_udp=true
    elif [ "$transport" != tcp ]; then enable_udp=false; fi
    local other pair private public host rhs
    local -A requested=(); local -a pairs=()
    if [ "$role" = 1 ]; then
        while IFS='|' read -r public host rhs; do requested[$public]=1; done < <(bh_expanded_ports "$ports_str" "$bind_host")
    fi
    for other in "$CONF_DIR"/*.meta; do
        [ -f "$other" ] && [ "$other" != "$CONF_DIR/$name.meta" ] || continue
        IFS=, read -ra pairs <<< "$(bh_meta_value BACKEND_PORTS "$other")"
        for pair in "${pairs[@]}"; do
            private="${pair##*:}"
            mt_valid_port "$private" || continue
            if [ "$port" = "$private" ] || [ -n "${requested[$private]:-}" ]; then
                echo "Port $private is reserved for $(basename "$other" .meta)'s local backend." >&2; return 1
            fi
        done
    done
    old_ports=$(bh_meta_value PORTS "$CONF_DIR/${name}.meta")
    if { [ "$forwarder" != "${old_forwarder:-backhaul}" ] || [ "$ports_str" != "$old_ports" ]; } && bh_backend_in_use "$name"; then
        echo 'Remove this Backhaul target from MPorter before changing its ports or forwarder.' >&2; return 1
    fi
    BH_BACKEND_IP=""; BH_BACKEND_PORTS=""; BH_BACKEND_BIND=""; BH_BACKEND_LINES=""
    if [ "$forwarder" != backhaul ]; then
        [ -n "$ports_str" ] || { echo 'External forwarding needs at least one port.' >&2; return 1; }
        bh_prepare_backend "$name" "$ports_str" "$bind_host" "$port" || return 1
        if [ "$forwarder" = mporter ]; then enable_udp=false; fi
    fi
    work=$(mktemp -d "$SECURE_TMP/bh-config.XXXXXX") || return 1
    final_toml="$CONF_DIR/${name}.toml"; final_meta="$CONF_DIR/${name}.meta"
    local toml="$work/config.toml" meta="$work/meta"

    echo "ROLE=$role" > "$meta"
    if [ "${MT_LINK_CREATING:-0}" = 1 ]; then printf 'PEER_SETUP_ID=%s\n' "$MT_LINK_CREATION_ID" >> "$meta"; fi
    echo "BIND_HOST=$bind_host" >> "$meta"
    echo "TRANSPORT=$transport" >> "$meta"
    echo "TUN_PORT=$port" >> "$meta"
    echo "REMOTE_IP=$r_ip" >> "$meta"
    echo "TOKEN=$token" >> "$meta"
    echo "PORTS=$ports_str" >> "$meta"
    echo "ENABLE_UDP=$enable_udp" >> "$meta"
    echo "FORWARDER=$forwarder" >> "$meta"
    echo "BACKEND_IP=$BH_BACKEND_IP" >> "$meta"
    echo "BACKEND_PORTS=$BH_BACKEND_PORTS" >> "$meta"
    echo "BACKEND_BIND=$BH_BACKEND_BIND" >> "$meta"
    local key; for key in "${!BH_OPTS[@]}"; do printf 'ADV_%s=%s\n' "$key" "${BH_OPTS[$key]}"; done >> "$meta"

    > "$toml"

    if [ "$role" == "1" ]; then
        echo "[server]" >> "$toml"
        echo "bind_addr = \"$(mt_hostport "$bind_host" "$port")\"" >> "$toml"
        echo "transport = \"${transport}\"" >> "$toml"
        echo "accept_udp = ${enable_udp}" >> "$toml"
        echo "token = \"${token}\"" >> "$toml"
        bh_emit_options "$role" "$transport" >> "$toml"
        if [[ "$transport" == wss || "$transport" == wssmux ]]; then
            local cert="${BH_OPTS[TLS_CERT]}" tls_key="${BH_OPTS[TLS_KEY]}"
            if [ -z "$cert" ]; then
                generate_ssl_cert || { rm -rf "$work"; return 1; }
                cert="$CERT_DIR/wssmux.crt"; tls_key="$CERT_DIR/wssmux.key"
            fi
            bh_validate_tls_pair "$cert" "$tls_key" || { echo 'TLS certificate/key is expired, unreadable or mismatched.' >&2; rm -rf "$work"; return 1; }
            printf 'tls_cert = "%s"\ntls_key = "%s"\n' "$cert" "$tls_key" >> "$toml"
        fi

        local port_lines
        if [ "$forwarder" = backhaul ]; then
            port_lines=$(bh_port_lines "$ports_str" "$bind_host") || { rm -rf "$work"; return 1; }
        else port_lines="$BH_BACKEND_LINES"; fi
        echo "ports = [ ${port_lines} ]" >> "$toml"

    else
        echo "[client]" >> "$toml"
        echo "remote_addr = \"$(mt_hostport "$r_ip" "$port")\"" >> "$toml"
        echo "transport = \"${transport}\"" >> "$toml"
        echo "token = \"${token}\"" >> "$toml"
        bh_emit_options "$role" "$transport" >> "$toml"
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
ExecStartPre=/usr/bin/mbackhaul --apply-forwarder %i
ExecStart=/usr/local/bin/bh -c /etc/mbackhaul/tunnels/%i.toml
ExecStopPost=/usr/bin/mbackhaul --clear-forwarder %i
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
    echo -e "\n  ${Y}● Tunnels Info And Specs:${NC}"
    local count=0
    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; ENABLE_UDP=""; BIND_HOST="0.0.0.0"; FORWARDER=backhaul
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
        [ "$ROLE" != 1 ] || bh_show_forwarder "$t_name"
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
        mt_monitor_wait 1 || break
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

    local meta
    for meta in "$CONF_DIR"/*.meta; do
        [ -f "$meta" ] || continue
        bh_delete_forwarder "$(basename "$meta" .meta)" || return 1
    done
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

show_tunnels_info() {
    mt_tunnels_info_menu backhaul draw_header show_tunnel_registry show_tunnel_logs
}

show_tunnel_logs() {
    select_tunnel || return 0
    local t_name int_trap
    t_name=$(basename "$SELECTED_TUN" .meta)
    draw_header
    echo -e "\n  ${DIM}● Live logs for ${W}${t_name}${NC} ${DIM}(Ctrl+C to return)${NC}\n"
    int_trap=$(trap -p INT)
    trap ':' INT
    journalctl -u "mbackhaul@${t_name}" -n 50 -f
    if [ -n "$int_trap" ]; then eval "$int_trap"; else trap - INT; fi
}

# BEGIN MTUNNEL WORKSPACE V13
# Embedded in each module: no external library or sourced setup-link code.
# Stable v12 visual grammar: keep the original module header untouched,
# use the original MDesign palette and grouped tree-navigation for new features.
mt_workspace_screen() { "$MT_HEADER"; }
mt_workspace_color() {
    local label="${1,,}"
    case "$label" in
        *uninstall*|*delete*|*purge*|*wipe*) printf '%s' "$R" ;;
        *update*|*install*|*bbr*|*mtu*|*restart*|*backup*|*restore*) printf '%s' "$Y" ;;
        *info*|*specs*|*security*|*encryption*|*secret*|*token*|*guard*) printf '%s' "$M" ;;
        *forward*|*balance*|*virtual\ ip*|*recovery*|*create\ from*|*peer\ setup*) printf '%s' "$G" ;;
        *monitor*|*check*|*health*) printf '%s' "$W" ;;
        *) printf '%s' "$C" ;;
    esac
}
mt_workspace_row() {
    local num="$1" label="$2" color="${3:-}"
    [ -n "$color" ] || color=$(mt_workspace_color "$label")
    printf '  %b├─%b %b%-2s%b %b❯%b %b%s%b\n' "$DIM" "$NC" "$W" "$num" "$NC" "$DIM" "$NC" "$color" "$label" "$NC"
}
mt_workspace_top_start() {
    mt_workspace_screen
    echo -e "\n  ${DIM}┌─[ $1 ]${NC}"
    echo -e "  ${DIM}│${NC}"
}
mt_workspace_top_section() {
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ $1 ]${NC}"
    echo -e "  ${DIM}│${NC}"
}
mt_workspace_top_end() {
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}
mt_workspace_menu() { # Title, then id|label|action entries; returns MT_ACTION.
    local title="$1" entry id label action choice; shift
    while true; do
        mt_workspace_screen
        echo -e "\n  ${DIM}┌─[ ${title} ]${NC}"
        echo -e "  ${DIM}│${NC}"
        for entry in "$@"; do
            IFS='|' read -r id label action <<< "$entry"
            mt_workspace_row "$id" "$label"
        done
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Go Back${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"
        read -r choice || return 1
        case "$choice" in 0|q|Q) return 1;; esac
        for entry in "$@"; do
            IFS='|' read -r id label action <<< "$entry"
            if [ "$choice" = "$id" ]; then MT_ACTION="$action"; return 0; fi
        done
        echo -e "  ${R}✖ Invalid selection.${NC}"
    done
}
mt_workspace_pause() { echo -ne "  ${DIM}Press Enter to continue...${NC}"; read -r _ || true; }
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

mt_link_deploy_locked() {
    mt_link_validate || return 1
    local MT_LINK_CREATING=1 MT_LINK_CREATION_ID
    MT_LINK_CREATION_ID=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n') || return 1
    local name="${MT_LINK_DATA[NAME]}" role="${MT_LINK_DATA[ROLE]}" host="${MT_LINK_DATA[HOST]}" port="${MT_LINK_DATA[LINK_PORT]}" token="${MT_LINK_DATA[TOKEN]}" bind=0.0.0.0 key settings conf tmp unit
    [[ "$token" =~ ^[A-Za-z0-9_-]{1,256}$ ]] || return 1
    [[ "$host" != *:* ]] || bind=::
    bind="${MT_LINK_DATA[BIND_HOST]:-$bind}"
    if [ "$MT_KIND" = backhaul ]; then name="bh_${name#bh_}"; conf="$CONF_DIR/$name.meta"
    else conf="$CONF_DIR/$name/meta.conf"; fi
    [ ! -e "$conf" ] && { [ "$MT_KIND" != rathole ] || [ ! -e "$CONF_DIR/$name" ]; } || { echo 'Tunnel already exists; nothing overwritten.' >&2; return 1; }
    if [ "$role" = 1 ] && mt_port_busy "$port"; then echo 'Link port is already in use.' >&2; return 1; fi
    if [ "$MT_KIND" = backhaul ]; then
        validate_bh_ports "${MT_LINK_DATA[PORTS]}" "$role" || return 1
        settings=$(mktemp "$SECURE_TMP/peer-backhaul.XXXXXX") || return 1
        for key in "${!MT_LINK_DATA[@]}"; do [[ "$key" != ADV_* ]] || printf '%s=%s\n' "$key" "${MT_LINK_DATA[$key]}"; done > "$settings"
        bh_load_options '' "$settings" || { rm -f "$settings"; return 1; }
        # Forwarder is a choice local to the access server; peer configuration uses the native default.
        bh_activate_config "$name" "$role" "${MT_LINK_DATA[TRANSPORT]}" "$port" "$host" "$token" "${MT_LINK_DATA[PORTS]}" "${MT_LINK_DATA[ENABLE_UDP]}" "$bind" backhaul "$settings"
        local rc=$?; rm -f "$settings"
        if [ "$rc" != 0 ]; then
            # Clean up only our own partially created profile, never a raced/manual profile.
            if [ "$(bh_meta_value PEER_SETUP_ID "$conf")" = "$MT_LINK_CREATION_ID" ]; then
                systemctl stop "mbackhaul@$name"; bh_clear_forwarder "$name"; clean_bh_counters "$name"
                rm -f "$conf" "$CONF_DIR/$name.toml"
            fi
            return 1
        fi
        unit="mbackhaul@$name"
    else
        validate_forward_ports "${MT_LINK_DATA[TCP_PORTS]}" "$role" tcp && validate_forward_ports "${MT_LINK_DATA[UDP_PORTS]}" "$role" udp || return 1
        mkdir "$CONF_DIR/$name" || return 1
        chmod 700 "$CONF_DIR/$name"
        {
            printf 'TYPE=%s\nBIND_HOST=%s\nLINK_PORT=%s\nREMOTE_IP=%s\nTOKEN=%s\nTCP_PORTS=%s\nUDP_PORTS=%s\n' "$role" "$bind" "$port" "$host" "$token" "${MT_LINK_DATA[TCP_PORTS]}" "${MT_LINK_DATA[UDP_PORTS]}"
        } > "$conf"; chmod 600 "$conf"
        unit="mrathole@$name"
        if ! generate_toml "$name" || ! systemctl restart "$unit" || ! mt_workspace_service_ready "$unit"; then
            journalctl -u "$unit" -n 8 --no-pager >&2; systemctl stop "$unit"; clean_rat_counters "$name"; rm -rf "$CONF_DIR/$name"; return 1
        fi
    fi
    systemctl enable "$unit" >/dev/null 2>&1
}
mt_workspace_service_ready() {
    local attempt
    for attempt in 1 2 3 4; do sleep .4; systemctl is-active --quiet "$1" || return 1; done
}
mt_workspace_health() {
    mt_link_select || return 1
    local name conf="$MT_LINK_CONF" host port role unit
    if [ "$MT_KIND" = rathole ]; then name=$(basename "$(dirname "$conf")"); role=$(mt_link_read "$conf" TYPE); port=$(mt_link_read "$conf" LINK_PORT); unit="mrathole@$name"
    else name=$(basename "$conf" .meta); role=$(mt_link_read "$conf" ROLE); port=$(mt_link_read "$conf" TUN_PORT); unit="mbackhaul@$name"; fi
    host=$(mt_link_read "$conf" REMOTE_IP)
    mt_workspace_screen
    systemctl status "$unit" --no-pager -l
    if [ "$role" = 2 ]; then
        if [ "$MT_KIND" = backhaul ] && [ "$(mt_link_read "$conf" TRANSPORT)" = udp ]; then
            echo '  UDP link: a TCP probe does not verify this transport; inspect packet counters and peer logs.'
        elif mt_tcp_probe "$host" "$port"; then echo '  TCP link endpoint is reachable (application forwarding must be checked separately).'
        else echo '  TCP link endpoint could not be reached.'; fi
    else echo '  Listener-side sessions:'; ss -tn "sport = :$port"; fi
    journalctl -u "$unit" -n 12 --no-pager
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
    local rv file="$SECURE_TMP/.mbackhaul_remote_ver"
    [ -f "$file" ] || return 0
    rv=$(tr -d '\r\n ' < "$file")
    mt_is_newer_version "$rv" "$MODULE_VERSION" && printf ' %b' "${Y}(Update Available: v${rv})${NC}"
    return 0
}
MT_KIND=backhaul; MT_HEADER=draw_header; MT_SECTION=""
mt_workspace_route() {
    local section="$1"
    case "$section" in
        1) MT_SECTION=1; mt_workspace_menu "CREATE TUNNEL" "1|Manual Backhaul Setup|1" "2|Create From Peer Link|97" "3|Generate Peer Setup Link|98" || { MT_SECTION=""; return 1; };;
        2) MT_SECTION=2; mt_workspace_menu "EDIT & MANAGE" "1|Remote Host / IP|3" "2|Transport & Advanced Settings|5" "3|Auth Token|6" "4|Link Port|7" "5|Tunnel Name|9" "6|Listen Address|10" "7|Delete Tunnels|2" || { MT_SECTION=""; return 1; };;
        3) MT_SECTION=3; mt_workspace_menu "FORWARDING" "1|Port Mappings & Forwarder (Native / iptables / MPorter)|4" "2|UDP Acceptance|8" || { MT_SECTION=""; return 1; };;
        4) MT_SECTION=4; mt_workspace_menu "SYSTEM & SECURITY" "1|Auto Recovery|13" "2|BBR Settings|14" "3|Scheduled Restart|15" "4|Restart & Zero Counters|16" "5|Check Selected Tunnel|99" || { MT_SECTION=""; return 1; };;
        7) MT_SECTION=7; mt_workspace_menu "UPDATE AND LOCAL INSTALL" "1|OTA Update / Local Script|18" "2|Install / Update Engine (Online / Local)|17" || { MT_SECTION=""; return 1; };;
        5) MT_ACTION=11;;
        6) MT_ACTION=12;;
        8) MT_ACTION=96;;
        9) MT_ACTION=19;;
        0) MT_ACTION=0;;
        *) return 1;;
    esac
}

render_mbackhaul_menu() {
    mt_workspace_top_start "PROVISION & MANAGE"
    mt_workspace_row 1 "Create Tunnel"
    mt_workspace_top_section "CONFIGURATION & EDITING"
    mt_workspace_row 2 "Edit & Manage"
    mt_workspace_row 3 "Forwarding"
    mt_workspace_top_section "SECURITY & OPTIMIZATION"
    mt_workspace_row 4 "System & Security"
    mt_workspace_top_section "MONITORING & DETAILS"
    mt_workspace_row 5 "Tunnels Info And Specs"
    mt_workspace_row 6 "Live Monitor"
    mt_workspace_top_section "SYSTEM OPERATIONS"
    mt_workspace_row 7 "Update and Local Install $(mt_workspace_update_badge)"
    mt_workspace_row 8 "Backup Configs"
    mt_workspace_row 9 "Uninstall MBACKHAUL"
    mt_workspace_top_end
}

while true; do
    if [ -n "$MT_SECTION" ]; then opt="$MT_SECTION"
    else
        render_mbackhaul_menu
        read_with_refresh "  ${C}MBACKHAUL ❯❯ ${NC}" opt render_mbackhaul_menu || break
        opt="${opt//$'\r'/}"
    fi
    mt_workspace_route "$opt" || continue
    case "$MT_ACTION" in
        97) mt_link_import; continue;;
        98) mt_link_export; continue;;
        99) mt_workspace_health; continue;;
        96) mt_workspace_menu "BACKUP" "1|Save Config Backup|save" || continue; mt_workspace_backup; continue;;
    esac
    # Every edit/forwarding action gets a private config restore point first.
    if [[ "$MT_SECTION" == 2 || "$MT_SECTION" == 3 ]]; then
        mt_workspace_auto_backup || { echo 'Could not save the config restore point; operation cancelled.' >&2; mt_workspace_pause; continue; }
    fi
    opt="$MT_ACTION"
    case $opt in
        1) 
           mt_workspace_screen
           bh_start_screen
           echo -e "\n  ${DIM}┌─[ DEPLOY NEW TUNNEL ]${NC}"
           while true; do 
               echo -ne "  ${C}●${NC} ${W}Role [1: IRAN (Server) | 2: KHAREJ (Client) | q: Back]: ${NC}"; read s_type
               s_type=$(echo "$s_type" | tr -d '\r')
               [[ "$s_type" =~ ^[12q]$ ]] && break
           done
           [[ "$s_type" == "q" ]] && continue
           
           bh_select_transport || continue
           tr_val="$BH_TRANSPORT"

           echo -ne "  ${C}● Tunnel Suffix Name (e.g. bh1): ${NC}"; read suffix
           suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
           t_name="bh_${suffix}"
           if [ -f "$CONF_DIR/$t_name.meta" ]; then
               echo -e "  ${R}● This tunnel name already exists.${NC}"; sleep 2; continue
           fi
           
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
           
           gen_tok=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
           echo -ne "  ${C}● Auth Token [Default ${gen_tok}]: ${NC}"; read u_tok
           u_tok=$(echo "$u_tok" | tr -dc 'a-zA-Z0-9_-')
           tok=${u_tok:-$gen_tok}

           u_udp="false"
           fwd_ports=""
           if [ "$s_type" == "1" ]; then
               if [ "$tr_val" = udp ]; then u_udp=true
               elif [ "$tr_val" = tcp ]; then
                   echo -ne "  ${C}●${NC} ${W}Accept UDP applications over TCP too? [y/N]: ${NC}"; read -r enable_udp
                   [[ "${enable_udp,,}" != y && "${enable_udp,,}" != yes ]] || u_udp=true
               fi

               # رفع باگ ۲: اعتبارسنجی دقیق پورت‌های فوروارد سرور ایران
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Forward Ports (e.g. 443=127.0.0.1:443): ${NC}"; read fwd_ports
                   fwd_ports=$(echo "$fwd_ports" | tr -d '\r')
                   validate_bh_ports "$fwd_ports" "1" && break
               done
           fi
           
           BH_FORWARDER=backhaul
           if [ "$s_type" = 1 ]; then bh_choose_forwarder || continue; fi
           if [ "$tr_val" = udp ] && [ "$BH_FORWARDER" = mporter ]; then
               echo -e "  ${Y}● UDP needs Backhaul or iptables; choose again.${NC}"
               bh_choose_forwarder || continue
           fi
           bh_advanced_wizard "$t_name" "$s_type" "$tr_val" || continue
           systemctl enable "mbackhaul@${t_name}" >/dev/null 2>&1
           bh_activate_config "$t_name" "$s_type" "$tr_val" "$t_port" "$r_ip" "$tok" "$fwd_ports" "$u_udp" "$bind_host" "$BH_FORWARDER" "$BH_SETTINGS_FILE"; deploy_rc=$?
           rm -f "$BH_SETTINGS_FILE"
           [ "$deploy_rc" = 0 ] || { echo -e "  ${R}● Tunnel was not deployed; check the error above.${NC}"; sleep 2; continue; }
           if systemctl is-active --quiet "mbackhaul@${t_name}"; then mt_ask_bbr_on_create; fi
           if systemctl is-active --quiet "mbackhaul@${t_name}"; then
               echo -e "  ${G}● Backhaul Tunnel Deployed Successfully!${NC}"
               bh_show_forwarder "$t_name"
               mt_link_offer "$CONF_DIR/$t_name.meta"
               echo -ne "  ${DIM}Press Enter to continue...${NC}"; read -r _
           else echo -e "  ${R}● Tunnel failed to start; check its logs.${NC}"; sleep 2; fi ;;
           
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
                   bh_delete_forwarder "$t_name" || continue
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
               bh_delete_forwarder "$t_name" || continue
               rm -f "${configs[$del_idx]}" "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${t_name}_restart.sh"
               echo -e "  ${G}Tunnel Purged!${NC}"; sleep 1.5
           fi ;;
           
        3|4|5|6|7|8|9|15|16|10)
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN" .meta)
           ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; ENABLE_UDP=""; BIND_HOST="0.0.0.0"; FORWARDER=backhaul
           BH_SETTINGS_FILE=""
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
                       if [ -z "$n_ports" ]; then break; fi
                       validate_bh_ports "$n_ports" "1" "$PORTS" && { PORTS="$n_ports"; break; }
                   done
                   bh_choose_forwarder "${FORWARDER:-backhaul}" || continue
                   FORWARDER="$BH_FORWARDER"
               else
                   echo -e "  ${Y}● Client role doesn't use port mappings.${NC}"; sleep 1.5; continue
               fi
               
           elif [[ "$opt" == "5" ]]; then
               bh_start_screen
               echo -e "\n  ${DIM}┌─[ TRANSPORT & ADVANCED SETTINGS ]${NC}"
               echo -ne "  ${C}Change transport? [y/N; current: $TRANSPORT] ❯❯ ${NC}"; read -r change_transport
               if [[ "${change_transport,,}" == y || "${change_transport,,}" == yes ]]; then
                   bh_select_transport || continue; TRANSPORT="$BH_TRANSPORT"
               fi
               if [ "$TRANSPORT" = udp ] && [ "$FORWARDER" = mporter ]; then bh_choose_forwarder "$FORWARDER" || continue; FORWARDER="$BH_FORWARDER"; fi
               bh_advanced_wizard "$t_name" "$ROLE" "$TRANSPORT" || continue
               echo -e "  ${Y}⚠ Update the peer to use matching transport / MUX settings.${NC}"

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
                   if [ "$TRANSPORT" != tcp ]; then echo -e "  ${Y}● UDP acceptance is available on TCP; UDP transport is always UDP-only.${NC}"; sleep 2; continue; fi
                   if [ "${FORWARDER:-backhaul}" = mporter ]; then
                       echo -e "  ${Y}● MPorter forwards TCP here; select Backhaul or iptables for UDP.${NC}"; sleep 2; continue
                   fi
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
               
           elif [[ "$opt" == "15" ]]; then
               manage_cron "$t_name"; continue
               
           elif [[ "$opt" == "10" ]]; then
               [ "$ROLE" == 1 ] || continue
               mt_ask_bind_host || continue; BIND_HOST="$MT_BIND_HOST"

           elif [[ "$opt" == "16" ]]; then
               zero_bh_counters "$t_name"
           fi
           
           bh_activate_config "$t_name" "$ROLE" "$TRANSPORT" "$TUN_PORT" "$REMOTE_IP" "$TOKEN" "$PORTS" "$ENABLE_UDP" "$BIND_HOST" "${FORWARDER:-backhaul}" "$BH_SETTINGS_FILE"; update_rc=$?
           rm -f "$BH_SETTINGS_FILE"
           [ "$update_rc" = 0 ] || { sleep 2; continue; }
           if systemctl is-active --quiet mbackhaul@$t_name; then
               echo -e "  ${G}✔ Tunnel updated and service restarted successfully.${NC}"
               bh_show_forwarder "$t_name"
               echo -ne "  ${DIM}Press Enter to continue...${NC}"; read -r _
           else
               echo -e "  ${R}✖ Tunnel failed to start. Please check logs!${NC}"; sleep 2
           fi
           ;;
           
        11) show_tunnels_info ;;
        17) menu_install_core ;;
        18) self_update_module ;;
        19) uninstall_mbackhaul ;;
        13) mt_run_tool mhealer --scope backhaul ;;
        14) mt_run_tool mbbr --from-tunnel ;;
        12) show_live_radar ;;
        0) break ;;
    esac
done
