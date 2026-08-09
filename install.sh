#!/bin/bash
# --- MTunnel Core Installer v7.5.6 (White Progress Bar & Auto-Exec) ---
# [Developed for MDesign Ecosystem]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

LOCAL_DIR="/root/mtunnel"
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"
BOOTSTRAP_MODULES=("main.sh" "mgre.sh" "mporter.sh" "mxlan.sh" "mrathole.sh" "mbbr.sh" "mweb.sh" "mstats.sh")

mkdir -p "$LOCAL_DIR"

# نوار پیشرفت کاملاً سفید
draw_progress() {
    local n=$1; local total=$2; local text=$3; local width=25
    [ -z "$total" ] || [ "$total" -le 0 ] && total=1
    local percent=$(( n * 100 / total ))
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar=$(printf "%${filled}s" "" | tr ' ' '#')
    local empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')
    
    tput civis 2>/dev/null || true
    printf "\r  %b✔%b %b%-20s%b %b[%b%s%b%s%b] %b%3d%%%%%b" "$G" "$NC" "$W" "$text" "$NC" "$W" "$W" "$bar" "$DIM" "$empty_bar" "$NC" "$W" "$percent" "$NC"
    tput cnorm 2>/dev/null || true
}

clear
echo -e "\n  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MTunnel Core Installer v7.5.6${NC}                              ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}\n"

total_mods=${#BOOTSTRAP_MODULES[@]}
current=0

for file in "${BOOTSTRAP_MODULES[@]}"; do
    ((current++))
    mod_name="${file%.sh}"
    [ "$mod_name" == "main" ] && target_bin="/usr/bin/mtunnel" || target_bin="/usr/bin/$mod_name"

    if [ -s "$LOCAL_DIR/$file" ]; then
        chmod +x "$LOCAL_DIR/$file"
        if [ "$(readlink -f "$LOCAL_DIR/$file" 2>/dev/null)" != "$(readlink -f "$target_bin" 2>/dev/null)" ]; then
            cp -f "$LOCAL_DIR/$file" "$target_bin" 2>/dev/null
        fi
        chmod +x "$target_bin" 2>/dev/null
        draw_progress "$current" "$total_mods" "$mod_name (local)"
        echo ""
        continue
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 8 -o "$LOCAL_DIR/$file" "$REPO_SCRIPTS/$file" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=8 -O "$LOCAL_DIR/$file" "$REPO_SCRIPTS/$file" 2>/dev/null
    fi

    if [ -s "$LOCAL_DIR/$file" ]; then
        sed -i 's/\r$//' "$LOCAL_DIR/$file" 2>/dev/null
        chmod +x "$LOCAL_DIR/$file"
        cp -f "$LOCAL_DIR/$file" "$target_bin" 2>/dev/null
        chmod +x "$target_bin" 2>/dev/null
        draw_progress "$current" "$total_mods" "$mod_name"
        echo ""
    else
        echo -e "\n  ${R}Installation failed: $mod_name${NC}"
        exit 1
    fi
done

ln -sfn /usr/bin/mtunnel /usr/local/bin/mtunnel 2>/dev/null

if [ -x "/usr/bin/mweb" ]; then
    mkdir -p /etc/mweb 2>/dev/null
    if [ ! -f "/etc/mweb/web.conf" ]; then
        echo -e "WEB_PORT=1000\nWEB_USER=admin\nWEB_PASS=admin" > /etc/mweb/web.conf
    fi
    cat <<'EOF' > /etc/systemd/system/mweb.service
[Unit]
Description=MDesign Fleet Radar UI
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/mweb
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable mweb.service >/dev/null 2>&1
    systemctl restart mweb.service >/dev/null 2>&1
fi

echo -e "\n  ${G}● MTunnel Installation Complete! Starting Core Dashboard...${NC}\n"
sleep 1.5

if [ -x "/usr/bin/mtunnel" ]; then
    exec /usr/bin/mtunnel
fi
