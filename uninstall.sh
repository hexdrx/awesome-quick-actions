#!/bin/zsh
# Remove the Quick Actions installed by this repo.
set -e
DEST="$HOME/Library/Services"

rm -rf "$DEST/Convert.workflow" "$DEST/ZIP.workflow" "$DEST/FileTools.workflow" "$DEST/QR.workflow" "$DEST/QRText.workflow" "$DEST/Transcribe.workflow"

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "🧹 Removed Convert + ZIP + File Tools + QR + Transcribe quick actions."
echo "Note: Transcribe's Russian model assets (~277 MB) are left in ~/Library/Application Support/AwesomeQuickActions/transcribe — remove that directory manually if you no longer need them."
