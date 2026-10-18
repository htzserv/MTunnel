#!/usr/bin/env bash
# Regenerate SHA256SUMS for every file the OTA updater downloads. Run it as the LAST step of a release,
# then publish SHA256SUMS next to the files on GitHub and on the mirror.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
files=(VERSION install.sh main.sh mporter.sh core/common.sh tunnels/*.sh)
sha256sum "${files[@]}" > SHA256SUMS && echo "SHA256SUMS written (${#files[@]} files)"
