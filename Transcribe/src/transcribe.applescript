-- Transcribe — Finder Quick Action (readable source; embedded copy lives in the .workflow)
-- English: Apple SpeechTranscriber (macOS 26+). Russian: sherpa-onnx + GigaAM v3.
-- Requires ffmpeg.

property gDone : 0

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

	set langChoice to (choose from list {"Русский", "English"} with title ("Transcribe (" & (count flist) & ")") with prompt "Язык записи:" default items {"Русский"})
	if langChoice is false then return input
	set lang to item 1 of langChoice

	set assetDir to (POSIX path of (path to library folder from user domain)) & "Application Support/AwesomeQuickActions/transcribe"

	set totalN to count flist
	set progress total steps to totalN * 2
	set progress completed steps to 0
	set progress description to "Transcribe"
	set progress additional description to "Подготовка…"
	set gDone to 0

	-- Russian needs the model; fetch it before anything else. A cold fetch
	-- downloads ~257 MB, so this needs the same generous timeout as the
	-- engine call below, not the default AppleEvent timeout.
	if lang is "Русский" then
		set progress additional description to "Загрузка модели (~257 МБ)…"
		try
			with timeout of 3600 seconds
				do shell script quoted form of (resDir & "/fetch-ru-assets.sh") & " 2>&1"
			end timeout
		on error errMsg
			display alert "Не удалось подготовить модель" message errMsg as warning
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
	set engineResult to my runEngine(lang, resDir, assetDir, wavs)
	set engStatus to status of engineResult
	set engOut to stdo of engineResult
	set engErr to errp of engineResult

	-- Exit codes are three-valued and mean different things: 0 = every file
	-- succeeded, 1 = ran but some files failed (still write what succeeded),
	-- 2 (or anything else unexpected) = could not start at all — nothing was
	-- produced, so stop rather than write empty/garbage output.
	if engStatus is 0 or engStatus is 1 then
		set okc to 0
		repeat with idx from 1 to (count decoded)
			set txt to my sectionOf(engOut, idx)
			set srcPath to item idx of decoded
			if txt is "" then
				set end of errs to my baseName(srcPath) & " — пустой результат"
			else
				set outp to my uniqueOut(my dirOf(srcPath), my baseOf(srcPath), "txt")
				set fh to missing value
				try
					set fh to open for access (POSIX file outp) with write permission
					set eof of fh to 0
					write txt to fh as «class utf8»
					close access fh
					set okc to okc + 1
				on error
					try
						if fh is not missing value then close access fh
					end try
					set end of errs to my baseName(srcPath) & " — не удалось записать .txt"
				end try
			end if
			set gDone to gDone + 1
			set progress completed steps to gDone
		end repeat

		-- Surface per-file engine failures that were only reported on stderr.
		repeat with eLine in my engineErrorLines(engErr)
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

		set failLines to my engineErrorLines(engErr)
		if (count of failLines) > 0 then
			set AppleScript's text item delimiters to return
			set failMsg to failLines as text
			set AppleScript's text item delimiters to ""
		else if engErr is not "" then
			set failMsg to engErr
		else
			set failMsg to "неизвестная ошибка (код " & (engStatus as text) & ")"
		end if
		display alert "Не удалось распознать" message failMsg as warning
	end if

	return input
end run

on runEngine(lang, resDir, assetDir, wavs)
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
	if lang is "Русский" then
		set enginePath to assetDir & "/transcribe-ru"
		set cmd to quoted form of enginePath & " --models " & quoted form of assetDir & " " & joined
	else
		set enginePath to resDir & "/transcribe-en"
		set cmd to quoted form of enginePath & " " & joined
	end if

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

	set errp to ""
	try
		set errp to (do shell script "cat " & quoted form of errFile)
	end try

	try
		do shell script "rm -f " & quoted form of errFile & " " & quoted form of exitFile
	end try

	return {status:exitStatus, stdo:rawOut, errp:errp}
end runEngine

on engineErrorLines(errp)
	set outLines to {}
	if errp is "" then return outLines
	repeat with ln in paragraphs of errp
		set lp to contents of ln
		if (lp starts with "ERROR " or lp starts with "ERROR:") and (length of lp) > 6 then
			set end of outLines to my trimBlank(text 7 thru -1 of lp)
		end if
	end repeat
	return outLines
end engineErrorLines

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
