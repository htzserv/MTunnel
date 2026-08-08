#!/bin/bash
set -u

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
LOCAL_DIR="/root/mtunnel"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"
MANIFEST="$LOCAL_DIR/.module-manifest"

BOOTSTRAP_MODULES=("main.sh" "mgre.sh" "mporter.sh" "mxlan.sh" "mrathole.sh" "mweb.sh" "mstats.sh")

MODE="auto"
case "${1:-}" in
    --force)   MODE="force" ;;
    --cache|--update) MODE="cache" ;;
    --offline) MODE="offline" ;;
    --online) MODE="cache" ;;
    -h|--help)
        cat <<USAGE
Usage: $0 [MODE]

Modes:
  --force     Force-download all core modules and replace local/installed copies.
  --cache     Smart cache/update: use local files when unchanged, update changed/missing files.
  --offline   Local-only deployment. Never contacts GitHub.
  --online    Alias for --cache.
  (no arg)    Auto mode: use bundled/local files first, otherwise download missing core modules.
USAGE
        exit 0
        ;;
esac

mkdir -p "$LOCAL_DIR" "$LOCAL_DIR/packages" || { echo -e "${R}Cannot create $LOCAL_DIR${NC}"; exit 1; }
# Keep the installer itself in the local cache so updates/force/offline can be launched without GitHub.
if [ -f "$SCRIPT_DIR/install.sh" ]; then cp -f "$SCRIPT_DIR/install.sh" "$LOCAL_DIR/install.sh" 2>/dev/null || true; fi
chmod 0755 "$LOCAL_DIR/install.sh" 2>/dev/null || true
touch "$MANIFEST" 2>/dev/null || true

log_ok(){ echo -e "  ${G}✓${NC} $*"; }
log_info(){ echo -e "  ${C}→${NC} $*"; }
log_warn(){ echo -e "  ${Y}!${NC} $*"; }
log_fail(){ echo -e "  ${R}✗${NC} $*"; }

sha256_file(){
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" | awk '{print $1}';
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$f" | awk '{print $1}';
    else return 1; fi
}

manifest_get(){ awk -v f="$1" '$1==f {print $2; exit}' "$MANIFEST" 2>/dev/null; }
manifest_set(){
    local f="$1" h="$2" tmp="$MANIFEST.$$"
    awk -v f="$f" '$1!=f {print}' "$MANIFEST" 2>/dev/null > "$tmp" || :
    printf '%s %s\n' "$f" "$h" >> "$tmp"
    mv -f "$tmp" "$MANIFEST"
}

progress(){
    local n="${1:-0}" total="${2:-0}" label="${3:-}" width=36 pct=0 filled empty done rest
    if [ "$total" -gt 0 ] 2>/dev/null; then pct=$((n*100/total)); else pct=100; fi
    [ "$pct" -gt 100 ] && pct=100
    filled=$((pct*width/100)); empty=$((width-filled))
    done="$(printf '%*s' "$filled" '' | tr ' ' '-')"
    rest="$(printf '%*s' "$empty" '' | tr ' ' '-')"
    printf '  %b%-22s%b %b%s%b%s %3d%%\n' "$C" "$label" "$NC" "$G" "$done" "$NC" "$rest" "$pct"
}

find_local(){
    local f="$1"
    if [ -s "$SCRIPT_DIR/$f" ]; then echo "$SCRIPT_DIR/$f"; return 0; fi
    if [ -s "$LOCAL_DIR/$f" ]; then echo "$LOCAL_DIR/$f"; return 0; fi
    return 1
}

same_file(){
    local a="$1" b="$2"
    [ -f "$a" ] && [ -f "$b" ] && [ "$(readlink -f "$a" 2>/dev/null)" = "$(readlink -f "$b" 2>/dev/null)" ]
}

deploy(){
    local f="$1" src="$2" name="${f%.sh}"
    [ "$name" = "main" ] && name="mtunnel"
    [ -s "$src" ] || return 1
    mkdir -p "$LOCAL_DIR"

    if ! same_file "$src" "$LOCAL_DIR/$f"; then
        cp -f "$src" "$LOCAL_DIR/$f" || return 1
    fi
    sed -i 's/\r$//' "$LOCAL_DIR/$f" 2>/dev/null || true
    chmod 0755 "$LOCAL_DIR/$f" 2>/dev/null || true

    if ! same_file "$LOCAL_DIR/$f" "/usr/bin/$name"; then
        install -m 0755 "$LOCAL_DIR/$f" "/usr/bin/$name" || return 1
    else
        chmod 0755 "/usr/bin/$name" 2>/dev/null || true
    fi

    if [ "$name" = "mtunnel" ]; then
        if ! same_file "$LOCAL_DIR/$f" "/usr/local/bin/mtunnel"; then
            install -m 0755 "$LOCAL_DIR/$f" /usr/local/bin/mtunnel 2>/dev/null || true
        fi
    fi

    if [ "$f" = "mstats.sh" ]; then
        install -m 0755 "$LOCAL_DIR/$f" /usr/bin/mstats 2>/dev/null || true
        ln -sfn /usr/bin/mstats /usr/bin/mstat 2>/dev/null || true
    fi
}

download_to_temp(){
    local f="$1" tmp="$2" url="$REPO_SCRIPTS/$f"
    rm -f "$tmp"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 8 --max-time 120 -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=8 --tries=2 -O "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    else
        log_fail "Neither curl nor wget is available."
        return 1
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    sed -i 's/\r$//' "$tmp" 2>/dev/null || true
    chmod 0755 "$tmp" 2>/dev/null || true
}

fetch_and_cache(){
    local f="$1" tmp="$LOCAL_DIR/.${f}.$$" h
    download_to_temp "$f" "$tmp" || return 1
    h="$(sha256_file "$tmp")" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$LOCAL_DIR/$f" || { rm -f "$tmp"; return 1; }
    manifest_set "$f" "$h"
    return 0
}

sync_module(){
    local f="$1" label="${f%.sh}" local_src="" local_hash remote_hash tmp="$LOCAL_DIR/.check-${f}.$$"
    [ "$f" = "mstats.sh" ] && label="mstat"

    case "$MODE" in
        force)
            log_info "$label: force download"
            if fetch_and_cache "$f"; then
                deploy "$f" "$LOCAL_DIR/$f" || return 1
                log_ok "$label updated"
                return 0
            fi
            log_fail "$label: GitHub download failed"
            return 1
            ;;
        offline)
            local_src="$(find_local "$f" || true)"
            if [ -n "$local_src" ]; then
                deploy "$f" "$local_src" || return 1
                log_ok "$label (local/offline)"
                return 0
            fi
            log_fail "$label: not available locally"
            return 1
            ;;
        cache|online)
            # Local project copy is a valid source. If it is different from cache, treat it as newer input.
            if [ -s "$SCRIPT_DIR/$f" ] && ! same_file "$SCRIPT_DIR/$f" "$LOCAL_DIR/$f"; then
                local_hash="$(sha256_file "$SCRIPT_DIR/$f" 2>/dev/null || true)"
                remote_hash="$(sha256_file "$LOCAL_DIR/$f" 2>/dev/null || true)"
                if [ -n "$local_hash" ] && [ "$local_hash" != "$remote_hash" ]; then
                    cp -f "$SCRIPT_DIR/$f" "$LOCAL_DIR/$f" || return 1
                    manifest_set "$f" "$local_hash"
                    deploy "$f" "$LOCAL_DIR/$f" || return 1
                    log_ok "$label updated from local bundle"
                    return 0
                fi
            fi

            # Missing cache: download and cache it.
            if [ ! -s "$LOCAL_DIR/$f" ]; then
                log_info "$label: missing, downloading"
                fetch_and_cache "$f" || return 1
                deploy "$f" "$LOCAL_DIR/$f" || return 1
                log_ok "$label downloaded"
                return 0
            fi

            # Cache exists: fetch a temporary copy and compare content hash.
            log_info "$label: checking GitHub version"
            if download_to_temp "$f" "$tmp"; then
                local_hash="$(sha256_file "$LOCAL_DIR/$f" 2>/dev/null || true)"
                remote_hash="$(sha256_file "$tmp" 2>/dev/null || true)"
                if [ -n "$remote_hash" ] && [ "$local_hash" = "$remote_hash" ]; then
                    rm -f "$tmp"
                    manifest_set "$f" "$local_hash"
                    deploy "$f" "$LOCAL_DIR/$f" || return 1
                    log_ok "$label up to date"
                else
                    mv -f "$tmp" "$LOCAL_DIR/$f" || { rm -f "$tmp"; return 1; }
                    manifest_set "$f" "$remote_hash"
                    deploy "$f" "$LOCAL_DIR/$f" || return 1
                    log_ok "$label updated"
                fi
                return 0
            fi

            # Offline fallback: keep the cached version if GitHub is unreachable.
            rm -f "$tmp"
            log_warn "$label: GitHub unavailable; keeping cached version"
            deploy "$f" "$LOCAL_DIR/$f" || return 1
            return 0
            ;;
        auto)
            local_src="$(find_local "$f" || true)"
            if [ -n "$local_src" ]; then
                deploy "$f" "$local_src" || return 1
                log_ok "$label (local)"
                return 0
            fi
            if [ -s "$LOCAL_DIR/$f" ]; then
                deploy "$f" "$LOCAL_DIR/$f" || return 1
                log_ok "$label (cache)"
                return 0
            fi
            log_info "$label: missing, downloading"
            fetch_and_cache "$f" || return 1
            deploy "$f" "$LOCAL_DIR/$f" || return 1
            log_ok "$label downloaded"
            return 0
            ;;
    esac
}

sync_installer_cache(){
    local tmp="$LOCAL_DIR/.install.sh.$$" h
    if [ "$MODE" = "offline" ]; then
        if [ -s "$SCRIPT_DIR/install.sh" ] && [ "$SCRIPT_DIR/install.sh" != "$LOCAL_DIR/install.sh" ]; then
            cp -f "$SCRIPT_DIR/install.sh" "$LOCAL_DIR/install.sh" 2>/dev/null || true
        fi
        return 0
    fi
    if [ "$MODE" = "auto" ]; then
        return 0
    fi
    if download_to_temp "install.sh" "$tmp"; then
        h="$(sha256_file "$tmp" 2>/dev/null || true)"
        if [ -n "$h" ]; then
            mv -f "$tmp" "$LOCAL_DIR/install.sh" || { rm -f "$tmp"; return 1; }
            chmod 0755 "$LOCAL_DIR/install.sh" 2>/dev/null || true
            manifest_set "install.sh" "$h"
            log_ok "installer cache synchronized"
            return 0
        fi
    fi
    rm -f "$tmp"
    if [ -s "$LOCAL_DIR/install.sh" ]; then
        log_warn "installer: GitHub unavailable; keeping cached installer"
        return 0
    fi
    return 1
}

clear 2>/dev/null || true
echo -e "\n  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MTunnel${NC} ${DIM}| Core Installer${NC}                              ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}\n"
echo -e "  ${DIM}Initial modules:${NC} ${W}mgre  mporter  mxlan  mrathole  mweb  mstat${NC}"
echo -e "  ${DIM}Mode:${NC} ${W}$MODE${NC}\n"

failed=()
if ! sync_installer_cache; then log_warn "installer cache could not be synchronized"; fi
for i in "${!BOOTSTRAP_MODULES[@]}"; do
    f="${BOOTSTRAP_MODULES[$i]}"
    sync_module "$f" || failed+=("${f%.sh}")
    progress "$((i+1))" "${#BOOTSTRAP_MODULES[@]}" "${f%.sh}"
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo -e "\n  ${R}Installation failed:${NC} ${failed[*]}"
    exit 1
fi

echo -e "\n  ${G}──────────────────────────────────── 100%${NC}"
echo -e "  ${G}✓ MTunnel core installed successfully.${NC}"
echo -e "  ${DIM}Smart update:${NC} ${W}bash install.sh --cache${NC}"
echo -e "  ${DIM}Force install:${NC} ${W}bash install.sh --force${NC}"
echo -e "  ${DIM}Offline deploy:${NC} ${W}bash install.sh --offline${NC}\n"
hash -r 2>/dev/null || true
if [ "${MTUNNEL_NO_EXEC:-0}" = "1" ]; then exit 0; fi
if [ -x /usr/bin/mtunnel ]; then
    if [ -t 0 ] && [ -e /dev/tty ]; then exec /usr/bin/mtunnel </dev/tty; else exec /usr/bin/mtunnel; fi
fi
