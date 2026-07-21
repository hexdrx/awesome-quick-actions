# 🗄️ ZIP

A Finder Quick Action that zips the selected file(s)/folder(s) with `zip -r` — cleaner than the stock **Compress**.

## Features

- **One item selected** → its own archive next to it: `photo.png` → `photo.zip` (a folder keeps its full name).
- **Several items** → prompts for **one** archive name and packs them all together.
- **No macOS junk:** `-X` drops resource forks so there's no `__MACOSX/` or `._` files; `.DS_Store` is excluded too.
- **Never overwrites:** `Archive.zip`, `Archive 2.zip`, …
- Trims stray whitespace, defaults an empty name to `Archive`, strips a redundant `.zip` you might type.
- Finishes with a notification.

## Install

```sh
./install.sh
```
or double-click `ZIP.workflow` in Finder → **Install**.

## Uninstall

```sh
rm -rf ~/Library/Services/ZIP.workflow
```

## Requirements

None — `zip` ships with macOS.

## Customizing

The readable source is [`src/zip.sh`](src/zip.sh) — it's the body of the *Run Shell Script* action (shell `/bin/zsh`, input **as arguments**) inside `ZIP.workflow/Contents/document.wflow`.

To edit, change `src/zip.sh` and re-embed:

```sh
python3 - <<'PY'
import plistlib
wf = "ZIP.workflow/Contents/document.wflow"
d = plistlib.load(open(wf,'rb'))
# strip the shebang/comment header we added for readability
body = "".join(l for l in open("src/zip.sh") if not l.startswith("#!") ).lstrip("\n")
d['actions'][0]['action']['ActionParameters']['COMMAND_STRING'] = body
plistlib.dump(d, open(wf,'wb'))
PY
./install.sh
```

Or open `ZIP.workflow` in **Automator** and edit the *Run Shell Script* action.

### Change the menu icon

Same mechanism as Convert: replace `ZIP.workflow/Contents/Resources/workflowCustomImageTemplate.png` (template PNG) and keep `NSIconName = workflowCustomImageTemplate`. This one ships with the `doc.zipper` SF Symbol.
