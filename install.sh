#!/bin/bash
# --- MDesign Master Core | Central Installer v7.7.0 (Automatic Full Sync) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
LOCAL_DIR="/root/mtunnel"

clear
echo -e "\n  ${B}╭──────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MDesign Master Core Setup${NC} ${DIM}| Auto-Syncing Ecosystem...${NC}  ${B}│${NC}"
echo -e "  ${B}╰──────────────────────────────────────────────────────────╯${NC}\n"

echo -e "  ${Y}● Fetching Core & Extra Ecosystem Modules...${NC}"

CORE_MODULES=("main.sh" "mgre.sh" "mxlan.sh" "mrathole.sh" "mgostun.sh" "mfrp.sh" "mporter.sh" "mweb.sh")
EXTRA_MODULES=("minterface.sh" "mdiag.sh" "mshield.sh" "mstats.sh" "mhealer.sh" "mwire.sh" "ml2tp.sh" "mhysteria.sh" "mbackhaul.sh")
MODULES=("${CORE_MODULES[@]}" "${EXTRA_MODULES[@]}")

mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
CACHE_BUST=$(date +%s)

for file in "${MODULES[@]}"; do
    echo -e "  ${DIM}├─ Syncing $file...${NC}"
    wget --timeout=5 --tries=2 -qO "/tmp/$file" "$REPO_SCRIPTS/${file}?v=$CACHE_BUST"
    
    if [ "$file" == "main.sh" ] && [ ! -s "/tmp/$file" ]; then
        wget --timeout=5 --tries=2 -qO "/tmp/$file" "$REPO_SCRIPTS/mtunnel.sh?v=$CACHE_BUST"
    fi
    
    if [ -s "/tmp/$file" ]; then
        mv "/tmp/$file" "$LOCAL_DIR/$file"
    elif [ -s "$LOCAL_DIR/$file" ]; then
        echo -e "  ${Y}├─ Internet unavailable, using offline cache for $file...${NC}"
    else
        echo -e "  ${R}● Warning: $file not found on GitHub and no offline cache! Skipping...${NC}"
        continue
    fi

    sed -i 's/\r$//' "$LOCAL_DIR/$file" 2>/dev/null
    mod_name="${file%.sh}"
    [ "$mod_name" == "main" ] && mod_name="mtunnel"
    
    cat "$LOCAL_DIR/$file" > "/usr/bin/$mod_name" 2>/dev/null
    chmod +x "/usr/bin/$mod_name" 2>/dev/null
    
    if [ "$mod_name" == "mtunnel" ]; then
        cp "/usr/bin/$mod_name" "/usr/local/bin/$mod_name" 2>/dev/null
        chmod +x "/usr/local/bin/$mod_name" 2>/dev/null
    fi
done

if [ ! -x "/usr/bin/mtunnel" ]; then
    echo -e "\n  ${R}● FATAL ERROR: Main script could not be deployed!${NC}"
    exit 1
fi

echo -e "\n  ${G}● Full Ecosystem Installation Completed Successfully!${NC}"
echo -e "  ${DIM}└─ Launching Central Dashboard...${NC}\n"
sleep 1.5

hash -r 2>/dev/null
if [ -t 0 ]; then mtunnel; else mtunnel < /dev/tty; fi
exit 0
