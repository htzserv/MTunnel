# 🛡️ MTunnel | MDesign Master Core

**Enterprise-Grade Tunneling, Load Balancing & Network Diagnostics for Linux**

MTunnel is a highly modular, automated, and visually flawless terminal dashboard designed for managing advanced networking infrastructures. Built upon the **MDesign** philosophy, it provides a pixel-perfect terminal UI for deploying GRE/6to4 tunnels, managing HAProxy/Gost multiplexers, and diagnosing network health without dealing with complex Linux commands.

---

## ✨ Key Features

* **🎛️ Centralized Dashboard (`mtunnel`)**: A dynamic, auto-updating core menu to control all modules from anywhere in your server.
* **🌐 Advanced Tunnel Manager (`mgre`)**: 
  * Support for Standard IPv4 GRE and 6to4 IP6GRE Encapsulation.
  * Live monitoring of all active tunnels and vIPs.
  * Hot-swap Public IPs (Edit tunnel endpoints without teardowns).
* **🚦 Smart Multiplexer & Failover (`mporter`)**:
  * Dual-core engine supporting **HAProxy** (Standard LB) and **Gost** (Advanced Routing).
  * Intelligent Load-Balancing (Round-Robin) across multiple nodes.
  * Auto-Restart Scheduler via Cron for 100% Uptime.
* **🩺 Deep Diagnostics (`mdiag`)**:
  * Real-time packet loss, average latency, and jitter calculation.
  * Built-in `iperf3` Throughput Speedtest directly between tunnel endpoints.
* **🔥 Nuclear Wipe**: Instantly self-destruct and purge all traces, configs, and services with a single command to return the server to a vanilla state.

---

## 🚀 Quick Install

Run the following command on a fresh Ubuntu 22.04 / 24.04 server. The dynamic installer will automatically fetch the latest core modules and build your workspace:

Note: Once installed, simply type mtunnel anywhere in your terminal to launch the MDesign Dashboard.📦

```bash
bash <(curl -sL [https://raw.githubusercontent.com/htzserv/MTunnel/main/install.sh](https://raw.githubusercontent.com/htzserv/MTunnel/main/install.sh))

