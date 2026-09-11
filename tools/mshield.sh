#!/bin/bash
# --- MDesign Modular Core (mshield.sh) | Stealth Anti-Probing & Anti-RST Shield v3.0.1 ---
# [Features: Refined Spacing | Async Background Checker | Minimal OTA Badges]

MODULE_VERSION="3.0.1"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mshield"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
CONF_FILE="/etc/mshield/shield.conf"

mkdir -p /etc/mshield "$LOCAL_DIR/packages" "$LOCAL_DIR/tools" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

# --- ASYNC BACKGROUND UPDATE CHECKER ---
check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tools/mshield.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tools/mshield.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mshield_remote_ver"
}
check_update_bg &
# ---------------------------------------

self_update_module() {
    local rel_path="tools/mshield.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mshield_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mshield_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (MShield Module) ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ AUTOMATIC MIRRORS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${gh_text}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MANUAL OVERRIDES ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Offline Editor)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_opt
    
    local tmp_file="$SECURE_TMP/.mshield_update.$$"
    > "$tmp_file"

    if [[ "$src_opt" == "4" ]]; then
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste your code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
            sleep 2; nano "$tmp_file"
        elif command -v vi >/dev/null 2>&1; then
            vi "$tmp_file"
        else
            echo -e "  ${R}✖ No text editor (nano/vi) found!${NC}"; rm -f "$tmp_file"; sleep 2; return
        fi
    elif [[ "$src_opt" =~ ^[123]$ ]]; then
        local dl_url=""
        case $src_opt in
            1) dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path$cb" ;;
            2) dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path$cb" ;;
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read custom_url; dl_url=$(echo "$custom_url" | tr -d '\r ') ;;
        esac
        [ -z "$dl_url" ] && rm -f "$tmp_file" && return

        echo -e "\n  ${C}⟳${NC} ${W}Downloading Update...${NC}"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp_file" "$dl_url" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 -O "$tmp_file" "$dl_url" 2>/dev/null
        fi
    else
        rm -f "$tmp_file"; return
    fi

    if [ -s "$tmp_file" ] && grep -q "#!/bin/bash" "$tmp_file"; then
        local new_ver=$(grep -m1 '^MODULE_VERSION=' "$tmp_file" | cut -d'"' -f2)
        [ -z "$new_ver" ] && new_ver="Unknown"
        
        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read confirm
        
        if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
            sed -i 's/\r$//' "$tmp_file" 2>/dev/null
            chmod +x "$tmp_file"
            cat "$tmp_file" > "$INSTALL_PATH" 2>/dev/null || true
            [ -f "$0" ] && cat "$tmp_file" > "$0" 2>/dev/null || true
            cp -f "$tmp_file" "$LOCAL_DIR/$rel_path" 2>/dev/null
            rm -f "$tmp_file"
            echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
            sleep 1.5
            exec "$INSTALL_PATH" "$@"
        else
            echo -e "  ${Y}● Update cancelled by user.${NC}"
            rm -f "$tmp_file"; sleep 1.5
        fi
    else
        echo -e "  ${R}✖ Update failed. Invalid format or network timeout.${NC}"
        rm -f "$tmp_file"; sleep 2
    fi
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    local sh_stat="${DIM}DISABLED${NC}"
    if [ -f "$CONF_FILE" ] && grep -q "SHIELD_ENABLED=true" "$CONF_FILE"; then sh_stat="${G}ACTIVE (Anti-RST + NOTRACK)${NC}"; fi
    clear; echo ""
    local str1=" Stealth Anti-Probing & Anti-RST Shield v${MODULE_VERSION} "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Shield:${NC} ${sh_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

enable_shield() {
    # 1. Drop Inactive RST Packets & Apply NOTRACK
    iptables -t mangle -C OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null
    iptables -t raw -C PREROUTING -p tcp -m multiport --dports 80,443,8443,8888,9443,9643,9743 -j NOTRACK 2>/dev/null || iptables -t raw -A PREROUTING -p tcp -m multiport --dports 80,443,8443,8888,9443,9643,9743 -j NOTRACK 2>/dev/null
    
    # 2. Block Active Port Scanners (SYN Rate Limit)
    iptables -N MSHIELD_PORT_SCAN 2>/dev/null || true
    iptables -C INPUT -p tcp --syn -j MSHIELD_PORT_SCAN 2>/dev/null || iptables -I INPUT -p tcp --syn -j MSHIELD_PORT_SCAN 2>/dev/null
    iptables -F MSHIELD_PORT_SCAN 2>/dev/null
    iptables -A MSHIELD_PORT_SCAN -m limit --limit 25/s --limit-burst 100 -j RETURN 2>/dev/null
    iptables -A MSHIELD_PORT_SCAN -j DROP 2>/dev/null

    echo "SHIELD_ENABLED=true" > "$CONF_FILE"
    echo -e "\n  ${G}● Stealth Shield & Anti-RST Protection Enabled!${NC}"; sleep 1.5
}

disable_shield() {
    iptables -t mangle -D OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || true
    iptables -t raw -D PREROUTING -p tcp -m multiport --dports 80,443,8443,8888,9443,9643,9743 -j NOTRACK 2>/dev/null || true
    iptables -D INPUT -p tcp --syn -j MSHIELD_PORT_SCAN 2>/dev/null || true
    iptables -F MSHIELD_PORT_SCAN 2>/dev/null || true
    iptables -X MSHIELD_PORT_SCAN 2>/dev/null || true

    rm -f "$CONF_FILE"
    echo -e "\n  ${Y}● Stealth Shield Disabled.${NC}"; sleep 1.5
}

while true; do
    badge=""
    if [ -f "$SECURE_TMP/.mshield_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.mshield_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_header
    echo -e "\n  ${DIM}┌─[ SECURITY & FIREWALL ACTIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Enable Stealth Shield (Anti-RST + Drop Probing Scans)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Disable Shield & Restore Default Kernel Flags${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Instant OTA Update (Sync Module)${NC}${badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"

    echo -ne "  ${C}SHIELD ❯❯ ${NC}"; read opt
    opt=$(echo "$opt" | tr -d '\r ')

    case $opt in
        1) enable_shield ;;
        2) disable_shield ;;
        3) self_update_module ;;
        0) break ;;
        *) echo -e "  ${R}● Invalid option!${NC}"; sleep 1 ;;
    esac
done
