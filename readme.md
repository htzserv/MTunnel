# 🚀 MHDesign Master Core (MGRE & MPorter)

A professional, modular, and minimal Bash-based infrastructure manager for creating advanced GRE / IP6GRE (6to4) tunnels and HAProxy port forwarding. Designed with the **MHDesign 0.1** philosophy: pixel-perfect UI, seamless user experience, and zero dependencies.

![Version](https://img.shields.io/badge/Version-v3.8-blue.svg)
![UI](https://img.shields.io/badge/UI-MHDesign_0.1-purple.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

---

## ✨ Key Features

* **Modular Architecture:** Centralized command dashboard with completely isolated background modules.
* **Multi-Tunnel Engine:** Create, manage, and monitor an unlimited number of tunnels simultaneously without conflict.
* **6to4 IP6GRE Encapsulation:** Bypass DPI and network restrictions by encapsulating IPv4 traffic within deterministic, auto-generated IPv6 subnets.
* **Pixel-Perfect Monitoring:** Live, boxed tree-view monitoring for each tunnel, core IPs, and virtual IPs.
* **Surgical Deletion:** Safely delete specific tunnels and their routing rules (iptables) without affecting the rest of the infrastructure.
* **MPorter (HAProxy):** Fully automated port mapping onto virtual IPs with real-time health checks.

## ⚡ Quick Start (One-Line Installer)

Run the following command on your fresh Ubuntu server (Iran or International) with `root` privileges. This command fetches the master core and all required modules directly from the repository and launches the dashboard.

```bash
bash <(curl -Ls [https://raw.githubusercontent.com/htzserv/MTunnel/main/main.sh](https://raw.githubusercontent.com/htzserv/MTunnel/main/main.sh) -o main.sh && curl -Ls [https://raw.githubusercontent.com/htzserv/MTunnel/main/mgre.sh](https://raw.githubusercontent.com/htzserv/MTunnel/main/mgre.sh) -o mgre.sh && curl -Ls [https://raw.githubusercontent.com/htzserv/MTunnel/main/mporter.sh](https://raw.githubusercontent.com/htzserv/MTunnel/main/mporter.sh) -o mporter.sh && chmod +x *.sh) && ./main.sh
