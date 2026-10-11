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

installer_main() {
    local source_dir='' root='' with_cores=0 launch=1 remote='' work path name target cur next item
    local script_file="${BASH_SOURCE[0]}" script_dir
    script_dir=$(cd -- "$(dirname -- "$script_file")" && pwd) || return 1
    local -a modules=(main:main.sh mporter:mporter.sh mgre:tunnels/mgre.sh mxlan:tunnels/mxlan.sh mrathole:tunnels/mrathole.sh mbackhaul:tunnels/mbackhaul.sh mpaqet:tunnels/mpaqet.sh mweb:tools/mweb.sh mstats:tools/mstats.sh mhealer:tools/mhealer.sh minterface:tools/minterface.sh mbbr:tools/mbbr.sh mdiag:tools/mdiag.sh mshield:tools/mshield.sh linktest:tools/linktest.sh)
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
                echo 'Usage: sudo bash install.sh [--local DIR] [--remote HTTPS_BASE | --online] [--allow-downgrade] [--no-launch]'
                echo 'Without options: use adjacent scripts, or download from the official GitHub source.'
                echo '  --online             Force online install from the official GitHub source.'
                echo '  --allow-downgrade    Permit installing an older module over a newer installed one.'
                echo '  --remote URL         Use a custom HTTPS repository base instead of the official source.'
                echo '  --with-cores         Also install bundled binary cores when available.'
                echo '  --root DIR           Test-install under DIR without touching the live root.'
                echo ''
                echo 'Local downgrade example:'
                echo '  sudo MT_ALLOW_DOWNGRADE=1 bash install.sh'
                echo 'Online one-line example:'
                echo '  curl -fsSL https://raw.githubusercontent.com/htzserv/MTunnel/main/install.sh | sudo bash -s -- --online --allow-downgrade'
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
        if [ -f "$script_dir/main.sh" ]; then source_dir="$script_dir"
        elif [ -f "$PWD/main.sh" ]; then source_dir="$PWD"
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
        mkdir "$work/scripts" || return 1
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
        source_dir="$work/scripts"
    fi
        [ -n "$source_dir" ] && [ -d "$source_dir" ] || { echo 'Script directory does not exist.' >&2; return 1; }
    if [ -n "$remote" ]; then
        active_modules=("${modules[@]}")
    else
        for item in "${modules[@]}"; do
            path="${item#*:}"
            mt_validate_script "$source_dir/$path" && active_modules+=("$item")
        done
        [ "${#active_modules[@]}" -gt 0 ] || { echo 'No valid MTunnel scripts were found in the local source.' >&2; return 1; }
    fi
    for item in "${active_modules[@]}"; do
        name="${item%%:*}"; path="${item#*:}"; target="$root/usr/bin/$name"
        [ "$name" != main ] || target="$root/usr/bin/mtunnel"
        mt_validate_script "$source_dir/$path" || { echo "Missing or invalid module: $path. Installed scripts preserved." >&2; return 1; }
        if mt_validate_script "$target" 2>/dev/null; then
            cur=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$target")
            next=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$source_dir/$path")
            mt_downgrade_blocked "$cur" "$next" && { echo "Refusing downgrade of $name." >&2; return 1; }
        fi
        files+=("$source_dir/$path" "$target" "$source_dir/$path" "$root/root/mtunnel/$path")
        if [ -z "$remote" ]; then
            current=$((current+1))
            mod_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$source_dir/$path")
            draw_progress "$current" "${#active_modules[@]}" "$name" "$mod_ver"
            echo ''
        fi
    done
    if [ -f "$source_dir/install.sh" ]; then
        mt_validate_script "$source_dir/install.sh" || return 1
        files+=("$source_dir/install.sh" "$root/root/mtunnel/install.sh")
    fi
    if [ "$with_cores" == 1 ]; then
        for name in bh rathole paqet gost haproxy; do
            path="packages/$name"
            mt_valid_elf "$source_dir/$path" || { echo "Missing or incompatible optional core: $name. Omit --with-cores to install scripts only." >&2; return 1; }
            files+=("$source_dir/$path" "$root/usr/local/bin/$name" "$source_dir/$path" "$root/usr/bin/$name" "$source_dir/$path" "$root/root/mtunnel/$path")
        done
    fi
    mt_install_files 755 "${files[@]}" || { echo 'Install failed; committed files were rolled back.' >&2; return 1; }
    if [ "$launch" == 1 ]; then
        echo -e "\n  ${G}● MTunnel Installation Complete! Launching Core Dashboard...${NC}\n"
    else echo -e "\n  ${G}● MTunnel Installation Complete!${NC}\n"; fi
    if [ "$with_cores" == 1 ] && [ -z "$root" ]; then
        while read -r target; do
            [ -z "$target" ] || systemctl restart "$target" || return 1
        done < <(systemctl list-units --type=service --state=active --no-legend --plain 'mrathole@*.service' 'mbackhaul@*.service' 'mpaqet@*.service' 'gost.service' 'haproxy.service' 2>/dev/null | awk '{print $1}')
    fi
    if [ "$launch" == 1 ]; then sleep 1.5; exec "$root/usr/bin/mtunnel"; fi
}
installer_main "$@"
