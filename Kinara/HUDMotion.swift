import AppKit
import QuartzCore

/// One motion language for every floating HUD: a quick ease-out rise with a
/// fade in, and a softer fade with a slight drift out. Core Animation runs it,
/// so nothing ticks on the main thread, and Reduce Motion keeps only the fade.
enum HUDMotion {
    /// Fast out, gentle settle: close to the system's own HUD timing.
    static let settle = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let leave = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Pure: where an entrance starts and an exit ends, for a resting origin.
    static func displaced(_ origin: NSPoint, by offset: CGVector, scale: CGFloat = 1) -> NSPoint {
        NSPoint(x: origin.x + offset.dx * scale, y: origin.y + offset.dy * scale)
    }

    /// Shows a window that is already at its resting origin.
    static func enter(_ window: NSWindow, offset: CGVector, fadeOnly: Bool = false) {
        let rest = window.frame.origin
        let moves = !fadeOnly && !reduceMotion
        window.alphaValue = 0
        if moves { window.setFrameOrigin(displaced(rest, by: offset)) }
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = moves ? 0.3 : 0.14
            context.timingFunction = settle
            window.animator().alphaValue = 1
            if moves { window.animator().setFrame(NSRect(origin: rest, size: window.frame.size), display: true) }
        }
    }

    /// Fades out (drifting back the way it came), then calls completion.
    /// Completion also runs when a newer animation supersedes this one, so
    /// callers check that they still mean to hide.
    static func exit(_ window: NSWindow, offset: CGVector, fadeOnly: Bool = false, completion: @escaping () -> Void) {
        let moves = !fadeOnly && !reduceMotion
        let end = displaced(window.frame.origin, by: offset, scale: 0.6)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = moves ? 0.22 : 0.14
            context.timingFunction = leave
            window.animator().alphaValue = 0
            if moves { window.animator().setFrame(NSRect(origin: end, size: window.frame.size), display: true) }
        }, completionHandler: completion)
    }

    /// A new request arrived mid-exit: glide straight back instead of blinking.
    static func restore(_ window: NSWindow, to origin: NSPoint) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = settle
            window.animator().alphaValue = 1
            window.animator().setFrame(NSRect(origin: origin, size: window.frame.size), display: true)
        }
    }
}
