#!/bin/zsh
# Ensure the Russian assets are present and intact.
# PROGRESS/ERROR on stderr; nothing on stdout.
# Env: ASSET_DIR (override target), MANIFEST (override manifest path),
#      VERIFY_ONLY=1 (check, never download).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve the manifest: env override first, then same-directory (installed
# layout: script and manifest copied flat into Contents/Resources/), then
# parent directory (repo layout: script in Transcribe/src/, manifest in
# Transcribe/).
if [ -n "${MANIFEST:-}" ]; then
  :
elif [ -f "$DIR/assets.manifest" ]; then
  MANIFEST="$DIR/assets.manifest"
else
  MANIFEST="$DIR/../assets.manifest"
fi

ASSET_DIR="${ASSET_DIR:-$HOME/Library/Application Support/AwesomeQuickActions/transcribe}"

err() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

[ -f "$MANIFEST" ] || err "манифест не найден: $MANIFEST"
mkdir -p "$ASSET_DIR"

typeset -a SHAS NAMES URLS
while read -r sha name url; do
  case "$sha" in ''|'#'*) continue ;; esac
  SHAS+=("$sha"); NAMES+=("$name"); URLS+=("$url")
done < "$MANIFEST"

total=${#NAMES[@]}
[ "$total" -gt 0 ] || err "манифест пуст"

typeset -a MISSING_I
for i in {1..$total}; do
  f="$ASSET_DIR/${NAMES[$i]}"
  if [ -f "$f" ] && [ "$(shasum -a 256 "$f" | awk '{print $1}')" = "${SHAS[$i]}" ]; then
    continue
  fi
  MISSING_I+=($i)
done

if [ ${#MISSING_I[@]} -eq 0 ]; then exit 0; fi

if [ "${VERIFY_ONLY:-0}" = "1" ]; then
  err "отсутствуют или повреждены: ${#MISSING_I[@]} файл(ов)"
fi

done_n=0
n=${#MISSING_I[@]}
for i in $MISSING_I; do
  name="${NAMES[$i]}"; url="${URLS[$i]}"; want="${SHAS[$i]}"
  tmp="$ASSET_DIR/$name.part"
  rm -f "$tmp"
  note "PROGRESS download $done_n $n $name"
  curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url" || { rm -f "$tmp"; err "не удалось скачать $name"; }
  got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    err "контрольная сумма не совпала: $name"
  fi
  chmod +x "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$ASSET_DIR/$name"
  done_n=$((done_n + 1))
  note "PROGRESS download $done_n $n $name"
done
exit 0
