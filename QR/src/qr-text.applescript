-- QR из текста — Service for selected text (readable source; embedded copy lives in the .workflow)
-- Input is the text selection in any app; output is a QR in the clipboard, opened in Preview.
-- Native, no dependencies: CoreImage (generate) + NSPasteboard (clipboard).
-- Generation mirrors QR/src/qr.applescript — keep the two in sync.

use framework "Foundation"
use framework "AppKit"
use framework "CoreImage"
use scripting additions

on run {input, parameters}
	-- A text service hands us a list of strings (normally one); join them as separate lines.
	set AppleScript's text item delimiters to linefeed
	set payload to (input as text)
	set AppleScript's text item delimiters to ""

	set msg to my trimWS(payload)
	if msg is "" then
		my notify("Пустой текст — отменено")
		return input
	end if
	-- 7089 digits is the largest a QR can hold in any mode; above that it can't fit,
	-- and the cap also keeps the char-by-char trim fast on accidentally-huge selections.
	if (length of msg) > 7100 then
		my notify("Текст слишком длинный для QR-кода")
		return input
	end if

	set theRep to my makeQR(msg)
	if theRep is missing value then
		my notify("Текст слишком длинный для QR-кода")
		return input
	end if
	my deliver(theRep)
	return input
end run

-- ---------- Generate ----------

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

-- ---------- Helpers ----------

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

on notify(m)
	try
		display notification m with title "QR из текста" sound name "Glass"
	end try
end notify
