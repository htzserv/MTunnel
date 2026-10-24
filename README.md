<div dir="rtl" align="right">

# MTunnel

مجموعه‌ی اسکریپت‌های bash برای ساخت و مدیریت تونل بین دو سرور لینوکسی (معمولاً یک سرور **ایران** و یک سرور **خارج**)، همراه با پورت‌فوروارد، تست کیفیت لینک، عیب‌یابی و بروزرسانی از GitHub یا آینه‌ی ایرانی.

نسخه‌ی این بسته: **1.4.0**

---

## فهرست

1. [امکانات](#امکانات)
2. [پیش‌نیازها](#پیش‌نیازها)
3. [ساختار مخزن](#ساختار-مخزن)
4. [نصب](#نصب)
5. [اجرا و منوی اصلی](#اجرا-و-منوی-اصلی)
6. [ساخت تونل و کد جفت (Peer Code)](#ساخت-تونل-و-کد-جفت-peer-code)
7. [توضیح ماژول‌ها](#توضیح-ماژول‌ها)
8. [بروزرسانی و نصب (منوی شماره‌ی 11)](#بروزرسانی-و-نصب-منوی-شمارهی-11)
9. [منبع دانلود (GitHub و آینه)](#منبع-دانلود-github-و-آینه)
10. [ساخت manifest.txt](#ساخت-manifesttxt)
11. [حذف تونل‌ها و حذف کامل](#حذف-تونلها-و-حذف-کامل)
12. [مسیرها و سرویس‌ها](#مسیرها-و-سرویسها)
13. [عیب‌یابی](#عیبیابی)
14. [نکات امنیتی](#نکات-امنیتی)

---

## امکانات

| ماژول | دستور | کار |
|---|---|---|
| داشبورد اصلی | `mtunnel` | منوی مرکزی، بروزرسانی، نصب آفلاین، حذف |
| GRE / GRE6 / IPIP | `mgre` | تونل لایه‌ی ۳ با MTU، قوانین فوروارد و رمزنگاری اختیاری |
| VXLAN | `mxlan` | شبکه‌ی مجازی VXLAN / VXLAN6 با محافظت از peer |
| Rathole | `mrathole` | تونل معکوس (Reverse Tunnel) |
| Backhaul | `mbackhaul` | مالتی‌پلکسر Backhaul (چند نوع ترنسپورت) |
| Paqet | `mpaqet` | تونل KCP روی بسته‌های خام |
| MPorter | `mporter` | ماتریس پورت‌فوروارد با موتورهای HAProxy / Gost / Realm / iptables |
| LinkTest | `linktest` | تست اتصال، پروتکل، تأخیر، Loss و MTU |
| MDoctor | `mdoctor` | عیب‌یابی سیستم، شبکه، فایروال و ابزار تعمیر امن |
| Mirror | `mmirror` | بهینه‌ساز DNS و آینه‌ی APT |

---

## پیش‌نیازها

- دسترسی **root** (همه‌چیز با `sudo` اجرا می‌شود).
- Ubuntu 24.04 روی معماری amd64. بسته‌های `.deb` پیش‌نیاز برای همین نسخه ساخته شده‌اند.
- اتصال به GitHub یا آینه‌ی ایرانی برای دانلود (برای نصب آفلاین لازم نیست).
- پیش‌نیازهای پیش‌فرض: `cron`، `curl`، `gzip`، `haproxy`، `iperf3` (و `libiperf0`)، `iproute2`، `jq`، `qrencode`، `socat`، `wget`.

---

## ساختار مخزن

```
MTunnel/
├── install.sh          نصب‌کننده
├── main.sh             داشبورد اصلی (دستور mtunnel)
├── mporter.sh          پورت‌فوروارد
├── linktest.sh         تست لینک
├── mdoctor.sh          عیب‌یابی
├── mirror.sh           بهینه‌ساز DNS / APT
├── core/
│   └── common.sh       هسته‌ی مشترک همه‌ی ماژول‌ها
├── tunnels/
│   ├── mgre.sh
│   ├── mxlan.sh
│   ├── mrathole.sh
│   ├── mbackhaul.sh
│   └── mpaqet.sh
├── engines/            موتورها: bh, rathole, paqet, gost, haproxy, realm و آرشیوهای آن‌ها
│   └── manifest.txt
└── prereqs/            بسته‌های پیش‌نیاز (.deb)
    └── manifest.txt
```

نکته‌ها:

- پوشه‌ای به اسم `packages` وجود ندارد. موتورها فقط در `engines/` و فایل‌های `.deb` فقط در `prereqs/` هستند.
- هر دو پوشه `manifest.txt` مخصوص خودشان را دارند (شیوه‌ی ساخت در بخش [ساخت manifest.txt](#ساخت-manifesttxt)). منیفست اختیاری است. اگر نباشد، برنامه از لیست داخلی خودش استفاده می‌کند.
- فایل‌های موردانتظار در `engines/`:
  - فایل‌های خام: `bh`، `rathole`، `paqet`، `haproxy`، `realm` و `gost` (اگر `gost` خام نبود، نصب‌کننده از `gost-linux-amd64-2.11.5.gz` استفاده می‌کند)
  - آرشیوها: `backhaul_linux_amd64.tar.gz`، `rathole-x86_64-unknown-linux-gnu.zip`، `paqet-linux-amd64-v1.0.0-alpha.21.tar.gz`، `gost-linux-amd64-2.11.5.gz`، `realm-x86_64-unknown-linux-musl.tar.gz`

---

## نصب

### روش ۱: منوی نصب‌کننده (پیشنهادی)

```bash
curl -fsSL https://raw.githubusercontent.com/htzserv/MTunnel/main/install.sh | sudo bash
```

منوی زیر نمایش داده می‌شود و با **یک عدد** و Enter کار انجام می‌شود:

| عدد | منبع | بسته |
|---|---|---|
| 1 | GitHub | Full package: اسکریپت‌ها + تونل‌ها + موتورها + پیش‌نیازها |
| 2 | GitHub | Scripts + tunnels: همه‌ی ماژول‌ها، بدون موتور و بدون `.deb` |
| 3 | GitHub | Scripts only: هسته + main + ابزارها، ماژول‌های تونل دست نمی‌خورند |
| 4 | آینه‌ی ایران | Full package |
| 5 | آینه‌ی ایران | Scripts + tunnels |
| 6 | آینه‌ی ایران | Scripts only |
| 7 | حذف | Uninstall: حذف کامل MTunnel از سیستم |
| 0 | | خروج |

اگر نصب‌کننده را کنار فایل‌های پروژه (کنار `main.sh`) اجرا کنید، منو نمایش داده نمی‌شود و نصب از همان پوشه انجام می‌شود.

بعد از نصب، داشبورد خودش باز می‌شود (مگر با `--no-launch`).

### روش ۲: نصب مستقیم با پارامتر

```bash
# نصب آنلاین مستقیم از GitHub (بدون منو)
curl -fsSL https://raw.githubusercontent.com/htzserv/MTunnel/main/install.sh | sudo bash -s -- --online

# نصب از یک پوشه‌ی محلی
sudo bash install.sh --local .

# نصب با موتورها
sudo bash install.sh --local . --with-cores
```

| پارامتر | کار |
|---|---|
| `--online` | نصب مستقیم از GitHub رسمی، بدون منو |
| `--remote URL` | نصب از یک آدرس HTTPS دلخواه |
| `--local DIR` | نصب از پوشه‌ی محلی |
| `--with-cores` | موتورها را هم نصب کن |
| `--no-launch` | بعد از نصب داشبورد را باز نکن |
| `--root DIR` | نصب آزمایشی داخل یک مسیر دیگر، بدون دست زدن به سیستم |
| `--uninstall` | حذف کامل (با تأیید) |
| `--allow-downgrade` | فقط برای سازگاری؛ برگشت به نسخه‌ی قدیمی‌تر همیشه آزاد است |
| `--help` | راهنما |

**موتورها در نصب:** هر موتوری که در `engines/` باشد و ELF معتبر برای CPU شما باشد نصب می‌شود. موتوری که نباشد در پایان نصب با اسم فهرست می‌شود و نصب ادامه پیدا می‌کند. بعداً می‌توانید آن را از منوی بروزرسانی دانلود کنید.

---

## اجرا و منوی اصلی

```bash
sudo mtunnel
```

| کلید | کار |
|---|---|
| `p` | استفاده از کد جفت (Peer Code) |
| `1` | GRE / GRE6 / IPIP Tunnel |
| `2` | VXLAN Virtual Mesh Fabric |
| `3` | Rathole Reverse Tunnel |
| `4` | Backhaul Multiplexer |
| `5` | Paqet Raw Packet KCP Tunnel |
| `6` | Port Forwarding Matrix (MPorter) |
| `7` | Link Test & Protocol Benchmark |
| `8` | iPerf3 Bandwidth Benchmark |
| `9` | MTunnel Doctor & Diagnostics |
| `10` | Mirror (DNS & APT Optimizer) |
| `11` | Update & Local Install |
| `12` | حذف همه‌ی تونل‌ها و فورواردها (فایل‌ها می‌مانند) |
| `13` | Nuclear Wipe: حذف کامل |
| `0` | خروج |

کنار هر ماژول، اگر نسخه‌ی جدیدتری موجود باشد، نشان `(Update Available: vX.Y.Z)` دیده می‌شود. بررسی بروزرسانی در پس‌زمینه انجام می‌شود.

---

## ساخت تونل و کد جفت (Peer Code)

هر تونل دو سر دارد:

- **IRAN (Server)**
- **KHAREJ (Client)**

روش پیشنهادی برای راه‌اندازی دو سر:

1. روی یک سرور، تونل را بسازید (مثلاً `mtunnel` ← `1` برای GRE).
2. بعد از ساخت، ماژول یک **Peer Setup Link** تولید می‌کند. شکل آن `mtunnel://3/<نوع>/...` است و با HMAC محافظت می‌شود. گزینه‌ی **Generate Peer Setup Link** در منوی Create Tunnel هم همین کار را می‌کند.
3. روی سرور دوم، `mtunnel` را اجرا کنید، `p` (Use Peer Code) را بزنید و لینک را paste کنید. تنظیمات سر مقابل خودکار ساخته می‌شود. (در ماژول‌ها گزینه‌ی **Create From Peer Link** هم هست.)

نوع لینک خودش مشخص می‌کند کدام ماژول باز شود: `gre` ← mgre، `vxlan` ← mxlan، `rathole` ← mrathole، `backhaul` ← mbackhaul، `paqet` ← mpaqet.

برای GRE و VXLAN هر دو سر باید **یک حالت و یک Master Token** داشته باشند، وگرنه لینک قطع می‌شود.

---

## توضیح ماژول‌ها

### `mgre`: GRE / GRE6 / IPIP

انواع قابل ساخت: GRE استاندارد IPv4، 6to4 IP6GRE، GRE6 مستقیم (IPv6 روی IPv6)، IPIP4 → IPIP4 و IPIP4 → IPIP6.

- رمزنگاری اختیاری (AES-256-CBC + HMAC-SHA256). بدون آن، ترافیک plaintext است.
- مدیریت MTU و پورت‌فوروارد روی تونل: افزودن پورت، حذف پورت مشخص، جایگزینی کل پورت‌ها، فعال‌کردن Load Balancer، انتخاب IP مقصد (تکی، چندتایی یا همه)، رفع تداخل پورت‌ها با سرویس‌های دیگر.
- ساخت و بازیابی Backup.
- Watchdog برای بازسازی خودکار تونل.

### `mxlan`: VXLAN

مثل mgre، برای VXLAN / VXLAN6. همان امکانات مدیریت پورت، Load Balancer، رفع تداخل و Backup را دارد و محافظت از peer هم دارد.

### `mrathole`: Rathole

تونل معکوس. نصب هسته از GitHub، آینه، لینک دلخواه یا پوشه‌ی محلی `/root/mtunnel/engines`. یک گزینه برای کرون‌جاب ری‌استارت خودکار (Add/Update و Remove) دارد.

### `mbackhaul`: Backhaul

چند نوع ترنسپورت (انتخاب با عدد ۱ تا ۷)، تنظیمات سفارشی و گواهی TLS (مسیر cert و key، یا ساخت خودکار). موتور فوروارد پورت را می‌شود انتخاب کرد: خود Backhaul، iptables، یا MPorter. کرون‌جاب ری‌استارت خودکار هم دارد.

### `mpaqet`: Paqet

تونل KCP روی بسته‌های خام. نصب هسته از GitHub، آینه، لینک دلخواه یا `/root/mtunnel/engines/paqet`.

### `mporter`: ماتریس پورت‌فوروارد

موتورهای فوروارد:

| موتور | ویژگی |
|---|---|
| HAProxy | Load Balancer، پایدار |
| Gost | مناسب TLS / WS Obfuscation |
| Realm | سریع، نوشته‌شده با Rust |
| iptables NAT | سرعت خام |

امکانات: افزودن Mapping به‌صورت یک‌به‌یک (ویزارد)، حذف یک پورت لوکال از همه‌ی موتورها، غیرفعال‌کردن OBFS روی یک پورت، تغییر IP مقصد، پاک‌سازی بر اساس Interface یا IP مقصد، پاک‌سازی کل Mappingها، نمایش IP/Port Mappings و **Backend Health Matrix**. هدف‌های Backhaul هم قابل انتخاب است.

### `linktest`: تست لینک

1. Full Auto-Synced Protocol + BH/RH Matrix & Speedtest
2. ماتریس IPv4 ↔ IPv6 برای Backhaul / Rathole
3. کشف خودکار MTU و Loss
4. اجرا به‌عنوان Listener (باز کردن پورت‌های موقت تست)
5. اجرا به‌عنوان Tester (بررسی پورت‌ها و فیلترینگ سمت مقابل)
6. نمایش پورت‌های در حال Listen
7. OTA Update

برای تست بین دو سرور، یکی را Listener و دیگری را Tester کنید.

### `mdoctor`: عیب‌یابی

- Run Full Health Scan
- Network & IPv6 Diagnostics
- Firewall & Port Diagnostics
- Tunnel Engines & Core & Script Health
- System Services & Failed Units
- Safe Repair Actions (فعال‌سازی IPv4/IPv6 forwarding، لود ماژول‌های کرنل تونل، ری‌لود systemd)
- Export Diagnostic Report
- OTA Update

### `mmirror`: DNS و APT

بهینه‌ساز DNS و آینه‌ی APT (MDesign Speed & Network Optimizer) با تست سرعت آینه‌ها.

### iPerf3

تست پهنای باند. نصب iPerf3 با APT، از آینه‌ی ایرانی (گزینه‌ی 2) یا از GitHub (گزینه‌ی 3) انجام می‌شود.

---

## بروزرسانی و نصب (منوی شماره‌ی 11)

| گزینه | کار |
|---|---|
| `A` | نصب Full Package از GitHub (اسکریپت‌ها + موتورها + همه‌ی `.deb`) |
| `B` | نصب Full Package از آینه |
| `1` تا `5` | دانلود از **GitHub رسمی**: اسکریپت‌ها، اسکریپت main، اسکریپت Mirror، موتورها، پیش‌نیازها |
| `6` تا `10` | همان پنج مورد از **آینه‌ی ایران** |
| `11` | Offline Install از پوشه / ZIP / آرشیو |
| `12` | Install from Link: آدرس مستقیم `.sh` یا `.zip` |
| `13` | Install via Code Paste: چسباندن کد در nano (ذخیره با Ctrl+X) |
| `0` | بازگشت |

نحوه‌ی کار دانلود:

- ابتدا کل مخزن به‌صورت **یک آرشیو** دانلود و باز می‌شود (از GitHub: آرشیو شاخه، از آینه: `<آینه>/MTunnel.zip`).
- اگر آرشیو در دسترس نبود، دانلود فایل‌به‌فایل جایگزین می‌شود: موتورها از `engines/` و `.deb`ها از `prereqs/`.
- با منیفست، فایل جدیدی که در پوشه بگذارید خودکار شناسایی می‌شود و SHA256 آن بررسی می‌شود.
- هر فایل خراب یا ناقص با دلیلش گزارش می‌شود و بقیه نصب می‌شوند.

نصب آفلاین: پوشه یا آرشیو باید شامل `main.sh`، `install.sh`، `core/common.sh` و همه‌ی ماژول‌ها باشد. اگر پوشه‌های `engines/` و `prereqs/` هم داخلش باشند، آن‌ها نیز نصب می‌شوند. وضعیت تونل‌ها، Backupها و گزارش‌ها حفظ می‌شود.

---

## منبع دانلود (GitHub و آینه)

آدرس‌های پیش‌فرض:

- GitHub: `https://raw.githubusercontent.com/htzserv/MTunnel/main`
- آینه: `https://c107328.parspack.net/c107328/MTunnel`

برای تغییر دائمی، فایل `/etc/mtunnel/sources.conf` بسازید:

```
MTUNNEL_GITHUB_BASE=https://raw.githubusercontent.com/USER/REPO/main
MTUNNEL_MIRROR_BASE=https://example.com/MTunnel
```

یا برای یک اجرا، متغیرهای محیطی `MTUNNEL_GITHUB_BASE` و `MTUNNEL_MIRROR_BASE` را تنظیم کنید.

قوانین: فقط آدرس **HTTPS** پذیرفته می‌شود، و کلید دیگری غیر از این دو در فایل مجاز نیست.

آینه باید همان ساختار مخزن را داشته باشد (`engines/`، `prereqs/`، و فایل `MTunnel.zip` از کل مخزن).

---

## ساخت manifest.txt

اسکریپت `make_manifest.py` (پایتون ۳) روی ویندوز، لینوکس و مک کار می‌کند و برای هر پوشه یک `manifest.txt` می‌سازد:

- `engines/manifest.txt` برای موتورها و آرشیوها
- `prereqs/manifest.txt` برای فایل‌های `.deb`

فرمت هر خط: `<sha256>  <نام فایل>`

```bash
python make_manifest.py C:\MTunnel               # هر دو پوشه
python make_manifest.py C:\MTunnel\engines       # فقط موتورها
python make_manifest.py C:\MTunnel -r            # جستجو در همه‌ی زیرپوشه‌ها
python make_manifest.py C:\MTunnel --check       # فقط بررسی، چیزی نمی‌نویسد
```

بدون آرگومان (دوبار کلیک)، پنجره‌ی انتخاب پوشه باز می‌شود. اسکریپت هشدار می‌دهد اگر باینری ELF نباشد، `.deb` یا gzip خراب باشد، فایل به‌جای باینری HTML باشد، یا فایلی در پوشه‌ی اشتباه باشد. نام‌های دارای فاصله رد می‌شوند.

بعد از ساخت، دو `manifest.txt` را هم روی مخزن آپلود کنید.

---

## حذف تونل‌ها و حذف کامل

| روش | چه چیزی پاک می‌شود | تأیید |
|---|---|---|
| منوی `12` | همه‌ی تونل‌ها (GRE، VXLAN، Rathole، Backhaul، Paqet)، فورواردهای MPorter و قوانین فایروال MTunnel. **اسکریپت‌ها و موتورها می‌مانند.** | تایپ `DELETE-TUNNELS` |
| منوی `13` (Nuclear Wipe) | همه‌چیز: تونل‌ها، سرویس‌ها، کرون‌جاب‌ها، قوانین فایروال، هسته‌های نصب‌شده توسط MTunnel، تنظیمات، اسکریپت‌ها | تایپ `WIPE-MTUNNEL` |
| منوی نصب‌کننده `7` یا `--uninstall` | همان حذف کامل | تایپ `WIPE-MTUNNEL` |

در حذف کامل، موتورهای Gost و Realm فقط وقتی پاک می‌شوند که MPorter آن‌ها را خودش نصب کرده باشد. هر ورودی دیگر، عملیات را لغو می‌کند.

---

## مسیرها و سرویس‌ها

| مسیر | محتوا |
|---|---|
| `/usr/bin/mtunnel` | داشبورد اصلی |
| `/usr/bin/mgre` `mxlan` `mrathole` `mbackhaul` `mpaqet` `mporter` `mdoctor` `linktest` `mmirror` | ماژول‌ها |
| `/usr/lib/mtunnel/common.sh` | هسته‌ی مشترک |
| `/root/mtunnel/` | نسخه‌ی اسکریپت‌ها |
| `/root/mtunnel/engines` | کش موتورها |
| `/root/mtunnel/prereqs` | کش `.deb`ها |
| `/root/mtunnel/tunnels` `backups` `reports` | وضعیت تونل‌ها، Backupها، گزارش‌ها |
| `/var/lib/mtunnel/owned-binaries` | ثبت موتورهایی که MTunnel خودش نصب کرده |
| `/etc/mgre` `/etc/mporter` `/etc/mrathole` `/etc/mbackhaul` `/etc/paqet` | تنظیمات ماژول‌ها |
| `/etc/mtunnel/sources.conf` | تغییر آدرس منبع‌ها (اختیاری) |

سرویس‌های systemd: `mgre.service`، `mxlan.service`، `mporter.service`، `mbackhaul@*`، `mrathole@*`، `mpaqet@*`، به‌علاوه‌ی Watchdogهای `mgre-watchdog.timer` و `mxlan-watchdog.timer`.

---

## عیب‌یابی

| مشکل | علت و راه‌حل |
|---|---|
| `curl: (22) ... 404` هنگام نصب | فایل در مخزن نیست یا در پوشه‌ی اشتباه است. موتورها باید در `engines/` و `.deb`ها در `prereqs/` باشند. |
| `Engines skipped: ...` | آن موتور در `engines/` پیدا نشد یا ELF معتبر برای CPU نبود. بعد از آپلود فایل، از منوی `11` گزینه‌ی دانلود موتورها را بزنید. |
| `checksum differs from manifest.txt` | فایل آپلودشده با منیفست نمی‌خواند. `make_manifest.py` را دوباره اجرا و منیفست را آپلود کنید. |
| دانلود موتور از آینه ناموفق است | مطمئن شوید آینه همان ساختار `engines/` را دارد. ماژول‌های Backhaul و Rathole اگر آینه جواب ندهد خودشان به GitHub رسمی برمی‌گردند؛ برای بقیه، منبع GitHub را دستی انتخاب کنید. |
| تونل برقرار نمی‌شود | دو سر باید یک حالت و یک Master Token داشته باشند. از `mdoctor` ← Full Health Scan و Firewall & Port Diagnostics استفاده کنید. |
| تداخل پورت | در منوی پورت‌های mgre/mxlan گزینه‌ی **Fix conflicts**. |
| IPv4/IPv6 forwarding خاموش است | `mdoctor` ← Safe Repair Actions. |
| لینک نیمه‌کاره یا تونل افتاده | `linktest` برای تست MTU و Loss، و Watchdog سرویس. |

برای گزارش مشکل، از `mdoctor` ← **Export Diagnostic Report** خروجی بگیرید.

---

## نکات امنیتی

- همه‌ی دانلودها فقط با **HTTPS** انجام می‌شوند.
- اسکریپت‌ها قبل از نصب از نظر سینتکس و نقش ماژول و سازگاری با هسته اعتبارسنجی می‌شوند. اگر نصب نیمه‌کاره بماند، فایل‌های قبلی برگردانده می‌شوند (Rollback).
- موتورها با SHA256 منیفست و بررسی ELF/deb/آرشیو کنترل می‌شوند.
- لینک‌های Peer با HMAC امضا شده‌اند؛ لینک را فقط به سرور مقابل بدهید.
- حذف کامل فقط فایل‌هایی را پاک می‌کند که MTunnel خودش نصب کرده است.
- قبل از چسباندن کد یا نصب از لینک دلخواه، مطمئن شوید منبع مورد اعتماد است.

</div>
