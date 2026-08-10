import AppKit

/// The four system-wide capture actions, each with a menu item and a
/// configurable global hotkey. Clipboard-AI is exposed as a menu submenu over
/// the user's presets, so it has no entry here.
enum CaptureAction: String, CaseIterable, Identifiable {
    case remind
    case ocr
    case reply
    case askProject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remind: return "Remind me"
        case .ocr: return "OCR region"
        case .reply: return "Draft reply"
        case .askProject: return "Ask project"
        }
    }

    var emoji: String {
        switch self {
        case .remind: return "⏰"
        case .ocr: return "🔤"
        case .reply: return "💬"
        case .askProject: return "🗂"
        }
    }

    /// UserDefaults key holding the user's chosen hotkey (matches the
    /// @AppStorage keys used by the Capture settings tab).
    var storageKey: String {
        switch self {
        case .remind: return "captureRemindHotkey"
        case .ocr: return "captureOCRHotkey"
        case .reply: return "captureReplyHotkey"
        case .askProject: return "captureAskProjectHotkey"
        }
    }

    var defaultHotkey: String {
        switch self {
        case .remind: return "ctrl+opt+cmd+r"
        case .ocr: return "ctrl+opt+cmd+o"
        case .reply: return "ctrl+opt+cmd+y"
        case .askProject: return "ctrl+opt+cmd+p"
        }
    }

    /// Absent key → default hotkey; explicit empty string → disabled by the user.
    var currentHotkey: String {
        UserDefaults.standard.object(forKey: storageKey) as? String ?? defaultHotkey
    }
}

/// Runs the capture actions, wiring capture (selection / screen region / window
/// / clipboard) → optional Claude transform → the shared result popup.
@MainActor
enum CaptureController {
    static func run(_ action: CaptureAction) {
        MenuBarPanel.dismiss()
        switch action {
        case .remind: remind()
        case .ocr: ocrRegion()
        case .reply: draftReply()
        case .askProject: AskProjectWindowController.shared.show()
        }
    }

    // MARK: - Remind me

    private static func remind() {
        Task { @MainActor in
            let sourceApp = NSWorkspace.shared.frontmostApplication
            // Snapshot where the user is (app, window title, browser tab URL)
            // before any Griasa UI can steal focus.
            var origin = ReminderSource.capture()

            // Prefer a live text selection; otherwise let the user drag a region
            // and OCR whatever is inside it. Region clips are also saved as an
            // image so the reminder keeps what the text was read from.
            var text = await SelectionGrabber.grab()
            var imageURL: URL?
            if text == nil {
                guard let image = await RegionCapture.capture() else { return }
                text = await ocrText(from: image)
                imageURL = saveClip(image)
            }
            guard let source = text, !source.isEmpty else {
                if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
                PopupController.shared.showMessage(
                    title: "⏰ Remind me",
                    message: "No text found. Select some text, or drag over something with text.")
                return
            }

            origin?.anchor(to: source)

            // Slack-style time menu at the cursor.
            guard let choice = RemindMenu.choose() else {
                if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
                return
            }

            switch choice {
            case .custom:
                ReminderComposer.shared.show(text: source, origin: origin, imageURL: imageURL)
            case .fromText:
                guard AIFormatter.isConfigured else {
                    PopupController.shared.showMessage(
                        title: "⏰ Remind me",
                        message: "\"From the text\" needs an AI provider (Settings → AI & Actions). The fixed time options work without one.")
                    return
                }
                PopupController.shared.showLoading(title: "⏰ Remind me", canReplace: false, sourceApp: sourceApp)
                await createReminder(from: source, origin: origin, imageURL: imageURL)
            case .at(let due):
                PopupController.shared.showLoading(title: "⏰ Remind me", canReplace: false, sourceApp: sourceApp)
                await createReminder(from: source, dueOverride: due, origin: origin, imageURL: imageURL)
            }
        }
    }

    /// With `dueOverride`, Claude only supplies a clean title (skipped without
    /// a key — a fixed-time reminder works fully offline). Without it, Claude
    /// extracts the due date from the text. `origin` records where the text
    /// was captured so the reminder links back there; `imageURL` is the saved
    /// region clip when the text came from OCR.
    static func createReminder(from text: String, dueOverride: Date? = nil,
                               origin: ReminderSource? = nil, imageURL: URL? = nil) async {
        var title: String?
        var notes: String?
        var due: Date?
        if AIFormatter.isConfigured, let parsed = await CaptureAI.parseReminder(text: text) {
            title = parsed.title
            notes = parsed.notes
            due = parsed.due
        }
        if title == nil {
            guard dueOverride != nil else {
                PopupController.shared.showResult(AIFormatter.isConfigured
                    ? "Couldn't work out a reminder from that text."
                    : "Configure an AI provider in Settings → AI & Actions, or pick a fixed time from the menu.")
                return
            }
            title = localTitle(text)
            notes = text
        }
        if let dueOverride { due = dueOverride }
        var extras: [String] = []
        if let origin { extras.append(origin.notesBlock) }
        if let imageURL { extras.append("🖼 Clip: \(imageURL.path)") }
        if !extras.isEmpty {
            notes = ((notes.map { $0 + "\n\n" }) ?? "") + extras.joined(separator: "\n")
        }

        guard let title else { return }
        guard await RemindersService.requestAccess() else {
            PopupController.shared.showResult("""
            Reminders access is off — it's only needed to create the reminder itself; everything else in Griasa works without it. Enable it in System Settings → Privacy & Security → Reminders, then try again.

            What I understood: \(title)
            """)
            return
        }
        do {
            // EventKit can't attach files to reminders, so the clip rides as
            // the reminder's link (and a path line in the notes) instead.
            try RemindersService.create(title: title, notes: notes, due: due,
                                        url: origin?.url ?? imageURL)
            var message = "Reminder set: \(title)"
            if let due {
                message += "\n📅 \(due.formatted(date: .abbreviated, time: .shortened))"
            }
            if let notes, !notes.isEmpty {
                message += "\n\n\(notes)"
            }
            PopupController.shared.showResult(message)
            HistoryStore.shared.add(kind: .action, title: "Reminder", text: message,
                                    filePath: imageURL?.path)
        } catch {
            PopupController.shared.showResult("Couldn't save the reminder: \(error.localizedDescription)")
        }
    }

    /// Saves a region clip so the reminder can point back at the pixels, not
    /// just the OCR text. Only "Remind me" keeps clips; plain OCR doesn't.
    private static func saveClip(_ image: NSImage) -> URL? {
        guard let data = image.pngRepresentation else { return nil }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Griasa/Reminders", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("clip-\(formatter.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func localTitle(_ text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }

    // MARK: - OCR region

    private static func ocrRegion() {
        Task { @MainActor in
            let sourceApp = NSWorkspace.shared.frontmostApplication
            guard let image = await RegionCapture.capture() else { return }

            PopupController.shared.showLoading(title: "🔤 OCR region", canReplace: false, sourceApp: sourceApp)
            let text = await ocrText(from: image)
            guard !text.isEmpty else {
                PopupController.shared.showResult("No text found in the selection.")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            PopupController.shared.showResult(text)
            HistoryStore.shared.add(kind: .action, title: "OCR", text: text)
        }
    }

    // MARK: - Draft reply

    private static func draftReply() {
        Task { @MainActor in
            let sourceApp = NSWorkspace.shared.frontmostApplication
            guard let image = await WindowCapture.captureFrontWindow() else {
                PopupController.shared.showMessage(
                    title: "💬 Draft reply",
                    message: "Couldn't read the active window. Click the chat window, then try again.")
                return
            }
            guard AIFormatter.isConfigured else {
                PopupController.shared.showMessage(
                    title: "💬 Draft reply",
                    message: "Configure an AI provider in Settings → AI & Actions to use this feature.")
                return
            }

            PopupController.shared.showLoading(title: "💬 Draft reply", canReplace: true, sourceApp: sourceApp)
            let transcript = await ocrText(from: image)
            guard !transcript.isEmpty else {
                PopupController.shared.showResult("Couldn't read any text from the window.")
                return
            }
            if let reply = await CaptureAI.draftReply(transcript: transcript) {
                PopupController.shared.showResult(reply)
                HistoryStore.shared.add(kind: .action, title: "Draft reply", text: reply)
            } else {
                PopupController.shared.showResult("Request failed — check your network connection and API key.")
            }
        }
    }

    // MARK: - Clipboard-AI

    /// Runs an existing prompt preset against the current clipboard text.
    static func runPresetOnClipboard(_ preset: PromptPreset) {
        MenuBarPanel.dismiss()
        Task { @MainActor in
            let clipboard = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !clipboard.isEmpty else {
                PopupController.shared.showMessage(title: preset.name, message: "The clipboard is empty.")
                return
            }
            guard AIFormatter.isConfigured else {
                PopupController.shared.showMessage(
                    title: preset.name,
                    message: "Configure an AI provider in Settings → AI & Actions to use this feature.")
                return
            }
            PopupController.shared.showLoading(
                title: "\(preset.emoji) \(preset.name) · clipboard",
                canReplace: false,
                sourceApp: NSWorkspace.shared.frontmostApplication)
            if let result = await SelectionAI.run(preset: preset, text: clipboard) {
                PopupController.shared.showResult(result)
                HistoryStore.shared.add(kind: .action, title: preset.name, text: result)
            } else {
                PopupController.shared.showResult("Request failed — check your network connection and API key.")
            }
        }
    }

    // MARK: - Helpers

    /// Encodes to PNG on the main thread, then runs Vision off it (Data is
    /// Sendable; NSImage/CGImage are not).
    private static func ocrText(from image: NSImage) async -> String {
        guard let data = image.pngRepresentation else { return "" }
        return await Task.detached(priority: .userInitiated) {
            OCR.recognize(imageData: data)
        }.value
    }
}
