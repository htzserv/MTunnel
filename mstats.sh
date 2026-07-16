manage_web_ui() {
    while true; do
        draw_mstats_header
        local s_ip=$(get_local_ip)
        w_stat_text="${R}OFFLINE${NC}"
        if systemctl is-active --quiet mweb.service 2>/dev/null; then 
            w_stat_text="${G}ONLINE${NC} ${DIM}❯${NC} ${C}http://${s_ip}:${WEB_PORT}${NC}"
        fi

        echo -e "\n  ${DIM}┌─[ WEB DASHBOARD CONTROLLER (MWEB) ]${NC}"
        echo -e "  ${DIM}│${NC} ${W}Status:${NC} ${w_stat_text}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Start / Deploy Web Dashboard${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Restart Web Dashboard${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Stop Web Dashboard${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Reset Username & Password${NC} ${DIM}(New Security Credentials)${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back to Main Menu${NC}\n"
        echo -ne "  ${C}WEB-CTRL ❯❯ ${NC}"; read w_opt
        w_opt=$(echo "$w_opt" | tr -d '\r' | tr -d ' ')
        
        case $w_opt in
            1)
                if [ ! -f "/usr/bin/mweb" ]; then
                    echo -e "\n  ${R}● Error: 'mweb' daemon script not found! Please install it first.${NC}"; sleep 2; continue
                fi
                echo -ne "\n  ${C}●${NC} ${W}Enter port for Web Dashboard (Default: 1000): ${NC}"; read custom_port
                custom_port=$(echo "$custom_port" | tr -d '\r' | tr -d ' ')
                WEB_PORT=${custom_port:-1000}
                mkdir -p /etc/mweb 2>/dev/null
                echo "WEB_PORT=$WEB_PORT" > "/etc/mweb/web.conf"
                
                cat <<EOF > "/etc/systemd/system/mweb.service"
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
                systemctl daemon-reload; systemctl enable mweb.service >/dev/null 2>&1; systemctl start mweb.service
                echo -e "\n  ${G}● Fleet Radar is LIVE!${NC}"; sleep 2; break ;;
            2)
                echo -e "\n  ${DIM}● Restarting Web Dashboard...${NC}"
                systemctl restart mweb.service 2>/dev/null; echo -e "  ${G}● Web Radar successfully restarted!${NC}"
                sleep 2; break ;;
            3)
                systemctl stop mweb.service 2>/dev/null; systemctl disable mweb.service >/dev/null 2>&1
                rm -rf /tmp/mweb_daemon
                echo -e "\n  ${R}● Web UI has been safely shut down.${NC}"; sleep 2; break ;;
            4)
                echo -ne "\n  ${C}●${NC} ${W}New Panel Username: ${NC}"; read n_usr
                echo -ne "  ${C}●${NC} ${W}New Panel Password: ${NC}"; read n_pwd
                n_usr=$(echo "$n_usr" | tr -d '\r' | tr -d ' ')
                n_pwd=$(echo "$n_pwd" | tr -d '\r' | tr -d ' ')
                if [ -n "$n_usr" ] && [ -n "$n_pwd" ]; then
                    sed -i "s/^WEB_USER=.*/WEB_USER=$n_usr/" /etc/mweb/web.conf
                    sed -i "s/^WEB_PASS=.*/WEB_PASS=$n_pwd/" /etc/mweb/web.conf
                    systemctl restart mweb.service 2>/dev/null
                    echo -e "  ${G}● Panel credentials updated successfully! New Session required.${NC}"; sleep 2
                else
                    echo -e "  ${R}● Invalid Input!${NC}"; sleep 1.5
                fi ;;
            0) break ;;
        esac
    done
}
