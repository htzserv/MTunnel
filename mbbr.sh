#!/bin/bash
# --- MDesign BBR Accelerator Core (mbbr.sh) v1.0.0 ---
# [Developed for MDesign Ecosystem]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; DIM='\033[2;37m'; NC='\033[0m'

enable_bbr() {
    echo -e "\n  ${DIM}● Enabling TCP BBR Acceleration...${NC}"
    
    # اعمال دستورات به هسته (Kernel)
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1

    # ثبت دائمی در فایل sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null

    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

    sysctl -p >/dev/null 2>&1

    # بررسی وضعیت
    local current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [ "$current_cc" == "bbr" ]; then
        echo -e "  ${G}● BBR Acceleration successfully ENABLED!${NC}"
    else
        echo -e "  ${R}● Failed to enable BBR or BBR is not supported on this kernel.${NC}"
    fi
}

disable_bbr() {
    echo -e "\n  ${DIM}● Disabling TCP BBR & Reverting to Cubic...${NC}"

    # بازگرداندن تنظیمات شبکه به حالت پیش‌فرض (Cubic)
    sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1

    # حذف کانفیگ‌ها از sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null

    sysctl -p >/dev/null 2>&1

    echo -e "  ${G}● BBR has been DISABLED and congestion control reverted to CUBIC.${NC}"
}

get_status() {
    local cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [ "$cc" == "bbr" ]; then
        echo -e "${G}ACTIVE (BBR)${NC}"
    else
        echo -e "${Y}INACTIVE (${cc:-cubic})${NC}"
    fi
}

# ورودی از خط فرمان (برای فراخوانی مستقیم)
if [ "$1" == "--enable" ]; then
    enable_bbr; exit 0
elif [ "$1" == "--disable" ]; then
    disable_bbr; exit 0
fi

# منوی تعاملی اجرا
clear
echo -e "\n  ${B}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MDesign BBR Acceleration Core v1.0.0${NC} ${B}│${NC} ${DIM}STATUS:${NC} $(get_status) ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────╯${NC}"

echo -e "\n  ${DIM}┌─[ BBR MANAGEMENT ]${NC}"
echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Enable BBR Network Acceleration${NC}"
echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Disable BBR & Remove Settings${NC}"
echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit${NC}\n"

echo -ne "  ${C}Select ❯❯ ${NC}"; read b_opt
b_opt=$(echo "$b_opt" | tr -d '\r' | tr -d ' ')

case $b_opt in
    1) enable_bbr ;;
    2) disable_bbr ;;
    0) exit 0 ;;
    *) echo -e "  ${R}● Invalid option!${NC}" ;;
esac
sleep 1.5
