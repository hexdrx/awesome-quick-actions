#!/bin/zsh
# Remove the Quick Actions installed by this repo.
set -e
DEST="$HOME/Library/Services"

rm -rf "$DEST/Convert.workflow" "$DEST/ZIP.workflow"

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "🧹 Removed Convert + ZIP quick actions."
