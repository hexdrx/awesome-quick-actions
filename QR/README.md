# QR

Two **Quick Actions** for QR codes — generate and decode, both native, **zero dependencies**.

## QR — right-click a file in Finder

Right-click any file/image → **Quick Actions → QR**. There's **no menu** — the action decides what to do from what you selected:

| You right-click… | What happens |
|-----------|--------------|
| **An image containing a QR** | Detected automatically, no prompt. The decoded text/URL is copied to the clipboard and shown in a dialog. If it's an **http/https** link it opens **silently in your default browser**. |
| **A plain-text file** (`.txt`, `.md`, `.csv`, `.json`, `.xml`, `.yaml`, `.log`, …) | Its contents are read and turned into a QR straight away, no prompt. |
| **An image with no QR**, or **anything else** | Falls through to **create**: prompts for text or a URL (pre-filled from the clipboard), generates the QR, puts it **in the clipboard as an image** (paste straight into Notes/Messages/Mail) **and** opens it in **Preview** to copy or share. Saving a file is optional — Preview's *Save As* handles it. |

So: click a screenshot with a QR → you get its contents; click a text file → its text becomes a QR; click anything else → you type what to encode.

## QR из текста — select text in any app

Select text anywhere — Safari, Notes, TextEdit, Mail, Terminal — and pick **Services → QR из текста** (right-click, or the app menu → Services). The selection is encoded straight away, no prompt: the QR lands **in the clipboard as an image** and opens in **Preview**.

This is a separate bundle (`QRText.workflow`) because a service takes *either* files *or* text, never both: it declares `NSSendTypes` instead of `NSSendFileTypes` and drops `NSRequiredContext`, which is what makes it show up outside Finder. Generation is the same code as above.

Nothing interrupts you when it can't encode: an empty selection or text past the QR capacity just posts a notification.

> Multi-line selections are encoded as-is. If the item is missing from a given app's Services menu, enable it in **System Settings → Keyboard → Keyboard Shortcuts… → Services → Text**.

Error-correction level is **L** (max data capacity — a single QR tops out around **2953 bytes / ~2900 chars**, or 7089 digits). Change `inputCorrectionLevel` in `src/qr.applescript` to `H` if you'll print the code or drop a logo in the center.

No external dependencies — uses only built-in macOS frameworks: **CoreImage** (`CIQRCodeGenerator`) to generate, **Vision** (`VNDetectBarcodesRequest`) to decode, **NSPasteboard** for the clipboard. Nothing to `brew install`.

## Install

```sh
./install.sh          # installs both bundles
```
…or double-click `QR.workflow` / `QRText.workflow` in Finder and confirm **Install**.

## Uninstall

```sh
rm -rf ~/Library/Services/QR.workflow ~/Library/Services/QRText.workflow
```

## Requirements

macOS only. Generation/decoding use system frameworks available out of the box — no Homebrew, no Python, no `qrencode`.

## Editing the code

The real sources are `src/qr.applescript` (Finder) and `src/qr-text.applescript` (text selection). Each `.workflow` bundle embeds a **copy** of its script, and the two share the same `makeQR` / `deliver` / `savePNG` — change one, change the other. After editing a src, sanity-check and re-embed:

```sh
osacompile -o /tmp/qr.scpt QR/src/qr.applescript           # catches syntax / reserved-word errors
osacompile -o /tmp/qrt.scpt QR/src/qr-text.applescript
```

```python
# re-embed a src into its bundle
import plistlib
for wf, src in [("QR/QR.workflow", "QR/src/qr.applescript"),
                ("QR/QRText.workflow", "QR/src/qr-text.applescript")]:
    doc = wf + "/Contents/document.wflow"
    d = plistlib.load(open(doc, 'rb'))
    d['actions'][0]['action']['ActionParameters']['source'] = open(src).read()
    plistlib.dump(d, open(doc, 'wb'))
```

Then `./install.sh`.

> **Note:** the code uses AppleScript's Objective-C bridge. Selector labels that collide with AppleScript keywords must be escaped with pipes (`|properties|:`, `|results|()`, `|size|()`, `|error|:`), and variables must avoid reserved words (`offset`, `text`, `file`, …) — those compile but crash at runtime (`-10006`).

## Change the menu icon

The menu icon is `Contents/Resources/workflowCustomImageTemplate.png` in each bundle — a black-on-transparent **template** PNG (macOS adapts it to light/dark). Both bundles ship the same `qrcode` glyph. Regenerate it from any SF Symbol:

```sh
osascript -e 'use framework "AppKit"' \
  -e 'set i to current application'\''s NSImage'\''s imageWithSystemSymbolName:"qrcode" accessibilityDescription:(missing value)' \
  -e 'set c to current application'\''s NSImageSymbolConfiguration'\''s configurationWithPointSize:96 weight:0.0 scale:3' \
  -e '(i'\''s imageWithSymbolConfiguration:c)'\''s TIFFRepresentation()'\''s writeToFile:"/tmp/glyph.tiff" atomically:true'
sips -s format png --resampleHeightWidthMax 40 /tmp/glyph.tiff \
  --out QR.workflow/Contents/Resources/workflowCustomImageTemplate.png
```

…then copy the result into `QRText.workflow` too. `NSIconName` in `Info.plist` must stay `workflowCustomImageTemplate`.
