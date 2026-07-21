#!/bin/zsh
# Install the ZIP Quick Action into ~/Library/Services
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Services"
mkdir -p "$DEST"

echo "Installing ZIP.workflow…"
rm -rf "$DEST/ZIP.workflow"
cp -R "$DIR/ZIP.workflow" "$DEST/ZIP.workflow"

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
killall iconservicesagent 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "✅ Installed. Right-click file(s)/folder(s) in Finder → Quick Actions → ZIP"
