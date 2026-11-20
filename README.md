<div align="center">

# ⚡ MTunnel — MDesign Tunneling & Network Suite

**Unified Linux Server Tunneling, Anti-DPI Transports, Multi-Tunnel Failover & Diagnostics**

[![Version](https://img.shields.io/badge/Version-v2.2.1-f5c542?style=for-the-badge)](https://github.com/htzserv/MTunnel)
[![Backhaul Core](https://img.shields.io/badge/Backhaul%20Core-v0.9.1-00d2ff?style=for-the-badge)](https://github.com/htzserv/MTunnel)
[![Platform](https://img.shields.io/badge/Linux-Ubuntu%20%2F%20Debian-3fb950?style=for-the-badge)](#requirements)
[![Core API](https://img.shields.io/badge/Core%20API-v1%20(Layout%202)-a371f7?style=for-the-badge)](#repository-architecture)

<br>

[![English](https://img.shields.io/badge/Language-English-1f6feb?style=for-the-badge)](README.md)
[![فارسی](https://img.shields.io/badge/زبان-فارسی-2ea043?style=for-the-badge)](README.fa.md)

</div>

---

**MTunnel** is a modular, low-latency CLI management suite designed for deploying, benchmarking, and maintaining high-stability tunnels between servers (such as Iran ⇄ Foreign pairs) under restrictive network conditions. Built with the **MDesign** terminal interface, it unifies kernel tunnels, reverse proxies, anti-DPI transports, automated failover, port conflict protection, and real-time monitoring under a single consistent workflow.

---

## ✨ Key Highlights

* **Backhaul Core v0.9.1 (Anti-DPI Edition):** Built-in **uTLS** browser fingerprinting (`chrome`, `firefox`, `safari`, `edge`, `ios`, `random`), in-memory ECDSA P-256 **Auto-TLS**, Smart Auto-SNI for CDN/direct setups, RFC-6455 framed `wsmux`/`wssmux`, pipelined HTTP/2 `xhttp`/`xhttps`, tuned `kcp`/`kcpmux`, IPv6 forwarding, and Proxy Protocol v2.
* **MSmart Auto-Failover & Benchmarking:** Pair an Iran controller with a Foreign agent over pinned TLS, automatically test reachability across IPv4/IPv6, deploy up to **33 dual-stack tunnel candidates**, run sequential `iperf3` + latency benchmarks, and automatically fail over with configurable hysteresis, pinning, and maintenance windows.
* **Kernel Fabrics (MKernel):** Unified **mGRE** (`ipv4`, `gre6`, `6to4`, `ipip4to4`, `ipip4to6`, `ipip6to6`) and **VXLAN** (`ipv4`, `ipv6`) management with internal Virtual IPs (vIPs) and multi-target iptables load balancing.
* **Zero-Error Peer Links (`mtunnel://2/...`):** Export compressed, checksum-verified peer setup codes (valid 7 days, OSC-52 clipboard support) to deploy the matching side on the remote server in seconds without manual config editing.
* **CPU-Aware Performance Profiles:** Standardized presets (`ECO`, `BALANCED`, `SPEED`, `LOW-LATENCY`, `EXTREME`, `MANUAL`) across MBackhaul, MRathole, and MPaqet.
* **Built-In Safety & Operations:** Interactive **Port Conflict Guard**, automatic pre-edit config restore points, integrated **TCP BBR** control, **Auto-Recovery** scanner, live 1 Hz dashboard vitals (CPU, RAM, RX/TX, peer ping/loss), and **MDiag** (Doctor + LinkTest).
* **Offline & Restricted-Server Ready:** Supports GitHub, Iranian Mirror, and local `/root/mtunnel` bundle installs with per-file downloads and `python3` ZIP fallback when `unzip` is unavailable.

---

## 🚀 Quick Installation

### 1. Online Install (GitHub)
```bash
curl -fsSL https://raw.githubusercontent.com/htzserv/MTunnel/main/install.sh | sudo bash -s -- --online
```

### 2. Online Install (Iranian Mirror)
```bash
curl -fsSL https://c107328.parspack.net/c107328/MTunnel/install.sh | sudo bash -s -- --remote https://c107328.parspack.net/c107328/MTunnel
```

### 3. Local / Offline Bundle Install
Upload and extract the release archive to `/root/mtunnel`, then run:
```bash
unzip -o MTunnel-v2.2.1.zip -d /root/mtunnel
sudo bash /root/mtunnel/install.sh --local /root/mtunnel
```

### Installer Flags
| Flag | Description |
| :--- | :--- |
| `--online` | Force online download from the official GitHub repository |
| `--remote URL` | Install from a custom HTTPS repository or mirror base URL |
| `--local DIR` | Install from an extracted local directory |
| `--with-cores` | Also install tunnel engine binaries (`bh`, `rathole`, `paqet`, `gost`, `haproxy`, `realm`) |
| `--with-prereqs` | Install missing Debian/Ubuntu APT prerequisites |
| `--scripts-only` | Install only the core/dashboard scripts |
| `--no-launch` | Finish installation without launching `mtunnel` immediately |
| `--uninstall` | Completely remove MTunnel (prompts for confirmation) |

---

## 🧩 Modules & CLI Commands

Launch the main dashboard with `mtunnel`, or jump directly into any module:

| Command | Module | Description |
| :--- | :--- | :--- |
| `mtunnel` | **Master Core** | Unified live dashboard, tunnel overview, BBR, Auto-Recovery, and OTA sync |
| `msmart` | **MSmart** | Paired Iran/Foreign controller, 33-path dual-stack benchmark, and auto-failover watchdog |
| `mbackhaul` | **MBackhaul** | Backhaul Core v0.9.1 reverse tunnels (TLS, XHTTP, WSS, KCP, TCP, UDP) |
| `mrathole` | **MRathole** | Rathole TCP/UDP reverse tunnel manager with preset profiles |
| `mpaqet` | **MPaqet** | Paqet KCP raw-packet tunnel manager with CPU-aware KCP profiles |
| `mgre` | **MKernel (GRE)** | GRE, GRE6, 6to4, and IPIP4/IPIP6 kernel tunnels with vIPs & NAT forwarding |
| `mxlan` | **MKernel (VXLAN)** | VXLAN IPv4/IPv6 overlay fabrics with vIP pools & load balancing |
| `mporter` | **MPorter** | Multi-engine port forwarding (HAProxy, GOST, iptables), load balancing & health checks |
| `mdoctor` | **MDiag Doctor** | System, firewall, service, and binary health diagnostics |
| `linktest` | **MDiag LinkTest** | Cross-protocol reachability, latency, and Backhaul/Rathole IPv4↔IPv6 matrix tester |
| `mmirror` | **Mirror Optimizer** | Ubuntu APT mirror benchmark and network optimizer |

---

## 🛡️ MBackhaul Transports (Core v0.9.1)

| Transport | Underlying Layer | Best Use Case |
| :--- | :--- | :--- |
| `tlsmux` / `tls` | TCP + uTLS + Auto-TLS | Best direct all-rounder; low latency with browser-grade TLS fingerprint |
| `xhttpsmux` / `xhttps` | Split-HTTP/2 + uTLS | Strongest DPI evasion & CDN compatibility; supports `stream-up` & pipelined `packet-up` |
| `wssmux` / `wss` | WebSocket + uTLS (RFC-6455) | CDN-ready (Cloudflare / Arvan / Nginx) with framed multiplexing |
| `kcpmux` / `kcp` | UDP + KCP + AES/Salsa20 | High packet-loss links and unstable routes (optional FEC) |
| `tcpmux` / `tcp` | Raw TCP | Maximum throughput on clean links (optional UDP forwarding on `tcp`) |
| `udp` | Raw UDP | Dedicated UDP application forwarding |

> **Zero-Hassle Defaults:** Selecting any preset profile (`ECO` through `EXTREME`) automatically configures Auto-TLS, Smart Auto-SNI, `utls_fingerprint = "chrome"`, and CPU-scaled buffers without extra prompts. Choose **`6) MANUAL`** only when customizing SNI, custom certificates, KCP encryption/FEC, XHTTP paths, or CDN Edge IPs.

---

## ⚙️ Performance Profiles

Apply the **same profile on both servers** so multiplexing and heartbeat timers stay aligned:

| Profile | Target Workload | Buffers / Pool Scaling |
| :--- | :--- | :--- |
| **ECO** | Low-spec VPS (1 core / minimal RAM) | 2 MB buffers, small pool, conservative heartbeats |
| **BALANCED** | General production (Default) | 4 MB buffers, up to 8 pool/mux streams |
| **SPEED** | High-bandwidth streaming & downloads | 16 MB buffers, 64 KB mux frames, MUX v2 |
| **LOW-LATENCY** | Gaming, VoIP, interactive sessions | Aggressive pool, fast heartbeat & keepalive |
| **EXTREME** | High-concurrency servers (4+ cores) | 32 MB buffers, up to 32 pool/mux streams |
| **MANUAL** | Custom engineering | Full control over SNI, uTLS, MTU/MSS, KCP, XHTTP, Proxy Protocol |

---

## 🔗 Fast 2-Server Deployment (Peer Link Workflow)

1. **On Server A (Iran / Server):** Run `mbackhaul` (or `mrathole`, `mgre`, `mxlan`, `mpaqet`) → **Create Tunnel** → choose transport, ports, and profile.
2. When prompted, select **Generate Peer Setup Link (`Y`)** and copy the single-line `mtunnel://2/...` code.
3. **On Server B (Foreign / Client):** Open the same module → **Create Tunnel → Create From Peer Link** → paste the code and confirm.
4. Both servers automatically match tokens, ports, transports, profiles, uTLS settings, and BBR state.

For automated multi-tunnel management, run `msmart` → **Install Prerequisites** on both servers → **Foreign: Create Pair Code** on the Foreign server → **Iran: Enter Pair Code & Create Group** on the Iran server.

---

## 🗂️ Repository Architecture

```text
MTunnel/
├── install.sh              # Standalone installer (GitHub / Mirror / Local / Uninstall)
├── main.sh                 # Master dashboard (`mtunnel`)
├── mdiag.sh                # Unified Doctor (`mdoctor`) & LinkTest (`linktest`)
├── mporter.sh              # Port forwarder (`mporter`)
├── mirror.sh               # APT mirror optimizer (`mmirror`)
├── core/
│   ├── common.sh           # Shared core (API 1, Layout 2): UI, BBR, Port Guard, Peer Links
│   └── bintunnel.sh        # Shared runtime & validation library for binary tunnels
└── tunnels/
    ├── mbackhaul.sh        # Backhaul Core v0.9.1 manager (`mbackhaul`)
    ├── msmart.sh           # Multi-tunnel benchmark & auto-failover (`msmart`)
    ├── mkernel.sh          # GRE / IPIP / VXLAN kernel tunnel engine (`mgre`, `mxlan`)
    ├── mrathole.sh         # Rathole reverse-tunnel manager (`mrathole`)
    └── mpaqet.sh           # Paqet KCP tunnel manager (`mpaqet`)
```

---

## 📋 Requirements

* **OS:** Ubuntu 20.04 / 22.04 / 24.04 / 26.04 or Debian 11 / 12 (systemd-based Linux)
* **Architecture:** `x86_64` (`amd64`) or `aarch64` (`arm64`)
* **Privileges:** Root (`sudo`)
* **Core Utilities:** `bash`, `iproute2`, `iptables`, `curl`/`wget`, `openssl`, `tar`, `python3` (installed automatically when needed)

---

## 🧹 Uninstallation

To cleanly remove MTunnel, its systemd units, firewall rules, and MTunnel-owned engine binaries:
```bash
sudo bash /root/mtunnel/install.sh --uninstall
```

---

<div align="center">

Built with **MDesign** • Maintained at [htzserv/MTunnel](https://github.com/htzserv/MTunnel)

</div>
