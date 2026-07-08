#!/bin/bash
# --- MDesign Master Core | Central Installer v1.3.1 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
REPO_BASE="https://raw.githubusercontent.com/htzserv/MTunnel/main"

clear
echo -e "\n  ${B}╭──────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MDesign Master Core Setup${NC} ${DIM}| Initializing Workspace...${NC}  ${B}│${NC}"
echo -e "  ${B}╰──────────────────────────────────────────────────────────╯${NC}\n"

echo -e "  ${Y}● Fetching latest Core Modules from Repository...${NC}"
CACHE_BUST=$(date +%s)
MODULES=("main.sh" "mgre.sh" "mporter.sh" "mdiag.sh" "minterface.sh")

for file in "${MODULES[@]}"; do
    echo -e "  ${DIM}├─ Downloading $file...${NC}"
    wget --timeout=10 --tries=2 -qO "/tmp/$file" "$REPO_BASE/${file}?v=$CACHE_BUST"
    if [ ! -s "/tmp/$file" ]; then
        echo -e "  ${R}● Critical Error: Failed to download $file. Check network connection!${NC}"
        exit 1
    fi
done

echo -e "  ${DIM}├─ Purging old binary symlinks & deploying updates...${NC}"
cat "/tmp/main.sh" > "/usr/bin/mtunnel"
cat "/tmp/mgre.sh" > "/usr/bin/mgre"
cat "/tmp/mporter.sh" > "/usr/bin/mporter"
cat "/tmp/mdiag.sh" > "/usr/bin/mdiag"
cat "/tmp/minterface.sh" > "/usr/bin/minterface"

chmod +x /usr/bin/mtunnel /usr/bin/mgre /usr/bin/mporter /usr/bin/mdiag /usr/bin/minterface
rm -f /tmp/*.sh

echo -e "  ${G}● Installation Complete!${NC}"
echo -e "  ${DIM}└─ Type '${W}mtunnel${DIM}' to launch the dashboard.${NC}\n"
sleep 1.5
exec mtunnel
