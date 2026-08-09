#!/bin/bash
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
REPO_SCRIPTS="https://raw.githubusercontent.com/htzserv/MTunnel/main"; LOCAL_DIR="/root/mtunnel"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"
MODE="auto"; case "${1:-}" in --offline) MODE="offline";; --online) MODE="online";; -h|--help) echo "Usage: $0 [--offline|--online]"; exit 0;; esac
CORE_MODULES=("main.sh" "mgre.sh" "mporter.sh" "mxlan.sh" "mrathole.sh" "mweb.sh" "mstats.sh")
mkdir -p "$LOCAL_DIR/packages" || { echo -e "${R}Cannot create $LOCAL_DIR${NC}"; exit 1; }
clear 2>/dev/null || true
echo -e "\n  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
echo -e "  ${B}│${NC} ${W}MTunnel${NC} ${DIM}| Core Installer${NC}                              ${B}│${NC}"
echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}\n"
echo -e "  ${DIM}Initial modules:${NC} ${W}mgre  mporter  mxlan  mrathole  mweb  mstat${NC}"
echo -e "  ${DIM}Mode:${NC} ${W}$MODE${NC}\n"
find_local(){ local f="$1"; [ -s "$SCRIPT_DIR/$f" ]&&{ echo "$SCRIPT_DIR/$f";return;}; [ -s "$LOCAL_DIR/$f" ]&&{ echo "$LOCAL_DIR/$f";return;}; return 1; }
progress(){ local n="$1" total="$2" label="$3" width=36 pct=$((n*100/total)) filled=$((pct*width/100)); local empty=$((width-filled)); local done rest; done="$(printf '%*s' "$filled" ''|tr ' '-'')"; rest="$(printf '%*s' "$empty" ''|tr ' '-'')"; printf "  ${C}%-22s${NC} ${G}%s${DIM}%s${NC} ${W}%3d%%${NC}\n" "$label" "$done" "$rest" "$pct"; }
deploy(){ local f="$1" src="$2" name="${f%.sh}"; [ "$name" = main ]&&name=mtunnel; cp -f "$src" "$LOCAL_DIR/$f"||return 1; sed -i 's/\r$//' "$LOCAL_DIR/$f" 2>/dev/null||true; install -m0755 "$LOCAL_DIR/$f" "/usr/bin/$name"||return 1; [ "$name" = mtunnel ]&&install -m0755 "$LOCAL_DIR/$f" /usr/local/bin/mtunnel 2>/dev/null||true; if [ "$f" = mstats.sh ];then install -m0755 "$LOCAL_DIR/$f" /usr/bin/mstats; ln -sfn /usr/bin/mstats /usr/bin/mstat;fi; }
download(){ local f="$1" tmp="/tmp/mtunnel_${f}_$$"; rm -f "$tmp"; if command -v curl>/dev/null;then curl -fL --retry 2 --connect-timeout 8 --max-time 120 --progress-bar -o "$tmp" "$REPO_SCRIPTS/$f?v=$(date +%s)";else wget --timeout=8 --tries=2 -O "$tmp" "$REPO_SCRIPTS/$f?v=$(date +%s)";fi; [ -s "$tmp" ]&&echo "$tmp"; }
failed=()
for i in "${!CORE_MODULES[@]}";do f="${CORE_MODULES[$i]}"; label="${f%.sh}";[ "$f" = mstats.sh ]&&label=mstat; src="";[ "$MODE" != online ]&&src="$(find_local "$f"||true)"; if [ -n "$src" ];then echo -e "  ${G}✓${NC} $label ${DIM}(local)${NC}";deploy "$f" "$src"||failed+=("$label");elif [ "$MODE" = offline ];then echo -e "  ${R}✗${NC} $label ${R}(not available locally)${NC}";failed+=("$label");else echo -e "  ${C}→${NC} $label ${DIM}(GitHub)${NC}";tmp="$(download "$f"||true)";if [ -n "$tmp" ]&&deploy "$f" "$tmp";then rm -f "$tmp";else rm -f "$tmp";failed+=("$label");fi;fi;progress "$((i+1))" "${#CORE_MODULES[@]}" "$label";done
if [ "${#failed[@]}" -gt 0 ];then echo -e "\n  ${R}Installation failed:${NC} ${failed[*]}";exit 1;fi
echo -e "\n  ${G}──────────────────────────────────── 100%${NC}\n  ${G}✓ MTunnel core installed successfully.${NC}\n  ${DIM}Offline install:${NC} ${W}bash install.sh --offline${NC}\n"; hash -r 2>/dev/null||true; if [ -t 0 ];then exec /usr/bin/mtunnel;else exec /usr/bin/mtunnel </dev/tty;fi
