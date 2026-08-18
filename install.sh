#!/bin/bash
# --- MTunnel & MDesign Core Installer v7.5.5 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; NC='\033[0m'
LOCAL_DIR="/root/mtunnel"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

clear
echo -e "${B}╭────────────────────────────────────────────────────────────╮${NC}"
echo -e "${B}│${NC} ${W}MTunnel Infrastructure Master Installer v7.5.5${NC}            ${B}│${NC}"
echo -e "${B}╰────────────────────────────────────────────────────────────╯${NC}"

# ۱. ساخت دایرکتوری‌های اصلی
echo -e "\n  ${C}[1/4]${NC} Creating required system workspaces..."
mkdir -p "$LOCAL_DIR/packages" /etc/haproxy /var/lib/haproxy /etc/gost /etc/mporter/obfs_rules /usr/local/bin /usr/sbin /usr/local/sbin 2>/dev/null

# ۲. کپی کردن اسکریپت‌های محلی در مسیرهای سیستم
echo -e "  ${C}[2/4]${NC} Deploying local modular scripts..."
if [ -d "$SCRIPT_DIR" ]; then
    cp -f "$SCRIPT_DIR"/*.sh "$LOCAL_DIR/" 2>/dev/null
    for f in "$SCRIPT_DIR"/*.sh; do
        [ -f "$f" ] || continue
        base_name=$(basename "$f" .sh)
        [ "$base_name" == "main" ] && base_name="mtunnel"
        cp -f "$f" "/usr/bin/$base_name" 2>/dev/null
        chmod +x "/usr/bin/$base_name" 2>/dev/null
    done
fi

# ۳. بررسی و استقرار باینری‌های پوشه packages
echo -e "  ${C}[3/4]${NC} Checking local packages cache..."
PKG_SOURCE=""
[ -d "$SCRIPT_DIR/packages" ] && PKG_SOURCE="$SCRIPT_DIR/packages"
[ -z "$PKG_SOURCE" ] && [ -d "$LOCAL_DIR/packages" ] && PKG_SOURCE="$LOCAL_DIR/packages"

if [ -n "$PKG_SOURCE" ] && [ -d "$PKG_SOURCE" ]; then
    cp -rf "$PKG_SOURCE"/* "$LOCAL_DIR/packages/" 2>/dev/null

    # هپروکسی لوکال
    if [ -s "$LOCAL_DIR/packages/haproxy" ]; then
        cp -f "$LOCAL_DIR/packages/haproxy" /usr/sbin/haproxy
        chmod +x /usr/sbin/haproxy
        echo -e "      ${G}✓${NC} HAProxy binary deployed from local package"
    fi

    # گاست لوکال
    if [ -s "$LOCAL_DIR/packages/gost" ]; then
        cp -f "$LOCAL_DIR/packages/gost" /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
        echo -e "      ${G}✓${NC} Gost binary deployed from local package"
    fi

    # پکیج‌های تانل دیگر
    for b in rathole backhaul bh frpc frps hysteria; do
        if [ -s "$LOCAL_DIR/packages/$b" ]; then
            cp -f "$LOCAL_DIR/packages/$b" /usr/local/bin/$b
            chmod +x "/usr/local/bin/$b"
            echo -e "      ${G}✓${NC} $b deployed from local package"
        fi
    done

    # فایل‌های deb
    if ls "$LOCAL_DIR/packages"/*.deb >/dev/null 2>&1; then
        dpkg -i "$LOCAL_DIR/packages"/*.deb >/dev/null 2>&1 || true
        echo -e "      ${G}✓${NC} System .deb packages installed"
    fi
fi

# ۴. تنظیم کانفیگ‌ها و سیستم‌دی
echo -e "  ${C}[4/4]${NC} Configuring system environment & services..."
sysctl -w fs.file-max=2000000 >/dev/null 2>&1
touch /var/lib/haproxy/stats 2>/dev/null

if [ ! -s /etc/haproxy/haproxy.cfg ]; then
cat << 'EOF_HAP' > /etc/haproxy/haproxy.cfg
global
    maxconn 500000
    daemon
defaults
    mode tcp
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend dummy_check
    bind 127.0.0.1:9999
    default_backend dummy_back
backend dummy_back
    server local 127.0.0.1:9999
EOF_HAP
fi

if [ -f /usr/sbin/haproxy ]; then
cat << 'EOF_UNIT' > /etc/systemd/system/haproxy.service
[Unit]
Description=HAProxy Load Balancer
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/haproxy -f /etc/haproxy/haproxy.cfg -db
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_UNIT
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable haproxy >/dev/null 2>&1
    systemctl restart haproxy >/dev/null 2>&1
fi

echo -e "\n  ${G}✔ Installation completed successfully!${NC}"
echo -e "  Run ${W}mtunnel${NC} or ${W}mporter${NC} from anywhere to manage.\n"
