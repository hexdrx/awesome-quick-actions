#!/bin/zsh
# Install the QR Quick Action into ~/Library/Services
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Services"
mkdir -p "$DEST"

echo "Installing QR.workflow…"
rm -rf "$DEST/QR.workflow"
cp -R "$DIR/QR.workflow" "$DEST/QR.workflow"

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
killall iconservicesagent 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "✅ Installed. Right-click any file/image in Finder → Quick Actions → QR"
