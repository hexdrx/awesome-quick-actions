#!/bin/zsh
# Embed src/transcribe.applescript into the bundle and stage its resources.
#
# If Contents/document.wflow already exists, only its ActionParameters.source
# is replaced -- everything else (UUIDs, AMAccepts/AMProvides, Category,
# Keywords, arguments, isViewVisible, location, nibPath, workflowMetaData)
# is preserved untouched.
#
# If it does NOT exist (a from-scratch / cold regeneration -- e.g. the file
# was deleted and this script is run to rebuild it), a complete document is
# generated instead of a minimal one. It must be behaviorally equivalent to
# a real Automator-exported document in every key that affects runtime
# behavior -- CanShowWhenRun above all: the AppleScript drives its progress
# window via `set progress total steps` / `set progress completed steps`,
# and that window is gated by this key. A thinner fallback would silently
# ship a Quick Action with no progress bar. See Transcribe/tests/
# test_embed_fallback.sh, which exercises this exact path.
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

# Fresh per-action UUIDs for a from-scratch document, so a bundle copied
# from this one (the way this one was originally seeded from QR's) does not
# inherit identifiers already in use by another shipped Quick Action.
INPUT_UUID="$(uuidgen)"
OUTPUT_UUID="$(uuidgen)"
ACTION_UUID="$(uuidgen)"

INPUT_UUID="$INPUT_UUID" OUTPUT_UUID="$OUTPUT_UUID" ACTION_UUID="$ACTION_UUID" \
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
        'AMApplicationBuild': '534',
        'AMApplicationVersion': '2.10',
        'AMDocumentVersion': '2',
        'actions': [{
            'action': {
                'AMAccepts': {
                    'Container': 'List',
                    'Optional': True,
                    'Types': ['com.apple.applescript.object'],
                },
                'AMActionVersion': '1.0.2',
                'AMApplication': ['Automator'],
                'AMParameterProperties': {'source': {}},
                'AMProvides': {
                    'Container': 'List',
                    'Types': ['com.apple.applescript.object'],
                },
                'ActionBundlePath': '/System/Library/Automator/Run AppleScript.action',
                'ActionName': 'Run AppleScript',
                'ActionParameters': {'source': ''},
                'BundleIdentifier': 'com.apple.Automator.RunScript',
                'CFBundleVersion': '1.0.2',
                # Gates the progress window the AppleScript drives via
                # `set progress total steps` / `set progress completed
                # steps`. Without this, the Quick Action would run with no
                # visible progress bar -- the single most important key in
                # this fallback.
                'CanShowWhenRun': True,
                'CanShowSelectedItemsWhenRun': False,
                'Category': ['AMCategoryUtilities'],
                'Class Name': 'RunScriptAction',
                'InputUUID': os.environ['INPUT_UUID'].upper(),
                'Keywords': ['Run'],
                'OutputUUID': os.environ['OUTPUT_UUID'].upper(),
                'UUID': os.environ['ACTION_UUID'].upper(),
                'UnlocalizedApplications': ['Automator'],
                'arguments': {
                    '0': {
                        'default value': '',
                        'name': 'source',
                        'required': '0',
                        'type': '0',
                        'uuid': '0',
                    },
                },
                'isViewVisible': 1,
                'location': '309.000000:305.000000',
                'nibPath': '/System/Library/Automator/Run AppleScript.action/Contents/Resources/Base.lproj/main.nib',
            },
            'isViewVisible': 1,
        }],
        'connectors': {},
        'workflowMetaData': {
            'applicationBundleID': 'com.apple.finder',
            'applicationBundleIDsByPath': {
                '/System/Library/CoreServices/Finder.app': 'com.apple.finder',
            },
            'applicationPath': '/System/Library/CoreServices/Finder.app',
            'applicationPaths': ['/System/Library/CoreServices/Finder.app'],
            'inputTypeIdentifier': 'com.apple.Automator.fileSystemObject',
            'outputTypeIdentifier': 'com.apple.Automator.nothing',
            'presentationMode': 15,
            'processesInput': False,
            'serviceApplicationBundleID': 'com.apple.finder',
            'serviceApplicationPath': '/System/Library/CoreServices/Finder.app',
            'serviceInputTypeIdentifier': 'com.apple.Automator.fileSystemObject',
            'serviceOutputTypeIdentifier': 'com.apple.Automator.nothing',
            'serviceProcessesInput': False,
            'systemImageName': 'waveform',
            'useAutomaticInputType': False,
            'workflowTypeIdentifier': 'com.apple.Automator.servicesMenu',
        },
    }
doc['actions'][0]['action']['ActionParameters']['source'] = source
with open(wflow, 'wb') as f:
    plistlib.dump(doc, f)
print("embedded", len(source), "chars")
PY
