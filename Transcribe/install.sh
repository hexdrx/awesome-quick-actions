#!/bin/zsh
# Install the Transcribe Quick Action into ~/Library/Services
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Services"
mkdir -p "$DEST"

echo "Installing Transcribe.workflow…"
rm -rf "$DEST/Transcribe.workflow"
cp -R "$DIR/Transcribe.workflow" "$DEST/Transcribe.workflow"
chmod +x "$DEST/Transcribe.workflow/Contents/Resources/transcribe-en"
chmod +x "$DEST/Transcribe.workflow/Contents/Resources/fetch-ru-assets.sh"

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
killall iconservicesagent 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "✅ Installed. Right-click audio/video in Finder → Quick Actions → Transcribe"
