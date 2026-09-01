#!/bin/bash
# --- MTunnel Core Modular Installer v8.1.0 ---
# [Structured Folder Hierarchy Edition for MDesign Ecosystem]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

LOCAL_DIR="/root/mtunnel"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
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

IS_FORCE=false
for arg in "$@"; do
    if [[ "$arg" == "--force" ]]; then
        IS_FORCE=true
        break
    fi
done

# ساخت ساختار کامل پوشه‌ها
mkdir -p "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$LOCAL_DIR/tools" /etc/haproxy /var/lib/haproxy /usr/sbin /usr/local/bin 2>/dev/null

draw_progress() {
    local n=$1; local total=$2; local text=$3; local width=25
    [ -z "$total" ] || [ "$total" -le 0 ] && total=1
    local percent=$(( n * 100 / total ))
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar=$(printf "%${filled}s" "" | tr ' ' '#')
    local empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')
    tput civis 2>/dev/null || true
    printf "\r  %b✔%b %b%-22s%b %b[%b%s%b%s%b] %b%3d%%%b" "$G" "$NC" "$W" "$text" "$NC" "$W" "$W" "$bar" "$DIM" "$empty_bar" "$NC" "$W" "$percent" "$NC"
    tput cnorm 2>/dev/null || true
}

clear
echo -e "\n  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MTunnel Core Modular Installer v8.1.0${NC}                      ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}\n"

PKG_DIR=""
[ -d "$SCRIPT_DIR/packages" ] && [ "$(ls -A "$SCRIPT_DIR/packages" 2>/dev/null)" ] && PKG_DIR="$SCRIPT_DIR/packages"
[ -z "$PKG_DIR" ] && [ -d "$LOCAL_DIR/packages" ] && [ "$(ls -A "$LOCAL_DIR/packages" 2>/dev/null)" ] && PKG_DIR="$LOCAL_DIR/packages"
[ -z "$PKG_DIR" ] && [ -d "./packages" ] && [ "$(ls -A "./packages" 2>/dev/null)" ] && PKG_DIR="./packages"

if [ -n "$PKG_DIR" ]; then
    if [ -s "$PKG_DIR/haproxy" ]; then
        cp -f "$PKG_DIR/haproxy" /usr/sbin/haproxy 2>/dev/null
        chmod +x /usr/sbin/haproxy 2>/dev/null
    fi

    for bin in rathole bh paqet gost frpc frps; do
        if [ -s "$PKG_DIR/$bin" ]; then
            cp -f "$PKG_DIR/$bin" /usr/local/bin/$bin 2>/dev/null
            chmod +x "/usr/local/bin/$bin" 2>/dev/null
        fi
    done

    if ls "$PKG_DIR"/*.deb >/dev/null 2>&1; then
        dpkg -i "$PKG_DIR"/*.deb >/dev/null 2>&1 || true
        apt-get --fix-broken install -y >/dev/null 2>&1 || true
    fi
fi

total_mods=${#BOOTSTRAP_MODULES[@]}
current=0

for item in "${BOOTSTRAP_MODULES[@]}"; do
    ((current++))
    mod_name="${item%%:*}"
    rel_path="${item##*:}"
    file_name="$(basename "$rel_path")"
    target_dest="$LOCAL_DIR/$rel_path"
    [ "$mod_name" == "main" ] && target_bin="/usr/bin/mtunnel" || target_bin="/usr/bin/$mod_name"

    # اطمینان از وجود پوشه مقصد در دایرکتوری لوکال
    mkdir -p "$(dirname "$target_dest")" 2>/dev/null

    local_source=""
    if [ "$IS_FORCE" = false ]; then
        if [ -s "$SCRIPT_DIR/$rel_path" ]; then local_source="$SCRIPT_DIR/$rel_path"
        elif [ -s "$SCRIPT_DIR/$file_name" ]; then local_source="$SCRIPT_DIR/$file_name"
        elif [ -s "$target_dest" ]; then local_source="$target_dest"
        elif [ -s "$LOCAL_DIR/$file_name" ]; then local_source="$LOCAL_DIR/$file_name"; fi
    fi

    if [ -n "$local_source" ]; then
        chmod +x "$local_source"
        if [ "$(readlink -f "$local_source" 2>/dev/null)" != "$(readlink -f "$target_dest" 2>/dev/null)" ]; then
            cp -f "$local_source" "$target_dest" 2>/dev/null
        fi
        cp -f "$target_dest" "$target_bin" 2>/dev/null
        chmod +x "$target_bin" "$target_dest" 2>/dev/null
        draw_progress "$current" "$total_mods" "$mod_name (local)"
        echo ""
        continue
    fi

    # در صورت عدم وجود لوکال، دانلود با حفظ ساختار دایرکتوری
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 8 -o "$target_dest" "$REPO_SCRIPTS/$rel_path" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=8 -O "$target_dest" "$REPO_SCRIPTS/$rel_path" 2>/dev/null
    fi

    if [ -s "$target_dest" ]; then
        sed -i 's/\r$//' "$target_dest" 2>/dev/null
        chmod +x "$target_dest"
        cp -f "$target_dest" "$target_bin" 2>/dev/null
        chmod +x "$target_bin" 2>/dev/null
        draw_progress "$current" "$total_mods" "$mod_name"
        echo ""
    else
        echo -e "\n  ${R}Installation failed: $mod_name ($rel_path)${NC}"
        exit 1
    fi
done

ln -sfn /usr/bin/mtunnel /usr/local/bin/mtunnel 2>/dev/null

echo -e "\n  ${G}● MTunnel Installation Complete! Starting Core Dashboard...${NC}\n"
sleep 1.5

if [ -x "/usr/bin/mtunnel" ]; then
    exec /usr/bin/mtunnel
fi
