```bash
#!/bin/bash

B='\033[1;34m'
G='\033[1;32m'
Y='\033[1;33m'
R='\033[1;31m'
C='\033[0;36m'
M='\033[1;35m'
W='\033[1;37m'
DIM='\033[2;37m'
NC='\033[0m'

REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
LOCAL_DIR="/root/mtunnel"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"

MODE="cache"

case "${1:-}" in
    --force)
        MODE="force"
        ;;
    --cache|--update|"")
        MODE="cache"
        ;;
    --offline)
        MODE="offline"
        ;;
    --online)
        MODE="cache"
        ;;
    -h|--help)
        echo
        echo "MTunnel Core Installer"
        echo
        echo "Usage:"
        echo "  bash install.sh              Smart Cache & Update"
        echo "  bash install.sh --cache      Smart Cache & Update"
        echo "  bash install.sh --update     Smart Cache & Update"
        echo "  bash install.sh --force      Force Download & Install"
        echo "  bash install.sh --offline    Offline Local Install"
        echo
        exit 0
        ;;
    *)
        echo -e "${R}Unknown option: $1${NC}"
        echo "Use: --cache, --force or --offline"
        exit 1
        ;;
esac

BOOTSTRAP_MODULES=(
    "main.sh"
    "mgre.sh"
    "mporter.sh"
    "mxlan.sh"
    "mrathole.sh"
    "mweb.sh"
    "mstats.sh"
)

mkdir -p "$LOCAL_DIR/packages" || {
    echo -e "${R}Cannot create $LOCAL_DIR${NC}"
    exit 1
}

same_file() {
    local a="$1"
    local b="$2"

    [ -e "$a" ] || return 1
    [ -e "$b" ] || return 1

    [ "$(readlink -f "$a" 2>/dev/null)" = "$(readlink -f "$b" 2>/dev/null)" ]
}

sha256_file() {
    local file="$1"

    [ -s "$file" ] || return 1

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        return 1
    fi
}

find_local() {
    local f="$1"

    if [ -s "$SCRIPT_DIR/$f" ]; then
        echo "$SCRIPT_DIR/$f"
        return 0
    fi

    if [ -s "$LOCAL_DIR/$f" ]; then
        echo "$LOCAL_DIR/$f"
        return 0
    fi

    return 1
}

progress() {
    local n="${1:-0}"
    local total="${2:-0}"
    local label="${3:-}"
    local width=36
    local pct=0

    if [ "$total" -gt 0 ] 2>/dev/null; then
        pct=$((n * 100 / total))
    else
        pct=100
    fi

    [ "$pct" -gt 100 ] && pct=100
    [ "$pct" -lt 0 ] && pct=0

    local filled=$((pct * width / 100))
    local empty=$((width - filled))

    local done rest
    done="$(printf '%*s' "$filled" '' | tr ' ' '#')"
    rest="$(printf '%*s' "$empty" '' | tr ' ' '-')"

    printf "  ${C}%-22s${NC} ${G}%s${DIM}%s${NC} ${W}%3d%%${NC}\n" \
        "$label" "$done" "$rest" "$pct"
}

download_to_cache() {
    local f="$1"
    local tmp="$LOCAL_DIR/.${f}.$$"

    rm -f "$tmp"

    if command -v curl >/dev/null 2>&1; then
        curl -fL \
            --retry 2 \
            --connect-timeout 8 \
            --max-time 120 \
            --progress-bar \
            -o "$tmp" \
            "$REPO_SCRIPTS/$f?v=$(date +%s)" || {
                rm -f "$tmp"
                return 1
            }
    elif command -v wget >/dev/null 2>&1; then
        wget \
            --timeout=8 \
            --tries=2 \
            -O "$tmp" \
            "$REPO_SCRIPTS/$f?v=$(date +%s)" || {
                rm -f "$tmp"
                return 1
            }
    else
        echo -e "  ${R}curl/wget not found${NC}"
        rm -f "$tmp"
        return 1
    fi

    [ -s "$tmp" ] || {
        rm -f "$tmp"
        return 1
    }

    sed -i 's/\r$//' "$tmp" 2>/dev/null || true
    chmod 0755 "$tmp" 2>/dev/null || true

    mv -f "$tmp" "$LOCAL_DIR/$f"
}

deploy() {
    local f="$1"
    local src="$2"
    local name="${f%.sh}"

    [ "$name" = "main" ] && name="mtunnel"

    if ! same_file "$src" "$LOCAL_DIR/$f"; then
        cp -f "$src" "$LOCAL_DIR/$f" || return 1
    fi

    sed -i 's/\r$//' "$LOCAL_DIR/$f" 2>/dev/null || true
    chmod 0755 "$LOCAL_DIR/$f" 2>/dev/null || true

    if ! same_file "$LOCAL_DIR/$f" "/usr/bin/$name"; then
        install -m0755 "$LOCAL_DIR/$f" "/usr/bin/$name" || return 1
    fi

    if [ "$name" = "mtunnel" ]; then
        if ! same_file "$LOCAL_DIR/$f" "/usr/local/bin/mtunnel"; then
            install -m0755 "$LOCAL_DIR/$f" /usr/local/bin/mtunnel 2>/dev/null || true
        fi
    fi

    if [ "$f" = "mstats.sh" ]; then
        if ! same_file "$LOCAL_DIR/$f" "/usr/bin/mstats"; then
            install -m0755 "$LOCAL_DIR/$f" /usr/bin/mstats 2>/dev/null || true
        fi

        ln -sfn /usr/bin/mstats /usr/bin/mstat
    fi

    return 0
}

clear 2>/dev/null || true

echo -e "\n  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MTunnel${NC} ${DIM}| Core Installer${NC}                              ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}\n"

echo -e "  ${DIM}Initial modules:${NC} ${W}mgre  mporter  mxlan  mrathole  mweb  mstat${NC}"

case "$MODE" in
    force)
        echo -e "  ${DIM}Mode:${NC} ${Y}FORCE INSTALL${NC}\n"
        ;;
    cache)
        echo -e "  ${DIM}Mode:${NC} ${G}CACHE & UPDATE${NC}\n"
        ;;
    offline)
        echo -e "  ${DIM}Mode:${NC} ${C}OFFLINE${NC}\n"
        ;;
esac

# If the whole project was copied to an offline server,
# preserve all bundled shell modules in the local cache.
if [ "$MODE" != "cache" ] &&
   [ -d "$SCRIPT_DIR" ] &&
   [ "$SCRIPT_DIR" != "$LOCAL_DIR" ]; then

    for bundled in "$SCRIPT_DIR"/*.sh; do
        [ -s "$bundled" ] || continue

        name="$(basename "$bundled")"

        if ! same_file "$bundled" "$LOCAL_DIR/$name"; then
            cp -f "$bundled" "$LOCAL_DIR/$name" 2>/dev/null || true
        fi

        chmod 0755 "$LOCAL_DIR/$name" 2>/dev/null || true
    done
fi

failed=()

total="${#BOOTSTRAP_MODULES[@]}"

for i in "${!BOOTSTRAP_MODULES[@]}"; do
    f="${BOOTSTRAP_MODULES[$i]}"
    label="${f%.sh}"

    [ "$f" = "mstats.sh" ] && label="mstat"

    src=""

    # ------------------------------------------------------------
    # FORCE
    # Always download a fresh copy when Internet is available.
    # ------------------------------------------------------------
    if [ "$MODE" = "force" ]; then

        echo -e "  ${C}→${NC} $label ${DIM}(forced GitHub download)${NC}"

        if download_to_cache "$f" &&
           deploy "$f" "$LOCAL_DIR/$f"; then
            :
        else
            echo -e "  ${R}✗${NC} $label ${R}(download/deploy failed)${NC}"
            failed+=("$label")
        fi

    # ------------------------------------------------------------
    # OFFLINE
    # Never access GitHub.
    # ------------------------------------------------------------
    elif [ "$MODE" = "offline" ]; then

        src="$(find_local "$f" || true)"

        if [ -n "$src" ]; then
            echo -e "  ${G}✓${NC} $label ${DIM}(local)${NC}"

            if ! deploy "$f" "$src"; then
                failed+=("$label")
            fi
        else
            echo -e "  ${R}✗${NC} $label ${R}(not available locally)${NC}"
            failed+=("$label")
        fi

    # ------------------------------------------------------------
    # CACHE & UPDATE
    # Use local version when present.
    # Download only if missing or changed.
    # ------------------------------------------------------------
    else

        local_file="$LOCAL_DIR/$f"
        bundled_file="$SCRIPT_DIR/$f"

        if [ -s "$bundled_file" ] && [ "$SCRIPT_DIR" != "$LOCAL_DIR" ]; then

            if [ ! -s "$local_file" ]; then
                echo -e "  ${G}✓${NC} $label ${DIM}(local bundle → cache)${NC}"

                cp -f "$bundled_file" "$local_file" || {
                    failed+=("$label")
                    progress "$((i + 1))" "$total" "$label"
                    continue
                }

                chmod 0755 "$local_file" 2>/dev/null || true

            else
                old_hash="$(sha256_file "$local_file" 2>/dev/null || true)"
                new_hash="$(sha256_file "$bundled_file" 2>/dev/null || true)"

                if [ -n "$old_hash" ] &&
                   [ -n "$new_hash" ] &&
                   [ "$old_hash" != "$new_hash" ]; then

                    echo -e "  ${Y}↻${NC} $label ${DIM}(local update)${NC}"
                    cp -f "$bundled_file" "$local_file" || {
                        failed+=("$label")
                        progress "$((i + 1))" "$total" "$label"
                        continue
                    }
                else
                    echo -e "  ${G}✓${NC} $label ${DIM}(cached)${NC}"
                fi
            fi

            src="$local_file"

        elif [ -s "$local_file" ]; then

            # Local cache exists. Compare it with GitHub.
            # A temporary download is used only for comparison.
            tmp="$LOCAL_DIR/.check_${f}.$$"

            echo -e "  ${C}→${NC} $label ${DIM}(checking version)${NC}"

            if command -v curl >/dev/null 2>&1; then
                if curl -fsL \
                    --retry 1 \
                    --connect-timeout 8 \
                    --max-time 60 \
                    -o "$tmp" \
                    "$REPO_SCRIPTS/$f?v=$(date +%s)" 2>/dev/null; then

                    remote_hash="$(sha256_file "$tmp" 2>/dev/null || true)"
                    local_hash="$(sha256_file "$local_file" 2>/dev/null || true)"

                    if [ -n "$remote_hash" ] &&
                       [ -n "$local_hash" ] &&
                       [ "$remote_hash" = "$local_hash" ]; then

                        echo -e "  ${G}✓${NC} $label ${DIM}(up to date)${NC}"
                        rm -f "$tmp"
                        src="$local_file"

                    else
                        echo -e "  ${Y}↻${NC} $label ${DIM}(updated version found)${NC}"

                        if [ -s "$tmp" ]; then
                            sed -i 's/\r$//' "$tmp" 2>/dev/null || true
                            chmod 0755 "$tmp" 2>/dev/null || true
                            mv -f "$tmp" "$local_file"
                            src="$local_file"
                        else
                            rm -f "$tmp"
                            src="$local_file"
                        fi
                    fi
                else
                    rm -f "$tmp"
                    echo -e "  ${Y}!${NC} $label ${DIM}(GitHub unavailable, using cache)${NC}"
                    src="$local_file"
                fi

            elif command -v wget >/dev/null 2>&1; then

                if wget \
                    --timeout=8 \
                    --tries=1 \
                    -q \
                    -O "$tmp" \
                    "$REPO_SCRIPTS/$f?v=$(date +%s)" 2>/dev/null; then

                    remote_hash="$(sha256_file "$tmp" 2>/dev/null || true)"
                    local_hash="$(sha256_file "$local_file" 2>/dev/null || true)"

                    if [ -n "$remote_hash" ] &&
                       [ -n "$local_hash" ] &&
                       [ "$remote_hash" = "$local_hash" ]; then

                        echo -e "  ${G}✓${NC} $label ${DIM}(up to date)${NC}"
                        rm -f "$tmp"
                        src="$local_file"

                    else
                        echo -e "  ${Y}↻${NC} $label ${DIM}(updated version found)${NC}"

                        if [ -s "$tmp" ]; then
                            sed -i 's/\r$//' "$tmp" 2>/dev/null || true
                            chmod 0755 "$tmp" 2>/dev/null || true
                            mv -f "$tmp" "$local_file"
                        fi

                        src="$local_file"
                    fi
                else
                    rm -f "$tmp"
                    echo -e "  ${Y}!${NC} $label ${DIM}(GitHub unavailable, using cache)${NC}"
                    src="$local_file"
                fi

            else
                echo -e "  ${Y}!${NC} $label ${DIM}(curl/wget unavailable, using cache)${NC}"
                src="$local_file"
            fi

        else

            echo -e "  ${C}→${NC} $label ${DIM}(missing → GitHub)${NC}"

            if download_to_cache "$f"; then
                src="$local_file"
            else
                echo -e "  ${R}✗${NC} $label ${R}(download failed)${NC}"
                failed+=("$label")
            fi
        fi

        if [ -n "$src" ]; then
            if ! deploy "$f" "$src"; then
                failed+=("$label")
            fi
        fi
    fi

    progress "$((i + 1))" "$total" "$label"
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo
    echo -e "  ${R}Installation failed:${NC} ${failed[*]}"
    exit 1
fi

echo
echo -e "  ${G}──────────────────────────────────── 100%${NC}"
echo -e "  ${G}✓ MTunnel core installed successfully.${NC}"
echo
echo -e "  ${DIM}Smart update:${NC} ${W}bash install.sh --cache${NC}"
echo -e "  ${DIM}Force install:${NC} ${W}bash install.sh --force${NC}"
echo -e "  ${DIM}Offline install:${NC} ${W}bash install.sh --offline${NC}"
echo

hash -r 2>/dev/null || true

if [ -x /usr/bin/mtunnel ]; then
    if [ -t 0 ]; then
        exec /usr/bin/mtunnel
    else
        exec /usr/bin/mtunnel </dev/tty
    fi
fi
```
