import AppKit
import ApplicationServices

/// Where a reminder was captured from, so the user can find their way back.
/// Browsers get the tab URL (with a scroll-to-text anchor when the reminder
/// came from a selection); other apps get the focused window title — in Slack
/// and Telegram that names the workspace/channel/chat. Neither app exposes a
/// per-message link outside its own UI, so the title is the best breadcrumb.
struct ReminderSource {
    var appName: String
    var bundleID: String
    var detail: String?  // focused-window title, or the browser tab title
    var url: URL?        // browser tab URL

    /// Lines appended to the reminder notes.
    var notesBlock: String {
        var lines = ["📍 From: \(appName)" + (detail.map { " — \($0)" } ?? "")]
        if let url { lines.append(url.absoluteString) }
        return lines.joined(separator: "\n")
    }

    /// Snapshot of the frontmost app. Call before showing any Griasa UI.
    @MainActor
    static func capture() -> ReminderSource? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }
        let name = app.localizedName ?? bundleID
        if let (url, title) = browserTab(bundleID: bundleID) {
            return ReminderSource(appName: name, bundleID: bundleID, detail: title, url: url)
        }
        let title = focusedWindowTitle(pid: app.processIdentifier)
        return ReminderSource(appName: name, bundleID: bundleID, detail: title, url: nil)
    }

    /// Adds a `#:~:text=` scroll-to-text fragment so supporting browsers
    /// (Safari 16.1+, Chrome, Edge, Brave…) jump straight to the captured
    /// text. Harmless when the text isn't found on the page.
    mutating func anchor(to text: String) {
        guard let url else { return }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let words = firstLine.split(separator: " ").prefix(8).joined(separator: " ")
        let snippet = String(words.prefix(80)).trimmingCharacters(in: .whitespaces)
        // Encode everything non-alphanumeric: "-" and "," are syntax inside
        // a text directive, and spaces must be %20.
        guard !snippet.isEmpty,
              let encoded = snippet.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return }
        let sep = url.absoluteString.contains("#") ? ":~:text=" : "#:~:text="
        self.url = URL(string: url.absoluteString + sep + encoded) ?? url
    }

    // MARK: - Browsers (Apple Events)

    private static let chromiumIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "org.chromium.Chromium", "company.thebrowser.Browser",
        "ru.yandex.desktop.yandex-browser",
    ]

    /// First run per browser triggers the macOS Automation permission prompt.
    @MainActor
    private static func browserTab(bundleID: String) -> (URL, String?)? {
        let script: String
        if bundleID == "com.apple.Safari" {
            script = """
            tell application id "com.apple.Safari" to return (URL of front document) & linefeed & (name of front document)
            """
        } else if chromiumIDs.contains(bundleID) {
            script = """
            tell application id "\(bundleID)" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)
            """
        } else {
            return nil  // Firefox etc. — no scriptable tabs; window title still helps
        }
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?
            .executeAndReturnError(&error).stringValue else { return nil }
        let parts = result.split(separator: "\n", maxSplits: 1).map(String.init)
        guard let first = parts.first,
              let url = URL(string: first.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (url, parts.count > 1 ? parts[1] : nil)
    }

    // MARK: - Window title (Accessibility)

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let windowElement = window as! AXUIElement  // type checked above
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            windowElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        let text = title as? String
        return (text?.isEmpty ?? true) ? nil : text
    }
}
