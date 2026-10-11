#!/bin/bash
# --- MTunnel Core Modular Installer v8.3.2 ---
# [Features: Pure GitHub | Fixed ANSI Alignment | MDesign Hierarchy]

MODULE_VERSION="8.3.2"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

LOCAL_DIR="/root/mtunnel"
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"

BOOTSTRAP_MODULES=(
    "main:main.sh"
    "mporter:mporter.sh"
    "mgre:tunnels/mgre.sh"
    "mxlan:tunnels/mxlan.sh"
    "mrathole:tunnels/mrathole.sh"
    "mbackhaul:tunnels/mbackhaul.sh"
    "mpaqet:tunnels/mpaqet.sh"
    "mweb:tools/mweb.sh"
    "mstats:tools/mstats.sh"
    "mhealer:tools/mhealer.sh"
    "minterface:tools/minterface.sh"
    "mbbr:tools/mbbr.sh"
    "mdiag:tools/mdiag.sh"
    "mshield:tools/mshield.sh"
    "linktest:tools/linktest.sh"
)

mkdir -p "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$LOCAL_DIR/tools" "$LOCAL_DIR/tmp" /etc/haproxy /var/lib/haproxy /usr/sbin /usr/local/bin 2>/dev/null
chmod 700 "$LOCAL_DIR/tmp" 2>/dev/null

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

clear
echo -e "\n  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MTunnel Core Modular Installer v${MODULE_VERSION}${NC}                      ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}\n"

total_mods=${#BOOTSTRAP_MODULES[@]}
current=0
cb="?t=$(date +%s)"

for item in "${BOOTSTRAP_MODULES[@]}"; do
    ((current++))
    mod_name="${item%%:*}"
    rel_path="${item##*:}"
    target_dest="$LOCAL_DIR/$rel_path"
    [ "$mod_name" == "main" ] && target_bin="/usr/bin/mtunnel" || target_bin="/usr/bin/$mod_name"

    mkdir -p "$(dirname "$target_dest")" 2>/dev/null

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 8 -o "$target_dest" "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --no-check-certificate --header="Cache-Control: no-cache" --timeout=8 -O "$target_dest" "$REPO_SCRIPTS/$rel_path$cb" 2>/dev/null
    fi

    if [ -s "$target_dest" ]; then
        sed -i 's/\r$//' "$target_dest" 2>/dev/null
        chmod +x "$target_dest"
        cp -f "$target_dest" "$target_bin" 2>/dev/null
        chmod +x "$target_bin" 2>/dev/null

        mod_ver=$(grep -m1 '^MODULE_VERSION=' "$target_dest" | cut -d'"' -f2)
        [ -z "$mod_ver" ] && mod_ver="Unknown"

        draw_progress "$current" "$total_mods" "$mod_name" "$mod_ver"
        echo ""
    else
        echo -e "\n  ${R}Installation failed: $mod_name ($rel_path)${NC}"
        exit 1
    fi
done

ln -sfn /usr/bin/mtunnel /usr/local/bin/mtunnel 2>/dev/null

echo -e "\n  ${G}● MTunnel Installation Complete! Launching Core Dashboard...${NC}\n"
sleep 1.5

if [ -x "/usr/bin/mtunnel" ]; then
    exec /usr/bin/mtunnel
fi
