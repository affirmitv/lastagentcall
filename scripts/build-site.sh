#!/bin/sh
# Copies the installable files next to index.html so the site serves them.
# bin/lastcall-hook.sh is NOT copied: /bin/lastcall-hook.sh is served by
# api/hook.js (see vercel.json), which counts installer runs. A static copy
# would win over the rewrite and the count would stop.
set -e
cd "$(dirname "$0")/.."
mkdir -p site/app site/scripts
rm -f site/bin/lastcall-hook.sh
cp install.sh uninstall.sh SHA256SUMS site/
cp app/LastCall.swift site/app/
cp scripts/settings.py site/scripts/
