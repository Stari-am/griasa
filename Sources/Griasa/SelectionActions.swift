import AppKit
import Carbon.HIToolbox

/// A user-configurable modifier+letter combination, stored as e.g.
/// "ctrl+opt+cmd+s".
struct KeyCombo: Equatable {
    var control = false
    var option = false
    var shift = false
    var command = false
    var key: String  // single lowercase character

    static func parse(_ stored: String) -> KeyCombo? {
        var combo = KeyCombo(key: "")
        for part in stored.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "ctrl", "control": combo.control = true
            case "opt", "option", "alt": combo.option = true
            case "shift": combo.shift = true
            case "cmd", "command": combo.command = true
            default: combo.key = part
            }
        }
        guard combo.key.count == 1,
              combo.control || combo.option || combo.command else { return nil }
        return combo
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if control { flags.insert(.control) }
        if option { flags.insert(.option) }
        if shift { flags.insert(.shift) }
        if command { flags.insert(.command) }
        return flags
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.control, .option, .shift, .command]) == modifierFlags
        else { return false }
        // Match the physical key: charactersIgnoringModifiers follows the
        // active input source, so on e.g. a Cyrillic layout the R key yields
        // "к" and a character comparison never fires.
        if let code = KeyCombo.keyCodes[key] {
            return event.keyCode == code
        }
        return event.charactersIgnoringModifiers?.lowercased() == key
    }

    /// kVK_ANSI virtual key codes for the keys a combo can use. Layout-independent.
    static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + key.uppercased()
    }
}

/// Global hotkeys for prompt presets. Matches every preset that has a hotkey
/// assigned; combos are read from UserDefaults, so Settings changes apply
/// instantly.
final class ActionHotkeys {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onPreset: (UUID) -> Void
    private let onCapture: (CaptureAction) -> Void

    init(onPreset: @escaping (UUID) -> Void, onCapture: @escaping (CaptureAction) -> Void) {
        self.onPreset = onPreset
        self.onCapture = onCapture
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            (self?.handle(event) ?? false) ? nil : event
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Cheap early-out: preset hotkeys always use a real modifier.
        guard !event.modifierFlags.intersection([.control, .option, .command]).isEmpty else { return false }
        for preset in PresetStore.presetsWithHotkeys() {
            if let combo = KeyCombo.parse(preset.hotkey), combo.matches(event) {
                onPreset(preset.id)
                return true
            }
        }
        for action in CaptureAction.allCases {
            if let combo = KeyCombo.parse(action.currentHotkey), combo.matches(event) {
                onCapture(action)
                return true
            }
        }
        return false
    }
}

/// Reads the current selection from any app by synthesizing ⌘C, then restores
/// the user's clipboard.
enum SelectionGrabber {
    @MainActor
    static func grab() async -> String? {
        // Wait for the user to release the hotkey's modifier keys first.
        // Posting a synthetic ⌘C while modifiers are physically held can be
        // delivered to some apps as a different combo — or as a plain
        // character, which *replaces the selection* with that character.
        await waitForModifiersRelease()

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        } ?? []
        let changeCountBefore = pasteboard.changeCount

        sendCopy()

        var text: String?
        for _ in 0..<20 { // up to ~1 s for slow apps
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != changeCountBefore {
                text = pasteboard.string(forType: .string)
                break
            }
        }

        pasteboard.clearContents()
        for (type, data) in saved {
            pasteboard.setData(data, forType: type)
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func waitForModifiersRelease() async {
        for _ in 0..<30 { // up to 1.5 s
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            if flags.intersection(held).isEmpty { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func sendCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_C)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// AI call behind a prompt preset.
enum SelectionAI {
    static func run(preset: PromptPreset, text: String) async -> String? {
        // Bound extreme selections; ~200k chars is far beyond any sane use.
        let input = text.count > 200_000 ? String(text.prefix(200_000)) : text
        return try? await AIFormatter.complete(system: preset.systemPrompt,
                                               user: input,
                                               tier: .smart,
                                               maxTokens: 8192)
    }
}
