#!/bin/bash
# --- MDesign Master Core | Auto Installer v1.2 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; DIM='\033[2;37m'; NC='\033[0m'
REPO="https://raw.githubusercontent.com/htzserv/MTunnel/main"

clear
echo -e "\n  ${B}╭────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MDesign Core Initializing...${NC}           ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────╯${NC}\n"

echo -e "  ${DIM}├─ Creating workspace directory (MTunnel)...${NC}"
mkdir -p MTunnel
cd MTunnel || exit

echo -e "  ${DIM}├─ Fetching Core Modules...${NC}"
curl --connect-timeout 10 -m 20 -sO "$REPO/main.sh"
curl --connect-timeout 10 -m 20 -sO "$REPO/mgre.sh"
curl --connect-timeout 10 -m 20 -sO "$REPO/mporter.sh"
curl --connect-timeout 10 -m 20 -sO "$REPO/mdiag.sh"

echo -e "  ${DIM}├─ Applying execution permissions...${NC}"
chmod +x *.sh

echo -e "  ${G}● Installation Complete! Booting Dashboard...${NC}"
sleep 1.5

./main.sh
