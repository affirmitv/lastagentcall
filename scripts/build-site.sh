#!/bin/sh
# Copies the installable files next to index.html so the site serves them.
set -e
cd "$(dirname "$0")/.."
mkdir -p site/bin site/app site/scripts
cp install.sh uninstall.sh site/
cp bin/lastcall-hook.sh site/bin/
cp app/LastCall.swift site/app/
cp scripts/settings.py site/scripts/
