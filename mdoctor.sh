#!/bin/bash
# --- MTunnel Doctor | System Diagnostics v1.2.1 ---
# [Features: Full Health Scan | Network/IPv6 | Firewall/Ports | Core & Script Health | Safe Repair | Export Report]
MODULE_VERSION="1.2.1"
MTUNNEL_REQUIRED_CORE_API=1
MTUNNEL_REQUIRED_LAYOUT_REV=2
umask 077

# MTUNNEL_COMMON_LOADER -- common API 1, required by this module.
mt_load_common() {
    local script_dir candidate
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    for candidate in \
        "$script_dir/../core/common.sh" \
        "$script_dir/core/common.sh" \
        /usr/lib/mtunnel/common.sh \
        /root/mtunnel/core/common.sh; do
        if [[ -f "$candidate" && -r "$candidate" ]]; then
            source "$candidate" || return 1
            if [[ "${MTUNNEL_CORE_API:-}" == "${MTUNNEL_REQUIRED_CORE_API:-1}" && "${MTUNNEL_LAYOUT_REV:-}" == "${MTUNNEL_REQUIRED_LAYOUT_REV:-2}" ]]; then return 0; fi
            printf 'MTunnel Doctor: incompatible shared core: %s\n' "$candidate" >&2
            return 1
        fi
    done
    echo 'MTunnel Doctor: core/common.sh is missing. Reinstall the complete bundle.' >&2
    return 1
}
mt_load_common || exit 1
unset -f mt_load_common
if [ "$EUID" != 0 ]; then echo "Run MTunnel Doctor with sudo." >&2; exit 1; fi

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
REPORT_DIR="$LOCAL_DIR/reports"
mkdir -p "$SECURE_TMP" "$REPORT_DIR" 2>/dev/null
chmod 700 "$SECURE_TMP" "$REPORT_DIR" 2>/dev/null || true

DOC_PASS=0
DOC_WARN=0
DOC_FAIL=0
DOC_TOTAL=0
DOC_LAST_SUMMARY="Not scanned"
DOC_LAST_COLOR="$DIM"
DOC_PLAIN=0

_doc_color() { [ "$DOC_PLAIN" = 1 ] && printf '' || printf '%b' "$1"; }
_doc_reset() { [ "$DOC_PLAIN" = 1 ] && printf '' || printf '%b' "$NC"; }
_doc_icon() {
    case "$1" in
        PASS) printf '✔';;
        WARN) printf '⚠';;
        FAIL) printf '✖';;
        INFO) printf '●';;
        *) printf '·';;
    esac
}
_doc_status_color() {
    case "$1" in PASS) printf '%b' "$G";; WARN) printf '%b' "$Y";; FAIL) printf '%b' "$R";; INFO) printf '%b' "$C";; *) printf '%b' "$DIM";; esac
}

doc_reset_counts() { DOC_PASS=0; DOC_WARN=0; DOC_FAIL=0; DOC_TOTAL=0; }
doc_count() {
    case "$1" in
        PASS) DOC_PASS=$((DOC_PASS+1)); DOC_TOTAL=$((DOC_TOTAL+1));;
        WARN) DOC_WARN=$((DOC_WARN+1)); DOC_TOTAL=$((DOC_TOTAL+1));;
        FAIL) DOC_FAIL=$((DOC_FAIL+1)); DOC_TOTAL=$((DOC_TOTAL+1));;
    esac
}

doc_group() {
    local title="$1"
    if [ "$DOC_PLAIN" = 1 ]; then
        printf '\n[%s]\n' "$title"
    else
        printf '\n  %b┌─[ %s ]%b\n' "$DIM" "$title" "$NC"
        printf '  %b│%b\n' "$DIM" "$NC"
    fi
}

doc_row() {
    local state="$1" label="$2" value="$3" color icon
    doc_count "$state"
    if [ "$DOC_PLAIN" = 1 ]; then
        printf '  %-4s %-27s %s\n' "$state" "$label" "$value"
        return
    fi
    color=$(_doc_status_color "$state"); icon=$(_doc_icon "$state")
    printf '  %b├─%b %b%s%b %-27s %b%s%b\n' "$DIM" "$NC" "$color" "$icon" "$NC" "$label" "$color" "$value" "$NC"
}

doc_info() {
    local label="$1" value="$2"
    if [ "$DOC_PLAIN" = 1 ]; then printf '  INFO %-27s %s\n' "$label" "$value"
    else printf '  %b├─%b %b●%b %-27s %b%s%b\n' "$DIM" "$NC" "$C" "$NC" "$label" "$W" "$value" "$NC"; fi
}

doc_note() {
    if [ "$DOC_PLAIN" = 1 ]; then printf '  NOTE %s\n' "$*"; else printf '  %b│%b  %b%s%b\n' "$DIM" "$NC" "$DIM" "$*" "$NC"; fi
}

doc_footer() {
    [ "$DOC_PLAIN" = 1 ] && return
    printf '  %b└────────────────────────────────────────────────────────────%b\n' "$DIM" "$NC"
}

doc_pause() {
    local _
    [ "$DOC_PLAIN" = 1 ] && return 0
    printf '\n  %bPress Enter to return...%b' "$DIM" "$NC"
    read -r _
}

doc_local_dev() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

doc_default_mtu() {
    local dev; dev=$(doc_local_dev)
    [ -n "$dev" ] || return 1
    ip -o link show dev "$dev" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") {print $(i+1); exit}}'
}

doc_public_source_check() {
    local url="${MTUNNEL_GITHUB_BASE%/}/VERSION" out=''
    if command -v curl >/dev/null 2>&1; then
        out=$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 2 --max-time 5 "$url?t=$(date +%s)" 2>/dev/null | head -c 32 | tr -d '\r\n ')
    elif command -v wget >/dev/null 2>&1; then
        out=$(wget -qO- --https-only --timeout=5 "$url?t=$(date +%s)" 2>/dev/null | head -c 32 | tr -d '\r\n ')
    fi
    [[ "$out" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && { printf '%s' "$out"; return 0; }
    return 1
}

doc_kernel_module_status() {
    local mod="$1"
    if [ -d "/sys/module/$mod" ]; then printf 'loaded'; return 0; fi
    if command -v modprobe >/dev/null 2>&1 && modprobe -n "$mod" >/dev/null 2>&1; then printf 'available'; return 0; fi
    return 1
}

doc_iptables_backend() {
    local v
    v=$(iptables --version 2>/dev/null | head -n1)
    [ -n "$v" ] || return 1
    case "$v" in *nf_tables*) printf 'iptables-nft';; *legacy*) printf 'iptables-legacy';; *) printf '%s' "$v";; esac
}

doc_version_of() {
    sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$1" 2>/dev/null | head -n1
}

doc_script_check() {
    local label="$1" file="$2" version
    if [ ! -f "$file" ]; then doc_row WARN "$label" "not installed"; return; fi
    if ! bash -n "$file" >/dev/null 2>&1; then doc_row FAIL "$label" "syntax error"; return; fi
    version=$(doc_version_of "$file"); [ -n "$version" ] || version='unknown'
    doc_row PASS "$label" "v${version} / syntax OK"
}

doc_os_name() {
    local p='Linux'
    if [ -r /etc/os-release ]; then
        p=$(awk '$0 ~ /^PRETTY_NAME=/{v=substr($0,index($0,"=")+1); gsub(/^"|"$/,"",v); print v; exit}' /etc/os-release)
    fi
    printf '%s' "${p:-Linux}"
}

doc_scan_system() {
    local diskp sync pid1
    doc_group 'SYSTEM HEALTH'
    doc_row PASS 'Operating System' "$(doc_os_name)"
    doc_row PASS 'Kernel' "$(uname -r) / $(uname -m)"
    pid1=$(cat /proc/1/comm 2>/dev/null)
    if [ "$pid1" = systemd ] && command -v systemctl >/dev/null 2>&1; then doc_row PASS 'systemd' 'running as PID 1'; else doc_row FAIL 'systemd' "PID1=${pid1:-unknown}"; fi
    diskp=$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5);print $5}')
    if [[ "$diskp" =~ ^[0-9]+$ ]]; then
        if [ "$diskp" -ge 95 ]; then doc_row FAIL 'Root Disk Usage' "${diskp}% used"
        elif [ "$diskp" -ge 85 ]; then doc_row WARN 'Root Disk Usage' "${diskp}% used"
        else doc_row PASS 'Root Disk Usage' "${diskp}% used"; fi
    else doc_row WARN 'Root Disk Usage' 'unable to read'; fi
    sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [ "$sync" = yes ]; then doc_row PASS 'Clock Synchronization' 'NTP synchronized'; else doc_row WARN 'Clock Synchronization' "NTP=${sync:-unknown}"; fi
    if [ -r /proc/sys/net/ipv4/ip_forward ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ]; then doc_row PASS 'IPv4 Forwarding' 'enabled'; else doc_row FAIL 'IPv4 Forwarding' 'disabled'; fi
    if [ -r /proc/sys/net/ipv6/conf/all/forwarding ]; then
        if [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" = 1 ]; then doc_row PASS 'IPv6 Forwarding' 'enabled';
        elif [ -n "$(mt_local_ipv6 2>/dev/null)" ]; then doc_row WARN 'IPv6 Forwarding' 'disabled'; else doc_row PASS 'IPv6 Forwarding' 'disabled / no global IPv6'; fi
    else doc_row WARN 'IPv6 Forwarding' 'sysctl unavailable'; fi
    doc_footer
}

doc_scan_network() {
    local v4 v6 dev mtu source_v
    doc_group 'NETWORK & IPv6'
    v4=$(mt_local_ipv4 2>/dev/null); v6=$(mt_local_ipv6 2>/dev/null); dev=$(doc_local_dev); mtu=$(doc_default_mtu)
    [ -n "$v4" ] && doc_row PASS 'Local IPv4' "$v4" || doc_row FAIL 'Local IPv4' 'not detected'
    if ip -4 route show default 2>/dev/null | grep -q '^default'; then doc_row PASS 'IPv4 Default Route' "dev ${dev:-unknown}"; else doc_row FAIL 'IPv4 Default Route' 'missing'; fi
    [ -n "$v6" ] && doc_row PASS 'Global IPv6' "$v6" || doc_row WARN 'Global IPv6' 'not detected'
    if ip -6 route show default 2>/dev/null | grep -q '^default'; then doc_row PASS 'IPv6 Default Route' 'present'; elif [ -n "$v6" ]; then doc_row FAIL 'IPv6 Default Route' 'missing'; else doc_row WARN 'IPv6 Default Route' 'not configured'; fi
    if getent ahostsv4 github.com >/dev/null 2>&1; then doc_row PASS 'DNS Resolution' 'github.com resolves'; else doc_row FAIL 'DNS Resolution' 'resolution failed'; fi
    if source_v=$(doc_public_source_check); then doc_row PASS 'Official Source HTTPS' "reachable / v${source_v}"; else doc_row WARN 'Official Source HTTPS' 'unreachable or blocked'; fi
    [ -n "$mtu" ] && doc_row PASS 'Default Interface MTU' "${mtu} on ${dev:-unknown}" || doc_row WARN 'Default Interface MTU' 'unable to read'
    if command -v ping >/dev/null 2>&1 && ping -4 -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then doc_row PASS 'IPv4 Internet Probe' '1.1.1.1 reachable'; else doc_row WARN 'IPv4 Internet Probe' 'ICMP blocked or unreachable'; fi
    if [ -n "$v6" ]; then
        if command -v ping >/dev/null 2>&1 && ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then doc_row PASS 'IPv6 Internet Probe' 'Cloudflare IPv6 reachable'; else doc_row WARN 'IPv6 Internet Probe' 'ICMPv6 blocked or unreachable'; fi
    fi
    doc_footer
}

doc_scan_kernel() {
    local s
    doc_group 'TUNNEL KERNEL SUPPORT'
    for s in 'ip_gre|GRE / GRE6' 'ipip|IPIP' 'vxlan|VXLAN' 'xfrm_user|XFRM / IPsec'; do
        local mod="${s%%|*}" label="${s#*|}" state
        if state=$(doc_kernel_module_status "$mod"); then doc_row PASS "$label" "$mod $state"; else doc_row FAIL "$label" "$mod unavailable"; fi
    done
    if ip xfrm state >/dev/null 2>&1; then doc_row PASS 'XFRM Userspace' 'ip xfrm operational'; else doc_row WARN 'XFRM Userspace' 'xfrm query failed'; fi
    doc_footer
}

doc_scan_firewall() {
    local backend listeners mt_rules=0 ufw_state='inactive' fw_state='inactive'
    doc_group 'FIREWALL & PORTS'
    if backend=$(doc_iptables_backend); then doc_row PASS 'iptables Backend' "$backend"; else doc_row FAIL 'iptables Backend' 'not available'; fi
    if command -v nft >/dev/null 2>&1; then doc_row PASS 'nftables Tooling' "$(nft --version 2>/dev/null | head -n1)"; else doc_row WARN 'nftables Tooling' 'nft command missing'; fi
    if command -v ufw >/dev/null 2>&1; then ufw_state=$(ufw status 2>/dev/null | awk 'NR==1{print tolower($2)}'); fi
    if [ "$ufw_state" = active ]; then doc_row WARN 'UFW' 'active — verify MTunnel rules are permitted'; else doc_row PASS 'UFW' "${ufw_state:-inactive}"; fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then fw_state='active'; fi
    if [ "$fw_state" = active ]; then doc_row WARN 'firewalld' 'active — verify MTunnel zones/rules'; else doc_row PASS 'firewalld' 'inactive/not installed'; fi
    if command -v ss >/dev/null 2>&1; then
        listeners=$(ss -H -lntu 2>/dev/null | wc -l | tr -d ' ')
        doc_row PASS 'Listening Sockets' "${listeners:-0} TCP/UDP listeners"
    else doc_row FAIL 'Socket Inspector' 'ss command missing'; fi
    if command -v iptables-save >/dev/null 2>&1; then
        mt_rules=$(iptables-save 2>/dev/null | grep -Ec 'MGRE_|MXLAN_|MPORTER_|MBH_|RAT_|MPAQET_|OBFS_CNT_' || true)
        doc_row PASS 'MTunnel IPv4 Rules' "$mt_rules tagged rules"
    else doc_row WARN 'MTunnel IPv4 Rules' 'iptables-save unavailable'; fi
    doc_footer
}

doc_scan_mtunnel() {
    local corev core_file=/usr/lib/mtunnel/common.sh bin corepath
    doc_group 'MTUNNEL CORE & SCRIPT HEALTH'
    if [ -f "$core_file" ] && bash -n "$core_file" >/dev/null 2>&1 && grep -q '^MTUNNEL_CORE_API=1$' "$core_file"; then
        corev=$(sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$core_file" | head -n1)
        doc_row PASS 'Shared Core' "v${corev:-unknown} / API 1"
    else doc_row FAIL 'Shared Core' 'missing or invalid'; fi
    doc_script_check 'MTunnel Dashboard' /usr/bin/mtunnel
    doc_script_check 'GRE Engine' /usr/bin/mgre
    doc_script_check 'VXLAN Engine' /usr/bin/mxlan
    doc_script_check 'Rathole Engine' /usr/bin/mrathole
    doc_script_check 'Backhaul Engine' /usr/bin/mbackhaul
    doc_script_check 'Paqet Engine' /usr/bin/mpaqet
    doc_script_check 'MPorter' /usr/bin/mporter
    doc_script_check 'MTunnel Doctor' /usr/bin/mdoctor
    for bin in bh rathole paqet; do
        corepath=$(command -v "$bin" 2>/dev/null || true)
        [ -n "$corepath" ] && doc_row PASS "Binary Core: $bin" "$corepath" || doc_row WARN "Binary Core: $bin" 'not installed yet'
    done
    doc_footer
}

doc_scan_services() {
    local failed mt_failed
    doc_group 'SERVICES & RUNTIME'
    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk 'NF{c++} END{print c+0}')
    if [ "${failed:-0}" -eq 0 ]; then doc_row PASS 'Failed systemd Units' '0'; else doc_row WARN 'Failed systemd Units' "$failed total failed units"; fi
    mt_failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '$1 ~ /^(mgre|mxlan|mporter|mbackhaul|mrathole|mpaqet)/ {print $1}' | paste -sd, -)
    [ -z "$mt_failed" ] && doc_row PASS 'Failed MTunnel Units' 'none' || doc_row FAIL 'Failed MTunnel Units' "$mt_failed"
    if systemctl is-system-running --quiet 2>/dev/null; then doc_row PASS 'systemd Overall State' 'running'; else
        local state; state=$(systemctl is-system-running 2>/dev/null || true)
        [ "$state" = degraded ] && doc_row WARN 'systemd Overall State' 'degraded' || doc_row WARN 'systemd Overall State' "${state:-unknown}"
    fi
    doc_footer
}

doc_print_summary() {
    local score=100 color="$G" verdict='HEALTHY'
    if [ "$DOC_TOTAL" -gt 0 ]; then
        score=$(( (DOC_PASS*100 + DOC_WARN*50) / DOC_TOTAL ))
    fi
    if [ "$DOC_FAIL" -gt 0 ]; then color="$R"; verdict='ACTION REQUIRED'
    elif [ "$DOC_WARN" -gt 0 ]; then color="$Y"; verdict='CHECK WARNINGS'; fi
    DOC_LAST_SUMMARY="${DOC_PASS} pass / ${DOC_WARN} warn / ${DOC_FAIL} fail — ${score}%"
    DOC_LAST_COLOR="$color"
    if [ "$DOC_PLAIN" = 1 ]; then
        printf '\nSUMMARY: %s | %s\n' "$verdict" "$DOC_LAST_SUMMARY"
    else
        printf '\n  %b┌─[ DOCTOR RESULT ]%b\n' "$DIM" "$NC"
        printf '  %b│%b\n' "$DIM" "$NC"
        printf '  %b├─%b %b%-17s%b %b%s%b\n' "$DIM" "$NC" "$color" "$verdict" "$NC" "$W" "$DOC_LAST_SUMMARY" "$NC"
        printf '  %b└────────────────────────────────────────────────────────────%b\n' "$DIM" "$NC"
    fi
}

doc_full_scan() {
    local mode="${1:-screen}"
    [ "$mode" = plain ] && DOC_PLAIN=1 || DOC_PLAIN=0
    doc_reset_counts
    if [ "$DOC_PLAIN" != 1 ]; then draw_doctor_header; fi
    doc_scan_system
    doc_scan_network
    doc_scan_kernel
    doc_scan_firewall
    doc_scan_mtunnel
    doc_scan_services
    doc_print_summary
    [ "$DOC_PLAIN" = 1 ] || doc_pause
    DOC_PLAIN=0
}

doc_network_screen() {
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_network; doc_scan_kernel; doc_print_summary; doc_pause
}

doc_firewall_screen() {
    local line n=0
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_firewall
    doc_group 'LISTENING PORT PREVIEW'
    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r line; do
            n=$((n+1)); [ "$n" -gt 18 ] && break
            printf '  %b├─%b %b●%b %s\n' "$DIM" "$NC" "$C" "$NC" "$line"
        done < <(ss -H -lntup 2>/dev/null | awk '{printf "%-4s %-24s %s\n", $1, $5, $NF}')
        [ "$n" -gt 0 ] || doc_note 'No TCP/UDP listeners found.'
        [ "$n" -lt 18 ] || doc_note 'Preview limited to first 18 listeners.'
    else doc_note 'ss command is not available.'; fi
    doc_footer; doc_print_summary; doc_pause
}

doc_core_screen() {
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_mtunnel; doc_scan_services; doc_print_summary; doc_pause
}

doc_services_screen() {
    local line n=0
    DOC_PLAIN=0; doc_reset_counts; draw_doctor_header; doc_scan_services
    doc_group 'FAILED UNIT DETAILS'
    while IFS= read -r line; do
        [ -n "$line" ] || continue; n=$((n+1)); [ "$n" -gt 15 ] && break
        printf '  %b├─%b %b⚠%b %s\n' "$DIM" "$NC" "$Y" "$NC" "$line"
    done < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1 " — " $4}')
    [ "$n" -gt 0 ] || doc_note 'No failed systemd units.'
    doc_footer; doc_print_summary; doc_pause
}

doc_persist_forwarding() {
    local v4="$1" v6="$2" file=/etc/sysctl.d/99-mtunnel-doctor.conf tmp
    tmp=$(mktemp "$SECURE_TMP/doctor-sysctl.XXXXXX") || return 1
    {
        echo '# Managed by MTunnel Doctor'
        [ "$v4" = 1 ] && echo 'net.ipv4.ip_forward = 1'
        [ "$v6" = 1 ] && echo 'net.ipv6.conf.all.forwarding = 1'
    } > "$tmp"
    install -m 0644 "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    sysctl --system >/dev/null 2>&1 || return 1
}

doc_confirm() {
    local answer
    printf '  %bType YES to continue ❯❯ %b' "$Y" "$NC"; read -r answer
    [ "$answer" = YES ]
}

doc_safe_repair() {
    local choice mod ok=1
    while true; do
        draw_doctor_header
        printf '\n  %b┌─[ SAFE REPAIR ACTIONS ]%b\n' "$DIM" "$NC"
        printf '  %b│%b\n' "$DIM" "$NC"
        printf '  %b├─%b %b1%b %b❯%b %bEnable & Persist IPv4 Forwarding%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC"
        printf '  %b├─%b %b2%b %b❯%b %bEnable & Persist IPv6 Forwarding%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$M" "$NC"
        printf '  %b├─%b %b3%b %b❯%b %bLoad Tunnel Kernel Modules%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
        printf '  %b├─%b %b4%b %b❯%b %bReload systemd Unit Database%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
        printf '  %b│%b\n' "$DIM" "$NC"
        printf '  %b├────────────────────────────%b\n' "$DIM" "$NC"
        printf '  %b└─%b %b0%b %b❯%b %bReturn to Doctor%b\n\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$DIM" "$NC"
        printf '  %bREPAIR ❯❯ %b' "$C" "$NC"; read -r choice
        case "$choice" in
            0|'') return 0;;
            1)
                echo -e "\n  ${Y}This writes /etc/sysctl.d/99-mtunnel-doctor.conf and enables IPv4 forwarding.${NC}"
                if doc_confirm && doc_persist_forwarding 1 0; then echo -e "  ${G}✔ IPv4 forwarding enabled and persisted.${NC}"; else echo -e "  ${R}✖ Cancelled or repair failed.${NC}"; fi; doc_pause;;
            2)
                echo -e "\n  ${Y}This writes /etc/sysctl.d/99-mtunnel-doctor.conf and enables IPv6 forwarding.${NC}"
                if doc_confirm && doc_persist_forwarding 0 1; then echo -e "  ${G}✔ IPv6 forwarding enabled and persisted.${NC}"; else echo -e "  ${R}✖ Cancelled or repair failed.${NC}"; fi; doc_pause;;
            3)
                echo -e "\n  ${DIM}Loading: ip_gre ipip vxlan xfrm_user${NC}"
                if doc_confirm; then
                    ok=1; for mod in ip_gre ipip vxlan xfrm_user; do modprobe "$mod" >/dev/null 2>&1 || ok=0; done
                    [ "$ok" = 1 ] && echo -e "  ${G}✔ Tunnel modules loaded.${NC}" || echo -e "  ${Y}⚠ One or more modules are unavailable on this kernel.${NC}"
                fi; doc_pause;;
            4)
                if doc_confirm && systemctl daemon-reload; then echo -e "  ${G}✔ systemd daemon-reload completed.${NC}"; else echo -e "  ${R}✖ Cancelled or reload failed.${NC}"; fi; doc_pause;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1;;
        esac
    done
}

doc_export_report() {
    local ts file tmp
    ts=$(date +%Y%m%d-%H%M%S); file="$REPORT_DIR/doctor-${ts}.txt"; tmp=$(mktemp "$SECURE_TMP/doctor-report.XXXXXX") || return 1
    {
        echo 'MTunnel Doctor Diagnostic Report'
        echo "Generated: $(date -Is)"
        echo "Doctor Version: $MODULE_VERSION"
        echo "Hostname: $(hostname 2>/dev/null)"
        echo '============================================================'
        doc_full_scan plain
    } > "$tmp"
    chmod 600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" || return 1
    DOC_PLAIN=0
    if [ "${DOC_NONINTERACTIVE:-0}" = 1 ]; then
        printf '%s\n' "$file"
        return 0
    fi
    draw_doctor_header
    echo -e "\n  ${DIM}┌─[ REPORT EXPORTED ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${G}✔${NC} ${W}Diagnostic report saved successfully.${NC}"
    echo -e "  ${DIM}└─${NC} ${C}${file}${NC}"
    doc_pause
}

draw_doctor_header() {
    clear
    mt_master_header_draw "$MODULE_VERSION"
}

render_doctor_menu() {
    draw_doctor_header
    printf '\n  %b┌─[ MTUNNEL DOCTOR & DIAGNOSTICS ]%b\n' "$DIM" "$NC"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├─%b %b1%b %b❯%b %bRun Full Health Scan%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
    printf '  %b├─%b %b2%b %b❯%b %bNetwork & IPv6 Diagnostics%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC"
    printf '  %b├─%b %b3%b %b❯%b %bFirewall & Port Diagnostics%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$Y" "$NC"
    printf '  %b├─%b %b4%b %b❯%b %bTunnel Engines & Core & Script Health%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$M" "$NC"
    printf '  %b├─%b %b5%b %b❯%b %bSystem Services & Failed Units%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$C" "$NC"
    printf '  %b├─%b %b6%b %b❯%b %bSafe Repair Actions%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$G" "$NC"
    printf '  %b├─%b %b7%b %b❯%b %bExport Diagnostic Report%b\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$W" "$NC"
    printf '  %b│%b\n' "$DIM" "$NC"
    printf '  %b├────────────────────────────%b\n' "$DIM" "$NC"
    printf '  %b└─%b %b0%b %b❯%b %bReturn to Dashboard%b\n\n' "$DIM" "$NC" "$W" "$NC" "$DIM" "$NC" "$DIM" "$NC"
}

case "${1:-}" in
    --report) DOC_NONINTERACTIVE=1; doc_export_report; exit $?;;
    --scan|--status) doc_full_scan plain; exit $?;;
    --version|-V) printf 'MTunnel Doctor %s\n' "$MODULE_VERSION"; exit 0;;
    --help|-h)
        cat <<EOF
MTunnel Doctor v$MODULE_VERSION
Usage: mdoctor [--scan|--status|--report|--version]
  --scan, --status   Run a non-interactive full health scan
  --report           Export a diagnostic report and print its path
  --version          Show Doctor version
EOF
        exit 0;;
esac

while true; do
    render_doctor_menu
    printf '  %bDOCTOR ❯❯ %b' "$C" "$NC"; read -r opt
    opt="${opt//[$' \r\n\t']/}"
    case "$opt" in
        1) doc_full_scan;;
        2) doc_network_screen;;
        3) doc_firewall_screen;;
        4) doc_core_screen;;
        5) doc_services_screen;;
        6) doc_safe_repair;;
        7) doc_export_report;;
        0|'') clear; exit 0;;
        *) echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1;;
    esac
done
