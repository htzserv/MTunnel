#!/usr/bin/env bash
# MTunnel shared core API 1 (v1.0.2; modular layout revision 2).
# Functions only: safe to source from installers, dashboards and all tunnel engines.
# Changes must be tested against every consuming module.
MTUNNEL_CORE_API=1
MTUNNEL_LAYOUT_REV=2
MTUNNEL_RELEASE_VERSION="1.0.3"
# CENTRAL SOURCE CONFIGURATION (root-managed, data-only; no eval or source).
# Override these defaults by copying config/sources.conf.example to
# /etc/mtunnel/sources.conf, or by exporting MTUNNEL_GITHUB_BASE and
# MTUNNEL_MIRROR_BASE before launching the script.
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
# Numeric sort alone sees 16.0.2 -> 1.0.3 as a downgrade, but for MTunnel this is
# an intentional forward migration. The inverse (1.x -> 15.x/16.x) remains blocked.
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
    [ "${MT_ALLOW_DOWNGRADE:-0}" != 1 ] && ! mt_release_migration "$1" "$2" && mt_is_newer_version "$1" "$2"
}
# True only when REMOTE ($1) is a real update for LOCAL ($2). A 1.x release is
# considered an update over retired 15.x/16.x even though its numeric major is lower.
mt_update_available() {
    if mt_release_migration "$2" "$1"; then return 0; fi
    mt_is_newer_version "$1" "$2" || return 1
    if [ "${MT_ALLOW_RETIRED:-0}" != 1 ] && mt_is_retired_version "$1" && ! mt_is_retired_version "$2"; then return 1; fi
    return 0
}
# Refuse a retired-line bundle over an installed 1.x installation.
# $1 = candidate bundle version, $2 = highest installed version (may be empty).
mt_retired_bundle_blocked() {
    [ "${MT_ALLOW_RETIRED:-0}" != 1 ] && [ -n "${2:-}" ] && mt_is_retired_version "$1" && ! mt_is_retired_version "$2"
}

# Require explicit operator approval for installing an older version. The caller
# must have validated the entire staged bundle before this prompt is shown.
# --allow-downgrade is an explicit non-interactive opt-in for CLI deployment.
# Installed version "unknown" (file present, version line unreadable) always asks.
# Return codes: 0 = proceed, 2 = operator cancelled, 1 = input error / EOF.
mt_confirm_downgrade() {
    local installed="${1:-}" downloaded="${2:-}" subject="${3:-MTunnel}" answer='' shown
    [ -n "$installed" ] || return 0
    # 15.x/16.x -> 1.x is the supported release-line migration, not a rollback.
    if [ "$installed" != unknown ] && mt_release_migration "$installed" "$downloaded"; then return 0; fi
    if [ "$installed" != unknown ] && ! mt_is_newer_version "$installed" "$downloaded"; then return 0; fi
    if [ "${MT_ALLOW_DOWNGRADE:-0}" = 1 ]; then return 0; fi
    shown="v$installed"; [ "$installed" != unknown ] || shown='unknown (version line unreadable)'
    printf '\n  ┌─[ DOWNGRADE CONFIRMATION: %s ]\n' "$subject" >&2
    printf '  ├─ Installed Version : %s\n' "$shown" >&2
    printf '  ├─ Downloaded Version: v%s\n' "$downloaded" >&2
    printf '  ├─ Only the selected component will be changed.\n' >&2
    printf '  └─ Downgrade to v%s? (y/N): ' "$downloaded" >&2
    IFS= read -r answer || return 1
    case "$answer" in y|Y|yes|YES|Yes) return 0;; *) printf '  Downgrade cancelled. Existing version preserved.\n' >&2; return 2;; esac
}
# Independent component updates/downgrades are supported. Compatibility is
# governed by the shared-core API/layout contract, not by matching release numbers.
mt_module_downgrade_allowed() {
    local installed="${1:-}" downloaded="${2:-}" approval="${installed}>${downloaded}"
    mt_release_migration "$installed" "$downloaded" && return 0
    if mt_is_newer_version "$installed" "$downloaded"; then
        # Some update paths validate once and mt_install_script validates again.
        # Cache only this exact pair so the operator never receives duplicate prompts.
        [ "${MTUNNEL_APPROVED_DOWNGRADE:-}" = "$approval" ] && return 0
        mt_confirm_downgrade "$installed" "$downloaded" 'Single Component' || return $?
        MTUNNEL_APPROVED_DOWNGRADE="$approval"
    fi
    return 0
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
    # Optional operator-pinned SHA256; remote manifest from the same untrusted
    # mirror is NOT a trust anchor. Pin a local root-owned digest file instead.
    if [ -z "$expected" ] && [ -n "${MTUNNEL_TRUSTED_SHA256_FILE:-}" ]; then
        local manifest="$MTUNNEL_TRUSTED_SHA256_FILE" basename key pinned
        [[ -f "$manifest" && ! -L "$manifest" ]] || { rm -f "$tmp"; return 1; }
        basename="${url%%\?*}"
        basename="${basename##*/}"
        [[ "$basename" =~ ^[A-Za-z0-9._-]+$ ]] || { rm -f "$tmp"; return 1; }
        # Pin names must be unique; mismatches or absent hashes fail closed.
        pinned=$(awk -v n="$basename" '$2==n {if(++c==1) h=$1} END{if(c==1) print h}' "$manifest")
        [[ "$pinned" =~ ^[a-fA-F0-9]{64}$ ]] || { rm -f "$tmp"; echo "Missing trusted digest for $basename" >&2; return 1; }
        expected="$pinned"
    fi
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
# Never claim preexisting system files. Hash guard preserves files modified by others.
mt_ownership_dir() { printf '%s' "${MTUNNEL_TEST_ROOT:-}/var/lib/mtunnel/owned-binaries"; }
mt_owned_binary_register() {
    local name="$1" target="$2" dir
    [[ "$name" =~ ^(bh|rathole|paqet)$ ]] || return 1
    [ -f "$target" ] || return 1
    dir=$(mt_ownership_dir); mkdir -p "$dir" || return 1
    sha256sum "$target" | awk '{print $1}' > "$dir/$name" || return 1
    chmod 600 "$dir/$name"
}
mt_owned_binary_remove() {
    local name="$1" target="$2" alias="${3:-}" dir saved actual
    [[ "$name" =~ ^(bh|rathole|paqet)$ ]] || return 1
    dir=$(mt_ownership_dir)
    [ -f "$dir/$name" ] || return 1
    saved=$(cat "$dir/$name")
    if [ -f "$target" ]; then
        actual=$(sha256sum "$target" | awk '{print $1}')
        [ "$actual" == "$saved" ] || { echo "Preserving modified binary: $target" >&2; return 1; }
    fi
    # Only remove a secondary /usr/bin copy when it matches our own binary hash.
    if [ -n "$alias" ] && [ -f "$alias" ]; then
        actual=$(sha256sum "$alias" | awk '{print $1}')
        if [ "$actual" == "$saved" ]; then rm -f -- "$alias" || return 1
        else echo "Preserving modified binary: $alias" >&2; fi
    fi
    [ ! -f "$target" ] || rm -f -- "$target" || return 1
    rm -f -- "$dir/$name"
}
# Keep the running executable until the candidate has been downloaded and checked.
mt_update_core() {
    local name="$1" unit_prefix="$2" source="$3" kind="${4:-url}" expected="${5:-}" work candidate item unit failed=0 had_old=0 register_owner=0
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
