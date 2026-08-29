# Awesome Quick Actions

A small collection of polished **macOS Finder Quick Actions** — the items that appear when you right-click a file or folder under **Quick Actions**. Each one is a self-contained `.workflow` bundle you can install with one command (or a double-click).

| Action | What it does | Engine |
|--------|--------------|--------|
| 🪄 **[Convert](Convert/)** | Right-click any image / audio / video → pick a target format from a native dropdown → converted file appears next to the original. Batch, per-type menus for mixed selections, a resolution picker for video, a live progress bar, and collision-safe names. | `sips` (images) + `ffmpeg` (A/V) |
| 🗄️ **[ZIP](ZIP/)** | Right-click file(s)/folder(s) → zipped with `zip -r`. One item → its own `.zip`; many → prompts for one archive name. No macOS junk (`__MACOSX`, `.DS_Store`), never overwrites. | `zip` (built-in) |
| 🧰 **[File Tools](FileTools/)** | Right-click any file/folder → one menu: **Copy path** (POSIX / `file://` / name), **Checksum** (SHA-256/1, MD5, verify), **New file here**, **Rename batch** (prefix/suffix/numbering/replace). Collision-safe, no dependencies. | built-in (`shasum`, `pbcopy`, `mv`…) |
| ▪️ **[QR](QR/)** | No menu — click an **image with a QR** and it's decoded automatically (text → clipboard, http/https opens in the browser); click a **text file** (`.txt`/`.md`/…) and its contents become a QR; click anything else and you **type** what to encode. Plus **QR из текста**: select text in *any* app → Services → it's encoded on the spot. Generated codes land **in the clipboard as an image** and open in Preview to copy/share. No dependencies. | built-in (CoreImage + Vision) |
| 🎙️ **[Transcribe](Transcribe/)** | Right-click audio/video → pick **Русский** or **English** → a `.txt` transcript appears next to the original. English runs on Apple's on-device recognizer; Russian on GigaAM v3 with punctuation and capitalization. Batch, progress bar, collision-safe names. | Apple Speech (EN) + sherpa-onnx / GigaAM v3 (RU) |

Each action has a **custom icon** in the right-click menu and adapts to light/dark mode.

---

## Requirements

- **macOS** (built with Automator services; tested on Apple Silicon, macOS 15/26).
- **Convert only:** [`ffmpeg`](https://ffmpeg.org) for audio/video (`sips` for images is built in):
  ```sh
  brew install ffmpeg
  ```
  The action auto-detects `ffmpeg` in `/opt/homebrew/bin`, `/usr/local/bin` (Intel), `/opt/local/bin` (MacPorts), or your `PATH`.
- **Transcribe only:** macOS 26+ (for the English engine) and `ffmpeg`. The Russian model (~277 MB) downloads itself on first use.

## Install

**Everything at once:**
```sh
git clone https://github.com/hexdrx/awesome-quick-actions.git
cd awesome-quick-actions
./install.sh
```

**Just one action:**
```sh
./Convert/install.sh      # or
./ZIP/install.sh
./FileTools/install.sh
./QR/install.sh
./Transcribe/install.sh
```

**No terminal?** Double-click `Convert/Convert.workflow` (or any other `*.workflow`) in Finder and confirm **Install**. They land in `~/Library/Services/`.

> After installing, right-click a file in Finder → **Quick Actions** (or the **⚙︎ Quick Actions** menu). **QR из текста** is not a Finder action — select text in any app and look under **Services**. If an action doesn't show up immediately, re-open the menu or log out/in once.

## Uninstall

```sh
./uninstall.sh
```
…or just delete the matching bundles in `~/Library/Services/` (`Convert.workflow`, `ZIP.workflow`, `FileTools.workflow`, `QR.workflow`, `QRText.workflow`, `Transcribe.workflow`).

---

## Repo layout

```
awesome-quick-actions/
├── Convert/
│   ├── Convert.workflow/     # the installable bundle
│   ├── src/convert.applescript   # readable source (embedded in the bundle)
│   ├── install.sh
│   └── README.md
├── ZIP/
│   ├── ZIP.workflow/
│   ├── src/zip.sh
│   ├── install.sh
│   └── README.md
├── FileTools/                # Copy path / Checksum / New file / Rename batch
├── QR/                       # QR.workflow (Finder: create/decode) + QRText.workflow (Services: selected text → QR)
├── Transcribe/               # Audio/video → .txt: Apple Speech (EN) + sherpa-onnx / GigaAM v3 (RU)
├── install.sh                # installs all of them
└── uninstall.sh
```

The `src/` files are the **human-readable** version of the code that lives inside each `.workflow`. If you edit them, see each action's README for how to re-embed and reinstall.

## Notes

- The in-app dialogs (format pickers, prompts) are in **Russian** — trivial to change in the `src/` files.
- Custom menu icons use the documented `workflowCustomImageTemplate.png` + `NSIconName` trick — see each README. Credit: [Eternal Storms Software](https://eternalstorms.wordpress.com/2018/10/19/developer-tip-custom-icons-for-quick-actions/).

## License

MIT — see [LICENSE](LICENSE).
