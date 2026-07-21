# 🪄 Convert

A Finder Quick Action that converts **images, audio, and video** in place. Right-click file(s) → **Quick Actions → Convert** → choose a target format in a native dropdown. The result is written **next to the original** with a collision-safe name.

## Features

- **Auto-detects the file type** and shows only the relevant target formats.
- **Batch:** select many files of one type → asked for the format **once**, converts all.
- **Mixed selections:** pick images + audio + video together → one menu **per type**.
- **Video resolution picker:** after choosing a video format — Original / 480p / 720p / 1080p / 2K / 4K / custom (`1280x720` or just a height).
- **Live progress bar** with the current filename and an `N / M` counter.
- **Never overwrites:** `file.jpg`, `file 2.jpg`, `file 3.jpg`, …
- Finishes with a notification.

## Supported formats

| Input type | Convert to |
|-----------|------------|
| **Images** (`sips`) | PNG · JPEG · HEIC · TIFF · GIF · BMP · PDF |
| **Audio** (`ffmpeg`) | MP3 · M4A (AAC) · WAV · FLAC · AIFF · OGG (Opus) |
| **Video** (`ffmpeg`) | MP4 (H.264) · MOV · WEBM (VP9) · MKV · GIF · + extract audio → MP3 / M4A |

AMR (`.amr`, `.awb`, `.3ga`) phone recordings are recognized as audio and decode fine (e.g. AMR → WAV).

Defaults: H.264 CRF 23 / audio ~192 kbps — a balanced quality/size preset.

## Requirements

- `sips` — built into macOS (images work out of the box).
- [`ffmpeg`](https://ffmpeg.org) for audio/video: `brew install ffmpeg`.
  Auto-detected in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, or `PATH`.

## Install

```sh
./install.sh
```
or double-click `Convert.workflow` in Finder → **Install**.

## Uninstall

```sh
rm -rf ~/Library/Services/Convert.workflow
```

## Customizing

The readable source is [`src/convert.applescript`](src/convert.applescript) (it's embedded inside `Convert.workflow/Contents/document.wflow`). To change formats, quality presets, or the Russian dialog text, edit it and re-embed:

```sh
# 1) validate
osacompile -o /tmp/c.scpt src/convert.applescript

# 2) re-embed into the bundle (round-trips the plist cleanly)
python3 - <<'PY'
import plistlib
wf = "Convert.workflow/Contents/document.wflow"
d = plistlib.load(open(wf,'rb'))
d['actions'][0]['action']['ActionParameters']['source'] = open("src/convert.applescript").read()
plistlib.dump(d, open(wf,'wb'))
PY

# 3) reinstall
./install.sh
```

Or just open `Convert.workflow` in **Automator** and edit the *Run AppleScript* action there.

### Change the menu icon

The context-menu icon is `Convert.workflow/Contents/Resources/workflowCustomImageTemplate.png` (a black-on-transparent **template** PNG; the `Template` suffix makes it adapt to light/dark). Replace it with any glyph and reinstall. To render an SF Symbol to a template PNG:

```sh
osascript -e 'use framework "AppKit"' \
  -e 'set i to current application'\''s NSImage'\''s imageWithSystemSymbolName:"wand.and.stars" accessibilityDescription:(missing value)' \
  -e 'set c to current application'\''s NSImageSymbolConfiguration'\''s configurationWithPointSize:96 weight:0.0 scale:3' \
  -e '(i'\''s imageWithSymbolConfiguration:c)'\''s TIFFRepresentation()'\''s writeToFile:"/tmp/glyph.tiff" atomically:true'
sips -s format png --resampleHeightWidthMax 40 /tmp/glyph.tiff \
  --out Convert.workflow/Contents/Resources/workflowCustomImageTemplate.png
```

`NSIconName` in `Info.plist` must stay `workflowCustomImageTemplate` — the Services loader looks for exactly that name.
