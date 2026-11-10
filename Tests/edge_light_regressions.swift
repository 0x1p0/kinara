import AppKit

@main
enum EdgeLightRegressionTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        checks += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    /// WCAG relative luminance of an 8-bit sRGB pixel.
    private static func luminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
    private static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// The light for `edge`, drawn over `background` at 2x; each pixel's contrast against the background.
    private static func render(edge: String, colors: [NSColor], background: NSColor) -> (width: Int, height: Int, contrast: [Double]) {
        let length: CGFloat = 180, depth: CGFloat = 30
        let vertical = edge == "left" || edge == "right"
        let size = vertical ? CGSize(width: depth, height: length) : CGSize(width: length, height: depth)
        return render(EdgeLightStyle.layer(edge: edge, length: length, depth: depth, colors: colors), size: size, background: background)
    }

    private static func render(_ layer: CALayer, size: CGSize, background: NSColor) -> (width: Int, height: Int, contrast: [Double]) {
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let ground = background.usingColorSpace(.sRGB)!
        context.setFillColor(ground.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        let base = luminance(UInt8(ground.redComponent * 255), UInt8(ground.greenComponent * 255), UInt8(ground.blueComponent * 255))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var result = [Double](repeating: 1, count: width * height)
        for index in 0..<(width * height) {
            let p = index * 4
            result[index] = contrast(luminance(pixels[p], pixels[p + 1], pixels[p + 2]), base)
        }
        return (width, height, result)
    }

    static func main() {
        // The window: every overlay shares the one the indicator always used, which shows over full-screen apps.
        let window = OSDWindow(contentRect: NSRect(x: 0, y: 0, width: 30, height: 180), shadow: false)
        let behavior = window.collectionBehavior
        expect(behavior.contains(.canJoinAllSpaces) && behavior.contains(.fullScreenAuxiliary), "overlays join every Space, full-screen ones included")
        expect(!behavior.contains(.stationary), "an overlay is never stationary: a full-screen Space has no desktop to sit on")
        expect(!window.hidesOnDeactivate, "an overlay never hides because Kinara stopped being the active app")
        expect(!((window as NSWindow) is NSPanel), "overlays are plain windows, not panels that hide with their app")
        expect(window.level >= .statusBar, "overlays float above ordinary and floating windows")
        expect(window.ignoresMouseEvents && !window.canBecomeKey && !window.canBecomeMain, "overlays never take clicks or focus")
        expect(!window.isOpaque && !window.hasShadow, "the light's window is clear, with no window shadow")
        expect(OSDWindow(contentRect: .zero).hasShadow, "the indicator keeps its shadow")

        // The light reads on any background a full-screen app may put against the edge, with any accent.
        let backgrounds: [(String, NSColor)] = [("white", .white), ("light grey", NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)),
                                                 ("mid grey", NSColor(white: 0.55, alpha: 1)),
                                                 ("near black", NSColor(srgbRed: 0.06, green: 0.06, blue: 0.06, alpha: 1)), ("black", .black)]
        let accents: [(String, NSColor)] = [("blue", .systemBlue), ("graphite", NSColor(srgbRed: 0.55, green: 0.55, blue: 0.57, alpha: 1)),
                                             ("yellow", .systemYellow), ("pink", .systemPink)]
        for (accentName, accent) in accents {
            for (groundName, ground) in backgrounds {
                let best = render(edge: "right", colors: [EdgeLightStyle.accent(accent)], background: ground).contrast.max() ?? 1
                expect(best >= 3, "\(accentName) light on \(groundName) stands out at least 3:1 (got \(String(format: "%.2f", best)))")
            }
        }

        // Flush with the edge it names, glowing inward, its ends fading.
        let reach = Int(((EdgeLightStyle.inset + EdgeLightStyle.tube) * 2).rounded(.up)) + 1
        for edge in ["left", "right", "top", "bottom"] {
            let (width, height, contrast) = render(edge: edge, colors: [EdgeLightStyle.accent(.systemBlue)], background: .black)
            var bright = 0, stray = 0
            for y in 0..<height {
                for x in 0..<width where contrast[y * width + x] >= 3 {
                    bright += 1
                    // Bitmap memory runs top row first.
                    let fromEdge: Int
                    switch edge {
                    case "left": fromEdge = x
                    case "right": fromEdge = width - 1 - x
                    case "top": fromEdge = y
                    default: fromEdge = height - 1 - y
                    }
                    if fromEdge > reach { stray += 1 }
                }
            }
            expect(bright > 0 && stray == 0, "the \(edge) light's tube hugs the \(edge) edge")
            let along = edge == "left" || edge == "right" ? height : width
            let tip = max(1, along / 40)
            var tipBest = 1.0
            for i in 0..<tip {
                for j in 0..<(edge == "left" || edge == "right" ? width : height) {
                    let index = edge == "left" || edge == "right" ? i * width + j : j * width + i
                    tipBest = max(tipBest, contrast[index])
                }
            }
            expect(tipBest < 1.6, "the \(edge) light fades out at its ends")
        }
        // Every colour choice reads on every background.
        for option in EdgeLightColor.allCases {
            let colors = option.colors(tint: option == .byAction ? .systemYellow : nil)
            expect(!colors.isEmpty, "\(option.rawValue) has colours")
            for (groundName, ground) in backgrounds {
                let best = render(edge: "left", colors: colors, background: ground).contrast.max() ?? 1
                expect(best >= 3, "\(option.label) light on \(groundName) stands out at least 3:1 (got \(String(format: "%.2f", best)))")
            }
        }
        expect(EdgeLightColor.accent.colors().count == 1 && EdgeLightColor.mono.colors().count == 1, "Accent and Mono are one colour")
        expect([EdgeLightColor.aurora, .sunset, .ember, .mint].allSatisfy { $0.colors().count >= 3 }, "the presets run through several colours")
        expect(EdgeLightColor.byAction.colors(tint: .systemYellow) == [EdgeLightStyle.accent(.systemYellow)], "By action glows in the action's colour")
        expect(EdgeLightColor.byAction.colors() == EdgeLightColor.accent.colors(), "an action without a colour glows in the accent")

        // Several colours drift along the light; one colour never animates.
        func animations(_ layer: CALayer) -> [String] {
            (layer.animationKeys() ?? []) + (layer.mask.map(animations) ?? []) + (layer.sublayers ?? []).flatMap(animations)
        }
        expect(animations(EdgeLightStyle.layer(edge: "right", length: 180, depth: 30, colors: EdgeLightColor.aurora.colors())).contains("drift"),
               "a multicolour edge light drifts")
        expect(animations(EdgeLightStyle.layer(edge: "right", length: 180, depth: 30, colors: EdgeLightColor.accent.colors())).isEmpty,
               "a single-colour edge light costs no animation")

        // The ambient light: a spot of light lapping a tube that hugs every edge of the screen.
        let screen = CGRect(x: 0, y: 0, width: 800, height: 500)
        let centre = EdgeLightStyle.inset + EdgeLightStyle.tube / 2
        let lapPath = EdgeLightStyle.perimeter(of: screen)
        expect(lapPath.boundingBoxOfPath.insetBy(dx: -0.01, dy: -0.01).contains(screen.insetBy(dx: centre, dy: centre)) &&
               screen.insetBy(dx: centre - 0.01, dy: centre - 0.01).contains(lapPath.boundingBoxOfPath), "the lap runs just inside every edge")
        let ambient = EdgeLightStyle.ambient(in: screen, colors: EdgeLightColor.aurora.colors(), still: false)
        let lap = ambient.mask?.animation(forKey: "lap") as? CAKeyframeAnimation
        expect(lap != nil && lap?.keyPath == "position" && lap?.repeatCount == .infinity, "the spot laps the screen forever")
        expect(lap?.duration == EdgeLightStyle.lap && lap?.calculationMode == .paced, "at one steady pace, one lap in \(EdgeLightStyle.lap) s")
        expect(lap?.path.map { $0 == lapPath } ?? false, "along the tube itself")
        let lit = render(ambient, size: screen.size, background: .black)
        let start = lapPath.currentPoint
        var near = 0.0, far = 0.0
        for y in 0..<lit.height {
            for x in 0..<lit.width {
                // Bitmap memory runs top row first; CA's origin is bottom left.
                let point = CGPoint(x: (Double(x) + 0.5) / 2, y: screen.height - (Double(y) + 0.5) / 2)
                let c = lit.contrast[y * lit.width + x]
                if hypot(point.x - start.x, point.y - start.y) < 60 { near = max(near, c) }
                if hypot(point.x - start.x, point.y - start.y) > EdgeLightStyle.reach + 20 { far = max(far, c) }
            }
        }
        expect(near >= 3 && far < 1.05, "only the spot is lit; the rest of the screen stays clear (near \(Int(near)):1, far \(String(format: "%.2f", far)):1)")
        let still = EdgeLightStyle.ambient(in: screen, colors: EdgeLightColor.mint.colors(), still: true)
        expect(still.mask == nil && animations(still).filter { $0 != "drift" }.isEmpty && still.opacity < 1,
               "with Reduce Motion it holds still: a faint glow all the way round")
        print("\(checks) edge light assertions passed. Offscreen rendering only; no window was shown.")
    }
}
