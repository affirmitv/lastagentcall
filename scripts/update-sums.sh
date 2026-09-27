#!/bin/sh
# Regenerates SHA256SUMS for the files install.sh and uninstall.sh download.
# Run after changing any of them; tests/test_install.sh fails if it is stale.
set -e
cd "$(dirname "$0")/.."
shasum -a 256 bin/lastcall-hook.sh app/LastCall.swift scripts/settings.py > SHA256SUMS
