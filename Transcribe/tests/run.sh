#!/bin/bash
# Run every test_*.sh in this directory.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$HERE"/test_*.sh; do
  echo "--- $(basename "$t")"
  "$t" || rc=1
done
exit $rc
