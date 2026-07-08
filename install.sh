#!/bin/bash
# --- MHDesign Master Core | Auto Installer ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; DIM='\033[2;37m'; NC='\033[0m'
REPO="https://raw.githubusercontent.com/htzserv/MTunnel/main"

clear
echo -e "\n  ${B}╭────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MHDesign Core Initializing...${NC}          ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────╯${NC}\n"

# ساخت پوشه پروژه و ورود به آن
echo -e "  ${DIM}├─ Creating workspace directory (MTunnel)...${NC}"
mkdir -p MTunnel
cd MTunnel || exit

# دانلود ماژول‌ها
echo -e "  ${DIM}├─ Fetching Core Modules...${NC}"
curl -sO "$REPO/main.sh"
curl -sO "$REPO/mgre.sh"
curl -sO "$REPO/mporter.sh"

# اعمال دسترسی‌ها
echo -e "  ${DIM}├─ Applying execution permissions...${NC}"
chmod +x *.sh

echo -e "  ${G}● Installation Complete! Booting Dashboard...${NC}"
sleep 1.5

# اجرای داشبورد مرکزی
./main.sh
