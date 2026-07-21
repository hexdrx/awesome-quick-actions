-- File Tools — Finder Quick Action (readable source; embedded copy lives in the .workflow)

on run {input, parameters}
	set paths to {}
	repeat with itm in input
		set p to POSIX path of itm
		if p ends with "/" then set p to text 1 thru -2 of p
		set end of paths to p
	end repeat
	if (count paths) is 0 then return input

	set ops to {"Copy path", "Checksum", "New file here", "Rename batch"}
	set c to (choose from list ops with title ("File Tools (" & (count paths) & ")") with prompt "Что сделать?" default items {"Copy path"})
	if c is false then return input
	set op to item 1 of c

	if op is "Copy path" then
		my opCopyPath(paths)
	else if op is "Checksum" then
		my opChecksum(paths)
	else if op is "New file here" then
		my opNewFile(paths)
	else if op is "Rename batch" then
		my opRename(paths)
	end if
	return input
end run

on baseName(p)
	set AppleScript's text item delimiters to "/"
	set c to last text item of p
	set AppleScript's text item delimiters to ""
	return c
end baseName

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

on padNum(n, width)
	set s to (n as text)
	repeat while (length of s) < width
		set s to "0" & s
	end repeat
	return s
end padNum

on expandTemplate(tmpl, idx)
	if tmpl does not contain "#" then return tmpl & " " & my padNum(idx, 3)
	-- find the first contiguous run of "#"
	set n to length of tmpl
	set startPos to 0
	repeat with i from 1 to n
		if character i of tmpl is "#" then
			set startPos to i
			exit repeat
		end if
	end repeat
	set endPos to startPos
	repeat while endPos < n and (character (endPos + 1) of tmpl is "#")
		set endPos to endPos + 1
	end repeat
	set runLen to endPos - startPos + 1
	set pre to ""
	if startPos > 1 then set pre to text 1 thru (startPos - 1) of tmpl
	set post to ""
	if endPos < n then set post to text (endPos + 1) thru n of tmpl
	return pre & my padNum(idx, runLen) & post
end expandTemplate

on pathExists(p)
	try
		do shell script "test -e " & quoted form of p
		return true
	on error
		return false
	end try
end pathExists

on isDir(p)
	try
		do shell script "test -d " & quoted form of p
		return true
	on error
		return false
	end try
end isDir

on joinName(dir, base, ex)
	if ex is "" then
		return dir & "/" & base
	else
		return dir & "/" & base & "." & ex
	end if
end joinName

on uniqueName(dir, base, ex)
	return my uniqueNameAvoiding(dir, base, ex, {})
end uniqueName

on uniqueNameAvoiding(dir, base, ex, takenList)
	set p to my joinName(dir, base, ex)
	set n to 2
	repeat while (my pathExists(p)) or (takenList contains p)
		set p to my joinName(dir, base & " " & (n as text), ex)
		set n to n + 1
	end repeat
	return p
end uniqueNameAvoiding

on posixToFileURL(p)
	set enc to do shell script "printf %s " & quoted form of p & " | /usr/bin/perl -pe 's/([^A-Za-z0-9\\-._~\\/])/sprintf(\"%%%02X\",ord($1))/ge'"
	return "file://" & enc
end posixToFileURL

on nameOnly(p)
	return my baseName(p)
end nameOnly

on opCopyPath(paths)
	set opts to {"POSIX path", "file:// URL", "Только имя"}
	set choice to (choose from list opts with title "Copy path" with prompt "Что скопировать?" default items {"POSIX path"})
	if choice is false then return
	set mode to item 1 of choice
	set outLines to {}
	repeat with p in paths
		set pp to contents of p
		if mode is "POSIX path" then
			set end of outLines to pp
		else if mode is "file:// URL" then
			set end of outLines to my posixToFileURL(pp)
		else
			set end of outLines to my nameOnly(pp)
		end if
	end repeat
	set AppleScript's text item delimiters to linefeed
	set payload to outLines as text
	set AppleScript's text item delimiters to ""
	do shell script "printf %s " & quoted form of payload & " | pbcopy"
	my notify("Скопировано " & (count paths) & " путь(ей)")
end opCopyPath

on notify(m)
	try
		display notification m with title "File Tools" sound name "Glass"
	end try
end notify

on hashOf(path, algo)
	if algo is "md5" then
		return do shell script "/sbin/md5 -q " & quoted form of path
	else
		return do shell script "/usr/bin/shasum -a " & algo & " " & quoted form of path & " | cut -d' ' -f1"
	end if
end hashOf

on hashesEqual(a, b)
	set aa to my trimSpace(a)
	set bb to my trimSpace(b)
	return (do shell script "printf %s " & quoted form of aa & " | tr 'A-Z' 'a-z'") is (do shell script "printf %s " & quoted form of bb & " | tr 'A-Z' 'a-z'")
end hashesEqual

on opChecksum(paths)
	set algOpts to {"SHA-256", "SHA-1", "MD5"}
	set ac to (choose from list algOpts with title "Checksum" with prompt "Алгоритм?" default items {"SHA-256"})
	if ac is false then return
	set alg to item 1 of ac
	if alg is "SHA-256" then
		set algo to "256"
	else if alg is "SHA-1" then
		set algo to "1"
	else
		set algo to "md5"
	end if
	set modeOpts to {"Посчитать → в буфер", "Сверить с ожидаемым"}
	set mc to (choose from list modeOpts with title "Checksum" with prompt (alg & ": что делать?") default items {"Посчитать → в буфер"})
	if mc is false then return
	set mode to item 1 of mc
	-- collect files only  (NB: 'files' is a reserved AppleScript term — use hashFiles)
	set hashFiles to {}
	repeat with p in paths
		set pp to contents of p
		if not (my isDir(pp)) then set end of hashFiles to pp
	end repeat
	if (count hashFiles) is 0 then
		my notify("Нет файлов для хеширования")
		return
	end if
	if mode is "Посчитать → в буфер" then
		set outLines to {}
		repeat with pp in hashFiles
			set fp to contents of pp
			if (count hashFiles) is 1 then
				set end of outLines to my hashOf(fp, algo)
			else
				set end of outLines to (my hashOf(fp, algo)) & "  " & my baseName(fp)
			end if
		end repeat
		set AppleScript's text item delimiters to linefeed
		set payload to outLines as text
		set AppleScript's text item delimiters to ""
		do shell script "printf %s " & quoted form of payload & " | pbcopy"
		my notify(alg & ": " & (count hashFiles) & " хеш(ей) в буфере")
	else
		-- verify: single file only
		set fp to item 1 of hashFiles
		set expected to ""
		try
			set expected to text returned of (display dialog "Ожидаемый хеш для «" & (my baseName(fp)) & "»:" default answer "" with title ("Сверить " & alg) buttons {"Отмена", "OK"} default button "OK" cancel button "Отмена")
		on error
			return
		end try
		set actual to my hashOf(fp, algo)
		if my hashesEqual(actual, expected) then
			display alert "✅ Совпадает" message (alg & " совпадает:" & return & actual)
		else
			display alert "❌ Не совпадает" message ("Ожидалось:" & return & (my trimSpace(expected)) & return & return & "Получено:" & return & actual) as warning
		end if
	end if
end opChecksum

on targetDir(paths)
	if (count paths) is 1 then
		set only to item 1 of paths
		if my isDir(only) then return only
	end if
	return my dirOf(item 1 of paths)
end targetDir

on opNewFile(paths)
	set dir to my targetDir(paths)
	set nm to ""
	try
		set nm to text returned of (display dialog "Имя нового файла (с расширением):" default answer "untitled.md" with title "New file here" buttons {"Отмена", "OK"} default button "OK" cancel button "Отмена")
	on error
		return
	end try
	set nm to my trimSpace(nm)
	if nm is "" then return
	-- split into base + extension for collision-safe naming.
	-- Leading-dot names (".gitignore", ".env") are dotfiles, not "base.ext":
	-- keep the whole name as the base so we never produce ".gitignore.gitignore".
	if nm contains "." and nm does not start with "." then
		set b to my baseOf("x/" & nm)
		set e to my extOf("x/" & nm)
	else
		set b to nm
		set e to ""
	end if
	set outp to my uniqueName(dir, b, e)
	do shell script "touch " & quoted form of outp
	my notify("Создан: " & my baseName(outp))
end opNewFile

on newBaseFor(mode, oldBase, arg1, arg2, idx)
	if mode is "prefix" then
		return arg1 & oldBase
	else if mode is "suffix" then
		return oldBase & arg1
	else if mode is "replace" then
		return my replaceText(oldBase, arg1, arg2)
	else
		return my expandTemplate(arg1, idx)
	end if
end newBaseFor

on renameBatch(paths, mode, arg1, arg2)
	set okc to 0
	set errs to {}
	set taken to {}
	set idx to 1
	repeat with p in paths
		set pp to contents of p
		set dir to my dirOf(pp)
		if my isDir(pp) then
			set oldBase to my baseName(pp)
			set e to ""
		else
			set oldBase to my baseOf(pp)
			set e to my extOf(pp)
		end if
		set nb to my newBaseFor(mode, oldBase, arg1, arg2, idx)
		-- If the computed name equals the current name (no-op: e.g. a replace
		-- that didn't match, or an empty prefix), skip silently. Do NOT run it
		-- through uniqueNameAvoiding — the file's own path would look like a
		-- collision with itself and get bumped to " 2", mangling the name.
		set ideal to my joinName(dir, nb, e)
		if ideal is not pp then
			set outp to my uniqueNameAvoiding(dir, nb, e, taken)
			set end of taken to outp
			try
				do shell script "mv -n " & quoted form of pp & " " & quoted form of outp
				set okc to okc + 1
			on error
				set end of errs to my baseName(pp)
			end try
		end if
		set idx to idx + 1
	end repeat
	return {okc, errs}
end renameBatch

on opRename(paths)
	set modeOpts to {"Префикс", "Суффикс", "Нумерация", "Замена подстроки"}
	set mc to (choose from list modeOpts with title "Rename batch" with prompt ("Как переименовать " & (count paths) & " объект(ов)?") default items {"Префикс"})
	if mc is false then return
	set sel to item 1 of mc
	set arg1 to ""
	set arg2 to ""
	if sel is "Префикс" then
		set mode to "prefix"
		set arg1 to my askText("Текст префикса:", "new_")
	else if sel is "Суффикс" then
		set mode to "suffix"
		set arg1 to my askText("Текст суффикса (перед расширением):", "_v2")
	else if sel is "Нумерация" then
		set mode to "number"
		set arg1 to my askText("Шаблон (# = номер, напр. Photo ###):", "Photo ###")
	else
		set mode to "replace"
		set arg1 to my askText("Найти подстроку:", "")
		if arg1 is missing value then return
		if arg1 is "" then
			my notify("Пустая строка поиска — отменено")
			return
		end if
		set arg2 to my askText("Заменить на:", "")
	end if
	if arg1 is missing value or arg2 is missing value then return
	set res to my renameBatch(paths, mode, arg1, arg2)
	set okc to item 1 of res
	set errs to item 2 of res
	set msg to (okc as text) & " переименовано"
	if (count errs) > 0 then set msg to msg & ", ошибок: " & (count errs)
	my notify(msg)
	if (count errs) > 0 then
		set AppleScript's text item delimiters to return
		set etext to errs as text
		set AppleScript's text item delimiters to ""
		display alert "Не удалось переименовать" message etext as warning
	end if
end opRename

on askText(promptText, defaultText)
	try
		return text returned of (display dialog promptText default answer defaultText with title "Rename batch" buttons {"Отмена", "OK"} default button "OK" cancel button "Отмена")
	on error
		return missing value
	end try
end askText
