import AppKit

/// Watches modifier keys globally and fires press/release callbacks for
/// hold-to-dictate. Requires the app to be trusted under
/// System Settings → Privacy & Security → Accessibility.
final class HotkeyMonitor {
    enum Key: String, CaseIterable, Identifiable {
        case rightOption
        case rightCommand
        case fn

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .rightOption: return "Right Option (⌥)"
            case .rightCommand: return "Right Command (⌘)"
            case .fn: return "Fn / Globe"
            }
        }
    }

    private let key: Key
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    init(key: Key, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.key = key
        self.onPress = onPress
        self.onRelease = onRelease

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func handle(_ event: NSEvent) {
        let down: Bool
        switch key {
        case .rightOption:
            guard event.keyCode == 61 else { return }
            down = event.modifierFlags.contains(.option)
        case .rightCommand:
            guard event.keyCode == 54 else { return }
            down = event.modifierFlags.contains(.command)
        case .fn:
            guard event.keyCode == 63 else { return }
            down = event.modifierFlags.contains(.function)
        }
        guard down != isDown else { return }
        isDown = down
        TypingTrace.log("hotkey \(down ? "press" : "release")")
        down ? onPress() : onRelease()
    }
}
