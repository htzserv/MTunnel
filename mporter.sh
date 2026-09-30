#!/bin/bash
# --- MDesign Modular Core (mporter.sh) | MPorter Manager v10.0.0 ---
# [Features: State Controller | Smart Loadbalancing | Failover | L4 Health | Safe OBFS | BBR/MSS Optimized]

MODULE_VERSION="10.0.0"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mporter"
SERVICE_FILE="/etc/systemd/system/mporter.service"
H_CONF="/etc/haproxy/haproxy.cfg"
G_CONF="/etc/gost/config.json"
R_CONF="/etc/realm/config.json"
OBFS_DIR="/etc/mporter/obfs_rules"
IPT_DIR="/etc/mporter/iptables_core"
IPT_CONF="$IPT_DIR/rules.sh"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
STATE_DIR="/etc/mporter"
STATE_FILE="$STATE_DIR/state.json"
HEALTH_FILE="/run/mporter-backends.tsv"
LOCK_FILE="/var/lock/mporter-state.lock"
LB_MARKER="# === MPORTER_V10_MANAGED ==="
LB_END_MARKER="# === MPORTER_V10_MANAGED_END ==="
WATCHDOG_SERVICE="mporter-watchdog.service"
WATCHDOG_SCRIPT="/usr/local/bin/mporter-watchdog.sh"

mkdir -p "$LOCAL_DIR/packages" /etc/haproxy /var/lib/haproxy /etc/gost /etc/realm "$OBFS_DIR" "$IPT_DIR" "$STATE_DIR" /usr/sbin /usr/local/sbin /usr/local/bin "$SECURE_TMP" /var/lock 2>/dev/null
touch "$IPT_CONF" 2>/dev/null; chmod +x "$IPT_CONF" 2>/dev/null

if [ -f "$0" ] && [ "$0" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

setup_mporter_service() {
    local tmp_srv="$SECURE_TMP/mporter_tpl.service"
    cat <<'EOF_SRV' > "$tmp_srv"
[Unit]
Description=MPorter Port Forwarding Master Service
After=network.target haproxy.service gost.service realm.service mporter-iptables.service
Wants=haproxy.service gost.service realm.service mporter-iptables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
EOF_SRV
    if ! cmp -s "$tmp_srv" "$SERVICE_FILE" 2>/dev/null; then
        mv -f "$tmp_srv" "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable mporter.service >/dev/null 2>&1
    else
        rm -f "$tmp_srv"
    fi

    if systemctl is-active --quiet haproxy 2>/dev/null || systemctl is-active --quiet gost 2>/dev/null || systemctl is-active --quiet realm 2>/dev/null || systemctl is-active --quiet mporter-iptables 2>/dev/null; then
        systemctl start mporter.service >/dev/null 2>&1
    fi
}
setup_mporter_service

ensure_jq() {
    if command -v jq >/dev/null 2>&1 && jq -n 'null' >/dev/null 2>&1; then return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::ForceIPv4=true -y -q >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -o Acquire::ForceIPv4=true -y -q jq libjq1 libonig5 >/dev/null 2>&1
    if command -v jq >/dev/null 2>&1 && jq -n 'null' >/dev/null 2>&1; then return 0; fi
    return 1
}

check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/mporter.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/mporter.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mporter_remote_ver"
}
check_update_bg &

self_update_module() {
    local rel_path="mporter.sh"
    local cb="?t=$(date +%s)"
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mporter_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mporter_remote_ver" | tr -d '\r\n ')

    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (Script Only) ]${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        echo -e "  ${DIM}├─${NC} ${Y}Update Available: v${MODULE_VERSION} ➔ v${remote_v}${NC}"
    else
        echo -e "  ${DIM}├─${NC} ${DIM}Current Version: v${MODULE_VERSION}${NC}"
    fi

    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Server${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Offline Editor)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_opt
    
    local tmp_file="$SECURE_TMP/.mporter_update.$$"
    local dl_success=false

    if [[ "$src_opt" == "4" ]]; then
        > "$tmp_file"
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste your code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
            sleep 2; nano "$tmp_file"
        else
            echo -e "  ${R}✖ No text editor found!${NC}"; rm -f "$tmp_file"; sleep 2; return
        fi
        dl_success=true
    elif [[ "$src_opt" =~ ^[123]$ ]]; then
        local dl_url=""
        case $src_opt in
            1) dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path$cb" ;;
            2) dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path$cb" ;;
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read custom_url; dl_url=$(echo "$custom_url" | tr -d '\r' | tr -d ' ');;
        esac

        echo -e "\n  ${C}⟳${NC} ${W}Downloading MPorter Update...${NC}"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 8 --max-time 45 -o "$tmp_file" "$dl_url" 2>/dev/null && dl_success=true
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 -O "$tmp_file" "$dl_url" 2>/dev/null && dl_success=true
        fi
    else return; fi

    if [ "$dl_success" = true ] && [ -s "$tmp_file" ] && grep -q "#!/bin/bash" "$tmp_file"; then
        local new_ver=$(grep -m1 '^MODULE_VERSION=' "$tmp_file" | cut -d'"' -f2)
        [ -z "$new_ver" ] && new_ver="Unknown"
        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read confirm

        if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
            sed -i 's/\r$//' "$tmp_file" 2>/dev/null; chmod +x "$tmp_file"
            cat "$tmp_file" > "$INSTALL_PATH" 2>/dev/null || true
            [ -f "$0" ] && cat "$tmp_file" > "$0" 2>/dev/null || true
            cp -f "$tmp_file" "$LOCAL_DIR/$rel_path" 2>/dev/null; rm -f "$tmp_file"
            echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"; sleep 1.5; exec "$INSTALL_PATH" "$@"
        else rm -f "$tmp_file"; fi
    else rm -f "$tmp_file"; fi
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_progress_bar() {
    local pid=$1; local text=$2; local width=28; local timeout_s=${3:-40}; local start_ts=$(date +%s)
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( $(date +%s) - start_ts ))
        local progress=$(( elapsed * 95 / timeout_s ))
        [ "$progress" -lt 1 ] && progress=1; [ "$progress" -gt 95 ] && progress=95
        local filled=$(( progress * width / 100 )); local empty=$(( width - filled ))
        local bar=$(printf "%${filled}s" "" | tr ' ' '#'); local empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')
        printf "\r  ${C}⟳${NC} ${W}%-26s${NC} ${B}[${G}%s${DIM}%s${B}]${NC} ${C}%3d%%${NC}" "$text" "$bar" "$empty_bar" "$progress"
        sleep 0.2
        if [ "$elapsed" -ge "$timeout_s" ]; then
            kill -9 "$pid" 2>/dev/null || true
            printf "\r  ${R}✖${NC} ${W}%-26s${NC} ${R}[ TIMEOUT ]${NC}      \n" "$text"
            tput cnorm 2>/dev/null || true; return 1
        fi
    done
    wait "$pid" 2>/dev/null || true
    local bar=$(printf "%${width}s" "" | tr ' ' '#')
    printf "\r  ${G}✔${NC} ${W}%-26s${NC} ${B}[${G}%s${B}]${NC} ${G}100%%${NC}\n" "$text" "$bar"
    tput cnorm 2>/dev/null || true
}


# ==========================================================
# MPorter v10 Controller / State / Health Layer
# ==========================================================

state_init() {
    mkdir -p "$STATE_DIR" /run "$SECURE_TMP" 2>/dev/null
    if ! command -v jq >/dev/null 2>&1; then return 1; fi
    if [ ! -s "$STATE_FILE" ] || ! jq -e '.version == 1 and (.mappings|type=="array") and (.backends|type=="array") and (.pools|type=="array")' "$STATE_FILE" >/dev/null 2>&1; then
        cat > "$STATE_FILE" <<EOF_STATE
{
  "version": 1,
  "updated_at": "$(date -Is)",
  "mappings": [],
  "backends": [],
  "pools": []
}
EOF_STATE
    fi
    chmod 600 "$STATE_FILE" 2>/dev/null
}

state_lock() {
    exec 9>"$LOCK_FILE"
    flock -x 9
}

state_unlock() {
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
}

state_write_json() {
    local tmp="$STATE_FILE.tmp.$$"
    cat > "$tmp"
    if jq . "$tmp" >/dev/null 2>&1; then
        chmod 600 "$tmp" 2>/dev/null
        mv -f "$tmp" "$STATE_FILE"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

state_add_mapping() {
    local port="$1" engine="$2" target="$3" iface="$4" mode="${5:-DIRECT}" pool="${6:-}" obfs="${7:-false}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    state_init || return 1
    state_lock
    local tmp="$STATE_FILE.tmp.$$"
    jq --argjson p "$port" --arg e "$engine" --arg t "$target" --arg i "$iface" --arg m "$mode" --arg pool "$pool" --argjson o "$obfs" \
       --arg now "$(date -Is)" \
       '.mappings = ([.mappings[] | select(.port != $p or .engine != $e or .target_ip != $t)] + [{port:$p,engine:$e,target_ip:$t,interface:$i,mode:$m,pool:$pool,obfs:$o,updated_at:$now}]) | .updated_at=$now' \
       "$STATE_FILE" > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    state_unlock
}

state_remove_target() {
    local target="$1"
    state_init || return 1
    state_lock
    local tmp="$STATE_FILE.tmp.$$"
    jq --arg t "$target" --arg now "$(date -Is)" '.mappings=[.mappings[]|select(.target_ip != $t)] | .backends=[.backends[]|select(.target_ip != $t)] | .pools=[.pools[]|.targets |= map(select(.ip != $t)) | select((.targets|length)>0)] | .updated_at=$now' "$STATE_FILE" > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    state_unlock
}

state_reconcile() {
    ensure_jq >/dev/null 2>&1 || return 1
    state_init || return 1
    local tmp="$STATE_FILE.reconcile.$$"
    local now="$(date -Is)"
    local h='[]' g='[]' r='[]' n='[]' pools='[]'
    pools=$(jq '.pools // []' "$STATE_FILE" 2>/dev/null || echo '[]')

    if [ -f "$H_CONF" ]; then
        h=$(awk '
          /^frontend ft_[0-9]+$/ {p=$2; sub(/^ft_/,"",p); next}
          /^    bind \*:[0-9]+$/ {next}
          /^backend bk_[0-9]+$/ {b=$2; sub(/^bk_/,"",b); next}
          /^    server srv_[^ ]+ [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+/ {
             split($3,a,":"); name=$2; gsub(/^srv_[0-9]+_?/ ,"",name); if(name==""||name==$2) name="0";
             print b"|"a[1]"|"a[2]"|HAP";
          }' "$H_CONF" 2>/dev/null | while IFS='|' read -r p ip rp e; do
            [ -n "$p" ] && [ -n "$ip" ] && printf '%s\n' "$p|$ip|$rp|$e"
        done | jq -Rn '[inputs|split("|")|select(length>=4)|{port:(.[0]|tonumber),target_ip:.[1],target_port:(.[2]|tonumber),engine:"HAP",mode:"LOADBALANCE"}]' 2>/dev/null)
    fi
    [ -z "$h" ] && h='[]'
    h=$(jq '[.[] | select(.target_ip != "127.0.0.1" and .port != 9999)] | group_by(.port) | map(if length > 1 then map(.mode="LOADBALANCE") else map(.mode="DIRECT") end) | add // []' <<< "$h" 2>/dev/null || echo '[]')

    if [ -f "$G_CONF" ] && jq -e '.ServeNodes|type=="array"' "$G_CONF" >/dev/null 2>&1; then
        g=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | sed -nE 's#tcp://:([0-9]+)/([0-9.]+):([0-9]+).*#\1|\2|\3|GST#p' | jq -Rn '[inputs|split("|")|{port:(.[0]|tonumber),target_ip:.[1],target_port:(.[2]|tonumber),engine:"GST",mode:"DIRECT"}]' 2>/dev/null); [ -z "$g" ] && g='[]'
    fi
    if [ -f "$R_CONF" ]; then
        r=$(jq -r '.endpoints[]? | "\(.listen)|\(.remote)"' "$R_CONF" 2>/dev/null | sed -nE 's#0\.0\.0\.0:([0-9]+)\|([0-9.]+):([0-9]+).*#\1|\2|\3|RLM#p' | jq -Rn '[inputs|split("|")|{port:(.[0]|tonumber),target_ip:.[1],target_port:(.[2]|tonumber),engine:"RLM",mode:"DIRECT"}]' 2>/dev/null); [ -z "$r" ] && r='[]'
    fi
    if [ -f "$IPT_CONF" ]; then
        n=$(grep 'PREROUTING' "$IPT_CONF" 2>/dev/null | sed -nE 's/.*--dport ([0-9]+).*MPORTER_NAT_([0-9.]+).*/\1|\2|\1|IPT/p' | jq -Rn '[inputs|split("|")|{port:(.[0]|tonumber),target_ip:.[1],target_port:(.[2]|tonumber),engine:"IPT",mode:"DIRECT"}]' 2>/dev/null); [ -z "$n" ] && n='[]'
    fi

    jq -n --arg now "$now" --argjson h "$h" --argjson g "$g" --argjson r "$r" --argjson n "$n" --argjson pools "$pools" '
      def norm: map(. + {interface:"",pool:"",obfs:false,updated_at:$now});
      (($h+$g+$r+$n)|norm) as $m |
      {version:1,updated_at:$now,mappings:$m,backends:[],pools:$pools}' > "$tmp" 2>/dev/null
    if jq . "$tmp" >/dev/null 2>&1; then chmod 600 "$tmp"; mv -f "$tmp" "$STATE_FILE"; else rm -f "$tmp"; return 1; fi
}

state_sync_interface_metadata() {
    state_init || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local tmp="$STATE_FILE.tmp.$$" now="$(date -Is)"
    cp -f "$STATE_FILE" "$tmp" 2>/dev/null || return 0
    while IFS=$'\t' read -r idx ip; do
        [ -n "$idx" ] || continue
        local iface=""
        iface=$(ip route get "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
        [ -z "$iface" ] && iface="unknown"
        jq --argjson idx "$idx" --arg iface "$iface" --arg now "$now" '.mappings[$idx].interface=$iface | .mappings[$idx].updated_at=$now | .updated_at=$now' "$tmp" > "$tmp.new" 2>/dev/null && mv -f "$tmp.new" "$tmp"
    done < <(jq -r 'to_entries[] | [.key,.value.target_ip] | @tsv' <(jq '.mappings' "$STATE_FILE") 2>/dev/null)
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp"
}

valid_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    for o in "$a" "$b" "$c" "$d"; do [ "$o" -le 255 ] 2>/dev/null || return 1; done
    return 0
}

# Peer discovery deliberately avoids the old blind last-octet+1 rule.
# Priority: explicit tunnel metadata -> kernel neighbour -> /30 peer inference.
discover_peer_ips() {
    local iface="$1" out="" conf var val
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf /etc/ml2tp/tunnels/*.conf /etc/mhysteria/tunnels/*.conf; do
        [ -f "$conf" ] || continue
        grep -qE "(^|[[:space:]])(T_NAME|BR_NAME)=[\"\']?$iface([\"\']|$)" "$conf" 2>/dev/null || continue
        while IFS='=' read -r var val; do
            val="${val%$'\r'}"; val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
            case "$var" in
                REMOTE_IP|PEER_IP|PEER_ADDR|PEER_ADDRESS|REMOTE_ADDR|REMOTE_ADDRESS|REMOTE|ENDPOINT|ENDPOINT_IP|CORE_PEER_IP|TUNNEL_PEER_IP)
                    valid_ipv4 "$val" && out+="$val\n";;
            esac
        done < "$conf"
    done
    # Kernel neighbour cache is preferred over arithmetic guessing.
    while read -r ip _; do valid_ipv4 "$ip" && out+="$ip\n"; done < <(ip -4 neigh show dev "$iface" nud reachable nud stale nud delay nud probe 2>/dev/null | awk '{print $1}')
    # Safe fallback only for a directly connected /30: select the other usable host.
    while read -r cidr; do
        local prefix="${cidr#*/}" ip="${cidr%/*}" base a b c d host net peer
        [ "$prefix" = "30" ] || continue
        IFS=. read -r a b c d <<< "$ip"; net=$(( (a<<24) | (b<<16) | (c<<8) | d )); base=$(( net & 0xFFFFFFFC )); host=$(( net-base ))
        if [ "$host" -eq 1 ]; then peer=$((base+2)); elif [ "$host" -eq 2 ]; then peer=$((base+1)); else continue; fi
        printf '%s.%s.%s.%s\n' $((peer>>24&255)) $((peer>>16&255)) $((peer>>8&255)) $((peer&255)) >> /tmp/mporter_peer.$$
    done < <(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}')
    [ -f /tmp/mporter_peer.$$ ] && out+="$(cat /tmp/mporter_peer.$$)\n" && rm -f /tmp/mporter_peer.$$
    printf '%b' "$out" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
}

find_free_local_port() {
    local base="$1" p="$base"
    while [ "$p" -le 65535 ]; do
        if ! ss -H -lntup 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$p$" && \
           ! grep -RqsE "(:|--dport[[:space:]])$p([[:space:]/]|$)" "$OBFS_DIR" "$H_CONF" "$G_CONF" "$R_CONF" "$IPT_CONF" 2>/dev/null; then
            echo "$p"; return 0
        fi
        p=$((p+1))
    done
    return 1
}

ensure_haproxy_v10() {
    [ -f "$H_CONF" ] || return 0
    if ! grep -q 'stats socket /run/haproxy/admin.sock' "$H_CONF" 2>/dev/null; then
        sed -i '/^global$/a\    stats socket /run/haproxy/admin.sock mode 660 level admin\n    stats timeout 5s' "$H_CONF" 2>/dev/null
    fi
    if ! grep -q '^    timeout client 1h' "$H_CONF" 2>/dev/null; then sed -i '/^defaults$/a\    timeout connect 5s\n    timeout client 1h\n    timeout server 1h' "$H_CONF" 2>/dev/null; fi
}

haproxy_test_config() {
    ensure_haproxy_v10
    haproxy -c -f "$H_CONF" >/dev/null 2>&1
}

haproxy_reload_safe() {
    ensure_haproxy_v10
    if ! haproxy_test_config; then return 1; fi
    systemctl reload haproxy >/dev/null 2>&1 || systemctl restart haproxy >/dev/null 2>&1
    systemctl is-active --quiet haproxy
}

apply_scoped_mss() {
    local iface="$1" tag="MPORTER_MSS_${iface//[^a-zA-Z0-9_]/_}"
    ip link show "$iface" >/dev/null 2>&1 || return 0
    iptables -t mangle -S OUTPUT 2>/dev/null | grep -F "$tag" | sed 's/-A /-D /' | while read -r rule; do iptables -t mangle $rule 2>/dev/null; done
    iptables -t mangle -S FORWARD 2>/dev/null | grep -F "$tag" | sed 's/-A /-D /' | while read -r rule; do iptables -t mangle $rule 2>/dev/null; done
    iptables -t mangle -A OUTPUT -o "$iface" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "$tag" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    iptables -t mangle -A FORWARD -o "$iface" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "$tag" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
}

health_probe() {
    local ip="$1" port="$2" timeout_s="${3:-2}"
    valid_ipv4 "$ip" || return 2
    timeout "$timeout_s" bash -c "</dev/tcp/$ip/$port" >/dev/null 2>&1
}

health_check_backend() {
    local iface="$1" ip="$2" port="$3" fail_limit="${4:-2}" fail=0 n=1
    while [ "$n" -le "$fail_limit" ]; do
        if health_probe "$ip" "$port" 2; then
            echo "$iface|$ip|$port|UP|$((n-1))|$(date +%s)"
            return 0
        fi
        fail=$n; n=$((n+1)); [ "$n" -le "$fail_limit" ] && sleep 0.2
    done
    if [ -z "$iface" ] || ! ip link show "$iface" >/dev/null 2>&1; then
        echo "$iface|$ip|$port|INTERFACE_REMOVED|$fail|$(date +%s)"
    else
        echo "$iface|$ip|$port|DOWN|$fail|$(date +%s)"
    fi
    return 1
}

health_scan() {
    state_reconcile >/dev/null 2>&1 || true
    : > "$HEALTH_FILE"
    [ -f "$H_CONF" ] || return 0
    local current_port=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^backend[[:space:]]bk_([0-9]+)$ ]]; then current_port="${BASH_REMATCH[1]}"; continue; fi
        if [[ "$line" =~ ^[[:space:]]+server[[:space:]]+[^[:space:]]+[[:space:]]+(([0-9]{1,3}\.){3}[0-9]{1,3}):([0-9]+) ]]; then
            local ip="${BASH_REMATCH[1]}" rp="${BASH_REMATCH[3]}" iface=""
            iface=$(ip route get "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
            health_check_backend "$iface" "$ip" "$rp" 2 >> "$HEALTH_FILE"
        fi
    done < "$H_CONF"
}

show_health_matrix() {
    draw_header
    echo -e "\n  ${DIM}┌─[ BACKEND HEALTH MATRIX ]${NC}"
    printf "  ${B}│${NC} ${W}%-18s %-16s %-7s %-18s %-6s${NC}\n" "INTERFACE" "TARGET" "PORT" "STATE" "FAILS"
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────────${NC}"
    if [ ! -s "$HEALTH_FILE" ]; then health_scan >/dev/null 2>&1; fi
    if [ -s "$HEALTH_FILE" ]; then
        while IFS='|' read -r iface ip port state fails ts; do
            case "$state" in UP) sc="$G";; DOWN) sc="$R";; INTERFACE_REMOVED) sc="$Y";; *) sc="$DIM";; esac
            printf "  ${B}│${NC} %-18s %-16s %-7s ${sc}%-18s${NC} %-6s\n" "${iface:-?}" "$ip" "$port" "$state" "$fails"
        done < "$HEALTH_FILE"
    else
        echo -e "  ${DIM}│  No HAProxy backends discovered.${NC}"
    fi
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────────${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

purge_ip_core() {
    local target_ip=$(echo "$1" | tr -dc '0-9.')
    valid_ipv4 "$target_ip" || return 1
    ensure_jq >/dev/null 2>&1 || true
    local t_ports=""
    [ -f "$H_CONF" ] && t_ports+=$(grep -E "server srv_[^ ]+ ${target_ip}:" "$H_CONF" 2>/dev/null | awk -F'[_ ]' '{print $3}' | xargs)
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then t_ports+=" "$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep "$target_ip:" | grep -oP 'tcp://:\K[0-9]+' | xargs); fi
    if [ -f "$R_CONF" ] && command -v jq >/dev/null 2>&1; then t_ports+=" "$(jq -r '.endpoints[]?' "$R_CONF" 2>/dev/null | grep "$target_ip:" | grep -oP '"listen":\s*"0.0.0.0:\K[0-9]+' | xargs); fi
    [ -f "$IPT_CONF" ] && t_ports+=" "$(grep "MPORTER_NAT_$target_ip" "$IPT_CONF" 2>/dev/null | grep PREROUTING | grep -oP -- '--dport \K[0-9]+' | xargs)
    t_ports=$(printf '%s\n' $t_ports | grep -E '^[0-9]+$' | sort -un | xargs)
    for p in $t_ports; do
        # Remove only this backend target. Preserve the LB pool if other servers remain.
        sed -i "/^[[:space:]]*server srv_${p}_[0-9][0-9]* ${target_ip}:/d; /^[[:space:]]*server srv_$p ${target_ip}:/d" "$H_CONF" 2>/dev/null
        local remaining=0
        if [ -f "$H_CONF" ]; then
            remaining=$(awk -v p="$p" 'BEGIN{inb=0} $0=="backend bk_"p {inb=1;next} inb && /^backend / {exit} inb && /^[[:space:]]+server / {c++} END{print c+0}' "$H_CONF")
        fi
        if [ "$remaining" -eq 0 ]; then
            awk -v p="$p" 'BEGIN{skip=0} $0=="frontend ft_"p {skip=1;next} $0=="backend bk_"p {skip=1;next} skip && /^(frontend|backend) / {skip=0; print; next} !skip{print}' "$H_CONF" > "$H_CONF.tmp.$$" 2>/dev/null && mv -f "$H_CONF.tmp.$$" "$H_CONF"
            rm -f "$H_CONF.tmp.$$"
        fi
        if command -v jq >/dev/null 2>&1; then
            jq --arg p "$p" '.ServeNodes=[.ServeNodes[]? | select(startswith("tcp://:"+$p+"/")|not)]' "$G_CONF" > /tmp/g.json 2>/dev/null && mv /tmp/g.json "$G_CONF" 2>/dev/null || true
            jq --arg p "0.0.0.0:$p" '.endpoints=[.endpoints[]? | select(.listen != $p)]' "$R_CONF" > /tmp/r.json 2>/dev/null && mv /tmp/r.json "$R_CONF" 2>/dev/null || true
        fi
        [ -f "$OBFS_DIR/nat.sh" ] && sed -i "/--dport $p /d" "$OBFS_DIR/nat.sh" 2>/dev/null
        [ -f "$OBFS_DIR/gost.sh" ] && sed -i "/:$p -F/d" "$OBFS_DIR/gost.sh" 2>/dev/null
        [ -f "$IPT_CONF" ] && sed -i "/--dport $p .*MPORTER_NAT_$target_ip/d" "$IPT_CONF" 2>/dev/null
    done
    [ -f "$OBFS_DIR/nat.sh" ] && sed -i "/-d $target_ip /d; /\/$target_ip:/d; /-d $target_ip -m comment --comment \"OBFS_CNT_TX_/d; /-s $target_ip -m comment --comment \"OBFS_CNT_RX_/d; /# OBFS_CNT_TX_.*_$target_ip/d" "$OBFS_DIR/nat.sh" 2>/dev/null
    state_remove_target "$target_ip" >/dev/null 2>&1 || true
}

if [[ "$1" == "--health-scan" ]]; then
    ensure_haproxy_v10
    health_scan
    exit 0
fi

if [[ "$1" == "--state-sync" ]]; then
    state_reconcile
    exit $?
fi

if [[ "$1" == "--purge-ip" && -n "$2" ]]; then
    purge_ip_core "$2"; systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart realm 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null; setup_mporter_service
    [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh
    exit 0
fi

if [[ "$1" == "--cleanup-orphans" ]]; then
    # v10 safe orphan cleanup: only remove mappings whose recorded interface is truly gone.
    state_reconcile >/dev/null 2>&1 || true
    state_sync_interface_metadata >/dev/null 2>&1 || true
    if command -v jq >/dev/null 2>&1 && [ -s "$STATE_FILE" ]; then
        mapfile -t orphan_ips < <(jq -r '.mappings[]? | select(.interface != "" and .interface != "unknown") | [.target_ip,.interface] | @tsv' "$STATE_FILE" 2>/dev/null | while IFS=$'\t' read -r ip iface; do
            if ! ip link show "$iface" >/dev/null 2>&1; then echo "$ip"; fi
        done | sort -u)
        for ip in "${orphan_ips[@]}"; do
            [ -n "$ip" ] || continue
            purge_ip_core "$ip"
        done
        haproxy_reload_safe >/dev/null 2>&1 || true
        systemctl restart gost 2>/dev/null || true
        systemctl restart realm 2>/dev/null || true
        systemctl restart mporter-iptables 2>/dev/null || true
        setup_mporter_service
        [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh
    fi
    exit 0
fi

build_iptables_runner() {
    cat <<'EOF_IPT' > /usr/local/bin/mporter-iptables.sh
#!/bin/bash
iptables -t nat -S PREROUTING 2>/dev/null | grep "MPORTER_NAT_" | sed 's/-A /-D /' | while read -r rule; do eval iptables -t nat $rule 2>/dev/null; done
iptables -t nat -S POSTROUTING 2>/dev/null | grep "MPORTER_NAT_" | sed 's/-A /-D /' | while read -r rule; do eval iptables -t nat $rule 2>/dev/null; done
[ -f /etc/mporter/iptables_core/rules.sh ] && source /etc/mporter/iptables_core/rules.sh 2>/dev/null
EOF_IPT
    chmod +x /usr/local/bin/mporter-iptables.sh
    cat <<'EOF_SRV_IPT' > /etc/systemd/system/mporter-iptables.service
[Unit]
Description=MPorter Kernel NAT Engine
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/mporter-iptables.sh
[Install]
WantedBy=multi-user.target
EOF_SRV_IPT
    systemctl daemon-reload; systemctl enable mporter-iptables >/dev/null 2>&1; systemctl restart mporter-iptables >/dev/null 2>&1
    setup_mporter_service
}

build_obfs_runner() {
    cat <<'EOF_OBFS' > /usr/local/bin/mporter-obfs.sh
#!/bin/bash
iptables -t nat -S OUTPUT 2>/dev/null | grep "MPORTER_OBFS" | sed 's/-A /-D /' | while read -r rule; do iptables -t nat $rule; done
iptables -t mangle -S OUTPUT 2>/dev/null | grep "OBFS_CNT_TX_" | sed 's/-A /-D /' | while read -r rule; do iptables -t mangle $rule; done
iptables -t mangle -S INPUT 2>/dev/null | grep "OBFS_CNT_RX_" | sed 's/-A /-D /' | while read -r rule; do iptables -t mangle $rule; done

# v10 intentionally does NOT install global TCPMSS rules.
# MPorter traffic is scoped to tunnel interfaces in the generated core rules when needed.
[ -f /etc/mporter/obfs_rules/nat.sh ] && source /etc/mporter/obfs_rules/nat.sh 2>/dev/null
[ -f /etc/mporter/obfs_rules/gost.sh ] && source /etc/mporter/obfs_rules/gost.sh 2>/dev/null

if [ -n "$(jobs -p)" ]; then wait; else sleep infinity; fi
EOF_OBFS
    chmod +x /usr/local/bin/mporter-obfs.sh
    cat <<'EOF_SRV' > /etc/systemd/system/mporter-obfs.service
[Unit]
Description=MPorter OBFS Stealth Engine
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mporter-obfs.sh
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF_SRV
    systemctl daemon-reload; systemctl enable mporter-obfs >/dev/null 2>&1; systemctl restart mporter-obfs >/dev/null 2>&1
    setup_mporter_service
}

download_gost_binary() {
    local target_bin="/usr/local/bin/gost"
    if [ -s "$target_bin" ] && "$target_bin" -V >/dev/null 2>&1; then return 0; fi
    local mirrors=("https://c107328.parspack.net/c107328/MTunnel/gost-linux-amd64-2.11.5.gz" "https://ghproxy.net/https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz")
    local gz_tmp="/tmp/gost_dl.$$.gz"; local raw_tmp="/tmp/gost_dl.$$"
    
    for url in "${mirrors[@]}"; do
        if command -v curl >/dev/null 2>&1; then curl -fkSL --connect-timeout 5 --max-time 25 -o "$gz_tmp" "$url" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then wget -q --no-check-certificate --timeout=15 --tries=1 -O "$gz_tmp" "$url" 2>/dev/null; fi
        if [ -s "$gz_tmp" ] && gzip -t "$gz_tmp" >/dev/null 2>&1; then
            gzip -df "$gz_tmp" -c > "$raw_tmp" 2>/dev/null
            if [ -s "$raw_tmp" ]; then mv "$raw_tmp" "$target_bin"; chmod +x "$target_bin"; rm -f "$gz_tmp" "$raw_tmp"; return 0; fi
        fi
        rm -f "$gz_tmp" "$raw_tmp"
    done; return 1
}

download_realm_binary() {
    local target_bin="/usr/local/bin/realm"
    if [ -s "$target_bin" ] && "$target_bin" --version >/dev/null 2>&1; then return 0; fi
    local url="https://c107328.parspack.net/c107328/MTunnel/realm.tar.gz"
    local dl_tmp="/tmp/realm_dl.tar.gz"
    if command -v curl >/dev/null 2>&1; then curl -fkSL --connect-timeout 5 --max-time 25 -o "$dl_tmp" "$url" 2>/dev/null
    else wget -qO "$dl_tmp" "$url" 2>/dev/null; fi
    if [ -s "$dl_tmp" ]; then tar -xzf "$dl_tmp" -C /tmp/ 2>/dev/null; mv /tmp/realm "$target_bin" 2>/dev/null; chmod +x "$target_bin"; rm -f "$dl_tmp"; return 0; fi
    return 1
}

install_core_engines() {
    clear; echo -e "\n  ${DIM}┌─[ ENGINE SELECTION (Select Cores to Install) ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy Engine Only${NC} ${DIM}(Load Balancer / Stable)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost Engine Only${NC} ${DIM}(TLS/WS Obfuscator)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Realm Engine Only${NC} ${DIM}(High-Performance / Rust)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Iptables NAT Engine Only${NC} ${DIM}(Raw Speed)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Install ALL Engines (Quad-Core)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    
    echo -ne "  ${C}Select Option ❯❯ ${NC}"; read eng_opt
    if [[ ! "$eng_opt" =~ ^[1-5]$ ]]; then return; fi
    
    echo -e "\n  ${DIM}┌─[ INITIALIZING INSTALLATION ]${NC}"
    (
        sysctl -w fs.file-max=2000000 >/dev/null 2>&1
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
        
        sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf 2>/dev/null; echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null; echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null; echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        
        rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock* /var/cache/apt/archives/lock >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold >/dev/null 2>&1 || true
        
        timeout 25 apt-get update -o Acquire::ForceIPv4=true -y -q >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive timeout 35 apt-get install -o Acquire::ForceIPv4=true -y -q jq libjq1 libonig5 curl wget gzip iptables tar >/dev/null 2>&1 || true
    ) &
    draw_progress_bar $! "Resolving Dependencies" 90

    if [[ "$eng_opt" == "5" || "$eng_opt" == "1" ]]; then
        (
            mkdir -p /etc/haproxy /var/lib/haproxy /usr/sbin /usr/local/sbin 2>/dev/null
            touch /var/lib/haproxy/stats 2>/dev/null
            DEBIAN_FRONTEND=noninteractive timeout 40 apt-get install -o Acquire::ForceIPv4=true -y haproxy >/dev/null 2>&1 || true
            if [ ! -s "$H_CONF" ]; then
                cat <<'EOF_HAP' > "$H_CONF"
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
            systemctl daemon-reload >/dev/null 2>&1; systemctl enable haproxy >/dev/null 2>&1; systemctl restart haproxy >/dev/null 2>&1 || true
        ) &
        draw_progress_bar $! "Deploying HAProxy Engine" 70
    fi

    if [[ "$eng_opt" == "5" || "$eng_opt" == "2" ]]; then
        (
            download_gost_binary; mkdir -p /etc/gost 2>/dev/null
            if [ ! -f "$G_CONF" ] || ! jq . "$G_CONF" >/dev/null 2>&1; then echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"; fi
            cat <<EOF_GST > /etc/systemd/system/gost.service
[Unit]
Description=GO Simple Tunnel (MPorter Core)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C /etc/gost/config.json
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF_GST
            systemctl daemon-reload >/dev/null 2>&1; systemctl enable gost >/dev/null 2>&1; systemctl restart gost >/dev/null 2>&1 || true
        ) &
        draw_progress_bar $! "Deploying Gost Engine" 100
    fi

    if [[ "$eng_opt" == "5" || "$eng_opt" == "3" ]]; then
        (
            download_realm_binary; mkdir -p /etc/realm 2>/dev/null
            if [ ! -f "$R_CONF" ] || ! jq . "$R_CONF" >/dev/null 2>&1; then echo '{"network": {"no_tcp_delay": true}, "endpoints": []}' > "$R_CONF"; fi
            cat <<EOF_RLM > /etc/systemd/system/realm.service
[Unit]
Description=Realm High-Performance Port Forwarder
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.json
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF_RLM
            systemctl daemon-reload >/dev/null 2>&1; systemctl enable realm >/dev/null 2>&1; systemctl restart realm >/dev/null 2>&1 || true
        ) &
        draw_progress_bar $! "Deploying Realm Engine" 80
    fi

    if [[ "$eng_opt" == "5" || "$eng_opt" == "4" ]]; then
        (
            mkdir -p "$IPT_DIR" 2>/dev/null; touch "$IPT_CONF" 2>/dev/null; chmod +x "$IPT_CONF" 2>/dev/null
            build_iptables_runner
        ) &
        draw_progress_bar $! "Deploying Kernel NAT Engine" 25
    fi

    setup_mporter_service
    echo -e "  ${DIM}└──────────────────────────────────────────────────────────┘${NC}\n"; sleep 1
}

get_iface_info() {
    local target_ip=$1
    local iface=$(ip route get "$target_ip" 2>/dev/null | head -n 1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    if [ -z "$iface" ] || [ "$iface" == "lo" ]; then
        local subnet=$(echo "$target_ip" | cut -d'.' -f1-3)
        local check_iface=$(ip -o -4 addr show 2>/dev/null | grep -w "${subnet}\." | awk '{print $2}' | head -n 1)
        [ -n "$check_iface" ] && iface="$check_iface"
    fi

    local t_type="System"; local t_name="$iface"
    if [[ "$iface" == greir* ]]; then t_type="GRE"; t_name="${iface#greir}"
    elif [[ "$iface" == grekh* ]]; then t_type="GRE"; t_name="${iface#grekh}"
    elif [[ "$iface" == vx_* || "$iface" == br_* ]]; then t_type="VXLAN"; t_name="${iface#vx_}"; t_name="${t_name#br_}"
    elif [[ "$iface" == bh_* ]]; then t_type="BACKHAUL"; t_name="${iface#bh_}"
    elif [[ "$iface" == rh_* || "$iface" == rt_* ]]; then t_type="RATHOLE"; t_name="${iface#rh_}"; t_name="${t_name#rt_}"
    elif [[ "$iface" == l2tp_* ]]; then t_type="L2TP"; t_name="${iface#l2tp_}"
    elif [[ "$iface" == hys_* ]]; then t_type="HYSTERIA"; t_name="${iface#hys_}"
    elif [ "$target_ip" == "127.0.0.1" ]; then t_type="Local"; t_name="Loopback"
    else [ -z "$t_name" ] && t_name="Unknown"; fi

    echo "${t_type}|${t_name}"
}

format_engine() {
    local raw="$1"; local e_list=()
    [[ "$raw" == *"HAP"* ]] && e_list+=("${C}HAProxy${NC}")
    [[ "$raw" == *"GST"* ]] && e_list+=("${M}Gost${NC}")
    [[ "$raw" == *"RLM"* ]] && e_list+=("${G}Realm${NC}")
    [[ "$raw" == *"IPT"* ]] && e_list+=("${Y}KernelNAT${NC}")
    [[ "$raw" == *"TUN"* ]] && e_list+=("${B}CoreNAT${NC}")
    
    local res=""
    for ((i=0; i<${#e_list[@]}; i++)); do
        res+="${e_list[$i]}"; [ $i -lt $(( ${#e_list[@]} - 1 )) ] && res+=" ${DIM}/${NC} "
    done
    echo "$res"
}

get_stats() {
    local server_ip=$(get_local_ip)
    local hap_stat; local raw_hap; local gst_stat; local raw_gst; local rlm_stat; local raw_rlm; local ipt_stat; local raw_ipt
    if systemctl is-active --quiet haproxy; then hap_stat="${C}●${NC}"; raw_hap="●"; else hap_stat="${DIM}○${NC}"; raw_hap="○"; fi
    if systemctl is-active --quiet gost; then gst_stat="${M}●${NC}"; raw_gst="●"; else gst_stat="${DIM}○${NC}"; raw_gst="○"; fi
    if systemctl is-active --quiet realm; then rlm_stat="${G}●${NC}"; raw_rlm="●"; else rlm_stat="${DIM}○${NC}"; raw_rlm="○"; fi
    if systemctl is-active --quiet mporter-iptables; then ipt_stat="${Y}●${NC}"; raw_ipt="●"; else ipt_stat="${DIM}○${NC}"; raw_ipt="○"; fi
    
    local h_ports=0; local g_ports=0; local r_ports=0; local ipt_ports=0; local ext_ports_count=0
    [ -f "$H_CONF" ] && h_ports=$(grep -c -w "frontend" "$H_CONF" 2>/dev/null); ((h_ports--)); [ "$h_ports" -lt 0 ] && h_ports=0
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then g_ports=$(jq '.ServeNodes | length' "$G_CONF" 2>/dev/null); [ -z "$g_ports" ] && g_ports=0; fi
    if [ -f "$R_CONF" ] && command -v jq >/dev/null 2>&1; then r_ports=$(jq '.endpoints | length' "$R_CONF" 2>/dev/null); [ -z "$r_ports" ] && r_ports=0; fi
    [ -f "$IPT_CONF" ] && ipt_ports=$(grep -c "PREROUTING" "$IPT_CONF" 2>/dev/null)
    
    local h_ips=""; local g_ips=""; local r_ips=""; local ipt_ips=""; local ext_ips=""
    [ -f "$H_CONF" ] && h_ips=$(grep -oP 'server srv_[0-9_]+ \K[0-9\.]+|server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null)
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then g_ips=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1); fi
    if [ -f "$R_CONF" ] && command -v jq >/dev/null 2>&1; then r_ips=$(jq -r '.endpoints[].remote?' "$R_CONF" 2>/dev/null | cut -d: -f1 | sort -u); fi
    [ -f "$IPT_CONF" ] && ipt_ips=$(grep -oP -- 'MPORTER_NAT_\K[0-9\.]+' "$IPT_CONF" 2>/dev/null | sort -u)

    shopt -s nullglob
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf; do
        [ -f "$conf" ] || continue
        local TYPE="" FWD_TCP="" FWD_UDP="" CORE_SUBNET="" TUN_ID="" VNI_ID=""
        source "$conf" 2>/dev/null; [ "$TYPE" != "1" ] && continue
        local t_ip=""
        if [ -n "$TUN_ID" ]; then t_ip="${CORE_SUBNET:-10.76.${TUN_ID}}.2"
        elif [ -n "$VNI_ID" ]; then t_ip="${CORE_SUBNET:-10.88.${VNI_ID}}.2"; fi
        local count=$(echo "$FWD_TCP,$FWD_UDP" | tr ',' '\n' | grep -v '^$' | sort -u | wc -l)
        if [ "$count" -gt 0 ]; then ext_ports_count=$((ext_ports_count + count)); ext_ips+="$t_ip\n"; fi
    done
    shopt -u nullglob

    local total_ports=$((h_ports + g_ports + r_ports + ipt_ports + ext_ports_count))
    local all_ips=$(echo -e "$h_ips\n$g_ips\n$r_ips\n$ipt_ips\n$ext_ips" | grep -v '^$' | sort -u)
    local mapped_ips=$(echo "$all_ips" | grep -v '^$' | wc -l)
    local ip_status="${DIM}NONE${NC}"; local raw_ip="NONE"
    if [ "$mapped_ips" -gt 0 ]; then ip_status="${G}${mapped_ips} ACTIVE${NC}"; raw_ip="${mapped_ips} ACTIVE"; fi

    export STATS_SERVER_IP="$server_ip" STATS_TOTAL_PORTS="$total_ports" STATS_RAW_HAP="$raw_hap" STATS_RAW_RLM="$raw_rlm" STATS_RAW_GST="$raw_gst" STATS_RAW_IPT="$raw_ipt" STATS_RAW_IP="$raw_ip" STATS_HAP_STAT="$hap_stat" STATS_RLM_STAT="$rlm_stat" STATS_GST_STAT="$gst_stat" STATS_IPT_STAT="$ipt_stat" STATS_IP_STATUS="$ip_status"
}

draw_header() {
    get_stats; clear; echo ""
    local raw_text=" MPorter v${MODULE_VERSION} │ IP: ${STATS_SERVER_IP} │ HAP:${STATS_RAW_HAP} RLM:${STATS_RAW_RLM} GST:${STATS_RAW_GST} IPT:${STATS_RAW_IPT} │ IPs: ${STATS_RAW_IP} │ Pts: ${STATS_TOTAL_PORTS} "
    local pad_len=$(( 106 - ${#raw_text} )); if (( pad_len < 0 )); then pad_len=0; fi
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MPorter v${MODULE_VERSION}${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${STATS_SERVER_IP}${NC} ${B}│${NC} ${DIM}HAP:${NC} ${STATS_HAP_STAT} ${DIM}RLM:${NC} ${STATS_RLM_STAT} ${DIM}GST:${NC} ${STATS_GST_STAT} ${DIM}IPT:${NC} ${STATS_IPT_STAT} ${B}│${NC} ${DIM}IPs:${NC} ${STATS_IP_STATUS} ${B}│${NC} ${DIM}Pts:${NC} ${G}${STATS_TOTAL_PORTS}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}├──────────────┬──────────┬────────────────────────────┬──────────────────────┬────────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-8s${NC} ${B}│${NC} ${W}%-26s${NC} ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} ${W}%-26s${NC} ${B}│${NC}\n" "TUNNEL NAME" "TYPE" "TARGET NETWORK IPs" "ENGINES" "DISTRIBUTION"
    echo -e "  ${B}├──────────────┬──────────┼────────────────────────────┼──────────────────────┬────────────────────────────┤${NC}"
    
    local h_map=""; local g_map=""; local r_map=""; local ipt_map=""; local ext_map_raw=""
    [ -f "$H_CONF" ] && h_map=$(grep -E 'server srv_[0-9_]+ [0-9\.]+|server srv_[0-9]+ [0-9\.]+' "$H_CONF" 2>/dev/null | awk '{print $3}' | cut -d: -f1 | sort | uniq -c | awk '{print $2 "|" $1 "|HAP"}')
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1 | sort | uniq -c | awk '{print $2 "|" $1 "|GST"}'); fi
    if [ -f "$R_CONF" ] && command -v jq >/dev/null 2>&1; then r_map=$(jq -r '.endpoints[]?' "$R_CONF" 2>/dev/null | grep -oP '"remote":\s*"\K[0-9\.]+' | sort | uniq -c | awk '{print $2 "|" $1 "|RLM"}'); fi
    [ -f "$IPT_CONF" ] && ipt_map=$(grep "PREROUTING" "$IPT_CONF" 2>/dev/null | grep -oP -- 'MPORTER_NAT_\K[0-9\.]+' | sort | uniq -c | awk '{print $2 "|" $1 "|IPT"}')

    shopt -s nullglob
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf; do
        [ -f "$conf" ] || continue
        local TYPE="" FWD_TCP="" FWD_UDP="" CORE_SUBNET="" TUN_ID="" VNI_ID=""
        source "$conf" 2>/dev/null; [ "$TYPE" != "1" ] && continue
        local t_ip=""
        if [ -n "$TUN_ID" ]; then t_ip="${CORE_SUBNET:-10.76.${TUN_ID}}.2"
        elif [ -n "$VNI_ID" ]; then t_ip="${CORE_SUBNET:-10.88.${VNI_ID}}.2"; fi
        local count=$(echo "$FWD_TCP,$FWD_UDP" | tr ',' '\n' | grep -v '^$' | sort -u | wc -l)
        if [ "$count" -gt 0 ]; then ext_map_raw+="${t_ip}|${count}|TUN\n"; fi
    done
    shopt -u nullglob

    local ip_port_counts=$(echo -e "$h_map\n$g_map\n$r_map\n$ipt_map\n$ext_map_raw" | grep -v '^$' | awk -F'|' '{
        a[$1]+=$2; if(eng[$1] == "") eng[$1]=$3; else if(index(eng[$1], $3) == 0) eng[$1]=eng[$1] "/" $3
    } END {for (i in a) print i"|"a[i]"|"eng[i]}')

    if [ -z "$ip_port_counts" ] || [ "$ip_port_counts" == "|" ]; then
        printf "  ${B}│${NC} ${DIM}%-104s${NC} ${B}│${NC}\n" "  No active mappings. Ready to route strictly."
    else
        declare -A iface_ips_arr; declare -A iface_ports_arr; declare -A iface_eng_arr
        while IFS='|' read -r ip count engs; do
            if [ -n "$ip" ]; then
                local iface_info=$(get_iface_info "$ip")
                iface_ips_arr["$iface_info"]+="$ip "; iface_ports_arr["$iface_info"]=$(( iface_ports_arr["$iface_info"] + count ))
                IFS='/' read -ra eng_list <<< "$engs"
                for e in "${eng_list[@]}"; do
                    if [[ ! "${iface_eng_arr["$iface_info"]}" == *"$e"* ]]; then iface_eng_arr["$iface_info"]+="$e/"; fi
                done
            fi
        done <<< "$ip_port_counts"
        
        for iface_info in $(for i in "${!iface_ips_arr[@]}"; do echo "$i"; done | sort); do
            local t_type="${iface_info%%|*}"; local t_name="${iface_info##*|}"; local clean_name="${t_name}"
            [ ${#clean_name} -gt 12 ] && clean_name="${clean_name:0:9}..."
            local ips=(${iface_ips_arr["$iface_info"]}); local total_p=${iface_ports_arr["$iface_info"]}
            
            local display_ips="${ips[0]}"
            if [ ${#ips[@]} -gt 2 ]; then display_ips="${ips[0]}, ${ips[1]}, ..."
            elif [ ${#ips[@]} -eq 2 ]; then display_ips="${ips[0]}, ${ips[1]}"; fi
            [ ${#display_ips} -gt 26 ] && display_ips="${display_ips:0:23}..."
            
            local raw_eng="${iface_eng_arr["$iface_info"]}"; local disp_eng=$(format_engine "$raw_eng")
            local clean_eng=$(echo -e "$disp_eng" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            local pad_eng=$(printf '%*s' "$(( 20 - ${#clean_eng} ))" "")
            
            local obfs_indicator=""
            if grep -q "\-d ${ips[0]} " "$OBFS_DIR/nat.sh" 2>/dev/null; then obfs_indicator="${M}[OBFS]${NC}"; fi
            local fwd_dist="${Y}${total_p} Ports${NC} ${obfs_indicator}"
            local clean_fwd=$(echo -e "$fwd_dist" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            local pad=$(printf '%*s' "$(( 26 - ${#clean_fwd} ))" "")
            
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-8s${NC} ${B}│${NC} ${G}%-26s${NC} ${B}│${NC} %b%s ${B}│${NC} %b%s ${B}│${NC}\n" "$clean_name" "$t_type" "$display_ips" "$disp_eng" "$pad_eng" "$fwd_dist" "$pad"
        done
    fi
    echo -e "  ${B}╰──────────────┴──────────┴────────────────────────────┴──────────────────────┴────────────────────────────╯${NC}"
}

smart_map() {
    draw_header
    echo -e "\n  ${DIM}┌─[ STRICT FORWARDING ENGINE (1-to-1) ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC} ${DIM}(Load Balancer / Stable)${NC}"
    echo -e "  ${DIM}│${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC} ${DIM}(TLS/WS Obfuscator)${NC}"
    echo -e "  ${DIM}│${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Realm${NC} ${DIM}(High-Performance / Rust)${NC}"
    echo -e "  ${DIM}│${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Iptables Kernel NAT${NC} ${DIM}(Raw Speed / 0% CPU)${NC}"
    echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read fwd_engine
    fwd_engine=$(echo "$fwd_engine" | tr -dc '1-4')
    if [ -z "$fwd_engine" ]; then echo -e "  ${R}● Invalid engine!${NC}"; sleep 1; return; fi
    if [ "$fwd_engine" == "2" ] || [ "$fwd_engine" == "3" ]; then
        if ! ensure_jq; then echo -e "  ${R}● Engine requires 'jq'. Run Installer first.${NC}"; sleep 2; return; fi
    fi

    local active_ifs=()
    shopt -s nullglob
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf /etc/ml2tp/tunnels/*.conf /etc/mhysteria/tunnels/*.conf; do 
        [ -f "$conf" ] && active_ifs+=($(grep -E "^T_NAME=|^BR_NAME=" "$conf" | cut -d= -f2 | tr -d '"' | tr -d "'"))
    done
    shopt -u nullglob

    local gre_ifs=()
    for iface in "${active_ifs[@]}"; do if ip link show "$iface" >/dev/null 2>&1; then gre_ifs+=("$iface"); fi; done

    local target_ip=""; local selected_if=""; local is_auto_all=false; local selected_ips=(); local auto_peers=()

    if [ ${#gre_ifs[@]} -eq 0 ]; then
        echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read target_ip
        target_ip=$(echo "$target_ip" | tr -dc '0-9.')
        if [[ ! "$target_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; return; fi
        selected_if="Manual"
    else
        echo -e "\n  ${B}╭────────────────── Available Interfaces ────────────────────╮${NC}"
        for i in "${!gre_ifs[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-52s${NC} ${B}│${NC}\n" "$i" "${gre_ifs[$i]}"; done
        echo -e "  ${B}├──────────────────────────────────────────────────────────────┤${NC}"
        printf "  ${B}│${NC}  ${Y}m${NC} ${C}❯${NC} ${M}%-52s${NC} ${B}│${NC}\n" "Manual IP Entry (Bypass Interfaces)"
        echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
        echo -ne "  ${C}●${NC} ${W}Select Interface (0-$(( ${#gre_ifs[@]} - 1 )) or 'm'): ${NC}"; read if_choice
        if_choice=$(echo "$if_choice" | tr -dc '0-9m')
        
        if [[ "$if_choice" == "m" ]]; then
            echo -ne "\n  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read target_ip
            target_ip=$(echo "$target_ip" | tr -dc '0-9.'); selected_if="Manual"
        elif [[ "$if_choice" =~ ^[0-9]+$ ]] && [[ -n "${gre_ifs[$if_choice]}" ]]; then 
            selected_if="${gre_ifs[$if_choice]}"
            local map_ips=($(ip -o -4 addr show "$selected_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1))
            if [ ${#map_ips[@]} -eq 0 ]; then
                echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read target_ip
                target_ip=$(echo "$target_ip" | tr -dc '0-9.')
            else
                echo -e "\n  ${B}╭────────────────── IPs on ${selected_if} ──────────────────╮${NC}"
                for i in "${!map_ips[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${G}%-50s${NC} ${B}│${NC}\n" "$i" "${map_ips[$i]}"; done
                echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
                echo -ne "  ${C}●${NC} ${W}Select EXACT Index (0-$(( ${#map_ips[@]} - 1 ))) or 'a' for Auto-Distribute: ${NC}"; read ip_choice
                ip_choice=$(echo "$ip_choice" | tr -dc '0-9a')
                if [[ "$ip_choice" == "a" ]]; then
                    selected_ips=("${map_ips[@]}"); is_auto_all=true
                    mapfile -t auto_peers < <(discover_peer_ips "$selected_if")
                    if [ ${#auto_peers[@]} -eq 0 ]; then echo -e "  ${R}● No peers discovered for auto-distribution.${NC}"; sleep 1.5; return; fi
                elif [[ "$ip_choice" =~ ^[0-9]+$ ]] && [[ -n "${map_ips[$ip_choice]}" ]]; then 
                    local calc_target="$(discover_peer_ips "$selected_if" | head -n1)"
                    if [ -z "$calc_target" ]; then echo -e "  ${R}● Could not safely discover the tunnel peer.${NC}"; sleep 1.5; return; fi
                    echo -ne "\n  ${C}●${NC} ${W}Confirm Target IP [${calc_target}]: ${NC}"; read custom_target
                    target_ip="${custom_target:-$calc_target}"
                else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            fi
        else return; fi
    fi

    echo -ne "\n  ${C}●${NC} ${W}Enter Exact Local Ports (e.g. 80,443): ${NC}"; read raw_ports
    raw_ports=$(echo "$raw_ports" | tr -dc '0-9,'); clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
    echo -e "\n  ${Y}● Applying Strict 1-to-1 Mappings...${NC}"
    echo -e "  ${B}╭──────────────┬─────────┬────────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "Local Port" "Engine" "Target IP"
    echo -e "  ${B}├──────────────┼─────────┼────────────────────────────────────────────┤${NC}"
    
    local port_idx=0
    for p in $clean_ports; do
        if [ "$p" -gt 65535 ]; then continue; fi
        if [ "$is_auto_all" = true ]; then
            local sl_ip="${selected_ips[$((port_idx % ${#selected_ips[@]}))]}"
            target_ip="$(discover_peer_ips "$selected_if" | head -n1)"
            [ -z "$target_ip" ] && { echo -e "  ${R}● Peer discovery failed for $sl_ip.${NC}"; continue; }
        fi

        local skip_reason=""
        if ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE ":$p$"; then skip_reason="OS/System"
        elif grep -q -w "frontend ft_$p" "$H_CONF" 2>/dev/null; then skip_reason="HAProxy"
        elif command -v jq >/dev/null 2>&1 && jq -e ".ServeNodes[] | select(. | contains(\"tcp://:$p/\"))" "$G_CONF" >/dev/null 2>&1; then skip_reason="Gost"
        elif command -v jq >/dev/null 2>&1 && jq -e ".endpoints[] | select(.listen == \"0.0.0.0:$p\")" "$R_CONF" >/dev/null 2>&1; then skip_reason="Realm"
        elif grep -q -- "--dport $p " "$IPT_CONF" 2>/dev/null; then skip_reason="KernelNAT"; fi

        if [ -n "$skip_reason" ]; then printf "  ${B}│${NC} ${R}%-12s${NC} ${B}│${NC} ${DIM}%-7s${NC} ${B}│${NC} ${DIM}%-42s${NC} ${B}│${NC}\n" "$p" "-" "Skipped ($skip_reason)"; continue; fi
        
        if [ "$fwd_engine" == "1" ]; then
            (flock -x 200; echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF") 200>/var/lock/mporter_haproxy.lock
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${C}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "HAProxy" "$target_ip"
        elif [ "$fwd_engine" == "2" ]; then
            jq --arg node "tcp://:$p/$target_ip:$p" '.ServeNodes += [$node]' "$G_CONF" > /tmp/g.json 2>/dev/null && mv /tmp/g.json "$G_CONF" 2>/dev/null
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${M}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "Gost" "$target_ip"
        elif [ "$fwd_engine" == "3" ]; then
            jq --arg lp "0.0.0.0:$p" --arg rp "$target_ip:$p" '.endpoints += [{"listen": $lp, "remote": $rp}]' "$R_CONF" > /tmp/r.json 2>/dev/null && mv /tmp/r.json "$R_CONF" 2>/dev/null
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${G}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "Realm" "$target_ip"
        elif [ "$fwd_engine" == "4" ]; then
            echo "iptables -t nat -A PREROUTING -p tcp --dport $p -m comment --comment \"MPORTER_NAT_$target_ip\" -j DNAT --to-destination $target_ip:$p" >> "$IPT_CONF"
            echo "iptables -t nat -A POSTROUTING -d $target_ip -p tcp --dport $p -m comment --comment \"MPORTER_NAT_$target_ip\" -j MASQUERADE" >> "$IPT_CONF"
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${Y}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "Iptable" "$target_ip"
        fi
        ((port_idx++))
    done
    echo -e "  ${B}╰──────────────┴─────────┴────────────────────────────────────────────╯${NC}"
    
    sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
    [ "$fwd_engine" == "1" ] && systemctl restart haproxy 2>/dev/null
    [ "$fwd_engine" == "2" ] && systemctl restart gost 2>/dev/null
    [ "$fwd_engine" == "3" ] && systemctl restart realm 2>/dev/null
    [ "$fwd_engine" == "4" ] && systemctl restart mporter-iptables 2>/dev/null
    setup_mporter_service

    if [ "$fwd_engine" == "1" ] || [ "$fwd_engine" == "4" ]; then
        echo -ne "\n  ${C}●${NC} ${W}Enable Strict OBFS Stealth for these ports? (y/n): ${NC}"; read enable_obfs
        if [[ "${enable_obfs,,}" == "y" ]]; then
            local remote_pub=""
            if [[ "$selected_if" != "Manual" ]]; then
                for c in /etc/mgre/tunnels/ /etc/mgre/vxlan/ /etc/ml2tp/tunnels/ /etc/mhysteria/tunnels/; do
                    [ -f "$c${selected_if}.conf" ] && remote_pub=$(grep "REMOTE_PUB=" "$c${selected_if}.conf" | cut -d= -f2)
                done
            fi
            
            if [ -z "$remote_pub" ]; then 
                echo -ne "  ${C}●${NC} ${W}Enter Kharej Server PUBLIC IP: ${NC}"; read remote_pub
            else echo -e "  ${G}✔ Auto-detected Kharej IP: ${remote_pub}${NC}"; fi
            
            echo -ne "  ${C}●${NC} ${W}Enter Kharej Stealth Port (Target Receiver): ${NC}"; read stealth_port
            echo -ne "  ${C}●${NC} ${W}Select Protocol [1: mTLS | 2: mWS | 3: mWSS] (Default 1): ${NC}"; read t_proto
            local method="relay+mtls"; [ "$t_proto" == "2" ] && method="relay+mws"; [ "$t_proto" == "3" ] && method="relay+mwss"

            mkdir -p "$OBFS_DIR"
            local port_idx=0
            for p in $clean_ports; do
                if [ "$p" -gt 65535 ]; then continue; fi
                if [ "$is_auto_all" = true ]; then
                    local sl_ip="${selected_ips[$((port_idx % ${#selected_ips[@]}))]}"
                    target_ip="${auto_peers[$((port_idx % ${#auto_peers[@]}))]}"
                    [ -z "$target_ip" ] && { echo -e "  ${R}● Peer discovery failed for $sl_ip.${NC}"; continue; }
                fi

                local obfs_lport="$(find_free_local_port "$((30000 + p))")"
                if [ -z "$obfs_lport" ]; then echo -e "  ${R}● No free OBFS local port for $p; skipping OBFS.${NC}"; continue; fi
                echo "iptables -t nat -A OUTPUT -d $target_ip -p tcp --dport $p -m comment --comment \"MPORTER_OBFS_${obfs_lport}\" -j REDIRECT --to-ports $obfs_lport" >> "$OBFS_DIR/nat.sh"
                echo "/usr/local/bin/gost -L tcp://:$obfs_lport/$target_ip:$p -F $method://$remote_pub:$stealth_port &" >> "$OBFS_DIR/gost.sh"
                if ! grep -q "OBFS_CNT_TX_${selected_if}_${target_ip}" "$OBFS_DIR/nat.sh" 2>/dev/null; then
                    echo "iptables -t mangle -A OUTPUT -d $target_ip -m comment --comment \"OBFS_CNT_TX_${selected_if}\" 2>/dev/null" >> "$OBFS_DIR/nat.sh"
                    echo "iptables -t mangle -A INPUT -s $target_ip -m comment --comment \"OBFS_CNT_RX_${selected_if}\" 2>/dev/null" >> "$OBFS_DIR/nat.sh"
                    echo "# OBFS_CNT_TX_${selected_if}_${target_ip}" >> "$OBFS_DIR/nat.sh"
                fi
                ((port_idx++))
            done
            build_obfs_runner; echo -e "\n  ${G}● OBFS Stealth Layer configured dynamically!${NC}"
        fi
    fi
    state_reconcile >/dev/null 2>&1 || true
    state_sync_interface_metadata >/dev/null 2>&1 || true
    [ "$selected_if" != "Manual" ] && apply_scoped_mss "$selected_if"
    echo -ne "\n  ${G}● Success! Press Enter...${NC}"; read dummy
}

smart_loadbalance() {
    draw_header
    echo -e "\n  ${DIM}┌─[ SMART LOADBALANCE v10 ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}Architecture:${NC} ${C}HAProxy L4${NC} ${DIM}+${NC} ${G}central state${NC} ${DIM}+${NC} ${M}health monitor${NC}"
    echo -e "  ${DIM}│${NC} ${DIM}Backend DOWN never deletes the mapping. Interface removal is tracked separately.${NC}\n"

    echo -ne "  ${C}●${NC} ${W}Ports (e.g. 443,8443): ${NC}"; read raw_ports
    raw_ports=$(echo "$raw_ports" | tr -dc '0-9,')
    local clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 2>/dev/null | awk '$1>=1&&$1<=65535' | sort -un | xargs)
    [ -n "$clean_ports" ] || { echo -e "  ${R}● Invalid port list.${NC}"; sleep 1.5; return; }

    local active_ifs=() conf iface
    shopt -s nullglob
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf /etc/ml2tp/tunnels/*.conf /etc/mhysteria/tunnels/*.conf; do
        [ -f "$conf" ] || continue
        iface=$(grep -m1 -E '^T_NAME=|^BR_NAME=' "$conf" | cut -d= -f2- | tr -d '"' | tr -d "'")
        [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1 && active_ifs+=("$iface")
    done
    shopt -u nullglob
    mapfile -t active_ifs < <(printf '%s\n' "${active_ifs[@]}" | awk 'NF&&!seen[$0]++')
    [ ${#active_ifs[@]} -gt 0 ] || { echo -e "  ${R}● No active MDesign interfaces found.${NC}"; sleep 2; return; }

    echo -e "  ${B}╭──────────────────── Interfaces ─────────────────────╮${NC}"
    local i
    for i in "${!active_ifs[@]}"; do printf "  ${B}│${NC} ${Y}%2d${NC} ${C}❯${NC} %-49s ${B}│${NC}\n" "$i" "${active_ifs[$i]}"; done
    echo -e "  ${B}╰──────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}Select Interface ❯❯ ${NC}"; read i
    [[ "$i" =~ ^[0-9]+$ ]] && [ -n "${active_ifs[$i]}" ] || { echo -e "  ${R}● Invalid selection.${NC}"; sleep 1.5; return; }
    local selected_if="${active_ifs[$i]}"

    mapfile -t local_ips < <(ip -o -4 addr show dev "$selected_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.')
    [ ${#local_ips[@]} -gt 0 ] || { echo -e "  ${R}● No IPv4 addresses found on $selected_if.${NC}"; sleep 1.5; return; }

    echo -e "\n  ${C}⟳${NC} ${W}Discovering peer addresses from tunnel metadata / neighbour cache...${NC}"
    mapfile -t peer_ips < <(discover_peer_ips "$selected_if")
    if [ ${#peer_ips[@]} -eq 0 ]; then
        echo -e "  ${R}● No peer IP could be resolved safely.${NC}"
        echo -e "  ${DIM}  v10 refuses blind .1/.2 guessing except for verified /30 links.${NC}"
        sleep 2.5; return
    fi

    echo -e "\n  ${B}╭──────────────────── Discovered Peers ─────────────────╮${NC}"
    for i in "${!peer_ips[@]}"; do printf "  ${B}│${NC} ${Y}%2d${NC} ${C}❯${NC} ${G}%-50s${NC} ${B}│${NC}\n" "$i" "${peer_ips[$i]}"; done
    echo -e "  ${B}╰───────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}How many peers to use? [1-${#peer_ips[@]}, a=all] ❯❯ ${NC}"; read peer_count
    local selected_peers=()
    if [[ "$peer_count" == "a" || "$peer_count" == "A" ]]; then
        selected_peers=("${peer_ips[@]}")
    elif [[ "$peer_count" =~ ^[0-9]+$ ]] && [ "$peer_count" -ge 1 ] && [ "$peer_count" -le "${#peer_ips[@]}" ]; then
        selected_peers=("${peer_ips[@]:0:peer_count}")
    else
        echo -e "  ${R}● Invalid peer count.${NC}"; sleep 1.5; return
    fi

    echo -ne "  ${C}●${NC} ${W}HAProxy distribution [1 leastconn / 2 roundrobin / 3 first-up failover] (default 1): ${NC}"; read lb_mode
    case "$lb_mode" in 2) local balance="roundrobin"; local mode="LOADBALANCE";; 3) local balance="first"; local mode="FAILOVER";; *) local balance="leastconn"; local mode="LOADBALANCE";; esac

    echo -e "\n  ${C}●${NC} ${W}Preparing atomic HAProxy configuration...${NC}"
    ensure_haproxy_v10
    local backup="$H_CONF.v10.$(date +%Y%m%d%H%M%S).bak"
    cp -f "$H_CONF" "$backup" 2>/dev/null || true
    local tmp="$SECURE_TMP/haproxy.v10.$$"
    awk -v a="$LB_MARKER" -v b="$LB_END_MARKER" 'BEGIN{skip=0} $0==a{skip=1;next} $0==b{skip=0;next} !skip{print}' "$H_CONF" > "$tmp"

    echo "$LB_MARKER" >> "$tmp"
    echo "# Generated by MPorter v10 at $(date -Is)" >> "$tmp"
    for p in $clean_ports; do
        if ss -H -lntup 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$p$" && ! grep -qE "^frontend ft_${p}$" "$H_CONF"; then
            echo -e "  ${Y}⚠${NC} Port $p is already occupied by another process; skipped."; continue
        fi
        echo "frontend ft_$p" >> "$tmp"
        echo "    bind *:$p" >> "$tmp"
        echo "    default_backend bk_$p" >> "$tmp"
        echo "backend bk_$p" >> "$tmp"
        echo "    mode tcp" >> "$tmp"
        echo "    balance $balance" >> "$tmp"
        local srv_idx=1
        for target in "${selected_peers[@]}"; do
            echo "    server srv_${p}_${srv_idx} ${target}:$p check inter 3s fall 2 rise 2 observe layer4 error-limit 3 on-error mark-down" >> "$tmp"
            ((srv_idx++))
        done
        echo "" >> "$tmp"
    done
    echo "$LB_END_MARKER" >> "$tmp"

    if ! haproxy -c -f "$tmp" >/dev/null 2>&1; then
        echo -e "  ${R}✖ Generated HAProxy configuration failed validation.${NC}"
        cp -f "$backup" "$H_CONF" 2>/dev/null || true
        rm -f "$tmp"
        echo -e "  ${DIM}Backup kept at: $backup${NC}"; sleep 2.5; return
    fi
    mv -f "$tmp" "$H_CONF"
    if ! haproxy_reload_safe; then
        echo -e "  ${R}✖ HAProxy reload failed; restoring last known-good configuration.${NC}"
        cp -f "$backup" "$H_CONF" 2>/dev/null || true
        haproxy_reload_safe >/dev/null 2>&1 || true
        sleep 2.5; return
    fi

    # Reconcile actual engine state first, then persist controller intent.
    state_reconcile >/dev/null 2>&1 || true
    state_sync_interface_metadata >/dev/null 2>&1 || true
    apply_scoped_mss "$selected_if"
    state_init >/dev/null 2>&1 || true
    if command -v jq >/dev/null 2>&1; then
        local targets_json='[]'
        for target in "${selected_peers[@]}"; do targets_json=$(jq --arg ip "$target" '. + [{ip:$ip}]' <<< "$targets_json"); done
        local pool_json="$SECURE_TMP/pool.$$.json"
        jq --argjson ports "[$(echo "$clean_ports" | tr ' ' ',')]" --arg iface "$selected_if" --arg balance "$balance" --arg mode "$mode" --argjson targets "$targets_json" --arg now "$(date -Is)" \
          '.pools=[.pools[]|select(.interface!=$iface or .ports != $ports)] + [{interface:$iface,ports:$ports,balance:$balance,mode:$mode,targets:$targets,updated_at:$now}] | .updated_at=$now' "$STATE_FILE" > "$pool_json" 2>/dev/null && mv -f "$pool_json" "$STATE_FILE"
        local pool_tmp="$SECURE_TMP/poolmeta.$$.json"
        jq --arg iface "$selected_if" --arg mode "$mode" --arg now "$(date -Is)" '.mappings |= map(if .engine=="HAP" and (.mode=="LOADBALANCE" or .mode=="FAILOVER") then .interface=$iface | .mode=$mode | .updated_at=$now else . end) | .updated_at=$now' "$STATE_FILE" > "$pool_tmp" 2>/dev/null && mv -f "$pool_tmp" "$STATE_FILE"
        rm -f "$pool_json" "$pool_tmp"
    fi

    echo -e "\n  ${G}✔ Loadbalance pool applied safely.${NC}"
    echo -e "  ${DIM}Interface : $selected_if${NC}"
    echo -e "  ${DIM}Peers     : ${selected_peers[*]}${NC}"
    echo -e "  ${DIM}Strategy  : $balance / $mode${NC}"
    echo -e "  ${DIM}Backup    : $backup${NC}"
    echo -ne "\n  ${G}● Health-check these backends now? (y/n) ❯❯ ${NC}"; read hc
    [[ "${hc,,}" == "y" ]] && health_scan
    echo -ne "\n  ${G}● Done. Press Enter...${NC}"; read dummy
}

show_table() {
    draw_header; echo -e "\n  ${Y}● Detailed IP -> Port Matrix:${NC}"
    echo -e "  ${B}├──────────────┬──────────┬────────────────┬──────────────────────────┬────────────────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-8s${NC} ${B}│${NC} ${W}%-14s${NC} ${B}│${NC} ${W}%-24s${NC} ${B}│${NC} ${W}%-34s${NC} ${B}│${NC}\n" "TUNNEL NAME" "TYPE" "TARGET IP" "FORWARD ENGINE" "FORWARDED PORTS"
    echo -e "  ${B}├──────────────┼──────────┼────────────────┼──────────────────────────┼────────────────────────────────────┤${NC}"
    
    local h_map=""; local g_map=""; local r_map=""; local ipt_map=""; local ext_map_raw=""
    [ -f "$H_CONF" ] && h_map=$(grep -E "frontend ft_|server srv_" "$H_CONF" 2>/dev/null | awk '/frontend ft_/ {port=$2; sub(/ft_/, "", port)} /server srv_/ {ip=$3; sub(/:.*/, "", ip); print port "|" ip "|HAP"}')
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | sed -E 's/tcp:\/\/:([0-9]+)\/([0-9\.]+):.*/\1|\2|GST/g'); fi
    if [ -f "$R_CONF" ] && command -v jq >/dev/null 2>&1; then r_map=$(jq -r '.endpoints[]? | "\(.listen)|\(.remote)|RLM"' "$R_CONF" 2>/dev/null | sed -E 's/0\.0\.0\.0:([0-9]+)\|([0-9\.]+):[0-9]+\|RLM/\1|\2|RLM/g'); fi
    [ -f "$IPT_CONF" ] && ipt_map=$(grep "PREROUTING" "$IPT_CONF" 2>/dev/null | grep -oP -- '--dport \K[0-9]+.*MPORTER_NAT_[0-9\.]+' | awk '{print $1 "|" $NF "|IPT"}' | sed 's/MPORTER_NAT_//g')
    
    shopt -s nullglob
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf; do
        [ -f "$conf" ] || continue
        local TYPE="" FWD_TCP="" FWD_UDP="" CORE_SUBNET="" TUN_ID="" VNI_ID=""
        source "$conf" 2>/dev/null; [ "$TYPE" != "1" ] && continue
        local t_ip=""
        if [ -n "$TUN_ID" ]; then t_ip="${CORE_SUBNET:-10.76.${TUN_ID}}.2"
        elif [ -n "$VNI_ID" ]; then t_ip="${CORE_SUBNET:-10.88.${VNI_ID}}.2"; fi
        for p in $(echo "$FWD_TCP,$FWD_UDP" | tr ',' ' ' | xargs -n1 2>/dev/null | sort -u); do
            if [ -n "$p" ]; then ext_map_raw+="$p|$t_ip|TUN\n"; fi
        done
    done
    shopt -u nullglob
    
    local mappings=$(echo -e "$h_map\n$g_map\n$r_map\n$ipt_map\n$ext_map_raw" | grep -v '^$')
    
    if [ -z "$mappings" ]; then 
        printf "  ${B}│${NC} ${DIM}%-104s${NC} ${B}│${NC}\n" "  No active mappings. Ready to route strictly."
    else
        declare -A ip_ports_arr; declare -A ip_eng_arr
        while IFS='|' read -r p_num d_ip eng; do 
            if [ -n "$d_ip" ]; then 
                ip_ports_arr["$d_ip"]+="$p_num, "; if [[ ! "${ip_eng_arr["$d_ip"]}" == *"$eng"* ]]; then ip_eng_arr["$d_ip"]+="$eng/"; fi
            fi
        done <<< "$mappings"

        for d_ip in $(for i in "${!ip_ports_arr[@]}"; do echo "$i"; done | sort); do
            local iface_info=$(get_iface_info "$d_ip"); local t_type="${iface_info%%|*}"; local t_name="${iface_info##*|}"
            local clean_name="${t_name}"; [ ${#clean_name} -gt 12 ] && clean_name="${clean_name:0:9}..."
            local raw_eng="${ip_eng_arr[$d_ip]}"; local disp_eng=$(format_engine "$raw_eng")
            local clean_eng=$(echo -e "$disp_eng" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            local pad_eng=$(printf '%*s' "$(( 24 - ${#clean_eng} ))" "")
            local raw_ports="${ip_ports_arr[$d_ip]}"; raw_ports="${raw_ports%, }"
            local display_ports=""
            for p in $(echo "$raw_ports" | tr ',' ' ' | sort -u -n); do
                if grep -q "dport $p " "$OBFS_DIR/nat.sh" 2>/dev/null; then display_ports+="${M}${p}*(OBFS)${Y}, "
                else display_ports+="${p}, "; fi
            done
            display_ports="${display_ports%, }"; local clean_str=$(echo -e "$display_ports" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            if [ ${#clean_str} -gt 34 ]; then display_ports="${clean_str:0:31}..."; clean_str="$display_ports"; fi
            local pad=$(printf '%*s' "$((34 - ${#clean_str}))" "")
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-8s${NC} ${B}│${NC} ${G}%-14s${NC} ${B}│${NC} %b%s ${B}│${NC} ${Y}%b%s ${B}│${NC}\n" "$clean_name" "$t_type" "$d_ip" "$disp_eng" "$pad_eng" "$display_ports" "$pad"
        done
    fi
    echo -e "  ${B}╰──────────────┴──────────┴───────────────┴──────────────────┴─────────────────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

purge_menu() {
    draw_header; echo -e "\n  ${DIM}┌─[ DELETE & PURGE MAPPINGS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${Y}Purge Specific Interface${NC} ${DIM}(Removes all IPs on an interface)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Purge Specific Target IP${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Wipe ALL Mappings Globally${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read p_opt; p_opt=$(echo "$p_opt" | tr -dc '0-3')
    
    local h_map=""; local g_map=""; local r_map=""; local ipt_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -oP 'server srv_[0-9_]+ \K[0-9\.]+|server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null)
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1); fi
    if [ -f "$R_CONF" ] && command -v jq >/dev/null 2>&1; then r_map=$(jq -r '.endpoints[].remote?' "$R_CONF" 2>/dev/null | cut -d: -f1); fi
    [ -f "$IPT_CONF" ] && ipt_map=$(grep -oP -- 'MPORTER_NAT_\K[0-9\.]+' "$IPT_CONF" 2>/dev/null | sort -u)
    local all_ips=$(echo -e "$h_map\n$g_map\n$r_map\n$ipt_map" | grep -v '^$' | sort -u)

    case $p_opt in
        1)
            if [ -z "$all_ips" ]; then echo -e "  ${R}● No active mappings found!${NC}"; sleep 2; return; fi
            declare -A iface_ips
            for ip in $all_ips; do local iface_info=$(get_iface_info "$ip"); iface_ips["$iface_info"]+="$ip "; done
            local i=0; local iface_list=()
            echo -e "\n  ${B}╭────────────────── Select Interface to Purge ─────────────────╮${NC}"
            for ifc_info in $(for key in "${!iface_ips[@]}"; do echo "$key"; done | sort); do
                iface_list[$i]="$ifc_info"; local ip_arr=(${iface_ips[$ifc_info]}); local t_type="${ifc_info%%|*}"; local t_name="${ifc_info##*|}"; local disp_name="${t_name} [${t_type}]"
                local raw_str=$(printf "  %02d ❯ %-22s (Contains %-2d IPs)" "$i" "$disp_name" "${#ip_arr[@]}"); local pad=$(( 58 - ${#raw_str} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
                printf "  ${B}│${NC}  ${Y}%02d${NC} ${C}❯${NC} ${W}%-22s${NC} ${DIM}(Contains %-2d IPs)${NC}%s${B}│${NC}\n" "$i" "$disp_name" "${#ip_arr[@]}" "$sp"
                ((i++))
            done
            echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}Select Index ❯❯ ${NC}"; read idx; idx=$(echo "$idx" | tr -dc '0-9')
            local selected_ifc_info="${iface_list[$idx]}"
            if [ -z "$selected_ifc_info" ]; then echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            local t_name="${selected_ifc_info##*|}"
            echo -ne "  ${Y}● Deep Purge ALL IPs on $t_name? (y/n): ${NC}"; read conf
            if [[ "${conf,,}" == "y" ]]; then
                for ip in ${iface_ips[$selected_ifc_info]}; do purge_ip_core "$ip"; done
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart realm 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null; setup_mporter_service
                [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh
                echo -e "  ${G}● Interface $t_name purged successfully!${NC}"; sleep 1.5
            fi ;;
        2)
            if [ -z "$all_ips" ]; then echo -e "  ${R}● No active mappings found!${NC}"; sleep 2; return; fi
            local ip_arr=($all_ips)
            echo -e "\n  ${B}╭────────────────── Select Target IP to Purge ─────────────────╮${NC}"
            for i in "${!ip_arr[@]}"; do 
                local ifc_info=$(get_iface_info "${ip_arr[$i]}"); local t_type="${ifc_info%%|*}"; local t_name="${ifc_info##*|}"; local disp_name="${t_name} [${t_type}]"
                local raw_str=$(printf "  %02d ❯ %-15s (%s)" "$i" "${ip_arr[$i]}" "$disp_name"); local pad=$(( 58 - ${#raw_str} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
                printf "  ${B}│${NC}  ${Y}%02d${NC} ${C}❯${NC} ${W}%-15s${NC} ${DIM}(%s)${NC}%s${B}│${NC}\n" "$i" "${ip_arr[$i]}" "$disp_name" "$sp"
            done
            echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}Select Index ❯❯ ${NC}"; read idx; idx=$(echo "$idx" | tr -dc '0-9')
            local target_ip="${ip_arr[$idx]}"
            if [ -z "$target_ip" ]; then echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            purge_ip_core "$target_ip"; systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart realm 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null; setup_mporter_service
            [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh; echo -e "  ${G}● IP $target_ip purged successfully!${NC}"; sleep 1.5 ;;
        3) 
            echo -ne "  ${R}● Wipe all active mappings globally? (y/n) ❯❯ ${NC}"; read confirm
            if [[ "${confirm,,}" == "y" ]]; then
                echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
                echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
                echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"
                echo '{"network": {"no_tcp_delay": true}, "endpoints": []}' > "$R_CONF"
                > "$IPT_CONF"; rm -rf "$OBFS_DIR"
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart realm 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null; setup_mporter_service; build_obfs_runner
                echo -e "  ${G}● All global mappings wiped. Core configs preserved.${NC}"; sleep 1.5
            fi ;;
        0) return ;;
    esac
}

setup_watchdog() {
    cat > "$WATCHDOG_SCRIPT" <<'EOF_WD'
#!/bin/bash
set -u
STATE="/etc/mporter/state.json"
HEALTH="/run/mporter-backends.tsv"
while true; do
    /usr/bin/mporter --health-scan >/dev/null 2>&1 || true
    sleep 15
done
EOF_WD
    chmod +x "$WATCHDOG_SCRIPT"
    cat > "/etc/systemd/system/$WATCHDOG_SERVICE" <<EOF_WDS
[Unit]
Description=MPorter v10 Backend Health Watchdog
After=network.target haproxy.service
Wants=haproxy.service

[Service]
Type=simple
ExecStart=$WATCHDOG_SCRIPT
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF_WDS
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable "$WATCHDOG_SERVICE" >/dev/null 2>&1
    systemctl restart "$WATCHDOG_SERVICE" >/dev/null 2>&1
}

smart_watchdog_menu() {
    draw_header
    local wd_stat="${R}OFFLINE${NC}"
    systemctl is-active --quiet "$WATCHDOG_SERVICE" 2>/dev/null && wd_stat="${G}ACTIVE${NC} ${DIM}(15s health scan)${NC}"
    echo -e "\n  ${DIM}┌─[ SMART HEALTH WATCHDOG v10 ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}Status:${NC} $wd_stat"
    echo -e "  ${DIM}│${NC} ${G}UP${NC} = reachable  ${R}DOWN${NC} = backend failed  ${Y}INTERFACE_REMOVED${NC} = tunnel device missing"
    echo -e "  ${DIM}│${NC} Backend failure ${R}never deletes${NC} a mapping.\n"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Enable / Restart Health Watchdog${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Disable Health Watchdog${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Run Health Scan Now${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}View Backend Matrix${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} Cancel\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read wd_opt
    case "$wd_opt" in
        1) setup_watchdog; echo -e "  ${G}● Health watchdog enabled.${NC}"; sleep 1.5;;
        2) systemctl stop "$WATCHDOG_SERVICE" 2>/dev/null; systemctl disable "$WATCHDOG_SERVICE" 2>/dev/null; echo -e "  ${Y}● Health watchdog disabled.${NC}"; sleep 1.5;;
        3) health_scan; echo -e "  ${G}● Health scan completed.${NC}"; sleep 1.5;;
        4) show_health_matrix;;
    esac
}

manual_restart() {
    draw_header
    echo -e "\n  ${DIM}┌─[ RESTART SERVICES ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Restart HAProxy Engine${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Restart Gost Engine${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Restart Realm Engine${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Restart Kernel NAT Engine${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${G}Restart ALL Engines${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read r_opt; r_opt=$(echo "$r_opt" | tr -dc '0-5'); echo ""
    case $r_opt in
        1) systemctl restart haproxy 2>/dev/null; setup_mporter_service; echo -e "  ${G}● HAProxy restarted successfully.${NC}" ;;
        2) systemctl restart gost 2>/dev/null; setup_mporter_service; echo -e "  ${G}● Gost restarted successfully.${NC}" ;;
        3) systemctl restart realm 2>/dev/null; setup_mporter_service; echo -e "  ${G}● Realm restarted successfully.${NC}" ;;
        4) systemctl restart mporter-iptables 2>/dev/null; setup_mporter_service; echo -e "  ${G}● Kernel NAT restarted successfully.${NC}" ;;
        5) systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart realm 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null; setup_mporter_service; echo -e "  ${G}● All engines restarted successfully.${NC}" ;;
        0) return ;; *) echo -e "  ${R}● Invalid selection!${NC}" ;;
    esac
    sleep 1.5
}

state_init >/dev/null 2>&1 || true
ensure_haproxy_v10 >/dev/null 2>&1 || true

while true; do
    badge=""
    if [ -f "$SECURE_TMP/.mporter_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.mporter_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then badge=" ${Y}(Update Available ➔ v${rv})${NC}"; fi
    fi

    draw_header
    echo -e "\n  ${DIM}┌─[ DEPLOYMENT & DESTRUCTION ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Install & Configure Quad-Core System${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Uninstall Engines & Purge (Nuclear Wipe)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Add Port Mappings (Strict 1-to-1)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Smart Loadbalance (Multi-IP / Failover / Health)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Edit Mappings (Add/Del/OBFS)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Delete & Purge Mappings (By Interface/IP/All)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & DETAILS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${M}View IP -> Port Matrix${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${W}Smart Health Watchdog (Safe Monitoring)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${C}Manual Restart Services${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC} ${DIM}❯${NC} ${G}Instant OTA Update (Script Only)${NC}${badge}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC} ${DIM}❯${NC} ${M}Backend Health Matrix (Live)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Workspace${NC}\n"

    echo -ne "  ${C}MPorter ❯❯ ${NC}"; read -t 30 opt; opt=$(echo "$opt" | tr -dc '0-9')
    case $opt in
        1) install_core_engines ;;
        2) echo -ne "  ${R}● Nuclear Wipe? (y/n) ❯❯ ${NC}"; read confirm
           if [[ "${confirm,,}" == "y" ]]; then 
               systemctl stop haproxy 2>/dev/null; systemctl disable haproxy 2>/dev/null; systemctl stop gost 2>/dev/null; systemctl disable gost 2>/dev/null; systemctl stop realm 2>/dev/null; systemctl disable realm 2>/dev/null; systemctl stop mporter-obfs 2>/dev/null; systemctl disable mporter-obfs 2>/dev/null; systemctl stop mporter-iptables 2>/dev/null; systemctl disable mporter-iptables 2>/dev/null; systemctl stop mporter-watchdog 2>/dev/null; systemctl disable mporter-watchdog 2>/dev/null; systemctl stop mporter.service 2>/dev/null; systemctl disable mporter.service 2>/dev/null
               rm -rf /etc/haproxy /var/lib/haproxy /usr/local/bin/gost /etc/gost /etc/systemd/system/gost.service /usr/local/bin/realm /etc/realm /etc/systemd/system/realm.service "$OBFS_DIR" "$IPT_DIR" "$STATE_DIR" /etc/systemd/system/mporter-obfs.service /etc/systemd/system/mporter-iptables.service /etc/systemd/system/mporter-watchdog.service /etc/systemd/system/mporter.service
               apt-get purge -y haproxy 2>/dev/null; systemctl daemon-reload
               iptables -t nat -S OUTPUT 2>/dev/null | grep "MPORTER_OBFS" | sed 's/-A /-D /' | while read -r rule; do iptables -t nat $rule; done
               iptables -t mangle -S OUTPUT 2>/dev/null | grep "OBFS_CNT_TX_" | sed 's/-A /-D /' | while read -r rule; do iptables -t mangle $rule; done
               iptables -t mangle -S INPUT 2>/dev/null | grep "OBFS_CNT_RX_" | sed 's/-A /-D /' | while read -r rule; do iptables -t mangle $rule; done
               iptables -t mangle -S OUTPUT 2>/dev/null | grep "MPORTER_MSS_" | sed 's/-A /-D /' | while read -r rule; do iptables -t mangle $rule; done
               iptables -t mangle -S FORWARD 2>/dev/null | grep "MPORTER_MSS_" | sed 's/-A /-D /' | while read -r rule; do iptables -t mangle $rule; done
               iptables -t nat -S PREROUTING 2>/dev/null | grep "MPORTER_NAT_" | sed 's/-A /-D /' | while read -r rule; do iptables -t nat $rule; done
               iptables -t nat -S POSTROUTING 2>/dev/null | grep "MPORTER_NAT_" | sed 's/-A /-D /' | while read -r rule; do iptables -t nat $rule; done
               echo -e "  ${G}● Erased from system completely.${NC}"; sleep 1; exit 0
           fi ;;
        3) smart_map ;; 
        4) smart_loadbalance ;;
        5) edit_mapping ;; 
        6) purge_menu ;;
        7) show_table ;;
        8) smart_watchdog_menu ;; 
        9) manual_restart ;; 
        10) self_update_module ;;
        11) show_health_matrix ;;
        0) clear; exit 0 ;;
    esac
done
