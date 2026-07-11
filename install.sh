#!/bin/bash
# --- MDesign Master Core | Central Installer v2.0.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
REPO_BASE="https://raw.githubusercontent.com/htzserv/MTunnel/main"

clear
echo -e "\n  ${B}╭──────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MDesign Master Core Setup${NC} ${DIM}| Initializing Workspace...${NC}  ${B}│${NC}"
echo -e "  ${B}╰──────────────────────────────────────────────────────────╯${NC}\n"

echo -e "  ${Y}● Fetching latest Core Modules from Repository...${NC}"
CACHE_BUST=$(date +%s)

# لیست کامل تمام ماژول‌های سیستم
MODULES=("main.sh" "mgre.sh" "mxlan.sh" "mwire.sh" "mporter.sh" "minterface.sh" "mdiag.sh" "mshield.sh" "mstats.sh" "mhealer.sh" "mweb.sh")

for file in "${MODULES[@]}"; do
    echo -e "  ${DIM}├─ Downloading $file...${NC}"
    wget --timeout=10 --tries=2 -qO "/tmp/$file" "$REPO_BASE/${file}?v=$CACHE_BUST"
    if [ ! -s "/tmp/$file" ]; then
        echo -e "  ${R}● Critical Error: Failed to download $file. Check network/Github!${NC}"
        exit 1
    fi
done

echo -e "  ${DIM}├─ Purging old binary symlinks & deploying updates...${NC}"
for file in "${MODULES[@]}"; do
    # حذف پسوند .sh برای ساخت دستورات لینوکسی تمیز
    mod_name="${file%.sh}"
    # فایل main تبدیل میشه به mtunnel
    if [ "$mod_name" == "main" ]; then mod_name="mtunnel"; fi
    
    cat "/tmp/$file" > "/usr/bin/$mod_name"
    chmod +x "/usr/bin/$mod_name"
    rm -f "/tmp/$file"
done

echo -e "  ${G}● Installation Complete! All Modules Deployed.${NC}"
echo -e "  ${DIM}└─ Type '${W}mtunnel${DIM}' to launch the dashboard.${NC}\n"
sleep 1.5
exec mtunnel
