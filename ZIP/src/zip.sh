#!/bin/zsh
# Body of the 'Run Shell Script' action (shell: /bin/zsh, input: as arguments)

excl=(-x "*.DS_Store" -x "*/.DS_Store" -x "__MACOSX*")

notify() { osascript -e "display notification \"$2\" with title \"$1\" sound name \"Glass\""; }

if [ "$#" -eq 1 ]; then
  # ── один объект ──
  dir=$(dirname "$1")
  base=$(basename "$1")

  if [ -d "$1" ]; then
    name="$base"            # папка -> имя целиком (точки не трогаем)
  else
    name="${base%.*}"       # файл -> отрезаем последнее расширение
    [ -z "$name" ] && name="$base"   # подстраховка для ".env" и т.п.
  fi

  ( cd "$dir" && zip -r -X "${name}.zip" "$base" "${excl[@]}" ) \
    && notify "ZIP готов" "${name}.zip"
else
  # ── несколько объектов ──
  dir=$(dirname "$1")
  items=()
  for f in "$@"; do items+=("$(basename "$f")"); done

  name=$(osascript -e 'try
    text returned of (display dialog "Название архива:" default answer "Archive" with title "Упаковать в ZIP" buttons {"Отмена", "OK"} default button "OK")
  on error
    return "___CANCEL___"
  end try')

  [ "$name" = "___CANCEL___" ] && exit 0

  # обрезаем пробелы по краям
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"

  # пусто (или только пробелы) + Enter -> дефолт
  [ -z "$name" ] && name="Archive"
  name=${name%.zip}

  out="${name}.zip"; n=2
  while [ -e "$dir/$out" ]; do out="${name} ${n}.zip"; n=$((n+1)); done

  ( cd "$dir" && zip -r -X "$out" "${items[@]}" "${excl[@]}" ) \
    && notify "ZIP готов" "$# файлов → $out"
fi
