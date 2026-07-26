#!/bin/bash
# --- MDesign Modular Core (mbackhaul.sh) | Backhaul Engine v6.2.0 (Offline Fixed) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
LOCAL_DIR="/root/mtunnel/packages"

check_binary() {
    if ! command -v bh >/dev/null 2>&1; then
        if [ -f "/usr/local/bin/bh" ]; then chmod +x /usr/local/bin/bh; return; fi
        
        if [ -s "$LOCAL_DIR/bh" ]; then
            echo -e "\n  ${G}● Using offline Backhaul Engine (bh)...${NC}"
            cp "$LOCAL_DIR/bh" /usr/local/bin/bh; chmod +x /usr/local/bin/bh
            return
        fi

        echo -e "\n  ${Y}● Fetching 'bh' (Backhaul Engine) from GitHub packages folder...${NC}"
        wget -qO "/tmp/bh" "https://raw.githubusercontent.com/htzserv/MTunnel/main/packages/bh"
        if [ -s "/tmp/bh" ]; then
            mv "/tmp/bh" "$LOCAL_DIR/bh"
            cp "$LOCAL_DIR/bh" /usr/local/bin/bh; chmod +x /usr/local/bin/bh
            echo -e "  ${G}● Engine installed successfully!${NC}"
        else
            echo -e "  ${R}● FATAL ERROR: Failed to download 'bh'!${NC}"; sleep 3; exit 1
        fi
    fi
}
# Only check_binary is replaced for brevity in patching tool.
echo "mbackhaul.sh offline fix applied."
