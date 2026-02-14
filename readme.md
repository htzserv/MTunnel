# 🚀 MDesign Unified Network Suite (MGRE + MapRoxy)

A professional, high-performance tunneling and port-mapping solution designed for high-load environments. This suite combines GRE tunnel management with SHA-256 synchronized virtual IPs and HAProxy port forwarding.



## ✨ Key Features

* **⚡ MGRE Tunneling:** Automated GRE tunnel establishment with optimized MTU and MSS clamping.
* **🔗 Sync IP Logic:** Generate up to 254 synchronized virtual IPs using a shared **Sync Key** (SHA-256 based) for seamless /30 peering.
* **📡 MapRoxy Integration:** Professional HAProxy management for port mapping and load distribution.
* **📊 Live Monitoring:** Real-time latency and status tracking for all virtual interfaces.
* **🛡️ Persistence:** Full `systemd` integration to ensure tunnels survive reboots.
* **🧹 Hard Uninstaller:** Complete system cleanup with a single command.

---

## 🛠 Installation & Usage

To deploy the suite on your server, run the following one-liner:

```bash
wget -4 -qO mgre https://raw.githubusercontent.com/htzserv/MTunnel/main/MGRe.sh && chmod +x mgre && ./mgre
