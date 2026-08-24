# 🛡️ MTunnel

**Enterprise-Grade Tunneling, Layer-4 Forwarding, Raw Packet Manipulation & Network Diagnostics for Linux**

**MTunnel** is a modular, automated, and visually structured network infrastructure management ecosystem built upon the strict **MDesign** standards. It empowers DevOps engineers and network administrators to deploy Layer-2 fabrics, Layer-3 encapsulations, high-concurrency reverse multiplexers, and raw packet tunneling alongside real-time traffic radars and dynamic protocol benchmarks.

---

## ✨ Key Features & Core Modules

### 🎛️ 1. Master Command Center (`mtunnel` / `main.sh`)
* Real-time dynamic header reflecting protocol states, listening sockets, and IP bindings.
* Zero-dependency offline deployment pipeline supporting pre-cached binaries and assets (`packages/`).
* Automated Systemd daemon management and a single-click **Nuclear Wipe** to completely purge all interfaces, firewall chains, and service records.

### 🌐 2. Tunnel Infrastructure Hub
* **Modular GRE Core (`mgre`):** Standard IPv4 GRE & 6to4 IP6GRE encapsulation with zero-downtime public IP hot-swapping and tree-view hierarchy mapping.
* **VXLAN Virtual Mesh (`mxlan`):** Isolated Layer-2 Virtual Ethernet Bridge meshes encapsulated over standard UDP port 4789.
* **Rathole Reverse Engine (`mrathole`):** Lightweight, highly resilient reverse tunnel architecture optimized for hostile international routing conditions.
* **Backhaul Multiplexer (`mbackhaul`):** Multi-transport connection aggregation engine supporting Plain TCP, TCPMUX, WSMUX (WebSocket), and TLS-encrypted WSSMUX.
* **Paqet Raw Packet Engine (`mpaqet`):** Low-level socket injection with spoofed TCP flags (`PA`), Reed-Solomon Forward Error Correction (FEC), and stateless Anti-RST firewall hooks (`NOTRACK` + mangle dropping).

### 🚦 3. Port Forwarding Matrix (`mporter`)
* High-throughput Layer-4 stream redirection and load-balancing powered by **HAProxy**.
* Strict interface-bound IP routing rules to prevent cross-interface leakage and unwanted traffic dispersal.
* Integrated health watchdog and cron scheduler to guarantee persistent uptime.

### 📊 4. Traffic Radar & Web Interface (`mstats` & `mweb`)
* **Live Omni-Radar:** High-precision real-time terminal telemetry monitoring bandwidth (TX/RX) across physical adapters, overlay interfaces, and kernel firewall counters.
* **MDesign Web Dashboard (`mweb`):** Lightweight HTTP telemetry dashboard for browser-based bandwidth inspection and remote daemon observation.

### 🔬 5. Network Laboratory & Diagnostics (`linktest` & `iperf3`)
* **Strict 2-Way Auto-Synced Benchmark:** Fully automated handshake matrix testing actual carrier viability across all tunnel engines concurrently between endpoints.
* **Live Channel Speedtest:** Real-time bandwidth throughput validation on confirmed operational transport paths.
* **Dynamic MTU & Loss Discovery:** Automated Don't-Fragment (DF) packet sweeps detecting exact Path MTU limits and carrier loss profiles.
* **Integrated iPerf3 Suite:** Direct memory-to-memory throughput measurement across custom server/client roles.

### 🛡️ 6. Security Shield & Kernel Accelerator (`mshield` & `mbbr`)
* **Stealth Anti-Probing & Anti-RST Shield:** Active SYN flood rate limiting, traffic loop interception, and suppression of injected RST packets.
* **TCP BBR Accelerator (`mbbr`):** Automated deployment of Google's BBR congestion control algorithm with Fair Queueing (FQ) scheduler.

---

## 🚀 Quick Automated Installation

Run the following command on a clean Linux server (Ubuntu 22.04 / 24.04 or Debian):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/htzserv/MTunnel/main/install.sh)
```
