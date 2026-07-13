#!/bin/bash
# --- MDesign Master Core | Central Installer v6.1.0 (Basic/Fast Edition) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
REPO_BASE="https://raw.githubusercontent.com/htzserv/MTunnel/main/mtunnel"
LOCAL_DIR="/root/mtunnel"

clear
echo -e "\n  ${B}╭──────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MDesign Master Core Setup${NC} ${DIM}| Initializing Workspace...${NC}  ${B}│${NC}"
echo -e "  ${B}╰──────────────────────────────────────────────────────────╯${NC}\n"

echo -e "  ${Y}● Fetching Core Scripts from Github...${NC}"
mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
CACHE_BUST=$(date +%s)
MODULES=("main.sh" "mgre.sh" "mxlan.sh" "mwire.sh" "mfrp.sh" "ml2tp.sh" "mhysteria.sh" "mbackhaul.sh" "mporter.sh" "minterface.sh" "mdiag.sh" "mshield.sh" "mstats.sh" "mhealer.sh" "mweb.sh")

for file in "${MODULES[@]}"; do
    echo -e "  ${DIM}├─ Syncing $file...${NC}"
    wget --timeout=10 --tries=2 -qO "$LOCAL_DIR/$file" "$REPO_BASE/${file}?v=$CACHE_BUST"
    sed -i 's/\r$//' "$LOCAL_DIR/$file" 2>/dev/null
    mod_name="${file%.sh}"
    [ "$mod_name" == "main" ] && mod_name="mtunnel"
    cat "$LOCAL_DIR/$file" > "/usr/bin/$mod_name" 2>/dev/null
    chmod +x "/usr/bin/$mod_name" 2>/dev/null
done

echo -e "\n  ${G}● Core Scripts Installed Successfully!${NC}"
echo -e "  ${DIM}└─ Launching Central Dashboard...${NC}\n"
sleep 1.5

if [ -t 0 ]; then bash /usr/bin/mtunnel; else bash /usr/bin/mtunnel < /dev/tty; fi
