#!/bin/bash
# --- MDesign Master Core | Central Installer v4.2.0 (WaterWall Edition) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
REPO_BASE="https://raw.githubusercontent.com/htzserv/MTunnel/main"
LOCAL_DIR="/root/mtunnel"

clear
echo -e "\n  ${B}╭──────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MDesign Master Core Setup${NC} ${DIM}| Initializing Workspace...${NC}  ${B}│${NC}"
echo -e "  ${B}╰──────────────────────────────────────────────────────────╯${NC}\n"

echo -e "  ${Y}● Creating Local Master Repository in ${W}$LOCAL_DIR${Y}...${NC}"
mkdir -p "$LOCAL_DIR/packages" 2>/dev/null

echo -e "  ${Y}● Fetching latest Core Modules from Github...${NC}"
CACHE_BUST=$(date +%s)

# لیست کامل ماژول‌ها شامل WaterWall
MODULES=("main.sh" "mgre.sh" "mxlan.sh" "mwire.sh" "mfrp.sh" "mwall.sh" "mporter.sh" "minterface.sh" "mdiag.sh" "mshield.sh" "mstats.sh" "mhealer.sh" "mweb.sh")

for file in "${MODULES[@]}"; do
    echo -e "  ${DIM}├─ Syncing $file...${NC}"
    wget --timeout=10 --tries=2 -qO "$LOCAL_DIR/$file" "$REPO_BASE/${file}?v=$CACHE_BUST"
    if [ ! -s "$LOCAL_DIR/$file" ]; then
        echo -e "  ${R}● Critical Error: Failed to download $file. Check network or GitHub URL.${NC}"
        exit 1
    fi
done

echo -e "  ${DIM}├─ Deploying binary modules to system core...${NC}"
for file in "${MODULES[@]}"; do
    mod_name="${file%.sh}"
    [ "$mod_name" == "main" ] && mod_name="mtunnel"
    
    cat "$LOCAL_DIR/$file" > "/usr/bin/$mod_name"
    chmod +x "/usr/bin/$mod_name"
done

echo -e "  ${G}● Installation Complete! Local Backup Saved.${NC}"
echo -e "  ${DIM}└─ Type '${W}mtunnel${DIM}' to launch the dashboard.${NC}\n"
sleep 1.5
exec mtunnel
