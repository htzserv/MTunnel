#!/usr/bin/env bash

# ==========================================================
# MTunnel Ecosystem - MDesign Speed & Network Optimizer
# Version: 8.8.0
# ==========================================================
MODULE_VERSION="1.4.0"

set -o pipefail

# ----------------------------------------------------------
# Colors (MDesign Matching Theme)
# ----------------------------------------------------------

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_LINE='\033[38;5;240m'      # Dark Divider Line
C_CYAN='\033[38;5;45m'       # Pure Aqua / Cyan
C_GREEN='\033[38;5;48m'      # Mint Green Indicator
C_RED='\033[38;5;203m'       # Soft Red Exit / IP
C_MAGENTA='\033[38;5;170m'   # Purple / Pink
C_ORANGE='\033[38;5;215m'    # Light Orange
C_WHITE='\033[38;5;255m'     # Bold Bright White
C_GRAY='\033[38;5;244m'      # Subtitle / Details

# ----------------------------------------------------------
# Root Check
# ----------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo -e "   ${C_RED}${C_BOLD}[!] Error: Run this script as root.${C_RESET}"
    exit 1
fi

# ----------------------------------------------------------
# Tools Preparation
# ----------------------------------------------------------

prepare_tools() {
    local packages=()
    command -v lsb_release >/dev/null 2>&1 || packages+=("lsb-release")
    command -v curl        >/dev/null 2>&1 || packages+=("curl")
    command -v dig         >/dev/null 2>&1 || packages+=("dnsutils")
    command -v bc          >/dev/null 2>&1 || packages+=("bc")

    if [[ ${#packages[@]} -gt 0 ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq "${packages[@]}" >/dev/null 2>&1 || true
        fi
    fi
}

prepare_tools

# ----------------------------------------------------------
# System Detectors
# ----------------------------------------------------------

UBUNTU_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
UBUNTU_RELEASE="$(lsb_release -rs 2>/dev/null || true)"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo "amd64")"

[[ -z "$UBUNTU_CODENAME" ]] && UBUNTU_CODENAME="jammy"
[[ -z "$UBUNTU_RELEASE" ]] && UBUNTU_RELEASE="22.04"

get_active_mirror_url() {
    local url=""
    if [[ -f "/etc/apt/sources.list.d/ubuntu.sources" ]]; then
        url="$(awk '/^[[:space:]]*URIs:/ {print $2; exit}' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null)"
    elif [[ -f "/etc/apt/sources.list" ]]; then
        url="$(awk '/^[[:space:]]*deb[[:space:]]+/ {print $2; exit}' /etc/apt/sources.list 2>/dev/null)"
    fi
    [[ -z "$url" ]] && url="http://archive.ubuntu.com/ubuntu"
    echo "$url"
}

get_mirror_display_name() {
    local url="${1%/}"
    case "$url" in
        *"mirror.cdn.ir"*) echo "Asiatech" ;;
        *"aminidc"*|*"amincloud"*) echo "AminiDC" ;;
        *"faraso"*) echo "Faraso" ;;
        *"sindad"*) echo "Sindad" ;;
        *"kimiahost"*) echo "KimiaHost" ;;
        *"petiak"*) echo "Petiak" ;;
        *"hostiran"*) echo "Hostiran" ;;
        *"bardia"*) echo "Bardia" ;;
        *"iranserver"*) echo "IranServer" ;;
        *"ir.archive.ubuntu.com"*) echo "Ubuntu Iran" ;;
        *"0-1.cloud"*) echo "0-1 Cloud" ;;
        *"linuxmirrors"*) echo "LinuxMirrors" ;;
        *"iut.ac.ir"*) echo "IUT" ;;
        *"shatel"*) echo "Shatel" ;;
        *"byteiran"*) echo "ByteIran" ;;
        *"rasanegar"*) echo "Rasanegar" ;;
        *"archive.ubuntu.com"*) echo "Official Archive" ;;
        *"arvancloud"*) echo "ArvanCloud" ;;
        *"sharif"*) echo "Sharif Univ" ;;
        *"ut.ac.ir"*) echo "Univ of Tehran" ;;
        *"manageit"*) echo "ManageIT" ;;
        *"pishgaman"*) echo "Pishgaman" ;;
        *"mobinhost"*) echo "MobinHost" ;;
        *"afranet"*) echo "Afranet" ;;
        *"digitalvps"*) echo "DigitalVPS" ;;
        *"liara"*) echo "Liara" ;;
        *"atlantiscloud"*) echo "AtlantisCloud" ;;
        *"chabokan"*) echo "Chabokan" ;;
        *"abrha"*) echo "Abrha" ;;
        *"parsdev"*) echo "ParsDev" ;;
        *"kargadan"*) echo "Kargadan" ;;
        *"hyperclouds"*) echo "HyperClouds" ;;
        *"dimit"*) echo "Dimit Cloud" ;;
        *"pars.host"*) echo "Pars.host" ;;
        *"0-1.ir"*) echo "Sefroyek Pardaz" ;;
        *"hetzner"*) echo "Hetzner Cloud" ;;
        *"ovh"*) echo "OVH Cloud" ;;
        *"digitalocean"*) echo "DigitalOcean" ;;
        *"leaseweb"*) echo "LeaseWeb" ;;
        *"de.archive.ubuntu.com"*) echo "Ubuntu Germany" ;;
        *"nl.archive.ubuntu.com"*) echo "Ubuntu Netherlands" ;;
        *"fr.archive.ubuntu.com"*) echo "Ubuntu France" ;;
        *"gb.archive.ubuntu.com"*) echo "Ubuntu UK" ;;
        *"us.archive.ubuntu.com"*) echo "Ubuntu USA" ;;
        *"tr.archive.ubuntu.com"*) echo "Ubuntu Turkey" ;;
        *"fi.archive.ubuntu.com"*) echo "Ubuntu Finland" ;;
        *"se.archive.ubuntu.com"*) echo "Ubuntu Sweden" ;;
        *"at.archive.ubuntu.com"*) echo "Ubuntu Austria" ;;
        *)
            local host="$(echo "$url" | awk -F'[/:]' '{print $4}')"
            echo "${host:-Default}"
            ;;
    esac
}

get_dns_ips() {
    local dns_list=()
    if command -v resolvectl >/dev/null 2>&1; then
        while read -r ip; do
            [[ -n "$ip" ]] && dns_list+=("$ip")
        done < <(
            resolvectl dns 2>/dev/null |
            awk -F': ' '{print $2}' |
            tr ' ' '\n' |
            grep -E '^[0-9a-fA-F:.]+$' |
            grep -v '^127\.' |
            head -n 2
        )
    fi

    if [[ ${#dns_list[@]} -eq 0 && -f /etc/resolv.conf ]]; then
        while read -r ip; do
            [[ -n "$ip" ]] && dns_list+=("$ip")
        done < <(
            awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf |
            grep -v '^127\.' |
            head -n 2
        )
    fi
    echo "${dns_list[0]:-None} ${dns_list[1]:-None}"
}

# ----------------------------------------------------------
# Solid (Filled) MDesign ASCII Header
# ----------------------------------------------------------

show_header() {
    clear
    local current_mirror_url="$(get_active_mirror_url)"
    local current_mirror_name="$(get_mirror_display_name "$current_mirror_url")"
    read -r DNS1 DNS2 <<< "$(get_dns_ips)"
    local server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    server_ip="${server_ip:-127.0.0.1}"

    echo ""
    echo -e "${C_CYAN}${C_BOLD}"
    cat << "EOF"
   ███    ███ ██ ██████  ██████   ██████  ██████      ██████  ██████  ████████ ██ ███    ███ ██ ███████ ███████ ██████  
   ████  ████ ██ ██   ██ ██   ██ ██    ██ ██   ██    ██    ██ ██   ██    ██    ██ ████  ████ ██    ███  ██      ██   ██ 
   ██ ████ ██ ██ ██████  ██████  ██    ██ ██████     ██    ██ ██████     ██    ██ ██ ████ ██ ██   ███   █████   ██████  
   ██  ██  ██ ██ ██   ██ ██   ██ ██    ██ ██   ██    ██    ██ ██         ██    ██ ██  ██  ██ ██  ███    ██      ██   ██ 
   ██      ██ ██ ██   ██ ██   ██  ██████  ██   ██     ██████  ██         ██    ██ ██      ██ ██ ███████ ███████ ██   ██ 
EOF
    echo -e "${C_RESET}"
    echo ""
    echo -e "   ${C_WHITE}${C_BOLD}Network Core v8.8.0${C_RESET}  ${C_LINE}│${C_RESET}  ${C_CYAN}IP:${C_RESET} ${C_RED}${server_ip}${C_RESET}  ${C_LINE}│${C_RESET}  ${C_CYAN}OS:${C_RESET} ${C_WHITE}Ubuntu ${UBUNTU_RELEASE} (${UBUNTU_CODENAME})${C_RESET}"
    echo ""
    echo -e "   ${C_LINE}────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo ""
    echo -e "   ${C_CYAN}Mirror:${C_RESET} ${C_WHITE}${C_BOLD}${current_mirror_name}${C_RESET} ${C_GRAY}(${current_mirror_url})${C_RESET}"
    echo -e "   ${C_CYAN}DNS:${C_RESET}    ${C_GREEN}●${C_RESET} ${C_GRAY}Pri:${C_RESET} ${C_RED}${DNS1}${C_RESET}   ${C_GREEN}●${C_RESET} ${C_GRAY}Sec:${C_RESET} ${C_RED}${DNS2}${C_RESET}"
    echo ""
    echo -e "   ${C_LINE}────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo ""
}

# ----------------------------------------------------------
# Single-Line Progress Bar Engine
# ----------------------------------------------------------

render_progress_bar() {
    local cur=$1
    local total=$2
    local label="$3"
    local bar_len=26
    local percent=$(( cur * 100 / total ))
    local filled=$(( cur * bar_len / total ))
    local empty=$(( bar_len - filled ))

    local bar_str=""
    for ((i=0; i<filled; i++)); do bar_str+="█"; done
    for ((i=0; i<empty; i++)); do bar_str+="░"; done

    printf "\r   ${C_CYAN}›${C_RESET} %-36s ${C_LINE}[${C_GREEN}%s${C_LINE}]${C_RESET} ${C_BOLD}%3d%%${C_RESET}" "$label" "$bar_str" "$percent"
}

# ----------------------------------------------------------
# System DNS & Mirror Deployment Helpers
# ----------------------------------------------------------

apply_system_dns() {
    local p1="$1"
    local p2="$2"

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/mtunnel_dns.conf <<EOF
[Resolve]
DNS=${p1} ${p2}
FallbackDNS=1.1.1.1 8.8.8.8
EOF
        systemctl restart systemd-resolved 2>/dev/null || true
    else
        [[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
        cat > /etc/resolv.conf <<EOF
nameserver ${p1}
nameserver ${p2}
EOF
    fi
}

apply_system_mirror() {
    local mirror_url="$1"
    local backup_dir="/etc/apt/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"

    if [[ -f "/etc/apt/sources.list.d/ubuntu.sources" ]]; then
        cp /etc/apt/sources.list.d/ubuntu.sources "$backup_dir/" 2>/dev/null || true
        cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: ${mirror_url}
Suites: ${UBUNTU_CODENAME} ${UBUNTU_CODENAME}-updates ${UBUNTU_CODENAME}-backports ${UBUNTU_CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    else
        [[ -f "/etc/apt/sources.list" ]] && cp /etc/apt/sources.list "$backup_dir/" 2>/dev/null || true
        cat > /etc/apt/sources.list <<EOF
deb ${mirror_url} ${UBUNTU_CODENAME} main restricted universe multiverse
deb ${mirror_url} ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb ${mirror_url} ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb ${mirror_url} ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
    fi
    apt-get update -qq >/dev/null 2>&1 || true
}

# ==========================================================
# Manual Benchmark Engines (With 0 Option)
# ==========================================================

run_dns_benchmark() {
    local scope_title="$1"
    shift
    local DNS_PROVIDERS=("$@")

    show_header
    echo -e "   ${C_WHITE}${C_BOLD}DNS BENCHMARK (${scope_title})${C_RESET}"
    echo ""

    declare -A PROVIDER_LATENCY=()
    declare -A PROVIDER_P1=()
    declare -A PROVIDER_P2=()

    local entry name ip1 ip2 T1 T2 AVG_TIME

    for entry in "${DNS_PROVIDERS[@]}"; do
        IFS='|' read -r name ip1 ip2 <<< "$entry"
        printf "     ${C_CYAN}›${C_RESET} %-20s %-34s " "$name" "(${ip1}, ${ip2})"

        T1="$(dig @"$ip1" google.com +time=2 +tries=1 +stats 2>/dev/null | awk '/Query time:/ {print $4; exit}')"
        T2="$(dig @"$ip2" google.com +time=2 +tries=1 +stats 2>/dev/null | awk '/Query time:/ {print $4; exit}')"

        if [[ "$T1" =~ ^[0-9]+([.][0-9]+)?$ && "$T2" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            AVG_TIME="$(echo "scale=1; ($T1 + $T2) / 2" | bc 2>/dev/null)"
            [[ -z "$AVG_TIME" ]] && AVG_TIME="$T1"
            echo -e "${C_GREEN}${AVG_TIME} ms${C_RESET}"
            PROVIDER_LATENCY["$name"]="$AVG_TIME"
            PROVIDER_P1["$name"]="$ip1"
            PROVIDER_P2["$name"]="$ip2"
        elif [[ "$T1" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo -e "${C_GREEN}${T1} ms${C_RESET}"
            PROVIDER_LATENCY["$name"]="$T1"
            PROVIDER_P1["$name"]="$ip1"
            PROVIDER_P2["$name"]="$ip1"
        elif [[ "$T2" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo -e "${C_GREEN}${T2} ms${C_RESET}"
            PROVIDER_LATENCY["$name"]="$T2"
            PROVIDER_P1["$name"]="$ip2"
            PROVIDER_P2["$name"]="$ip2"
        else
            echo -e "${C_RED}Timeout${C_RESET}"
        fi
    done

    mapfile -t SORTED_NAMES < <(
        for name in "${!PROVIDER_LATENCY[@]}"; do
            echo "${PROVIDER_LATENCY[$name]}|$name"
        done | sort -n -t'|' -k1,1 | cut -d'|' -f2-
    )

    if [[ ${#SORTED_NAMES[@]} -eq 0 ]]; then
        echo -e "\n   ${C_RED}[!] No DNS servers responded.${C_RESET}"
        return 1
    fi

    show_header
    local best_name="${SORTED_NAMES[0]}"
    local best_ips="(${PROVIDER_P1[$best_name]}, ${PROVIDER_P2[$best_name]})"

    echo -e "   ${C_WHITE}${C_BOLD}SELECT DNS NETWORK (${scope_title})${C_RESET}"
    echo ""
    printf "     ${C_GREEN}${C_BOLD}1 ›${C_RESET} ${C_GREEN}%-18s %-34s (%s ms) [Default]${C_RESET}\n" "$best_name" "$best_ips" "${PROVIDER_LATENCY[$best_name]}"

    local idx=2
    declare -A MENU_MAP=()
    MENU_MAP[1]="$best_name"

    local dns_name
    for dns_name in "${SORTED_NAMES[@]}"; do
        [[ "$dns_name" == "$best_name" ]] && continue
        local ips="(${PROVIDER_P1[$dns_name]}, ${PROVIDER_P2[$dns_name]})"
        printf "     ${C_WHITE}${C_BOLD}%d${C_RESET} ${C_CYAN}›${C_RESET} %-18s %-34s (${C_GREEN}%s ms${C_RESET})\n" "$idx" "$dns_name" "$ips" "${PROVIDER_LATENCY[$dns_name]}"
        MENU_MAP[$idx]="$dns_name"
        ((idx++))
    done

    echo ""
    printf "     ${C_WHITE}${C_BOLD}0${C_RESET} ${C_CYAN}›${C_RESET} ${C_RED}Back to Main Menu${C_RESET}\n"
    echo ""
    echo -ne "   ${C_CYAN}${C_BOLD}DNS >> ${C_RESET}"
    read -r dns_choice

    [[ -z "$dns_choice" ]] && dns_choice=1
    [[ "$dns_choice" == "0" ]] && return 0

    local SELECTED_NAME="${MENU_MAP[$dns_choice]:-$best_name}"
    local SELECTED_DNS1="${PROVIDER_P1[$SELECTED_NAME]}"
    local SELECTED_DNS2="${PROVIDER_P2[$SELECTED_NAME]}"

    echo ""
    echo -e "   ${C_GREEN}[✓] Setting DNS to [${SELECTED_NAME}]...${C_RESET}"
    apply_system_dns "$SELECTED_DNS1" "$SELECTED_DNS2"
    echo -e "   ${C_GREEN}[✓] Applied: ${SELECTED_DNS1} / ${SELECTED_DNS2}${C_RESET}\n"
    return 2
}

run_mirror_benchmark() {
    local scope_title="$1"
    shift
    local MIRRORS_DATA=("$@")

    show_header
    echo -e "   ${C_WHITE}${C_BOLD}APT MIRROR BENCHMARK (${scope_title})${C_RESET}"
    echo ""

    declare -A MIRROR_SPEEDS=()
    declare -A MIRROR_DISPLAY_SPEEDS=()
    declare -A MIRROR_NAMES=()

    local entry display_name mirror_url test_file SPEED_BPS SPEED_BPS_CLEAN SPEED_KB SPEED_MBPS SPEED_MB SPEED_TXT

    for entry in "${MIRRORS_DATA[@]}"; do
        IFS='|' read -r display_name mirror_url <<< "$entry"
        mirror_url="${mirror_url%/}"
        test_file="${mirror_url}/dists/${UBUNTU_CODENAME}/Release"

        printf "     ${C_CYAN}›${C_RESET} %-23s %-48s " "$display_name" "(${mirror_url})"

        SPEED_BPS="$(curl -s -k -L --connect-timeout 2 -m 5 -o /dev/null -w "%{speed_download}" "$test_file" 2>/dev/null)"
        SPEED_BPS_CLEAN="$(printf "%.0f" "${SPEED_BPS:-0}" 2>/dev/null || echo "0")"

        if [[ "$SPEED_BPS_CLEAN" =~ ^[0-9]+$ && "$SPEED_BPS_CLEAN" -gt 0 ]]; then
            SPEED_KB="$(echo "scale=1; $SPEED_BPS_CLEAN / 1024" | bc 2>/dev/null || echo "0")"
            SPEED_MBPS="$(echo "scale=2; ($SPEED_BPS_CLEAN * 8) / 1000000" | bc 2>/dev/null || echo "0")"

            if (( $(echo "$SPEED_KB > 1024" | bc -l 2>/dev/null || echo 0) )); then
                SPEED_MB="$(echo "scale=2; $SPEED_KB / 1024" | bc 2>/dev/null)"
                SPEED_TXT="${SPEED_MB} MB/s (${SPEED_MBPS} Mbps)"
            else
                SPEED_TXT="${SPEED_KB} KB/s (${SPEED_MBPS} Mbps)"
            fi
            echo -e "${C_GREEN}${SPEED_TXT}${C_RESET}"
            MIRROR_SPEEDS["$mirror_url"]="$SPEED_BPS_CLEAN"
            MIRROR_DISPLAY_SPEEDS["$mirror_url"]="$SPEED_TXT"
            MIRROR_NAMES["$mirror_url"]="$display_name"
        else
            echo -e "${C_RED}Unreachable${C_RESET}"
        fi
    done

    mapfile -t SORTED_MIRRORS < <(
        for mirror in "${!MIRROR_SPEEDS[@]}"; do
            echo "${MIRROR_SPEEDS[$mirror]}|$mirror"
        done | sort -rn -t'|' -k1,1 | cut -d'|' -f2-
    )

    if [[ ${#SORTED_MIRRORS[@]} -eq 0 ]]; then
        echo -e "\n   ${C_RED}[!] No responsive mirrors found.${C_RESET}"
        return 1
    fi

    show_header
    local best_url="${SORTED_MIRRORS[0]}"
    local best_url_fmt="(${best_url})"

    echo -e "   ${C_WHITE}${C_BOLD}SELECT APT MIRROR (${scope_title})${C_RESET}"
    echo ""
    printf "     ${C_GREEN}${C_BOLD}1 ›${C_RESET} ${C_GREEN}%-23s %-48s (%s) [Default]${C_RESET}\n" "${MIRROR_NAMES[$best_url]}" "$best_url_fmt" "${MIRROR_DISPLAY_SPEEDS[$best_url]}"

    local idx=2
    declare -A MIRROR_MENU_MAP=()
    MIRROR_MENU_MAP[1]="$best_url"

    local m
    for m in "${SORTED_MIRRORS[@]}"; do
        [[ "$m" == "$best_url" ]] && continue
        printf "     ${C_WHITE}${C_BOLD}%d${C_RESET} ${C_CYAN}›${C_RESET} %-23s %-48s (${C_GREEN}%s${C_RESET})\n" "$idx" "${MIRROR_NAMES[$m]}" "(${m})" "${MIRROR_DISPLAY_SPEEDS[$m]}"
        MIRROR_MENU_MAP[$idx]="$m"
        ((idx++))
    done

    echo ""
    printf "     ${C_WHITE}${C_BOLD}0${C_RESET} ${C_CYAN}›${C_RESET} ${C_RED}Back to Main Menu${C_RESET}\n"
    echo ""
    echo -ne "   ${C_CYAN}${C_BOLD}MIRROR >> ${C_RESET}"
    read -r mirror_choice

    [[ -z "$mirror_choice" ]] && mirror_choice=1
    [[ "$mirror_choice" == "0" ]] && return 0

    local SELECTED_MIRROR="${MIRROR_MENU_MAP[$mirror_choice]:-$best_url}"

    echo ""
    echo -e "   ${C_GREEN}[✓] Deploying Mirror: ${MIRROR_NAMES[$SELECTED_MIRROR]} -> ${SELECTED_MIRROR}${C_RESET}"
    apply_system_mirror "$SELECTED_MIRROR"
    echo -e "   ${C_GREEN}[✓] APT cache updated successfully!${C_RESET}\n"
    return 2
}

# ==========================================================
# Automated Auto-Pilot (Progress Bar Driven, No Prompts)
# ==========================================================

run_auto_pilot() {
    local profile_title="$1"
    local -n dns_list_ref=$2
    local -n mirror_list_ref=$3

    show_header
    echo -e "   ${C_WHITE}${C_BOLD}AUTO-PILOT OPTIMIZATION (${profile_title})${C_RESET}"
    echo ""

    # Phase 1: DNS Benchmarking
    local total_dns=${#dns_list_ref[@]}
    local cur_dns=0
    declare -A AUTO_DNS_LATENCY=()
    declare -A AUTO_DNS_P1=()
    declare -A AUTO_DNS_P2=()

    render_progress_bar 0 "$total_dns" "Measuring DNS Latencies..."

    for entry in "${dns_list_ref[@]}"; do
        ((cur_dns++))
        IFS='|' read -r name ip1 ip2 <<< "$entry"

        T1="$(dig @"$ip1" google.com +time=2 +tries=1 +stats 2>/dev/null | awk '/Query time:/ {print $4; exit}')"
        T2="$(dig @"$ip2" google.com +time=2 +tries=1 +stats 2>/dev/null | awk '/Query time:/ {print $4; exit}')"

        if [[ "$T1" =~ ^[0-9]+([.][0-9]+)?$ && "$T2" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            AVG_TIME="$(echo "scale=1; ($T1 + $T2) / 2" | bc 2>/dev/null)"
            [[ -z "$AVG_TIME" ]] && AVG_TIME="$T1"
            AUTO_DNS_LATENCY["$name"]="$AVG_TIME"
            AUTO_DNS_P1["$name"]="$ip1"
            AUTO_DNS_P2["$name"]="$ip2"
        elif [[ "$T1" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            AUTO_DNS_LATENCY["$name"]="$T1"
            AUTO_DNS_P1["$name"]="$ip1"
            AUTO_DNS_P2["$name"]="$ip1"
        elif [[ "$T2" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            AUTO_DNS_LATENCY["$name"]="$T2"
            AUTO_DNS_P1["$name"]="$ip2"
            AUTO_DNS_P2["$name"]="$ip2"
        fi

        render_progress_bar "$cur_dns" "$total_dns" "Selecting Fastest DNS..."
    done

    mapfile -t SORTED_AUTO_DNS < <(
        for name in "${!AUTO_DNS_LATENCY[@]}"; do
            echo "${AUTO_DNS_LATENCY[$name]}|$name"
        done | sort -n -t'|' -k1,1 | cut -d'|' -f2-
    )

    local best_dns_name="${SORTED_AUTO_DNS[0]:-None}"
    if [[ "$best_dns_name" != "None" ]]; then
        apply_system_dns "${AUTO_DNS_P1[$best_dns_name]}" "${AUTO_DNS_P2[$best_dns_name]}"
        printf "\r   ${C_GREEN}[✓] Applied Fastest DNS:${C_RESET} ${C_WHITE}%-16s${C_RESET} (${C_CYAN}%s ms${C_RESET}) [%s, %s]                    \n\n" \
            "$best_dns_name" "${AUTO_DNS_LATENCY[$best_dns_name]}" "${AUTO_DNS_P1[$best_dns_name]}" "${AUTO_DNS_P2[$best_dns_name]}"
    else
        printf "\r   ${C_RED}[!] DNS benchmark timed out. Skipped DNS configuration.${C_RESET}                                      \n\n"
    fi

    # Phase 2: APT Mirror Benchmarking
    local total_mirrors=${#mirror_list_ref[@]}
    local cur_mirror=0
    declare -A AUTO_MIRROR_SPEEDS=()
    declare -A AUTO_MIRROR_NAMES=()
    declare -A AUTO_MIRROR_TXT=()

    render_progress_bar 0 "$total_mirrors" "Testing APT Mirror Speeds..."

    for entry in "${mirror_list_ref[@]}"; do
        ((cur_mirror++))
        IFS='|' read -r display_name mirror_url <<< "$entry"
        mirror_url="${mirror_url%/}"
        test_file="${mirror_url}/dists/${UBUNTU_CODENAME}/Release"

        SPEED_BPS="$(curl -s -k -L --connect-timeout 2 -m 5 -o /dev/null -w "%{speed_download}" "$test_file" 2>/dev/null)"
        SPEED_BPS_CLEAN="$(printf "%.0f" "${SPEED_BPS:-0}" 2>/dev/null || echo "0")"

        if [[ "$SPEED_BPS_CLEAN" =~ ^[0-9]+$ && "$SPEED_BPS_CLEAN" -gt 0 ]]; then
            SPEED_KB="$(echo "scale=1; $SPEED_BPS_CLEAN / 1024" | bc 2>/dev/null || echo "0")"
            SPEED_MBPS="$(echo "scale=2; ($SPEED_BPS_CLEAN * 8) / 1000000" | bc 2>/dev/null || echo "0")"

            if (( $(echo "$SPEED_KB > 1024" | bc -l 2>/dev/null || echo 0) )); then
                SPEED_MB="$(echo "scale=2; $SPEED_KB / 1024" | bc 2>/dev/null)"
                SPEED_TXT="${SPEED_MB} MB/s (${SPEED_MBPS} Mbps)"
            else
                SPEED_TXT="${SPEED_KB} KB/s (${SPEED_MBPS} Mbps)"
            fi

            AUTO_MIRROR_SPEEDS["$mirror_url"]="$SPEED_BPS_CLEAN"
            AUTO_MIRROR_NAMES["$mirror_url"]="$display_name"
            AUTO_MIRROR_TXT["$mirror_url"]="$SPEED_TXT"
        fi

        render_progress_bar "$cur_mirror" "$total_mirrors" "Selecting Fastest Mirror..."
    done

    mapfile -t SORTED_AUTO_MIRRORS < <(
        for mirror in "${!AUTO_MIRROR_SPEEDS[@]}"; do
            echo "${AUTO_MIRROR_SPEEDS[$mirror]}|$mirror"
        done | sort -rn -t'|' -k1,1 | cut -d'|' -f2-
    )

    local best_mirror_url="${SORTED_AUTO_MIRRORS[0]:-None}"
    if [[ "$best_mirror_url" != "None" ]]; then
        apply_system_mirror "$best_mirror_url"
        printf "\r   ${C_GREEN}[✓] Deployed Fastest Mirror:${C_RESET} ${C_WHITE}%-16s${C_RESET} (${C_CYAN}%s${C_RESET}) -> %s                    \n\n" \
            "${AUTO_MIRROR_NAMES[$best_mirror_url]}" "${AUTO_MIRROR_TXT[$best_mirror_url]}" "$best_mirror_url"
        echo -e "   ${C_GREEN}[✓] System optimization completed successfully!${C_RESET}\n"
    else
        printf "\r   ${C_RED}[!] No responsive mirrors found. Kept original APT configuration.${C_RESET}                             \n\n"
    fi
}

# ==========================================================
# Data Definitions
# ==========================================================

IRAN_DNS_SERVERS=(
    "TIC (Zirsakht)|217.218.127.127|217.218.155.155"
    "Pishgaman|5.202.100.100|5.202.100.101"
    "Shecan|178.22.122.100|185.51.200.2"
    "Electro|78.157.42.100|78.157.42.101"
    "403.online|10.202.10.202|10.202.10.102"
    "RadarGame|10.202.10.10|10.202.10.11"
    "Hostiran|172.29.0.100|172.29.2.100"
)

GLOBAL_DNS_SERVERS=(
    "Cloudflare|1.1.1.1|1.0.0.1"
    "Google|8.8.8.8|8.8.4.4"
    "Quad9 (Secured)|9.9.9.9|149.112.112.112"
    "Cisco OpenDNS|208.67.222.222|208.67.220.220"
    "AdGuard DNS|94.140.14.14|94.140.15.15"
    "Control D|76.76.2.0|76.76.10.0"
    "DNS.WATCH|84.200.69.80|84.200.70.40"
    "Comodo Secure|8.26.56.26|8.20.247.20"
)

IRAN_MIRRORS_LIST=(
    "Asiatech|https://mirror.cdn.ir/ubuntu"
    "LinuxMirrors|https://linuxmirrors.ir"
    "Shatel|https://mirror.shatel.ir"
    "Pishgaman|https://ubuntu.pishgaman.net"
    "ArvanCloud|https://mirror.arvancloud.ir/ubuntu"
    "IranServer|https://mirror.iranserver.com/ubuntu"
    "AminiDC|http://mirror.aminidc.com/ubuntu"
    "KimiaHost|https://ubuntu-mirror.kimiahost.com"
    "DigitalVPS|https://mirror.digitalvps.ir/ubuntu"
    "Sindad|https://ir.ubuntu.sindad.cloud/ubuntu"
    "Petiak|https://archive.ubuntu.petiak.ir"
    "0-1 Cloud|https://mirror.0-1.cloud/ubuntu"
    "ManageIT|https://mirror.manageit.ir/ubuntu"
    "MobinHost|https://mirror.mobinhost.com/ubuntu"
    "Afranet|http://mirror.afranet.com/ubuntu"
    "Liara|https://linux-mirror.liara.ir"
    "AtlantisCloud|https://mirror.atlantiscloud.ir"
    "Chabokan|https://mirror2.chabokan.net"
    "Abrha|https://repo.abrha.net"
    "ParsDev|https://mirror.parsDev.com"
    "Kargadan|https://mirror.kargadan.ir"
    "HyperClouds|https://mirror.hyperclouds.ir"
    "Dimit Cloud|https://mirrors.ubuntu.dimit.cloud"
    "Pars.host|https://ubuntu.pars.host"
    "Sefroyek Pardaz|https://mirror.0-1.ir"
    "IUT|http://repo.iut.ac.ir/repo/Ubuntu"
    "Sharif University|http://mirrors.sharif.ir/ubuntu"
    "University of Tehran|http://mirror.ut.ac.ir/ubuntu"
    "Ubuntu Iran|https://ir.archive.ubuntu.com/ubuntu"
)

GLOBAL_MIRRORS_LIST=(
    "Hetzner (Germany/EU)|https://mirror.hetzner.com/ubuntu/packages"
    "OVH (Europe)|http://mirrors.ovh.net/ubuntu"
    "DigitalOcean|http://mirrors.digitalocean.com/ubuntu"
    "LeaseWeb (Global)|http://mirror.leaseweb.com/ubuntu"
    "Ubuntu Germany (DE)|http://de.archive.ubuntu.com/ubuntu"
    "Ubuntu Netherlands (NL)|http://nl.archive.ubuntu.com/ubuntu"
    "Ubuntu France (FR)|http://fr.archive.ubuntu.com/ubuntu"
    "Ubuntu UK (GB)|http://gb.archive.ubuntu.com/ubuntu"
    "Ubuntu USA (US)|http://us.archive.ubuntu.com/ubuntu"
    "Ubuntu Turkey (TR)|http://tr.archive.ubuntu.com/ubuntu"
    "Ubuntu Finland (FI)|http://fi.archive.ubuntu.com/ubuntu"
    "Ubuntu Sweden (SE)|http://se.archive.ubuntu.com/ubuntu"
    "Ubuntu Austria (AT)|http://at.archive.ubuntu.com/ubuntu"
    "Ubuntu Official Main|http://archive.ubuntu.com/ubuntu"
    "Ubuntu Official HTTPS|https://archive.ubuntu.com/ubuntu"
)

# ==========================================================
# Main Menu Loop
# ==========================================================

while true; do
    show_header

    echo -e "   ${C_WHITE}${C_BOLD}CORE NETWORK & OPTIMIZATION (IRAN SERVERS)${C_RESET}"
    echo ""
    echo -e "     ${C_WHITE}${C_BOLD}1${C_RESET} ${C_CYAN}›${C_RESET} ${C_CYAN}Iran DNS Resolver Hub (Latency Benchmark & Switcher)${C_RESET}"
    echo -e "     ${C_WHITE}${C_BOLD}2${C_RESET} ${C_CYAN}›${C_RESET} ${C_MAGENTA}Iran APT Repository Matrix (Speed Benchmark & Auto Mirror)${C_RESET}"
    echo -e "     ${C_WHITE}${C_BOLD}3${C_RESET} ${C_CYAN}›${C_RESET} ${C_ORANGE}Full Auto-Pilot Optimization (Iran DNS + Mirror Sync)${C_RESET}"
    echo ""
    echo -e "   ${C_WHITE}${C_BOLD}CORE NETWORK & OPTIMIZATION (GLOBAL SERVERS)${C_RESET}"
    echo ""
    echo -e "     ${C_WHITE}${C_BOLD}4${C_RESET} ${C_CYAN}›${C_RESET} ${C_CYAN}Global DNS Resolver Hub (International Latency Benchmark)${C_RESET}"
    echo -e "     ${C_WHITE}${C_BOLD}5${C_RESET} ${C_CYAN}›${C_RESET} ${C_MAGENTA}Global APT Repository Matrix (International Speed Benchmark)${C_RESET}"
    echo -e "     ${C_WHITE}${C_BOLD}6${C_RESET} ${C_CYAN}›${C_RESET} ${C_ORANGE}Full Auto-Pilot Optimization (Global DNS + Mirror Sync)${C_RESET}"
    echo ""
    echo -e "   ${C_LINE}────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo ""
    echo -e "   ${C_WHITE}${C_BOLD}SYSTEM OPERATIONS${C_RESET}"
    echo ""
    echo -e "     ${C_WHITE}${C_BOLD}0${C_RESET} ${C_CYAN}›${C_RESET} ${C_RED}Exit Terminal${C_RESET}"
    echo ""
    echo -e "   ${C_LINE}────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo ""
    echo -ne "   ${C_CYAN}${C_BOLD}CORE >> ${C_RESET}"
    read -r choice

    case "$choice" in
        1)
            run_dns_benchmark "IRAN" "${IRAN_DNS_SERVERS[@]}"
            ret=$?
            if [[ $ret -eq 2 ]]; then
                echo ""
                read -r -p "   Press Enter to return to menu..."
            fi
            ;;
        2)
            run_mirror_benchmark "IRAN" "${IRAN_MIRRORS_LIST[@]}"
            ret=$?
            if [[ $ret -eq 2 ]]; then
                echo ""
                read -r -p "   Press Enter to return to menu..."
            fi
            ;;
        3)
            run_auto_pilot "IRAN" IRAN_DNS_SERVERS IRAN_MIRRORS_LIST
            echo ""
            read -r -p "   Press Enter to return to menu..."
            ;;
        4)
            run_dns_benchmark "GLOBAL" "${GLOBAL_DNS_SERVERS[@]}"
            ret=$?
            if [[ $ret -eq 2 ]]; then
                echo ""
                read -r -p "   Press Enter to return to menu..."
            fi
            ;;
        5)
            run_mirror_benchmark "GLOBAL" "${GLOBAL_MIRRORS_LIST[@]}"
            ret=$?
            if [[ $ret -eq 2 ]]; then
                echo ""
                read -r -p "   Press Enter to return to menu..."
            fi
            ;;
        6)
            run_auto_pilot "GLOBAL" GLOBAL_DNS_SERVERS GLOBAL_MIRRORS_LIST
            echo ""
            read -r -p "   Press Enter to return to menu..."
            ;;
        0)
            echo ""
            echo -e "   ${C_CYAN}[*] Exiting MDesign Optimizer.${C_RESET}"
            echo ""
            exit 0
            ;;
        *)
            echo -e "   ${C_RED}Invalid option.${C_RESET}"
            sleep 1
            ;;
    esac
done