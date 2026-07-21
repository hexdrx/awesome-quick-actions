#!/bin/zsh
# Install all Quick Actions in this repo.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

"$DIR/Convert/install.sh"
"$DIR/ZIP/install.sh"
"$DIR/FileTools/install.sh"

echo
echo "🎉 All done. Open Finder, right-click a file → Quick Actions."
