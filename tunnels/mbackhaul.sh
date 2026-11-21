#!/bin/bash
# MTunnel MBackhaul — Backhaul tunnel setup, configuration, and connection management (v2.2.5, Backhaul Core v0.9.1).
MODULE_VERSION="2.2.5"
MTUNNEL_REQUIRED_CORE_API=1
MTUNNEL_REQUIRED_LAYOUT_REV=2
umask 077

# MTUNNEL_COMMON_LOADER -- common API 1, required by this module.
# Source next to a checkout first, or from the system-wide installed location.
# No network calls, implicit fallbacks to generated code, or silent failures.
mt_load_common() {
    local script_dir candidate
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    for candidate in \
        "$script_dir/core/common.sh" \
        "$script_dir/../core/common.sh" \
        /usr/lib/mtunnel/common.sh \
        /root/mtunnel/core/common.sh; do
        if [[ -f "$candidate" && -r "$candidate" ]]; then
            # A bad or incompatible shared core must fail loudly, not fall back.
            source "$candidate" || return 1
            if [[ "${MTUNNEL_CORE_API:-}" == "${MTUNNEL_REQUIRED_CORE_API:-1}" && "${MTUNNEL_LAYOUT_REV:-}" == "${MTUNNEL_REQUIRED_LAYOUT_REV:-2}" ]]; then return 0; fi
            printf 'MTunnel: incompatible shared core: %s\n' "$candidate" >&2
            return 1
        fi
    done
    echo 'MTunnel: core/common.sh is missing. Reinstall the complete bundle (bash install.sh --local .).' >&2
    return 1
}
mt_load_common || exit 1
if ! declare -F mt_hdr_draw >/dev/null || ! declare -F mt_port_guard >/dev/null || ! declare -F mt_unit_live_peer >/dev/null; then
    echo 'MTunnel: the installed shared core (common.sh) is older than this module (requires the current shared-core API/layout).' >&2
    echo 'Update the whole bundle from the main menu (Sync) or run: bash install.sh --local .' >&2
    exit 1
fi
unset -f mt_load_common
if [ "$EUID" != 0 ]; then echo "Run MTunnel with sudo." >&2; exit 1; fi
BT_MOD="mbackhaul"; BT_REL_PATH="tunnels/mbackhaul.sh"; BT_TITLE="MBackhaul"
for _bt_cand in "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../core/bintunnel.sh" /usr/lib/mtunnel/bintunnel.sh /root/mtunnel/core/bintunnel.sh; do
    if [[ -f "$_bt_cand" && -r "$_bt_cand" ]]; then source "$_bt_cand" || exit 1; break; fi
done; unset _bt_cand
if ! declare -F bt_init_runtime >/dev/null 2>&1; then echo "MTunnel: core/bintunnel.sh is missing. Reinstall the complete bundle." >&2; exit 1; fi


















B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
FR='\033[1;33m'   # frame colour: gold (double-line frames and menu tree connectors)
INSTALL_PATH="/usr/bin/mbackhaul"
CONF_DIR="/etc/mbackhaul/tunnels"
CERT_DIR="/etc/mbackhaul/certs"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

# Never delete a pre-existing executable merely by opening this menu.

mkdir -p "$CONF_DIR" "$CERT_DIR" "$LOCAL_DIR/engines" "$LOCAL_DIR/prereqs" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$CONF_DIR" "$CERT_DIR" "$SECURE_TMP" 2>/dev/null
rm -f "$SECURE_TMP/.mbackhaul_in_menu" 2>/dev/null

ensure_dependencies() {
    [ -f /var/lib/mtunnel/.deps_ok ] && return 0
    local missing=()
    command -v crontab >/dev/null 2>&1 || missing+=("cron")
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v iptables >/dev/null 2>&1 || missing+=("iptables")
    command -v flock >/dev/null 2>&1 || missing+=("util-linux")
    command -v openssl >/dev/null 2>&1 || missing+=("openssl")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
    if [ ${#missing[@]} -gt 0 ]; then
        apt-get update -y -q >/dev/null 2>&1
        apt-get install -y -q "${missing[@]}" >/dev/null 2>&1
        systemctl enable cron >/dev/null 2>&1
        systemctl start cron >/dev/null 2>&1
    fi
}
if [[ "${1:-}" != --* ]]; then ensure_dependencies && mkdir -p /var/lib/mtunnel 2>/dev/null && touch /var/lib/mtunnel/.deps_ok 2>/dev/null || true; fi

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    mt_install_files 755 "$0" "$INSTALL_PATH" || { echo "Cannot install module." >&2; exit 1; }
fi

is_valid_host() {
    mt_valid_host "$1"
}

# Port-conflict guard for Backhaul mapping specs ("443=127.0.0.1:443,8000-8010,1.2.3.4:80=9000").
# $1 spec  $2 udp too? (0/1)  $3 self unit  -> BH_SPEC_OUT (conflicting entries closed/skipped); rc 1 = cancelled
bh_ports_guard() {
    local spec="$1" udp="${2:-0}" self="${3:-}" raw lhs rhs port a b tcp_list='' item p rm='' kept
    local -a items=() pieces=(); BH_SPEC_OUT="$spec"
    [ -n "$spec" ] || return 0
    IFS=, read -ra items <<< "$spec"
    for raw in "${items[@]}"; do
        raw="${raw// /}"; lhs="${raw%%=*}"
        if [[ "$lhs" == *:* ]]; then a="${lhs##*:}"; b="$a"
        elif [[ "$lhs" == *-* ]]; then a="${lhs%-*}"; b="${lhs#*-}"
        else a="$lhs"; b="$lhs"; fi
        [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || continue
        tcp_list+="${tcp_list:+,}$(mt_range_fmt "$((10#$a))" "$((10#$b))")"
    done
    mt_port_guard bind "$tcp_list" "$([ "$udp" = 1 ] && echo "$tcp_list")" "$self" "" "Backhaul" || return 1
    kept=" $(mt_ports_expand "$MT_PORT_TCP") "
    local orig; orig=$(mt_ports_expand "$tcp_list")
    for p in $orig; do [[ "$kept" == *" $p "* ]] || rm+="$p "; done
    [ -n "$rm" ] || return 0
    local out=''
    for raw in "${items[@]}"; do
        raw="${raw// /}"; lhs="${raw%%=*}"; rhs=''; [[ "$raw" == *=* ]] && rhs="=${raw#*=}"
        if [[ "$lhs" == *:* ]]; then
            [[ " $rm " == *" ${lhs##*:} "* ]] && continue
            out+="${out:+,}$raw"
        elif [[ "$lhs" == *-* ]]; then
            local sub; sub=$(mt_ports_subtract "$(mt_range_fmt "${lhs%-*}" "${lhs#*-}")" "$rm")
            local piece
            IFS=, read -ra pieces <<< "$sub"
            for piece in "${pieces[@]}"; do [ -n "$piece" ] && out+="${out:+,}${piece/:/-}${rhs}"; done
        else
            [[ " $rm " == *" $((10#$lhs)) "* ]] && continue
            out+="${out:+,}$raw"
        fi
    done
    BH_SPEC_OUT="$out"
    return 0
}

validate_bh_ports() {
    local list="$1" check="${2:-0}" owned="${3:-}" raw lhs rhs port start end host owned_port
    local -a items=(); local -A seen=()
    [ -z "$list" ] && return 0
    [[ "$list" != *, && "$list" != ,* && "$list" != *,,* ]] || return 1
    IFS=, read -ra items <<< "$list"
    for raw in "${items[@]}"; do
        raw="${raw// /}"; lhs="${raw%%=*}"; rhs=''
        if [[ "$raw" == *=* ]]; then
            rhs="${raw#*=}"; [[ "$rhs" != *=* && -n "$rhs" ]] || return 1
            if [[ "$rhs" == *:* ]]; then
                host=$(mt_normalize_host "${rhs%:*}"); port="${rhs##*:}"
                if [[ "$rhs" == \[*\]:* ]]; then
                    mt_valid_ipv6 "$host" && mt_valid_port "$port" || return 1
                else
                    mt_valid_host "$host" && [[ "$host" != *:* ]] && mt_valid_port "$port" || return 1
                fi
            else mt_valid_port "$rhs" || return 1; fi
        fi
        if [[ "$lhs" == *:* ]]; then
            host=$(mt_normalize_host "${lhs%:*}"); port="${lhs##*:}"
            mt_valid_ipv4 "$host" || mt_valid_ipv6 "$host" || return 1
            start="$port"; end="$port"
        elif [[ "$lhs" == *-* ]]; then start="${lhs%-*}"; end="${lhs#*-}"
        else start="$lhs"; end="$lhs"; fi
        mt_valid_port "$start" && mt_valid_port "$end" && ((10#$start <= 10#$end)) || return 1
        for ((port=10#$start;port<=10#$end;port++)); do
            [ -z "${seen[$port]:-}" ] || return 1; seen[$port]=1
            owned_port=0
            if [ -n "$owned" ]; then
                local old old_l old_s old_e; local -a old_items=()
                IFS=, read -ra old_items <<< "$owned"
                for old in "${old_items[@]}"; do
                    old_l="${old%%=*}"; old_l="${old_l##*:}"
                    old_s="${old_l%-*}"; old_e="${old_l#*-}"
                    mt_valid_port "$old_s" && mt_valid_port "$old_e" && ((port>=10#$old_s && port<=10#$old_e)) && owned_port=1
                done
            fi
            if [ "$check" == 1 ] && [ "$owned_port" == 0 ] && mt_port_busy "$port"; then
                echo "Port $port is already in use." >&2; return 1
            fi
        done
    done
    return 0
}

bt_init_runtime "$@"

# Keeps the last known good value when a source is unreachable (no "Unknown" overwrite).




# mt_choose_peer_host supplied by core/common.sh

# Any valid Backhaul binary version is accepted without version lock.
BH_EXPECT_VERSION="any"
BH_PROBED_VERSION=""; _BH_PROBE_KEY=""
bh_core_bin() { local c; for c in /usr/local/bin/bh /usr/bin/bh; do [ -x "$c" ] && { printf '%s' "$c"; return 0; }; done; return 1; }
bh_probe_version() { # path
    local b="$1" key out
    key="$b:$(stat -c '%Y:%s' "$b" 2>/dev/null)"
    [ "$key" != "$_BH_PROBE_KEY" ] || return 0
    out=$(timeout 3 "$b" -v 2>&1 </dev/null | head -n 3) || true
    BH_PROBED_VERSION=""
    [[ "$out" =~ ([0-9]+(\.[0-9]+)+) ]] && BH_PROBED_VERSION="${BASH_REMATCH[1]}"
    _BH_PROBE_KEY="$key"
    return 0
}
bh_core_version_ok() { # path
    [ -x "${1:-}" ] && mt_valid_elf "$1"
}
is_bh_core_valid() {
    local candidate
    for candidate in /usr/local/bin/bh /usr/bin/bh; do
        if [ -x "$candidate" ] && mt_valid_elf "$candidate"; then return 0; fi
    done
    return 1
}
# Restore a saved copy of the core after a wrong-version install, then restart the units that were running.
bh_restore_core() { # saved-file
    local prev="$1" unit; local -a active=()
    [ -f "$prev" ] || return 1
    mapfile -t active < <(systemctl list-units --type=service --state=active --no-legend --plain 'mbackhaul@*.service' 2>/dev/null | awk '{print $1}')
    mt_install_files 755 "$prev" /usr/local/bin/bh "$prev" /usr/bin/bh || return 1
    for unit in "${active[@]}"; do systemctl restart "$unit" >/dev/null 2>&1 || true; done
}



apply_bbr_optimization() {
    return 0  # BBR is managed explicitly by mbbr.
}

bh_select_transport() {
    local choice
    echo -e "\n  ${FR}┌─[ TRANSPORT PROTOCOL — Core v0.9.1 ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC}  ${DIM}❯${NC} ${G}TLSMUX${NC}    ${DIM}(TCP + uTLS + Mux — Best Direct All-Rounder)${NC}"
    echo -e "  ${FR}├─${NC} ${W}2${NC}  ${DIM}❯${NC} ${M}XHTTPSMUX${NC} ${DIM}(Split-HTTP/2 + uTLS + Mux — Best vs DPI & CDN)${NC}"
    echo -e "  ${FR}├─${NC} ${W}3${NC}  ${DIM}❯${NC} ${M}XHTTPS${NC}    ${DIM}(Split-HTTP/2 + uTLS Single-Stream — No TCP-over-TCP)${NC}"
    echo -e "  ${FR}├─${NC} ${W}4${NC}  ${DIM}❯${NC} ${G}TLS${NC}       ${DIM}(TCP + uTLS Single-Stream — Low Latency / High Speed)${NC}"
    echo -e "  ${FR}├─${NC} ${W}5${NC}  ${DIM}❯${NC} ${C}WSSMUX${NC}    ${DIM}(WebSocket + uTLS + Framed Mux — CDN Ready)${NC}"
    echo -e "  ${FR}├─${NC} ${W}6${NC}  ${DIM}❯${NC} ${C}WSS${NC}       ${DIM}(WebSocket + uTLS Single-Stream — CDN Ready)${NC}"
    echo -e "  ${FR}├─${NC} ${W}7${NC}  ${DIM}❯${NC} ${Y}KCPMUX${NC}    ${DIM}(UDP + KCP + AES + Mux — Packet Loss Recovery)${NC}"
    echo -e "  ${FR}├─${NC} ${W}8${NC}  ${DIM}❯${NC} ${Y}KCP${NC}       ${DIM}(UDP + KCP + AES Single-Stream)${NC}"
    echo -e "  ${FR}├─${NC} ${W}9${NC}  ${DIM}❯${NC} ${W}TCPMUX${NC}    ${DIM}(Raw TCP + Mux — Max Speed on Clean Links)${NC}"
    echo -e "  ${FR}├─${NC} ${W}10${NC} ${DIM}❯${NC} ${W}TCP${NC}       ${DIM}(Raw TCP + Optional UDP Forwarding)${NC}"
    echo -e "  ${FR}├─${NC} ${W}11${NC} ${DIM}❯${NC} ${W}UDP${NC}       ${DIM}(Raw UDP Applications Only)${NC}"
    echo -e "  ${FR}│${NC}"
    echo -ne "  ${FR}└─${NC} ${C}Select [1-11 | q: cancel] ❯❯ ${NC}"; read -r choice || return 1
    case "${choice//$'\r'/}" in
        1) BH_TRANSPORT=tlsmux;;
        2) BH_TRANSPORT=xhttpsmux;;
        3) BH_TRANSPORT=xhttps;;
        4) BH_TRANSPORT=tls;;
        5) BH_TRANSPORT=wssmux;;
        6) BH_TRANSPORT=wss;;
        7) BH_TRANSPORT=kcpmux;;
        8) BH_TRANSPORT=kcp;;
        9) BH_TRANSPORT=tcpmux;;
        10) BH_TRANSPORT=tcp;;
        11) BH_TRANSPORT=udp;;
        *) return 1;;
    esac
}

bh_cpu_cores() { local n; n=$(nproc 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || n=1; echo "$n"; }
bh_cap_at() { local v="$1" m="$2"; [ "$v" -gt "$m" ] && v="$m"; echo "$v"; }

bh_get_tunnel_profile() {
    local meta="$CONF_DIR/${1}.meta" p=""
    [ -f "$meta" ] && p=$(sed -n 's/^PROFILE=//p' "$meta" | head -n1 | tr -d '\r" ')
    echo "${p:-BALANCED}"
}

bh_load_options() {
    local meta="$1" override="${2:-}" key value file
    BH_PROFILE="BALANCED"
    declare -gA BH_OPTS=([KEEPALIVE]=75 [HEARTBEAT]=40 [CHANNEL]=4096 [POOL]=8
        [RETRY]=3 [DIAL]=10 [AGGRESSIVE]=false [NODELAY]=true [LOG]=info
        [MUX_CON]=8 [MUX_VERSION]=1 [MUX_FRAME]=32768 [MUX_RECEIVE]=4194304 [MUX_STREAM]=65536
        [MTU]=0 [MSS]=1360 [RCVBUF]=4194304 [SNDBUF]=4194304 [PROXY]=false
        [EDGE]="" [TLS_CERT]="" [TLS_KEY]="" [SNI]="" [UTLS]="chrome" [KCP_MODE]="fast2" [KCP_CRYPT]="aes" [KCP_NOFEC]="false" [XHTTP_PATH]="/api/v1/stream" [XHTTP_MODE]="auto" [XHTTP_HOST]="")
    for file in "$meta" "$override"; do
        [ -n "$file" ] && [ -f "$file" ] || continue
        while IFS='=' read -r key value; do
            value="${value//$'\r'/}"
            if [ "$key" = "PROFILE" ] && [[ "$value" =~ ^(ECO|BALANCED|SPEED|LATENCY|EXTREME|MANUAL|CUSTOM)$ ]]; then
                BH_PROFILE="$value"
                continue
            fi
            [[ "$key" == ADV_* ]] || continue; key="${key#ADV_}"
            [[ "$key" =~ ^[A-Z_]+$ ]] && [[ -v BH_OPTS[$key] ]] || return 1
            BH_OPTS[$key]="$value"
        done < "$file"
    done
    bh_validate_options
}

bh_apply_profile_defaults() {
    local profile="${1^^}" cores
    cores=$(bh_cpu_cores)
    BH_PROFILE="$profile"
    local edge="${BH_OPTS[EDGE]:-}" cert="${BH_OPTS[TLS_CERT]:-}" key="${BH_OPTS[TLS_KEY]:-}" sni="${BH_OPTS[SNI]:-}" utls="${BH_OPTS[UTLS]:-chrome}" kmode="${BH_OPTS[KCP_MODE]:-fast2}" kcrypt="${BH_OPTS[KCP_CRYPT]:-aes}" knofec="${BH_OPTS[KCP_NOFEC]:-false}" xpath="${BH_OPTS[XHTTP_PATH]:-/api/v1/stream}" xmode="${BH_OPTS[XHTTP_MODE]:-auto}" xhost="${BH_OPTS[XHTTP_HOST]:-}"
    local mtu="${BH_OPTS[MTU]:-0}" mss="${BH_OPTS[MSS]:-1360}" proxy="${BH_OPTS[PROXY]:-false}" log="${BH_OPTS[LOG]:-info}"

    case "$profile" in
        ECO)
            BH_OPTS[KEEPALIVE]=90; BH_OPTS[HEARTBEAT]=60; BH_OPTS[CHANNEL]=1024
            BH_OPTS[POOL]=$(bh_cap_at "$cores" 2); BH_OPTS[RETRY]=5; BH_OPTS[DIAL]=10
            BH_OPTS[AGGRESSIVE]=false; BH_OPTS[NODELAY]=false
            BH_OPTS[MUX_CON]=2; BH_OPTS[MUX_VERSION]=1; BH_OPTS[MUX_FRAME]=16384
            BH_OPTS[MUX_RECEIVE]=2097152; BH_OPTS[MUX_STREAM]=32768
            BH_OPTS[RCVBUF]=2097152; BH_OPTS[SNDBUF]=2097152
            ;;
        BALANCED)
            BH_OPTS[KEEPALIVE]=75; BH_OPTS[HEARTBEAT]=40; BH_OPTS[CHANNEL]=4096
            BH_OPTS[POOL]=$(bh_cap_at $((cores * 2)) 8); BH_OPTS[RETRY]=3; BH_OPTS[DIAL]=10
            BH_OPTS[AGGRESSIVE]=false; BH_OPTS[NODELAY]=true
            BH_OPTS[MUX_CON]=8; BH_OPTS[MUX_VERSION]=1; BH_OPTS[MUX_FRAME]=32768
            BH_OPTS[MUX_RECEIVE]=4194304; BH_OPTS[MUX_STREAM]=65536
            BH_OPTS[RCVBUF]=4194304; BH_OPTS[SNDBUF]=4194304
            ;;
        SPEED)
            BH_OPTS[KEEPALIVE]=45; BH_OPTS[HEARTBEAT]=25; BH_OPTS[CHANNEL]=8192
            BH_OPTS[POOL]=$(bh_cap_at $((cores * 4)) 16); [ "${BH_OPTS[POOL]}" -lt 4 ] && BH_OPTS[POOL]=4
            BH_OPTS[RETRY]=2; BH_OPTS[DIAL]=8
            BH_OPTS[AGGRESSIVE]=false; BH_OPTS[NODELAY]=true
            BH_OPTS[MUX_CON]=16; BH_OPTS[MUX_VERSION]=2; BH_OPTS[MUX_FRAME]=65535
            BH_OPTS[MUX_RECEIVE]=16777216; BH_OPTS[MUX_STREAM]=262144
            BH_OPTS[RCVBUF]=16777216; BH_OPTS[SNDBUF]=16777216
            ;;
        LATENCY)
            BH_OPTS[KEEPALIVE]=25; BH_OPTS[HEARTBEAT]=15; BH_OPTS[CHANNEL]=4096
            BH_OPTS[POOL]=$(bh_cap_at $((cores * 2)) 8); [ "${BH_OPTS[POOL]}" -lt 2 ] && BH_OPTS[POOL]=2
            BH_OPTS[RETRY]=1; BH_OPTS[DIAL]=5
            BH_OPTS[AGGRESSIVE]=true; BH_OPTS[NODELAY]=true
            BH_OPTS[MUX_CON]=4; BH_OPTS[MUX_VERSION]=2; BH_OPTS[MUX_FRAME]=16384
            BH_OPTS[MUX_RECEIVE]=4194304; BH_OPTS[MUX_STREAM]=65536
            BH_OPTS[RCVBUF]=4194304; BH_OPTS[SNDBUF]=4194304
            ;;
        EXTREME)
            BH_OPTS[KEEPALIVE]=30; BH_OPTS[HEARTBEAT]=15; BH_OPTS[CHANNEL]=16384
            BH_OPTS[POOL]=$(bh_cap_at $((cores * 6)) 32); [ "${BH_OPTS[POOL]}" -lt 8 ] && BH_OPTS[POOL]=8
            BH_OPTS[RETRY]=1; BH_OPTS[DIAL]=5
            BH_OPTS[AGGRESSIVE]=true; BH_OPTS[NODELAY]=true
            BH_OPTS[MUX_CON]=32; BH_OPTS[MUX_VERSION]=2; BH_OPTS[MUX_FRAME]=65535
            BH_OPTS[MUX_RECEIVE]=33554432; BH_OPTS[MUX_STREAM]=524288
            BH_OPTS[RCVBUF]=33554432; BH_OPTS[SNDBUF]=33554432
            ;;
        *)
            BH_PROFILE="MANUAL"
            ;;
    esac
    BH_OPTS[EDGE]="$edge"; BH_OPTS[TLS_CERT]="$cert"; BH_OPTS[TLS_KEY]="$key"; BH_OPTS[SNI]="$sni"; BH_OPTS[UTLS]="$utls"; BH_OPTS[KCP_MODE]="$kmode"; BH_OPTS[KCP_CRYPT]="$kcrypt"; BH_OPTS[KCP_NOFEC]="$knofec"; BH_OPTS[XHTTP_PATH]="$xpath"; BH_OPTS[XHTTP_MODE]="$xmode"; BH_OPTS[XHTTP_HOST]="$xhost"
    BH_OPTS[MTU]="$mtu"; BH_OPTS[MSS]="$mss"; BH_OPTS[PROXY]="$proxy"; BH_OPTS[LOG]="$log"
    return 0
}

bh_validate_options() {
    local key value min max
    for key in KEEPALIVE HEARTBEAT CHANNEL POOL RETRY DIAL MUX_CON MUX_VERSION MUX_FRAME MUX_RECEIVE MUX_STREAM MTU MSS RCVBUF SNDBUF; do
        value="${BH_OPTS[$key]}"
        [[ "$value" =~ ^[0-9]{1,9}$ ]] || { echo "Invalid $key." >&2; return 1; }
        value=$((10#$value)); BH_OPTS[$key]="$value"
        min=1; max=3600
        case "$key" in
            CHANNEL) max=65536;; POOL|MUX_CON) max=1024;; MUX_VERSION) max=2;;
            MUX_FRAME) min=512; max=65535;; MUX_RECEIVE) min=65536; max=134217728;;
            MUX_STREAM) min=1024; max=134217728;; MTU) min=0; max=9000;; MSS) min=0; max=8960;;
            RCVBUF|SNDBUF) min=0; max=134217728;;
        esac
        ((value>=min && value<=max)) || { echo "$key must be $min-$max." >&2; return 1; }
    done
    ((BH_OPTS[MUX_STREAM]<=BH_OPTS[MUX_RECEIVE])) || { echo 'MUX stream buffer must not exceed receive buffer.' >&2; return 1; }
    ((BH_OPTS[MTU]==0 || BH_OPTS[MTU]>=1280)) || { echo 'Link MTU must be 0 or 1280-9000.' >&2; return 1; }
    ((BH_OPTS[MSS]==0 || BH_OPTS[MSS]>=536)) || { echo 'MSS must be 0 or 536-8960.' >&2; return 1; }
    for key in AGGRESSIVE NODELAY PROXY; do [[ "${BH_OPTS[$key]}" =~ ^(true|false)$ ]] || return 1; done
    [[ "${BH_OPTS[LOG]}" =~ ^(trace|debug|info|warn|error)$ ]] || return 1
    [ -z "${BH_OPTS[EDGE]}" ] || mt_valid_ipv4 "${BH_OPTS[EDGE]}" || mt_valid_ipv6 "${BH_OPTS[EDGE]}" || return 1
    for key in TLS_CERT TLS_KEY; do
        [ -z "${BH_OPTS[$key]}" ] || [[ "${BH_OPTS[$key]}" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    done
    [[ -z "${BH_OPTS[TLS_CERT]}" && -z "${BH_OPTS[TLS_KEY]}" || -n "${BH_OPTS[TLS_CERT]}" && -n "${BH_OPTS[TLS_KEY]}" ]] || return 1
    [[ "${BH_OPTS[KCP_NOFEC]}" =~ ^(true|false)$ ]] || return 1
    [[ "${BH_OPTS[KCP_MODE]}" =~ ^(normal|fast|fast2|fast3|manual)$ ]] || return 1
    [[ "${BH_OPTS[KCP_CRYPT]}" =~ ^(aes|aes-128|aes-256|salsa20|xor|tea|xtea|sm4|blowfish|twofish|cast5|3des|none)$ ]] || return 1
    [[ "${BH_OPTS[XHTTP_MODE]}" =~ ^(auto|stream-up|packet-up)$ ]] || return 1
    [[ "${BH_OPTS[XHTTP_PATH]}" =~ ^/[A-Za-z0-9._/-]*$ ]] || return 1
    [ -z "${BH_OPTS[SNI]}" ] || mt_valid_host "${BH_OPTS[SNI]}" || return 1
    [[ "${BH_OPTS[UTLS]}" =~ ^(chrome|firefox|safari|edge|ios|random|none)$ ]] || return 1
    [ -z "${BH_OPTS[XHTTP_HOST]}" ] || mt_valid_host "${BH_OPTS[XHTTP_HOST]}" || return 1
}

bh_ask_option() {
    local key="$1" label="$2" value old="${BH_OPTS[$1]}"
    while true; do
        echo -ne "  ${FR}├─${NC} ${W}$label [${old:-auto}; Enter: keep; -: auto/empty]${NC} ${C}❯❯ ${NC}"
        read -r value || return 1; value="${value//$'\r'/}"
        [ -n "$value" ] || return 0
        [ "$value" != - ] || { value=""; [[ "$key" != MTU && "$key" != MSS && "$key" != RCVBUF && "$key" != SNDBUF ]] || value=0; }
        BH_OPTS[$key]="$value"
        if bh_validate_options; then return 0; fi
        BH_OPTS[$key]="$old"; echo -e "  ${R}✖ Invalid value; try again.${NC}"
    done
}

bh_advanced_wizard() {
    local name="$1" role="$2" transport="$3" choice key cores current_prof
    bh_load_options "$CONF_DIR/$name.meta" || return 1
    current_prof="${BH_PROFILE:-BALANCED}"
    cores=$(bh_cpu_cores)
    BH_SETTINGS_FILE=""

    echo -e "\n  ${FR}┌─[ PERFORMANCE PROFILE — ${cores} CPU Core(s) | Current: ${current_prof} ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}ECO${NC}          ${DIM}(Lowest CPU/RAM — Small Pool, 2MB Buffers)${NC}"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}BALANCED${NC}     ${DIM}(Recommended Default — Up to 8 Pool/Mux, 4MB Buffers)${NC}"
    echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}SPEED${NC}        ${DIM}(High Throughput — 16MB Buffers, 64KB Frames)${NC}"
    echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}LOW-LATENCY${NC}  ${DIM}(Aggressive Pool — Fast Heartbeat & Keepalive)${NC}"
    echo -e "  ${FR}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${R}EXTREME${NC}      ${DIM}(Max Capacity — Up to 32 Pool/Mux, 32MB Buffers)${NC}"
    echo -e "  ${FR}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${W}MANUAL${NC}       ${DIM}(Customize Transport, SNI, uTLS, Buffers & MUX)${NC}"
    echo -e "  ${FR}│${NC}"
    echo -ne "  ${FR}└─${NC} ${C}Select Profile [1-6 | Enter: ${current_prof} | q: cancel] ❯❯ ${NC}"
    read -r choice || return 1
    choice="${choice//$'\r'/}"

    case "$choice" in
        1) bh_apply_profile_defaults ECO ;;
        2) bh_apply_profile_defaults BALANCED ;;
        3) bh_apply_profile_defaults SPEED ;;
        4) bh_apply_profile_defaults LATENCY ;;
        5)
            if [ "$cores" -lt 4 ]; then
                echo -e "  ${Y}⚠ This server has only ${cores} core(s). EXTREME is meant for 4+ cores; SPEED is safer here.${NC}"
                local go; echo -ne "  ${C}Use EXTREME anyway? [y/N]: ${NC}"; read -r go || return 1
                [[ "${go,,}" == "y" || "${go,,}" == "yes" ]] || return 1
            fi
            bh_apply_profile_defaults EXTREME ;;
        6)
            BH_PROFILE="MANUAL"
            echo -e "\n  ${FR}┌─[ MANUAL TUNNEL SETTINGS ]${NC}"
            bh_ask_option LOG 'Log level (trace/debug/info/warn/error)' || return 1
            if [ "$role" = 1 ]; then
                bh_ask_option CHANNEL 'Pending channel capacity (1-65536)' || return 1
                bh_ask_option HEARTBEAT 'Heartbeat interval (seconds)' || return 1
            else
                bh_ask_option POOL 'Connection pool (1-1024)' || return 1
                bh_ask_option RETRY 'Retry interval (seconds)' || return 1
                if [ "$transport" != udp ]; then
                    bh_ask_option DIAL 'Dial timeout (seconds)' || return 1
                    bh_ask_option AGGRESSIVE 'Aggressive pool (true/false)' || return 1
                fi
            fi
            [ "$transport" = udp ] || bh_ask_option KEEPALIVE 'TCP keepalive (seconds)' || return 1
            if [[ "$transport" == *mux ]]; then
                echo -e "  ${FR}├─${NC} ${Y}Use matching MUX version/frame/buffer settings on both peers.${NC}"
                [ "$role" != 1 ] || bh_ask_option MUX_CON 'Streams per MUX connection (1-1024)' || return 1
                bh_ask_option MUX_VERSION 'MUX version (1/2)' || return 1
                bh_ask_option MUX_FRAME 'Maximum MUX frame (bytes, 512-65535)' || return 1
                bh_ask_option MUX_RECEIVE 'MUX receive buffer (bytes)' || return 1
                bh_ask_option MUX_STREAM 'MUX stream buffer (bytes <= receive buffer)' || return 1
            fi
            if [[ "$transport" == tcp || "$transport" == tcpmux || "$transport" == tls || "$transport" == tlsmux ]]; then
                bh_ask_option NODELAY 'TCP_NODELAY (true/false)' || return 1
                echo -e "  ${FR}├─${NC} ${W}Link MTU derives TCP MSS = MTU - 60 (IPv6-safe); interface MTU is unchanged.${NC}"
                bh_ask_option MTU 'Link MTU (0: use MSS below; 1280-9000)' || return 1
                [ "${BH_OPTS[MTU]}" != 0 ] || bh_ask_option MSS 'TCP MSS (0: kernel default)' || return 1
                bh_ask_option RCVBUF 'Socket receive buffer (bytes; 0: kernel default)' || return 1
                bh_ask_option SNDBUF 'Socket send buffer (bytes; 0: kernel default)' || return 1
            elif [[ "$transport" == kcp || "$transport" == kcpmux ]]; then
                bh_ask_option RCVBUF 'UDP receive buffer (bytes; 0: kernel default)' || return 1
                bh_ask_option SNDBUF 'UDP send buffer (bytes; 0: kernel default)' || return 1
            elif [[ "$transport" == ws* || "$transport" == xhttp* ]]; then
                bh_ask_option NODELAY 'TCP_NODELAY (true/false)' || return 1
            fi
            if [ "$role" = 1 ] && [[ "$transport" == tcp || "$transport" == tls || "$transport" == kcp || "$transport" == xhttp || "$transport" == xhttps || "$transport" == *mux ]]; then
                echo -e "  ${FR}├─${NC} ${Y}PROXY protocol requires a compatible service at the destination.${NC}"
                bh_ask_option PROXY 'Send PROXY protocol header (true/false)' || return 1
            fi
            if [[ "$transport" == kcp || "$transport" == kcpmux ]]; then
                bh_ask_option KCP_MODE 'KCP mode (fast3/fast2/fast/normal)' || return 1
                bh_ask_option KCP_CRYPT 'KCP encryption (aes/salsa20/xor/none)' || return 1
                bh_ask_option KCP_NOFEC 'Disable KCP FEC overhead (true/false)' || return 1
            fi
            if [[ "$transport" == xhttp* ]]; then
                bh_ask_option XHTTP_PATH 'XHTTP stream path (e.g. /api/v1/stream)' || return 1
                if [ "$role" = 2 ]; then
                    bh_ask_option XHTTP_MODE 'XHTTP upload mode (auto/stream-up/packet-up)' || return 1
                    bh_ask_option XHTTP_HOST 'Optional XHTTP Host header' || return 1
                fi
            fi
            if [ "$role" = 2 ] && [[ "$transport" == tls || "$transport" == tlsmux || "$transport" == wss || "$transport" == wssmux || "$transport" == xhttps || "$transport" == xhttpsmux ]]; then
                bh_ask_option SNI 'TLS SNI hostname (empty: auto from domain / cloudflare)' || return 1
                bh_ask_option UTLS 'uTLS fingerprint (chrome/firefox/safari/edge/ios/random/none)' || return 1
            fi
            if [ "$role" = 2 ] && [[ "$transport" == tls || "$transport" == tlsmux || "$transport" == ws* || "$transport" == xhttp* ]]; then
                bh_ask_option EDGE 'Optional Edge / CDN IP' || return 1
            fi
            if [ "$role" = 1 ] && [[ "$transport" == tls || "$transport" == tlsmux || "$transport" == wss || "$transport" == wssmux || "$transport" == xhttps || "$transport" == xhttpsmux ]]; then
                echo -e "  ${FR}├─${NC} ${W}TLS paths: leave empty for built-in Auto-TLS (in-memory ECDSA P-256).${NC}"
                echo -ne "  ${FR}├─${NC} ${W}Certificate path [${BH_OPTS[TLS_CERT]:-Auto-TLS}; -: Auto-TLS]${NC} ${C}❯❯ ${NC}"; read -r choice || return 1
                if [ "$choice" = - ]; then BH_OPTS[TLS_CERT]=""; BH_OPTS[TLS_KEY]=""
                elif [ -n "$choice" ]; then
                    BH_OPTS[TLS_CERT]="$choice"
                    echo -ne "  ${FR}├─${NC} ${W}Private key path${NC} ${C}❯❯ ${NC}"; read -r choice || return 1; BH_OPTS[TLS_KEY]="$choice"
                fi
                if [ -z "${BH_OPTS[TLS_CERT]}" ]; then
                    bh_ask_option SNI 'Auto-TLS cert CN / SNI (empty: www.cloudflare.com)' || return 1
                fi
            fi
            ;;
        "")
            [[ "$current_prof" =~ ^(ECO|BALANCED|SPEED|LATENCY|EXTREME)$ ]] && bh_apply_profile_defaults "$current_prof"
            ;;
        q|Q) return 1 ;;
        *) echo -e "  ${R}✖ Invalid profile selection.${NC}"; return 1 ;;
    esac

    bh_validate_options || return 1
    BH_SETTINGS_FILE=$(mktemp "$SECURE_TMP/bh-settings.XXXXXX") || return 1
    printf 'PROFILE=%s\n' "${BH_PROFILE:-BALANCED}" > "$BH_SETTINGS_FILE"
    for key in "${!BH_OPTS[@]}"; do printf 'ADV_%s=%s\n' "$key" "${BH_OPTS[$key]}"; done >> "$BH_SETTINGS_FILE"
}
bh_emit_options() {
    local role="$1" transport="$2" key mss="${BH_OPTS[MSS]}"
    printf 'log_level = "%s"\nsniffer = false\nweb_port = 0\n' "${BH_OPTS[LOG]}"
    if [ "$role" = 1 ]; then
        printf 'channel_size = %s\nheartbeat = %s\n' "${BH_OPTS[CHANNEL]}" "${BH_OPTS[HEARTBEAT]}"
        if [[ "$transport" == tls || "$transport" == tlsmux || "$transport" == wss || "$transport" == wssmux || "$transport" == xhttps || "$transport" == xhttpsmux ]]; then
            [ -z "${BH_OPTS[SNI]}" ] || printf 'sni = "%s"\n' "${BH_OPTS[SNI]}"
        fi
    else
        printf 'connection_pool = %s\nretry_interval = %s\n' "${BH_OPTS[POOL]}" "${BH_OPTS[RETRY]}"
        [ "$transport" = udp ] || printf 'dial_timeout = %s\naggressive_pool = %s\n' "${BH_OPTS[DIAL]}" "${BH_OPTS[AGGRESSIVE]}"
        if [[ "$transport" == tls || "$transport" == tlsmux || "$transport" == ws* || "$transport" == xhttp* ]]; then
            local edge="${BH_OPTS[EDGE]}"; [[ "$edge" != *:* ]] || edge="[$edge]"
            printf 'edge_ip = "%s"\n' "$edge"
        fi
        if [[ "$transport" == tls || "$transport" == tlsmux || "$transport" == wss || "$transport" == wssmux || "$transport" == xhttps || "$transport" == xhttpsmux ]]; then
            [ -z "${BH_OPTS[SNI]}" ] || printf 'sni = "%s"\n' "${BH_OPTS[SNI]}"
            printf 'utls_fingerprint = "%s"\n' "${BH_OPTS[UTLS]:-chrome}"
        fi
        if [[ "$transport" == xhttp* ]]; then
            printf 'xhttp_mode = "%s"\n' "${BH_OPTS[XHTTP_MODE]}"
            [ -z "${BH_OPTS[XHTTP_HOST]}" ] || printf 'xhttp_host = "%s"\n' "${BH_OPTS[XHTTP_HOST]}"
        fi
    fi
    [ "$transport" = udp ] || printf 'keepalive_period = %s\n' "${BH_OPTS[KEEPALIVE]}"
    if [[ "$transport" == kcp || "$transport" == kcpmux ]]; then
        printf 'kcp_mode = "%s"\nkcp_crypt = "%s"\nkcp_nofec = %s\nso_rcvbuf = %s\nso_sndbuf = %s\n' "${BH_OPTS[KCP_MODE]}" "${BH_OPTS[KCP_CRYPT]}" "${BH_OPTS[KCP_NOFEC]}" "${BH_OPTS[RCVBUF]}" "${BH_OPTS[SNDBUF]}"
    fi
    if [[ "$transport" == xhttp* ]]; then
        printf 'xhttp_path = "%s"\n' "${BH_OPTS[XHTTP_PATH]}"
    fi
    if [[ "$transport" == *mux ]]; then
        [ "$role" != 1 ] || printf 'mux_con = %s\n' "${BH_OPTS[MUX_CON]}"
        printf 'mux_version = %s\nmux_framesize = %s\nmux_recievebuffer = %s\nmux_streambuffer = %s\n' "${BH_OPTS[MUX_VERSION]}" "${BH_OPTS[MUX_FRAME]}" "${BH_OPTS[MUX_RECEIVE]}" "${BH_OPTS[MUX_STREAM]}"
    fi
    if [[ "$transport" == tcp || "$transport" == tcpmux || "$transport" == tls || "$transport" == tlsmux ]]; then
        [ "${BH_OPTS[MTU]}" = 0 ] || mss=$((BH_OPTS[MTU]-60))
        printf 'nodelay = %s\nmss = %s\nso_rcvbuf = %s\nso_sndbuf = %s\n' "${BH_OPTS[NODELAY]}" "$mss" "${BH_OPTS[RCVBUF]}" "${BH_OPTS[SNDBUF]}"
    elif [[ "$transport" == ws* || "$transport" == xhttp* ]]; then
        printf 'nodelay = %s\n' "${BH_OPTS[NODELAY]}"
    fi
    if [ "$role" = 1 ] && [[ "$transport" == tcp || "$transport" == tls || "$transport" == kcp || "$transport" == xhttp || "$transport" == xhttps || "$transport" == *mux ]]; then printf 'proxy_protocol = %s\n' "${BH_OPTS[PROXY]}"; fi
}

bh_validate_tls_pair() {
    local cert="$1" key="$2" certpub keypub
    command -v openssl >/dev/null 2>&1 || { echo 'Install openssl for WSS / WSSMUX.' >&2; return 1; }
    [ -f "$cert" ] && [ -f "$key" ] || return 1
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
    certpub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || return 1
    keypub=$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null) || return 1
    [ -n "$certpub" ] && [ "$certpub" = "$keypub" ]
}

bh_service_ready() {
    local unit="$1" i
    for i in 1 2 3 4; do sleep 0.4; systemctl is-active --quiet "$unit" || return 1; done
}

bh_start_screen() {
    draw_header
}

bh_ensure_download_tools() {
    local need_zip="${1:-0}" missing=() log
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then missing+=(curl); fi
    if [ "$need_zip" = 1 ] && ! command -v unzip >/dev/null 2>&1; then missing+=(unzip); fi
    [ -s /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
    [ "${#missing[@]}" -gt 0 ] || return 0
    command -v apt-get >/dev/null 2>&1 || { echo "Install the missing packages: ${missing[*]}" >&2; return 1; }
    echo -e "  ${DIM}● Installing download prerequisites: ${missing[*]}...${NC}"
    log=$(mktemp "$SECURE_TMP/rh-deps.XXXXXX") || return 1
    DEBIAN_FRONTEND=noninteractive timeout 120 apt-get -o DPkg::Lock::Timeout=45 update -q > "$log" 2>&1 || true
    if ! DEBIAN_FRONTEND=noninteractive timeout 180 apt-get -o DPkg::Lock::Timeout=45 install -y -q "${missing[@]}" >> "$log" 2>&1; then
        echo 'Download prerequisites could not be installed:' >&2
        tail -n 6 "$log" >&2; rm -f "$log"; return 1
    fi
    rm -f "$log"
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || return 1
    [ "$need_zip" != 1 ] || command -v unzip >/dev/null 2>&1 || return 1
    [ -s /etc/ssl/certs/ca-certificates.crt ] || { echo 'System CA certificate bundle is missing.' >&2; return 1; }
}

bh_download() {
    local url="$1" dest="$2" tmp log tool family rc=1 code permanent=false
    [[ "$url" == https://* ]] || { echo 'Download requires an HTTPS URL.' >&2; return 1; }
    tmp=$(mktemp "${dest}.download.XXXXXX") || return 1
    log=$(mktemp "$SECURE_TMP/rh-download.XXXXXX") || { rm -f "$tmp"; return 1; }
    local -a args=()
    for tool in curl wget; do
        command -v "$tool" >/dev/null 2>&1 || continue
        for family in auto ipv4; do
            args=(); [ "$family" != ipv4 ] || args=(-4)
            : > "$tmp"
            echo -e "  ${DIM}● Downloading with $tool ($family)...${NC}"
            if [ "$tool" = curl ]; then
                code=$(curl "${args[@]}" -fsSL --proto '=https' --proto-redir '=https' \
                    --connect-timeout 10 --max-time 120 --retry 1 -w '%{http_code}' -o "$tmp" "$url" 2> "$log"); rc=$?
                if [ "$rc" = 22 ] && [[ "$code" =~ ^(400|401|403|404|410)$ ]]; then permanent=true; fi
            else
                wget "${args[@]}" --https-only --timeout=30 --tries=2 -O "$tmp" "$url" 2> "$log"; rc=$?
                [ "$rc" != 8 ] || permanent=true
            fi
            if [ "$rc" = 0 ] && [ -s "$tmp" ]; then
                mv -f "$tmp" "$dest"; rc=$?
                rm -f "$log"; return "$rc"
            fi
            [ "$permanent" != true ] || break
        done
        [ "$permanent" != true ] || break
    done
    echo 'Backhaul download failed:' >&2
    if [ -s "$log" ]; then tail -n 4 "$log" >&2; else echo 'The server returned an empty file or no downloader is available.' >&2; fi
    rm -f "$tmp" "$log"; return 1
}

generate_ssl_cert() {
    command -v openssl >/dev/null 2>&1 || { echo 'Install openssl before using WSS / WSSMUX.' >&2; return 1; }
    if bh_validate_tls_pair "$CERT_DIR/wssmux.crt" "$CERT_DIR/wssmux.key"; then return 0; fi
    local work; work=$(mktemp -d "$SECURE_TMP/bh-cert.XXXXXX") || return 1
    mkdir -p "$CERT_DIR" || { rm -rf "$work"; return 1; }
    if ! openssl req -x509 -newkey rsa:2048 -keyout "$work/key" -out "$work/cert" -days 3650 -nodes \
        -subj "/CN=mdesign-backhaul" -addext "subjectAltName=DNS:mdesign-backhaul,IP:127.0.0.1,IP:::1" >/dev/null 2>&1 || \
        ! bh_validate_tls_pair "$work/cert" "$work/key" || \
        ! mt_install_files 600 "$work/cert" "$CERT_DIR/wssmux.crt" "$work/key" "$CERT_DIR/wssmux.key"; then
        rm -rf "$work"; echo 'TLS certificate generation failed.' >&2; return 1
    fi
    rm -rf "$work"
}

bh_validate_package() {
    local source="$1" stage item count=0
    mt_valid_elf "$source" && return 0
    stage=$(mktemp -d "$SECURE_TMP/rh-validate.XXXXXX") || return 1
    if ! mt_extract_archive "$source" "$stage"; then rm -rf "$stage"; return 1; fi
    while IFS= read -r item; do
        mt_valid_elf "$item" && count=$((count+1))
    done < <(find "$stage" -type f \( -name '*backhaul*' -o -name '*bh*' \))
    rm -rf "$stage"
    [ "$count" = 1 ]
}

install_core_from_source() {
    local src_choice="$1" triplet asset url kind=url source="" work item local_source="" need_zip=0 chosen_url=""
    triplet=$(case "$(uname -m)" in x86_64) echo amd64;; aarch64|arm64) echo arm64;; *) exit 1;; esac) || { echo -e "  ${R}✖ Unsupported CPU architecture.${NC}"; return 1; }
    asset="backhaul_linux_${triplet}.tar.gz"
    local -a urls=()
    # Core comes from the project's own GitHub repo (engines/), never from the upstream Backhaul releases.
    local gh_base="${MTUNNEL_GITHUB_BASE:-https://raw.githubusercontent.com/htzserv/MTunnel/main}"
    local -a gh_urls=("${gh_base}/engines/$asset")
    [ "$triplet" != amd64 ] || gh_urls+=("${gh_base}/engines/bh")
    case "$src_choice" in
        1) urls=("${gh_urls[@]}"); need_zip=0;;
        2)
            urls=("${MTUNNEL_MIRROR_BASE}/engines/$asset")
            # The unqualified mirror binary is the bundled x86_64 build only.
            [ "$triplet" != amd64 ] || urls+=("${MTUNNEL_MIRROR_BASE}/engines/bh")
            urls+=("${gh_urls[@]}")
            need_zip=0;;
        5)
            # Strict MTunnel GitHub source for Smart prerequisite installation.
            urls=("${gh_urls[@]}")
            need_zip=0;;
        6)
            # Strict MTunnel mirror source for Smart prerequisite installation.
            urls=("${MTUNNEL_MIRROR_BASE}/engines/$asset")
            [ "$triplet" != amd64 ] || urls+=("${MTUNNEL_MIRROR_BASE}/engines/bh")
            need_zip=0;;
        3)
            echo -ne "  ${C}● Enter Direct Link: ${NC}"; read -r url || return 0
            url="${url//$'\r'/}"; [ -n "$url" ] || return 0
            [[ "$url" == https://* ]] || { echo 'Use an HTTPS direct link.' >&2; return 1; }
            urls=("$url"); need_zip=0;;
        4)
            kind=local
            for item in "$LOCAL_DIR/engines/bh" "$LOCAL_DIR/engines/backhaul" "$LOCAL_DIR/engines/$asset"; do
                [ -f "$item" ] || continue
                if [[ "$item" != *.tar.gz && "$item" != *.zip ]] && ! mt_valid_elf "$item"; then continue; fi
                source="$item"; break
            done
            [ -n "$source" ] || { echo "No compatible Backhaul binary or $asset found in $LOCAL_DIR/engines." >&2; return 1; }
            [[ "$source" != *.zip ]] || need_zip=1;;
        *) return 0;;
    esac
    # Do not require internet/download utilities for a local binary.
    if [ "$kind" = url ]; then bh_ensure_download_tools "$need_zip" || return 1
    elif [ "$need_zip" = 1 ] && ! command -v unzip >/dev/null 2>&1; then
        echo 'Install unzip to use a local ZIP; an unpacked local binary needs no download tools.' >&2; return 1
    fi
    echo -e "  ${DIM}● Preparing Backhaul Core ($triplet)...${NC}"
    if [ "$kind" = url ]; then
        work=$(mktemp -d "$SECURE_TMP/rh-package.XXXXXX") || return 1
        source=""
        for url in "${urls[@]}"; do
            local source_host="${url#https://}"; source_host="${source_host%%/*}"; source_host="${source_host##*@}"
            echo -e "  ${DIM}● Source: $source_host${NC}"
            if bh_download "$url" "$work/package"; then
                if bh_validate_package "$work/package"; then source="$work/package"; chosen_url="$url"; break
                else echo 'Downloaded file is not a compatible Backhaul binary/archive.' >&2; fi
            fi
            [ "$url" = "${urls[-1]}" ] || echo -e "  ${Y}● Trying the next download source...${NC}"
        done
        [ -n "$source" ] || { rm -rf "$work"; echo -e "  ${R}✖ Download failed. Previous installation preserved.${NC}" >&2; return 1; }
        mt_engine_cache "$source" "$chosen_url"
    fi
    local prev_bh="" bh_new_bin
    if is_bh_core_valid; then
        prev_bh=$(mktemp "$SECURE_TMP/bh-prev.XXXXXX") && cp -pL "$(bh_core_bin)" "$prev_bh" 2>/dev/null || prev_bh=""
    fi
    if mt_update_core bh mbackhaul "$source" local; then
        [ -z "$work" ] || rm -rf "$work"
        bh_new_bin=$(bh_core_bin) || bh_new_bin=""
        if [ -n "$bh_new_bin" ] && ! bh_core_version_ok "$bh_new_bin"; then
            echo -e "  ${R}✖ The installed core reports v${BH_PROBED_VERSION}, but v${BH_EXPECT_VERSION} is required by these modules.${NC}" >&2
            echo -e "  ${DIM}  The source you chose provides the wrong Backhaul version.${NC}" >&2
            if [ -n "$prev_bh" ] && bh_restore_core "$prev_bh"; then
                echo -e "  ${Y}● Previous working core restored.${NC}" >&2
            fi
            [ -z "$prev_bh" ] || rm -f "$prev_bh"
            return 1
        fi
        [ -z "$prev_bh" ] || rm -f "$prev_bh"
        echo -e "  ${G}✔ Backhaul Core installed successfully.${NC}"
        echo -e "  ${DIM}● Previously active tunnels restarted.${NC}"
    else
        [ -z "$work" ] || rm -rf "$work"
        echo -e "  ${R}✖ Package extraction, validation or service restart failed. Previous installation preserved.${NC}" >&2
        return 1
    fi
}

mt_core_version() {
    local out
    out=$(timeout 3 bh -v 2>&1 </dev/null | head -n1)
    [ -n "$out" ] || out=$(timeout 3 bh -V 2>&1 </dev/null | head -n1)
    out=$(printf '%s' "$out" | grep -oE '[0-9]+(\.[0-9A-Za-z-]+)+' | head -n1)
    printf '%s' "${out:-not-installed}"
}
mt_install_local_bundle() {
    local installer="$LOCAL_DIR/install.sh" rc=0
    if [ -f "$installer" ]; then
        bash "$installer" --local "$LOCAL_DIR" --no-launch || rc=1
    else
        echo -e "  ${R}✖ $LOCAL_DIR/install.sh was not found.${NC}"; rc=1
    fi
    if ! install_core_from_source 4; then
        echo -e "  ${Y}● Local Backhaul core was not found; scripts/tools were still processed.${NC}"
        rc=1
    fi
    return "$rc"
}
render_unified_update_menu() {
    local gh_label mirror_label core_v core_tag=""
    gh_label=$(mt_update_label "$SECURE_TMP/.mbackhaul_remote_ver_github")
    mirror_label=$(mt_update_label "$SECURE_TMP/.mbackhaul_remote_ver_mirror")
    core_v=$(mt_core_version)
    if [ -n "$core_v" ] && [ "$core_v" != "not-installed" ]; then
        if is_bh_core_valid; then core_tag=" ${G}(installed)${NC}"
        else core_tag=" ${Y}(installed v${core_v}; v${BH_EXPECT_VERSION} required)${NC}"; fi
    fi
    mt_workspace_screen
    echo -e "\n  ${FR}┌─[ UPDATE & LOCAL INSTALL — MBACKHAUL ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Install Core From Github${NC}${core_tag}"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Install Core From Iranian Mirror${NC}${core_tag}"
    echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Install Script From Github${NC} ${DIM}(${gh_label})${NC}"
    echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Install Script From Iranian Mirror${NC} ${DIM}(${mirror_label})${NC}"
    echo -e "  ${FR}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Install Everything from /root/mtunnel${NC}"
    echo -e "  ${FR}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${Y}Paste Script Code Manually${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return${NC}\n"
}
unified_update_menu() {
    local opt
    while true; do
        render_unified_update_menu
        read_with_refresh "  ${C}MBACKHAUL UPDATE ❯❯ ${NC}" opt render_unified_update_menu || return 0
        opt="${opt//$'\r'/}"
        case "$opt" in
            1) install_core_from_source 1; mt_workspace_pause;;
            2) install_core_from_source 2; mt_workspace_pause;;
            3) self_update_module 1; mt_workspace_pause;;
            4) self_update_module 2; mt_workspace_pause;;
            5) mt_install_local_bundle; mt_workspace_pause;;
            6) self_update_module 4; mt_workspace_pause;;
            0|q|Q) return 0;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1;;
        esac
    done
}

menu_install_core() {
    echo -e "\n  ${FR}┌─[ INSTALL / UPDATE BACKHAUL CORE ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}GitHub Repo${NC}"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Iranian Mirror${NC} ${DIM}(${MTUNNEL_MIRROR_BASE})${NC}"
    echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
    echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/engines)${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r src_choice
    src_choice=$(echo "$src_choice" | tr -d '\r')

    [[ "$src_choice" =~ ^[1-4]$ ]] && install_core_from_source "$src_choice"
}

check_first_run_core() {
    if ! is_bh_core_valid; then
        local first_prompt_flag="$CONF_DIR/.core_prompted"
        if [ "$(cat "$first_prompt_flag" 2>/dev/null)" != "$MODULE_VERSION" ]; then
            clear
            echo -e "\n  ${FR}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
            local core_msg="Backhaul Core binary is NOT installed on this machine!"
            if bh_core_bin >/dev/null; then bh_probe_version "$(bh_core_bin)"; core_msg="Installed Backhaul Core is v${BH_PROBED_VERSION}; v${BH_EXPECT_VERSION} is required!"; fi
            printf '  %b║%b   %b● %-71.71s%b%b║%b\n' "$FR" "$NC" "$R" "$core_msg" "$NC" "$FR" "$NC"
            echo -e "  ${FR}║${NC}   ${W}Would you like to install the Core binary now?${NC}                           ${FR}║${NC}"
            echo -e "  ${FR}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}GitHub Repo${NC}"
            echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Iranian Mirror${NC} ${DIM}(${MTUNNEL_MIRROR_BASE})${NC}"
            echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Direct Link${NC} ${DIM}(Binary or .tar.gz)${NC}"
            echo -e "  ${FR}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Local Directory (/root/mtunnel/engines)${NC}"
            echo -e "  ${FR}│${NC}"
            echo -e "  ${FR}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Skip for now${NC}\n"
            echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r init_opt
            init_opt=$(echo "$init_opt" | tr -d '\r')
            if [[ "$init_opt" =~ ^[1-4]$ ]]; then
                if install_core_from_source "$init_opt"; then printf '%s\n' "$MODULE_VERSION" > "$first_prompt_flag"
                else rm -f "$first_prompt_flag"; return 1; fi
            elif [[ "$init_opt" = q || -z "$init_opt" ]]; then
                printf '%s\n' "$MODULE_VERSION" > "$first_prompt_flag"
            else return 1
            fi
        fi
    fi
}

setup_bh_counters() {
    local proto
    proto=$(bh_meta_value TRANSPORT "$CONF_DIR/$1.meta" 2>/dev/null)
    [[ "$proto" =~ ^(udp|kcp|kcpmux)$ ]] && proto=udp || proto=tcp
    mt_setup_counter_pair MBH "$1" "$2" "$3" "$4" "${5:-0.0.0.0}" "$proto"
}

clean_bh_counters() {
    local bin chain direction
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        for direction in RX TX; do
            for chain in INPUT OUTPUT; do mt_delete_tagged_rules "$bin" mangle "$chain" "MBH_${direction}_$1"; done
        done
    done
}

zero_bh_counters() {
    local bin chain direction num
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        for chain in INPUT OUTPUT; do
            for direction in RX TX; do
                while read -r num; do [ -n "$num" ] && "$bin" -w 5 -t mangle -Z "$chain" "$num"; done < <(mt_tagged_rules "$bin" mangle "$chain" "MBH_${direction}_$1")
            done
        done
    done
}

# Backhaul remains the transport; external forwarders use separate local ingress ports.
bh_meta_value() {
    [ -f "$2" ] || return 0
    mt_config_value "$1" "$2"
}

bh_expanded_ports() {
    local list="$1" bind="$2" raw lhs rhs host start end p
    local -a items=(); IFS=, read -ra items <<< "$list"
    for raw in "${items[@]}"; do
        raw="${raw// /}"; lhs="${raw%%=*}"; rhs=""
        [[ "$raw" != *=* ]] || rhs="${raw#*=}"
        host="$bind"
        if [[ "$lhs" == *:* ]]; then
            host=$(mt_normalize_host "${lhs%:*}"); start="${lhs##*:}"; end="$start"
        else start="${lhs%-*}"; end="${lhs#*-}"; fi
        for ((p=10#$start;p<=10#$end;p++)); do
            printf '%s|%s|%s\n' "$p" "$host" "${rhs:-127.0.0.1:$p}"
        done
    done
}

bh_choose_forwarder() {
    local choice current="${1:-backhaul}"
    echo -e "\n  ${FR}┌─[ FORWARDING ENGINE ]${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Backhaul (Built-in TCP / UDP)${NC}"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}iptables (TCP / UDP)${NC}"
    echo -e "  ${FR}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}MPorter (Select its TCP engine separately)${NC}"
    echo -ne "  ${FR}└─${NC} ${C}Select [Enter: ${current}, q: cancel] ❯❯ ${NC}"
    read -r choice || return 1
    case "${choice//$'\r'/}" in
        1) BH_FORWARDER=backhaul;; 2) BH_FORWARDER=iptables;; 3) BH_FORWARDER=mporter;;
        '') BH_FORWARDER="$current";; *) return 1;;
    esac
}

bh_backend_in_use() {
    local ip rc; ip=$(bh_meta_value BACKEND_IP "$CONF_DIR/$1.meta")
    [[ "$ip" == 127.77.* ]] && [ -x /usr/bin/mporter ] || return 1
    # Older MPorter has no read-only probe; don't accidentally open its menu.
    grep -q '^mp_bh_records()' /usr/bin/mporter || return 0
    /usr/bin/mporter --backhaul-in-use "$ip"; rc=$?
    [ "$rc" != 1 ]
}

bh_prepare_backend() {
    # Called while the config writer holds the allocation lock.
    local name="$1" ports="$2" bind="$3" link_port="$4" conf spec pair public host rhs candidate n ip
    local -a pairs=()
    local old; old=$(bh_meta_value BACKEND_PORTS "$CONF_DIR/$name.meta")
    BH_BACKEND_IP=$(bh_meta_value BACKEND_IP "$CONF_DIR/$name.meta")
    local -A reserved=() old_ports=() ips=() publics=()
    while IFS='|' read -r public host rhs; do publics[$public]=1; done < <(bh_expanded_ports "$ports" "$bind")
    [ "${#publics[@]}" -le 1024 ] || { echo 'External forwarding supports up to 1024 ports per tunnel.' >&2; return 1; }
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        ip=$(bh_meta_value BACKEND_IP "$conf"); [ -z "$ip" ] || ips[$ip]=1
        n=$(bh_meta_value TUN_PORT "$conf"); if mt_valid_port "$n"; then reserved[$n]=1; fi
        while IFS='|' read -r public host rhs; do reserved[$public]=1; done < <(bh_expanded_ports "$(bh_meta_value PORTS "$conf")" "$(bh_meta_value BIND_HOST "$conf")")
        spec=$(bh_meta_value BACKEND_PORTS "$conf")
        IFS=, read -ra pairs <<< "$spec"
        for pair in "${pairs[@]}"; do
            public="${pair%:*}"; n="${pair##*:}"
            mt_valid_port "$public" && mt_valid_port "$n" || continue
            if [ "$conf" = "$CONF_DIR/$name.meta" ]; then old_ports[$public]="$n"; fi
            reserved[$n]=1
        done
    done
    if ! [[ "$BH_BACKEND_IP" =~ ^127\.77\.[0-9]+\.[0-9]+$ ]] || ! mt_valid_ipv4 "$BH_BACKEND_IP"; then
        BH_BACKEND_IP=""
        for ((n=1;n<65535;n++)); do
            ip="127.77.$((n/256)).$((n%256))"
            [ -n "${ips[$ip]:-}" ] || { BH_BACKEND_IP="$ip"; break; }
        done
    fi
    [ -n "$BH_BACKEND_IP" ] || return 1
    BH_BACKEND_PORTS=""; BH_BACKEND_LINES=""; candidate=45000
    BH_BACKEND_BIND=0.0.0.0
    if [ -r /proc/net/if_inet6 ] && grep -q . /proc/net/if_inet6; then BH_BACKEND_BIND=::; fi
    command -v iptables >/dev/null 2>&1 || { echo 'Install iptables before selecting an external forwarder.' >&2; return 1; }
    [ "$BH_BACKEND_BIND" != :: ] || command -v ip6tables >/dev/null 2>&1 || return 1
    while IFS='|' read -r public host rhs; do
        n="${old_ports[$public]:-}"
        if [ -n "$n" ] && { [ "$n" = "$link_port" ] || [ -n "${publics[$n]:-}" ]; }; then
            if bh_backend_in_use "$name"; then
                echo 'An existing backend port conflicts with a requested port. Remove its MPorter mappings first.' >&2; return 1
            fi
            n=""
        fi
        if [ -z "$n" ]; then
            while [ "$candidate" -le 60999 ]; do
                if [ -z "${reserved[$candidate]:-}" ] && [ -z "${publics[$candidate]:-}" ] && [ "$candidate" != "$link_port" ] && ! mt_port_busy "$candidate" any; then break; fi
                candidate=$((candidate+1))
            done
            [ "$candidate" -le 60999 ] || { echo 'No free backend ports in 45000-60999.' >&2; return 1; }
            n="$candidate"; reserved[$n]=1; candidate=$((candidate+1))
        fi
        BH_BACKEND_PORTS+="${BH_BACKEND_PORTS:+,}$public:$n"
        BH_BACKEND_LINES+="${BH_BACKEND_LINES:+, }\"$(mt_hostport "$BH_BACKEND_BIND" "$n")=$rhs\""
    done < <(bh_expanded_ports "$ports" "$bind")
}

bh_show_forwarder() {
    local name="$1" meta="$CONF_DIR/$1.meta" mode ip pair
    mode=$(bh_meta_value FORWARDER "$meta")
    [ -n "$mode" ] && [ "$mode" != backhaul ] || return 0
    echo -e "  ${FR}├─${NC} ${W}Forwarder:${NC} ${C}${mode}${NC}"
    [ "$mode" = mporter ] || return 0
    ip=$(bh_meta_value BACKEND_IP "$meta")
    echo -e "  ${FR}├─${NC} ${W}MPorter Target IP:${NC} ${G}$ip${NC} ${DIM}(this server only)${NC}"
    local -a pairs=(); IFS=, read -ra pairs <<< "$(bh_meta_value BACKEND_PORTS "$meta")"
    for pair in "${pairs[@]}"; do
        printf "  ${FR}├─${NC} ${W}%-5s${NC} ${DIM}❯${NC} ${G}%s:%s${NC} ${DIM}(TCP)${NC}\n" "${pair%:*}" "$ip" "${pair##*:}"
    done
    echo -e "  ${FR}└─${NC} ${W}Open MPorter > Add Port Mappings > Backhaul Targets; ports are matched automatically.${NC}"
}

bh_forward_chain() {
    local hash; hash=$(printf '%s' "$1" | sha256sum); printf 'MBHF_%s' "${hash:0:16}"
}

bh_clear_forwarder() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    local chain bin parent table; chain=$(bh_forward_chain "$1")
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        for table in filter nat; do
            if [ "$table" = filter ]; then
                while "$bin" -w 5 -t filter -C INPUT -j "${chain}G" 2>/dev/null; do "$bin" -w 5 -t filter -D INPUT -j "${chain}G" || return 1; done
                "$bin" -w 5 -t filter -F "${chain}G" 2>/dev/null || true
                "$bin" -w 5 -t filter -X "${chain}G" 2>/dev/null || true
            else
                for parent in PREROUTING OUTPUT; do
                    while "$bin" -w 5 -t nat -C "$parent" -j "$chain" 2>/dev/null; do "$bin" -w 5 -t nat -D "$parent" -j "$chain" || return 1; done
                done
                "$bin" -w 5 -t nat -F "$chain" 2>/dev/null || true
                "$bin" -w 5 -t nat -X "$chain" 2>/dev/null || true
            fi
        done
    done
}

bh_apply_forwarder() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    local fd rc
    exec {fd}>"$CONF_DIR/.forwarder-firewall.lock" || return 1
    flock -x "$fd" || { exec {fd}>&-; return 1; }
    bh_apply_forwarder_locked "$1"; rc=$?
    if [ "$rc" != 0 ]; then
        bh_clear_forwarder "$1"
        echo "Backhaul forwarder firewall failed for $1; partial rules removed. Check iptables/ip6tables -w 5 errors above." >&2
    fi
    exec {fd}>&-
    return "$rc"
}

bh_apply_forwarder_locked() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    local name="$1" meta="$CONF_DIR/$1.meta" mode bind spec pair public private host rhs bin proto chain
    [ -f "$meta" ] || return 1
    mode=$(bh_meta_value FORWARDER "$meta"); mode="${mode:-backhaul}"
    [[ "$mode" =~ ^(backhaul|iptables|mporter)$ ]] || return 1
    bh_clear_forwarder "$name" || return 1
    [ "$mode" != backhaul ] && [ "$(bh_meta_value ROLE "$meta")" = 1 ] || return 0
    bind=$(bh_meta_value BACKEND_BIND "$meta"); [[ "$bind" = :: || "$bind" = 0.0.0.0 ]] || return 1
    spec=$(bh_meta_value BACKEND_PORTS "$meta"); [ -n "$spec" ] || return 1
    local -a pairs=() bins=(iptables) protos=(tcp) match=(); IFS=, read -ra pairs <<< "$spec"
    [ "$bind" != :: ] || bins+=(ip6tables)
    if [ "$(bh_meta_value TRANSPORT "$meta")" = udp ]; then protos=(udp)
    elif [ "$(bh_meta_value TRANSPORT "$meta")" = tcp ] && [ "$(bh_meta_value ENABLE_UDP "$meta")" = true ]; then protos+=(udp); fi
    chain=$(bh_forward_chain "$name")
    for bin in "${bins[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || return 1
        # Guard is installed before the process listens; private ingress is local/DNAT only.
        "$bin" -w 5 -t filter -N "${chain}G" || return 1
        for pair in "${pairs[@]}"; do
            public="${pair%:*}"; private="${pair##*:}"
            mt_valid_port "$public" && mt_valid_port "$private" || return 1
            for proto in "${protos[@]}"; do
                "$bin" -w 5 -t filter -A "${chain}G" -i lo -p "$proto" --dport "$private" -j ACCEPT || return 1
                "$bin" -w 5 -t filter -A "${chain}G" -p "$proto" --dport "$private" -m conntrack --ctstatus DNAT -j ACCEPT || return 1
                "$bin" -w 5 -t filter -A "${chain}G" -p "$proto" --dport "$private" -j DROP || return 1
            done
        done
        "$bin" -w 5 -t filter -I INPUT 1 -j "${chain}G" || return 1
        if [ "$mode" = mporter ]; then
            # The frontend has a public listener too; accept its configured ports
            # before a host firewall's later INPUT drop/reject rules.
            while IFS='|' read -r public host rhs; do
                if [ "$bin" = ip6tables ]; then mt_valid_ipv6 "$host" || continue
                else [ "$host" = :: ] || mt_valid_ipv4 "$host" || continue; fi
                match=(); [[ "$host" = 0.0.0.0 || "$host" = :: ]] || match=(-d "$host")
                "$bin" -w 5 -t filter -A "${chain}G" "${match[@]}" -p tcp --dport "$public" -j ACCEPT || return 1
            done < <(bh_expanded_ports "$(bh_meta_value PORTS "$meta")" "$(bh_meta_value BIND_HOST "$meta")")
            continue
        fi
        "$bin" -w 5 -t nat -N "$chain" || return 1
        while IFS='|' read -r public host rhs; do
            if [ "$bin" = ip6tables ]; then mt_valid_ipv6 "$host" || continue
            else [ "$host" = :: ] || mt_valid_ipv4 "$host" || continue; fi
            private=""
            for pair in "${pairs[@]}"; do [ "${pair%:*}" != "$public" ] || private="${pair##*:}"; done
            mt_valid_port "$private" || return 1
            match=(); [[ "$host" = 0.0.0.0 || "$host" = :: ]] || match=(-d "$host")
            for proto in "${protos[@]}"; do
                "$bin" -w 5 -t nat -A "$chain" "${match[@]}" -p "$proto" --dport "$public" -m addrtype --dst-type LOCAL -j REDIRECT --to-ports "$private" || return 1
            done
        done < <(bh_expanded_ports "$(bh_meta_value PORTS "$meta")" "$(bh_meta_value BIND_HOST "$meta")")
        "$bin" -w 5 -t nat -A PREROUTING -j "$chain" || return 1
        "$bin" -w 5 -t nat -A OUTPUT -j "$chain" || return 1
    done
}

bh_delete_forwarder() {
    local ip; ip=$(bh_meta_value BACKEND_IP "$CONF_DIR/$1.meta")
    if [[ "$ip" == 127.77.* ]] && [ -x /usr/bin/mporter ]; then
        /usr/bin/mporter --purge-ip "$ip" || return 1
        bh_backend_in_use "$1" && { echo 'MPorter still uses this target; deletion cancelled.' >&2; return 1; }
    fi
    bh_clear_forwarder "$1"
}

bh_activate_config() {
    local name="$1" saved rc=0 existing=false
    saved=$(mktemp -d "$SECURE_TMP/bh-rollback.XXXXXX") || return 1
    if [ -f "$CONF_DIR/$name.meta" ] && [ -f "$CONF_DIR/$name.toml" ]; then
        cp -p "$CONF_DIR/$name.meta" "$saved/meta" && cp -p "$CONF_DIR/$name.toml" "$saved/config" || { rm -rf "$saved"; return 1; }
        existing=true
    fi
    if ! write_bh_config "$@"; then rm -rf "$saved"; return 1; fi
    systemctl restart "mbackhaul@$name" && bh_service_ready "mbackhaul@$name" || rc=1
    if [ "$rc" != 0 ]; then journalctl -u "mbackhaul@$name" -n 8 --no-pager >&2; fi
    if [ "$rc" != 0 ] && [ "$existing" = true ]; then
        systemctl stop "mbackhaul@$name" >/dev/null 2>&1 || true
        if mt_install_files 600 "$saved/meta" "$CONF_DIR/$name.meta" "$saved/config" "$CONF_DIR/$name.toml" && systemctl restart "mbackhaul@$name" && systemctl is-active --quiet "mbackhaul@$name"; then
            clean_bh_counters "$name"
            setup_bh_counters "$name" "$(bh_meta_value TUN_PORT "$saved/meta")" "$(bh_meta_value REMOTE_IP "$saved/meta")" "$(bh_meta_value ROLE "$saved/meta")" "$(bh_meta_value BIND_HOST "$saved/meta")"
            echo 'Forwarder failed to start; previous tunnel configuration restored.' >&2
        else
            echo "Rollback failed. Previous configuration is saved in $saved" >&2; return 1
        fi
    fi
    rm -rf "$saved"
    return "$rc"
}

case "${1:-}" in
    --install-core-smart)
        case "${2:-}" in
            mtunnel) install_core_from_source 5;;
            mirror) install_core_from_source 6;;
            official) install_core_from_source 1;;
            *) echo 'Usage: mbackhaul --install-core-smart {mtunnel|mirror|official}' >&2; exit 2;;
        esac
        exit $?;;
    --apply-forwarder) bh_apply_forwarder "${2:-}"; exit $?;;
    --clear-forwarder) bh_clear_forwarder "${2:-}"; exit $?;;
    --delete-one)
        bh_n="${2:-}"; [[ "$bh_n" =~ ^[A-Za-z0-9_.-]+$ ]] || exit 2
        [ -f "$CONF_DIR/$bh_n.meta" ] || exit 0
        systemctl disable --now "mbackhaul@$bh_n" >/dev/null 2>&1 || true
        clean_bh_counters "$bh_n"
        if command -v crontab >/dev/null 2>&1; then
            cron_tmp="$SECURE_TMP/crontab.$$"; crontab -l 2>/dev/null | grep -v "mbackhaul@${bh_n}" > "$cron_tmp"; crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
        fi
        bh_delete_forwarder "$bh_n" || exit 1
        rm -f "$CONF_DIR/$bh_n.meta" "$CONF_DIR/$bh_n.toml" "$CONF_DIR/${bh_n}_restart.sh"; exit 0;;
    --delete-all)
        # Delete every Backhaul tunnel (units, forwarders, counters, cron, configs) but keep this script and the bh core.
        bh_rc=0
        for meta in "$CONF_DIR"/*.meta; do
            [ -f "$meta" ] || continue
            bh_n=$(basename "$meta" .meta)
            systemctl disable --now "mbackhaul@$bh_n" >/dev/null 2>&1
            if bh_delete_forwarder "$bh_n"; then rm -f "$CONF_DIR/$bh_n.meta" "$CONF_DIR/$bh_n.toml"; else bh_rc=1; fi
        done
        systemctl stop 'mbackhaul@*' mbackhaul-apply.service >/dev/null 2>&1
        systemctl disable 'mbackhaul@*' mbackhaul-apply.service >/dev/null 2>&1
        for bin in iptables ip6tables; do
            command -v "$bin" >/dev/null 2>&1 || continue
            for chain in INPUT OUTPUT; do
                for direction in RX TX; do mt_delete_tagged_rules "$bin" mangle "$chain" "MBH_${direction}_" prefix; done
            done
        done
        if command -v crontab >/dev/null 2>&1; then
            cron_tmp="$SECURE_TMP/crontab.$$"
            crontab -l 2>/dev/null | grep -v "mbackhaul@" > "$cron_tmp"
            crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
        fi
        rm -f /etc/systemd/system/multi-user.target.wants/mbackhaul@*.service /etc/systemd/system/mbackhaul@.service /etc/systemd/system/mbackhaul-apply.service
        systemctl daemon-reload >/dev/null 2>&1
        if [ "$bh_rc" -eq 0 ]; then
            find "$CONF_DIR" "$CERT_DIR" -mindepth 1 -maxdepth 1 ! -name '.*' -exec rm -rf {} + 2>/dev/null
        fi
        exit "$bh_rc" ;;
esac

if [[ "$1" == "--apply" ]]; then
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        t_name=$(basename "$conf" .meta)
        ROLE=""; TUN_PORT=""; REMOTE_IP=""; BIND_HOST="0.0.0.0"; mt_source_conf "$conf" 2>/dev/null
        setup_bh_counters "$t_name" "$TUN_PORT" "$REMOTE_IP" "$ROLE" "$BIND_HOST"
    done
    exit 0
fi

get_bh_rx() {
    local data; data=$({ iptables -t mangle -L INPUT -v -n -x; ip6tables -w 5 -t mangle -L INPUT -v -n -x; } 2>/dev/null)
    mt_counter_sum "$data" "MBH_RX_$1"
}

get_bh_tx() {
    local data; data=$({ iptables -t mangle -L OUTPUT -v -n -x; ip6tables -w 5 -t mangle -L OUTPUT -v -n -x; } 2>/dev/null)
    mt_counter_sum "$data" "MBH_TX_$1"
}

bh_endpoint_host() {
    local ep="$1" host
    [ -n "$ep" ] || return 1
    if [[ "$ep" == \[*\]:* ]]; then host="${ep#\[}"; host="${host%\]:*}"; else host="${ep%:*}"; fi
    host="${host#::ffff:}"; printf '%s' "$host"
}

bh_unit_peer_ip() { mt_unit_live_peer "mbackhaul@${1}" "${2:-}" "${3:-}"; }

bh_unit_tcp_rtt() { mt_unit_tcp_rtt "mbackhaul@${1}" "$2"; }

check_bh_connection() {
    local t_name="$1" known_active="${2:-0}" meta="$CONF_DIR/${t_name}.meta"
    local ROLE="" TUN_PORT="" REMOTE_IP="" TRANSPORT="tcp" peer
    [ -f "$meta" ] || { echo "OFFLINE"; return; }
    mt_source_conf "$meta" 2>/dev/null
    if [ "$known_active" != "1" ] && ! systemctl is-active --quiet "mbackhaul@${t_name}" 2>/dev/null; then echo "OFFLINE"; return; fi

    if [[ "$TRANSPORT" =~ ^(udp|kcp|kcpmux)$ ]]; then
        local rx tx tot f now last_tot=0 last_chg=0; rx=$(get_bh_rx "$t_name"); tx=$(get_bh_tx "$t_name")
        tot=$(( ${rx:-0} + ${tx:-0} )); f="$SECURE_TMP/.mbh_udp_${t_name}"; now=$(date +%s)
        [ -f "$f" ] && read -r last_tot last_chg < "$f"
        if [ "$tot" != "$last_tot" ]; then last_chg=$now; fi
        [[ "$last_chg" =~ ^[0-9]+$ ]] || last_chg=0
        echo "$tot $last_chg" > "$f" 2>/dev/null
        if (( tot > 0 && now - last_chg <= 60 )); then echo "ONLINE"
        elif [ "$ROLE" = "1" ]; then echo "WAITING"
        else echo "CONNECTING"; fi
        return
    fi

    if [ "$ROLE" = "1" ]; then peer=$(bh_unit_peer_ip "$t_name" "$TUN_PORT" 2>/dev/null || true)
    else peer=$(bh_unit_peer_ip "$t_name" "" "$REMOTE_IP" 2>/dev/null || true); fi
    if [ -n "$peer" ]; then echo "ONLINE"
    elif [ "$ROLE" = "1" ]; then echo "WAITING"
    else echo "CONNECTING"; fi
}

get_peer_ping() {
    local target_ip port t_name ping_res ping_val tcp_rtt start_ts end_ts t_rtt
    target_ip=$(echo "$1" | tr -d ' \n\r'); port=$(echo "$2" | tr -d ' \n\r'); t_name="${3:-}"
    if [ -z "$target_ip" ] || [ "$target_ip" = "0.0.0.0" ]; then echo "N/A"; return; fi

    local -a pcmd=(ping); [[ "$target_ip" == *:* ]] && pcmd=(ping -6)
    ping_res=$(timeout 2 "${pcmd[@]}" -c 1 -W 1 "$target_ip" 2>/dev/null || true)
    if echo "$ping_res" | grep -q 'time='; then
        ping_val=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+' | head -n1 | awk '{print int($1+0.5)}')
        echo "${ping_val}ms"; return
    fi

    if [ -n "$t_name" ]; then
        tcp_rtt=$(bh_unit_tcp_rtt "$t_name" "$target_ip" 2>/dev/null || true)
        [ -n "$tcp_rtt" ] && { echo "$tcp_rtt"; return; }
    fi

    # Only perform a direct TCP connect as a last resort. It measures the
    # configured endpoint but is never used to identify another tunnel's peer.
    if [ -n "$port" ] && [[ "$port" =~ ^[0-9]+$ ]]; then
        start_ts=$(date +%s%3N 2>/dev/null)
        if mt_tcp_probe "$target_ip" "$port"; then
            end_ts=$(date +%s%3N 2>/dev/null)
            if [[ "$start_ts" =~ ^[0-9]+$ && "$end_ts" =~ ^[0-9]+$ ]]; then
                t_rtt=$((end_ts-start_ts)); [ "$t_rtt" -le 0 ] && t_rtt=1
                echo "${t_rtt}ms*"; return
            fi
        fi
    fi
    echo "Timeout"
}

bh_port_lines() {
    local list="$1" bind="$2" raw lhs rhs host start end port mapped output=''
    local -a items=()
    [ -n "$list" ] || { printf ''; return 0; }
    IFS=, read -ra items <<< "$list"
    for raw in "${items[@]}"; do
        raw="${raw// /}"; lhs="${raw%%=*}"; rhs=''
        [[ "$raw" != *=* ]] || rhs="${raw#*=}"
        if [[ "$lhs" == *:* ]]; then
            host=$(mt_normalize_host "${lhs%:*}")
            port="${lhs##*:}"
            mapped="$(mt_hostport "$host" "$port")=${rhs:-127.0.0.1:$port}"
            output+="${output:+, }\"$mapped\""
        else
            start="${lhs%-*}"; end="${lhs#*-}"
            for ((port=10#$start;port<=10#$end;port++)); do
                mapped="$(mt_hostport "$bind" "$port")=${rhs:-127.0.0.1:$port}"
                output+="${output:+, }\"$mapped\""
            done
        fi
    done
    printf '%s' "$output"
}

write_bh_config() {
    local fd rc
    exec {fd}>"$CONF_DIR/.forwarder-allocation.lock" || return 1
    flock -x "$fd" || { exec {fd}>&-; return 1; }
    bh_write_config_locked "$@"; rc=$?
    exec {fd}>&-
    return "$rc"
}

bh_write_config_locked() {
    local name="$(echo "$1" | tr -d '\r\n')"
    local role="$(echo "$2" | tr -d '\r\n')"
    local transport="$(echo "$3" | tr -d '\r\n')"
    local port="$(echo "$4" | tr -d '\r\n')"
    local r_ip="$(echo "$5" | tr -d '\r\n')"
    local token="$(echo "$6" | tr -d '\r\n' | sed 's/"/\\"/g')"
    local ports_str="$(echo "$7" | tr -d '\r\n')"
    local enable_udp="$(echo "$8" | tr -d '\r\n')"

    [ -z "$role" ] && role="1"
    [ -z "$transport" ] && transport="tcp"
    [ -z "$port" ] && port="8443"
    [ -z "$token" ] && token="mdesign_token"
    [ -z "$enable_udp" ] && enable_udp="true"

    bh_load_options "$CONF_DIR/${name}.meta" "${11:-}" || return 1
    local bind_host="${9:-}" BIND_HOST='0.0.0.0' work final_toml final_meta
    if [ -f "$CONF_DIR/${name}.meta" ]; then
        BIND_HOST=$(sed -n 's/^BIND_HOST=//p' "$CONF_DIR/${name}.meta")
    fi
    bind_host=$(mt_normalize_host "${bind_host:-${BIND_HOST:-0.0.0.0}}")
    mt_valid_ipv4 "$bind_host" || mt_valid_ipv6 "$bind_host" || return 1
    mt_valid_port "$port" && [[ "$role" =~ ^[12]$ ]] || return 1
    [ "$role" != 2 ] || mt_valid_host "$r_ip" || return 1
    validate_bh_ports "$ports_str" 0 || return 1
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ && "$transport" =~ ^(tcp|tcpmux|tls|tlsmux|ws|wss|wsmux|wssmux|udp|kcp|kcpmux|xhttp|xhttps|xhttpmux|xhttpsmux)$ && "$enable_udp" =~ ^(true|false)$ ]] || return 1
    [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    if [ "${MT_LINK_CREATING:-0}" = 1 ] && { [ -e "$CONF_DIR/${name}.meta" ] || [ -e "$CONF_DIR/${name}.toml" ]; }; then
        echo 'Tunnel appeared during peer creation; nothing overwritten.' >&2; return 1
    fi
    local forwarder="${10:-}" old_forwarder old_ports
    old_forwarder=$(bh_meta_value FORWARDER "$CONF_DIR/${name}.meta")
    forwarder="${forwarder:-${old_forwarder:-backhaul}}"
    [ "$role" = 1 ] || forwarder=backhaul
    [[ "$forwarder" =~ ^(backhaul|iptables|mporter)$ ]] || return 1
    if [ "$transport" = udp ] && [ "$forwarder" = mporter ]; then
        echo 'UDP transport requires Backhaul or iptables forwarding; MPorter targets here are TCP.' >&2; return 1
    fi
    if [ "$transport" = udp ]; then enable_udp=true
    elif [ "$transport" != tcp ]; then enable_udp=false; fi
    local other pair private public host rhs
    local -A requested=(); local -a pairs=()
    if [ "$role" = 1 ]; then
        while IFS='|' read -r public host rhs; do requested[$public]=1; done < <(bh_expanded_ports "$ports_str" "$bind_host")
    fi
    for other in "$CONF_DIR"/*.meta; do
        [ -f "$other" ] && [ "$other" != "$CONF_DIR/$name.meta" ] || continue
        IFS=, read -ra pairs <<< "$(bh_meta_value BACKEND_PORTS "$other")"
        for pair in "${pairs[@]}"; do
            private="${pair##*:}"
            mt_valid_port "$private" || continue
            if [ "$port" = "$private" ] || [ -n "${requested[$private]:-}" ]; then
                echo "Port $private is reserved for $(basename "$other" .meta)'s local backend." >&2; return 1
            fi
        done
    done
    old_ports=$(bh_meta_value PORTS "$CONF_DIR/${name}.meta")
    if { [ "$forwarder" != "${old_forwarder:-backhaul}" ] || [ "$ports_str" != "$old_ports" ]; } && bh_backend_in_use "$name"; then
        echo 'Remove this Backhaul target from MPorter before changing its ports or forwarder.' >&2; return 1
    fi
    BH_BACKEND_IP=""; BH_BACKEND_PORTS=""; BH_BACKEND_BIND=""; BH_BACKEND_LINES=""
    if [ "$forwarder" != backhaul ]; then
        [ -n "$ports_str" ] || { echo 'External forwarding needs at least one port.' >&2; return 1; }
        bh_prepare_backend "$name" "$ports_str" "$bind_host" "$port" || return 1
        if [ "$forwarder" = mporter ]; then enable_udp=false; fi
    fi
    work=$(mktemp -d "$SECURE_TMP/bh-config.XXXXXX") || return 1
    final_toml="$CONF_DIR/${name}.toml"; final_meta="$CONF_DIR/${name}.meta"
    local toml="$work/config.toml" meta="$work/meta"

    echo "ROLE=$role" > "$meta"
    if [ "${MT_LINK_CREATING:-0}" = 1 ]; then printf 'PEER_SETUP_ID=%s\n' "$MT_LINK_CREATION_ID" >> "$meta"; fi
    echo "BIND_HOST=$bind_host" >> "$meta"
    echo "TRANSPORT=$transport" >> "$meta"
    echo "TUN_PORT=$port" >> "$meta"
    echo "REMOTE_IP=$r_ip" >> "$meta"
    echo "TOKEN=$token" >> "$meta"
    echo "PORTS=$ports_str" >> "$meta"
    echo "ENABLE_UDP=$enable_udp" >> "$meta"
    echo "FORWARDER=$forwarder" >> "$meta"
    echo "BACKEND_IP=$BH_BACKEND_IP" >> "$meta"
    echo "BACKEND_PORTS=$BH_BACKEND_PORTS" >> "$meta"
    echo "BACKEND_BIND=$BH_BACKEND_BIND" >> "$meta"
    echo "PROFILE=${BH_PROFILE:-BALANCED}" >> "$meta"
    local key; for key in "${!BH_OPTS[@]}"; do printf 'ADV_%s=%s\n' "$key" "${BH_OPTS[$key]}"; done >> "$meta"

    > "$toml"

    if [ "$role" == "1" ]; then
        echo "[server]" >> "$toml"
        echo "bind_addr = \"$(mt_hostport "$bind_host" "$port")\"" >> "$toml"
        echo "transport = \"${transport}\"" >> "$toml"
        echo "accept_udp = ${enable_udp}" >> "$toml"
        echo "token = \"${token}\"" >> "$toml"
        bh_emit_options "$role" "$transport" >> "$toml"
        if [[ "$transport" == tls || "$transport" == tlsmux || "$transport" == wss || "$transport" == wssmux || "$transport" == xhttps || "$transport" == xhttpsmux ]]; then
            local cert="${BH_OPTS[TLS_CERT]}" tls_key="${BH_OPTS[TLS_KEY]}"
            if [ -n "$cert" ]; then
                bh_validate_tls_pair "$cert" "$tls_key" || { echo 'TLS certificate/key is expired, unreadable or mismatched.' >&2; rm -rf "$work"; return 1; }
                printf 'tls_cert = "%s"\ntls_key = "%s"\n' "$cert" "$tls_key" >> "$toml"
            fi
        fi

        local port_lines
        if [ "$forwarder" = backhaul ]; then
            port_lines=$(bh_port_lines "$ports_str" "$bind_host") || { rm -rf "$work"; return 1; }
        else port_lines="$BH_BACKEND_LINES"; fi
        echo "ports = [ ${port_lines} ]" >> "$toml"

    else
        echo "[client]" >> "$toml"
        echo "remote_addr = \"$(mt_hostport "$r_ip" "$port")\"" >> "$toml"
        echo "transport = \"${transport}\"" >> "$toml"
        echo "token = \"${token}\"" >> "$toml"
        bh_emit_options "$role" "$transport" >> "$toml"
    fi

    mt_install_files 600 "$meta" "$final_meta" "$toml" "$final_toml" || { rm -rf "$work"; return 1; }
    rm -rf "$work"
    clean_bh_counters "$name"
    setup_bh_counters "$name" "$port" "$r_ip" "$role" "$bind_host"
    return 0
}

bh_smart_ports() { # NAME PORTS
    local name="$1" ports="$2" meta="$CONF_DIR/$1.meta" ROLE='' TRANSPORT='' TUN_PORT='' REMOTE_IP='' TOKEN='' ENABLE_UDP='false' BIND_HOST='0.0.0.0'
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    [ -f "$meta" ] || return 1
    mt_source_conf "$meta" 2>/dev/null || return 1
    [ "$ROLE" = 1 ] || return 1
    [[ "$TRANSPORT" =~ ^(tcp|tcpmux|tls|tlsmux|ws|wss|wsmux|wssmux|udp|kcp|kcpmux|xhttp|xhttps|xhttpmux|xhttpsmux)$ ]] || return 1
    validate_bh_ports "$ports" 0 || return 1
    write_bh_config "$name" "$ROLE" "$TRANSPORT" "$TUN_PORT" "$REMOTE_IP" "$TOKEN" "$ports" false "$BIND_HOST" backhaul "$meta" || return 1
    systemctl restart "mbackhaul@$name" >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "mbackhaul@$name"
}

if [ "${1:-}" == --smart-ports ]; then
    bh_smart_ports "${2:-}" "${3:-}"; exit $?
fi

setup_systemd_service() {
    local changed=false
    local tmp_srv="$SECURE_TMP/mbackhaul_tpl.service"
    local tmp_app="$SECURE_TMP/mbackhaul_apply.service"

    cat <<'EOF' > "$tmp_srv"
[Unit]
Description=MBackhaul Multi-Multiplexer (%i)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStartPre=/usr/bin/mbackhaul --apply-forwarder %i
ExecStart=/usr/local/bin/bh -c /etc/mbackhaul/tunnels/%i.toml
ExecStopPost=/usr/bin/mbackhaul --clear-forwarder %i
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    cat <<'EOF' > "$tmp_app"
[Unit]
Description=MBackhaul Boot Restorer
After=network.target

[Service]
ExecStart=/usr/bin/mbackhaul --apply
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    if ! cmp -s "$tmp_srv" "/etc/systemd/system/mbackhaul@.service" 2>/dev/null; then
        mv -f "$tmp_srv" "/etc/systemd/system/mbackhaul@.service"
        changed=true
    else
        rm -f "$tmp_srv"
    fi

    if ! cmp -s "$tmp_app" "/etc/systemd/system/mbackhaul-apply.service" 2>/dev/null; then
        mv -f "$tmp_app" "/etc/systemd/system/mbackhaul-apply.service"
        changed=true
    else
        rm -f "$tmp_app"
    fi

    if [ "$changed" = true ]; then
        systemctl daemon-reload
        systemctl enable mbackhaul-apply.service >/dev/null 2>&1
    fi
}

# ---- Per-tunnel header rows: background cache + in-place live refresh ----
hdr_ping_probe() {
    local ip="$1" name="${2:-}" transport="${3:-tcp}" res loss avg="---" tcp_rtt
    local -a pcmd=(ping); [[ "$ip" == *:* ]] && pcmd=(ping -6)
    res=$(timeout 3 "${pcmd[@]}" -c 2 -i 0.2 -W 1 "$ip" 2>/dev/null || true)
    loss=$(echo "$res" | grep -oP '[0-9]+(?=% packet loss)' | head -n1); [ -n "$loss" ] || loss=100
    if echo "$res" | grep -q 'min/avg/max'; then
        avg=$(echo "$res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2 | head -n1)
        [ -n "$avg" ] && avg="$(awk -v v="$avg" 'BEGIN {printf "%.0fms", v}')" || avg="---"
    elif [[ ! "$transport" =~ ^(udp|kcp|kcpmux)$ ]] && [ -n "$name" ]; then
        tcp_rtt=$(bh_unit_tcp_rtt "$name" "$ip" 2>/dev/null || true)
        if [ -n "$tcp_rtt" ]; then avg="$tcp_rtt"; loss="---"
        elif [ -n "$(bh_unit_peer_ip "$name" 2>/dev/null || true)" ]; then loss="---"; fi
    fi
    echo "${avg}|${loss}"
}
hdr_ss_peer() { bh_unit_peer_ip "$1" "$2" 2>/dev/null || true; }
collect_header_rows() {
    local mode="${1:-}" tmp conf name role port remote transport peer fwd up avg loss st act="" ina="" line
    local _prev_rows; _prev_rows=$(cat "$HDR_ROWS_FILE" 2>/dev/null || true)
    tmp=$(mktemp "$SECURE_TMP/.mbackhaul_hdr_rows.XXXXXX") || return 1
    mt_ss_snapshot_begin 2>/dev/null || true
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        name=$(basename "$conf" .meta)
        role=$(mt_read_kv "$conf" ROLE 2>/dev/null) || role=""
        port=$(mt_read_kv "$conf" TUN_PORT 2>/dev/null) || port=""
        remote=$(mt_read_kv "$conf" REMOTE_IP 2>/dev/null) || remote=""
        transport=$(mt_read_kv "$conf" TRANSPORT 2>/dev/null) || transport=""; [ -n "$transport" ] || transport=tcp
        st=0; systemctl is-active --quiet "mbackhaul@${name}" 2>/dev/null && st=1
        peer="$remote"
        if [ "$st" = 1 ] && [ "$role" = 1 ]; then
            if [[ "$transport" =~ ^(udp|kcp|kcpmux)$ ]]; then
                # UDP has no ESTABLISHED socket to look at: use the traffic counters instead of a fixed label.
                if [ "$(check_bh_connection "$name" 1 2>/dev/null)" = ONLINE ]; then peer="UDP Connected"; else peer="UDP Listening"; fi
            else peer=$(hdr_ss_peer "$name" "$port"); [ -n "$peer" ] || peer="Listening"; fi
        fi
        [ -n "$peer" ] && [ "$peer" != "0.0.0.0" ] || peer="---"
        avg="---"; loss="---"
        if [ "$st" = 1 ] && hdr_is_ip "$peer"; then
            if [ "$mode" = fast ]; then
                avg="..."
                while IFS='|' read -r _ _pn _ _pa _pq _; do
                    if [ "$_pn" = "$name" ] && [ -n "$_pa" ] && [ "$_pa" != "..." ]; then avg="$_pa"; loss="$_pq"; break; fi
                done <<< "$_prev_rows"
            else IFS='|' read -r avg loss <<< "$(hdr_ping_probe "$peer" "$name" "$transport")"; fi
        fi
        fwd="OFF"; hdr_conf_has "$conf" PORTS && fwd="ACT"; [ "$role" = 2 ] && fwd="CLI"
        up="STOPPED"; [ "$st" = 1 ] && up=$(hdr_unit_uptime "mbackhaul@${name}")
        line="${st}|${name}|${peer}|${avg}|${loss}|${up}|${fwd}"
        if [ "$st" = 1 ]; then act+="${line}"$'\n'; else ina+="${line}"$'\n'; fi
    done
    mt_ss_snapshot_end 2>/dev/null || true
    printf '%s%s' "$act" "$ina" | head -n 3 > "$tmp"
    mv -f "$tmp" "$HDR_ROWS_FILE" 2>/dev/null
}

# Header rows: show the transport next to the BH tag, e.g. "test [BH:tcp]". The name column is 17 characters wide
# (name + " [" + tag + "]"), so long transports get a short code and a long name is shortened to fit.
bh_short_transport() {
    case "$1" in
        tcpmux) printf tcpmx;; tlsmux) printf tlsmx;; wsmux) printf wsmx;; wssmux) printf wssmx;;
        kcpmux) printf kcpmx;; xhttpmux) printf xhmux;; xhttpsmux) printf xhsmx;; xhttps) printf xhtps;;
        *) printf '%s' "$1";;
    esac
}
bh_rows_add_transport() {
    local line st name tag peer vip ping loss up fwd tr newtag room out='' conf
    [ -n "${MT_HDR_ROWS:-}" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS='|' read -r st name tag peer vip ping loss up fwd <<< "$line"
        conf="$CONF_DIR/bh_${name}.meta"; [ -f "$conf" ] || conf="$CONF_DIR/${name}.meta"
        tr=""
        if [ -r "$conf" ]; then
            local _k _v
            while IFS='=' read -r _k _v; do
                if [ "$_k" = TRANSPORT ]; then
                    tr="${_v//$'\r'/}"; tr="${tr//\"/}"; tr="${tr//\'/}"
                    break
                fi
            done < "$conf"
        fi
        newtag="$tag"
        if [ -n "$tr" ]; then
            newtag="${tag}:$(bh_short_transport "$tr")"
            room=$(( 17 - ${#newtag} - 3 )); (( room < 3 )) && room=3; (( room > 8 )) && room=8
            name="${name// /}"; name="${name:0:$room}"
        fi
        out+="${st}|${name}|${newtag}|${peer}|${vip}|${ping}|${loss}|${up}|${fwd}"$'\n'
    done <<< "$MT_HDR_ROWS"
    MT_HDR_ROWS="$out"
}

draw_header() {
    local _meta_cache="$SECURE_TMP/.mbackhaul_header_meta"
    if [ -n "${HEADER_LIVE:-}${MT_HEADER_USE_CACHE:-}" ] && [ -s "$_meta_cache" ]; then
        local act_text act_color core_raw core_color stat_icon stat_text stat_color g_text g_color total_t
        IFS='|' read -r act_text act_color core_raw core_color stat_icon stat_text stat_color g_text g_color total_t < "$_meta_cache"
        mt_hdr_rows_from_cache "$HDR_ROWS_FILE" "BH" "bh_"; bh_rows_add_transport
        HDR_DRAWN_ROWS=$MT_HDR_ROW_COUNT
        mt_hdr_draw "MBackhaul Core v${MODULE_VERSION}" "Active|${act_text}|${act_color}" \
            "Core|${core_raw}|${core_color}" "Status|${stat_icon} ${stat_text}|${stat_color}" \
            "Peer Ping|${g_text}|${g_color}" "Tunnels|${total_t}|${W}"
        return 0
    fi
    local _deep=1
    mt_ss_snapshot_begin 2>/dev/null || true
    local total_t=0; local active_t=0; local online_t=0; local waiting_t=0; local connecting_t=0
    local t_names=() units=()
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            local t_name=$(basename "$conf" .meta)
            t_names+=("$t_name"); units+=("mbackhaul@$t_name")
        fi
    done
    total_t=${#t_names[@]}
    if [ "$total_t" -gt 0 ]; then
        local states=() i=0
        while IFS= read -r st_line; do states+=("$st_line"); done < <(systemctl is-active "${units[@]}" 2>/dev/null)
        for t_name in "${t_names[@]}"; do
            if [ "${states[$i]}" == "active" ]; then
                ((active_t++))
                if [ "$_deep" = 1 ]; then
                    local st=$(check_bh_connection "$t_name" "1")
                    case "$st" in ONLINE) ((online_t++));; WAITING) ((waiting_t++));; CONNECTING) ((connecting_t++));; esac
                fi
            fi
            ((i++))
        done
    fi

    local core_color="${R}"; local core_raw="✖"
    if is_bh_core_valid; then
        bh_probe_version "$(bh_core_bin)"
        core_color="${G}"; core_raw="✔"
        [ -n "${BH_PROBED_VERSION:-}" ] && core_raw="✔ v${BH_PROBED_VERSION:0:10}"
    elif bh_core_bin >/dev/null; then
        bh_probe_version "$(bh_core_bin)"
        core_color="${Y}"; core_raw="✖ v${BH_PROBED_VERSION:0:10}"
    fi
    
    local act_color="${DIM}"; local act_text="0/0"
    if [ "$total_t" -gt 0 ]; then
        act_text="${active_t}/${total_t}"
        if [ "$active_t" -eq "$total_t" ]; then act_color="${G}"
        elif [ "$active_t" -gt 0 ]; then act_color="${Y}"
        else act_color="${R}"; fi
    fi

    local stat_color="${R}"; local stat_icon="○"; local stat_text="STOPPED"
    if [ "$active_t" -gt 0 ]; then
        if [ "$online_t" -eq "$active_t" ]; then 
            stat_color="${G}"; stat_icon="●"; stat_text="CONNECTED"
        elif [ "$online_t" -gt 0 ]; then 
            stat_color="${Y}"; stat_icon="◐"; stat_text="PARTIAL"
        elif [ "$connecting_t" -gt 0 ]; then
            stat_color="${Y}"; stat_icon="◎"; stat_text="CONNECTING"
        elif [ "$waiting_t" -gt 0 ]; then
            stat_color="${Y}"; stat_icon="◎"; stat_text="WAITING"
        else
            stat_color="${Y}"; stat_icon="◎"; stat_text="STARTING"
        fi
    fi

    local peer_ip="" peer_name=""
    local tmp_port=""
    for conf in "$CONF_DIR"/*.meta; do
        if [ -f "$conf" ]; then
            local tmp_role=$(grep "^ROLE=" "$conf" | cut -d'=' -f2)
            local tmp_remote=$(grep "^REMOTE_IP=" "$conf" | cut -d'=' -f2)
            tmp_port=$(grep "^TUN_PORT=" "$conf" | cut -d'=' -f2)
            
            if [ -n "$tmp_remote" ] && [ "$tmp_remote" != "0.0.0.0" ]; then
                peer_ip="$tmp_remote"
                peer_name=$(basename "$conf" .meta)
                break
            elif [ "$tmp_role" == "1" ]; then
                local tmp_name=$(basename "$conf" .meta)
                peer_ip=$(bh_unit_peer_ip "$tmp_name" "$tmp_port" 2>/dev/null || true)
                if [ -n "$peer_ip" ]; then peer_name="$tmp_name"; break; fi
            fi
        fi
    done

    local g_color="${DIM}"; local g_text="N/A"
    if [ -n "$peer_ip" ]; then
        local cache_key="${peer_name:-peer}"; cache_key="${cache_key//[^A-Za-z0-9_.-]/_}"
        local ping_cache="$SECURE_TMP/.mbackhaul_ping_${cache_key}"
        local ping_lock="$SECURE_TMP/.mbackhaul_ping_${cache_key}.lock"
        local now=$(date +%s)
        local cache_ts=0; [ -f "$ping_cache" ] && cache_ts=$(stat -c %Y "$ping_cache" 2>/dev/null || echo 0)
        local cache_age=$(( now - cache_ts ))

        if [ -f "$ping_cache" ] && [ "$cache_age" -lt 15 ]; then
            local p_val=$(cat "$ping_cache" 2>/dev/null)
            if [[ "$p_val" != "Timeout" && "$p_val" != "N/A" ]]; then
                local p_int=$(echo "$p_val" | tr -dc '0-9')
                [ -z "$p_int" ] && p_int=0
                if [ "$p_int" -lt 90 ]; then g_color="${G}"
                elif [ "$p_int" -lt 160 ]; then g_color="${Y}"
                else g_color="${R}"
                fi
                g_text="${p_val}"
            else
                g_color="${R}"; g_text="Timeout"
            fi
        else
            g_color="${DIM}"; g_text="..."
        fi

        local lock_ts=0; [ -f "$ping_lock" ] && lock_ts=$(stat -c %Y "$ping_lock" 2>/dev/null || echo 0)
        local lock_age=$(( now - lock_ts ))
        if { [ ! -f "$ping_cache" ] || [ "$cache_age" -ge 15 ]; } && { [ ! -f "$ping_lock" ] || [ "$lock_age" -gt 5 ]; }; then
            touch "$ping_lock"
            (
                bg_val=$(get_peer_ping "$peer_ip" "$tmp_port" "$peer_name")
                echo "$bg_val" > "$ping_cache"
                if [ -s "$_meta_cache" ]; then
                    IFS='|' read -r _m1 _m2 _m3 _m4 _m5 _m6 _m7 _m8 _m9 _m10 < "$_meta_cache"
                    _mt="$bg_val"; _mc="$R"
                    if [ "$bg_val" != Timeout ] && [ "$bg_val" != "N/A" ]; then
                        _mi=$(echo "$bg_val" | tr -dc '0-9'); [ -n "$_mi" ] || _mi=0
                        if [ "$_mi" -lt 90 ]; then _mc="$G"; elif [ "$_mi" -lt 160 ]; then _mc="$Y"; fi
                    else _mt=Timeout; fi
                    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_m1" "$_m2" "$_m3" "$_m4" "$_m5" "$_m6" "$_m7" "$_mt" "$_mc" "$_m10" > "$_meta_cache.tmp" 2>/dev/null && mv -f "$_meta_cache.tmp" "$_meta_cache" 2>/dev/null
                fi
                rm -f "$ping_lock"
                if [ -f "$SECURE_TMP/.mbackhaul_in_menu" ]; then
                    kill -SIGUSR2 "$MAIN_PID" 2>/dev/null
                fi
            ) &
        fi
    else
        g_color="${DIM}"; g_text="Waiting"
    fi
    mt_ss_snapshot_end 2>/dev/null || true

    # Unified dashboard header (same look as the main screen) -- THIS module's tunnels only.
    local _now _mtime
    _now=$(date +%s); _mtime=$(stat -c %Y "$HDR_ROWS_FILE" 2>/dev/null || echo 0)
    if [ ! -s "$HDR_ROWS_FILE" ]; then
        collect_header_rows fast >/dev/null 2>&1 || true
        _mtime=$(stat -c %Y "$HDR_ROWS_FILE" 2>/dev/null || echo "$_now")
    elif [ $((_now - _mtime)) -ge 15 ]; then
        ( collect_header_rows fast >/dev/null 2>&1 & )
    fi
    mt_hdr_rows_from_cache "$HDR_ROWS_FILE" "BH" "bh_"; bh_rows_add_transport
    HDR_DRAWN_ROWS=$MT_HDR_ROW_COUNT
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$act_text" "$act_color" "$core_raw" "$core_color" "$stat_icon" "$stat_text" "$stat_color" "$g_text" "$g_color" "${total_t}" > "$_meta_cache"
    mt_hdr_draw "MBackhaul Core v${MODULE_VERSION}" "Active|${act_text}|${act_color}" \
        "Core|${core_raw}|${core_color}" "Status|${stat_icon} ${stat_text}|${stat_color}" \
        "Peer Ping|${g_text}|${g_color}" "Tunnels|${total_t}|${W}"
}

show_tunnel_registry() {
    draw_header
    echo -e "\n  ${Y}● Tunnel Info & Specs:${NC}"
    local count=0
    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; ENABLE_UDP=""; BIND_HOST="0.0.0.0"; FORWARDER=backhaul; PROFILE="BALANCED"
        mt_source_conf "$conf" 2>/dev/null
        
        local role_text=$([ "$ROLE" == "1" ] && echo "IRAN (Server)" || echo "KHAREJ (Client)")
        local ping_val="N/A"
        local connected_peer=""

        if [ "$ROLE" == "2" ] && [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "0.0.0.0" ]; then
            ping_val=$(get_peer_ping "$REMOTE_IP" "$TUN_PORT" "$t_name")
            connected_peer="$REMOTE_IP"
        elif [ "$ROLE" == "1" ]; then
            local p_ip=$(bh_unit_peer_ip "$t_name" "$TUN_PORT" 2>/dev/null || true)
            if [ -n "$p_ip" ]; then
                ping_val=$(get_peer_ping "$p_ip" "$TUN_PORT" "$t_name")
                connected_peer="$p_ip"
            else
                ping_val="Waiting"
            fi
        fi

        local peer_text=$([ "$ROLE" == "1" ] && echo "Listening on :${TUN_PORT}" || echo "${REMOTE_IP}:${TUN_PORT}")
        if [ "$ROLE" == "1" ] && [ -n "$connected_peer" ]; then
            peer_text="${connected_peer}:${TUN_PORT} (Active)"
        fi

        local st=$(check_bh_connection "$t_name")
        local stat_icon="○"; local stat_text="OFFLINE"; local stat_color="${R}"
        if [ "$st" == "ONLINE" ]; then stat_icon="●"; stat_text="CONNECTED"; stat_color="${G}";
        elif [ "$st" == "WAITING" ]; then stat_icon="◎"; stat_text="WAITING CLIENT"; stat_color="${Y}";
        elif [ "$st" == "CONNECTING" ]; then stat_icon="◎"; stat_text="CONNECTING..."; stat_color="${Y}"; fi

        local rx=$(get_bh_rx "$t_name"); local tx=$(get_bh_tx "$t_name")

        local prof_tag="${PROFILE:-BALANCED}"
        local proto_display="${C}${TRANSPORT^^}${NC}"
        if [ "$ROLE" == "1" ]; then
            local udp_status="Enabled"; [ "$ENABLE_UDP" == "false" ] && udp_status="Disabled"
            proto_display="${C}${TRANSPORT^^}${NC} ${DIM}(UDP: ${G}${udp_status}${DIM})${NC}"
        fi
        proto_display="${proto_display} ${DIM}| Profile:${NC} ${M}${prof_tag}${NC}"

        echo -e "  ${FR}╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        local left_p="▼ Tunnel: $t_name"; local right_p="Role: $role_text"
        local pad=$(( 122 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
        echo -e "  ${FR}║${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${FR}║${NC}"
        echo -e "  ${FR}╠════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
        
        local l1="Link Port    : ${TUN_PORT}"; local r1="Latency: ${ping_val}"
        local pad1=$(( 122 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; local sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${FR}║${NC} ${M}Link Port    :${NC} ${W}${TUN_PORT}${NC}${sp1}${DIM}Latency:${NC} ${Y}${ping_val}${NC} ${FR}║${NC}"
        
        local l2="Peer Target  : ${peer_text}"; local r2="Link State: ${stat_icon} ${stat_text}"
        local clean_r2=$(echo -e "$r2" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
        local pad2=$(( 122 - ${#l2} - ${#clean_r2} )); [ "$pad2" -lt 0 ] && pad2=0; local sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${FR}║${NC} ${C}Peer Target  :${NC} ${W}${peer_text}${NC}${sp2}${DIM}Link State:${NC} ${stat_color}${stat_icon} ${stat_text}${NC} ${FR}║${NC}"
        if [ "$st" != "ONLINE" ]; then
            mt_reason_row "$(mt_link_why "mbackhaul@${t_name}" "$([ "$ROLE" == "1" ] && echo 1 || echo 0)" "$([ "$ROLE" == "1" ] && echo "$TUN_PORT")" "$([ "$ROLE" != "1" ] && echo "$REMOTE_IP")" "$([[ "$TRANSPORT" =~ ^(udp|kcp|kcpmux)$ ]] && echo 1 || echo 0)")"
        fi

        local l3="Auth Token   : ${TOKEN}"
        local raw_r3="Protocol: ${TRANSPORT^^} | Profile: ${prof_tag}"
        [ "$ROLE" == "1" ] && raw_r3="Protocol: ${TRANSPORT^^} (UDP: ${udp_status}) | Profile: ${prof_tag}"
        local pad3=$(( 122 - ${#l3} - ${#raw_r3} )); [ "$pad3" -lt 0 ] && pad3=0; local sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${FR}║${NC} ${Y}Auth Token   :${NC} ${W}${TOKEN}${NC}${sp3}${DIM}Protocol:${NC} ${proto_display} ${FR}║${NC}"

        local l4="Traffic Usage: RX $(format_total $rx) / TX $(format_total $tx)"
        local pad4=$(( 122 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; local sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${FR}║${NC} ${DIM}Traffic Usage:${NC} ${G}RX $(format_total $rx)${NC} ${DIM}/${NC} ${Y}TX $(format_total $tx)${NC}${sp4} ${FR}║${NC}"
        
        if [ "$ROLE" == "1" ]; then
            local p_str="${PORTS:0:100}"
            [ ${#PORTS} -gt 100 ] && p_str="${p_str}..."
            local l5="Port Mappings: ${p_str}"
            local pad5=$(( 122 - ${#l5} )); [ "$pad5" -lt 0 ] && pad5=0; local sp5=$(printf '%*s' "$pad5" "")
            echo -e "  ${FR}║${NC} ${DIM}Port Mappings:${NC} ${Y}${p_str}${NC}${sp5} ${FR}║${NC}"
        fi
        
        echo -e "  ${FR}╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝\n"
        [ "$ROLE" != 1 ] || bh_show_forwarder "$t_name"
        ((count++))
    done
    if [ "$count" -eq 0 ]; then echo -e "  ${R}● No tunnels configured yet!${NC}\n"; fi
    if [ "${1:-}" != --no-pause ]; then
        echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r dummy
    fi
}

show_live_radar() {
    tput civis; clear
    declare -A rx_old tx_old sample_old

    for conf in "$CONF_DIR"/*.meta; do
        [ ! -f "$conf" ] && continue
        local t_name=$(basename "$conf" .meta)
        mt_source_conf "$conf" 2>/dev/null
        setup_bh_counters "$t_name" "$TUN_PORT" "$REMOTE_IP" "$ROLE" "$BIND_HOST"
        rx_old[$t_name]=$(get_bh_rx "$t_name")
        sample_old[$t_name]=$(mt_milliseconds)
        tx_old[$t_name]=$(get_bh_tx "$t_name")
    done

    while true; do
        printf "\033[H"; draw_header
        echo -e "\n  ${FR}┌─[ BACKHAUL TRAFFIC RADAR ]${NC} ${C}(1s Auto-Refresh | Press 'q' to exit)${NC}\n"
        echo -e "  ${FR}╔══════════════════════╦════════════════╦══════════════════╦══════════════════╦════════════════════╦════════════════════╗${NC}"
        printf "  ${FR}║${NC} ${W}%-20s${NC} ${FR}║${NC} ${W}%-14s${NC} ${FR}║${NC} ${C}%-16s${NC} ${FR}║${NC} ${M}%-16s${NC} ${FR}║${NC} ${DIM}%-18s${NC} ${FR}║${NC} ${DIM}%-18s${NC} ${FR}║${NC}\n" "TUNNEL NAME" "STATUS" "▼ DOWNLOAD" "▲ UPLOAD" "∑ TOTAL RX" "∑ TOTAL TX"
        echo -e "  ${FR}╠══════════════════════╬════════════════╬══════════════════╬══════════════════╬════════════════════╬════════════════════╣${NC}"

        local count=0
        for conf in "$CONF_DIR"/*.meta; do
            [ ! -f "$conf" ] && continue
            local t_name=$(basename "$conf" .meta)
            local st=$(check_bh_connection "$t_name")
            local st_color="${R}"; local st_text="OFFLINE"
            if [ "$st" == "ONLINE" ]; then st_color="${G}"; st_text="ONLINE";
            elif [ "$st" == "WAITING" ]; then st_color="${Y}"; st_text="WAITING";
            elif [ "$st" == "CONNECTING" ]; then st_color="${Y}"; st_text="CONNECTING"; fi

            local r_new=$(get_bh_rx "$t_name"); local t_new=$(get_bh_tx "$t_name")
            local r_prev=${rx_old[$t_name]:-$r_new}; local t_prev=${tx_old[$t_name]:-$t_new}
            local now_ms=$(mt_milliseconds) ms_diff; ms_diff=$((now_ms-${sample_old[$t_name]:-$now_ms}))
            local rx_s=$(mt_rate "$r_new" "$r_prev" "$ms_diff"); local tx_s=$(mt_rate "$t_new" "$t_prev" "$ms_diff")
            sample_old[$t_name]=$now_ms
            [ "$rx_s" -lt 0 ] && rx_s=0; [ "$tx_s" -lt 0 ] && tx_s=0
            rx_old[$t_name]=$r_new; tx_old[$t_name]=$t_new

            local c_rx="${DIM}"; [ "$rx_s" -gt 0 ] && c_rx="${G}"
            local c_tx="${DIM}"; [ "$tx_s" -gt 0 ] && c_tx="${Y}"

            printf "  ${FR}║${NC} ${W}%-20s${NC} ${FR}║${NC} %b%-14s%b ${FR}║${NC} %b%-16s%b ${FR}║${NC} %b%-16s%b ${FR}║${NC} ${DIM}%-18s${NC} ${FR}║${NC} ${DIM}%-18s${NC} ${FR}║${NC}\n" "$t_name" "$st_color" "$st_text" "$NC" "$c_rx" "$(format_speed $rx_s)" "$NC" "$c_tx" "$(format_speed $tx_s)" "$NC" "$(format_total $r_new)" "$(format_total $t_new)"
            ((count++))
        done

        if [ "$count" -eq 0 ]; then
            printf "  ${FR}║${NC} ${DIM}%-120s${NC} ${FR}║${NC}\n" "  No active Backhaul tunnels configured."
        fi
        echo -e "  ${FR}╚══════════════════════╩════════════════╩══════════════════╩══════════════════╩════════════════════╩════════════════════╝${NC}"
        printf "\033[J"
        mt_monitor_wait 1 || break
    done
    tput cnorm
}

manage_cron() {
    local t_name="$1"
    local cron_script="$CONF_DIR/${t_name}_restart.sh"
    
    echo -e "\n  ${FR}┌─[ ANTI-FREEZE CRONJOB MANAGER ]${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add/Update Auto-Restart Cronjob${NC}"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Remove Auto-Restart Cronjob${NC}"
    echo -e "  ${FR}│${NC}"
    echo -e "  ${FR}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read -r cr_opt

    if [[ "$cr_opt" == "1" ]]; then
        echo -ne "  ${C}●${NC} ${W}Restart interval in hours (e.g. 2, 4, 6): ${NC}"; read -r interval
        interval=$(echo "$interval" | tr -d '\r')
        [[ "$interval" =~ ^[0-9]+$ ]] && ((10#$interval >= 1 && 10#$interval <= 24)) || { echo -e "  ${R}Invalid interval! Use 1-24 hours.${NC}"; sleep 1.5; return; }
        
        echo "#!/bin/bash" > "$cron_script"
        echo "systemctl kill -s SIGKILL mbackhaul@${t_name}" >> "$cron_script"
        echo "systemctl restart mbackhaul@${t_name}" >> "$cron_script"
        chmod +x "$cron_script"
        
        if command -v crontab >/dev/null 2>&1; then
            local cron_tmp="$SECURE_TMP/crontab.$$"
            crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
            if [ "$interval" -eq 24 ]; then
                echo "0 0 * * * $cron_script #mbackhaul@${t_name}" >> "$cron_tmp"
            else
                echo "0 */${interval} * * * $cron_script #mbackhaul@${t_name}" >> "$cron_tmp"
            fi
            crontab "$cron_tmp"; rm -f "$cron_tmp"
            echo -e "  ${G}✔ Cronjob added: Tunnel will restart every ${interval} hours.${NC}"; sleep 2
        else
            echo -e "  ${R}✖ Crontab utility is missing on this system.${NC}"; sleep 2
        fi
    elif [[ "$cr_opt" == "2" ]]; then
        if command -v crontab >/dev/null 2>&1; then
            local cron_tmp="$SECURE_TMP/crontab.$$"
            crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
            crontab "$cron_tmp"; rm -f "$cron_tmp"
        fi
        rm -f "$cron_script"
        echo -e "  ${G}✔ Cronjob removed.${NC}"; sleep 1.5
    fi
}

uninstall_mbackhaul() {
    clear
    echo -e "\n  ${R}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${R}║${NC}   ${R}⚠ WARNING: COMPLETE PURGE & UNINSTALLATION OF MBACKHAUL${NC}                 ${R}║${NC}"
    echo -e "  ${R}║${NC}   This will permanently stop and delete:                                   ${R}║${NC}"
    echo -e "  ${R}║${NC}   ● All active Backhaul tunnels & systemd units                            ${R}║${NC}"
    echo -e "  ${R}║${NC}   ● All configurations, metadata & SSL certificates                        ${R}║${NC}"
    echo -e "  ${R}║${NC}   ● All iptables traffic counters & crontabs                               ${R}║${NC}"
    echo -e "  ${R}║${NC}   ● Backhaul core binaries (/usr/local/bin/bh) & mbackhaul module          ${R}║${NC}"
    echo -e "  ${R}╚════════════════════════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -ne "  ${Y}Are you sure you want to proceed? Type '${R}yes${Y}' to confirm: ${NC}"; read -r confirm
    confirm=$(echo "$confirm" | tr -d '\r ')
    
    if [ "$confirm" != "yes" ]; then
        echo -e "  ${G}● Uninstallation cancelled.${NC}"; sleep 1.5; return
    fi

    echo -e "\n  ${DIM}● [1/6] Stopping services & killing processes...${NC}"
    systemctl stop mbackhaul@* mbackhaul-apply.service 2>/dev/null
    systemctl disable mbackhaul@* mbackhaul-apply.service 2>/dev/null
    # Do not kill every system process with the same executable name.

    local meta
    for meta in "$CONF_DIR"/*.meta; do
        [ -f "$meta" ] || continue
        bh_delete_forwarder "$(basename "$meta" .meta)" || return 1
    done
    echo -e "  ${DIM}● [2/6] Purging iptables traffic counters...${NC}"
    local bin chain direction
    for bin in iptables ip6tables; do
        for chain in INPUT OUTPUT; do
            for direction in RX TX; do mt_delete_tagged_rules "$bin" mangle "$chain" "MBH_${direction}_" prefix; done
        done
    done

    echo -e "  ${DIM}● [3/6] Purging scheduled auto-restart cronjobs...${NC}"
    if command -v crontab >/dev/null 2>&1; then
        local cron_tmp="$SECURE_TMP/crontab.$$"
        crontab -l 2>/dev/null | grep -v "mbackhaul@" > "$cron_tmp"
        crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
    fi

    echo -e "  ${DIM}● [4/6] Removing systemd unit files...${NC}"
    rm -f /etc/systemd/system/mbackhaul@.service /etc/systemd/system/mbackhaul-apply.service
    systemctl daemon-reload 2>/dev/null

    echo -e "  ${DIM}● [5/6] Deleting configs, certificates & core binary...${NC}"
    rm -rf /etc/mbackhaul "$SECURE_TMP/.mbackhaul"*
    # Remove only an MTunnel-owned binary matching its ownership manifest.
    mt_owned_binary_remove bh /usr/local/bin/bh /usr/bin/bh || true

    echo -e "  ${DIM}● [6/6] Removing mbackhaul wrapper script...${NC}"
    rm -f "$INSTALL_PATH" 2>/dev/null
    [ -f "$0" ] && rm -f "$0" 2>/dev/null

    echo -e "\n  ${G}✔ MBackhaul ecosystem has been completely eradicated from this system.${NC}\n"
    exit 0
}

select_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; fi
    
    echo -e "\n  ${FR}╔══════════════════ Select Tunnel to Manage ═════════════════╗${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${FR}║${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${FR}║${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"
    done
    echo -e "  ${FR}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read -r t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r')
    mt_valid_index "$t_idx" "${#configs[@]}" || return 1
    t_idx=$((10#$t_idx))
    
    SELECTED_TUN="${configs[$t_idx]}"
    return 0
}

if [ -z "${MT_PEER_LINK:-}" ] && [ "${1:-}" != "--deploy-peer-link" ] && [ "${1:-}" != "--deploy-peer-stdin" ] && [ "${1:-}" != "--install-core-smart" ]; then check_first_run_core; fi
apply_bbr_optimization
setup_systemd_service

show_tunnels_info() {
    mt_tunnels_info_menu backhaul draw_header show_tunnel_registry show_tunnel_logs
}

show_tunnel_logs() {
    select_tunnel || return 0
    local t_name int_trap
    t_name=$(basename "$SELECTED_TUN" .meta)
    draw_header
    echo -e "\n  ${DIM}● Live logs for ${W}${t_name}${NC} ${DIM}(Ctrl+C to return)${NC}\n"
    int_trap=$(trap -p INT)
    trap ':' INT
    journalctl -u "mbackhaul@${t_name}" -n 50 -f
    if [ -n "$int_trap" ]; then eval "$int_trap"; else trap - INT; fi
}

# BEGIN MTUNNEL WORKSPACE V1.0.2
# Embedded in each module: no external library or sourced setup-link code.
# mt_header_refresh_now supplied by core/common.sh
# mt_live_readline supplied by core/common.sh
# mt_ask supplied by core/common.sh
# mt_workspace_screen supplied by core/common.sh
# mt_term_cols supplied by core/common.sh
# Responsive menu row: compact on all terminal widths; visual labels may trim on narrow screens.
# mt_workspace_row supplied by core/common.sh
# mt_workspace_group supplied by core/common.sh
# mt_workspace_footer supplied by core/common.sh
# mt_workspace_menu supplied by core/common.sh
# mt_workspace_pause supplied by core/common.sh
# mt_link_encode supplied by core/common.sh
# mt_link_decode supplied by core/common.sh
# mt_bbr_state supplied by core/common.sh
# mt_sync_bbr_from_peer supplied by core/common.sh
# mt_ask_bbr_from_peer supplied by core/common.sh
# mt_clipboard_copy supplied by core/common.sh
# mt_peer_copy_prompt supplied by core/common.sh
# mt_link_box supplied by core/common.sh
# mt_link_read supplied by core/common.sh
# mt_link_uint supplied by core/common.sh
# mt_link_ports supplied by core/common.sh
# mt_link_validate supplied by core/common.sh
# mt_link_select supplied by core/common.sh
# mt_link_export supplied by core/common.sh
mt_peer_ensure_core() {
    is_bh_core_valid && return 0
    local choice
    echo -e "\n  ${Y}● Backhaul Core is required before applying this Peer Code.${NC}"
    if bh_core_bin >/dev/null; then bh_probe_version "$(bh_core_bin)"; echo -e "  ${R}✖ Installed core is v${BH_PROBED_VERSION}; v${BH_EXPECT_VERSION} is required.${NC}"; fi
    echo -e "  ${FR}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Install Core From Github${NC}"
    echo -e "  ${FR}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Install Core From Iranian Mirror${NC}"
    echo -e "  ${FR}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    while true; do
        mt_live_readline choice "  ${C}Select Source ❯❯ ${NC}" || return 1
        choice="${choice//$'\r'/}"
        case "$choice" in
            1|2)
                if install_core_from_source "$choice"; then
                    is_bh_core_valid && return 0
                    echo -e "  ${R}✖ Core installer returned but the binary is still unavailable.${NC}" >&2
                    return 1
                fi
                echo -e "  ${R}✖ Core installation failed. Peer setup was not changed.${NC}" >&2
                return 1
                ;;
            0|q|Q|'') return 1 ;;
            *) echo -e "  ${R}✖ Invalid selection.${NC}" ;;
        esac
    done
}
# mt_workspace_vip supplied by core/common.sh
# mt_workspace_backup supplied by core/common.sh
# END MTUNNEL WORKSPACE V1.0.2

mt_link_field_valid() {
    local key="$1" val="$2"
    case "$key" in
        ROLE) [[ "$val" =~ ^[12]$ ]];;
        NAME) [[ "$val" =~ ^[A-Za-z0-9_-]{1,64}$ ]];;
        HOST) mt_valid_host "$val";;
        EXPIRES) mt_link_uint "$val" 1 9999999999;;
        BBR) [[ "$val" =~ ^[01]$ ]];;
        TOKEN) [[ "$val" =~ ^[A-Za-z0-9_-]{1,256}$ ]];;
        LINK_PORT) mt_valid_port "$val";;
        TRANSPORT) [[ "$val" =~ ^(tcp|tcpmux|tls|tlsmux|ws|wss|wsmux|wssmux|udp|kcp|kcpmux|xhttp|xhttps|xhttpmux|xhttpsmux)$ ]];;
        PORTS) validate_bh_ports "$val" 0;;
        ENABLE_UDP) [[ "$val" =~ ^(true|false)$ ]];;
        BIND_HOST) mt_valid_ipv4 "$val" || mt_valid_ipv6 "$val";;
        PROFILE) [[ "$val" =~ ^(ECO|BALANCED|SPEED|LATENCY|EXTREME|MANUAL|CUSTOM)$ ]];;
        ADV_KEEPALIVE|ADV_HEARTBEAT|ADV_RETRY|ADV_DIAL) mt_link_uint "$val" 1 3600;;
        ADV_CHANNEL) mt_link_uint "$val" 1 65536;;
        ADV_POOL|ADV_MUX_CON) mt_link_uint "$val" 1 1024;;
        ADV_MUX_VERSION) mt_link_uint "$val" 1 2;;
        ADV_MUX_FRAME) mt_link_uint "$val" 512 65535;;
        ADV_MUX_RECEIVE) mt_link_uint "$val" 65536 134217728;;
        ADV_MUX_STREAM) mt_link_uint "$val" 1024 134217728;;
        ADV_MTU) [[ "$val" =~ ^[0-9]{1,5}$ ]] && (( 10#$val == 0 || (10#$val >= 1280 && 10#$val <= 9000) ));;
        ADV_MSS) [[ "$val" =~ ^[0-9]{1,5}$ ]] && (( 10#$val == 0 || (10#$val >= 536 && 10#$val <= 8960) ));;
        ADV_RCVBUF|ADV_SNDBUF) mt_link_uint "$val" 0 134217728;;
        ADV_AGGRESSIVE|ADV_NODELAY|ADV_PROXY|ADV_KCP_NOFEC) [[ "$val" =~ ^(true|false)$ ]];;
        ADV_LOG) [[ "$val" =~ ^(trace|debug|info|warn|error)$ ]];;
        ADV_SNI|ADV_XHTTP_HOST) [ -z "$val" ] || mt_valid_host "$val";;
        ADV_UTLS) [[ "$val" =~ ^(chrome|firefox|safari|edge|ios|random|none)$ ]];;
        ADV_KCP_MODE) [[ "$val" =~ ^(normal|fast|fast2|fast3|manual)$ ]];;
        ADV_KCP_CRYPT) [[ "$val" =~ ^(aes|aes-128|aes-256|salsa20|xor|tea|xtea|sm4|blowfish|twofish|cast5|3des|none)$ ]];;
        ADV_XHTTP_PATH) [[ "$val" =~ ^/[A-Za-z0-9._/-]*$ ]];;
        ADV_XHTTP_MODE) [[ "$val" =~ ^(auto|stream-up|packet-up)$ ]];;
        *) return 1;;
    esac
}

mt_link_deploy_locked() {
    mt_link_validate || return 1
    local MT_LINK_CREATING=1 MT_LINK_CREATION_ID
    MT_LINK_CREATION_ID=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n') || return 1
    local name="${MT_LINK_DATA[NAME]}" role="${MT_LINK_DATA[ROLE]}" host="${MT_LINK_DATA[HOST]}" port="${MT_LINK_DATA[LINK_PORT]}" token="${MT_LINK_DATA[TOKEN]}" bind=0.0.0.0 key settings conf tmp unit
    [[ "$token" =~ ^[A-Za-z0-9_-]{1,256}$ ]] || return 1
    [[ "$host" != *:* ]] || bind=::
    bind="${MT_LINK_DATA[BIND_HOST]:-$bind}"
    if [ "$MT_KIND" = backhaul ]; then name="bh_${name#bh_}"; conf="$CONF_DIR/$name.meta"
    else conf="$CONF_DIR/$name/meta.conf"; fi
    [ ! -e "$conf" ] && { [ "$MT_KIND" != rathole ] || [ ! -e "$CONF_DIR/$name" ]; } || { echo 'Tunnel already exists; nothing overwritten.' >&2; return 1; }
    local _bp_proto=tcp; [[ "${MT_LINK_DATA[TRANSPORT]:-}" =~ ^(udp|kcp|kcpmux)$ ]] && _bp_proto=udp
    if [ "$role" = 1 ] && mt_port_busy "$port" "$_bp_proto"; then echo 'Link port is already in use.' >&2; return 1; fi
    if [ "$MT_KIND" = backhaul ]; then
        validate_bh_ports "${MT_LINK_DATA[PORTS]}" "$role" || return 1
        settings=$(mktemp "$SECURE_TMP/peer-backhaul.XXXXXX") || return 1
        for key in "${!MT_LINK_DATA[@]}"; do
            [[ "$key" == ADV_* || "$key" == PROFILE ]] && printf '%s=%s\n' "$key" "${MT_LINK_DATA[$key]}"
        done > "$settings"
        bh_load_options '' "$settings" || { rm -f "$settings"; return 1; }
        # Forwarder is a choice local to the access server; peer configuration uses the native default.
        bh_activate_config "$name" "$role" "${MT_LINK_DATA[TRANSPORT]}" "$port" "$host" "$token" "${MT_LINK_DATA[PORTS]}" "${MT_LINK_DATA[ENABLE_UDP]}" "$bind" backhaul "$settings"
        local rc=$?; rm -f "$settings"
        if [ "$rc" != 0 ]; then
            # Clean up only our own partially created profile, never a raced/manual profile.
            if [ "$(bh_meta_value PEER_SETUP_ID "$conf")" = "$MT_LINK_CREATION_ID" ]; then
                systemctl stop "mbackhaul@$name"; bh_clear_forwarder "$name"; clean_bh_counters "$name"
                rm -f "$conf" "$CONF_DIR/$name.toml"
            fi
            return 1
        fi
        unit="mbackhaul@$name"
    else
        validate_forward_ports "${MT_LINK_DATA[TCP_PORTS]}" "$role" tcp && validate_forward_ports "${MT_LINK_DATA[UDP_PORTS]}" "$role" udp || return 1
        mkdir "$CONF_DIR/$name" || return 1
        chmod 700 "$CONF_DIR/$name"
        {
            printf 'TYPE=%s\nBIND_HOST=%s\nLINK_PORT=%s\nREMOTE_IP=%s\nTOKEN=%s\nTCP_PORTS=%s\nUDP_PORTS=%s\n' "$role" "$bind" "$port" "$host" "$token" "${MT_LINK_DATA[TCP_PORTS]}" "${MT_LINK_DATA[UDP_PORTS]}"
        } > "$conf"; chmod 600 "$conf"
        unit="mrathole@$name"
        if ! generate_toml "$name" || ! systemctl restart "$unit" || ! mt_workspace_service_ready "$unit"; then
            journalctl -u "$unit" -n 8 --no-pager >&2; systemctl stop "$unit"; clean_rat_counters "$name"; rm -rf "$CONF_DIR/$name"; return 1
        fi
    fi
    systemctl enable "$unit" >/dev/null 2>&1
}
mt_workspace_health() {
    mt_link_select || return 1
    local name conf="$MT_LINK_CONF" host port role unit
    if [ "$MT_KIND" = rathole ]; then name=$(basename "$(dirname "$conf")"); role=$(mt_link_read "$conf" TYPE); port=$(mt_link_read "$conf" LINK_PORT); unit="mrathole@$name"
    else name=$(basename "$conf" .meta); role=$(mt_link_read "$conf" ROLE); port=$(mt_link_read "$conf" TUN_PORT); unit="mbackhaul@$name"; fi
    host=$(mt_link_read "$conf" REMOTE_IP)
    mt_workspace_screen
    systemctl status "$unit" --no-pager -l
    if [ "$role" = 2 ]; then
        if [ "$MT_KIND" = backhaul ] && [[ "$(mt_link_read "$conf" TRANSPORT)" =~ ^(udp|kcp|kcpmux)$ ]]; then
            echo '  UDP link: a TCP probe does not verify this transport; inspect packet counters and peer logs.'
        elif mt_tcp_probe "$host" "$port"; then echo '  TCP link endpoint is reachable (application forwarding must be checked separately).'
        else echo '  TCP link endpoint could not be reached.'; fi
    else echo '  Listener-side sessions:'; ss -tn "sport = :$port"; fi
    journalctl -u "$unit" -n 12 --no-pager
    mt_workspace_pause
}

# mt_link_deploy supplied by core/common.sh

# mt_workspace_auto_backup supplied by core/common.sh
MT_KIND=backhaul; MT_HEADER=draw_header; MT_SECTION=""
mt_workspace_route() {
    local section="$1"
    case "$section" in
        1) MT_SECTION=1; mt_workspace_menu "CREATE TUNNEL" "1|Manual Backhaul Setup|1|${G}" "2|Create From Peer Link|97|${G}" "3|Generate Peer Setup Link|98|${M}" || { MT_SECTION=""; return 1; };;
        2) MT_SECTION=2; mt_workspace_menu "EDIT & MANAGE" "1|Remote Host / IP|3|${C}" "2|Transport & Profile Settings|5|${M}" "3|Auth Token|6|${G}" "4|Link Port|7|${C}" "5|Tunnel Name|9|${W}" "6|Listen Address|10|${C}" "7|Delete Tunnels|2|${R}" || { MT_SECTION=""; return 1; };;
        3) MT_SECTION=3; mt_workspace_menu "FORWARDING" "1|Port Mappings|4|${Y}" "2|UDP Acceptance|8|${C}" || { MT_SECTION=""; return 1; };;
        4) MT_SECTION=4; mt_workspace_menu "SYSTEM & SECURITY" "1|Auto Recovery|13|${G}" "2|BBR Settings|14|${G}" "3|Scheduled Restart|15|${Y}" "4|Restart & Zero Counters|16|${G}" "5|Check Selected Tunnel|99|${C}" || { MT_SECTION=""; return 1; };;
        5) MT_ACTION=11;;
        6) MT_ACTION=12;;
        7) MT_ACTION=20;;
        8) MT_ACTION=96;;
        9) MT_ACTION=201;;
        10) MT_SECTION=2; MT_ACTION=2; MT_SHORTCUT=1;;
        11) MT_ACTION=19;;
        0) MT_ACTION=0;;
        *) return 1;;
    esac
}

render_mbackhaul_menu() {
    mt_workspace_screen
    mt_workspace_group 'PROVISION & MANAGE' first
    mt_workspace_row 1 'Create Tunnel' "$C"
    mt_workspace_row 2 'Edit & Manage' "$Y"
    mt_workspace_row 3 'Forwarding' "$G"
    mt_workspace_row 4 'System & Security' "$M"
    mt_workspace_row 5 'Tunnel Info & Specs' "$M"
    mt_workspace_row 6 'Live Monitor' "$C"
    mt_workspace_row 7 'Update & Local Install' "$G" "$(mt_workspace_update_badge)"
    mt_workspace_row 8 'Backup & Restore' "$W"
    mt_workspace_row 9 'Logs' "$Y"
    mt_workspace_row 10 'Delete Tunnels' "$R"
    mt_workspace_row 11 'Uninstall MBACKHAUL' "$R"
    mt_workspace_footer 'Return to Main Core'
}

if [ "${1:-}" = "--deploy-peer-link" ] || [ "${1:-}" = "--deploy-peer-stdin" ]; then
    is_bh_core_valid || {
        if bh_core_bin >/dev/null; then bh_probe_version "$(bh_core_bin)"; echo "Backhaul core is v${BH_PROBED_VERSION} but v${BH_EXPECT_VERSION} is required on this server." >&2
        else echo "Backhaul core is missing or invalid on this server." >&2; fi
        exit 3
    }
    if [ "${1:-}" = "--deploy-peer-stdin" ]; then IFS= read -r mt_peer_arg; else mt_peer_arg="${2:-}"; fi
    [ -n "$mt_peer_arg" ] || { echo "Missing Peer Link." >&2; exit 2; }
    mt_link_decode "$mt_peer_arg" || { echo "Invalid Peer Link." >&2; exit 2; }
    unset mt_peer_arg
    mt_link_deploy
    exit $?
fi
if [ -n "${MT_PEER_LINK:-}" ]; then mt_link_import; exit $?; fi
_MT_SKIP_HDR_SCAN=0
while true; do
    if [ -n "$MT_SECTION" ]; then opt="$MT_SECTION"
    else
        if [ "$_MT_SKIP_HDR_SCAN" = 1 ]; then _MT_SKIP_HDR_SCAN=0; MT_HEADER_USE_CACHE=1 render_mbackhaul_menu
        else render_mbackhaul_menu; fi
        read_with_refresh "  ${C}MBACKHAUL ❯❯ ${NC}" opt render_mbackhaul_menu || break
        opt="${opt//$'\r'/}"
    fi
    mt_workspace_route "$opt" || { _MT_SKIP_HDR_SCAN=1; continue; }
    case "$MT_ACTION" in
        97) mt_link_import; continue;;
        98) mt_link_export; continue;;
        99) mt_workspace_health; continue;;
        201) mt_main_logs; continue;;
        96) mt_workspace_menu "BACKUP & RESTORE" "1|Save Config Backup|save|${W}" || continue; mt_workspace_backup; continue;;
    esac
    # Every edit/forwarding action gets a private config restore point first.
    if [[ "$MT_SECTION" == 2 || "$MT_SECTION" == 3 ]]; then
        mt_workspace_auto_backup || { echo 'Could not save the config restore point; operation cancelled.' >&2; mt_workspace_pause; continue; }
    fi
    [ "${MT_SHORTCUT:-}" = 1 ] && { MT_SECTION=""; MT_SHORTCUT=""; }
    opt="$MT_ACTION"
    case $opt in
        1) 
           bh_start_screen
           echo -e "\n  ${FR}┌─[ DEPLOY NEW TUNNEL ]${NC}"
           while true; do 
               echo -ne "  ${C}●${NC} ${W}Role [1: IRAN (Server) | 2: KHAREJ (Client) | q: Back]: ${NC}"; read -r s_type
               s_type=$(echo "$s_type" | tr -d '\r')
               [[ "$s_type" =~ ^[12q]$ ]] && break
           done
           [[ "$s_type" == "q" ]] && continue
           
           bh_select_transport || continue
           tr_val="$BH_TRANSPORT"

           _def_suf=1
           while [ -f "$CONF_DIR/bh_${_def_suf}.meta" ]; do _def_suf=$((_def_suf + 1)); done
           while true; do
               echo -ne "  ${C}● Tunnel Suffix Name [Default ${_def_suf}]: ${NC}"; read -r suffix
               suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9_-')
               suffix="${suffix#bh_}"
               suffix="${suffix:-$_def_suf}"
               [ -n "$suffix" ] && break
               echo -e "  ${R}Error: Tunnel suffix cannot be empty.${NC}"
           done
           t_name="bh_${suffix}"
           if [ -f "$CONF_DIR/$t_name.meta" ]; then
               echo -e "  ${R}● This tunnel name already exists.${NC}"; sleep 2; continue
           fi
           
           def_p=8443
           case "$tr_val" in
               tcpmux|tlsmux|kcpmux|kcp) def_p=9443;;
               wss|wssmux|xhttps|xhttpsmux) def_p=2053;;
               ws|wsmux|xhttp|xhttpmux) def_p=8080;;
           esac
           _ss_flag="-tln"; [[ "$tr_val" =~ ^(udp|kcp|kcpmux)$ ]] && _ss_flag="-uln"
           while true; do
               echo -ne "  ${C}● Tunnel Link Port [Default ${def_p}]: ${NC}"; read -r t_port
               t_port=${t_port//$'\r'/}
               t_port=${t_port:-$def_p}
               
               if ! mt_valid_port "$t_port"; then
                   echo -e "  ${R}Error: Port must be between 1 and 65535!${NC}"
                   continue
               fi

               if [ "$s_type" == "1" ] && ss "$_ss_flag" 2>/dev/null | grep -qE ":${t_port}\s"; then
                   echo -e "  ${R}Error: Local port ${t_port} is already in use by another service!${NC}"
                   continue
               fi
               break
           done
           
           bind_host="0.0.0.0"
           if [ "$s_type" == 1 ]; then mt_ask_bind_host || continue; bind_host="$MT_BIND_HOST"; fi
           r_ip="0.0.0.0"
           if [ "$s_type" == "2" ]; then
               while true; do
                   echo -ne "  ${C}● Iran Server Host/IP: ${NC}"; read -r r_ip
                   r_ip=$(mt_normalize_host "${r_ip//$'\r'/}")
                   is_valid_host "$r_ip" && break
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"
               done
           fi
           
           gen_tok=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
           echo -ne "  ${C}● Auth Token [Default ${gen_tok}]: ${NC}"; read -r u_tok
           u_tok=$(echo "$u_tok" | tr -dc 'a-zA-Z0-9_-')
           tok=${u_tok:-$gen_tok}

           u_udp="false"
           fwd_ports=""
           if [ "$s_type" == "1" ]; then
               if [ "$tr_val" = udp ]; then u_udp=true
               elif [ "$tr_val" = tcp ]; then
                   echo -ne "  ${C}●${NC} ${W}Accept UDP applications over TCP too? [y/N]: ${NC}"; read -r enable_udp
                   [[ "${enable_udp,,}" != y && "${enable_udp,,}" != yes ]] || u_udp=true
               fi

               # Validate forwarded ports on Iran server
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Forward Ports (e.g. 443=127.0.0.1:443): ${NC}"; read -r fwd_ports
                   fwd_ports=$(echo "$fwd_ports" | tr -d '\r')
                   if [ -n "$fwd_ports" ]; then bh_ports_guard "$fwd_ports" "$([ "$u_udp" = true ] && echo 1 || echo 0)" "" || continue; fwd_ports="$BH_SPEC_OUT"; fi
                   validate_bh_ports "$fwd_ports" "1" && break
               done
           fi
           
           BH_FORWARDER=backhaul
           bh_advanced_wizard "$t_name" "$s_type" "$tr_val" || continue
           bh_activate_config "$t_name" "$s_type" "$tr_val" "$t_port" "$r_ip" "$tok" "$fwd_ports" "$u_udp" "$bind_host" "$BH_FORWARDER" "$BH_SETTINGS_FILE"; deploy_rc=$?
           rm -f "$BH_SETTINGS_FILE"
           [ "$deploy_rc" = 0 ] || { systemctl disable --now "mbackhaul@${t_name}" >/dev/null 2>&1 || true; echo -e "  ${R}● Tunnel was not deployed; check the error above.${NC}"; sleep 2; continue; }
           systemctl enable "mbackhaul@${t_name}" >/dev/null 2>&1
           if systemctl is-active --quiet "mbackhaul@${t_name}"; then mt_ask_bbr_on_create; fi
           if systemctl is-active --quiet "mbackhaul@${t_name}"; then
               echo -e "  ${G}● Backhaul Tunnel Deployed Successfully! (Profile: ${BH_PROFILE:-BALANCED})${NC}"
               bh_show_forwarder "$t_name"
               mt_link_offer "$CONF_DIR/$t_name.meta"
               echo -ne "  ${DIM}Press Enter to continue...${NC}"; read -r _
           else echo -e "  ${R}● Tunnel failed to start; check its logs.${NC}"; sleep 2; fi ;;
           
        2)
           configs=($(ls "$CONF_DIR"/*.meta 2>/dev/null))
           [ ${#configs[@]} -eq 0 ] && continue
           echo -e "\n  ${FR}╔══════════════════ Select Tunnel to Delete ═════════════════╗${NC}"
           for i in "${!configs[@]}"; do printf "  ${FR}║${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${FR}║${NC}\n" "$i" "$(basename "${configs[$i]}" .meta)"; done
           echo -e "  ${FR}╚════════════════════════════════════════════════════════════╝${NC}"
           echo -ne "  ${C}Index (or 'all' / 'q'): ${NC}"; read -r del_idx
           del_idx=$(echo "$del_idx" | tr -d '\r')
           if [[ "$del_idx" == "all" ]]; then
               for conf in "${configs[@]}"; do
                   t_name=$(basename "$conf" .meta)
                   systemctl stop mbackhaul@$t_name 2>/dev/null; systemctl disable mbackhaul@$t_name 2>/dev/null
                   clean_bh_counters "$t_name"
                   if command -v crontab >/dev/null 2>&1; then
                       cron_tmp="$SECURE_TMP/crontab.$$"
                       crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
                       crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
                   fi
                   bh_delete_forwarder "$t_name" || continue
                   rm -f "$conf" "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${t_name}_restart.sh"
               done
               echo -e "  ${G}All Tunnels Purged!${NC}"; sleep 1.5
           elif mt_valid_index "$del_idx" "${#configs[@]}"; then
               del_idx=$((10#$del_idx))
               t_name=$(basename "${configs[$del_idx]}" .meta)
               systemctl stop mbackhaul@$t_name 2>/dev/null; systemctl disable mbackhaul@$t_name 2>/dev/null
               clean_bh_counters "$t_name"
               if command -v crontab >/dev/null 2>&1; then
                   cron_tmp="$SECURE_TMP/crontab.$$"
                   crontab -l 2>/dev/null | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
                   crontab "$cron_tmp" 2>/dev/null; rm -f "$cron_tmp"
               fi
               bh_delete_forwarder "$t_name" || continue
               rm -f "${configs[$del_idx]}" "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${t_name}_restart.sh"
               echo -e "  ${G}Tunnel Purged!${NC}"; sleep 1.5
           fi ;;
           
        3|4|5|6|7|8|9|15|16|10)
           select_tunnel || continue
           t_name=$(basename "$SELECTED_TUN" .meta)
           ROLE=""; TRANSPORT=""; TUN_PORT=""; REMOTE_IP=""; TOKEN=""; PORTS=""; ENABLE_UDP=""; BIND_HOST="0.0.0.0"; FORWARDER=backhaul
           BH_SETTINGS_FILE=""
           mt_source_conf "$SELECTED_TUN" 2>/dev/null
           [ -z "$ENABLE_UDP" ] && ENABLE_UDP="true"
           
           if [[ "$opt" == "3" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Remote Host/IP (Current: ${REMOTE_IP}): ${NC}"; read -r n_ip
               n_ip=$(mt_normalize_host "${n_ip//$'\r'/}")
               if [ -z "$n_ip" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               if ! is_valid_host "$n_ip"; then
                   echo -e "  ${R}Error: Invalid Host or IP format!${NC}"; sleep 1.5; continue
               fi
               clean_bh_counters "$t_name"
               REMOTE_IP="$n_ip"
               
           elif [[ "$opt" == "4" ]]; then
               if [ "$ROLE" == "1" ]; then
                   while true; do
                       echo -ne "  ${C}●${NC} ${W}New Port Mappings (e.g. 443=127.0.0.1:443) [Current: ${PORTS:-None}]: ${NC}"; read -r n_ports
                       n_ports=$(echo "$n_ports" | tr -d '\r')
                       if [ -z "$n_ports" ]; then break; fi
                       bh_ports_guard "$n_ports" "$([ "$ENABLE_UDP" = true ] || [ "$TRANSPORT" = udp ] && echo 1 || echo 0)" "mbackhaul@${t_name}.service" || continue; n_ports="$BH_SPEC_OUT"
                       [ -n "$n_ports" ] || { echo -e "  ${Y}● No usable ports left.${NC}"; continue; }
                       validate_bh_ports "$n_ports" "1" "$PORTS" && { PORTS="$n_ports"; break; }
                   done
                   FORWARDER="backhaul"
               else
                   echo -e "  ${Y}● Client role doesn't use port mappings.${NC}"; sleep 1.5; continue
               fi
               
           elif [[ "$opt" == "5" ]]; then
               bh_start_screen
               echo -e "\n  ${FR}┌─[ TRANSPORT & ADVANCED SETTINGS ]${NC}"
               echo -ne "  ${C}Change transport? [y/N; current: $TRANSPORT] ❯❯ ${NC}"; read -r change_transport
               if [[ "${change_transport,,}" == y || "${change_transport,,}" == yes ]]; then
                   bh_select_transport || continue; TRANSPORT="$BH_TRANSPORT"
               fi
               if [ "$TRANSPORT" = udp ] && [ "$FORWARDER" = mporter ]; then FORWARDER="backhaul"; fi
               bh_advanced_wizard "$t_name" "$ROLE" "$TRANSPORT" || continue
               echo -e "  ${Y}⚠ Update the peer to use matching transport / MUX settings.${NC}"

           elif [[ "$opt" == "6" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Auth Token / Secret [Current: ${Y}${TOKEN}${W}]: ${NC}"; read -r n_tok
               n_tok=$(echo "$n_tok" | tr -dc 'a-zA-Z0-9_-')
               if [ -z "$n_tok" ]; then
                   echo -e "  ${Y}● No changes made.${NC}"; sleep 1; continue
               fi
               TOKEN="$n_tok"
               echo -e "  ${G}✔ Auth Token updated to: ${TOKEN}${NC}"

           elif [[ "$opt" == "7" ]]; then
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Enter New Link Port [Current: ${Y}${TUN_PORT}${W}]: ${NC}"; read -r n_tun_port
                   n_tun_port=${n_tun_port//$'\r'/}
                   if [ -z "$n_tun_port" ]; then
                       echo -e "  ${Y}● No changes made.${NC}"; break
                   fi
                   if ! mt_valid_port "$n_tun_port"; then
                       echo -e "  ${R}Error: Port must be between 1 and 65535!${NC}"; continue
                   fi
                   _e_ss="-tln"; [[ "$TRANSPORT" =~ ^(udp|kcp|kcpmux)$ ]] && _e_ss="-uln"
                   if [ "$ROLE" == "1" ] && [ "$n_tun_port" != "$TUN_PORT" ] && ss "$_e_ss" 2>/dev/null | grep -qE ":${n_tun_port}\s"; then
                       echo -e "  ${R}Error: Port ${n_tun_port} is already in use!${NC}"; continue
                   fi
                   clean_bh_counters "$t_name"
                   TUN_PORT="$n_tun_port"
                   echo -e "  ${G}✔ Link Port updated to ${n_tun_port}.${NC}"
                   break
               done
               [ -z "$n_tun_port" ] && continue

           elif [[ "$opt" == "8" ]]; then
               if [ "$ROLE" == "1" ]; then
                   if [ "$TRANSPORT" != tcp ]; then echo -e "  ${Y}● UDP acceptance is available on TCP; UDP transport is always UDP-only.${NC}"; sleep 2; continue; fi
                   if [ "${FORWARDER:-backhaul}" = mporter ]; then
                       echo -e "  ${Y}● MPorter forwards TCP here; select Backhaul or iptables for UDP.${NC}"; sleep 2; continue
                   fi
                   if [ "$ENABLE_UDP" == "true" ]; then
                       ENABLE_UDP="false"
                       echo -e "  ${Y}● UDP forwarding Disabled.${NC}"
                   else
                       ENABLE_UDP="true"
                       echo -e "  ${G}✔ UDP forwarding Enabled.${NC}"
                   fi
               else
                   echo -e "  ${Y}● UDP toggle is configured on the Server (Iran) side.${NC}"; sleep 1.5; continue
               fi
               
           elif [[ "$opt" == "9" ]]; then
               echo -ne "  ${C}●${NC} ${W}New Tunnel Suffix Name (Current: ${Y}${t_name#bh_}${W}): ${NC}"; read -r new_suffix
               new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
               if [ -n "$new_suffix" ]; then
                   new_t_name="bh_${new_suffix}"
                   if [ -f "$CONF_DIR/${new_t_name}.meta" ]; then
                       echo -e "  ${R}● Error: Tunnel name [${new_t_name}] already exists!${NC}"; sleep 1.5; continue
                   fi
                   
                   systemctl stop mbackhaul@$t_name 2>/dev/null; systemctl disable mbackhaul@$t_name 2>/dev/null
                   clean_bh_counters "$t_name"
                   
                   if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "mbackhaul@${t_name}"; then
                       cron_tmp="$SECURE_TMP/crontab.$$"
                       crontab -l | grep -v "mbackhaul@${t_name}" > "$cron_tmp"
                       crontab "$cron_tmp"; rm -f "$cron_tmp"
                       rm -f "$CONF_DIR/${t_name}_restart.sh"
                   fi

                   mv "$CONF_DIR/${t_name}.meta" "$CONF_DIR/${new_t_name}.meta" 2>/dev/null
                   mv "$CONF_DIR/${t_name}.toml" "$CONF_DIR/${new_t_name}.toml" 2>/dev/null
                   
                   t_name="$new_t_name"
                   systemctl enable mbackhaul@$t_name >/dev/null 2>&1
                   echo -e "  ${G}● Tunnel successfully renamed to: ${new_t_name}${NC}"
               else
                   echo -e "  ${Y}● Rename cancelled.${NC}"; sleep 1; continue
               fi
               
           elif [[ "$opt" == "15" ]]; then
               manage_cron "$t_name"; continue
               
           elif [[ "$opt" == "10" ]]; then
               [ "$ROLE" == 1 ] || continue
               mt_ask_bind_host || continue; BIND_HOST="$MT_BIND_HOST"

           elif [[ "$opt" == "16" ]]; then
               zero_bh_counters "$t_name"
           fi
           
           bh_activate_config "$t_name" "$ROLE" "$TRANSPORT" "$TUN_PORT" "$REMOTE_IP" "$TOKEN" "$PORTS" "$ENABLE_UDP" "$BIND_HOST" "${FORWARDER:-backhaul}" "$BH_SETTINGS_FILE"; update_rc=$?
           rm -f "$BH_SETTINGS_FILE"
           [ "$update_rc" = 0 ] || { sleep 2; continue; }
           if systemctl is-active --quiet mbackhaul@$t_name; then
               echo -e "  ${G}✔ Tunnel updated and service restarted successfully.${NC}"
               bh_show_forwarder "$t_name"
               echo -ne "  ${DIM}Press Enter to continue...${NC}"; read -r _
           else
               echo -e "  ${R}✖ Tunnel failed to start. Please check logs!${NC}"; sleep 2
           fi
           ;;
           
        11) show_tunnels_info ;;
        17) menu_install_core ;;
        18) self_update_module ;;
        20) unified_update_menu ;;
        19) uninstall_mbackhaul ;;
        13) mt_run_tool mhealer --scope backhaul ;;
        14) mt_run_tool mbbr --from-tunnel ;;
        12) show_live_radar ;;
        0) break ;;
    esac
done
