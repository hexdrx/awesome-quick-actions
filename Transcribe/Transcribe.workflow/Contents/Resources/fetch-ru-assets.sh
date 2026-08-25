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

# `read` returns nonzero at EOF on a final line lacking a trailing newline,
# so the while-loop below would silently drop that last row. Fail loudly
# instead of quietly losing an asset row (Task 8 hand-edits this file).
if [ -s "$MANIFEST" ] && [ -n "$(tail -c1 "$MANIFEST")" ]; then
  err "манифест должен заканчиваться переводом строки: $MANIFEST"
fi

mkdir -p "$ASSET_DIR" || err "не удалось создать каталог: $ASSET_DIR"

# --- own-process temp file cleanup on graceful exit / Ctrl-C / TERM ---
# Covers normal `set -e` aborts, INT, and TERM. Never touches a bare glob:
# only ever the single $$-suffixed path this process itself is using right
# now, so a concurrently running process's own download is untouched.
CURRENT_TMP=""
cleanup_tmp() {
  ec=$?
  [ -n "$CURRENT_TMP" ] && rm -f -- "$CURRENT_TMP"
  exit $ec
}
trap cleanup_tmp EXIT INT TERM

# --- stale-orphan sweep (handles the case a trap cannot: SIGKILL, a crash,
# a force-quit) ---
# A bare `*.part` sweep would also delete a concurrently running process's
# in-progress download, reintroducing the race the unique name closed. Sweep
# by liveness instead: a *.part is only removed if no process with the PID
# embedded in its name exists. PID reuse can rarely make a stale file look
# live; it just survives one more cycle, which is harmless.
for f in "$ASSET_DIR"/*.part(N); do
  pid="${f%.part}"
  pid="${pid##*.}"
  case "$pid" in
    ''|*[!0-9]*) continue ;;  # not a PID-suffixed name we recognize; leave it alone
  esac
  kill -0 "$pid" 2>/dev/null || rm -f -- "$f"
done

typeset -a SHAS NAMES URLS
while read -r sha name url; do
  case "$sha" in ''|'#'*) continue ;; esac
  # Defensively strip a trailing CR in case the manifest was saved as CRLF.
  sha="${sha%$'\r'}"; name="${name%$'\r'}"; url="${url%$'\r'}"
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
  # Unique per process: a fixed name would let two overlapping runs (e.g.
  # the action triggered twice) race on the same .part path, letting one
  # process's mv install another's half-written bytes under a name that
  # was just verified. The rename below is already atomic; a unique name
  # removes the race with no lock needed.
  tmp="$ASSET_DIR/$name.$$.part"
  CURRENT_TMP="$tmp"
  rm -f "$tmp"
  note "PROGRESS download $done_n $n $name"
  curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url" || { rm -f "$tmp"; err "не удалось скачать $name"; }
  got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    err "контрольная сумма не совпала: $name"
  fi
  # Only transcribe-ru is an executable; the model/VAD files don't need +x.
  if [ "$name" = "transcribe-ru" ]; then
    chmod +x "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$ASSET_DIR/$name"
  CURRENT_TMP=""
  done_n=$((done_n + 1))
  note "PROGRESS download $done_n $n $name"
done
exit 0
