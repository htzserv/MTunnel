#!/bin/bash
# MTunnel standalone installer: use local scripts or bootstrap from GitHub.
MODULE_VERSION="1.2.6"
umask 077
DEFAULT_REMOTE="${MTUNNEL_REPO_URL:-${MTUNNEL_GITHUB_BASE:-https://raw.githubusercontent.com/htzserv/MTunnel/main}}"

# MTUNNEL_COMMON_LOADER -- installer bootstrap (also supports curl | bash --online).
# Installers cannot assume a shared core has been installed yet, so fetch it
# from the same selected source, or use a bundled local core when available.
mt_installer_load_common() {
    local script_dir='' source_dir='' remote='' mode='' arg candidate tmp rc
    local -a args=("$@")
    # When piped (curl | bash) BASH_SOURCE[0] is not a file: there is no "adjacent"
    # directory, and the current directory must never be trusted as a source.
    if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    fi
    for ((arg=0; arg<${#args[@]}; arg++)); do
        case "${args[$arg]}" in
            --local)
                ((arg+1 < ${#args[@]})) || return 1
                source_dir="${args[$((arg+1))]}"; mode=local; ((arg+=1));;
            --remote)
                ((arg+1 < ${#args[@]})) || return 1
                remote="${args[$((arg+1))]}"; mode=remote; ((arg+=1));;
            --online) remote="$DEFAULT_REMOTE"; mode=remote;;
        esac
    done
    if [[ "$mode" == local ]]; then
        candidate="${source_dir%/}/core/common.sh"
        [[ -f "$candidate" && -r "$candidate" ]] || { echo "Missing local shared core: $candidate" >&2; return 1; }
        # A newer installer must run its own matching helper API while staging
        # an older target bundle. The target core is separately validated.
        if [[ -n "$script_dir" && -f "$script_dir/core/common.sh" ]] &&
           grep -Fqx "MTUNNEL_RELEASE_VERSION=\"${MODULE_VERSION}\"" "$script_dir/core/common.sh"; then
            candidate="$script_dir/core/common.sh"
        fi
    elif [[ "$mode" == remote && -n "$script_dir" && -f "$script_dir/core/common.sh" ]] &&
         grep -Fqx "MTUNNEL_RELEASE_VERSION=\"${MODULE_VERSION}\"" "$script_dir/core/common.sh"; then
        candidate="$script_dir/core/common.sh"
    elif [[ "$mode" != remote && -n "$script_dir" && -f "$script_dir/core/common.sh" ]]; then
        candidate="$script_dir/core/common.sh"
    elif [[ "$mode" != remote && -n "$script_dir" && -f "$PWD/core/common.sh" ]]; then
        candidate="$PWD/core/common.sh"
    else
        # A curl/process-substitution bootstrap must not borrow an older installed
        # common.sh: installer helper functions may have changed within the same API.
        # Fetch the core from the same source as this installer instead.
        if [[ "$mode" != remote ]]; then remote="$DEFAULT_REMOTE"; fi
        [[ "$remote" == https://* ]] || { echo 'Shared core download requires HTTPS.' >&2; return 1; }
        tmp=$(mktemp "${TMPDIR:-/tmp}/mtunnel-core.XXXXXXXX") || return 1
        MT_INSTALLER_BOOTSTRAP_TEMP="$tmp"
        rc=1
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 --retry 2 -o "$tmp" "${remote%/}/core/common.sh" && rc=0
        elif command -v wget >/dev/null 2>&1; then
            wget -q --https-only --timeout=30 --tries=2 -O "$tmp" "${remote%/}/core/common.sh" && rc=0
        fi
        [[ "$rc" == 0 && -s "$tmp" ]] || { echo 'Unable to fetch the shared MTunnel core.' >&2; rm -f "$tmp"; return 1; }
        candidate="$tmp"
    fi
    if ! bash -n "$candidate" 2>/dev/null; then
        [[ -z "${MT_INSTALLER_BOOTSTRAP_TEMP:-}" ]] || rm -f "$MT_INSTALLER_BOOTSTRAP_TEMP"
        unset MT_INSTALLER_BOOTSTRAP_TEMP
        return 1
    fi
    # shellcheck source=core/common.sh
    if ! source "$candidate"; then
        [[ -z "${MT_INSTALLER_BOOTSTRAP_TEMP:-}" ]] || rm -f "$MT_INSTALLER_BOOTSTRAP_TEMP"
        unset MT_INSTALLER_BOOTSTRAP_TEMP
        return 1
    fi
    if [[ "${MTUNNEL_CORE_API:-}" != 1 || "${MTUNNEL_LAYOUT_REV:-}" != 2 ]]; then
        echo "Incompatible shared core: $candidate" >&2
        [[ -z "${MT_INSTALLER_BOOTSTRAP_TEMP:-}" ]] || rm -f "$MT_INSTALLER_BOOTSTRAP_TEMP"
        unset MT_INSTALLER_BOOTSTRAP_TEMP
        return 1
    fi
    [[ -z "${MT_INSTALLER_BOOTSTRAP_TEMP:-}" ]] || rm -f "$MT_INSTALLER_BOOTSTRAP_TEMP"
    unset MT_INSTALLER_BOOTSTRAP_TEMP
}
mt_installer_load_common "$@" || exit 1
unset -f mt_installer_load_common
DEFAULT_REMOTE="${MTUNNEL_REPO_URL:-$MTUNNEL_GITHUB_BASE}"


# Backward-compatible installer fallbacks. These make install.sh independently
# updatable: if it is pasted/replaced before common.sh, it still cannot fail with
# "command not found" for release-line/downgrade helpers.
if ! declare -F mt_is_retired_version >/dev/null; then
    mt_is_retired_version() { [[ "${1:-}" =~ ^(15|16)\.[0-9]+(\.[0-9]+)?$ ]]; }
fi
if ! declare -F mt_is_current_release_line >/dev/null; then
    mt_is_current_release_line() { [[ "${1:-}" =~ ^1\.[0-9]+(\.[0-9]+)?$ ]]; }
fi
if ! declare -F mt_release_migration >/dev/null; then
    mt_release_migration() { mt_is_retired_version "$1" && mt_is_current_release_line "$2"; }
fi
if ! declare -F mt_retired_bundle_blocked >/dev/null; then mt_retired_bundle_blocked() { return 1; }; fi
if ! declare -F mt_confirm_downgrade >/dev/null; then mt_confirm_downgrade() { return 0; }; fi


















B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

draw_progress() {
    local n=$1; local total=$2; local text=$3; local ver=$4; local width=26
    [ -z "$total" ] || [ "$total" -le 0 ] && total=1
    local percent=$(( n * 100 / total ))
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar=$(printf "%${filled}s" "" | tr ' ' '#')
    local empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')

    local ver_clean=""
    [ -n "$ver" ] && [ "$ver" != "Unknown" ] && ver_clean=" (v${ver})"

    local plain_label="${text}${ver_clean}"
    local pad_spaces=$(( 26 - ${#plain_label} ))
    [ "$pad_spaces" -lt 0 ] && pad_spaces=0
    local padding=$(printf '%*s' "$pad_spaces" "")

    tput civis 2>/dev/null || true
    if [ -n "$ver_clean" ]; then
        printf "\r  %b✔%b %b%s%b%b%s%b%s %b[%b%s%b%s%b] %b%3d%%%b" \
            "$G" "$NC" \
            "$W" "$text" "$NC" \
            "$Y" "$ver_clean" "$NC" \
            "$padding" \
            "$W" "$W" "$bar" "$DIM" "$empty_bar" "$NC" \
            "$W" "$percent" "$NC"
    else
        printf "\r  %b✔%b %b%s%b%s %b[%b%s%b%s%b] %b%3d%%%b" \
            "$G" "$NC" \
            "$W" "$text" "$NC" \
            "$padding" \
            "$W" "$W" "$bar" "$DIM" "$empty_bar" "$NC" \
            "$W" "$percent" "$NC"
    fi
    tput cnorm 2>/dev/null || true
}

draw_installer_header() {
    local title="MTunnel Core Modular Installer v${MODULE_VERSION}"
    local padding=$((59-${#title}))
    [ "$padding" -ge 0 ] || padding=0
    clear 2>/dev/null || true
    echo -e "\n  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
    printf "  %b│%b %b%s%b%*s%b│%b\n" "$B" "$NC" "$W" "$title" "$NC" "$padding" '' "$B" "$NC"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}\n"
}

mt_validate_shared_core() {
    local file="$1"
    [ -s "$file" ] && bash -n "$file" 2>/dev/null && grep -q '^MTUNNEL_CORE_API=1$' "$file" && grep -q '^MTUNNEL_LAYOUT_REV=2$' "$file" && grep -q '^MTUNNEL_RELEASE_VERSION="[0-9][0-9.]*"$' "$file"
}
# Retire components that were folded into core/common.sh (or removed on purpose).
# Nothing is deleted before a copy is stored under /root/mtunnel/backup, and any
# cron/systemd entry that still points at a retired tool is reported, not edited.
mt_installer_retire_legacy() {
    local f stamp backup_dir found=0 failed=0 refs=''
    local -a legacy=(/etc/mweb /etc/systemd/system/mweb.service /usr/bin/mweb /root/mtunnel/tools/mweb.sh
        /usr/bin/mbbr /usr/bin/mhealer /usr/bin/minterface
        /root/mtunnel/tools/mbbr.sh /root/mtunnel/tools/mhealer.sh /root/mtunnel/tools/minterface.sh)
    for f in "${legacy[@]}"; do
        if [ -e "$f" ] || [ -L "$f" ]; then found=1; break; fi
    done
    [ "$found" == 1 ] || return 0
    stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
    backup_dir="/root/mtunnel/backup/legacy-$stamp"
    mkdir -p "$backup_dir" && chmod 700 "$backup_dir" || {
        echo -e "  ${Y}● Cannot create $backup_dir; legacy files were left untouched.${NC}" >&2; return 0; }
    for f in "${legacy[@]}"; do
        if [ -e "$f" ] || [ -L "$f" ]; then cp -a --parents "$f" "$backup_dir" 2>/dev/null || failed=1; fi
    done
    if [ "$failed" == 1 ]; then
        echo -e "  ${Y}● Backup of legacy files failed; they were left untouched.${NC}" >&2; return 0
    fi
    systemctl disable --now mweb.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/mweb.service /usr/bin/mweb /root/mtunnel/tools/mweb.sh
    rm -rf /etc/mweb
    rm -f /usr/bin/mbbr /usr/bin/mhealer /usr/bin/minterface /root/mtunnel/tools/mbbr.sh /root/mtunnel/tools/mhealer.sh /root/mtunnel/tools/minterface.sh
    rmdir /root/mtunnel/tools 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo -e "  ${DIM}● Retired legacy mweb web panel and standalone mbbr/mhealer/minterface scripts (now part of the shared core).${NC}"
    echo -e "  ${DIM}  A copy was stored in ${backup_dir}.${NC}"
    refs=$(grep -rlE '/usr/bin/(mweb|mbbr|mhealer|minterface)\b' /etc/cron.d /etc/cron.daily /etc/cron.hourly /var/spool/cron /etc/systemd/system 2>/dev/null | head -n 5)
    if [ -n "$refs" ]; then
        echo -e "  ${Y}● These files still reference a retired tool; please review them:${NC}"
        while IFS= read -r f; do echo -e "    ${Y}-${NC} $f"; done <<< "$refs"
    fi
    return 0
}
installer_main() {
    local source_dir='' root='' with_cores=0 launch=1 remote='' work path name target item
    local script_file="${BASH_SOURCE[0]:-}" script_dir=''
    [[ ! -f "$script_file" ]] || script_dir=$(cd -- "$(dirname -- "$script_file")" && pwd) || return 1
    local -a modules=(main:main.sh mporter:mporter.sh linktest:linktest.sh mgre:tunnels/mgre.sh mxlan:tunnels/mxlan.sh mrathole:tunnels/mrathole.sh mbackhaul:tunnels/mbackhaul.sh mpaqet:tunnels/mpaqet.sh mdoctor:mdoctor.sh)
    local -a active_modules=()
    local -a files=()
    local current=0 mod_ver
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --local) [ "$#" -ge 2 ] || return 1; source_dir="$2"; remote=''; shift 2;;
            --root) [ "$#" -ge 2 ] || return 1; root="${2%/}"; launch=0; shift 2;;
            --with-cores) with_cores=1; shift;;
            --no-launch) launch=0; shift;;
            --remote) [ "$#" -ge 2 ] || return 1; remote="${2%/}"; source_dir=''; shift 2;;
            --online) remote="$DEFAULT_REMOTE"; source_dir=''; shift;;
            --allow-downgrade) export MT_ALLOW_DOWNGRADE=1; shift;;
            --help|-h)
                echo 'Usage: sudo bash install.sh [--local DIR] [--remote HTTPS_BASE | --online] [--no-launch]'
                echo 'Without options: use adjacent scripts, or download from the official GitHub source.'
                echo '  --online             Force online install from the official GitHub source.'
                echo '  --allow-downgrade    Compatibility alias; downgrades are always permitted.'
                echo '  --remote URL         Use a custom HTTPS repository base instead of the official source.'
                echo '  --with-cores         Also install bundled binary cores when available.'
                echo '  --root DIR           Test-install under DIR without touching the live root.'
                echo ''
                echo 'Version switching is unrestricted: upgrade or downgrade directly from any compatible bundle.'
                echo 'Local install example:'
                echo '  sudo bash install.sh --local .'
                echo 'Online one-line example:'
                echo "  curl -fsSL $MTUNNEL_GITHUB_BASE/install.sh | sudo bash -s -- --online"
                return 0;;
            *) echo "Unknown option: $1" >&2; return 1;;
        esac
    done
    if [ -n "$root" ]; then
        [[ "$root" == /* && "$root" != / ]] || return 1
        [[ ! "$root" =~ (^|/)\.\.(/|$) && ! "$root" =~ (^|/)\.(/|$) ]] || { echo 'Unsafe --root path.' >&2; return 1; }
        root=$(readlink -m -- "$root") || return 1
        [ "$root" != / ] || return 1
    elif [ "$EUID" != 0 ]; then echo 'Run the installer with sudo.' >&2; return 1; fi
    if [ -z "$source_dir" ] && [ -z "$remote" ]; then
        if [ -n "$script_dir" ] && [ -f "$script_dir/main.sh" ]; then source_dir="$script_dir"
        elif [ -n "$script_dir" ] && [ -f "$PWD/main.sh" ]; then source_dir="$PWD"
        else remote="$DEFAULT_REMOTE"; fi
    fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/mtunnel-install.XXXXXX") || return 1
    chmod 700 "$work"
    INSTALLER_WORK="$work"
    trap 'rm -rf -- "$INSTALLER_WORK"' EXIT
    draw_installer_header
    if [ -n "$remote" ]; then
        [[ "$remote" == https://* ]] || { echo 'Download requires HTTPS.' >&2; return 1; }
        remote="${remote%/}"
        mkdir "$work/scripts" "$work/scripts/core" || return 1
        if ! mt_download "$remote/core/common.sh" "$work/scripts/core/common.sh" || ! mt_validate_shared_core "$work/scripts/core/common.sh"; then
            echo 'Cannot prepare shared core; current installation preserved.' >&2; return 1
        fi
        for item in "${modules[@]}"; do
            path="${item#*:}"
            mkdir -p "$work/scripts/$(dirname "$path")" || return 1
            if ! mt_download "$remote/$path" "$work/scripts/$path" || ! mt_validate_script "$work/scripts/$path"; then
                echo "Cannot prepare module: $path. Installed scripts preserved." >&2; return 1
            fi
            current=$((current+1)); name="${item%%:*}"
            mod_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$work/scripts/$path")
            draw_progress "$current" "${#modules[@]}" "$name" "$mod_ver"
            echo ''
        done
        if ! mt_download "$remote/install.sh" "$work/scripts/install.sh" || ! mt_validate_script "$work/scripts/install.sh"; then
            echo 'Cannot prepare installer: install.sh. Installed scripts preserved.' >&2; return 1
        fi
        # The remote VERSION file is only an update marker and may lag behind the files.
        # Bundle consistency is enforced below by comparing the staged core, every module
        # and install.sh, so a stale VERSION marker must never block an install.
        source_dir="$work/scripts"
    fi
        [ -n "$source_dir" ] && [ -d "$source_dir" ] || { echo 'Script directory does not exist.' >&2; return 1; }
    mt_validate_shared_core "$source_dir/core/common.sh" || {
        echo 'Shared core is missing or invalid. Existing installation preserved.' >&2; return 1;
    }
    # Release numbers are informational and any compatible mix of module versions is
    # accepted. The only gate is the shared-core API/layout contract (validated above
    # and re-checked by every module at start-up).
    mt_validate_script "$source_dir/install.sh" || { echo 'Missing or invalid install.sh in complete bundle.' >&2; return 1; }
    head -n 5 "$source_dir/install.sh" | grep -Fq '# MTunnel standalone installer:' || { echo 'Incorrect install.sh in complete bundle.' >&2; return 1; }
    if [ -n "$remote" ]; then
        active_modules=("${modules[@]}")
    else
        # A partial package must not silently leave mixed module/core versions.
        for item in "${modules[@]}"; do
            path="${item#*:}"
            mt_validate_script "$source_dir/$path" || { echo "Missing module: $path. Existing installation preserved." >&2; return 1; }
            mt_validate_module_role "$source_dir/$path" "$path" || { echo "Wrong module role: $path. Existing installation preserved." >&2; return 1; }
            mt_validate_module_core_contract "$source_dir/$path" || { echo "Incompatible module/core contract: $path. Existing installation preserved." >&2; return 1; }
        done
        active_modules=("${modules[@]}")
    fi
    # Install the shared API before replacing any dependent module. All files
    # are staged and rolled back together by mt_install_files on copy failure.
    files+=("$source_dir/core/common.sh" "$root/usr/lib/mtunnel/common.sh"
            "$source_dir/core/common.sh" "$root/root/mtunnel/core/common.sh")
    for item in "${active_modules[@]}"; do
        name="${item%%:*}"; path="${item#*:}"; target="$root/usr/bin/$name"
        [ "$name" != main ] || target="$root/usr/bin/mtunnel"
        mt_validate_script "$source_dir/$path" || { echo "Missing or invalid module: $path. Installed scripts preserved." >&2; return 1; }
        mt_validate_module_role "$source_dir/$path" "$path" || { echo "Wrong module role: $path. Installed scripts preserved." >&2; return 1; }
        mt_validate_module_core_contract "$source_dir/$path" || { echo "Incompatible module/core contract: $path. Installed scripts preserved." >&2; return 1; }
        files+=("$source_dir/$path" "$target" "$source_dir/$path" "$root/root/mtunnel/$path")
        if [ -z "$remote" ]; then
            current=$((current+1))
            mod_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$source_dir/$path")
            draw_progress "$current" "${#active_modules[@]}" "$name" "$mod_ver"
            echo ''
        fi
    done
    files+=("$source_dir/install.sh" "$root/root/mtunnel/install.sh")
    if [ "$with_cores" == 1 ]; then
        for name in bh rathole paqet gost haproxy; do
            path="packages/$name"
            if [ -n "$remote" ]; then
                mkdir -p "$work/scripts/packages" || return 1
                mt_download "$remote/$path" "$work/scripts/$path" || { echo "Could not fetch $path" >&2; return 1; }
            fi
            mt_valid_elf "$source_dir/$path" || { echo "Missing or incompatible optional core: $name. Omit --with-cores to install scripts only." >&2; return 1; }
            files+=("$source_dir/$path" "$root/usr/local/bin/$name" "$source_dir/$path" "$root/usr/bin/$name" "$source_dir/$path" "$root/root/mtunnel/$path")
        done
    fi
    local -a owned_candidates=()
    if [ "$with_cores" == 1 ]; then
        for name in bh rathole paqet; do
            if [ -f "$root/var/lib/mtunnel/owned-binaries/$name" ] || \
               { [ ! -e "$root/usr/local/bin/$name" ] && [ ! -e "$root/usr/bin/$name" ]; }; then
                owned_candidates+=("$name")
            fi
        done
    fi
    mt_install_files 755 "${files[@]}" || { echo 'Install failed; committed files were rolled back.' >&2; return 1; }
    for name in "${owned_candidates[@]}"; do
        MTUNNEL_TEST_ROOT="$root" mt_owned_binary_register "$name" "$root/usr/local/bin/$name" || echo "Warning: Could not record $name ownership" >&2
    done
    if [ -z "$root" ]; then
        mt_installer_retire_legacy
    fi
    if [ "$launch" == 1 ]; then
        echo -e "\n  ${G}● MTunnel Installation Complete! Launching Core Dashboard...${NC}\n"
    else echo -e "\n  ${G}● MTunnel Installation Complete!${NC}\n"; fi
    if [ "$with_cores" == 1 ] && [ -z "$root" ]; then
        while read -r target; do
            [ -z "$target" ] || systemctl restart "$target" || return 1
        done < <(systemctl list-units --type=service --state=active --no-legend --plain 'mrathole@*.service' 'mbackhaul@*.service' 'mpaqet@*.service' 'gost.service' 'haproxy.service' 2>/dev/null | awk '{print $1}')
    fi
    if [ "$launch" == 1 ]; then
        sleep 1.5
        rm -rf -- "$INSTALLER_WORK"
        trap - EXIT
        exec "$root/usr/bin/mtunnel"
    fi
}
installer_main "$@"
