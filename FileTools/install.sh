#!/bin/zsh
# Install the File Tools Quick Action into ~/Library/Services
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Services"
mkdir -p "$DEST"

echo "Installing FileTools.workflow…"
rm -rf "$DEST/FileTools.workflow"
cp -R "$DIR/FileTools.workflow" "$DEST/FileTools.workflow"

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
killall iconservicesagent 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "✅ Installed. Right-click any file/folder in Finder → Quick Actions → File Tools"
