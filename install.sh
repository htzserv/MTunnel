#!/bin/bash
# --- MTunnel Core Installer v7.5.2 (Fixed Division by Zero & Local Copy) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

LOCAL_DIR="/root/mtunnel"
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
BOOTSTRAP_MODULES=("main.sh" "mgre.sh" "mporter.sh" "mxlan.sh" "mrathole.sh" "mbbr.sh" "mweb.sh" "mstats.sh")

mkdir -p "$LOCAL_DIR"

draw_progress() {
    local n=$1
    local total=$2
    local text=$3
    local width=30
    
    # جلوگیری از خطای تقسیم بر صفر (Division by Zero Fix)
    if [ -z "$total" ] || [ "$total" -le 0 ]; then
        total=1
    fi

    local percent=$(( n * 100 / total ))
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar=$(printf "%${filled}s" "" | tr ' ' '#')
    local empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')

    printf "\r  %b→%b %-20s %b[%s%s]%b %3d%%" "$C" "$NC" "$text" "$G" "$bar" "$DIM" "$empty_bar" "$NC" "$percent"
}

echo -e "\n  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MTunnel Core Installer v7.5.2${NC}                              ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}\n"

total_mods=${#BOOTSTRAP_MODULES[@]}
current=0

for file in "${BOOTSTRAP_MODULES[@]}"; do
    ((current++))
    mod_name="${file%.sh}"
    [ "$mod_name" == "main" ] && target_bin="/usr/bin/mtunnel" || target_bin="/usr/bin/$mod_name"

    # چک کردن فایل محلی و جلوگیری از کپی فایل روی خودش
    if [ -s "$LOCAL_DIR/$file" ]; then
        chmod +x "$LOCAL_DIR/$file"
        if [ "$(readlink -f "$LOCAL_DIR/$file" 2>/dev/null)" != "$(readlink -f "$target_bin" 2>/dev/null)" ]; then
            cp -f "$LOCAL_DIR/$file" "$target_bin" 2>/dev/null
        fi
        chmod +x "$target_bin" 2>/dev/null
        draw_progress "$current" "$total_mods" "$mod_name (local)"
        echo ""
        continue
    fi

    # دانلود از گیت‌هاب در صورت عدم وجود فایل محلی
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 8 -o "$LOCAL_DIR/$file" "$REPO_SCRIPTS/$file" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=8 -O "$LOCAL_DIR/$file" "$REPO_SCRIPTS/$file" 2>/dev/null
    fi

    if [ -s "$LOCAL_DIR/$file" ]; then
        sed -i 's/\r$//' "$LOCAL_DIR/$file" 2>/dev/null
        chmod +x "$LOCAL_DIR/$file"
        cp -f "$LOCAL_DIR/$file" "$target_bin" 2>/dev/null
        chmod +x "$target_bin" 2>/dev/null
        draw_progress "$current" "$total_mods" "$mod_name"
        echo ""
    else
        echo -e "\n  ${R}Installation failed: $mod_name${NC}"
        exit 1
    fi
done

# لینک دادن mtunnel به مسیر اصلی اجرای سیستم
ln -sfn /usr/bin/mtunnel /usr/local/bin/mtunnel 2>/dev/null

echo -e "\n  ${G}● MTunnel Installation Complete! Run 'mtunnel' to start.${NC}\n"
