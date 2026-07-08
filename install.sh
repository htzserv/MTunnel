#!/bin/bash
# --- MDesign Master Core | Auto Installer v1.3 (Fully Dynamic) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; DIM='\033[2;37m'; NC='\033[0m'
REPO="https://raw.githubusercontent.com/htzserv/MTunnel/main"

clear
echo -e "\n  ${B}╭────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MDesign Core Initializing...${NC}           ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────╯${NC}\n"

echo -e "  ${DIM}├─ Creating workspace directory (MTunnel)...${NC}"
mkdir -p MTunnel
cd MTunnel || exit

echo -e "  ${DIM}├─ Scanning remote repository structure...${NC}"
# اسکن داینامیک پوشه گیت‌هاب برای استخراج تمام اسکریپت‌ها
sh_files=$(curl -sL --connect-timeout 10 "https://api.github.com/repos/htzserv/MTunnel/contents/" | grep -oP '"name": "\K[^"]+\.sh')

# لایه دوم: اگر ال‌پی‌آی گیت‌هاب در سرور ایران محدود بود، هسته اصلی را دانلود کن
if [ -z "$sh_files" ]; then
    sh_files="main.sh mgre.sh mporter.sh mdiag.sh"
fi

echo -e "  ${DIM}├─ Fetching All Detected Modules...${NC}"
for file in $sh_files; do
    echo -e "  ${DIM}│  ❯ Downloading $file...${NC}"
    curl --connect-timeout 10 -m 20 -sO "$REPO/$file"
done

echo -e "  ${DIM}├─ Applying execution permissions...${NC}"
chmod +x *.sh

echo -e "  ${G}● Installation Complete! Booting Dashboard...${NC}"
sleep 1.5

./main.sh
