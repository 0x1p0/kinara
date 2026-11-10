// Renders Kinara's app icon from geometry: a graphite macOS tile holding a
// quiet trackpad surface whose right edge glows as a live level.
// Usage: swift Design/render-icon.swift <output.png> [size]
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fatalError("usage: render-icon.swift <output.png> [size]") }
let size = arguments.count > 2 ? CGFloat(Double(arguments[2]) ?? 1024) : 1024
let scale = size / 1024
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ white: CGFloat, _ alpha: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [white, white, white, alpha])! }
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }

/// macOS's icon tile: a rounded square with continuous corners, drawn with
/// the widely published three-cubic corner that Apple's icon shape uses.
func continuousRect(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    // (along incoming edge, along outgoing edge), in radii from the corner.
    let start = (1.52866483, 0.0)
    let curves: [((Double, Double), (Double, Double), (Double, Double))] = [
        ((1.08849323, 0), (0.86840694, 0), (0.63149399, 0.07491100)),
        ((0.37282150, 0.16906012), (0.16906012, 0.37282150), (0.07491100, 0.63149399)),
        ((0, 0.86840694), (0, 1.08849323), (0, 1.52866483)),
    ]
    let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    let corners: [(Double, Double) -> CGPoint] = [
        { s, t in CGPoint(x: maxX - CGFloat(s) * r, y: maxY - CGFloat(t) * r) }, // top-right
        { s, t in CGPoint(x: maxX - CGFloat(t) * r, y: minY + CGFloat(s) * r) }, // bottom-right
        { s, t in CGPoint(x: minX + CGFloat(s) * r, y: minY + CGFloat(t) * r) }, // bottom-left
        { s, t in CGPoint(x: minX + CGFloat(t) * r, y: maxY - CGFloat(s) * r) }, // top-left
    ]
    let path = CGMutablePath()
    for (index, map) in corners.enumerated() {
        let first = map(start.0, start.1)
        index == 0 ? path.move(to: first) : path.addLine(to: first)
        for (c1, c2, end) in curves {
            path.addCurve(to: map(end.0, end.1), control1: map(c1.0, c1.1), control2: map(c2.0, c2.1))
        }
    }
    path.closeSubpath()
    return path
}

func capsule(_ rect: CGRect) -> CGPath { CGPath(roundedRect: rect, cornerWidth: rect.width / 2, cornerHeight: rect.width / 2, transform: nil) }

let pixels = Int(size)
guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }
context.scaleBy(x: scale, y: scale)
context.setShouldAntialias(true)
context.interpolationQuality = .high

// Apple's macOS icon grid: an 824-point body centered on the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = continuousRect(body, radius: 185)

// Grounding shadow, as on the system grid.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0, 0.38))
context.addPath(tile); context.setFillColor(color(0.08)); context.fillPath()
context.restoreGState()

// Graphite body: lit from above, deepening toward the bottom.
context.saveGState()
context.addPath(tile); context.clip()
let bodyGradient = CGGradient(colorsSpace: space, colors: [rgb(0.205, 0.212, 0.230), rgb(0.105, 0.110, 0.122), rgb(0.050, 0.053, 0.060)] as CFArray, locations: [0, 0.55, 1])!
context.drawLinearGradient(bodyGradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// A soft top sheen, like light falling on brushed glass.
let sheen = CGGradient(colorsSpace: space, colors: [color(1, 0.10), color(1, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(sheen, startCenter: CGPoint(x: 380, y: 980), startRadius: 0, endCenter: CGPoint(x: 380, y: 980), endRadius: 620, options: [])
context.restoreGState()

// Hairline rim: brighter on top, so the tile edge catches the light.
context.saveGState()
context.addPath(tile); context.setLineWidth(3); context.replacePathWithStrokedPath(); context.clip()
let rim = CGGradient(colorsSpace: space, colors: [color(1, 0.28), color(1, 0.04)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(rim, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 300), options: [])
context.restoreGState()

// The tile itself is the trackpad. A quiet track marks the left edge; the
// right edge carries one luminous swipe: a streak of light that rises and
// ends in a bright fingertip. It reads as motion and as a level at once.
// Small renditions (64 px and below) keep only what survives at that size:
// a bolder streak and fingertip, without the quiet track or the bloom.
let small = size <= 64
let trackWidth: CGFloat = small ? 136 : 74
let top: CGFloat = 806, bottom: CGFloat = 218
let leftTrack = CGRect(x: 214, y: bottom, width: trackWidth, height: top - bottom)
let rightTrack = CGRect(x: 1024 - (small ? 236 : 214) - trackWidth, y: bottom, width: trackWidth, height: top - bottom)
for track in small ? [rightTrack] : [leftTrack, rightTrack] {
    context.saveGState()
    context.addPath(capsule(track)); context.setFillColor(color(1, 0.055)); context.fillPath()
    context.addPath(capsule(track)); context.clip()
    // Recessed: a soft dark inner edge along the top.
    context.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: color(0, 0.55))
    context.addRect(track.insetBy(dx: -40, dy: -40)); context.addPath(capsule(track))
    context.setFillColor(color(0, 1)); context.fillPath(using: .evenOdd)
    context.restoreGState()
}

let streak = CGRect(x: rightTrack.minX, y: bottom, width: trackWidth, height: (top - bottom) * 0.74)
let head = CGPoint(x: streak.midX, y: streak.maxY - trackWidth / 2)
// Bloom around the fingertip, clipped to the tile.
if !small {
context.saveGState()
context.addPath(tile); context.clip()
let bloom = CGGradient(colorsSpace: space, colors: [rgb(0.86, 0.92, 1.0, 0.34), rgb(0.86, 0.92, 1.0, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(bloom, startCenter: head, startRadius: 0, endCenter: head, endRadius: 190, options: [])
context.restoreGState()
}
// The streak fades out downward, like light left behind by the swipe.
context.saveGState()
context.addPath(capsule(streak)); context.clip()
let trail = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 1), rgb(0.88, 0.92, 1.0, 0.85), rgb(0.80, 0.86, 1.0, small ? 0.25 : 0.0)] as CFArray,
                       locations: [0, small ? 0.35 : 0.22, 1])!
context.drawLinearGradient(trail, start: CGPoint(x: 0, y: streak.maxY), end: CGPoint(x: 0, y: streak.minY), options: [])
context.restoreGState()
// The fingertip: a solid, softly shadowed cap at the top of the streak.
context.saveGState()
context.setShadow(offset: .zero, blur: 28, color: rgb(0.80, 0.88, 1.0, 0.9))
context.addEllipse(in: CGRect(x: head.x - trackWidth / 2, y: head.y - trackWidth / 2, width: trackWidth, height: trackWidth))
context.setFillColor(color(1)); context.fillPath()
context.restoreGState()

guard let image = context.makeImage() else { fatalError("image") }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[1]))
print("Rendered \(Int(size))×\(Int(size)) icon to \(arguments[1])")
