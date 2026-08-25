-- Transcribe — Finder Quick Action (readable source; embedded copy lives in the .workflow)
-- English: Apple SpeechTranscriber (macOS 26+). Russian: sherpa-onnx + GigaAM v3.
-- Requires ffmpeg.

use framework "Foundation"
use framework "AppKit"
use scripting additions

property gDone : 0
property gUIResult : "FAILED"
property gUICount : 0

on run {input, parameters}
	set FF to my findFFmpeg()
	if FF is missing value then
		display alert "ffmpeg не найден" message "Установи ffmpeg: brew install ffmpeg" & return & "(искал в /opt/homebrew/bin, /usr/local/bin, /opt/local/bin и PATH)." as warning
		return input
	end if

	-- Inside an Automator service, `path to me` resolves to Automator's own
	-- runner stub, not the .workflow bundle — every bundled resource would
	-- otherwise become unreachable only once actually installed. Fail loudly
	-- here rather than let that surface later as a confusing missing-file error.
	set resDir to my resourceDir()
	if resDir is missing value then
		display alert "Не найдены ресурсы Quick Action" message "Не удалось найти папку Resources ни в " & (POSIX path of (path to home folder)) & "Library/Services/Transcribe.workflow/Contents/Resources, ни рядом со скриптом." & return & "Переустанови Quick Action «Transcribe»." as warning
		return input
	end if

	set mediaExt to {"mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "ogg", "oga", "opus", "wma", "amr", "mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "m2ts", "ts", "3gp", "ogv"}

	set flist to {}
	repeat with itm in input
		set p to POSIX path of itm
		if p ends with "/" then set p to text 1 thru -2 of p
		if mediaExt contains my extOf(p) then set end of flist to p
	end repeat

	if (count of flist) is 0 then
		display notification "Нет поддерживаемых файлов" with title "Transcribe"
		return input
	end if

	set uiChoice to my askLangAndTimestamps(count flist)
	if uiChoice is missing value then return input
	set lang to lang of uiChoice
	set wantTimestamps to timestamps of uiChoice
	set wantWordTimestamps to wordTimestamps of uiChoice

	-- transcribe-en is built (deliberately) against the macOS 26 SDK with
	-- nothing weak-linked, so on an older system it fails at dyld load
	-- before its own `#available` guard ever runs -- that guard's "нужна
	-- macOS 26 или новее" message is unreachable dead code. Catch this here
	-- instead, before any work (decode, model fetch) is wasted. This matters
	-- because transcribe-ru only needs macOS 14+ and this repo's README
	-- explicitly invites macOS 14 users in for Russian, so a macOS 14 user
	-- has every reason to try English too.
	if lang is "English" and (my majorVersionOf(system version of (system info))) < 26 then
		display alert "Нужна macOS 26 или новее" message "Распознавание английской речи требует macOS 26 (Tahoe) или новее." & return & "Для русской речи достаточно macOS 14+." as warning
		return input
	end if

	set assetDir to (POSIX path of (path to library folder from user domain)) & "Application Support/AwesomeQuickActions/transcribe"

	set totalN to count flist
	set progress total steps to totalN * 2
	set progress completed steps to 0
	set progress description to "Transcribe"
	set progress additional description to "Подготовка…"
	set gDone to 0

	-- Russian needs the model; fetch it before anything else. A cold fetch
	-- downloads ~277 MB, so this needs the same generous timeout as the
	-- engine call below, not the default AppleEvent timeout.
	if lang is "Русский" then
		-- The fetcher re-verifies checksums on every run and exits silently
		-- when nothing is missing or stale; it only becomes an actual
		-- download when it emits its own PROGRESS lines. Don't claim a
		-- download is happening on every single run.
		set progress additional description to "Проверка модели…"
		try
			with timeout of 3600 seconds
				-- assetDir (derived once, above, from the user's Library
				-- folder) is the single source of truth for where assets
				-- live; pass it through explicitly rather than letting the
				-- fetcher independently re-derive it from $HOME.
				do shell script "ASSET_DIR=" & quoted form of assetDir & " " & quoted form of (resDir & "/fetch-ru-assets.sh") & " 2>&1"
			end timeout
		on error errMsg
			-- do shell script hands back the ENTIRE combined output as the
			-- error message on a non-zero exit, so a network drop partway
			-- through can bury the one actionable "ERROR: …" line under a
			-- dozen lines of PROGRESS chatter. Show only the actionable
			-- line(s) when there are any.
			set errLines to my engineErrorLines(errMsg)
			if (count of errLines) > 0 then
				set AppleScript's text item delimiters to return
				set errText to errLines as text
				set AppleScript's text item delimiters to ""
			else
				set errText to errMsg
			end if
			display alert "Не удалось подготовить модель" message errText as warning
			return input
		end try
	end if

	-- Decode everything to 16 kHz mono WAV. One ffmpeg call per file; the
	-- Russian binary does its own segmentation internally.
	set wavs to {}
	set decoded to {}
	set errs to {}
	repeat with p in flist
		set pp to contents of p
		set progress additional description to "Подготовка: " & my baseName(pp)
		set w to "/tmp/transcribe_" & (my randomTag()) & ".wav"
		try
			with timeout of 1800 seconds
				do shell script quoted form of FF & " -nostdin -y -loglevel error -i " & quoted form of pp & " -vn -ac 1 -ar 16000 -c:a pcm_s16le " & quoted form of w
			end timeout
			set end of wavs to w
			set end of decoded to pp
		on error
			-- ffmpeg can die mid-encode (abrupt termination, e.g. the timeout
			-- above firing) and leave a partial multi-megabyte .wav behind. It
			-- was never added to `wavs`, so neither cleanup loop below would
			-- ever see it — remove it here, at the only point that still has
			-- its path.
			try
				do shell script "rm -f " & quoted form of w
			end try
			set end of errs to my baseName(pp) & " — не удалось декодировать"
		end try
		set gDone to gDone + 1
		set progress completed steps to gDone
	end repeat

	if (count of wavs) is 0 then
		display alert "Нечего распознавать" message "Ни один файл не удалось декодировать." as warning
		return input
	end if

	-- One process for the whole batch. do shell script cannot stream, so the
	-- visible bar already advanced per decoded file above and advances again
	-- per written file below; this call itself is one opaque step.
	set progress additional description to "Распознавание…"
	set engineResult to my runEngine(lang, resDir, assetDir, wavs, wantTimestamps, wantWordTimestamps)
	set engStatus to status of engineResult
	set engOut to stdo of engineResult
	set engErr to errp of engineResult

	-- Exit codes are three-valued and mean different things: 0 = every file
	-- succeeded, 1 = ran but some files failed (still write what succeeded),
	-- 2 (or anything else unexpected) = could not start at all — nothing was
	-- produced, so stop rather than write empty/garbage output.
	if engStatus is 0 or engStatus is 1 then
		-- Computed up front so the per-file loop below can suppress the
		-- generic "empty result" message for a file the engine already
		-- explained on stderr — otherwise the same failure shows up twice
		-- in the alert (one vague, one precise). Kept keyed on the TEMP wav
		-- basename here, because that is what the engine actually printed —
		-- it only ever sees the argv path in `wavs`, never the user's
		-- original filename. rewriteErrorLines (used below, once, for
		-- display) is what translates that back to the original name.
		set engErrLines to my engineErrorLines(engErr)

		set okc to 0
		repeat with idx from 1 to (count decoded)
			set txt to my sectionOf(engOut, idx)
			set srcPath to item idx of decoded
			set tempWav to item idx of wavs
			if txt is "" then
				if not (my hasErrorFor(engErrLines, my baseName(tempWav))) then
					set end of errs to my baseName(srcPath) & " — пустой результат"
				end if
			else
				set outp to my uniqueOut(my dirOf(srcPath), my baseOf(srcPath), "txt")
				if my writeUTF8(outp, txt) then
					set okc to okc + 1
				else
					set end of errs to my baseName(srcPath) & " — не удалось записать .txt"
				end if
			end if
			set gDone to gDone + 1
			set progress completed steps to gDone
		end repeat

		-- Surface per-file engine failures that were only reported on stderr.
		-- The engine only ever sees the temp WAV path, so its raw ERROR lines
		-- are keyed on e.g. "transcribe_a1b2c3d4.wav" — meaningless to the
		-- user, and on a multi-file batch, impossible to attribute to a
		-- specific one of their files. Rewrite the leading name back to the
		-- user's original filename before it ever reaches the alert.
		repeat with eLine in my rewriteErrorLines(engErrLines, wavs, decoded)
			set end of errs to contents of eLine
		end repeat

		repeat with w in wavs
			try
				do shell script "rm -f " & quoted form of (contents of w)
			end try
		end repeat

		set progress completed steps to (totalN * 2)

		set msg to (okc as text) & " файл(ов) готово"
		if (count of errs) > 0 then set msg to msg & ", ошибок: " & (count of errs)
		my notify("Transcribe", msg)

		if (count of errs) > 0 then
			set AppleScript's text item delimiters to return
			set etext to errs as text
			set AppleScript's text item delimiters to ""
			display alert "Не всё распозналось" message etext as warning
		end if
	else
		-- Hard failure: the engine could not start at all, nothing was produced.
		repeat with w in wavs
			try
				do shell script "rm -f " & quoted form of (contents of w)
			end try
		end repeat
		set progress completed steps to (totalN * 2)

		-- Same rewrite as the partial-success path: never show a temp WAV
		-- name to the user, even on a hard failure.
		set failLines to my rewriteErrorLines(my engineErrorLines(engErr), wavs, decoded)
		if (count of failLines) > 0 then
			set AppleScript's text item delimiters to return
			set failMsg to failLines as text
			set AppleScript's text item delimiters to ""
		else
			-- The engine died without emitting a single ERROR line at all
			-- (e.g. a crash) -- engineErrorLines found nothing to extract,
			-- so all that is left is the raw stderr blob, which is mostly
			-- PROGRESS chatter meant for the progress bar's own
			-- bookkeeping, never for a human, and may still name a temp
			-- WAV. Strip PROGRESS lines and rewrite any remaining temp
			-- basename before this ever reaches an alert.
			set rawLines to my rewriteErrorLines(my nonProgressLines(engErr), wavs, decoded)
			if (count of rawLines) > 0 then
				set AppleScript's text item delimiters to return
				set failMsg to rawLines as text
				set AppleScript's text item delimiters to ""
			else
				set failMsg to "неизвестная ошибка (код " & (engStatus as text) & ")"
			end if
		end if
		display alert "Не удалось распознать" message failMsg as warning
	end if

	return input
end run

on runEngine(lang, resDir, assetDir, wavs, wantTimestamps, wantWordTimestamps)
	set AppleScript's text item delimiters to " "
	set quotedWavs to {}
	repeat with w in wavs
		set end of quotedWavs to quoted form of (contents of w)
	end repeat
	set joined to quotedWavs as text
	set AppleScript's text item delimiters to ""

	-- transcribe-ru is fetched by fetch-ru-assets.sh into assetDir alongside
	-- the model files — it is NOT a bundled resource. transcribe-en, in
	-- contrast, lives in the bundle's Resources.
	set enginePath to my enginePathFor(lang, resDir, assetDir)
	set argStr to my engineArgsFor(lang, assetDir, wantTimestamps, wantWordTimestamps)
	set cmd to quoted form of enginePath
	if argStr is not "" then set cmd to cmd & " " & argStr
	set cmd to cmd & " " & joined

	if not (my pathExists(enginePath)) then
		return {status:2, stdo:"", errp:"движок не найден: " & enginePath}
	end if

	set tag to my randomTag()
	set errFile to "/tmp/transcribe_err_" & tag & ".log"
	set exitFile to "/tmp/transcribe_exit_" & tag & ".txt"

	-- Route the engine's stderr (PROGRESS/ERROR lines) to a file instead of
	-- discarding it, and capture its real exit status in a second file —
	-- `do shell script` raises an AppleScript error on any non-zero exit,
	-- which would otherwise flatten the 1-vs-2 distinction the caller needs.
	-- The exit-status write is the LAST command in the group, so the group's
	-- own exit status (what `do shell script` sees) is always 0 regardless
	-- of what the engine returned.
	set fullCmd to "{ " & cmd & "; echo $? > " & quoted form of exitFile & "; } 2> " & quoted form of errFile

	set rawOut to ""
	try
		with timeout of 3600 seconds
			set rawOut to (do shell script fullCmd)
		end timeout
	on error
		-- The group always exits 0 (its last command is the exit-file write),
		-- so this only fires for something outside the engine itself: a
		-- malformed invocation, or the 3600s timeout being exceeded. Either
		-- way exitFile will be absent, so the read below correctly falls
		-- back to the hard-failure status (2) initialised above.
		set rawOut to ""
	end try

	set exitStatus to 2
	try
		set exitTxt to (do shell script "cat " & quoted form of exitFile)
		set exitStatus to exitTxt as integer
	end try

	set stde to ""
	try
		set stde to (do shell script "cat " & quoted form of errFile)
	end try

	try
		do shell script "rm -f " & quoted form of errFile & " " & quoted form of exitFile
	end try

	return {status:exitStatus, stdo:rawOut, errp:stde}
end runEngine

on enginePathFor(lang, resDir, assetDir)
	-- transcribe-ru is fetched by fetch-ru-assets.sh into assetDir alongside
	-- the model files — it is NOT a bundled resource. transcribe-en, in
	-- contrast, lives in the bundle's Resources.
	if lang is "Русский" then
		return assetDir & "/transcribe-ru"
	else
		return resDir & "/transcribe-en"
	end if
end enginePathFor

on engineArgsFor(lang, assetDir, wantTimestamps, wantWordTimestamps)
	-- Pure, side-effect-free flag threading, kept separate from runEngine so
	-- it is testable headlessly: --models is Russian-only (the engine needs
	-- to find its model files); --timestamps / --word-timestamps are
	-- threaded through to whichever binary gets dispatched, on both
	-- languages alike, whenever the dialog's checkboxes are checked.
	--
	-- "по словам" (wantWordTimestamps) implies word timestamps regardless of
	-- "Таймкоды" (wantTimestamps) -- there is no combination of the two
	-- checkboxes that means nothing, so only one of --word-timestamps /
	-- --timestamps is ever passed, never both.
	if lang is "Русский" then
		set args to "--models " & quoted form of assetDir
	else
		set args to ""
	end if
	if wantWordTimestamps then
		if args is "" then
			set args to "--word-timestamps"
		else
			set args to args & " --word-timestamps"
		end if
	else if wantTimestamps then
		if args is "" then
			set args to "--timestamps"
		else
			set args to args & " --timestamps"
		end if
	end if
	return args
end engineArgsFor

on askLangAndTimestamps(n)
	-- Native NSAlert with a language popup and a "Таймкоды" checkbox.
	--
	-- Automator's "Run AppleScript" action does NOT run the script on the main
	-- thread. An earlier version assumed it did and simply called the alert
	-- inline; every real run then failed with -10000 "NSWindow should only be
	-- instantiated on the main thread!" and silently fell back to the plain
	-- list, so the checkbox never appeared. NSAlert creates an NSWindow, so it
	-- must be hopped onto the main thread explicitly.
	--
	-- The result travels through a property because performSelectorOnMainThread
	-- cannot return a value.
	set my gUICount to n
	set my gUIResult to "FAILED"
	try
		my performSelectorOnMainThread:"showAlertOnMain:" withObject:(missing value) waitUntilDone:true
	end try

	if my gUIResult is "CANCELLED" then return missing value
	if my gUIResult is not "FAILED" then return my gUIResult

	-- Last resort: ask a plainer question rather than let the action die.
	-- Neither timestamp mode is offered here -- there is no checkbox in a
	-- plain `choose from list`.
	set langChoice to (choose from list {"Русский", "English"} with title ("Transcribe (" & n & ")") with prompt "Язык записи:" default items {"Русский"})
	if langChoice is false then return missing value
	return {lang:(item 1 of langChoice), timestamps:false, wordTimestamps:false}
end askLangAndTimestamps

on showAlertOnMain:sender
	try
		set r to my showTranscribeAlert(my gUICount)
		if r is missing value then
			set my gUIResult to "CANCELLED"
		else
			set my gUIResult to r
		end if
	on error
		set my gUIResult to "FAILED"
	end try
end showAlertOnMain:

on showTranscribeAlert(n)
	set alertObj to current application's NSAlert's alloc()'s init()
	alertObj's setMessageText:("Transcribe (" & n & ")")
	alertObj's setInformativeText:"Язык записи:"
	alertObj's addButtonWithTitle:"Распознать"
	alertObj's addButtonWithTitle:"Отмена"

	-- Accessory view: language popup, then "Таймкоды" (sentence timestamps),
	-- then "по словам" (word timestamps) indented below it so it reads as
	-- subordinate. No enable/disable wiring between the two checkboxes --
	-- see engineArgsFor: "по словам" ticked always wins and implies word
	-- timestamps whether or not "Таймкоды" is also ticked, so every
	-- combination of the two means something and there is nothing to gate.
	set accView to current application's NSView's alloc()'s initWithFrame:(current application's NSMakeRect(0, 0, 260, 106))
	set popup to current application's NSPopUpButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, 72, 260, 26)) pullsDown:false
	popup's addItemsWithTitles:{"Русский", "English"}
	set cb to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, 40, 260, 22))
	cb's setButtonType:(current application's NSButtonTypeSwitch)
	cb's setTitle:"Таймкоды"
	cb's setState:(current application's NSControlStateValueOff)
	set cbWords to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(16, 10, 244, 22))
	cbWords's setButtonType:(current application's NSButtonTypeSwitch)
	cbWords's setTitle:"по словам"
	cbWords's setState:(current application's NSControlStateValueOff)
	accView's addSubview:popup
	accView's addSubview:cb
	accView's addSubview:cbWords
	alertObj's setAccessoryView:accView

	set btn to (alertObj's runModal()) as integer

	-- NSAlertFirstButtonReturn (1000) is "Распознать"; anything else
	-- (1001 "Отмена", or a window-closed return) is a clean cancel.
	if btn is not 1000 then return missing value

	set selLang to (popup's titleOfSelectedItem()) as text
	set cbState to (cb's state()) as integer
	set cbWordsState to (cbWords's state()) as integer
	return {lang:selLang, timestamps:(cbState is 1), wordTimestamps:(cbWordsState is 1)}
end showTranscribeAlert

-- Write UTF-8 via NSString rather than `open for access`.
-- `use framework` puts this script in AppleScriptObjC mode, where the bare
-- `POSIX file` term resolves against the ObjC bridge and fails with
-- -1700 "Can't make current application into type «class fsrf»". That broke
-- every .txt write the moment the NSAlert dialog introduced the framework
-- imports. NSString's writeToFile is atomic and needs no file handle, so
-- there is nothing to leak on failure either.
on writeUTF8(outp, txt)
	try
		set ns to current application's NSString's stringWithString:txt
		-- `do shell script` hands back its output with CR line endings, so the
		-- engine's LF-separated lines arrive here as CR. That went unnoticed
		-- while a transcript was a single paragraph; with --timestamps it is
		-- many lines, and a CR-only .txt reads as one long line in most
		-- editors. Normalise CRLF and CR back to LF before writing.
		set ns to ns's stringByReplacingOccurrencesOfString:(character id 13 & character id 10) withString:(character id 10)
		set ns to ns's stringByReplacingOccurrencesOfString:(character id 13) withString:(character id 10)
		if not ((ns's hasSuffix:(character id 10)) as boolean) then
			set ns to ns's stringByAppendingString:(character id 10)
		end if
		set ok to ns's writeToFile:outp atomically:true encoding:(current application's NSUTF8StringEncoding) |error|:(missing value)
		return (ok as boolean)
	on error
		return false
	end try
end writeUTF8

on engineErrorLines(errBlob)
	set outLines to {}
	if errBlob is "" then return outLines
	repeat with ln in paragraphs of errBlob
		set lp to contents of ln
		if (lp starts with "ERROR " or lp starts with "ERROR:") and (length of lp) > 6 then
			set end of outLines to my trimBlank(text 7 thru -1 of lp)
		end if
	end repeat
	return outLines
end engineErrorLines

on nonProgressLines(errBlob)
	-- Last-resort fallback used only when engineErrorLines found nothing
	-- (the engine died without emitting a single ERROR line, e.g. a crash).
	-- Strips PROGRESS lines -- protocol chatter for the progress bar's own
	-- bookkeeping, never meant for a human -- out of the raw stderr blob.
	set outLines to {}
	if errBlob is "" then return outLines
	repeat with ln in paragraphs of errBlob
		set lp to contents of ln
		if lp is not "" and lp does not start with "PROGRESS " then
			set end of outLines to lp
		end if
	end repeat
	return outLines
end nonProgressLines

on majorVersionOf(v)
	-- "14.6.1" -> 14. Used to gate English on macOS 26+: transcribe-en is
	-- built with nothing weak-linked, so it fails at dyld load on an older
	-- system before its own #available guard ever runs.
	set AppleScript's text item delimiters to "."
	set majorStr to item 1 of (text items of v)
	set AppleScript's text item delimiters to ""
	return majorStr as integer
end majorVersionOf

on hasErrorFor(errLines, base)
	-- Engine ERROR lines are always "<basename>: <message>" (see main.swift's
	-- `note("ERROR \(base): ...")`), so a colon-terminated basename prefix
	-- unambiguously identifies which file an already-stripped line is about.
	-- Callers must pass the basename the ENGINE actually saw (the temp WAV),
	-- not the user's original filename — the engine never sees the latter.
	set marker to base & ":"
	repeat with eLine in errLines
		if (contents of eLine) starts with marker then return true
	end repeat
	return false
end hasErrorFor

on rewriteErrorLines(errLines, wavs, decoded)
	-- errLines are keyed on the temp WAV's basename (all the engine ever
	-- saw), which is meaningless to the user and, on a multi-file batch,
	-- impossible to attribute to a specific one of their files. `wavs` and
	-- `decoded` are parallel arrays built in lockstep by the decode loop, so
	-- the temp basename at index i maps to the user's original basename at
	-- the same index. Rewrite just the leading name; the message body after
	-- the colon is genuinely informative and is kept verbatim.
	set outLines to {}
	repeat with eLine in errLines
		set ln to contents of eLine
		repeat with idx from 1 to (count wavs)
			set tempBase to my baseName(item idx of wavs)
			set marker to tempBase & ":"
			if ln starts with marker then
				set ln to my baseName(item idx of decoded) & (text ((length of tempBase) + 1) thru -1 of ln)
				exit repeat
			end if
		end repeat
		set end of outLines to ln
	end repeat
	return outLines
end rewriteErrorLines

on sectionOf(outText, idx)
	set marker to "=== FILE " & (idx as text) & " ==="
	if outText does not contain marker then return ""
	set AppleScript's text item delimiters to marker
	set tail to text item 2 of outText
	set AppleScript's text item delimiters to "=== FILE "
	set chunk to text item 1 of tail
	set AppleScript's text item delimiters to ""
	return my trimBlank(chunk)
end sectionOf

on trimBlank(s)
	repeat while s starts with return or s starts with linefeed or s starts with " "
		if (length of s) < 2 then return ""
		set s to text 2 thru -1 of s
	end repeat
	repeat while s ends with return or s ends with linefeed or s ends with " "
		if (length of s) < 2 then return ""
		set s to text 1 thru -2 of s
	end repeat
	return s
end trimBlank

on parseProgress(aLine)
	-- "PROGRESS <phase> <done> <total> <detail>" -> {phase, done, total}
	if aLine does not start with "PROGRESS " then return missing value
	set AppleScript's text item delimiters to " "
	set parts to text items of aLine
	set AppleScript's text item delimiters to ""
	if (count parts) < 4 then return missing value
	return {item 2 of parts, (item 3 of parts) as integer, (item 4 of parts) as integer}
end parseProgress

on randomTag()
	return (do shell script "od -An -N4 -tx1 /dev/urandom | tr -d ' \\n'")
end randomTag

on resourceDir()
	set installedDir to (POSIX path of (path to home folder)) & "Library/Services/Transcribe.workflow/Contents/Resources"
	if my pathExists(installedDir) then return installedDir

	set p to POSIX path of (path to me)
	if p ends with "/" then set p to text 1 thru -2 of p
	set fallbackDir to p & "/Contents/Resources"
	if my pathExists(fallbackDir) then return fallbackDir

	return missing value
end resourceDir

-- Copied verbatim from Convert/src/convert.applescript:274-380 — each action
-- in this repo is a self-contained bundle with no cross-action imports.

on extOf(p)
	set nm to my baseName(p)
	if nm contains "." then
		set AppleScript's text item delimiters to "."
		set parts to text items of nm
		set AppleScript's text item delimiters to ""
		return item -1 of parts
	else
		return ""
	end if
end extOf

on baseName(p)
	set AppleScript's text item delimiters to "/"
	set c to last text item of p
	set AppleScript's text item delimiters to ""
	return c
end baseName

on baseOf(p)
	set nm to my baseName(p)
	if nm contains "." then
		set AppleScript's text item delimiters to "."
		set parts to text items of nm
		if (count of parts) < 2 then
			set AppleScript's text item delimiters to ""
			return nm
		end if
		set r to (items 1 thru -2 of parts) as text
		set AppleScript's text item delimiters to ""
		if r is "" then return nm
		return r
	else
		return nm
	end if
end baseOf

on dirOf(p)
	set AppleScript's text item delimiters to "/"
	set parts to text items of p
	if (count of parts) < 2 then
		set AppleScript's text item delimiters to ""
		return "."
	end if
	set r to (items 1 thru -2 of parts) as text
	set AppleScript's text item delimiters to ""
	if r is "" then return "/"
	return r
end dirOf

on uniqueOut(dir, base, ex)
	set p to dir & "/" & base & "." & ex
	set n to 2
	repeat while my pathExists(p)
		set p to dir & "/" & base & " " & (n as text) & "." & ex
		set n to n + 1
	end repeat
	return p
end uniqueOut

on pathExists(p)
	try
		do shell script "test -e " & quoted form of p
		return true
	on error
		return false
	end try
end pathExists

on notify(t, m)
	try
		display notification m with title t sound name "Glass"
	end try
end notify

on findFFmpeg()
	repeat with c in {"/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"}
		try
			do shell script "test -x " & quoted form of (contents of c)
			return (contents of c)
		end try
	end repeat
	try
		return (do shell script "/usr/bin/env PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin command -v ffmpeg")
	on error
		return missing value
	end try
end findFFmpeg
