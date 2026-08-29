#!/bin/zsh
# Install the QR Quick Actions into ~/Library/Services
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Services"
mkdir -p "$DEST"

for wf in QR.workflow QRText.workflow; do
  echo "Installing $wf…"
  rm -rf "$DEST/$wf"
  cp -R "$DIR/$wf" "$DEST/$wf"
done

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
killall iconservicesagent 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "✅ Installed."
echo "   • Finder: right-click any file/image → Quick Actions → QR"
echo "   • Anywhere: select text → Services → QR из текста"
