import AppKit

/// A visible alert for account-level AI failures (no credits, invalid key,
/// spend limit). These break every AI feature at once, yet without this the
/// only trace is a menu-bar error line — e.g. ;tldr silently types itself
/// back and looks like the app is broken. Throttled so a burst of failing
/// requests produces one alert, not a stack of them.
@MainActor
enum AIAccountAlert {
    private static var lastShown: Date?
    private static let minInterval: TimeInterval = 600

    static func show(_ error: AIProviderError) {
        if let last = lastShown, Date().timeIntervalSince(last) < minInterval { return }
        lastShown = Date()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(error.provider) is rejecting AI requests"
        alert.informativeText = """
        \(error.accountAdvice)

        Details: \(error.errorDescription ?? "no details")

        AI features (snippets like ;tldr, meeting notes, capture actions) won't work until this is fixed. Dictation keeps working — it's local.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        if SupportLinks.canSendFeedback {
            alert.addButton(withTitle: "Report this problem…")
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .alertThirdButtonReturn:
            SupportLinks.sendFeedback(topic: .aiError,
                                      errorDetails: error.errorDescription)
        default:
            break
        }
    }
}
