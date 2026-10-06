import AppKit
import CoreText

let root = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
let fontURL = URL(fileURLWithPath: root + "/assets/fonts/NotoNaskhArabicUI.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
let ink = NSColor(srgbRed: 78/255, green: 63/255, blue: 59/255, alpha: 1)
let muted = NSColor(srgbRed: 130/255, green: 123/255, blue: 120/255, alpha: 1)
let accent = NSColor(srgbRed: 174/255, green: 71/255, blue: 33/255, alpha: 1)
let size = NSSize(width: 640, height: 400)
let image = NSImage(size: size)
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640 * scale, pixelsHigh: 400 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(scale))
    transform.concat()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    func text(_ value: String, y: CGFloat, font: NSFont, color: NSColor, rtl: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        (value as NSString).draw(in: NSRect(x: 24, y: y, width: 592, height: 38), withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }
    text("تثبيت الجامع", y: 322, font: NSFont(name: "NotoNaskhArabicUI-Regular", size: 30) ?? .systemFont(ofSize: 28), color: ink, rtl: true)
    text("اسحب الجامع إلى مجلد التطبيقات", y: 282, font: NSFont(name: "NotoNaskhArabicUI-Regular", size: 21) ?? .systemFont(ofSize: 20), color: muted, rtl: true)
    // The actual app and Applications icons are supplied by Finder.
    accent.setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 292, y: 196))
    arrow.line(to: NSPoint(x: 348, y: 196))
    arrow.move(to: NSPoint(x: 337, y: 207))
    arrow.line(to: NSPoint(x: 348, y: 196))
    arrow.line(to: NSPoint(x: 337, y: 185))
    arrow.stroke()
    text("Drag Aljam3 to Applications", y: 60, font: .systemFont(ofSize: 15), color: muted)
    text("ثم افتح الجامع من مجلد التطبيقات", y: 27, font: NSFont(name: "NotoNaskhArabicUI-Regular", size: 17) ?? .systemFont(ofSize: 16), color: muted, rtl: true)
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(bitmap)
}
try image.tiffRepresentation!.write(to: URL(fileURLWithPath: destination))
