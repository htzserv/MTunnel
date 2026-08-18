#!/bin/bash

# ==========================================================
# MTunnel - Porter & Heproxim / Gost Module (Offline & Online)
# ==========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/packages"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

# تابع بررسی و استقرار لوکال هپروکسی (HAProxy)
deploy_haproxy_offline() {
    echo -e "${YELLOW}[*] بررسی پکیج‌های لوکال هپروکسی (HAProxy) در ${PKG_DIR}...${NC}"
    
    if [ ! -d "$PKG_DIR" ]; then
        mkdir -p "$PKG_DIR"
        return 1
    fi

    # ۱. باینری مستقیم
    if [ -f "$PKG_DIR/haproxy" ]; then
        echo -e "${GREEN}[✓] باینری haproxy لوکال یافت شد. در حال استقرار...${NC}"
        cp "$PKG_DIR/haproxy" /usr/sbin/haproxy 2>/dev/null || cp "$PKG_DIR/haproxy" /usr/local/sbin/haproxy
        chmod +x /usr/sbin/haproxy /usr/local/sbin/haproxy 2>/dev/null
        mkdir -p /etc/haproxy /var/lib/haproxy
        touch /var/lib/haproxy/stats
        return 0
    fi

    # ۲. پکیج دبیان .deb
    if ls "$PKG_DIR"/haproxy*.deb 1> /dev/null 2>&1; then
        echo -e "${GREEN}[✓] فایل haproxy.deb یافت شد. در حال نصب...${NC}"
        dpkg -i "$PKG_DIR"/haproxy*.deb 2>/dev/null || apt-get install -f -y
        mkdir -p /etc/haproxy /var/lib/haproxy
        touch /var/lib/haproxy/stats
        return 0
    fi

    # ۳. آرشیو فشرده tar.gz یا zip
    if ls "$PKG_DIR"/haproxy*.tar.gz 1> /dev/null 2>&1; then
        echo -e "${GREEN}[✓] آرشیو haproxy.tar.gz یافت شد. در حال استخراج...${NC}"
        mkdir -p /tmp/haproxy_tmp
        tar -xzf "$PKG_DIR"/haproxy*.tar.gz -C /tmp/haproxy_tmp/
        cp $(find /tmp/haproxy_tmp -type f -name "haproxy" | head -n 1) /usr/sbin/haproxy 2>/dev/null
        chmod +x /usr/sbin/haproxy
        rm -rf /tmp/haproxy_tmp
        mkdir -p /etc/haproxy /var/lib/haproxy
        touch /var/lib/haproxy/stats
        return 0
    fi

    return 1
}

# تابع بررسی و استقرار لوکال گاست (Gost)
deploy_gost_offline() {
    echo -e "${YELLOW}[*] بررسی پکیج‌های لوکال گاست (Gost) در ${PKG_DIR}...${NC}"
    
    if [ ! -d "$PKG_DIR" ]; then
        mkdir -p "$PKG_DIR"
        return 1
    fi

    # ۱. باینری مستقیم
    if [ -f "$PKG_DIR/gost" ]; then
        echo -e "${GREEN}[✓] باینری gost لوکال یافت شد. در حال استقرار...${NC}"
        cp "$PKG_DIR/gost" /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
        return 0
    fi

    # ۲. فایل فشرده gz
    if ls "$PKG_DIR"/gost*.gz 1> /dev/null 2>&1 && ! ls "$PKG_DIR"/gost*.tar.gz 1> /dev/null 2>&1; then
        echo -e "${GREEN}[✓] فایل gost.gz لوکال یافت شد. در حال استخراج...${NC}"
        gzip -d -c "$PKG_DIR"/gost*.gz > /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
        return 0
    fi

    # ۳. فایل فشرده tar.gz
    if ls "$PKG_DIR"/gost*.tar.gz 1> /dev/null 2>&1; then
        echo -e "${GREEN}[✓] فایل gost.tar.gz لوکال یافت شد. در حال استخراج...${NC}"
        mkdir -p /tmp/gost_tmp
        tar -xzf "$PKG_DIR"/gost*.tar.gz -C /tmp/gost_tmp/
        cp $(find /tmp/gost_tmp -type f -name "gost" | head -n 1) /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
        rm -rf /tmp/gost_tmp
        return 0
    fi

    # ۴. فایل فشرده zip
    if ls "$PKG_DIR"/gost*.zip 1> /dev/null 2>&1; then
        echo -e "${GREEN}[✓] فایل gost.zip لوکال یافت شد. در حال استخراج...${NC}"
        mkdir -p /tmp/gost_tmp
        unzip -o "$PKG_DIR"/gost*.zip -d /tmp/gost_tmp/ >/dev/null 2>&1
        cp $(find /tmp/gost_tmp -type f -name "gost" | head -n 1) /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
        rm -rf /tmp/gost_tmp
        return 0
    fi

    return 1
}

# نصب هپروکسی با اولویت لوکال سپس آنلاین
install_heproxim() {
    clear
    echo -e "${CYAN}===============================================${NC}"
    echo -e "${YELLOW}           نصب و راه‌اندازی هپروکسی (HAProxy)   ${NC}"
    echo -e "${CYAN}===============================================${NC}"

    if deploy_haproxy_offline; then
        echo -e "${GREEN}[✔] هپروکسی به صورت آفلاین بدون نیاز به دانلود مستقر شد.${NC}"
    else
        echo -e "${YELLOW}[!] پکیج محلی یافت نشد. تلاش برای نصب آنلاین مخازن...${NC}"
        apt-get update -y
        apt-get install -y haproxy
        if [ $? -ne 0 ]; then
            echo -e "${RED}[-] خطای نصب آنلاین. لطفاً فایل باینری را در پوشه packages قرار دهید.${NC}"
            read -p "اینتر بزنید..." dummy
            return 1
        fi
    fi

    systemctl daemon-reload
    systemctl enable haproxy 2>/dev/null
    echo -e "${GREEN}[✔] نصب هپروکسی با موفقیت به پایان رسید.${NC}"
    read -p "اینتر بزنید..." dummy
}

# نصب گاست با اولویت لوکال سپس آنلاین
install_gost() {
    clear
    echo -e "${CYAN}===============================================${NC}"
    echo -e "${YELLOW}             نصب و راه‌اندازی گاست (Gost)       ${NC}"
    echo -e "${CYAN}===============================================${NC}"

    if deploy_gost_offline; then
        echo -e "${GREEN}[✔] گاست به صورت آفلاین بدون نیاز به دانلود مستقر شد.${NC}"
    else
        echo -e "${YELLOW}[!] پکیج محلی یافت نشد. در حال دانلود از گیت‌هاب...${NC}"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) GOST_ARCH="linux-amd64" ;;
            aarch64) GOST_ARCH="linux-arm64" ;;
            *) GOST_ARCH="linux-amd64" ;;
        esac

        GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-${GOST_ARCH}-2.11.5.gz"
        wget -q --show-progress -O /tmp/gost.gz "$GOST_URL"
        if [ $? -eq 0 ]; then
            gzip -d -c /tmp/gost.gz > /usr/local/bin/gost
            chmod +x /usr/local/bin/gost
            rm -f /tmp/gost.gz
            echo -e "${GREEN}[✔] گاست با موفقیت دانلود و نصب شد.${NC}"
        else
            echo -e "${RED}[-] خطا در دانلود گاست. اینترنت سرور یا اتصال گیتهاب را بررسی کنید.${NC}"
            read -p "اینتر بزنید..." dummy
            return 1
        fi
    fi

    read -p "اینتر بزنید..." dummy
}

# منوی داخلی مدیریت پورت و سرویس‌ها
porter_menu() {
    while true; do
        clear
        echo -e "${CYAN}===============================================${NC}"
        echo -e "${GREEN}          مدیریت Heproxim / Gost / Porter       ${NC}"
        echo -e "${CYAN}===============================================${NC}"
        echo -e " [1] نصب / استقرار هپروکسی (HAProxy)"
        echo -e " [2] نصب / استقرار گاست (Gost)"
        echo -e " [3] استقرار خودکار پکیج‌های لوکال (هر دو)"
        echo -e " [0] بازگشت به منوی اصلی"
        echo -e "${CYAN}-----------------------------------------------${NC}"
        read -p "گزینه مورد نظر را وارد کنید: " p_choice

        case $p_choice in
            1) install_heproxim ;;
            2) install_gost ;;
            3)
                clear
                echo -e "${YELLOW}[*] بررسی و استقرار خودکار تمامی باینری‌های لوکال...${NC}\n"
                deploy_haproxy_offline && echo -e "${GREEN}[✓] هپروکسی مستقر شد.${NC}"
                deploy_gost_offline && echo -e "${GREEN}[✓] گاست مستقر شد.${NC}"
                echo ""
                read -p "اینتر بزنید..." dummy
                ;;
            0) break ;;
            *) echo -e "${RED}گزینه نامعتبر!${NC}"; sleep 1 ;;
        esac
    done
}

porter_menu
