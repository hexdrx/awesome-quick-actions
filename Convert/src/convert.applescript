property gDone : 0

on run {input, parameters}
	set SIPS to "/usr/bin/sips"
	set FF to my findFFmpeg()
	if FF is missing value then
		display alert "ffmpeg не найден" message "Установи ffmpeg: brew install ffmpeg" & return & "(искал в /opt/homebrew/bin, /usr/local/bin, /opt/local/bin и PATH)." as warning
		return input
	end if

	set imgs to {}
	set vids to {}
	set auds to {}
	set skipped to {}

	set imgExt to {"jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "jp2", "avif", "svg"}
	set vidExt to {"mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "m2ts", "ts", "3gp", "ogv"}
	set audExt to {"mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "ogg", "oga", "opus", "wma", "amr", "awb", "3ga"}

	repeat with itm in input
		set p to POSIX path of itm
		if p ends with "/" then set p to text 1 thru -2 of p
		set isDir to false
		try
			do shell script "test -d " & quoted form of p
			set isDir to true
		end try
		if isDir then
			set end of skipped to p
		else
			set e to my extOf(p)
			if imgExt contains e then
				set end of imgs to p
			else if vidExt contains e then
				set end of vids to p
			else if audExt contains e then
				set end of auds to p
			else
				set end of skipped to p
			end if
		end if
	end repeat

	set okCount to 0
	set errs to {}

	set totalN to (count imgs) + (count vids) + (count auds)
	set gDone to 0
	if totalN > 0 then
		set progress total steps to totalN
		set progress completed steps to 0
		set progress description to "Convert"
		set progress additional description to "Подготовка…"
	end if

	if (count of imgs) > 0 then
		set res to my doImages(imgs, SIPS)
		set okCount to okCount + (item 1 of res)
		set errs to errs & (item 2 of res)
	end if
	if (count of vids) > 0 then
		set res to my doVideos(vids, FF)
		set okCount to okCount + (item 1 of res)
		set errs to errs & (item 2 of res)
	end if
	if (count of auds) > 0 then
		set res to my doAudios(auds, FF)
		set okCount to okCount + (item 1 of res)
		set errs to errs & (item 2 of res)
	end if

	if totalN > 0 then set progress completed steps to totalN

	if totalN is 0 then
		set AppleScript's text item delimiters to return
		set stext to skipped as text
		set AppleScript's text item delimiters to ""
		display alert "Нет поддерживаемых файлов" message stext as warning
	else if okCount is 0 and (count of errs) is 0 then
		-- the format menu was cancelled
	else
		set msg to (okCount as text) & " файл(ов) готово"
		if (count of errs) > 0 then set msg to msg & ", ошибок: " & (count of errs)
		my notify("Convert", msg)
	end if
	if (count of errs) > 0 then
		set AppleScript's text item delimiters to return
		set etext to errs as text
		set AppleScript's text item delimiters to ""
		display alert "Не удалось сконвертировать" message etext as warning
	end if

	return input
end run

on doImages(flist, SIPS)
	set names to {"PNG", "JPEG", "HEIC", "TIFF", "GIF", "BMP", "PDF", "SVG (вектор, ч/б)", "SVG (встроенная картинка)"}
	set choice to (choose from list names with title ("Convert · Картинки (" & (count flist) & ")") with prompt "В какой формат?" default items {"JPEG"})
	if choice is false then return {0, {}}
	set target to item 1 of choice
	if target starts with "SVG" then return my doSVG(flist, SIPS, target)
	if target is "PNG" then
		set sf to "png"
		set ex to "png"
		set extra to ""
	else if target is "JPEG" then
		set sf to "jpeg"
		set ex to "jpg"
		set extra to " -s formatOptions 85"
	else if target is "HEIC" then
		set sf to "heic"
		set ex to "heic"
		set extra to " -s formatOptions 80"
	else if target is "TIFF" then
		set sf to "tiff"
		set ex to "tiff"
		set extra to ""
	else if target is "GIF" then
		set sf to "gif"
		set ex to "gif"
		set extra to ""
	else if target is "BMP" then
		set sf to "bmp"
		set ex to "bmp"
		set extra to ""
	else
		set sf to "pdf"
		set ex to "pdf"
		set extra to ""
	end if
	set okc to 0
	set errs to {}
	set progress description to "Convert · Картинки"
	repeat with p in flist
		set pp to contents of p
		set progress additional description to (my baseName(pp)) & "  →  " & target
		set outp to my uniqueOut(my dirOf(pp), my baseOf(pp), ex)
		try
			set src to my rasterIn(pp, {"JPEG", "BMP", "HEIC"} contains target)
			try
				do shell script SIPS & " -s format " & sf & extra & " " & quoted form of src & " --out " & quoted form of outp
			on error errMsg
				my dropRaster(src, pp)
				error errMsg
			end try
			my dropRaster(src, pp)
			set okc to okc + 1
		on error errMsg
			set end of errs to (my baseName(pp)) & " -> " & target & ": " & errMsg
		end try
		set gDone to gDone + 1
		set progress completed steps to gDone
	end repeat
	return {okc, errs}
end doImages

-- SVG: either a potrace bitmap trace (black & white, real vector) or the image
-- embedded as base64 inside an SVG wrapper (exact look, no dependencies).
on doSVG(flist, SIPS, target)
	set isTrace to (target is "SVG (вектор, ч/б)")
	if isTrace then
		set PT to my findTool("potrace")
		if PT is missing value then
			display alert "potrace не найден" message "Для векторного SVG установи potrace: brew install potrace" as warning
			return {0, {}}
		end if
		set FF to my findTool("ffmpeg")
	end if
	set okc to 0
	set errs to {}
	set progress description to "Convert · Картинки"
	repeat with p in flist
		set pp to contents of p
		set progress additional description to (my baseName(pp)) & "  →  " & target
		if my extOf(pp) is "svg" then
			set end of errs to (my baseName(pp)) & " -> " & target & ": уже SVG"
		else
		set outp to my uniqueOut(my dirOf(pp), my baseOf(pp), "svg")
		set q to quoted form of pp
		set qo to quoted form of outp
		-- every intermediate goes through sips first, so HEIC/WEBP/… all work
		set sh to "set -e; T=$(mktemp -d); trap 'rm -rf \"$T\"' EXIT; "
		if isTrace then
			-- flatten transparency onto white (else transparent pixels trace as black), then trace
			set sh to sh & SIPS & " -s format png " & q & " --out \"$T/i.png\" >/dev/null; " & ¬
				FF & " -y -v error -i \"$T/i.png\" -filter_complex 'color=white[bg];[bg][0:v]scale2ref[b][f];[b][f]overlay=format=auto,format=gray' -frames:v 1 \"$T/i.pgm\"; " & ¬
				PT & " -s -o \"$T/o.svg\" \"$T/i.pgm\"; " & ¬
				"/usr/bin/sed -E 's/([0-9])pt\"/\\1\"/g' \"$T/o.svg\" > " & qo
		else
			-- photos (no alpha) embed as JPEG to stay small; anything with alpha embeds as PNG
			set sh to sh & "if " & SIPS & " -g hasAlpha " & q & " | /usr/bin/grep -q 'hasAlpha: yes'; then M=png; " & ¬
				SIPS & " -s format png " & q & " --out \"$T/i\" >/dev/null; else M=jpeg; " & ¬
				SIPS & " -s format jpeg -s formatOptions 90 " & q & " --out \"$T/i\" >/dev/null; fi; " & ¬
				"W=$(" & SIPS & " -g pixelWidth \"$T/i\" | /usr/bin/awk '/pixelWidth/{print $2}'); " & ¬
				"H=$(" & SIPS & " -g pixelHeight \"$T/i\" | /usr/bin/awk '/pixelHeight/{print $2}'); " & ¬
				"{ printf '<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox=\"0 0 %s %s\"><image width=\"%s\" height=\"%s\" href=\"data:image/%s;base64,' $W $H $W $H $W $H $M; " & ¬
				"/usr/bin/base64 -i \"$T/i\" | /usr/bin/tr -d '\\n'; printf '\"/></svg>\\n'; } > " & qo
		end if
		try
			do shell script sh
			set okc to okc + 1
		on error errMsg
			try
				do shell script "rm -f " & qo
			end try
			set end of errs to (my baseName(pp)) & " -> " & target
		end try
		end if
		set gDone to gDone + 1
		set progress completed steps to gDone
	end repeat
	return {okc, errs}
end doSVG

-- sips can't read SVG: render it to a temp PNG (longest side 2048 px) with rsvg-convert.
-- opaque = flatten onto white, for targets without alpha (JPEG/BMP/HEIC/trace).
on rasterIn(pp, opaque)
	if my extOf(pp) is not "svg" then return pp
	set RSVG to my findTool("rsvg-convert")
	if RSVG is missing value then error "нужен rsvg-convert (brew install librsvg)"
	set tmpPng to (do shell script "/usr/bin/mktemp -t convert") & ".png"
	set bg to ""
	if opaque then set bg to " -b white"
	do shell script RSVG & " -f png -a -w 2048 -h 2048" & bg & " -o " & quoted form of tmpPng & " " & quoted form of pp
	return tmpPng
end rasterIn

on dropRaster(src, pp)
	if src is not pp then
		try
			do shell script "rm -f " & quoted form of src & " " & quoted form of (text 1 thru -5 of src)
		end try
	end if
end dropRaster

on doAudios(flist, FF)
	set names to {"MP3", "M4A (AAC)", "WAV", "FLAC", "AIFF", "OGG (Opus)"}
	set choice to (choose from list names with title ("Convert · Аудио (" & (count flist) & ")") with prompt "В какой формат?" default items {"MP3"})
	if choice is false then return {0, {}}
	set target to item 1 of choice
	if target is "MP3" then
		set args to "-c:a libmp3lame -b:a 192k"
		set ex to "mp3"
	else if target is "M4A (AAC)" then
		set args to "-c:a aac -b:a 192k"
		set ex to "m4a"
	else if target is "WAV" then
		set args to "-c:a pcm_s16le"
		set ex to "wav"
	else if target is "FLAC" then
		set args to "-c:a flac"
		set ex to "flac"
	else if target is "AIFF" then
		set args to "-c:a pcm_s16be"
		set ex to "aiff"
	else
		set args to "-c:a libopus -b:a 192k"
		set ex to "ogg"
	end if
	set okc to 0
	set errs to {}
	set progress description to "Convert · Аудио"
	repeat with p in flist
		set pp to contents of p
		set progress additional description to (my baseName(pp)) & "  →  " & target
		set outp to my uniqueOut(my dirOf(pp), my baseOf(pp), ex)
		try
			do shell script FF & " -y -v error -i " & quoted form of pp & " " & args & " " & quoted form of outp
			set okc to okc + 1
		on error errMsg
			set end of errs to (my baseName(pp)) & " -> " & target
		end try
		set gDone to gDone + 1
		set progress completed steps to gDone
	end repeat
	return {okc, errs}
end doAudios

on doVideos(flist, FF)
	set names to {"MP4 (H.264)", "MOV", "WEBM (VP9)", "MKV", "GIF (анимация)", "Извлечь аудио -> MP3", "Извлечь аудио -> M4A"}
	set choice to (choose from list names with title ("Convert · Видео (" & (count flist) & ")") with prompt "В какой формат?" default items {"MP4 (H.264)"})
	if choice is false then return {0, {}}
	set target to item 1 of choice

	set scaleArg to ""
	set isVideoOut to (target is "MP4 (H.264)") or (target is "MOV") or (target is "WEBM (VP9)") or (target is "MKV")
	if isVideoOut then
		set scaleArg to my chooseScale()
		if scaleArg is missing value then return {0, {}}
	end if

	if target is "MP4 (H.264)" then
		set args to "-c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart"
		set ex to "mp4"
	else if target is "MOV" then
		set args to "-c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart"
		set ex to "mov"
	else if target is "WEBM (VP9)" then
		set args to "-c:v libvpx-vp9 -crf 32 -b:v 0 -c:a libopus -b:a 192k"
		set ex to "webm"
	else if target is "MKV" then
		set args to "-c:v libx264 -crf 23 -preset medium -c:a aac -b:a 192k"
		set ex to "mkv"
	else if target is "GIF (анимация)" then
		set args to "-vf fps=12,scale=480:-1:flags=lanczos -loop 0"
		set ex to "gif"
	else if target is "Извлечь аудио -> MP3" then
		set args to "-vn -c:a libmp3lame -b:a 192k"
		set ex to "mp3"
	else
		set args to "-vn -c:a aac -b:a 192k"
		set ex to "m4a"
	end if

	set okc to 0
	set errs to {}
	set progress description to "Convert · Видео"
	repeat with p in flist
		set pp to contents of p
		set progress additional description to (my baseName(pp)) & "  →  " & target
		set outp to my uniqueOut(my dirOf(pp), my baseOf(pp), ex)
		try
			do shell script FF & " -y -v error -i " & quoted form of pp & scaleArg & " " & args & " " & quoted form of outp
			set okc to okc + 1
		on error errMsg
			set end of errs to (my baseName(pp)) & " -> " & target
		end try
		set gDone to gDone + 1
		set progress completed steps to gDone
	end repeat
	return {okc, errs}
end doVideos

on chooseScale()
	set opts to {"Оригинал", "480p", "720p", "1080p", "1440p (2K)", "2160p (4K)", "Свой размер..."}
	set c to (choose from list opts with title "Разрешение" with prompt "Масштабировать видео?" default items {"Оригинал"})
	if c is false then return missing value
	set r to item 1 of c
	if r is "Оригинал" then return ""
	if r is "480p" then return " -vf scale=-2:480"
	if r is "720p" then return " -vf scale=-2:720"
	if r is "1080p" then return " -vf scale=-2:1080"
	if r is "1440p (2K)" then return " -vf scale=-2:1440"
	if r is "2160p (4K)" then return " -vf scale=-2:2160"
	set t to ""
	try
		set t to text returned of (display dialog "Высота в px (напр. 720) или ШИРИНАxВЫСОТА (напр. 1280x720):" default answer "1280x720" with title "Свой размер")
	on error
		return missing value
	end try
	set t to my trimSpace(t)
	if t is "" then return ""
	set t to my replaceText(t, "X", "x")
	if t contains "x" then
		set AppleScript's text item delimiters to "x"
		set parts to text items of t
		set AppleScript's text item delimiters to ""
		set w to my trimSpace(item 1 of parts)
		set h to my trimSpace(item 2 of parts)
		return " -vf scale=" & w & ":" & h
	else
		return " -vf scale=-2:" & t
	end if
end chooseScale

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

on trimSpace(s)
	repeat while s is not "" and (character 1 of s is in {" ", tab})
		set s to text 2 thru -1 of s
	end repeat
	repeat while s is not "" and (character -1 of s is in {" ", tab})
		set s to text 1 thru -2 of s
	end repeat
	return s
end trimSpace

on replaceText(s, findT, replaceT)
	set AppleScript's text item delimiters to findT
	set parts to text items of s
	set AppleScript's text item delimiters to replaceT
	set r to parts as text
	set AppleScript's text item delimiters to ""
	return r
end replaceText

on findFFmpeg()
	return my findTool("ffmpeg")
end findFFmpeg

on findTool(nm)
	repeat with c in {"/opt/homebrew/bin/", "/usr/local/bin/", "/opt/local/bin/"}
		try
			do shell script "test -x " & quoted form of ((contents of c) & nm)
			return (contents of c) & nm
		end try
	end repeat
	try
		return (do shell script "/usr/bin/env PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin command -v " & nm)
	on error
		return missing value
	end try
end findTool
