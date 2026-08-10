import AppKit

/// A small bottom-center pill shown while a snippet render takes noticeable
/// time. AI-backed snippets ({ai:}, {slot}) can run for seconds after the
/// typed trigger has already been erased — without feedback that silence
/// reads as "snippets are broken". Borderless, non-activating, click-through:
/// it must never steal focus from the field the user is typing in.
@MainActor
final class SnippetHUD {
    static let shared = SnippetHUD()

    private var window: NSWindow?
    private var label: NSTextField?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        hideTask?.cancel()
        let (window, label) = ensureWindow()
        label.stringValue = text
        label.sizeToFit()

        let padding = NSSize(width: 18, height: 10)
        let size = NSSize(width: label.frame.width + padding.width * 2,
                          height: label.frame.height + padding.height * 2)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        window.setFrame(NSRect(x: screen.midX - size.width / 2,
                               y: screen.minY + 120,
                               width: size.width, height: size.height),
                        display: true)
        label.frame.origin = NSPoint(x: padding.width, y: padding.height)

        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 1
        }
    }

    /// Show briefly, then fade out — for terminal states like a failure.
    func flash(_ text: String, seconds: TimeInterval = 1.6) {
        show(text)
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                if self.window?.alphaValue == 0 { self.window?.orderOut(nil) }
            }
        })
    }

    private func ensureWindow() -> (NSWindow, NSTextField) {
        if let window, let label { return (window, label) }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        effect.addSubview(label)

        let window = NSWindow(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.contentView = effect

        self.window = window
        self.label = label
        return (window, label)
    }
}
