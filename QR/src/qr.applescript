-- QR — Finder Quick Action (readable source; embedded copy lives in the .workflow)
-- Native, no dependencies: CoreImage (generate) + Vision (decode) + NSPasteboard (clipboard).

use framework "Foundation"
use framework "AppKit"
use framework "CoreImage"
use framework "Vision"
use scripting additions

on run {input, parameters}
	set imgPaths to {}
	set txtPaths to {}
	repeat with itm in input
		set p to POSIX path of itm
		if p ends with "/" then set p to text 1 thru -2 of p
		if my isImage(p) then
			set end of imgPaths to p
		else if my isTextFile(p) then
			set end of txtPaths to p
		end if
	end repeat

	-- Image(s) selected → auto-detect a QR, no prompt.
	if (count imgPaths) > 0 then
		set found to my decodeAll(imgPaths)
		if (count found) > 0 then
			my showDecoded(found)
			return input
		end if
	end if

	-- Plain-text file selected → QR straight from its contents, no prompt.
	if (count txtPaths) > 0 then
		my opGenerateFromFile(item 1 of txtPaths)
		return input
	end if

	-- Otherwise → create from typed text / clipboard.
	my opGenerate()
	return input
end run

-- ---------- Generate ----------

on opGenerate()
	set clip to ""
	try
		set clip to (do shell script "pbpaste")
	end try
	if clip is "" then set clip to "https://"
	set msg to my askText("Текст или ссылка для QR:", clip)
	if msg is missing value then return
	if msg is "" then
		my notify("Пустой текст — отменено")
		return
	end if
	set theRep to my makeQR(msg)
	if theRep is missing value then
		my notify("Текст слишком длинный для QR-кода")
		return
	end if
	my deliver(theRep)
end opGenerate

on opGenerateFromFile(p)
	set ca to current application
	set nsStr to (ca's NSString's stringWithContentsOfFile:p encoding:(ca's NSUTF8StringEncoding) |error|:(missing value))
	if nsStr is missing value then
		my notify("Не удалось прочитать файл как текст (UTF-8)")
		return
	end if
	set fileBody to (nsStr as text)
	-- 7089 digits is the largest a QR can hold in any mode; above that it can't fit,
	-- and the cap also keeps the char-by-char trim fast on accidentally-huge files.
	if (length of fileBody) > 7100 then
		my notify("Текст в файле слишком длинный для QR-кода")
		return
	end if
	set msg to my trimWS(fileBody)
	if msg is "" then
		my notify("Файл пустой")
		return
	end if
	set theRep to my makeQR(msg)
	if theRep is missing value then
		my notify("Текст в файле слишком длинный для QR-кода")
		return
	end if
	my deliver(theRep)
end opGenerateFromFile

on makeQR(msg)
	set ca to current application
	set d to (ca's NSString's stringWithString:msg)'s dataUsingEncoding:(ca's NSUTF8StringEncoding)
	set f to ca's CIFilter's filterWithName:"CIQRCodeGenerator"
	f's setValue:d forKey:"inputMessage"
	-- "L" = lowest error correction = highest data capacity (~2953 bytes / 7089 digits).
	-- Fine for on-screen scanning; bump to "H" if you print or add a center logo.
	f's setValue:"L" forKey:"inputCorrectionLevel"
	-- outputImage is nil when the text exceeds the QR capacity — bail out cleanly.
	set ci to missing value
	try
		set ci to f's outputImage
	end try
	if ci is missing value then return missing value
	set ciRep to ca's NSCIImageRep's imageRepWithCIImage:ci
	set small to ca's NSImage's alloc()'s initWithSize:(ciRep's |size|())
	small's addRepresentation:ciRep
	set sz to (small's |size|())
	set modW to (width of sz)
	set theScale to 10
	set marginMods to 4
	set fin to ((modW + 2 * marginMods) * theScale) as integer
	set modPx to (modW * theScale)
	set insetPx to (marginMods * theScale)

	set rep2 to ca's NSBitmapImageRep's alloc()'s initWithBitmapDataPlanes:(missing value) pixelsWide:fin pixelsHigh:fin bitsPerSample:8 samplesPerPixel:4 hasAlpha:true isPlanar:false colorSpaceName:(ca's NSDeviceRGBColorSpace) bytesPerRow:0 bitsPerPixel:0
	set gctx to ca's NSGraphicsContext's graphicsContextWithBitmapImageRep:rep2
	ca's NSGraphicsContext's saveGraphicsState()
	ca's NSGraphicsContext's setCurrentContext:gctx
	gctx's setImageInterpolation:(ca's NSImageInterpolationNone)
	(ca's NSColor's whiteColor())'s |set|()
	ca's NSBezierPath's fillRect:(ca's NSMakeRect(0, 0, fin, fin))
	small's drawInRect:(ca's NSMakeRect(insetPx, insetPx, modPx, modPx)) fromRect:(ca's NSMakeRect(0, 0, modW, modW)) operation:(ca's NSCompositingOperationSourceOver) fraction:1.0
	ca's NSGraphicsContext's restoreGraphicsState()
	return rep2
end makeQR

on deliver(theRep)
	set ca to current application
	-- Sweep QR temp files from earlier runs (older than a day), then use a per-process unique name.
	do shell script "find /tmp -maxdepth 1 -name 'qr-*.png' -mtime +0 -delete 2>/dev/null || true"
	set tmpPath to "/tmp/qr-" & (do shell script "date +%Y%m%d-%H%M%S-$$") & ".png"
	my savePNG(theRep, tmpPath)
	set pw to (theRep's pixelsWide())
	set ph to (theRep's pixelsHigh())
	set img to ca's NSImage's alloc()'s initWithSize:(ca's NSMakeSize(pw, ph))
	img's addRepresentation:theRep
	set pb to ca's NSPasteboard's generalPasteboard()
	pb's clearContents()
	pb's writeObjects:(ca's NSArray's arrayWithObject:img)
	do shell script "open -a Preview " & quoted form of tmpPath
	my notify("QR готов — в буфере и открыт в Просмотре")
end deliver

on savePNG(theRep, outPath)
	set ca to current application
	set emptyOpts to (ca's NSDictionary's dictionary())
	set png to (theRep's representationUsingType:(ca's NSBitmapImageFileTypePNG) |properties|:emptyOpts)
	png's writeToFile:outPath atomically:true
end savePNG

-- ---------- Decode ----------

on decodeAll(imgPaths)
	set found to {}
	repeat with p in imgPaths
		set pp to contents of p
		set res to my decodeQR(pp)
		repeat with r in res
			set end of found to (contents of r)
		end repeat
	end repeat
	return found
end decodeAll

on showDecoded(found)
	-- Copy everything to the clipboard (silent).
	set AppleScript's text item delimiters to linefeed
	set payload to found as text
	set AppleScript's text item delimiters to ""
	do shell script "printf %s " & quoted form of payload & " | pbcopy"

	-- http/https links open silently in the default browser; keep the others for a dialog.
	set nonUrls to {}
	repeat with f in found
		set ff to my trimWS(contents of f)
		if my isHttpUrl(ff) then
			do shell script "open " & quoted form of ff
		else
			set end of nonUrls to (contents of f)
		end if
	end repeat

	if (count nonUrls) > 0 then
		set AppleScript's text item delimiters to linefeed
		set nonUrlText to nonUrls as text
		set AppleScript's text item delimiters to ""
		display dialog "Найдено и скопировано в буфер:" & return & return & nonUrlText with title "QR" buttons {"OK"} default button "OK"
	end if
end showDecoded

on isHttpUrl(s)
	if (length of s) < 7 then return false
	set low to (do shell script "printf %s " & quoted form of s & " | tr 'A-Z' 'a-z'")
	return (low starts with "http://") or (low starts with "https://")
end isHttpUrl

on trimWS(s)
	set t to s
	repeat while t is not "" and (character 1 of t is in {" ", tab, return, linefeed})
		set t to text 2 thru -1 of t
	end repeat
	repeat while t is not "" and (character -1 of t is in {" ", tab, return, linefeed})
		set t to text 1 thru -2 of t
	end repeat
	return t
end trimWS

on decodeQR(p)
	set ca to current application
	set u to ca's NSURL's fileURLWithPath:p
	set req to ca's VNDetectBarcodesRequest's alloc()'s init()
	set h to ca's VNImageRequestHandler's alloc()'s initWithURL:u options:(ca's NSDictionary's dictionary())
	h's performRequests:(ca's NSArray's arrayWithObject:req) |error|:(missing value)
	set res to (req's |results|())
	set outList to {}
	if res is missing value then return outList
	repeat with r in res
		set pl to ""
		try
			set pl to ((r's payloadStringValue()) as text)
		end try
		if pl is not "" then set end of outList to pl
	end repeat
	return outList
end decodeQR

-- ---------- Helpers (mirrors FileTools conventions) ----------

on isImage(p)
	set e to my extOf(p)
	if e is "" then return false
	set e to (do shell script "printf %s " & quoted form of e & " | tr 'A-Z' 'a-z'")
	return e is in {"png", "jpg", "jpeg", "gif", "tiff", "tif", "heic", "heif", "bmp", "webp"}
end isImage

on isTextFile(p)
	set e to my extOf(p)
	if e is "" then return false
	set e to (do shell script "printf %s " & quoted form of e & " | tr 'A-Z' 'a-z'")
	return e is in {"txt", "md", "markdown", "text", "log", "csv", "tsv", "json", "xml", "yaml", "yml", "ini", "conf", "cfg"}
end isTextFile

on baseName(p)
	set AppleScript's text item delimiters to "/"
	set c to last text item of p
	set AppleScript's text item delimiters to ""
	return c
end baseName

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

on askText(promptText, defaultText)
	try
		return text returned of (display dialog promptText default answer defaultText with title "QR" buttons {"Отмена", "OK"} default button "OK" cancel button "Отмена")
	on error
		return missing value
	end try
end askText

on notify(m)
	try
		display notification m with title "QR" sound name "Glass"
	end try
end notify
