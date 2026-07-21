# File Tools

A single Finder **Quick Action** bundling four file/text utilities behind one menu. Right-click file(s) or folder(s) → **Quick Actions → File Tools** → pick an operation:

| Operation | What it does |
|-----------|--------------|
| **Copy path** | Copies the selection's path(s) to the clipboard — `POSIX path`, `file:// URL`, or name only. Multiple items → one per line. |
| **Checksum** | SHA-256 / SHA-1 / MD5. *Посчитать* → hash(es) to clipboard; *Сверить* → paste an expected hash and get a ✅/❌ match. Folders skipped. |
| **New file here** | Creates a new file (any extension) in the target folder — the selected folder, or the parent of the selection. Collision-safe. |
| **Rename batch** | Prefix / suffix / numbering (`Photo ###` → `Photo 001…`) / substring replace, over the whole selection. Collision-safe; folders too. |

No external dependencies — uses only built-in macOS tools (`shasum`, `md5`, `pbcopy`, `touch`, `mv`, `perl`).

## Install

```sh
./install.sh
```
…or double-click `FileTools.workflow` in Finder and confirm **Install**.

## Editing the code

The real source is `src/filetools.applescript`. The `.workflow` bundle embeds a **copy** of it. After editing the src, re-embed and reinstall:

```sh
zsh test/filetools_test.sh        # run unit tests
# regenerate the embedded copy (see plan Task 8 Step 3), then:
./install.sh
```
