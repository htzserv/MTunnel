#!/bin/bash
# --- MDesign Master Core | Central Installer v7.4.0 (Fixed GitHub Paths) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

# 🌟 آدرس اصلاح شد: مستقیم از روتِ شاخه main می‌خونه 🌟
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
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
    wget --timeout=10 --tries=2 -qO "$LOCAL_DIR/$file" "$REPO_SCRIPTS/${file}?v=$CACHE_BUST"
    
    # اگر فایل با اسم main.sh پیدا نشد، شاید اسمش mtunnel.sh باشه
    if [ "$file" == "main.sh" ] && [ ! -s "$LOCAL_DIR/$file" ]; then
        wget --timeout=10 --tries=2 -qO "$LOCAL_DIR/$file" "$REPO_SCRIPTS/mtunnel.sh?v=$CACHE_BUST"
    fi
    
    if [ ! -s "$LOCAL_DIR/$file" ]; then
        echo -e "  ${R}● Warning: $file not found on GitHub! Skipping...${NC}"
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
    echo -e "\n  ${R}● FATAL ERROR: Main script could not be downloaded!${NC}"
    exit 1
fi

echo -e "\n  ${G}● Core Scripts Installed Successfully!${NC}"
echo -e "  ${DIM}└─ Launching Central Dashboard...${NC}\n"
sleep 1.5

hash -r 2>/dev/null
if [ -t 0 ]; then
    mtunnel
else
    mtunnel < /dev/tty
fi
exit 0
