import AppKit

/// Griasa's own menu-bar glyph: a speech bubble with a short waveform inside.
///
/// It used to be the SF Symbols microphone, and people who had just installed
/// the app could not find it — a microphone is what every dictation app, the
/// system's own recording indicator and half the menu bar already show. The
/// bubble says "conversation" rather than "microphone" and matches nothing
/// else up there. Drawn in code as a template image, so it follows the menu
/// bar's light, dark and tinted appearances like a system icon.
@MainActor
enum MenuBarMark {
    enum Variant {
        case idle
        /// Holding the dictation key: the bubble fills in.
        case listening
        /// Recording a conversation: a dot in the corner, like a camera's.
        case recording
        /// Waiting for speech recognition or the AI: dots instead of the wave.
        case processing
    }

    private static var cache: [String: NSImage] = [:]

    /// Local builds get a small square in the corner, so the copy under test
    /// can be told from the installed one at a glance.
    static func image(_ variant: Variant, devBuild: Bool) -> NSImage {
        let key = "\(variant)-\(devBuild)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            draw(variant, devBuild: devBuild)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Griasa"
        cache[key] = image
        return image
    }

    private static func draw(_ variant: Variant, devBuild: Bool) {
        guard let context = NSGraphicsContext.current else { return }
        NSColor.black.set()

        // Body with a tail at the bottom left.
        let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4, width: 16, height: 10.5),
                                xRadius: 4, yRadius: 4)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 4.2, y: 4.6))
        tail.line(to: NSPoint(x: 3.2, y: 1))
        tail.line(to: NSPoint(x: 8.4, y: 4.6))
        tail.close()

        if variant == .listening {
            body.fill()
            tail.fill()
        } else {
            body.lineWidth = 1.5
            body.stroke()
            tail.fill()
            // The tail's top edge would cross the outline; clear the gap.
            context.compositingOperation = .clear
            NSBezierPath(rect: NSRect(x: 4.6, y: 4.75, width: 3.2, height: 0.7)).fill()
            context.compositingOperation = .sourceOver
        }

        // Contents: four bars, or three dots while processing. Knocked out of
        // the filled bubble, drawn on the hollow one.
        if variant == .listening { context.compositingOperation = .destinationOut }
        if variant == .processing {
            for x in [5.5, 9.5, 13.5] {
                NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: 8.15, width: 2.2, height: 2.2)).fill()
            }
        } else {
            for (x, height) in [(5.6, 3.0), (8.2, 6.2), (10.8, 4.4), (13.4, 2.2)] {
                NSBezierPath(roundedRect: NSRect(x: x - 0.8, y: 9.25 - height / 2,
                                                 width: 1.6, height: height),
                             xRadius: 0.8, yRadius: 0.8).fill()
            }
        }
        context.compositingOperation = .sourceOver

        if variant == .recording { badge(context) { NSBezierPath(ovalIn: $0) } }
        if devBuild { badge(context, low: true) { NSBezierPath(rect: $0.insetBy(dx: 0.4, dy: 0.4)) } }
    }

    /// A small shape in a corner, separated from the bubble by a cleared ring
    /// so it reads as its own mark rather than a bump on the outline.
    private static func badge(_ context: NSGraphicsContext, low: Bool = false,
                              shape: (NSRect) -> NSBezierPath) {
        let rect = low ? NSRect(x: 15, y: 0, width: 5, height: 5)
                       : NSRect(x: 14.6, y: 10.6, width: 5.4, height: 5.4)
        context.compositingOperation = .clear
        shape(rect.insetBy(dx: -1.4, dy: -1.4)).fill()
        context.compositingOperation = .sourceOver
        shape(rect).fill()
    }
}
