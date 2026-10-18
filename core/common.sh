#!/usr/bin/env bash
# MTunnel shared core API 1 (v1.2.0; modular layout revision 2).
# Functions only: safe to source from installers, dashboards and all tunnel engines.
# Changes must be tested against every consuming module.
MTUNNEL_CORE_API=1
MTUNNEL_LAYOUT_REV=2
MTUNNEL_RELEASE_VERSION="1.2.0"
# CENTRAL SOURCE CONFIGURATION (root-managed, data-only; no eval or source).
# Override these defaults with /etc/mtunnel/sources.conf, or by exporting
# MTUNNEL_GITHUB_BASE and MTUNNEL_MIRROR_BASE before launching the script.
MTUNNEL_GITHUB_BASE="${MTUNNEL_GITHUB_BASE:-https://raw.githubusercontent.com/htzserv/MTunnel/main}"
MTUNNEL_MIRROR_BASE="${MTUNNEL_MIRROR_BASE:-https://c107328.parspack.net/c107328/MTunnel}"
mt_source_valid_base() {
    local base="$1"
    [[ "$base" =~ ^https://[A-Za-z0-9][A-Za-z0-9._:-]*(/[A-Za-z0-9._~/%+@=-]+)*/?$ ]] && [[ "$base" != *'..'* ]]
}
mt_sources_load() {
    local conf="${MTUNNEL_SOURCES_FILE:-/etc/mtunnel/sources.conf}" key value
    local github="$MTUNNEL_GITHUB_BASE" mirror="$MTUNNEL_MIRROR_BASE"
    [[ -f "$conf" ]] || { mt_source_valid_base "$github" && mt_source_valid_base "$mirror"; return; }
    # No shell expansion, command substitution, eval, or arbitrary file code.
    [[ -r "$conf" && ! -L "$conf" ]] || return 1
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == '#'* ]] && continue
        case "$key" in
            MTUNNEL_GITHUB_BASE) github="$value";;
            MTUNNEL_MIRROR_BASE) mirror="$value";;
            *) echo "MTunnel: invalid source setting: $key" >&2; return 1;;
        esac
    done < "$conf"
    mt_source_valid_base "$github" && mt_source_valid_base "$mirror" || {
        echo 'MTunnel: invalid sources.conf (HTTPS URL required)' >&2; return 1;
    }
    MTUNNEL_GITHUB_BASE="${github%/}"
    MTUNNEL_MIRROR_BASE="${mirror%/}"
}
mt_sources_load || { echo 'MTunnel: cannot read source configuration' >&2; return 1; }
mt_source_url() {
    local base
    case "${1:-}" in
        github) base="$MTUNNEL_GITHUB_BASE";;
        mirror) base="$MTUNNEL_MIRROR_BASE";;
        *) return 1;;
    esac
    [[ "${2:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/+@=-]*$ && "${2:-}" != *'..'* ]] || return 1
    printf '%s/%s\n' "$base" "$2"
}

# BEGIN MTUNNEL SHARED HELPERS
# Internal helpers centralized here; tunnel scripts load this module with source.
# Sourcing this file performs no network, filesystem, or service operations.
mt_normalize_host() {
    local host="$1"
    if [[ "$host" == \[*\] ]]; then host="${host:1:${#host}-2}"; fi
    printf '%s' "$host"
}
mt_valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

mt_legacy_core_subnet() {
    local id="$1" kind="${2:-gre}" n idx a b
    [[ "$id" =~ ^[0-9]{1,9}$ ]] || return 1
    n=$((10#$id))
    if [ "$kind" == vxlan ]; then
        if ((n <= 255)); then printf '10.88.%d' "$n"; return 0; fi
        idx=$(((n - 256) % 32768))
        a=$((128 + idx / 256)); b=$((idx % 256))
    else
        if ((n <= 255)); then printf '10.76.%d' "$n"; return 0; fi
        # Extended GRE space uses 10.0.0.0/9 while reserving legacy 10.76/16 and 10.88/16.
        idx=$(((n - 256) % 32256))
        a=$((idx / 256)); b=$((idx % 256))
        ((a >= 76)) && a=$((a + 1))
        ((a >= 88)) && a=$((a + 1))
    fi
    printf '10.%d.%d' "$a" "$b"
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

# Release-line migration support. MTunnel 15.x/16.x was renumbered to the 1.x line.
# Historic 15.x/16.x builds and the 1.x line may be switched in either direction.
# Version numbers are informational; API/layout compatibility is the deployment gate.
MTUNNEL_RETIRED_MAJOR_MIN=15
MTUNNEL_RETIRED_MAJOR_MAX=16
mt_version_major() {
    [[ "${1:-}" =~ ^([0-9]+)\.[0-9]+(\.[0-9]+)?$ ]] || return 1
    printf '%d' "$((10#${BASH_REMATCH[1]}))"
}
mt_is_retired_version() {
    local major; major=$(mt_version_major "$1") || return 1
    ((major >= MTUNNEL_RETIRED_MAJOR_MIN && major <= MTUNNEL_RETIRED_MAJOR_MAX))
}
mt_is_current_release_line() {
    local major; major=$(mt_version_major "$1") || return 1
    ((major == 1))
}
# $1 installed/local, $2 candidate/remote
mt_release_migration() {
    mt_is_retired_version "$1" && mt_is_current_release_line "$2"
}
# True when installing $2 over installed $1 would be a real downgrade. A recognized
# retired-line -> 1.x migration is not treated as a downgrade.
mt_downgrade_blocked() {
    return 1   # version restrictions disabled: nothing is ever blocked as a downgrade
}
# A different remote version is available, regardless of numeric direction.
# This intentionally makes upgrades and downgrades symmetric.
mt_update_available() {
    [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ "$1" != "$2" ]
}
# Legacy compatibility hook retained for older callers. Version direction is unrestricted.
mt_retired_bundle_blocked() {
    return 1   # version restrictions disabled: no bundle is ever blocked
}

# Legacy downgrade-confirmation hook retained for older callers.
# 1.2.0 permits switching to any selected version without a version-direction prompt.
mt_confirm_downgrade() {
    return 0   # version restrictions disabled: install whatever version was selected
}
# Independent component updates/downgrades are supported. Compatibility is
# governed by the shared-core API/layout contract, not by matching release numbers.
mt_module_downgrade_allowed() {
    return 0   # version restrictions disabled
}

# Validate that a module can run against the currently loaded shared core.
# Future modules can bump these constants when a breaking shared-core change occurs.
# Older API-1/layout-2 modules without explicit constants remain compatible.
mt_validate_module_core_contract() {
    local candidate="$1" req_api req_layout
    grep -Fq '# MTUNNEL_COMMON_LOADER' "$candidate" || return 0
    req_api=$(sed -n 's/^MTUNNEL_REQUIRED_CORE_API=\([0-9][0-9]*\)$/\1/p' "$candidate" | head -n1)
    req_layout=$(sed -n 's/^MTUNNEL_REQUIRED_LAYOUT_REV=\([0-9][0-9]*\)$/\1/p' "$candidate" | head -n1)
    req_api="${req_api:-1}"; req_layout="${req_layout:-2}"
    if [ "${MTUNNEL_CORE_API:-}" != "$req_api" ] || [ "${MTUNNEL_LAYOUT_REV:-}" != "$req_layout" ]; then
        printf 'Module requires shared core API %s / layout %s; installed core is API %s / layout %s.\n' \
            "$req_api" "$req_layout" "${MTUNNEL_CORE_API:-unknown}" "${MTUNNEL_LAYOUT_REV:-unknown}" >&2
        return 1
    fi
    return 0
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
    local item a b target="$2"; local -a parts=()
    mt_valid_port "$target" || return 1
    target=$((10#$target))
    IFS=, read -ra parts <<< "$1"
    for item in "${parts[@]}"; do
        [[ "$item" == *"="* ]] && item="${item%%=*}"
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
            a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
            ((target >= a && target <= b)) && return 0
        elif mt_valid_port "$item" && ((10#$item == target)); then
            return 0
        fi
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
    local list="$1" check="$2" proto="${3:-both}" owned="${4:-}" item a b p
    local -A seen=(); local -a parts=()
    [ -z "$list" ] && return 0
    [[ "$list" =~ ^[0-9]+(:[0-9]+)?(,[0-9]+(:[0-9]+)?)*$ ]] || return 1
    IFS=, read -ra parts <<< "$list"
    for item in "${parts[@]}"; do
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
            a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
            ((a >= 1 && b <= 65535 && a < b)) || return 1
        else
            mt_valid_port "$item" || return 1; a=$((10#$item)); b=$a
        fi
        for ((p=a; p<=b; p++)); do
            [ -z "${seen[$p]:-}" ] || return 1; seen[$p]=1
            if [ "$check" == 1 ] && ! mt_list_has_port "$owned" "$p" && mt_port_busy "$p" "$proto"; then return 1; fi
        done
    done
}
mt_validate_script() {
    local file="$1" version
    [ -s "$file" ] && head -n 1 "$file" | grep -qE '^#!(/bin/bash|/usr/bin/env bash)$' || return 1
    bash -n "$file" || return 1
    version=$(sed -n 's/^MODULE_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$file")
    [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}
# Open GNU nano on a disposable candidate, then syntax/version-check it.
# nano -t (--saveonexit) means Ctrl+X saves without asking Y/N + filename.
# The caller, not this helper, commits a validated candidate transactionally.
mt_ensure_nano() {
    command -v nano >/dev/null 2>&1 && return 0
    [ "$EUID" -eq 0 ] || {
        echo 'GNU nano is required. Install it first (sudo apt-get install nano).' >&2
        return 1
    }
    echo 'Installing required GNU nano editor...' >&2
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y nano >/dev/null 2>&1 || {
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -qq >&2 &&
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y nano >/dev/null 2>&1
        } || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf -y install nano >/dev/null 2>&1 || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum -y install nano >/dev/null 2>&1 || return 1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache nano >/dev/null 2>&1 || return 1
    else
        echo 'Cannot install nano: no supported package manager. Install nano manually.' >&2
        return 1
    fi
    command -v nano >/dev/null 2>&1 || { echo 'nano installation failed.' >&2; return 1; }
}
mt_capture_manual_script() {
    local output="${1:-}" pasted_version
    [[ -n "$output" && -f "$output" && ! -L "$output" ]] || {
        echo 'Manual nano: invalid candidate path.' >&2; return 1;
    }
    [[ -t 0 && -t 1 ]] || {
        echo 'Manual nano requires an interactive SSH terminal (TTY).' >&2; return 1;
    }
    mt_ensure_nano || { echo 'GNU nano unavailable. Existing script preserved.' >&2; return 1; }
    : > "$output" || return 1
    # Reset screen before opening fullscreen nano. Keep stdout connected to TTY.
    printf '\033[2J\033[H'
    if ! nano -t -- "$output"; then
        echo 'Nano closed with an error; previous module was not changed.' >&2
        return 1
    fi
    if [[ ! -s "$output" ]]; then
        echo 'Nothing saved in Nano; previous module preserved.' >&2; return 1
    fi
    # Normalize text copied from Windows and optionally enclosed by Markdown.
    sed -i 's/\r$//' "$output" || return 1
    if [[ "$(head -n1 "$output")" == \`\`\`bash || "$(head -n1 "$output")" == \`\`\`sh ]]; then
        sed -i '1d; ${/^```$/d;}' "$output" || return 1
    fi
    # Drop an optional BOM on the first line only.
    sed -i '1s/^\xEF\xBB\xBF//' "$output" || return 1
    if ! mt_validate_script "$output"; then
        echo 'Invalid full Bash module (shebang, syntax or MODULE_VERSION). Previous module preserved.' >&2
        return 1
    fi
    pasted_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$output" | head -n1)
    mt_validate_module_core_contract "$output" || {
        echo 'Pasted module is not compatible with the installed shared-core API/layout. Previous module preserved.' >&2
        return 1
    }
    echo 'Nano save successful. Syntax, version and shared-core compatibility verified; applying module automatically...' >&2
    return 0
}

# Plain HTTPS fetch (curl, else wget). No integrity logic here.
_mt_fetch_raw() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 --retry 2 -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --https-only --timeout=30 --tries=2 -O "$dest" "$url"
    else return 1; fi
}

# Download a resource from the selected source.
# Release/version selection is intentionally permissive: no checksum manifest,
# release-number gate, upgrade-only rule or downgrade block is applied here.
# HTTPS and a non-empty response are still required so transport errors do not
# replace a working installation with an empty file.
mt_download() {
    local url="$1" dest="$2" tmp
    [[ "$url" == https://* ]] || { echo 'Download requires HTTPS.' >&2; return 1; }
    tmp=$(mktemp "${dest}.download.XXXXXX") || return 1
    if ! _mt_fetch_raw "$url" "$tmp" || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
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
# Avoid accidentally replacing a different engine when paste auto-applies.
mt_validate_module_role() {
    local candidate="$1" rel="$2" role
    case "$rel" in
        main.sh) role='Master Core';;
        mporter.sh) role='MPorter';;
        tunnels/mgre.sh) role='MGRE';;
        tunnels/mxlan.sh) role='MXLAN';;
        tunnels/mrathole.sh) role='MRathole';;
        tunnels/mbackhaul.sh) role='MBackhaul';;
        tunnels/mpaqet.sh) role='MPaqet';;
        mdoctor.sh) role='Doctor';;
        *) echo "Unrecognized MTunnel module path: $rel" >&2; return 1;;
    esac
    # Header check guards against accidental cross-module paste, not malicious code.
    head -n 5 "$candidate" | grep -Fq "# --- MTunnel $role |" || {
        echo "Incorrect module pasted for $rel. Current script preserved." >&2
        return 1
    }
}
mt_install_script() {
    local candidate="$1" rel="$2" target="$3" current="${4:-}"; local -a files=()
    mt_validate_script "$candidate" || return 1
    mt_validate_module_role "$candidate" "$rel" || return 1
    # Module version numbers are independent from the shared-core release.
    # Only the declared core API/layout contract must remain compatible.
    mt_validate_module_core_contract "$candidate" || return 1
    if grep -Fq '# MTUNNEL_COMMON_LOADER' "$candidate" && [ -z "${MTUNNEL_CORE_API:-}" ]; then
        echo 'Shared core is not loaded. Install or load a compatible MTunnel shared core before this module.' >&2
        return 1
    fi
    if mt_validate_script "$target" 2>/dev/null; then
        local current_version new_version
        current_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$target")
        new_version=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$candidate")
        if ! mt_module_downgrade_allowed "$current_version" "$new_version"; then return 1; fi
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
    local prefix="$1" name="$2" port="$3" remote="$4" role="$5" bind="${6:-0.0.0.0}" proto="${7:-tcp}" bin addr
    local -a addresses=() input=() output=()
    mt_valid_port "$port" || return 1
    [[ "$proto" =~ ^(tcp|udp)$ ]] || return 1
    if [ "$role" == 1 ]; then
        input=(--dport "$port"); output=(--sport "$port")
        if [[ "$bind" == *:* ]]; then addresses=('::'); else addresses=('0.0.0.0'); fi
    else
        remote=$(mt_normalize_host "$remote")
        mt_valid_host "$remote" || return 1
        if mt_valid_ipv4 "$remote" || mt_valid_ipv6 "$remote"; then addresses=("$remote")
        else mapfile -t addresses < <({ getent ahostsv4 "$remote"; getent ahostsv6 "$remote"; } 2>/dev/null | awk '{print $1}' | sort -u); fi
    fi
    if [ "$role" == 1 ] && [ "$bind" == '::' ]; then addresses+=('0.0.0.0'); fi
    for addr in "${addresses[@]}"; do
        bin=iptables; [[ "$addr" == *:* ]] && bin=ip6tables
        command -v "$bin" >/dev/null 2>&1 || continue
        if [ "$role" != 1 ]; then input=(-s "$addr" --sport "$port"); output=(-d "$addr" --dport "$port"); fi
        "$bin" -w 5 -t mangle -C INPUT -p "$proto" "${input[@]}" -m comment --comment "${prefix}_RX_${name}" 2>/dev/null ||
            "$bin" -w 5 -t mangle -A INPUT -p "$proto" "${input[@]}" -m comment --comment "${prefix}_RX_${name}" || return 1
        "$bin" -w 5 -t mangle -C OUTPUT -p "$proto" "${output[@]}" -m comment --comment "${prefix}_TX_${name}" 2>/dev/null ||
            "$bin" -w 5 -t mangle -A OUTPUT -p "$proto" "${output[@]}" -m comment --comment "${prefix}_TX_${name}" || return 1
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
        subnet="${CORE_SUBNET:-}"
        if [ -z "$subnet" ]; then
            if [ -n "${VNI_ID:-}" ]; then subnet=$(mt_legacy_core_subnet "$VNI_ID" vxlan) || return 1
            else subnet=$(mt_legacy_core_subnet "${TUN_ID:-}" gre) || return 1; fi
        fi
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
mt_read_kv() {
    local file="$1" key="$2" value
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    value=$(awk -v k="$key" 'index($0,k"=")==1 {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null) || return 1
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    [[ "$value" =~ ^[][A-Za-z0-9_.:/,=+%-]*$ ]] || return 1
    printf '%s' "$value"
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
# Ownership manifest: only binaries explicitly installed as NEW by MTunnel may be wiped.
# Never claim pre-existing system files. The marker records MTunnel ownership only.
mt_ownership_dir() { printf '%s' "${MTUNNEL_TEST_ROOT:-}/var/lib/mtunnel/owned-binaries"; }
mt_owned_binary_register() {
    local name="$1" target="$2" dir
    [[ "$name" =~ ^(bh|rathole|paqet)$ ]] || return 1
    [ -f "$target" ] || return 1
    dir=$(mt_ownership_dir); mkdir -p "$dir" || return 1
    printf 'owned
' > "$dir/$name" || return 1
    chmod 600 "$dir/$name"
}
mt_owned_binary_remove() {
    local name="$1" target="$2" alias="${3:-}" dir
    [[ "$name" =~ ^(bh|rathole|paqet)$ ]] || return 1
    dir=$(mt_ownership_dir)
    [ -f "$dir/$name" ] || return 1
    [ ! -f "$target" ] || rm -f -- "$target" || return 1
    [ -z "$alias" ] || [ ! -f "$alias" ] || rm -f -- "$alias" || return 1
    rm -f -- "$dir/$name"
}
# Keep the running executable until the candidate has been downloaded and validated.
mt_update_core() {
    local name="$1" unit_prefix="$2" source="$3" kind="${4:-url}" work candidate item unit failed=0 had_old=0 register_owner=0
    local target="${MTUNNEL_TEST_ROOT:-}/usr/local/bin/$name" alias="${MTUNNEL_TEST_ROOT:-}/usr/bin/$name"; local -a active=()
    work=$(mktemp -d "$SECURE_TMP/core.XXXXXX") || return 1
    if [ "$kind" == local ]; then
        cp "$source" "$work/download" || { rm -rf "$work"; return 1; }
    else
        mt_download "$source" "$work/download" || { rm -rf "$work"; return 1; }
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
    # Do not claim ownership of a binary that predates MTunnel.
    case "$name" in
        bh|rathole|paqet)
            if [ -f "$(mt_ownership_dir)/$name" ] || { [ ! -e "$target" ] && [ ! -e "$alias" ]; }; then register_owner=1; fi;;
    esac
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
            if ! mt_install_files 755 "$work/previous" "$target" "$work/previous" "$alias"; then
                echo 'CRITICAL: Could not restore previous core binary!' >&2
            else
                for unit in "${active[@]}"; do
                    if ! systemctl restart "$unit" || ! systemctl is-active --quiet "$unit"; then
                        echo "CRITICAL: Could not restore service: $unit" >&2
                    fi
                done
            fi
        else rm -f "$target" "$alias"; fi
        rm -rf "$work"; return 1
    fi
    if [ "$register_owner" == 1 ]; then
        mt_owned_binary_register "$name" "$target" || echo "Warning: ownership tracking failed for $name; uninstall will retain it." >&2
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
        [ -n "$CORE_SUBNET" ] || CORE_SUBNET="$(mt_legacy_core_subnet "$TUN_ID" gre)" || return 1
        case "$TUN_PROTO" in
            gre6|ipip4to6|ipip6to6) mt_valid_ipv6 "${LOCAL_PUB6:-$LOCAL_IP6}" && mt_valid_ipv6 "${REMOTE_PUB6:-$REMOTE_IP6}" || return 1;;
            *) mt_valid_ipv4 "$LOCAL_PUB" && mt_valid_ipv4 "$REMOTE_PUB" || return 1;;
        esac
        if [ "$TUN_PROTO" == ipip6to6 ]; then mt_valid_ipv6 "$CORE_V6::1" || return 1
        else mt_valid_ipv4 "$CORE_SUBNET.1" || return 1; fi
        if [ "$TUN_PROTO" == 6to4 ]; then mt_valid_ipv6 "$LOCAL_IP6" && mt_valid_ipv6 "$REMOTE_IP6" || return 1; fi
    else
        [[ "$VX_NAME" =~ ^[A-Za-z0-9_.-]{1,15}$ && "$BR_NAME" =~ ^[A-Za-z0-9_.-]{1,15}$ && "$VNI_ID" =~ ^[0-9]{1,8}$ && "$FAB_PROTO" =~ ^(ipv4|ipv6)$ ]] && ((10#$VNI_ID >= 1 && 10#$VNI_ID <= 16777215)) || return 1
        local main_mx_mtu_max=1450
        [ "$FAB_PROTO" != ipv6 ] || main_mx_mtu_max=1430
        [ -z "$CUSTOM_MTU" ] || ((10#$CUSTOM_MTU >= 900 && 10#$CUSTOM_MTU <= main_mx_mtu_max)) || return 1
        [ -n "$CORE_SUBNET" ] || CORE_SUBNET="$(mt_legacy_core_subnet "$VNI_ID" vxlan)" || return 1
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
# Lightweight former tools integrated in shared core. No tools/ or standalone executables.
mt_bbr_state() {
    local want="$1" cc qdisc
    if [ "$want" = 1 ]; then cc=bbr; qdisc=fq; modprobe tcp_bbr 2>/dev/null || true
    else cc=cubic; qdisc=fq_codel; fi
    mkdir -p /etc/sysctl.d || return 1
    # Keep a dedicated, documented MTunnel override (system-wide effect).
    printf 'net.core.default_qdisc=%s\nnet.ipv4.tcp_congestion_control=%s\n' "$qdisc" "$cc" > /etc/sysctl.d/99-mtunnel-bbr.conf || return 1
    sysctl -w "net.core.default_qdisc=$qdisc" >/dev/null 2>&1 || true
    sysctl -w "net.ipv4.tcp_congestion_control=$cc" >/dev/null 2>&1 || return 1
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "$cc" ]
}
mt_bbr_status() {
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ] && echo ON || echo OFF
}
mt_bbr_menu() {
    local opt
    while true; do
        clear 2>/dev/null || true
        echo -e "\n  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} ${W}MTunnel BBR v%s${NC} — Status: ${C}%s${NC}%*s${B}│${NC}\n" "${MODULE_VERSION:-1.0.2}" "$(mt_bbr_status)" 21 ''
        echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}\n"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Enable BBR${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Disable BBR${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"; read -r opt || return 0
        case "$opt" in 1) mt_bbr_state 1;; 2) mt_bbr_state 0;; 0|q|Q) return 0;; esac
    done
}
mt_healer_units() {
    case "$1" in
        gre) printf '%s\n' mgre.service;;
        vxlan) printf '%s\n' mxlan.service;;
        backhaul|rathole|paqet) systemctl list-unit-files "m${1}@*.service" --no-legend 2>/dev/null | awk '{print $1}';;
        all) printf '%s\n' mgre.service mxlan.service
             systemctl list-unit-files 'mbackhaul@*.service' 'mrathole@*.service' 'mpaqet@*.service' --no-legend 2>/dev/null | awk '{print $1}';;
        *) return 2;;
    esac
}
mt_healer_scan() {
    local scope="$1" unit bad=0
    mt_valid_scope "$scope" || return 2
    while read -r unit; do
        [ -n "$unit" ] || continue
        systemctl is-enabled --quiet "$unit" 2>/dev/null || continue
        if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
            echo -e "  ${Y}● Recovering ${unit}...${NC}"
            systemctl restart "$unit" >/dev/null 2>&1 || bad=1
            systemctl is-active --quiet "$unit" 2>/dev/null || bad=1
        fi
    done < <(mt_healer_units "$scope")
    return "$bad"
}
mt_healer_menu() {
    local scope="$1" opt
    mt_valid_scope "$scope" || return 2
    while true; do
        clear 2>/dev/null || true
        echo -e "\n  ${B}┌─[ AUTO RECOVERY — ${scope^^} ]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run Recovery Scan Now${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"; read -r opt || return 0
        case "$opt" in
            1) if mt_healer_scan "$scope"; then echo -e "  ${G}● Recovery scan complete.${NC}"
               else echo -e "  ${R}✖ Some services could not be recovered.${NC}"; fi
               read -r -p '  Press Enter...' _ || return 0;;
            0|q|Q) return 0;;
        esac
    done
}
mt_run_tool() {
    local name="${1:-}" scope=all; [ "$#" -gt 0 ] && shift
    case "$name" in
        mbbr)
            case "${1:---from-tunnel}" in
                --enable) mt_bbr_state 1;; --disable) mt_bbr_state 0;;
                --status) mt_bbr_status;; --from-tunnel) mt_bbr_menu;;
                *) echo 'Invalid BBR command' >&2; return 2;;
            esac;;
        mhealer)
            local scan_only=0
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --scope) [ "$#" -ge 2 ] || return 2; scope="$2"; shift 2;;
                    --scan) scan_only=1; shift;;
                    *) return 2;;
                esac
            done
            if [ "$scan_only" == 1 ]; then mt_healer_scan "$scope"; else mt_healer_menu "$scope"; fi;;
        *) echo "Unknown built-in MTunnel tool: $name" >&2; return 2;;
    esac
}

mt_ask_bbr_on_create() {
    local answer
    echo -ne "  ${C}●${NC} ${W}Enable BBR? [y/N]: ${NC}"
    read -r answer || answer=''
    case "${answer,,}" in
        y|yes) mt_run_tool mbbr --enable || echo -e "  ${Y}● BBR could not be enabled; tunnel configuration is retained.${NC}" >&2;;
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
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${Y}${extra_label}${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Menu${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"
        rc=0
        read -r choice || rc=$?
        [ "$rc" -le 128 ] || continue
        [ "$rc" -eq 0 ] || return 0
        case "${choice//$'\r'/}" in
            1) "$extra_view";;
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

# BEGIN MTUNNEL CROSS-ENGINE HELPERS
is_global_ipv6() {
    local ip="${1,,}"
    mt_valid_ipv6 "$ip" || return 1
    # A public endpoint must be in 2000::/3. Reject ULA, link-local,
    # loopback, multicast, and unspecified addresses.
    [[ "$ip" =~ ^[23][0-9a-f]{0,3}: ]] || return 1
    # Documentation space is not publicly routable.
    [[ "$ip" != 2001:db8:* ]] || return 1
    return 0
}

subnet_in_use() {
    local sub="$1" exclude="${2:-}" f existing tid vid route
    local candidate="${sub}.0/30"
    mt_ipv4_cidr_overlap() {
        local a="$1" b="$2" ip1 p1 ip2 p2 n1 n2 m1 m2 lo1 hi1 lo2 hi2
        ip1="${a%/*}"; p1="${a#*/}"; [ "$ip1" != "$p1" ] || p1=32
        ip2="${b%/*}"; p2="${b#*/}"; [ "$ip2" != "$p2" ] || p2=32
        [[ "$p1" =~ ^[0-9]+$ && "$p2" =~ ^[0-9]+$ ]] || return 1
        ((p1>=0 && p1<=32 && p2>=0 && p2<=32)) || return 1
        mt_ipv4_u32() { local IFS=. o1 o2 o3 o4; read -r o1 o2 o3 o4 <<< "$1"; mt_valid_ipv4 "$1" || return 1; printf '%u' "$(( (10#$o1<<24) | (10#$o2<<16) | (10#$o3<<8) | 10#$o4 ))"; }
        n1=$(mt_ipv4_u32 "$ip1") || return 1; n2=$(mt_ipv4_u32 "$ip2") || return 1
        if ((p1==0)); then m1=0; else m1=$(( (0xFFFFFFFF << (32-p1)) & 0xFFFFFFFF )); fi
        if ((p2==0)); then m2=0; else m2=$(( (0xFFFFFFFF << (32-p2)) & 0xFFFFFFFF )); fi
        lo1=$((n1 & m1)); hi1=$((lo1 | (0xFFFFFFFF ^ m1)))
        lo2=$((n2 & m2)); hi2=$((lo2 | (0xFFFFFFFF ^ m2)))
        ((lo1 <= hi2 && lo2 <= hi1))
    }
    for f in "$MT_ROOT_CONF"/tunnels/*.conf "$MT_ROOT_CONF"/vxlan/*.conf; do
        [ -f "$f" ] || continue
        [ -n "$exclude" ] && [ "$(readlink -f "$f")" == "$(readlink -f "$exclude")" ] && continue
        existing=$(mt_config_value CORE_SUBNET "$f")
        if [ -z "$existing" ]; then
            if [[ "$f" == */vxlan/* ]]; then
                vid=$(mt_config_value VNI_ID "$f"); [ -n "$vid" ] && existing=$(mt_legacy_core_subnet "$vid" vxlan 2>/dev/null || true)
            else
                tid=$(mt_config_value TUN_ID "$f"); [ -n "$tid" ] && existing=$(mt_legacy_core_subnet "$tid" gre 2>/dev/null || true)
            fi
        fi
        [ -z "$existing" ] || ! mt_ipv4_cidr_overlap "$candidate" "${existing}.0/30" || return 0
    done
    while read -r route; do
        [[ "$route" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || continue
        mt_ipv4_cidr_overlap "$candidate" "$route" && return 0
    done < <(ip -4 route show table all 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ {print $1}')
    return 1
}

# Identical implementations extracted from MGRE, MXLAN, Rathole, Backhaul and Paqet.
mt_choose_peer_host() {
    local v4 v6 choice custom default
    v4=$(get_local_ip); mt_valid_ipv4 "$v4" || v4=''
    v6=$(get_local_ipv6); mt_valid_ipv6 "$v6" || v6=''
    if [ -n "$v4" ] && [ -n "$v6" ]; then
        echo -e "
  ${DIM}┌─[ PEER LINK ADDRESS ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}IPv4${NC} ${DIM}(${v4})${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}IPv6${NC} ${DIM}(${v6})${NC}"
        echo -e "  ${DIM}└─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Custom IP / Hostname${NC}"
        mt_ask choice 'Select address [1]: ' || return 1
        case "${choice:-1}" in
            1) custom="$v4";;
            2) custom="$v6";;
            3) mt_ask custom 'Reachable public IP / hostname: ' || return 1;;
            *) return 1;;
        esac
    else
        default="${v4:-$v6}"
        mt_ask custom "This server's reachable public IP/hostname [${default:-none}]: " || return 1
        custom="${custom:-$default}"
    fi
    mt_valid_host "$custom" && [[ "$custom" != 0.0.0.0 && "$custom" != :: ]] || { echo 'Enter a reachable endpoint.' >&2; return 1; }
    MT_PEER_HOST="$custom"
}

mt_header_refresh_now() {
    [ -t 1 ] || return 0
    [ -n "${MT_HEADER:-}" ] || return 0
    local frame
    frame=$(HEADER_LIVE=1 "$MT_HEADER" 2>/dev/null) || return 0
    [ -n "$frame" ] || return 0
    printf '\0337\033[1;1H%s\0338' "$frame"
}

mt_live_readline() {
    local __var="$1" prompt="$2" buffer="" char rc now last_refresh=0
    printf '%b' "$prompt"
    while true; do
        IFS= read -rsn1 -t 0.25 char
        rc=$?
        if [ $rc -ne 0 ]; then
            if [ "$rc" -eq 142 ] || [ "$rc" -gt 128 ]; then
                now=$(date +%s)
                if [ "$now" != "$last_refresh" ]; then
                    last_refresh="$now"
                    mt_header_refresh_now
                fi
                continue
            fi
            return "$rc"
        fi
        if [[ -z "$char" || "$char" == $'\n' || "$char" == $'\r' ]]; then
            echo
            break
        fi
        if [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
            if [ -n "$buffer" ]; then
                buffer="${buffer%?}"
                printf '\b \b'
            fi
            continue
        fi
        buffer+="$char"
        printf '%s' "$char"
    done
    printf -v "$__var" '%s' "$buffer"
}

mt_ask() { # styled prompt + live header refresh while waiting for peer input
    local __var="$1"; shift
    mt_live_readline "$__var" "  ${C}●${NC} ${W}$*${NC} "
}

mt_workspace_screen() { "$MT_HEADER"; }

mt_term_cols() {
    local c
    c=$(tput cols 2>/dev/null || printf '%s' "${COLUMNS:-80}")
    [[ "$c" =~ ^[0-9]+$ ]] || c=80
    [ "$c" -ge 32 ] || c=32
    printf '%s' "$c"
}

mt_workspace_row() {
    local cols max_label label="$2"
    cols=$(mt_term_cols)
    max_label=$((cols - 12)); [ "$max_label" -lt 12 ] && max_label=12
    [ ${#label} -le "$max_label" ] || label="${label:0:$((max_label-1))}…"
    printf '  %b├─%b %b%-2s%b%b❯%b %b\033[1m%s%b%b\n' \
        "$DIM" "$NC" "$W" "$1" "$NC" "$DIM" "$NC" "${3:-$C}" "$label" "$NC" "${4:-}"
}

mt_workspace_group() {
    local cols; cols=$(mt_term_cols)
    if [ "${2:-}" = first ]; then
        printf '\n  %b┌─[ %s ]%b\n' "$DIM" "$1" "$NC"
    else
        [ "$cols" -lt 72 ] || printf '  %b│%b\n' "$DIM" "$NC"
        printf '  %b├─[ %s ]%b\n' "$DIM" "$1" "$NC"
    fi
    [ "$cols" -lt 72 ] || printf '  %b│%b\n' "$DIM" "$NC"
}

mt_workspace_footer() {
    # Keep option 0 *inside* the left-hand menu frame, visibly separated
    # from destructive actions such as Delete/Uninstall. Shared by all tunnels.
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├────────────────────────────%b\n' "$DIM" "$NC"
    printf '  %b└─%b %b0%b %b❯%b %b\033[1m%s%b\n\n' \
        "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$DIM" "$1" "$NC"
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
        mt_workspace_footer 'Return to Previous Menu'
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
    local _pause_input
    mt_live_readline _pause_input "  ${DIM}Press Enter to continue...${NC}" || true
}

mt_peer_key_file() {
    local keyfile="${MTUNNEL_PEER_LINK_KEY_FILE:-/etc/mtunnel/peer-link.key}" raw mode
    [[ -f "$keyfile" && -r "$keyfile" && ! -L "$keyfile" ]] || return 1
    mode=$(stat -c %a "$keyfile" 2>/dev/null) || return 1
    # No permissions for group/other, key must be 32 random bytes represented as hex.
    (( (8#$mode & 0077) == 0 )) || return 1
    raw=$(cat "$keyfile")
    [[ "$raw" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    MT_PEER_SECRET_FILE="$keyfile"
    MT_PEER_MAC_KEY=$(printf 'mtunnel-v3-hmac:%s' "$raw" | sha256sum)
    MT_PEER_MAC_KEY="${MT_PEER_MAC_KEY%% *}"
}
mt_peer_hmac() {
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:$MT_PEER_MAC_KEY" -r 2>/dev/null | awk '{print $1}'
}
mt_link_encode() {
    mt_link_validate || return 1
    local raw encoded checksum key ver=2
    raw=$(for key in "${!MT_LINK_DATA[@]}"; do
            [ "$key" = SYNC_KEY ] && [ "${MT_LINK_DATA[SYNC_KEY]}" = "${MT_LINK_DATA[TUN_SECRET]:-}" ] && continue
            printf '%s=%s\n' "$key" "${MT_LINK_DATA[$key]}"
          done | LC_ALL=C sort)
    if mt_peer_key_file; then
        command -v openssl >/dev/null 2>&1 || { echo 'OpenSSL required for encrypted Peer Links.' >&2; return 1; }
        encoded=$(printf '%s\n' "$raw" | gzip -9n | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$MT_PEER_SECRET_FILE" -a -A 2>/dev/null | tr '+/' '-_' | tr -d '=') || return 1
        [[ "$encoded" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
        checksum=$(printf '%s' "3/$MT_KIND/$encoded" | mt_peer_hmac) || return 1
        [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || return 1
        printf 'mtunnel://3/%s/%s.%s\n' "$MT_KIND" "$encoded" "$checksum"
    else
        if [ -n "${MTUNNEL_PEER_LINK_KEY_FILE:-}" ] || [ -e /etc/mtunnel/peer-link.key ]; then
            echo 'Configured Peer Link key is invalid or insecurely permissioned; refusing plaintext fallback.' >&2
            return 1
        fi
        # Preserve compatibility until operators provision the same out-of-band
        # encryption key on BOTH peers; legacy v2 is neither secret nor authenticated.
        echo 'WARNING: Peer Link is NOT encrypted. Protect it as a password.' >&2
        encoded=$(printf '%s\n' "$raw" | gzip -9n | base64 -w0 | tr '+/' '-_' | tr -d '=')
        checksum=$(printf '%s' "2/$MT_KIND/$encoded" | sha256sum); checksum="${checksum:0:16}"
        printf 'mtunnel://2/%s/%s.%s\n' "$MT_KIND" "$encoded" "$checksum"
    fi
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
        mtunnel://3/*) ver=3; rest="${link#mtunnel://3/}";;
        *) return 1;;
    esac
    kind="${rest%%/*}"; rest="${rest#*/}"
    [[ "$kind" =~ ^(gre|vxlan|backhaul|rathole|paqet)$ ]] || return 1
    [ "$kind" = "$MT_KIND" ] || { echo "This link is for $kind, not $MT_KIND." >&2; return 1; }
    encoded="${rest%.*}"; checksum="${rest##*.}"
    [[ "$encoded" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    if [ "$ver" = 3 ]; then
        [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || return 1
        mt_peer_key_file || { echo 'Encrypted link: matching local /etc/mtunnel/peer-link.key is required.' >&2; return 1; }
        actual=$(printf '%s' "3/$kind/$encoded" | mt_peer_hmac) || return 1
    elif [ "$ver" = 1 ]; then
        [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || return 1
        actual=$(printf '%s' "1/$kind/$encoded" | sha256sum); actual="${actual%% *}"
    else
        [[ "$checksum" =~ ^[a-f0-9]{16}$ ]] || return 1
        actual=$(printf '%s' "2/$kind/$encoded" | sha256sum); actual="${actual:0:16}"
    fi
    [ "$actual" = "$checksum" ] || { echo 'Setup link checksum failed.' >&2; return 1; }
    padded=$(printf '%s' "$encoded" | tr '_-' '/+'); case $((${#padded}%4)) in 2) padded+='==';; 3) padded+='=';; 1) return 1;; esac
    if [ "$ver" = 3 ]; then
        raw=$(printf '%s' "$padded" | base64 -d 2>/dev/null | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$MT_PEER_SECRET_FILE" 2>/dev/null | gunzip 2>/dev/null) || return 1
    elif [ "$ver" = 1 ]; then
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
    # v2/v3 links omit SYNC_KEY when it equals the tunnel secret; restore it here.
    if [[ "$ver" = 2 || "$ver" = 3 ]] && [[ ! -v MT_LINK_DATA[SYNC_KEY] ]] && [[ -v MT_LINK_DATA[TUN_SECRET] ]]; then MT_LINK_DATA[SYNC_KEY]="${MT_LINK_DATA[TUN_SECRET]}"; fi
    mt_link_validate
}

mt_bbr_state() { [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ] && echo 1 || echo 0; }

mt_sync_bbr_from_peer() {
    local desired="${1:-0}" current
    [[ "$desired" =~ ^[01]$ ]] || desired=0
    current=$(mt_bbr_state)
    [ "$current" = "$desired" ] && return 0
    if [ "$desired" = 1 ]; then
        mt_run_tool mbbr --enable || echo -e "  ${Y}● Could not enable BBR to match the peer; tunnel was kept.${NC}" >&2
    else
        mt_run_tool mbbr --disable || echo -e "  ${Y}● Could not disable BBR to match the peer; tunnel was kept.${NC}" >&2
    fi
    return 0
}

mt_ask_bbr_from_peer() { mt_sync_bbr_from_peer 1; }

mt_clipboard_copy() {
    local text="$1" encoded seq
    command -v base64 >/dev/null 2>&1 || return 1
    encoded=$(printf '%s' "$text" | base64 -w0 2>/dev/null) || return 1
    # OSC 52 writes to the LOCAL terminal clipboard even when MTunnel runs over SSH.
    # tmux/screen need passthrough wrappers; direct terminals receive OSC 52 as-is.
    if [ -n "${TMUX:-}" ]; then
        seq=$(printf '\033Ptmux;\033\033]52;c;%s\a\033\\' "$encoded")
    elif [[ "${TERM:-}" == screen* ]]; then
        seq=$(printf '\033P\033]52;c;%s\a\033\\' "$encoded")
    else
        seq=$(printf '\033]52;c;%s\a' "$encoded")
    fi
    if [ -w /dev/tty ]; then printf '%s' "$seq" > /dev/tty 2>/dev/null; else printf '%s' "$seq"; fi
}

mt_peer_copy_prompt() {
    local link="$1" key rc now last_refresh=0
    mt_clipboard_copy "$link" >/dev/null 2>&1 || true
    echo -e "  ${G}●${NC} ${W}Peer Code sent to clipboard.${NC} ${DIM}(terminal support required)${NC}"
    while true; do
        printf '  %bC%b = Copy again   %bEnter%b = Continue ❯❯ ' "$C" "$NC" "$C" "$NC"
        while true; do
            key=''
            IFS= read -rsn1 -t 0.25 key
            rc=$?
            if [ $rc -eq 0 ]; then break; fi
            if [ "$rc" -eq 142 ] || [ "$rc" -gt 128 ]; then
                now=$(date +%s)
                if [ "$now" != "$last_refresh" ]; then last_refresh="$now"; mt_header_refresh_now; fi
                continue
            fi
            return 0
        done
        case "$key" in
            c|C)
                mt_clipboard_copy "$link" >/dev/null 2>&1 || true
                printf '\r\033[K  %b●%b %bCopy request sent again.%b\n' "$G" "$NC" "$W" "$NC"
                ;;
            ''|$'\n'|$'\r')
                echo
                return 0
                ;;
        esac
    done
}

mt_link_box() {
    local text="$1" box_width=80 pad=5 inner_width text_width line chunk
    inner_width=$((box_width - 2))
    text_width=$((inner_width - (pad * 2)))
    printf -v line '%*s' "$inner_width" ''
    line="${line// /─}"
    echo -e "  ${DIM}╭${line}╮${NC}"
    while [ -n "$text" ]; do
        chunk="${text:0:text_width}"
        text="${text:text_width}"
        printf "  ${DIM}│${NC}%*s${W}%-*s${NC}%*s${DIM}│${NC}
" "$pad" '' "$text_width" "$chunk" "$pad" ''
    done
    echo -e "  ${DIM}╰${line}╯${NC}"
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

mt_link_validate() {
    local key required
    [[ "$MT_KIND" =~ ^(gre|vxlan|backhaul|rathole|paqet)$ ]] || return 1
    local allowed=' ROLE NAME HOST EXPIRES BBR '
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
    MT_LINK_DATA[BBR]=$(mt_bbr_state)
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
        mt_choose_peer_host || return 1
        host="$MT_PEER_HOST"
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
    mt_workspace_screen
    echo -e "\n  ${DIM}┌─[ PEER CODE (valid for 7 days) ]${NC}\n  ${DIM}│${NC}"
    mt_link_box "$link"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${Y}Contains the tunnel secret. Share privately; this link is not encrypted.${NC}"
    mt_peer_copy_prompt "$link"
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

# END MTUNNEL CROSS-ENGINE HELPERS

# ═══════════════════════════════════════════════════════════════════════════
#  UNIFIED HEADER (v1.1.3) — one look for the main dashboard and every tunnel
#  module. Modules fill MT_HDR_ROWS (their OWN tunnels only) and call mt_hdr_draw.
#  Row format (pipe separated, max 3 rows are drawn):
#     state|name|tag|peer|vip|ping|loss|up|fwd        state: 1=up 0=down
# ═══════════════════════════════════════════════════════════════════════════
MT_HDR_ROWS=''
MT_HDR_ROW_COUNT=0

mt_hdr_cols() {
    local c
    c=$(tput cols 2>/dev/null) || c=''
    [[ "$c" =~ ^[0-9]+$ ]] || c=$({ stty size </dev/tty; } 2>/dev/null | awk '{print $2}')
    [[ "$c" =~ ^[0-9]+$ ]] || c="${COLUMNS:-120}"
    printf '%s' "$c"
}

mt_local_ipv4() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s' "${ip:-Unknown}"
}

# Primary global IPv6 of this host (empty when the host has none).
mt_local_ipv6() {
    local ip
    ip=$(ip -6 -o addr show scope global 2>/dev/null | grep -v -E 'temporary|deprecated|tentative' | awk '{print $4}' | cut -d/ -f1 | head -n 1)
    [ -n "$ip" ] || ip=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    printf '%s' "${ip,,}"
}

mt_fmt_speed() {
    local b="$1"
    if [ -z "$b" ] || [ "$b" -le 0 ] 2>/dev/null; then echo "0 B/s"; return; fi
    if [ "$b" -lt 1024 ]; then echo "${b} B/s"
    elif [ "$b" -lt 1048576 ]; then
        if [ $((b / 1024)) -lt 100 ]; then awk -v v="$b" 'BEGIN {printf "%.1f KB/s", v/1024}'
        else echo "$((b / 1024)) KB/s"; fi
    elif [ "$b" -lt 1073741824 ]; then
        if [ $((b / 1048576)) -lt 100 ]; then awk -v v="$b" 'BEGIN {printf "%.1f MB/s", v/1048576}'
        else echo "$((b / 1048576)) MB/s"; fi
    else awk -v v="$b" 'BEGIN {printf "%.1f GB/s", v/1073741824}'; fi
}

# CPU / RAM / network sample, same file + format the main dashboard writes, so
# the two never disagree. A module only samples itself when the file is stale
# (module started on its own, without the main dashboard running).
mt_sys_stats_collect() {
    local dir="${SECURE_TMP:-/root/mtunnel/tmp}" target
    mkdir -p "$dir" 2>/dev/null || return 1
    target="$dir/.main_sys_stats.$$"
    local cores cpu_pct=0 p_idle p_total u n s i io ir st cur_idle cur_total d_idle d_total
    cores=$(nproc 2>/dev/null); [ -n "$cores" ] || cores=1
    read -r _ u n s i io ir st _ < <(grep '^cpu ' /proc/stat 2>/dev/null)
    cur_idle=$(( ${i:-0} + ${io:-0} )); cur_total=$(( ${u:-0} + ${n:-0} + ${s:-0} + ${i:-0} + ${io:-0} + ${ir:-0} + ${st:-0} ))
    if [ -f "$dir/.cpu_last" ]; then
        read -r p_idle p_total < "$dir/.cpu_last"
        d_idle=$(( cur_idle - ${p_idle:-0} )); d_total=$(( cur_total - ${p_total:-0} ))
        if [ "$d_total" -gt 0 ] 2>/dev/null; then
            cpu_pct=$(( (d_total - d_idle) * 100 / d_total ))
            [ "$cpu_pct" -lt 0 ] && cpu_pct=0; [ "$cpu_pct" -gt 100 ] && cpu_pct=100
        fi
    else cpu_pct=5; fi
    echo "$cur_idle $cur_total" > "$dir/.cpu_last"
    local r_used="0G" r_total="0G" r_pct=0 mt ma mu
    mt=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null); ma=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)
    [ -n "$ma" ] || ma=$(awk '/MemFree/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$mt" ] && [ "$mt" -gt 0 ] 2>/dev/null; then
        mu=$(( mt - ${ma:-0} )); r_pct=$(( mu * 100 / mt ))
        r_used=$(awk -v v="$mu" 'BEGIN {if(v<1048576) printf "%.0fM", v/1024; else printf "%.1fG", v/1048576}')
        r_total=$(awk -v v="$mt" 'BEGIN {printf "%.1fG", v/1048576}')
    fi
    local dev rx_speed="0 B/s" tx_speed="0 B/s" now_ts cur_rx cur_tx p_ts p_rx p_tx dt drx dtx
    dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
    [ -n "$dev" ] || dev=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n 1)
    now_ts=$(date +%s)
    if [ -n "$dev" ] && [ -r "/sys/class/net/$dev/statistics/rx_bytes" ]; then
        cur_rx=$(cat "/sys/class/net/$dev/statistics/rx_bytes" 2>/dev/null); cur_tx=$(cat "/sys/class/net/$dev/statistics/tx_bytes" 2>/dev/null)
        if [ -f "$dir/.net_last" ]; then
            read -r p_ts p_rx p_tx < "$dir/.net_last"
            dt=$(( now_ts - ${p_ts:-now_ts} ))
            if [ "$dt" -gt 0 ]; then
                drx=$(( (cur_rx - p_rx) / dt )); dtx=$(( (cur_tx - p_tx) / dt ))
                [ "$drx" -lt 0 ] && drx=0; [ "$dtx" -lt 0 ] && dtx=0
                rx_speed=$(mt_fmt_speed "$drx"); tx_speed=$(mt_fmt_speed "$dtx")
            fi
        fi
        echo "$now_ts $cur_rx $cur_tx" > "$dir/.net_last"
    fi
    local v6="OFF"
    if ip -6 route show default 2>/dev/null | grep -q default || ip -6 addr show scope global 2>/dev/null | grep -q inet6; then v6="ON"; fi
    echo "${cpu_pct}|${cores}|${r_used}|${r_total}|${r_pct}|${rx_speed}|${tx_speed}|${v6}" > "$target" && mv -f "$target" "$dir/.main_sys_stats" 2>/dev/null
}

mt_sys_stats_read() {
    local f="${SECURE_TMP:-/root/mtunnel/tmp}/.main_sys_stats" now mtime
    MT_CPU_PCT=0; MT_CPU_CORES=1; MT_RAM_USED="0G"; MT_RAM_TOTAL="0G"; MT_RAM_PCT=0; MT_RX="0 B/s"; MT_TX="0 B/s"; MT_V6_STATE="OFF"
    now=$(date +%s); mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    [ $(( now - mtime )) -le 12 ] || mt_sys_stats_collect 2>/dev/null
    [ -f "$f" ] && IFS='|' read -r MT_CPU_PCT MT_CPU_CORES MT_RAM_USED MT_RAM_TOTAL MT_RAM_PCT MT_RX MT_TX MT_V6_STATE < "$f"
    return 0
}

# Fill MT_HDR_ROWS from an engine's "st|name|peer|ping|loss|up|fwd" cache file.
# $1 file  $2 tag shown in [..]  $3 name prefix to strip
mt_hdr_rows_from_cache() {
    local file="$1" tag="$2" strip="${3:-}" st name peer ping loss up fwd n=0
    MT_HDR_ROWS=''; MT_HDR_ROW_COUNT=0
    [ -s "$file" ] || return 0
    while IFS='|' read -r st name peer ping loss up fwd; do
        [ -n "$name" ] || continue
        n=$((n+1)); [ "$n" -gt 3 ] && break
        [ -z "$strip" ] || name="${name#"$strip"}"
        MT_HDR_ROWS+="${st}|${name}|${tag}|${peer}|OFF|${ping}|${loss}|${up}|${fwd}"$'\n'
    done < "$file"
    MT_HDR_ROW_COUNT=$n; [ "$n" -le 3 ] || MT_HDR_ROW_COUNT=3
}

_mt_info_cell() { # content-width label value color  (pads by characters, not bytes)
    local w="$1" l="$2" v="$3" c="$4" lead='' room LC_CTYPE=C.UTF-8
    [ -z "$l" ] || lead="${l}: "
    room=$(( w - ${#lead} )); (( room < 0 )) && room=0
    (( ${#v} > room )) && v="${v:0:room}"
    printf ' %b%s%b%b%s%*s%b ' "$DIM" "$lead" "$NC" "$c" "$v" "$((room-${#v}))" '' "$NC"
}

# mt_hdr_draw "<title>" "<label>|<value>|<color>" [info cells "<label>|<value>|<color>" x4]
#   cell 4 of row 1 = BBR + the given label/value (e.g. "Active|2/3|$G")
#   info cells (optional) draw a 3rd dashboard row aligned with the 4 columns
mt_hdr_draw() {
    local title="$1" x_spec="${2:-}"
    shift; [ $# -eq 0 ] || shift
    local -a info=("$@")
    local x_label='' x_val='' x_col="$DIM"
    IFS='|' read -r x_label x_val x_col <<< "$x_spec"
    [ -n "$x_col" ] || x_col="$DIM"

    local s_ip s_v6 bbr_cc bbr_col="$DIM" bbr_icon="○" bbr_text="OFF"
    s_ip=$(mt_local_ipv4); s_ip="${s_ip:0:16}"
    s_v6=$(mt_local_ipv6)
    bbr_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [ "$bbr_cc" = bbr ] && { bbr_col="$G"; bbr_icon="●"; bbr_text="ON"; }
    mt_sys_stats_read
    local cpu_col="$G" ram_col="$G" rx_col="$DIM" tx_col="$DIM" core_label="${MT_CPU_CORES} Cores"
    [ "$MT_CPU_PCT" -gt 60 ] 2>/dev/null && cpu_col="$Y"; [ "$MT_CPU_PCT" -gt 85 ] 2>/dev/null && cpu_col="$R"
    [ "$MT_RAM_PCT" -gt 70 ] 2>/dev/null && ram_col="$Y"; [ "$MT_RAM_PCT" -gt 88 ] 2>/dev/null && ram_col="$R"
    [ "$MT_CPU_CORES" = 1 ] && core_label="1 Core"
    [[ "$MT_RX" != "0 B/s" && -n "$MT_RX" ]] && rx_col="$G"
    [[ "$MT_TX" != "0 B/s" && -n "$MT_TX" ]] && tx_col="$Y"
    local cpu_str="${MT_CPU_PCT}%" ram_str="${MT_RAM_USED}/${MT_RAM_TOTAL} [${MT_RAM_PCT}%]"

    local -a rows=(); local line
    while IFS= read -r line; do [ -n "$line" ] && rows+=("$line"); done <<< "$MT_HDR_ROWS"
    [ "${#rows[@]}" -le 3 ] || rows=("${rows[@]:0:3}")
    MT_HDR_ROW_COUNT=${#rows[@]}

    [ -n "${HEADER_LIVE:-}" ] || clear
    local term_cols boxw content_w border cl
    term_cols=$(mt_hdr_cols)

    # ── compact layouts (narrow terminals) ──────────────────────────────
    if [ "$term_cols" -lt 124 ]; then
        local v6_txt="OFF"; [ -n "$s_v6" ] && v6_txt="$s_v6"
        if [ "$term_cols" -lt 72 ]; then
            boxw=$((term_cols - 4)); [ "$boxw" -lt 32 ] && boxw=32; [ "$boxw" -gt 66 ] && boxw=66
        else
            boxw=$((term_cols - 4)); [ "$boxw" -lt 32 ] && boxw=32; [ "$boxw" -gt 78 ] && boxw=78
        fi
        content_w=$((boxw - 2))
        printf -v border '%*s' "$content_w" ''; border="${border// /─}"
        printf '\033[K\n  %b╭%s╮%b\033[K\n' "$B" "$border" "$NC"
        _mt_hdr_line() {
            local t="$1" w=$((content_w-2)) LC_CTYPE=C.UTF-8
            (( ${#t} > w )) && t="${t:0:w}"
            printf "  ${B}│${NC} %s%*s ${B}│${NC}\033[K\n" "$t" "$((w-${#t}))" ''
        }
        _mt_hdr_line "${title} | ${s_ip}"
        _mt_hdr_line "IPv6 ${v6_txt}"
        _mt_hdr_line "CPU ${cpu_str} | RAM ${ram_str} | BBR ${bbr_text}"
        [ -z "$x_label" ] || _mt_hdr_line "${x_label} ${x_val} | RX ${MT_RX} | TX ${MT_TX}"
        local c
        for c in "${info[@]}"; do
            local il iv; IFS='|' read -r il iv _ <<< "$c"
            [ -z "$il" ] || _mt_hdr_line "${il}: ${iv}"
        done
        printf "  ${B}├%s┤${NC}\033[K\n" "$border"
        if [ "${#rows[@]}" -eq 0 ]; then _mt_hdr_line "No tunnels configured."
        else
            local st name tag peer vip ping loss up fwd
            for line in "${rows[@]}"; do
                IFS='|' read -r st name tag peer vip ping loss up fwd <<< "$line"
                [[ "$loss" =~ ^[0-9]+$ ]] && loss="${loss}%"
                _mt_hdr_line "$([ "$st" = 1 ] && echo '●' || echo '○') ${name} [${tag}] | ${peer:-"---"} | Ping ${ping:-"---"} | Loss ${loss:-"---"}"
            done
        fi
        printf '  %b╰%s╯%b\033[K\n' "$B" "$border" "$NC"
        unset -f _mt_hdr_line
        return 0
    fi

    # ── wide dashboard: sized from what has to be shown (same maths as main) ──
    local total extra peer_w v6_col v6_text v6_need peer_need need_total w6 w4 v6_field
    if [ -n "$s_v6" ]; then v6_col="$M"; v6_text="$s_v6"; v6_need=$(( ${#s_v6} + 10 ))
    else v6_col="$DIM"; v6_text="OFF"; v6_need=21; fi
    (( v6_need < 21 )) && v6_need=21
    peer_need=16
    for line in "${rows[@]}"; do
        local _p; IFS='|' read -r _ _ _ _p _ <<< "$line"
        (( ${#_p} > peer_need )) && peer_need=${#_p}
    done
    need_total=$(( 31 + 25 + v6_need + 29 + 3 ))
    (( need_total < 117 )) && need_total=117
    (( 117 + peer_need - 16 > need_total )) && need_total=$(( 117 + peer_need - 16 ))
    total=$(( term_cols - 4 )); (( total > 150 )) && total=150
    (( total > need_total )) && total=$need_total
    (( total < 117 )) && total=117
    extra=$(( total - 117 )); peer_w=$(( 16 + extra ))
    w6=$v6_need
    (( w6 > total - 31 - 25 - 29 - 3 )) && w6=$(( total - 31 - 25 - 29 - 3 ))
    w4=$(( total - 31 - 25 - w6 - 3 ))
    v6_field=$(( w6 - 10 ))
    printf -v border '%*s' "$total" ''; border="${border// /─}"

    printf '\033[K\n  %b╭%s╮%b\033[K\n' "$B" "$border" "$NC"
    # Row 1: title | IPv4 | IPv6 | BBR + module status
    local x_lbl="${x_label:0:8}" x_w
    x_w=$(( w4 - 15 - (${#x_lbl} + 1) )); (( x_w < 1 )) && x_w=1
    printf "  ${B}│${NC} ${W}%-29.29s${NC} ${B}│${NC} ${C}◆${NC} ${DIM}IPv4${NC}  ${M}%-15.15s${NC} ${B}│${NC} ${M}◆${NC} ${DIM}IPv6${NC}  %b%-*.*s%b ${B}│${NC} ${DIM}BBR:${NC} %b%s%b %-3.3s  ${DIM}%s:${NC} %b%-*.*s%b ${B}│${NC}\033[K\n" \
        "$title" "$s_ip" \
        "$v6_col" "$v6_field" "$v6_field" "$v6_text" "$NC" \
        "$bbr_col" "$bbr_icon" "$NC" "$bbr_text" \
        "$x_lbl" "$x_col" "$x_w" "$x_w" "$x_val" "$NC"
    printf "  ${B}├${border}┤${NC}\033[K\n"
    # Row 2: CPU/cores | RAM | Net down | Net up
    printf "  ${B}│${NC} ${DIM}CPU:${NC} %b%-4.4s%b   ${DIM}Cores:${NC} ${W}%-10.10s${NC} ${B}│${NC} ${DIM}RAM:${NC} %b%-18.18s%b ${B}│${NC} ${DIM}Net ▼:${NC} %b%-*.*s%b ${B}│${NC} ${DIM}Net ▲:${NC} %b%-*.*s%b ${B}│${NC}\033[K\n" \
        "$cpu_col" "$cpu_str" "$NC" "$core_label" \
        "$ram_col" "$ram_str" "$NC" \
        "$rx_col" "$((w6-9))" "$((w6-9))" "$MT_RX" "$NC" \
        "$tx_col" "$((w4-9))" "$((w4-9))" "$MT_TX" "$NC"

    # Optional row 3: engine specific facts (Core / Status / Peer Ping ...)
    if [ "${#info[@]}" -gt 0 ]; then
        printf "  ${B}├${border}┤${NC}\033[K\n"
        local sep="${B}│${NC}" il0 iv0 ic0 il1 iv1 ic1 il2 iv2 ic2 il3 iv3 ic3
        IFS='|' read -r il0 iv0 ic0 <<< "${info[0]:-}"; IFS='|' read -r il1 iv1 ic1 <<< "${info[1]:-}"
        IFS='|' read -r il2 iv2 ic2 <<< "${info[2]:-}"; IFS='|' read -r il3 iv3 ic3 <<< "${info[3]:-}"
        printf '  %b\033[K\n' "${sep}$(_mt_info_cell 29 "$il0" "$iv0" "${ic0:-$W}")${sep}$(_mt_info_cell 23 "$il1" "$iv1" "${ic1:-$W}")${sep}$(_mt_info_cell $((w6-2)) "$il2" "$iv2" "${ic2:-$W}")${sep}$(_mt_info_cell $((w4-2)) "$il3" "$iv3" "${ic3:-$W}")${sep}"
    fi
    printf "  ${B}├${border}┤${NC}\033[K\n"

    local shown=0
    for line in "${rows[@]}"; do
        local st name tag peer vip ping loss up fwd
        IFS='|' read -r st name tag peer vip ping loss up fwd <<< "$line"
        shown=$((shown+1))
        local pure_name="${name// /}"; [ ${#pure_name} -gt 8 ] && pure_name="${pure_name:0:8}"
        local name_tag="${pure_name} [${tag}]"; [ ${#name_tag} -gt 17 ] && name_tag="${name_tag:0:17}"
        [ ${#peer} -gt "$peer_w" ] && peer="${peer:0:$peer_w}"
        [ -n "$peer" ] || peer="---"
        local stat_icon="●" stat_col="$G"
        if [ "$st" != 1 ] || [ "$up" = DOWN ]; then stat_icon="○"; stat_col="$R"; fi
        local fwd_col="$DIM" fwd_warn=' '; [ -n "$fwd" ] && [ "$fwd" != OFF ] && [ "$fwd" != "---" ] && fwd_col="$C"
        if [[ "$fwd" == *⚠ ]]; then fwd="${fwd%⚠}"; fwd_warn="${R}⚠${NC}"; fwd_col="$Y"; fi
        local vip_col="$DIM"; [ -n "$vip" ] && [ "$vip" != OFF ] && vip_col="$G"
        local live_ping="---"
        if [ -n "$ping" ] && [ "$ping" != "---" ]; then
            local num_p="${ping%ms}"; num_p="${num_p%\*}"
            if [[ "$num_p" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then live_ping=$(awk -v v="$num_p" 'BEGIN {printf "%.0fms", v}'); else live_ping="$ping"; fi
        fi
        local loss_col="$DIM" loss_disp="---"
        if [ -n "$loss" ] && [ "$loss" != "---" ]; then
            loss="${loss%\%}"; loss_disp="${loss}%"
            if [[ "$loss" =~ ^[0-9]+$ ]]; then
                if [ "$loss" -eq 0 ]; then loss_col="$G"; elif [ "$loss" -lt 30 ]; then loss_col="$Y"; else loss_col="$R"; fi
            fi
        fi
        printf "  ${B}│${NC} %b%s%b ${W}%-17.17s${NC} ${B}│${NC} ${DIM}Peer:${NC} ${Y}%-*.*s${NC} ${B}│${NC} ${DIM}vIP:${NC}%b%-5.5s%b ${B}│${NC} ${DIM}Ping:${NC}${Y}%-5.5s${NC} ${B}│${NC} ${DIM}Loss:${NC}%b%-4.4s%b ${B}│${NC} ${DIM}Up:${NC} ${W}%-10.10s${NC} ${B}│${NC} ${DIM}FWD:${NC} %b%-8.8s%b%b ${B}│${NC}\033[K\n" \
            "$stat_col" "$stat_icon" "$NC" "$name_tag" "$peer_w" "$peer_w" "$peer" "$vip_col" "${vip:-OFF}" "$NC" "$live_ping" "$loss_col" "$loss_disp" "$NC" "${up:----}" "$fwd_col" "${fwd:-OFF}" "$NC" "$fwd_warn"
    done
    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}● %-*.*s${NC}  ${B}│${NC}\033[K\n" "$((total-6))" "$((total-6))" "No tunnels of this type are configured on this host."
    fi
    printf '  %b╰%s╯%b\033[K\n' "$B" "$border" "$NC"
}

# ═══════════════════════════════════════════════════════════════════════════
#  MASTER DASHBOARD HEADER
#  Shared by the main dashboard and MTunnel Doctor. This is intentionally
#  the exact main-header renderer so both screens stay pixel-for-pixel aligned.
# ═══════════════════════════════════════════════════════════════════════════
mt_master_iface_uptime() {
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
mt_master_header_draw() {
    local master_version="${1:-${MODULE_VERSION:-${MTUNNEL_RELEASE_VERSION:-unknown}}}"
    local s_ip=$(mt_local_ipv4)
    s_ip="${s_ip:0:16}"

    local bbr_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')

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

    local term_cols boxw content_w compact_line border
    term_cols=$(tput cols 2>/dev/null || echo "${COLUMNS:-120}")
    if [ "$term_cols" -lt 72 ]; then
        local tun_count=0
        boxw=$((term_cols - 4)); [ "$boxw" -lt 32 ] && boxw=32; [ "$boxw" -gt 66 ] && boxw=66
        content_w=$((boxw - 2))
        printf -v border '%*s' "$content_w" ''; border="${border// /─}"
        [ -f "$SECURE_TMP/.main_tun_stats" ] && tun_count=$(awk -F'|' 'NF>2{n++} END{print n+0}' "$SECURE_TMP/.main_tun_stats" 2>/dev/null)
        printf "\033[K\n  ${B}╭${border}╮${NC}\033[K\n"
        compact_line="MDesign v${master_version} | ${s_ip}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        compact_line="CPU ${cpu_str} | RAM ${ram_str} | BBR ${bbr_text} | IPv6 ${v6_text}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        compact_line="Tunnels ${tun_count} | Porter ${porter_text}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        printf "  ${B}╰${border}╯${NC}\033[K\n"
        return 0
    fi
    if [ "$term_cols" -lt 124 ]; then
        boxw=$((term_cols - 4)); [ "$boxw" -lt 32 ] && boxw=32; [ "$boxw" -gt 78 ] && boxw=78
        content_w=$((boxw - 2))
        printf -v border '%*s' "$content_w" ''; border="${border// /─}"
        printf "\033[K\n  ${B}╭${border}╮${NC}\033[K\n"
        compact_line="MDesign v${master_version} | Local: ${s_ip}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        compact_line="CPU ${cpu_str} | RAM ${ram_str} | BBR ${bbr_text} | IPv6 ${v6_text}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        compact_line="Porter ${porter_text} | RX ${rx_speed} | TX ${tx_speed}"; printf "  ${B}│${NC} %-*.*s ${B}│${NC}\033[K\n" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        printf "  ${B}├${border}┤${NC}\033[K\n"
        local cshown=0
        if [ -f "$SECURE_TMP/.main_tun_stats" ]; then
            while IFS='|' read -r t_proto t_name t_remote t_vip t_ping t_loss t_dev t_fwd; do
                [ -n "$t_proto" ] || continue; ((cshown++)); [ "$cshown" -gt 3 ] && break
                local compact_loss="${t_loss:----}"; [[ "$t_loss" =~ ^[0-9]+$ ]] && compact_loss="${t_loss}%"
                compact_line="${t_name} [${t_proto}] | ${t_remote} | Ping ${t_ping:-} | Loss ${compact_loss}"
                printf "  ${B}│${NC} %-*.*s ${B}│${NC}[K
" "$((content_w-2))" "$((content_w-2))" "$compact_line"
            done < "$SECURE_TMP/.main_tun_stats"
        fi
        if [ "$cshown" -eq 0 ]; then
            compact_line='No active tunnels configured.'
            printf "  ${B}│${NC} %-*.*s ${B}│${NC}[K
" "$((content_w-2))" "$((content_w-2))" "$compact_line"
        fi
        printf "  ${B}╰${border}╯${NC}[K
"
        return 0
    fi

    # Wide dashboard (responsive): the frame is sized from what has to be shown.
    #   - never narrower than 117 columns (original layout), never wider than the terminal / 150
    #   - grows only as far as needed for the server IPv6 and the longest tunnel Peer
    #   - when the server has no IPv6 the IPv6 cell shrinks and so does the whole header
    local total extra peer_w v6_addr v6_need peer_need need_total w6 w4 v6_field
    v6_addr=$(mt_local_ipv6)
    if [ -n "$v6_addr" ]; then v6_col="${M}"; v6_text="$v6_addr"; v6_need=$(( ${#v6_addr} + 10 ))
    else v6_col="${DIM}"; v6_text="OFF"; v6_need=21; fi
    (( v6_need < 21 )) && v6_need=21
    peer_need=16
    if [ -f "$SECURE_TMP/.main_tun_stats" ]; then
        peer_need=$(awk -F'|' 'NF>2 && n<3 {n++; l=length($3); if(l>m)m=l} END{print (m<16?16:m)}' "$SECURE_TMP/.main_tun_stats" 2>/dev/null)
        [[ "$peer_need" =~ ^[0-9]+$ ]] || peer_need=16
    fi
    need_total=$(( 31 + 25 + v6_need + 29 + 3 ))
    (( need_total < 117 )) && need_total=117
    (( 117 + peer_need - 16 > need_total )) && need_total=$(( 117 + peer_need - 16 ))
    total=$(( term_cols - 4 ))
    (( total > 150 )) && total=150
    (( total > need_total )) && total=$need_total
    (( total < 117 )) && total=117
    extra=$(( total - 117 )); peer_w=$(( 16 + extra ))
    w6=$v6_need
    (( w6 > total - 31 - 25 - 29 - 3 )) && w6=$(( total - 31 - 25 - 29 - 3 ))
    w4=$(( total - 31 - 25 - w6 - 3 ))
    v6_field=$(( w6 - 10 ))
    printf -v border '%*s' "$total" ''
    border="${border// /─}"

    printf '\033[K\n  %b╭%s╮%b\033[K\n' "$B" "$border" "$NC"
    # Row 1: title 31 | IPv4 25 | IPv6 w6 | BBR + Porter w4
    printf "  ${B}│${NC} ${W}%-29.29s${NC} ${B}│${NC} ${C}◆${NC} ${DIM}IPv4${NC}  ${M}%-15.15s${NC} ${B}│${NC} ${M}◆${NC} ${DIM}IPv6${NC}  %b%-*.*s%b ${B}│${NC} ${DIM}BBR:${NC} %b%s%b %-3.3s  ${DIM}Porter:${NC} %b%s%b %-*.*s ${B}│${NC}\033[K\n" \
        "MDesign Master Core v${master_version}" "$s_ip" \
        "$v6_col" "$v6_field" "$v6_field" "$v6_text" "$NC" \
        "$bbr_col" "$bbr_icon" "$NC" "$bbr_text" \
        "$porter_col" "$porter_icon" "$NC" "$((w4-24))" "$((w4-24))" "$porter_text"
    printf "  ${B}├${border}┤${NC}\033[K\n"
    # Row 2: CPU 31 | RAM 25 | Net ▼ w6 | Net ▲ w4
    printf "  ${B}│${NC} ${DIM}CPU:${NC} %b%-4.4s%b   ${DIM}Cores:${NC} ${W}%-10.10s${NC} ${B}│${NC} ${DIM}RAM:${NC} %b%-18.18s%b ${B}│${NC} ${DIM}Net ▼:${NC} %b%-*.*s%b ${B}│${NC} ${DIM}Net ▲:${NC} %b%-*.*s%b ${B}│${NC}\033[K\n" \
        "$cpu_col" "$cpu_str" "$NC" "$core_label" \
        "$ram_col" "$ram_str" "$NC" \
        "$rx_col" "$((w6-9))" "$((w6-9))" "$rx_speed" "$NC" \
        "$tx_col" "$((w4-9))" "$((w4-9))" "$tx_speed" "$NC"
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

            [ ${#t_remote} -gt "$peer_w" ] && t_remote="${t_remote:0:$peer_w}"

            local if_uptime=$(mt_master_iface_uptime "$t_dev")
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

            printf "  ${B}│${NC} %b%s%b ${W}%-17.17s${NC} ${B}│${NC} ${DIM}Peer:${NC} ${Y}%-*.*s${NC} ${B}│${NC} ${DIM}vIP:${NC}%b%-5.5s%b ${B}│${NC} ${DIM}Ping:${NC}${Y}%-5.5s${NC} ${B}│${NC} ${DIM}Loss:${NC}%b%-4.4s%b ${B}│${NC} ${DIM}Up:${NC} ${W}%-10.10s${NC} ${B}│${NC} ${DIM}FWD:${NC} %b%-9.9s%b ${B}│${NC}\033[K\n" \
                "$stat_col" "$stat_icon" "$NC" "$name_tag" "$peer_w" "$peer_w" "$t_remote" "$vip_col" "$vip_stat" "$NC" "$live_ping" "$loss_col" "$loss_disp" "$NC" "$if_uptime" "$fwd_col" "$fwd_str" "$NC"
        done < "$SECURE_TMP/.main_tun_stats"
    fi

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}● %-*.*s${NC}  ${B}│${NC}\033[K\n" "$((111+extra))" "$((111+extra))" "No active tunnels or fabrics deployed across the ecosystem."
    fi
    printf "  ${B}╰${border}╯${NC}\033[K\n"
}


# ═══════════════════════════════════════════════════════════════════════════
#  PORT CONFLICT GUARD (v1.1.3)
#  Finds out WHO is holding a port (process, systemd unit, command line, or
#  another tunnel's NAT rule), shows it in a vertical card and asks whether to
#  close it and restart this tunnel, skip the port, or cancel.
#
#  mt_port_guard <mode> <tcp_list> <udp_list> [self_units] [self_tag] [context]
#     mode       nat  = iptables DNAT forwarding (loopback-only listeners do not clash)
#                bind = the engine itself binds the port (every listener clashes)
#     *_list     "80,443,10000:10100"  (empty allowed)
#     self_units space separated unit names that belong to THIS tunnel (ignored)
#     self_tag   iptables comment tag that belongs to THIS tunnel (ignored)
#  Result: MT_PORT_TCP / MT_PORT_UDP hold the (possibly reduced) lists,
#          MT_PORT_CLOSED=1 if some other process was closed (caller should
#          (re)start the tunnel so it can take the freed port).
#  Return: 0 proceed | 1 cancelled | 3 nothing usable is left
# ═══════════════════════════════════════════════════════════════════════════
MT_PORT_TCP=''; MT_PORT_UDP=''; MT_PORT_CLOSED=0
declare -gA MT_PL=()

mt_range_fmt() { if [ "$1" = "$2" ]; then printf '%s' "$1"; else printf '%s:%s' "$1" "$2"; fi; }

# "80 81 82 90" -> "80-82, 90"
mt_ports_compact() {
    printf '%s\n' $1 | sort -n -u | awk '
        NF { p=$1+0
             if (start=="") { start=p; prev=p }
             else if (p==prev+1) { prev=p }
             else { out=out (out==""?"":", ") (start==prev?start:start "-" prev); start=p; prev=p } }
        END { if (start!="") out=out (out==""?"":", ") (start==prev?start:start "-" prev); print out }'
}

# list + space separated ports to drop -> new list (ranges are split around them)
mt_ports_subtract() {
    local list="$1" rm=" $2 " item a b p out='' start
    local -a parts=()
    IFS=, read -ra parts <<< "$list"
    for item in "${parts[@]}"; do
        [ -n "$item" ] || continue
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
        elif [[ "$item" =~ ^[0-9]+$ ]]; then a=$((10#$item)); b=$a
        else out+="${out:+,}$item"; continue; fi
        start=''
        for ((p=a; p<=b; p++)); do
            if [[ "$rm" == *" $p "* ]]; then
                [ -z "$start" ] || { out+="${out:+,}$(mt_range_fmt "$start" "$((p-1))")"; start=''; }
            else [ -n "$start" ] || start=$p; fi
        done
        [ -z "$start" ] || out+="${out:+,}$(mt_range_fmt "$start" "$b")"
    done
    printf '%s' "$out"
}

# Fill MT_PL[proto/port] with newline separated "addr|pid,pid|comm" entries.
mt_port_scan() {
    MT_PL=()
    local proto port addr pids comm key
    while IFS='|' read -r proto port addr pids comm; do
        [ -n "$port" ] || continue
        key="${proto}/${port}"
        MT_PL[$key]+="${addr}|${pids}|${comm}"$'\n'
    done < <(ss -H -lntup 2>/dev/null | awk '
        {
            proto=$1; if (proto!="tcp" && proto!="udp") next
            loc=$5; port=loc; sub(/^.*:/,"",port); addr=loc; sub(/:[0-9]+$/,"",addr)
            users=""; for (i=6;i<=NF;i++) if ($i ~ /^users:/) users=$i
            comm=""; pids=""; s=users
            while (match(s, /\("[^"]*",pid=[0-9]+/)) {
                m=substr(s,RSTART,RLENGTH); n=m; sub(/^\("/,"",n); sub(/",pid=.*/,"",n)
                pd=m; sub(/.*pid=/,"",pd)
                if (comm=="") comm=n
                if (index(","pids",", ","pd",")==0) pids=pids (pids==""?"":",") pd
                s=substr(s,RSTART+RLENGTH)
            }
            if (comm=="") comm="?"
            print proto "|" port "|" addr "|" pids "|" comm
        }')
}

mt_port_addr_is_loopback() { case "$1" in 127.*|"[::1]"|::1) return 0;; esac; return 1; }

mt_pid_unit() {
    local pid="$1" unit
    [ -r "/proc/$pid/cgroup" ] || return 1
    unit=$(grep -oE '[^/]+\.service' "/proc/$pid/cgroup" 2>/dev/null | tail -n 1)
    [ -n "$unit" ] || return 1
    printf '%s' "$unit"
}

# pid 1, this script and all of its parents (the SSH session we run in) are untouchable
mt_pid_protected() {
    local pid="$1" cur="$$" comm
    [ "$pid" = 1 ] && return 0
    comm=$(cat "/proc/$pid/comm" 2>/dev/null)
    [ "$comm" = sshd ] && return 0
    while [[ "$cur" =~ ^[0-9]+$ ]] && [ "$cur" -gt 1 ]; do
        [ "$cur" = "$pid" ] && return 0
        cur=$(awk '{print $4}' "/proc/$cur/stat" 2>/dev/null)
    done
    return 1
}

mt_pid_age() {
    local s; s=$(ps -o etimes= -p "$1" 2>/dev/null | tr -d ' ')
    [[ "$s" =~ ^[0-9]+$ ]] || { printf -- '---'; return; }
    local d=$((s/86400)) h=$(( (s%86400)/3600 )) m=$(( (s%3600)/60 ))
    if [ "$d" -gt 0 ]; then printf '%dd %02dh' "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf '%dh %02dm' "$h" "$m"
    else printf '%dm' "$m"; fi
}

# NAT rules that already forward ports: "proto|ports|tag|target"
mt_port_nat_rules() {
    iptables -w 5 -t nat -S PREROUTING 2>/dev/null | awk '
        /-j (DNAT|REDIRECT)/ {
            proto=""; dp=""; tag=""; tgt=""
            for (i=1;i<=NF;i++) {
                if ($i=="-p") proto=$(i+1)
                if ($i=="--dport" || $i=="--dports") dp=$(i+1)
                if ($i=="--comment") { tag=$(i+1); gsub(/"/,"",tag) }
                if ($i=="--to-destination" || $i=="--to-ports") tgt=$(i+1)
            }
            if (proto!="" && dp!="") print proto "|" dp "|" tag "|" tgt
        }'
}

mt_port_in_spec() {  # port, "80,443,1000:2000"
    local port="$1" item a b; local -a parts=()
    IFS=, read -ra parts <<< "$2"
    for item in "${parts[@]}"; do
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
            a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
            ((port >= a && port <= b)) && return 0
        elif [[ "$item" =~ ^[0-9]+$ ]] && ((10#$item == port)); then return 0; fi
    done
    return 1
}

# Human label for the thing behind a unit/process.
mt_port_kind() {  # unit comm
    local unit="$1" comm="$2"
    case "$comm" in docker-proxy) echo docker; return;; esac
    case "$unit" in
        mbackhaul@*|mrathole@*|mpaqet@*|mgre*|mxlan*|mporter*|mtunnel*|haproxy*|gost*) echo mtunnel; return;;
    esac
    [ -n "$unit" ] && echo service || echo process
}

# mt_port_holder_label <tcp|udp> <port>  ->  "nginx [nginx.service, PID 812]" (empty when free)
mt_port_holder_label() {
    local proto="${1:-tcp}" port="$2" addr pids comm unit first
    mt_port_scan
    while IFS='|' read -r addr pids comm; do
        [ -n "$addr$pids$comm" ] || continue
        first="${pids%%,*}"; unit=''
        [ -z "$first" ] || unit=$(mt_pid_unit "$first" 2>/dev/null || true)
        printf '%s [%s%s]' "$comm" "${unit:+$unit, }" "${first:+PID $first}"
        return 0
    done <<< "${MT_PL[${proto}/${port}]:-}"
    return 1
}

# Print the card for one owner group.
#   $1 proto  $2 ports(space sep)  $3 addr  $4 pids  $5 comm  $6 unit  $7 kind  $8 protected(0/1)  $9 context
mt_port_card() {
    local proto="${1^^}" ports="$2" addr="$3" pids="$4" comm="$5" unit="$6" kind="$7" prot="$8" ctx="$9"
    local first="${pids%%,*}" cmd='' user='' n_extra=0 pshown
    if [ -n "$first" ] && [ -r "/proc/$first/cmdline" ]; then
        cmd=$(tr '\0\n\r\t' '    ' < "/proc/$first/cmdline" 2>/dev/null | sed 's/  */ /g; s/ *$//'); cmd="${cmd:0:64}"
        user=$(ps -o user= -p "$first" 2>/dev/null | tr -d ' ')
    fi
    [[ "$pids" == *,* ]] && n_extra=$(( $(tr -cd ',' <<< "$pids" | wc -c) ))
    pshown=$(mt_ports_compact "$ports")
    echo -e "\n  ${R}┌─[ ⚠ PORT CONFLICT${ctx:+ · ${ctx}} ]${NC}"
    echo -e "  ${R}│${NC}"
    echo -e "  ${R}├─${NC} ${DIM}Port(s)   ❯${NC} ${W}${pshown}${NC} ${DIM}(${proto})${NC}"
    if [ "$kind" = rule ]; then
        echo -e "  ${R}├─${NC} ${DIM}Held by   ❯${NC} ${M}NAT forwarding rule${NC} ${DIM}— already forwarded by another tunnel${NC}"
        echo -e "  ${R}├─${NC} ${DIM}Rule tag  ❯${NC} ${Y}${comm}${NC}"
        [ -z "$cmd" ] || echo -e "  ${R}├─${NC} ${DIM}Target    ❯${NC} ${C}${cmd}${NC}"
        echo -e "  ${R}│${NC}"
        echo -e "  ${R}│${NC}  ${DIM}Two DNAT rules on one port: only the first one ever matches.${NC}"
    else
        echo -e "  ${R}├─${NC} ${DIM}Process   ❯${NC} ${Y}${comm}${NC} ${DIM}(PID ${first}$([ "$n_extra" -gt 0 ] && echo ", +${n_extra} more"))${NC}"
        [ -z "$unit" ] || echo -e "  ${R}├─${NC} ${DIM}Service   ❯${NC} ${C}${unit}${NC}"
        echo -e "  ${R}├─${NC} ${DIM}Listening ❯${NC} ${W}${addr}${NC}"
        [ -z "$cmd" ] || echo -e "  ${R}├─${NC} ${DIM}Command   ❯${NC} ${DIM}${cmd}${NC}"
        echo -e "  ${R}├─${NC} ${DIM}Running   ❯${NC} ${W}$(mt_pid_age "$first")${NC}${user:+ ${DIM}(user: ${user})${NC}}"
        case "$kind" in
            mtunnel) echo -e "  ${R}│${NC}"; echo -e "  ${R}│${NC}  ${M}This is another MTunnel component — closing it takes that tunnel down.${NC}" ;;
            docker)  echo -e "  ${R}│${NC}"; echo -e "  ${R}│${NC}  ${Y}Published by a Docker container. Stop the container (docker stop) instead.${NC}" ;;
        esac
        [ "$prot" != 1 ] || { echo -e "  ${R}│${NC}"; echo -e "  ${R}│${NC}  ${R}Protected process (SSH / this session / init) — it cannot be closed from here.${NC}"; }
    fi
    echo -e "  ${R}│${NC}"
}

# stop a holder: unit first (so systemd does not respawn it), then any leftover PID
mt_port_close_owner() {  # unit pids disable(0/1)
    local unit="$1" pids="$2" disable="$3" pid
    if [ -n "$unit" ]; then
        systemctl stop "$unit" >/dev/null 2>&1
        systemctl stop "${unit%.service}.socket" >/dev/null 2>&1
        [ "$disable" != 1 ] || systemctl disable "$unit" >/dev/null 2>&1
    fi
    for pid in ${pids//,/ }; do kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null; done
    sleep 1
    for pid in ${pids//,/ }; do kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null; done
    return 0
}

mt_port_guard() {
    local mode="$1" tcp="$2" udp="$3" self_units="${4:-}" self_tag="${5:-}" ctx="${6:-}"
    MT_PORT_TCP="$tcp"; MT_PORT_UDP="$udp"; MT_PORT_CLOSED=0
    [ -n "$tcp$udp" ] || return 0
    local round=0 proto list p a b item key addr pids comm unit kind u first_pid pid
    local -a parts=()

    while :; do
        round=$((round+1)); [ "$round" -le 12 ] || return 1
        mt_port_scan
        # conflicts[ownerkey] = "proto|ports|addr|pids|comm|unit|kind|prot"
        local -A grp_ports=() grp_meta=()
        local order=()
        for proto in tcp udp; do
            list="$MT_PORT_TCP"; [ "$proto" = udp ] && list="$MT_PORT_UDP"
            [ -n "$list" ] || continue
            IFS=, read -ra parts <<< "$list"
            for item in "${parts[@]}"; do
                if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
                elif [[ "$item" =~ ^[0-9]+$ ]]; then a=$((10#$item)); b=$a
                else continue; fi
                for ((p=a; p<=b; p++)); do
                    key="${proto}/${p}"
                    [ -n "${MT_PL[$key]:-}" ] || continue
                    while IFS='|' read -r addr pids comm; do
                        [ -n "$addr$pids$comm" ] || continue
                        if [ "$mode" = nat ] && mt_port_addr_is_loopback "$addr"; then continue; fi
                        unit=''; first_pid="${pids%%,*}"
                        [ -z "$first_pid" ] || unit=$(mt_pid_unit "$first_pid" 2>/dev/null || true)
                        if [ -n "$unit" ] && [ -n "$self_units" ]; then
                            for u in $self_units; do [ "$u" = "$unit" ] && continue 2; done
                        fi
                        kind=$(mt_port_kind "$unit" "$comm")
                        local prot=0
                        for pid in ${pids//,/ }; do mt_pid_protected "$pid" && prot=1; done
                        [ "$kind" != docker ] || prot=1
                        local gk="L|${proto}|${comm}|${pids}|${unit}"
                        [ -n "${grp_meta[$gk]:-}" ] || { order+=("$gk"); grp_meta[$gk]="${proto}|${addr}|${pids}|${comm}|${unit}|${kind}|${prot}"; }
                        grp_ports[$gk]+="$p "
                        break   # one owner per port is enough for the card
                    done <<< "${MT_PL[$key]}"
                done
            done
        done
        if [ "$mode" = nat ]; then
            local rline rproto rports rtag rtgt
            while IFS='|' read -r rproto rports rtag rtgt; do
                [ -n "$rproto" ] || continue
                [ -z "$self_tag" ] || [ "$rtag" != "$self_tag" ] || continue
                for proto in tcp udp; do
                    [ "$rproto" = "$proto" ] || continue
                    list="$MT_PORT_TCP"; [ "$proto" = udp ] && list="$MT_PORT_UDP"
                    [ -n "$list" ] || continue
                    IFS=, read -ra parts <<< "$list"
                    for item in "${parts[@]}"; do
                        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
                        elif [[ "$item" =~ ^[0-9]+$ ]]; then a=$((10#$item)); b=$a
                        else continue; fi
                        for ((p=a; p<=b; p++)); do
                            mt_port_in_spec "$p" "${rports//,/,}" || continue
                            local gk="R|${proto}|${rtag}|${rtgt}"
                            [ -n "${grp_meta[$gk]:-}" ] || { order+=("$gk"); grp_meta[$gk]="${proto}|rule|${rtgt}|${rtag}||rule|1"; }
                            grp_ports[$gk]+="$p "
                        done
                    done
                done
            done < <(mt_port_nat_rules)
        fi

        if [ "${#order[@]}" -eq 0 ]; then
            if [ "$round" -eq 1 ]; then echo -e "  ${G}✔${NC} ${DIM}Port check: no conflicts found.${NC}"; fi
            [ -n "$MT_PORT_TCP$MT_PORT_UDP" ] || return 3
            return 0
        fi

        # Resolve the first unresolved group, then rescan (closing one holder may free several).
        local gk meta mproto maddr mpids mcomm munit mkind mprot choice gports
        gk="${order[0]}"; meta="${grp_meta[$gk]}"; gports="${grp_ports[$gk]}"
        IFS='|' read -r mproto maddr mpids mcomm munit mkind mprot <<< "$meta"
        mt_port_card "$mproto" "$gports" "$maddr" "${mpids}" "$mcomm" "$munit" "$mkind" "$mprot" "$ctx"
        if [ "$mkind" != rule ] && [ "$mprot" != 1 ]; then
            local what="${munit:-$mcomm}"
            echo -e "  ${R}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Close ${what} and restart this tunnel${NC}"
            [ -z "$munit" ] || echo -e "  ${R}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Close it and keep it disabled at boot${NC}"
        fi
        echo -e "  ${R}├─${NC} ${W}s${NC} ${DIM}❯${NC} ${C}Skip this port (leave it out of the list)${NC}"
        echo -e "  ${R}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel — change nothing${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"
        read -r choice || return 1
        case "${choice,,}" in
            1|2)
                if [ "$mkind" = rule ] || [ "$mprot" = 1 ]; then echo -e "  ${R}✖ Not available for this holder.${NC}"; continue; fi
                if [ "$mkind" = mtunnel ]; then
                    local ans; echo -ne "  ${R}● This stops another MTunnel tunnel. Type 'yes' to confirm: ${NC}"; read -r ans
                    [ "${ans,,}" = yes ] || { echo -e "  ${Y}● Not closed.${NC}"; continue; }
                fi
                mt_port_close_owner "$munit" "$mpids" "$([ "$choice" = 2 ] && echo 1 || echo 0)"
                MT_PORT_CLOSED=1
                local waited=0 still=0
                while [ "$waited" -lt 5 ]; do
                    mt_port_scan; still=0
                    for p in $gports; do [ -z "${MT_PL[${mproto,,}/$p]:-}" ] || { still=1; break; }; done
                    [ "$still" = 0 ] && break
                    sleep 1; waited=$((waited+1))
                done
                if [ "$still" = 1 ]; then echo -e "  ${R}✖ The port is still busy after closing it.${NC}"
                else echo -e "  ${G}✔ ${mcomm} closed; port(s) $(mt_ports_compact "$gports") are free.${NC}"; fi
                ;;
            s|skip)
                if [ "${mproto,,}" = tcp ]; then MT_PORT_TCP=$(mt_ports_subtract "$MT_PORT_TCP" "$gports")
                else MT_PORT_UDP=$(mt_ports_subtract "$MT_PORT_UDP" "$gports"); fi
                echo -e "  ${Y}● Skipped $(mt_ports_compact "$gports") (${mproto^^}).${NC}"
                ;;
            0|q|c|'') echo -e "  ${Y}● Cancelled — nothing was changed.${NC}"; return 1 ;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}" ;;
        esac
    done
}

# ── NAT port-forward engine shared by MGRE and MXLAN (moved out of both modules) ──
mt_get_ssh_ports() {
    local p
    p=$(ss -tlnpH 2>/dev/null | grep -w 'sshd' | awk '{print $4}' | sed 's/.*://' | sort -u | tr '\n' ' ')
    echo "${p:-22}"
}
# Clean a port list (supports ranges a:b). For TCP it refuses to hijack the SSH port.
mt_sanitize_ports() {
    local raw="$1" proto="$2" out="" item a b s skip
    local ssh_ports; ssh_ports=$(mt_get_ssh_ports)
    raw=$(printf '%s' "$raw" | tr -d '[:space:]')
    [ -z "$raw" ] && { echo ''; return 0; }
    [[ "$raw" =~ ^[0-9]+(:[0-9]+)?(,[0-9]+(:[0-9]+)?)*$ ]] || { echo -e "  ${Y}● Invalid port list; use only ports/ranges separated by commas.${NC}" >&2; return 1; }
    local IFS=','
    for item in $raw; do
        [ -z "$item" ] && continue
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
            a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
            { [ "$a" -lt 1 ] || [ "$b" -gt 65535 ] || [ "$a" -ge "$b" ]; } && { echo -e "  ${Y}● Invalid range: $item${NC}" >&2; return 1; }
            item="${a}:${b}"
        else
            a=$((10#$item)); b=$a
            { [ "$a" -lt 1 ] || [ "$a" -gt 65535 ]; } && { echo -e "  ${Y}● Invalid port: $item${NC}" >&2; return 1; }
            item="$a"
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
mt_merge_ports() {
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
mt_remove_ports() {
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
# NAT / Load-Balancer builder. DNAT only hits traffic addressed to THIS host and never traffic coming from the tunnel itself.
mt_rollback_fwd_tag() {
    local tag="$1"
    mt_delete_tagged_rules iptables nat PREROUTING "$tag" >/dev/null 2>&1 || true
    mt_delete_tagged_rules iptables nat POSTROUTING "$tag" >/dev/null 2>&1 || true
    mt_delete_tagged_rules iptables filter FORWARD "$tag" >/dev/null 2>&1 || true
}
mt_build_fwd_rules() {
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
                    iptables -w 5 -t nat -A PREROUTING ! -i "$tif" -m addrtype --dst-type LOCAL -p "$proto" -m "$proto" --dport "$p" -m statistic --mode nth --every "$rem" --packet 0 -m comment --comment "$tag" -j DNAT --to-destination "$dst" 2>/dev/null || { mt_rollback_fwd_tag "$tag"; return 1; }
                else
                    iptables -w 5 -t nat -A PREROUTING ! -i "$tif" -m addrtype --dst-type LOCAL -p "$proto" -m "$proto" --dport "$p" -m comment --comment "$tag" -j DNAT --to-destination "$dst" 2>/dev/null || { mt_rollback_fwd_tag "$tag"; return 1; }
                fi
                iptables -w 5 -t nat -A POSTROUTING -o "$tif" -p "$proto" -m "$proto" -d "$dst" --dport "$p" -m comment --comment "$tag" -j MASQUERADE 2>/dev/null || { mt_rollback_fwd_tag "$tag"; return 1; }
                iptables -w 5 -t filter -A FORWARD -o "$tif" -p "$proto" -d "$dst" --dport "$p" -m comment --comment "$tag" -j ACCEPT 2>/dev/null || { mt_rollback_fwd_tag "$tag"; return 1; }
            done
        done
    done
}

# ── Forward-port conflict detection (non-interactive; safe for watchdogs) ──
# mt_fwd_conflicts <tcp list> <udp list> [self NAT tag]
# Prints "proto/port" for every forwarded port that is (a) held by a non-loopback
# listener (DNAT would silently swallow its traffic) or (b) already DNAT'ed by
# another tunnel's rule. Ranges are checked against the listener table, never expanded.
mt_fwd_conflicts() {
    local tcp="${1:-}" udp="${2:-}" self_tag="${3:-}" key proto port list addr pids comm out='' hit
    local rproto rports rtag rtgt p
    [ -n "$tcp$udp" ] || return 0
    mt_port_scan
    for key in "${!MT_PL[@]}"; do
        proto="${key%%/*}"; port="${key##*/}"
        list="$tcp"; [ "$proto" = udp ] && list="$udp"
        [ -n "$list" ] || continue
        mt_port_in_spec "$port" "$list" || continue
        hit=0
        while IFS='|' read -r addr pids comm; do
            [ -n "$addr$pids$comm" ] || continue
            mt_port_addr_is_loopback "$addr" && continue
            hit=1; break
        done <<< "${MT_PL[$key]}"
        [ "$hit" = 1 ] && out+="${proto}/${port} "
    done
    while IFS='|' read -r rproto rports rtag rtgt; do
        [ -n "$rproto" ] || continue
        [ -z "$self_tag" ] || [ "$rtag" != "$self_tag" ] || continue
        list="$tcp"; [ "$rproto" = udp ] && list="$udp"
        [ "$rproto" = tcp ] || [ "$rproto" = udp ] || continue
        [ -n "$list" ] || continue
        for p in $(mt_ports_expand "$list"); do
            mt_port_in_spec "$p" "$rports" && out+="${rproto}/${p} "
        done
    done < <(mt_port_nat_rules)
    [ -n "$out" ] || return 0
    printf '%s\n' $out | sort -u | tr '\n' ' '
}

# Marker file per tunnel: non-empty = conflicts exist (shown as ⚠ in the FWD column).
mt_fwd_conflict_file() { printf '%s/.mt_fwdconf_%s' "$SECURE_TMP" "$1"; }
mt_fwd_conflict_flag() { [ -s "$(mt_fwd_conflict_file "$1")" ]; }

# Used by the watchdogs: refresh the marker, log only when the state changes.
# $1 name  $2 tcp  $3 udp  $4 self tag  $5 log function (optional)
mt_fwd_conflict_refresh() {
    local name="$1" f old new; f=$(mt_fwd_conflict_file "$name")
    old=$(cat "$f" 2>/dev/null || true)
    new=$(mt_fwd_conflicts "$2" "$3" "$4" 2>/dev/null | sed 's/ *$//')
    if [ -n "$new" ]; then ( umask 077; printf '%s' "$new" > "$f" ); else rm -f "$f"; fi
    if [ "$new" != "$old" ] && [ -n "${5:-}" ]; then
        if [ -n "$new" ]; then "$5" "$name: forward-port conflict with a local listener / other NAT rule: $new"
        else "$5" "$name: forward-port conflicts cleared"; fi
    fi
    return 0
}

# "80,100:102" -> "80 100 101 102"
mt_ports_expand() {
    local item a b p out=''; local -a parts=()
    IFS=, read -ra parts <<< "$1"
    for item in "${parts[@]}"; do
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
        elif [[ "$item" =~ ^[0-9]+$ ]]; then a=$((10#$item)); b=$a
        else continue; fi
        for ((p=a; p<=b; p++)); do out+="$p "; done
    done
    printf '%s' "$out"
}

# ═══════════════════════════════════════════════════════════════════════════
#  LIVE LINK DETECTION (v1.1.5) — shared by Backhaul, Rathole and the main
#  dashboard. Fixes both false results:
#   * "WAITING while connected": the socket belongs to a child/worker of the
#     unit, not to MainPID -> every PID in the unit's cgroup is considered.
#   * "CONNECTED while dead": a half-open ESTABLISHED socket was enough ->
#     the socket must also have received data recently (heartbeats count).
# ═══════════════════════════════════════════════════════════════════════════
mt_unit_pids() {
    local unit="$1" cg f pid
    cg=$(systemctl show "$unit" -p ControlGroup --value 2>/dev/null)
    if [ -n "$cg" ]; then
        for f in "/sys/fs/cgroup${cg}/cgroup.procs" "/sys/fs/cgroup/systemd${cg}/cgroup.procs"; do
            if [ -r "$f" ] && [ -s "$f" ]; then tr '\n' ' ' < "$f"; return 0; fi
        done
    fi
    pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null | tr -dc '0-9')
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "$pid"
}

# _mt_unit_sockets <unit> [local_port] [expected_peer_ip]
# One line "peer_host|lastrcv_ms" per ESTABLISHED socket owned by the unit (any PID of its cgroup).
# lastrcv_ms is empty when the kernel does not report it.
_mt_unit_sockets() {
    local unit="$1" lport="${2:-}" expected="${3:-}" pids lep pep spids lr host p pid mine
    pids=" $(mt_unit_pids "$unit" 2>/dev/null) "
    [ "$pids" != "  " ] || return 1
    while IFS='|' read -r lep pep spids lr; do
        [ -n "$pep" ] || continue
        mine=0
        for pid in ${spids//,/ }; do [[ "$pids" == *" $pid "* ]] && { mine=1; break; }; done
        [ "$mine" = 1 ] || continue
        if [[ "$lport" =~ ^[0-9]+$ ]]; then p="${lep##*:}"; [ "$p" = "$lport" ] || continue; fi
        host="${pep%:*}"; host="${host#[}"; host="${host%]}"; host="${host#::ffff:}"
        if [ -n "$expected" ] && { mt_valid_ipv4 "$expected" 2>/dev/null || mt_valid_ipv6 "$expected" 2>/dev/null; }; then
            [ "$host" = "$expected" ] || continue
        fi
        printf '%s|%s\n' "$host" "$lr"
    done < <(ss -Htinp state established 2>/dev/null | awk '
        function flush() { if (have) print loc "|" peer "|" pids "|" lr; have=0 }
        /^[^ \t]/ { flush(); have=1; loc=$3; peer=$4; lr=""; pids=""; s=$0
            while (match(s,/pid=[0-9]+/)) { pids=pids (pids==""?"":",") substr(s,RSTART+4,RLENGTH-4); s=substr(s,RSTART+RLENGTH) }
            next }
        { if (match($0,/lastrcv:[0-9]+/)) lr=substr($0,RSTART+8,RLENGTH-8) }
        END { flush() }')
}

# mt_hb_max_idle_ms <toml> [default_heartbeat_s]
# How long a healthy link may stay silent = 3 x the heartbeat THIS tunnel is configured with (+5 s),
# clamped to 30 s .. 10 min. heartbeat = 0 (disabled) or no config -> falls back to the old 150 s.
mt_hb_max_idle_ms() {
    local f="$1" def="${2:-40}" v ms
    v=$(awk -F= '/^[[:space:]]*heartbeat(_interval|_timeout)?[[:space:]]*=/ { gsub(/[^0-9]/,"",$2); if ($2!="" && $2+0>m) m=$2+0; seen=1 } END { if (seen) print m+0 }' "$f" 2>/dev/null)
    [[ "$v" =~ ^[0-9]+$ ]] || v="$def"
    [ "$v" -gt 0 ] || { printf '150000'; return; }
    ms=$(( (v * 3 + 5) * 1000 ))
    [ "$ms" -ge 30000 ] || ms=30000
    [ "$ms" -le 600000 ] || ms=600000
    printf '%s' "$ms"
}

# mt_unit_max_idle <unit>  -> silence limit (ms) from the unit's own config; 150000 for engines without heartbeat.
mt_unit_max_idle() {
    local unit="$1" root="${MTUNNEL_TEST_ROOT:-}" f
    case "$unit" in
        mbackhaul@*) f="$root/etc/mbackhaul/tunnels/${unit#*@}.toml"; [ -r "$f" ] && { mt_hb_max_idle_ms "$f" 40; return; };;
        mrathole@*)  f="$root/etc/mrathole/tunnels/${unit#*@}/config.toml"; [ -r "$f" ] && { mt_hb_max_idle_ms "$f" 40; return; };;
    esac
    printf '150000'
}

# mt_unit_live_peer <unit> [local_port] [expected_peer_ip] [max_idle_ms: default from the unit's own heartbeat]
# Prints the peer host of the first ESTABLISHED, recently-active socket of the unit.
mt_unit_live_peer() {
    local max_idle="${4:-$(mt_unit_max_idle "$1")}" host lr
    while IFS='|' read -r host lr; do
        # stale / half-open: nothing received for too long
        if [[ "$lr" =~ ^[0-9]+$ ]] && [ "$lr" -gt "$max_idle" ]; then continue; fi
        printf '%s' "$host"; return 0
    done < <(_mt_unit_sockets "$1" "${2:-}" "${3:-}")
    return 1
}

# Exact-instance TCP RTT fallback for hosts that block ICMP. Loss is left
# unknown in that case rather than incorrectly showing 100%.
mt_unit_tcp_rtt() {
    local unit="$1" target="$2" pid line rtt hit=0
    pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null | tr -dc '0-9')
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS= read -r line; do
        if [[ "$line" == *"pid=$pid,"* || "$line" == *"pid=$pid)"* ]]; then
            if [[ "$line" == *"$target"* ]]; then
                if [[ "$line" =~ rtt:([0-9.]+) ]]; then rtt="${BASH_REMATCH[1]}"; break; fi
                hit=1; continue
            fi
            hit=0
        elif [ "$hit" = 1 ]; then
            if [[ "$line" =~ rtt:([0-9.]+) ]]; then rtt="${BASH_REMATCH[1]}"; break; fi
            [[ "$line" =~ ^[[:space:]] ]] || hit=0
        fi
    done < <(ss -Htinp 2>/dev/null)
    [ -n "$rtt" ] || return 1
    awk -v v="$rtt" 'BEGIN {printf "%.0fms*", v}'
}

mt_fmt_age_ms() {  # 183000 -> 3m
    local ms="$1" s
    [[ "$ms" =~ ^[0-9]+$ ]] || { printf -- '---'; return; }
    s=$((ms/1000))
    if [ "$s" -lt 60 ]; then printf '%ss' "$s"
    elif [ "$s" -lt 3600 ]; then printf '%sm' "$((s/60))"
    else printf '%sh' "$((s/3600))"; fi
}

# mt_unit_link_reason <unit> <server 0|1> [local_port] [expected_peer_ip] [max_idle_ms]
# Why is the link NOT live?  "" = it is live.  "STALE 3m" = socket exists but silent for 3 minutes,
# "NO CLIENT" (server) / "NO LINK" (client) = no established socket at all.
mt_unit_link_reason() {
    local unit="$1" server="$2" lport="${3:-}" expected="${4:-}" max_idle="${5:-$(mt_unit_max_idle "$1")}" host lr best='' any=0
    while IFS='|' read -r host lr; do
        any=1
        [[ "$lr" =~ ^[0-9]+$ ]] || lr=0
        if [ -z "$best" ] || [ "$lr" -lt "$best" ]; then best="$lr"; fi
    done < <(_mt_unit_sockets "$unit" "$lport" "$expected")
    if [ "$any" = 1 ]; then
        [ "$best" -gt "$max_idle" ] && printf 'STALE %s' "$(mt_fmt_age_ms "$best")"
        return 0
    fi
    [ "$server" = 1 ] && printf 'NO CLIENT' || printf 'NO LINK'
}

# mt_unit_journal_hint <unit>  ->  "LABEL (last matching log line)" for the usual failure causes.
mt_unit_journal_hint() {
    local unit="$1" log entry label pat line
    log=$(journalctl -u "$unit" --since "-15 min" -n 60 --no-pager -o cat 2>/dev/null | tr -d '\r')
    [ -n "$log" ] || return 1
    local -a rules=(
        'BAD TOKEN@@invalid token|bad token|token mismatch|wrong token|authentication (fail|error)|auth(entication)? fail|unauthorized|invalid secret|handshake.*(fail|denied|reject)|forbidden'
        'PORT IN USE@@address already in use|eaddrinuse|failed to bind|bind:.*in use|only one usage'
        'CONN REFUSED@@connection refused'
        'NO ROUTE@@no route to host|network is unreachable'
        'TIMEOUT@@timed out|i/o timeout|deadline exceeded'
        'TLS ERROR@@x509|certificate|tls:'
        'DNS ERROR@@no such host|name resolution|lookup .*(fail|error)'
    )
    for entry in "${rules[@]}"; do
        label="${entry%%@@*}"; pat="${entry#*@@}"
        line=$(grep -iE -- "$pat" <<< "$log" | tail -n 1)
        [ -n "$line" ] || continue
        line=$(sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g; s/^[0-9T:.+ Z-]{10,} *//' <<< "$line")
        printf '%s (%s)' "$label" "${line:0:70}"; return 0
    done
    return 1
}

# mt_link_why <unit> <server 0|1> [local_port] [expected_peer] [skip_socket 0|1]
# Combined human-readable reason shown next to WAITING / CONNECTING / OFFLINE.
mt_link_why() {
    local unit="$1" server="$2" lport="${3:-}" expected="${4:-}" skip="${5:-0}" live='' hint='' out=''
    if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
        hint=$(mt_unit_journal_hint "$unit" 2>/dev/null || true)
        printf 'SERVICE STOPPED%s' "${hint:+ · $hint}"; return 0
    fi
    [ "$skip" = 1 ] || live=$(mt_unit_link_reason "$unit" "$server" "$lport" "$expected" 2>/dev/null || true)
    hint=$(mt_unit_journal_hint "$unit" 2>/dev/null || true)
    out="${live}${hint:+${live:+ · }$hint}"
    printf '%s' "$out"
}

# Detail-card row (122 columns, same frame as the other rows). No output when empty.
mt_reason_row() {
    local why="${1:0:100}" l pad sp
    [ -n "$why" ] || return 0
    l="Reason       : ${why}"
    pad=$(( 122 - ${#l} )); [ "$pad" -lt 0 ] && pad=0
    printf -v sp '%*s' "$pad" ''
    echo -e "  ${B}│${NC} ${R}Reason       :${NC} ${Y}${why}${NC}${sp} ${B}│${NC}"
}
