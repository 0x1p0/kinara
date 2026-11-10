import AppKit

/// The window behind every Kinara overlay: the indicator, the edge light, the
/// corner light and the tap pill. Borderless, click-through, never key, on
/// every Space and over full-screen apps. They share it so they behave alike:
/// the lights used to be panels marked stationary ("like the desktop window"),
/// which hide with their app and have no desktop to join in a full-screen
/// Space, while the indicator showed there.
final class OSDWindow: NSWindow {
    static let overlayLevel: NSWindow.Level = .statusBar
    static let overlayBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    init(contentRect: NSRect, shadow: Bool = true) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = shadow
        level = Self.overlayLevel
        ignoresMouseEvents = true
        collectionBehavior = Self.overlayBehavior
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // No opaque backing or clipping parent: AppKit owns glass compositing.
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The light's colours. One colour is a solid tube; several run along it.
enum EdgeLightColor: String, CaseIterable, Identifiable {
    case accent, aurora, sunset, ember, mint, mono, byAction
    var id: String { rawValue }
    var label: String {
        switch self {
        case .accent: return "Accent"
        case .aurora: return "Aurora"
        case .sunset: return "Sunset"
        case .ember: return "Ember"
        case .mint: return "Mint"
        case .mono: return "Mono"
        case .byAction: return "By action"
        }
    }
    /// `tint` is the colour of what the slide adjusts, for By action.
    func colors(tint: NSColor? = nil) -> [NSColor] {
        let palette: [NSColor]
        switch self {
        case .accent: palette = [.controlAccentColor]
        case .aurora: palette = [.systemTeal, .systemBlue, .systemPurple, .systemPink]
        case .sunset: palette = [.systemOrange, .systemPink, .systemPurple]
        case .ember: palette = [.systemYellow, .systemOrange, .systemRed]
        case .mint: palette = [.systemMint, .systemGreen, .systemTeal]
        case .mono: palette = [.white]
        case .byAction: palette = [tint ?? .controlAccentColor]
        }
        return palette.map { EdgeLightStyle.accent($0) }
    }
}

/// How Kinara's lights look: a white-hot core in a coloured tube with a
/// darker rim, glowing. White alone vanished on white pages, which a
/// full-screen app puts right against the edge; the tube reads on any
/// background, in any colour.
enum EdgeLightStyle {
    /// The tube, rim to rim; its body; and the white core.
    static let tube: CGFloat = 5
    static let body: CGFloat = 3.2
    static let core: CGFloat = 1.6
    /// From the screen edge to the tube.
    static let inset: CGFloat = 1
    static let glow: CGFloat = 9
    /// Several colours drift along the edge light, one round in this long.
    static let drift: CFTimeInterval = 4
    /// The ambient light's lap of the screen, its reach either side of its
    /// brightest point, and the corners it rounds, like the display's own.
    static let lap: CFTimeInterval = 30
    static let reach: CGFloat = 220
    static let cornerRadius: CGFloat = 12

    static func accent(_ color: NSColor = .controlAccentColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? .systemBlue
    }
    /// The tube's edge: its colour darkened until it's dark enough to edge the
    /// light on a white page, so pale colours (yellow, white) get a deeper rim.
    static func rim(_ color: NSColor) -> NSColor {
        var fraction: CGFloat = 0.5
        var rim = color.blended(withFraction: fraction, of: .black) ?? color
        while luminance(rim) > 0.12, fraction < 0.85 {
            fraction += 0.05
            rim = color.blended(withFraction: fraction, of: .black) ?? color
        }
        return rim
    }

    /// WCAG relative luminance.
    static func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.040_45 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    /// The edge light for `edge` ("left", "right", "top", "bottom"): `length`
    /// along the edge, `depth` into the screen, its ends fading.
    static func layer(edge: String, length: CGFloat, depth: CGFloat, colors: [NSColor]) -> CALayer {
        let vertical = edge == "left" || edge == "right"
        let bounds = vertical ? CGRect(x: 0, y: 0, width: depth, height: length) : CGRect(x: 0, y: 0, width: length, height: depth)
        let centre = inset + tube / 2, end = tube / 2
        let line = CGMutablePath()
        switch edge {
        case "left": line.move(to: CGPoint(x: centre, y: end)); line.addLine(to: CGPoint(x: centre, y: length - end))
        case "right": line.move(to: CGPoint(x: depth - centre, y: end)); line.addLine(to: CGPoint(x: depth - centre, y: length - end))
        case "top": line.move(to: CGPoint(x: end, y: depth - centre)); line.addLine(to: CGPoint(x: length - end, y: depth - centre))
        default: line.move(to: CGPoint(x: end, y: centre)); line.addLine(to: CGPoint(x: length - end, y: centre))
        }
        let root = tube(along: line, in: bounds, colors: colors, flow: .along(vertical: vertical))
        let fade = CAGradientLayer()
        fade.frame = bounds
        fade.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.3, 0.7, 1]
        fade.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
        fade.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
        root.mask = fade
        return root
    }

    /// The path the ambient light laps: just inside every edge of `bounds`, round its corners.
    static func perimeter(of bounds: CGRect) -> CGPath {
        let centre = inset + tube / 2
        return CGPath(roundedRect: bounds.insetBy(dx: centre, dy: centre),
                      cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    /// The ambient light: one tube round the whole screen, its colours running
    /// round the centre, shown only around a soft spot of light that laps the
    /// edges. Core Animation runs the lap; nothing is drawn per frame. With
    /// Reduce Motion it stays still: a faint glow all the way round.
    static func ambient(in bounds: CGRect, colors: [NSColor], still: Bool) -> CALayer {
        let path = perimeter(of: bounds)
        let root = tube(along: path, in: bounds, colors: colors, flow: .around(CGPoint(x: bounds.midX, y: bounds.midY)))
        if still {
            root.opacity = 0.4
            return root
        }
        let spot = CAGradientLayer()
        spot.type = .radial
        spot.bounds = CGRect(x: 0, y: 0, width: reach * 2, height: reach * 2)
        spot.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        spot.locations = [0, 0.35, 1]
        spot.startPoint = CGPoint(x: 0.5, y: 0.5)
        spot.endPoint = CGPoint(x: 1, y: 1)
        spot.position = path.currentPoint
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = path
        travel.calculationMode = .paced
        travel.duration = lap
        travel.repeatCount = .infinity
        spot.add(travel, forKey: "lap")
        root.mask = spot
        return root
    }

    enum Flow {
        /// Colours along a straight light, drifting slowly.
        case along(vertical: Bool)
        /// Colours round a centre, so they change as the light travels the screen.
        case around(CGPoint)
    }

    /// The tube stroked along `path`: a glow under it, the darker rim, the
    /// coloured body and the white core.
    static func tube(along path: CGPath, in bounds: CGRect, colors: [NSColor], flow: Flow) -> CALayer {
        let colors = colors.isEmpty ? [accent()] : colors
        func stroke(_ width: CGFloat, _ color: NSColor) -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.frame = bounds
            shape.path = path
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = width
            shape.lineCap = .round
            shape.lineJoin = .round
            return shape
        }
        // Several colours: a gradient seen through the tube's shape.
        func painted(_ width: CGFloat, _ palette: [NSColor]) -> CALayer {
            guard palette.count > 1 else { return stroke(width, palette[0]) }
            let holder = CALayer()
            holder.frame = bounds
            holder.mask = stroke(width, .black)
            let gradient = CAGradientLayer()
            let loop = palette + [palette[0]]
            switch flow {
            case let .around(centre):
                gradient.type = .conic
                gradient.frame = bounds
                gradient.colors = loop.map(\.cgColor)
                gradient.startPoint = CGPoint(x: centre.x / bounds.width, y: centre.y / bounds.height)
                gradient.endPoint = CGPoint(x: gradient.startPoint.x, y: 0)
            case let .along(vertical):
                // Twice as long, the palette twice over: sliding it one length loops seamlessly.
                gradient.frame = vertical ? CGRect(x: 0, y: -bounds.height, width: bounds.width, height: bounds.height * 2)
                                          : CGRect(x: -bounds.width, y: 0, width: bounds.width * 2, height: bounds.height)
                gradient.colors = (loop + loop.dropFirst()).map(\.cgColor)
                gradient.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
                gradient.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
                let slide = CABasicAnimation(keyPath: vertical ? "position.y" : "position.x")
                slide.byValue = vertical ? bounds.height : bounds.width
                slide.duration = drift
                slide.repeatCount = .infinity
                gradient.add(slide, forKey: "drift")
            }
            holder.addSublayer(gradient)
            return holder
        }
        let root = CALayer()
        root.frame = bounds
        // Hidden under the tube; only its shadow shows, in the palette's middle colour.
        let middle = colors[colors.count / 2]
        let glowing = stroke(tube, middle)
        glowing.shadowColor = middle.cgColor
        glowing.shadowOpacity = 1
        glowing.shadowRadius = glow
        glowing.shadowOffset = .zero
        root.addSublayer(glowing)
        root.addSublayer(painted(tube, colors.map(rim)))
        root.addSublayer(painted(body, colors))
        root.addSublayer(stroke(core, NSColor.white.withAlphaComponent(0.95)))
        return root
    }
}
