#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MTunnel manifest builder (Windows / Linux / macOS)

برای هر کدام از دو پوشه یک manifest.txt جدا می‌سازد:
    engines/manifest.txt   -> انجین‌ها و آرشیوهای آن‌ها (bh, rathole, paqet, gost, haproxy, realm, *.tar.gz, *.zip, *.gz)
    prereqs/manifest.txt   -> بسته‌های پیش‌نیاز (*.deb)

فرمت هر خط (همان چیزی که main.sh می‌خواند):
    <sha256>  <filename>
پایان خط LF، UTF-8 بدون BOM.

روش‌های اجرا:
  1) دوبار کلیک روی فایل            -> پنجره‌ی انتخاب پوشه باز می‌شود
  2) کشیدن و رها کردن پوشه روی فایل  -> پوشه‌ی پروژه (یا خود engines / prereqs)
  3) خط فرمان:
       python make_manifest.py C:\\MTunnel                 (هر دو پوشه)
       python make_manifest.py C:\\MTunnel\\engines         (فقط انجین)
       python make_manifest.py C:\\MTunnel -r              (جستجوی همه‌ی engines / prereqs در زیرپوشه‌ها)
       python make_manifest.py C:\\MTunnel --check         (فقط بررسی، چیزی نمی‌نویسد)
"""

import argparse
import hashlib
import os
import re
import sys

MANIFEST_NAME = "manifest.txt"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*$")
ENGINE_EXACT = {"bh", "backhaul", "rathole", "paqet", "gost", "haproxy", "realm"}
ENGINE_SUFFIXES = (".tar.gz", ".zip", ".gz")

# نام پوشه -> نوع
FOLDER_KIND = {"engines": "engines", "prereqs": "deps", "prerequisites": "deps"}
KIND_TITLE = {"engines": "انجین", "deps": "پیش‌نیاز"}


def kind_of_name(name):
    """نوع فایل بر اساس نامش: engines / deps / None."""
    low = name.lower()
    if low.endswith(".deb"):
        return "deps"
    if name in ENGINE_EXACT or low.endswith(ENGINE_SUFFIXES):
        return "engines"
    return None


def folder_kind(path):
    return FOLDER_KIND.get(os.path.basename(os.path.abspath(path)).lower())


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sanity_warning(path, name):
    try:
        if os.path.getsize(path) == 0:
            return "فایل خالی است"
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError as e:
        return "خواندن فایل ممکن نشد: %s" % e
    low = name.lower()
    if low.endswith(".deb") and not head.startswith(b"!<arch>"):
        return "این فایل .deb معتبر به نظر نمی‌رسد"
    if name in ENGINE_EXACT and not head.startswith(b"\x7fELF"):
        return "این فایل ELF لینوکسی نیست (آپلود اشتباه؟)"
    if low.endswith((".tar.gz", ".gz")) and not head.startswith(b"\x1f\x8b"):
        return "این فایل gzip معتبر به نظر نمی‌رسد"
    if low.endswith(".zip") and not head.startswith(b"PK"):
        return "این فایل zip معتبر به نظر نمی‌رسد"
    if head.lstrip().lower().startswith((b"<!doc", b"<html")):
        return "محتوای فایل HTML است (دانلود ناقص یا صفحه‌ی خطا)"
    return None


def scan_dir(folder, kind):
    """-> (entries, skipped_bad_name, misplaced)"""
    entries, skipped, misplaced = [], [], []
    for name in sorted(os.listdir(folder), key=str.lower):
        path = os.path.join(folder, name)
        if not os.path.isfile(path) or name == MANIFEST_NAME:
            continue
        k = kind_of_name(name)
        if k is None:
            continue
        if k != kind:
            misplaced.append(name)
        elif not NAME_RE.match(name):
            skipped.append(name)
        else:
            entries.append((name, path))
    return entries, skipped, misplaced


def read_existing(folder):
    mf = os.path.join(folder, MANIFEST_NAME)
    if not os.path.isfile(mf):
        return None
    result = {}
    with open(mf, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^([0-9a-fA-F]{64})\s+\*?(\S+)$", line)
            if m:
                result[m.group(2)] = m.group(1).lower()
    return result


def process(folder, kind, check_only=False):
    folder = os.path.abspath(folder)
    entries, skipped, misplaced = scan_dir(folder, kind)
    print("\n=== [%s] %s" % (KIND_TITLE[kind], folder))
    for n in skipped:
        print("  [رد شد] %s  -> نام شامل فاصله یا کاراکتر غیرمجاز است" % n)
    for n in misplaced:
        other = "prereqs" if kind == "engines" else "engines"
        print("  [پوشه‌ی اشتباه] %s  -> جایش در %s است، وارد منیفست نشد" % (n, other))

    lines, problems = [], 0
    for name, path in entries:
        digest = sha256_of(path)
        lines.append((name, digest))
        warn = sanity_warning(path, name)
        print("  %s%s...  %s" % ("OK " if not warn else "!! ", digest[:16], name))
        if warn:
            problems += 1
            print("       هشدار: %s" % warn)

    if not lines:
        print("  (فایلی برای منیفست پیدا نشد)")
        if not check_only:
            return None

    if check_only:
        old = read_existing(folder)
        if old is None:
            print("  manifest.txt وجود ندارد.")
            return False
        new = dict(lines)
        bad = False
        for n, d in new.items():
            if n not in old:
                print("  [در منیفست نیست] %s" % n); bad = True
            elif old[n] != d:
                print("  [هش متفاوت] %s" % n); bad = True
        for n in old:
            if n not in new:
                print("  [در منیفست هست ولی فایلش نیست] %s" % n); bad = True
        print("  نتیجه: %s" % ("ناهماهنگ" if bad else "منیفست کاملاً درست است"))
        return not bad

    out = os.path.join(folder, MANIFEST_NAME)
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        for name, digest in lines:
            f.write("%s  %s\n" % (digest, name))
    os.replace(tmp, out)
    print("  -> %s ساخته شد (%d فایل%s)" % (
        MANIFEST_NAME, len(lines), "، %d هشدار" % problems if problems else ""))
    return True


def find_targets(root, recursive):
    """-> لیست (پوشه، نوع)"""
    root = os.path.abspath(root)
    k = folder_kind(root)
    if k:
        return [(root, k)]
    found = []
    if recursive:
        for cur, dirs, _ in os.walk(root):
            dirs[:] = [d for d in dirs if not d.startswith(".") and d != "__pycache__"]
            for d in sorted(dirs):
                dk = FOLDER_KIND.get(d.lower())
                if dk:
                    found.append((os.path.join(cur, d), dk))
    else:
        seen = set()
        for d in sorted(os.listdir(root)):
            p = os.path.join(root, d)
            dk = FOLDER_KIND.get(d.lower())
            if dk and os.path.isdir(p) and dk not in seen:
                found.append((p, dk)); seen.add(dk)
    return found


def pick_folder_gui():
    try:
        import tkinter as tk
        from tkinter import filedialog
        r = tk.Tk()
        r.withdraw()
        r.attributes("-topmost", True)
        path = filedialog.askdirectory(title="پوشه‌ی پروژه (حاوی engines و prereqs) را انتخاب کنید")
        r.destroy()
        return path or None
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser(description="Build manifest.txt for MTunnel engines and prereqs")
    ap.add_argument("folders", nargs="*", help="پوشه‌ی پروژه، یا خود engines / prereqs")
    ap.add_argument("-r", "--recursive", action="store_true",
                    help="همه‌ی پوشه‌های engines و prereqs را در زیرپوشه‌ها پیدا کن")
    ap.add_argument("--check", action="store_true",
                    help="فقط manifest.txt موجود را با فایل‌ها مقایسه کن")
    args = ap.parse_args()

    interactive = False
    folders = args.folders
    if not folders:
        picked = pick_folder_gui() or input("مسیر پوشه را وارد کنید: ").strip().strip('"')
        if not picked:
            print("پوشه‌ای انتخاب نشد."); return 1
        folders, interactive = [picked], True

    rc, done = 0, 0
    for root in folders:
        if not os.path.isdir(root):
            print("پوشه پیدا نشد: %s" % root); rc = 1; continue
        targets = find_targets(root, args.recursive)
        if not targets:
            print("در %s پوشه‌ای به نام engines یا prereqs پیدا نشد." % root); rc = 1; continue
        for d, kind in targets:
            res = process(d, kind, args.check)
            if res is None:
                continue
            done += 1
            if res is False:
                rc = 1
    if done == 0:
        rc = 1
    if interactive and os.name == "nt":
        input("\nبرای خروج Enter بزنید...")
    return rc


if __name__ == "__main__":
    sys.exit(main())
