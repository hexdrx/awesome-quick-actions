#!/bin/zsh
# Install the Convert Quick Action into ~/Library/Services
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Services"
mkdir -p "$DEST"

echo "Installing Convert.workflow…"
rm -rf "$DEST/Convert.workflow"
cp -R "$DIR/Convert.workflow" "$DEST/Convert.workflow"

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
killall iconservicesagent 2>/dev/null || true
killall Finder 2>/dev/null || true

if ! command -v ffmpeg >/dev/null 2>&1 \
   && [ ! -x /opt/homebrew/bin/ffmpeg ] \
   && [ ! -x /usr/local/bin/ffmpeg ] \
   && [ ! -x /opt/local/bin/ffmpeg ]; then
  echo "⚠️  ffmpeg not found — audio/video conversion needs it:  brew install ffmpeg"
  echo "    (images via sips work without it)"
fi

echo "✅ Installed. Right-click an image/audio/video in Finder → Quick Actions → Convert"
