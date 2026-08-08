#!/bin/bash
# --- MTunnel Installer | Core Modules + Offline-First Cache ---
# Initial core: mgre, mporter, mxlan, mrathole, mweb, mstat
# Web UI defaults are intentionally preserved.

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'
C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
LOCAL_DIR="/root/mtunnel"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"

# The initial install intentionally fetches only these core modules.
CORE_MODULES=("main.sh" "mgre.sh" "mporter.sh" "mxlan.sh" "mrathole.sh" "mweb.sh" "mstats.sh")

MODE="auto"
case "${1:-}" in
    --offline) MODE="offline" ;;
    --online) MODE="online" ;;
    --help|-h)
        echo "Usage: $0 [--offline|--online]"
        exit 0
        ;;
esac

mkdir -p "$LOCAL_DIR" "$LOCAL_DIR/packages" 2>/dev/null || exit 1

hide_cursor() { tput civis 2>/dev/null || true; }
show_cursor() { tput cnorm 2>/dev/null || true; }

cleanup() { show_cursor; }
trap cleanup EXIT INT TERM

clear 2>/dev/null || true
echo ""
echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MTunnel${NC} ${DIM}• MDesign Master Core Installer${NC} ${C}• Offline-First${NC}           ${B}│${NC}"
echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────┤${NC}"
echo -e "  ${B}│${NC} ${DIM}Core:${NC} ${G}mgre${NC} ${DIM}•${NC} ${G}mporter${NC} ${DIM}•${NC} ${G}mxlan${NC} ${DIM}•${NC} ${G}mrathole${NC} ${DIM}•${NC} ${G}mweb${NC} ${DIM}•${NC} ${G}mstat${NC} ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
echo ""
echo -e "  ${DIM}Source mode:${NC} ${W}${MODE}${NC}"
echo ""

module_name() {
    case "$1" in
        main.sh) echo "mtunnel" ;;
        mstats.sh) echo "mstats" ;;
        *) echo "${1%.sh}" ;;
    esac
}

deploy_module() {
    local src="$1" file="$2" mod
    mod="$(module_name "$file")"
    cp -f "$src" "$LOCAL_DIR/$file" || return 1
    sed -i 's/\r$//' "$LOCAL_DIR/$file" 2>/dev/null || true
    cat "$LOCAL_DIR/$file" > "/usr/bin/$mod" || return 1
    chmod +x "/usr/bin/$mod" || return 1

    if [ "$file" = "mstats.sh" ]; then
        cp -f "$LOCAL_DIR/mstats.sh" "/usr/bin/mstat" || return 1
        chmod +x "/usr/bin/mstat" || return 1
    fi
    return 0
}

find_local() {
    local file="$1"
    [ -s "$SCRIPT_DIR/$file" ] && { echo "$SCRIPT_DIR/$file"; return 0; }
    [ -s "$LOCAL_DIR/$file" ] && { echo "$LOCAL_DIR/$file"; return 0; }
    return 1
}

draw_linear() {
    local current="$1" total="$2" text="$3" width=44
    local pct=$(( current * 100 / total ))
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local left rest
    left="$(printf "%${filled}s" "" | tr ' ' '-')"
    rest="$(printf "%${empty}s" "" | tr ' ' '-')"
    printf "\r  ${C}→${NC} ${W}%-25s${NC} ${G}%s${DIM}%s${NC} ${C}%3d%%${NC}" \
        "$text" "$left" "$rest" "$pct"
}

draw_download() {
    local pid="$1" text="$2" width=44 pct=0
    local left rest
    hide_cursor
    while kill -0 "$pid" 2>/dev/null; do
        pct=$((pct + 2))
        [ "$pct" -gt 95 ] && pct=95
        local filled=$(( pct * width / 100 ))
        local empty=$(( width - filled ))
        left="$(printf "%${filled}s" "" | tr ' ' '-')"
        rest="$(printf "%${empty}s" "" | tr ' ' '-')"
        printf "\r  ${C}→${NC} ${W}%-25s${NC} ${G}%s${DIM}%s${NC} ${C}%3d%%${NC}" \
            "$text" "$left" "$rest" "$pct"
        sleep 0.12
    done
    left="$(printf "%${width}s" "" | tr ' ' '-')"
    printf "\r  ${G}✓${NC} ${W}%-25s${NC} ${G}%s${NC} ${G}100%%${NC}\n" "$text" "$left"
}

download_module() {
    local file="$1" tmp="/tmp/mtunnel_${file}_$$"
    rm -f "$tmp"
    if command -v curl >/dev/null 2>&1; then
        (curl -fLsS --retry 2 --connect-timeout 8 --max-time 120 \
            -o "$tmp" "${REPO_SCRIPTS}/${file}?v=$(date +%s)") >/dev/null 2>&1 &
    elif command -v wget >/dev/null 2>&1; then
        (wget --timeout=8 --tries=2 -qO "$tmp" \
            "${REPO_SCRIPTS}/${file}?v=$(date +%s)") >/dev/null 2>&1 &
    else
        echo -e "  ${R}✗ Neither curl nor wget is available.${NC}"
        return 1
    fi
    local pid=$!
    draw_download "$pid" "Downloading ${file%.sh}"
    wait "$pid"
    local rc=$?
    if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
        deploy_module "$tmp" "$file"
        rc=$?
    else
        rc=1
    fi
    rm -f "$tmp"
    return "$rc"
}

done_count=0
failed=()
total="${#CORE_MODULES[@]}"

echo -e "  ${W}Core module deployment${NC}"
echo ""

for file in "${CORE_MODULES[@]}"; do
    name="${file%.sh}"
    [ "$file" = "main.sh" ] && name="mtunnel"
    [ "$file" = "mstats.sh" ] && name="mstat"

    local_src=""
    if [ "$MODE" != "online" ]; then
        local_src="$(find_local "$file" || true)"
    fi

    if [ -n "$local_src" ]; then
        echo -e "  ${DIM}Local cache →${NC} ${W}${name}${NC}"
        if deploy_module "$local_src" "$file"; then
            echo -e "  ${G}✓${NC} ${DIM}Using local ${name}${NC}"
        else
            echo -e "  ${R}✗${NC} ${name} local deployment failed"
            failed+=("$name")
        fi
    elif [ "$MODE" = "offline" ]; then
        echo -e "  ${R}✗${NC} ${name} is not available locally"
        failed+=("$name")
    else
        if ! download_module "$file"; then
            # Last chance: an old cache may exist.
            if [ -s "$LOCAL_DIR/$file" ] && deploy_module "$LOCAL_DIR/$file" "$file"; then
                echo -e "  ${Y}↳${NC} ${DIM}GitHub unavailable; cached ${name} used${NC}"
            else
                echo -e "  ${R}✗${NC} Failed to download ${name}"
                failed+=("$name")
            fi
        fi
    fi

    done_count=$((done_count + 1))
    draw_linear "$done_count" "$total" "Overall installation"
    echo
done

echo ""
if [ "${#failed[@]}" -gt 0 ]; then
    echo -e "  ${R}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${R}│${NC} ${W}Installation incomplete${NC}                                             ${R}│${NC}"
    echo -e "  ${R}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
    echo -e "  ${R}Failed:${NC} ${failed[*]}"
    echo ""
    exit 1
fi

echo -e "  ${G}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${G}│${NC} ${W}✓ MTunnel installation completed${NC}                                    ${G}│${NC}"
echo -e "  ${G}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
echo ""
echo -e "  ${DIM}Local cache:${NC} ${W}${LOCAL_DIR}${NC}"
echo -e "  ${DIM}Additional modules will be fetched only when requested.${NC}"
echo ""

if [ -x "/usr/bin/mtunnel" ]; then
    exec /usr/bin/mtunnel
else
    echo -e "  ${R}mtunnel was not deployed correctly.${NC}"
    exit 1
fi
