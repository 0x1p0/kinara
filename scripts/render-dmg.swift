import AppKit
import ImageIO

// Static, Retina-aware installer artwork. Actual files remain native Finder icons.
// This renderer does not open windows, launch the app, or modify Finder settings.
let width: CGFloat = 720
let height: CGFloat = 470
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: render-dmg output-directory /path/to/Kinara.app")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let bundle = CommandLine.arguments[2]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: height - y - h, width: w, height: h)
}

func label(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat,
           size: CGFloat, weight: NSFont.Weight = .regular,
           gray: CGFloat = 0.2, centered: Bool = false) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = centered ? .center : .left
    paragraph.lineSpacing = 4
    (string as NSString).draw(in: box(x, y, width, 70), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(white: gray, alpha: 1),
        .paragraphStyle: paragraph,
    ])
}

func artwork() {
    NSGradient(starting: NSColor(white: 0.99, alpha: 1),
               ending: NSColor(white: 0.9, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    label("Kinara", x: 56, y: 35, width: 460, size: 43, weight: .semibold, gray: 0.12)
    label("A lighter touch for your Mac.", x: 58, y: 91, width: 450,
          size: 16, gray: 0.38)

    for x: CGFloat in [131, 441] {
        let rect = box(x, 148, 148, 150)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.07)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        NSColor(white: 1, alpha: 0.62).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.95).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: 30, yRadius: 30)
        outline.lineWidth = 1
        outline.stroke()
    }

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 333, y: height - 218))
    arrow.line(to: NSPoint(x: 385, y: height - 218))
    arrow.move(to: NSPoint(x: 375, y: height - 208))
    arrow.line(to: NSPoint(x: 385, y: height - 218))
    arrow.line(to: NSPoint(x: 375, y: height - 228))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(white: 0.46, alpha: 1).setStroke()
    arrow.stroke()
    label("DRAG TO INSTALL", x: 294, y: 247, width: 132,
          size: 10, weight: .medium, gray: 0.43, centered: true)

    NSColor(white: 0, alpha: 0.09).setFill()
    box(56, 326, 608, 1).fill()
    label("Make yourself at home.", x: 58, y: 352, width: 455,
          size: 21, weight: .medium, gray: 0.2)
    label("Drag Kinara into Applications. Eject this disk,\nthen open Kinara from Applications.",
          x: 58, y: 388, width: 445, size: 13, gray: 0.37)
}

func render(scale: Int, preview: Bool = false) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    // The bitmap's logical size supplies the Retina transform automatically.
    artwork()
    if preview {
        // Layout proof only: Finder draws the real icons and labels in the DMG.
        let items: [(String, CGFloat, CGFloat, NSImage)] = [
            ("Kinara", 205, 218, NSImage(contentsOfFile: bundle + "/Contents/Resources/AppIcon.icns")!),
            ("Applications", 515, 218, NSWorkspace.shared.icon(forFile: "/Applications")),
            ("First Launch", 625, 373, NSWorkspace.shared.icon(for: .plainText)),
        ]
        for (title, x, y, icon) in items {
            icon.draw(in: box(x - 48, y - 48, 96, 96))
            label(title, x: x - 78, y: y + 51, width: 156,
                  size: 13, gray: 0.12, centered: true)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let representations = [render(scale: 1), render(scale: 2)]
let image = NSImage(size: NSSize(width: width, height: height))
image.addRepresentations(representations)
let tiff = image.tiffRepresentation
guard let tiff else { fatalError("Could not encode installer background") }
guard let source = CGImageSourceCreateWithData(tiff as CFData, nil),
      CGImageSourceGetCount(source) == 2 else {
    fatalError("Installer background must preserve both resolution representations")
}
var verifiedScales = Set<Int>()
for index in 0..<2 {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)! as NSDictionary
    let scale = (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) / Int(width)
    guard [1, 2].contains(scale),
          properties[kCGImagePropertyPixelWidth] as? Int == Int(width) * scale,
          properties[kCGImagePropertyPixelHeight] as? Int == Int(height) * scale,
          // AppKit omits the default 72 DPI tags for the 1× representation.
          (properties[kCGImagePropertyDPIWidth] as? Double ?? 72) == Double(72 * scale),
          (properties[kCGImagePropertyDPIHeight] as? Double ?? 72) == Double(72 * scale) else {
        fputs("Unexpected TIFF representation \(index): \(properties)\n", stderr)
        exit(1)
    }
    verifiedScales.insert(scale)
}
precondition(verifiedScales == [1, 2])
try tiff.write(to: output.appendingPathComponent("Installer.tiff"), options: .atomic)
guard let preview = render(scale: 2, preview: true).representation(using: .png, properties: [:]) else {
    fatalError("Could not encode layout proof")
}
try preview.write(to: output.appendingPathComponent("Installer-preview.png"), options: .atomic)
print("Rendered 1×/2× installer artwork and layout proof in \(output.path)")
