<div align="center">

# ⚡ MTunnel — مجموعه جامع تانلینگ و شبکه MDesign

**مدیریت یکپارچه تانل‌های سرور لینوکس، پروتکل‌های ضد‌فیلتر (Anti-DPI)، فیل‌اور هوشمند و عیب‌یابی شبکه**

[![Version](https://img.shields.io/badge/Version-v2.2.1-f5c542?style=for-the-badge)](https://github.com/htzserv/MTunnel)
[![Backhaul Core](https://img.shields.io/badge/Backhaul%20Core-v0.9.1-00d2ff?style=for-the-badge)](https://github.com/htzserv/MTunnel)
[![Platform](https://img.shields.io/badge/Linux-Ubuntu%20%2F%20Debian-3fb950?style=for-the-badge)](#پیش‌نیازها)
[![Core API](https://img.shields.io/badge/Core%20API-v1%20(Layout%202)-a371f7?style=for-the-badge)](#ساختار-مخزن)

<br>

[![English](https://img.shields.io/badge/Language-English-1f6feb?style=for-the-badge)](README.md)
[![فارسی](https://img.shields.io/badge/زبان-فارسی-2ea043?style=for-the-badge)](README.fa.md)

</div>

---

<div dir="rtl">

**MTunnel** یک مجموعه ابزار ماژولار و کم‌تأخیر در محیط ترمینال لینوکس است که برای راه‌اندازی، بنچمارک و نگهداری تانل‌های پایدار بین دو سرور (مانند سرور ایران ⇄ سرور خارج) در شرایط محدودیت شبکه و فیلترینگ طراحی شده است. این مجموعه با رابط کاربری **MDesign**، تانل‌های کرنل، تانل‌های معکوس، پروتکل‌های ضد‌DPI، فیل‌اور خودکار، محافظت از تداخل پورت و مانیتورینگ زنده را در یک محیط یکپارچه گرد هم می‌آورد.

---

## ✨ ویژگی‌های کلیدی

* **هسته Backhaul Core v0.9.1 (نسخه Anti-DPI):** پشتیبانی داخلی از اثرانگشت مرورگر **uTLS** (`chrome`، `firefox`، `safari`، `edge`، `ios`، `random`)، گواهی خودکار درون‌حافظه‌ای ECDSA P-256 (**Auto-TLS**)، تشخیص هوشمند **SNI** برای حالت مستقیم و پشت CDN، فریم‌بندی استاندارد RFC-6455 روی `wsmux`/`wssmux`، پشتیبانی از HTTP/2 و آپلود موازی در `xhttp`/`xhttps`، تیونینگ `kcp`/`kcpmux`، فورواردینگ IPv6 و Proxy Protocol v2.
* **فیل‌اور و بنچمارک خودکار (MSmart):** جفت‌سازی امن سرور ایران و خارج روی TLS با پین کردن گواهی، تست خودکار دسترسی‌پذیری دوطرفه IPv4/IPv6، ساخت تا **۳۳ مسیر دوپشته (Dual-Stack)**، بنچمارک ترتیبی سرعت (`iperf3`) و پینگ، و جابه‌جایی خودکار روی بهترین تانل با تنظیمات Hysteresis، پین کردن تانل و حالت Maintenance.
* **تانل‌های کرنل (MKernel):** مدیریت یکپارچه **mGRE** (`ipv4`، `gre6`، `6to4`، `ipip4to4`، `ipip4to6`، `ipip6to6`) و **VXLAN** (`ipv4`، `ipv6`) همراه با آی‌پی‌های مجازی داخلی (vIP) و لودبالانسینگ چندمقصده با `iptables`.
* **کد اتصال سریع بدون خطا (`mtunnel://2/...`):** خروجی گرفتن از کدهای فشرده و دارای چکسام (معتبر به مدت ۷ روز همراه با کپی خودکار در کلیپ‌بورد با OSC-52) برای راه‌اندازی طرف مقابل در چند ثانیه و بدون ویرایش دستی کانفیگ.
* **پروفایل‌های هوشمند متناسب با CPU:** پروفایل‌های آماده و یکدست (`ECO`، `BALANCED`، `SPEED`، `LOW-LATENCY`، `EXTREME`، `MANUAL`) در ماژول‌های MBackhaul، MRathole و MPaqet.
* **ابزارهای ایمنی و نگهداری داخلی:** سیستم تعاملی **Port Conflict Guard** (تشخیص و رفع تداخل پورت)، بکاپ خودکار پیش از هر ویرایش، کنترل یکپارچه **TCP BBR**، اسکنر **Auto-Recovery**، داشبورد زنده با رفرش ۱ ثانیه‌ای (CPU، RAM، سرعت RX/TX، پینگ و پکت‌لاس) و **MDiag** (Doctor + LinkTest).
* **آماده برای سرورهای محدود و آفلاین:** پشتیبانی از نصب از طریق GitHub، میرور ایران و پکیج محلی `/root/mtunnel` با دانلود تک‌فایلی و اکسترکت جایگزین با `python3` در سرورهایی که `unzip` ندارند.

---

## 🚀 نصب سریع

### ۱. نصب آنلاین از گیت‌هاب
</div>

```bash
curl -fsSL https://raw.githubusercontent.com/htzserv/MTunnel/main/install.sh | sudo bash -s -- --online
```

<div dir="rtl">

### ۲. نصب آنلاین از میرور ایران
</div>

```bash
curl -fsSL https://c107328.parspack.net/c107328/MTunnel/install.sh | sudo bash -s -- --remote https://c107328.parspack.net/c107328/MTunnel
```

<div dir="rtl">

### ۳. نصب محلی / آفلاین
فایل آرشیو ریلیز را در مسیر `/root/mtunnel` استخراج و نصب کنید:
</div>

```bash
unzip -o MTunnel-v2.2.1.zip -d /root/mtunnel
sudo bash /root/mtunnel/install.sh --local /root/mtunnel
```

<div dir="rtl">

### فلگ‌های نصب‌کننده (`install.sh`)

| فلگ | توضیحات |
| :--- | :--- |
| `--online` | نصب اجباری آنلاین از مخزن رسمی گیت‌هاب |
| `--remote URL` | نصب از یک آدرس HTTPS یا میرور دلخواه |
| `--local DIR` | نصب از پوشه اکسترکت‌شده روی سرور |
| `--with-cores` | نصب هم‌زمان باینری هسته‌ها (`bh`، `rathole`، `paqet`، `gost`، `haproxy`، `realm`) |
| `--with-prereqs` | نصب پیش‌نیازهای سیستمی APT (مخصوص اوبونتو/دبیان) |
| `--scripts-only` | نصب فقط اسکریپت‌های هسته و داشبورد |
| `--no-launch` | اتمام نصب بدون اجرای خودکار `mtunnel` در پایان |
| `--uninstall` | حذف کامل MTunnel از سرور (با تأیید کاربر) |

---

## 🧩 ماژول‌ها و دستورات CLI

با دستور `mtunnel` وارد داشبورد اصلی شوید یا هر ماژول را مستقیم اجرا کنید:

| دستور | ماژول | کاربرد |
| :--- | :--- | :--- |
| `mtunnel` | **Master Core** | داشبورد زنده یکپارچه، نمای کلی تانل‌ها، BBR، Auto-Recovery و آپدیت OTA |
| `msmart` | **MSmart** | کنترلر جفت‌شده ایران/خارج، بنچمارک ۳۳ مسیره و واچ‌داگ فیل‌اور خودکار |
| `mbackhaul` | **MBackhaul** | مدیریت تانل‌های معکوس Backhaul Core v0.9.1 (TLS، XHTTP، WSS، KCP، TCP، UDP) |
| `mrathole` | **MRathole** | مدیریت تانل معکوس Rathole (TCP/UDP) با پروفایل‌های آماده |
| `mpaqet` | **MPaqet** | مدیریت تانل KCP مبتنی بر Paqet با پروفایل‌های بهینه‌شده |
| `mgre` | **MKernel (GRE)** | تانل‌های کرنل GRE، GRE6، 6to4 و IPIP4/IPIP6 با vIP و فورواردینگ NAT |
| `mxlan` | **MKernel (VXLAN)** | شبکه لایه‌دو VXLAN روی IPv4/IPv6 با استخر vIP و لودبالانسینگ |
| `mporter` | **MPorter** | پورت‌فوروارد چندموتوره (HAProxy، GOST، iptables) با Health Check |
| `mdoctor` | **MDiag Doctor** | بررسی سلامت سیستم، فایروال، سرویس‌ها و باینری‌ها |
| `linktest` | **MDiag LinkTest** | تست دسترسی‌پذیری پروتکل‌ها، پینگ و ماتریس IPv4↔IPv6 بکهال و رتهول |
| `mmirror` | **Mirror Optimizer** | تست و انتخاب سریع‌ترین میرور APT اوبونتو |

---

## 🛡️ پروتکل‌های MBackhaul (هسته v0.9.1)

| پروتکل | لایه زیرساخت | بهترین سناریوی استفاده |
| :--- | :--- | :--- |
| `tlsmux` / `tls` | TCP + uTLS + Auto-TLS | بهترین گزینه همه‌کاره برای اتصال مستقیم با پینگ پایین و اثرانگشت مرورگر |
| `xhttpsmux` / `xhttps` | Split-HTTP/2 + uTLS | قوی‌ترین گزینه در برابر DPI و کاملاً سازگار با CDN (`stream-up` و `packet-up` موازی) |
| `wssmux` / `wss` | WebSocket + uTLS (RFC-6455) | مناسب عبور از کلودفلر، آروان و Nginx با مالتی‌پلکس فریم‌بندی‌شده |
| `kcpmux` / `kcp` | UDP + KCP + AES/Salsa20 | مناسب لینک‌های دارای پکت‌لاس بالا و مسیرهای ناپایدار (با FEC اختیاری) |
| `tcpmux` / `tcp` | TCP خام | بیشترین سرعت خام روی لینک‌های تمیز (پشتیبانی اختیاری از فوروارد UDP روی `tcp`) |
| `udp` | UDP خام | فورواردینگ اختصاصی اپلیکیشن‌های UDP |

> **پیش‌فرض‌های بی‌دردسر:** با انتخاب هرکدام از پروفایل‌های آماده (`ECO` تا `EXTREME`)، تنظیمات Auto-TLS، تشخیص هوشمند SNI، مقدار `utls_fingerprint = "chrome"` و بافرهای متناسب با CPU به‌صورت خودکار و بدون هیچ سؤال اضافه‌ای اعمال می‌شوند. فقط در صورت نیاز به تنظیمات دستی (مثل SNI دلخواه، گواهی شخصی، رمزنگاری KCP، مسیر XHTTP یا Edge IP) گزینه **`6) MANUAL`** را انتخاب کنید.

---

## ⚙️ پروفایل‌های عملکرد (Performance Profiles)

برای هماهنگی کامل تایمرها و تنظیمات MUX، **پروفایل یکسان را روی هر دو سرور** انتخاب کنید:

| پروفایل | نوع استفاده | بافرها و استخر اتصال |
| :--- | :--- | :--- |
| **ECO** | سرورهای ضعیف (۱ هسته / رم کم) | بافر 2MB، استخر کوچک، Heartbeat سبک |
| **BALANCED** | استفاده استاندارد و روزمره (پیش‌فرض) | بافر 4MB، تا ۸ کانکشن/استریم مالتی‌پلکس |
| **SPEED** | دانلود، استریم و ترافیک سنگین | بافر 16MB، فریم 64KB و MUX نسخه ۲ |
| **LOW-LATENCY** | گیم، تماس صوتی و ترافیک حساس به پینگ | استخر تهاجمی (Aggressive)، Heartbeat و Keepalive سریع |
| **EXTREME** | سرورهای پرترافیک (۴ هسته و بالاتر) | بافر 32MB، تا ۳۲ کانکشن/استریم مالتی‌پلکس |
| **MANUAL** | تنظیمات مهندسی دلخواه | کنترل کامل روی SNI، uTLS، MTU/MSS، KCP، XHTTP و Proxy Protocol |

---

## 🔗 راه‌اندازی سریع بین دو سرور (Peer Link)

1. **روی سرور اول (ایران / Server):** دستور `mbackhaul` (یا `mrathole`، `mgre`، `mxlan`، `mpaqet`) را اجرا کرده و از بخش **Create Tunnel**، پروتکل، پورت‌ها و پروفایل را مشخص کنید.
2. در انتهای ساخت تانل، گزینه **Generate Peer Setup Link (`Y`)** را بزنید و کد تک‌خطی `mtunnel://2/...` را کپی کنید.
3. **روی سرور دوم (خارج / Client):** همان ماژول را باز کرده و از مسیر **Create Tunnel → Create From Peer Link** کد را پیست و تأیید کنید.
4. توکن، پورت‌ها، پروتکل، پروفایل، تنظیمات uTLS و وضعیت BBR روی هر دو سرور به‌صورت خودکار هماهنگ می‌شوند.

برای مدیریت چندتانله و فیل‌اور خودکار، دستور `msmart` را روی هر دو سرور اجرا کرده، گزینه **Install Prerequisites** را بزنید، سپس روی سرور خارج **Foreign: Create Pair Code** و روی سرور ایران **Iran: Enter Pair Code & Create Group** را انتخاب کنید.

---

## 🗂️ ساختار مخزن

</div>

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

<div dir="rtl">

---

## 📋 پیش‌نیازها

* **سیستم‌عامل:** اوبونتو `20.04` / `22.04` / `24.04` / `26.04` یا دبیان `11` / `12` (مبتنی بر `systemd`)
* **معماری پردازنده:** `x86_64` (`amd64`) یا `aarch64` (`arm64`)
* **دسترسی:** کاربر ریشه (`root` / `sudo`)
* **ابزارهای پایه:** `bash`، `iproute2`، `iptables`، `curl`/`wget`، `openssl`، `tar`، `python3` (در صورت نیاز به‌صورت خودکار نصب می‌شوند)

---

## 🧹 حذف کامل (Uninstallation)

برای پاک‌سازی کامل MTunnel، سرویس‌های systemd، رول‌های فایروال و باینری‌های نصب‌شده توسط MTunnel:
</div>

```bash
sudo bash /root/mtunnel/install.sh --uninstall
```

---

<div align="center">

ساخته‌شده با **MDesign** • نگهداری‌شده در [htzserv/MTunnel](https://github.com/htzserv/MTunnel)

</div>
