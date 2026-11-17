#!/bin/sh
# Copies the backend package into the Worker bundle (wrangler runs this before dev/deploy).
# Only runtime modules: no CLI tools, caches or tests.
set -eu
cd "$(dirname "$0")"
rm -rf src/app
mkdir -p src/app
for f in ../app/*.py; do
  case "$(basename "$f")" in tools.py) continue ;; esac
  cp "$f" src/app/
done
