#!/usr/bin/env bash
set -euo pipefail

echo "==> Creating a 'bare' clone of the upstream repo..."

HASH="$(echo "$1" | sha256sum | awk '{print $1}')"
git clone --bare "$1" ".${HASH}"

echo " "
echo "==> Pushing repo in 'mirror' mode to new upsteam..."

cd ".${HASH}" && git push --force --mirror "$2"

echo ""
echo "Done."
