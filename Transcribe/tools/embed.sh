#!/bin/zsh
# Embed src/transcribe.applescript into the bundle and stage its resources.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
WF="$DIR/Transcribe.workflow"
RES="$WF/Contents/Resources"

[ -x "$DIR/bin/transcribe-en" ] || { echo "run tools/build.sh first" >&2; exit 1; }

mkdir -p "$RES"
cp "$DIR/bin/transcribe-en" "$RES/transcribe-en"
cp "$DIR/src/fetch-ru-assets.sh" "$RES/fetch-ru-assets.sh"
cp "$DIR/assets.manifest" "$RES/assets.manifest"
chmod +x "$RES/transcribe-en" "$RES/fetch-ru-assets.sh"

python3 - "$WF/Contents/document.wflow" "$DIR/src/transcribe.applescript" <<'PY'
import plistlib, sys, os
wflow, src = sys.argv[1], sys.argv[2]
with open(src, encoding='utf-8') as f:
    source = f.read()
if os.path.exists(wflow):
    with open(wflow, 'rb') as f:
        doc = plistlib.load(f)
else:
    doc = {
        'AMApplicationBuild': '523', 'AMApplicationVersion': '2.10',
        'AMDocumentVersion': '2',
        'actions': [{'action': {
            'ActionBundlePath': '/System/Library/Automator/Run AppleScript.action',
            'ActionName': 'Run AppleScript',
            'ActionParameters': {'source': ''},
            'BundleIdentifier': 'com.apple.Automator.RunScript',
            'CFBundleVersion': '1.0',
            'Class Name': 'RunScriptAction',
            'InputUUID': '00000000-0000-0000-0000-000000000001',
            'OutputUUID': '00000000-0000-0000-0000-000000000002',
            'UUID': '00000000-0000-0000-0000-000000000003',
        }}],
        'workflowMetaData': {
            'serviceInputTypeIdentifier': 'com.apple.Automator.fileSystemObject',
            'serviceOutputTypeIdentifier': 'com.apple.Automator.nothing',
            'serviceApplicationBundleID': 'com.apple.finder',
            'serviceApplicationPath': '/System/Library/CoreServices/Finder.app',
            'workflowTypeIdentifier': 'com.apple.Automator.servicesMenu',
        },
    }
doc['actions'][0]['action']['ActionParameters']['source'] = source
with open(wflow, 'wb') as f:
    plistlib.dump(doc, f)
print("embedded", len(source), "chars")
PY
