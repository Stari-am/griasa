import AppKit

/// Where a feedback mail draft is being triggered from. The subject encodes
/// this so the maintainer's inbox can filter/route without opening every
/// message — "Menu bar" is a nudge, "AI provider error" is triage-worthy.
enum FeedbackTopic: String {
    case general       = "Feedback"
    case menu          = "Menu bar"
    case settings      = "Settings"
    case welcome       = "Welcome tab"
    case aiError       = "AI provider error"
    case dictation     = "Dictation"
    case snippet       = "Snippets"
    case meeting       = "Meeting notes"
    case commitments   = "Commitments"
    case people        = "People"
    case prep          = "Meeting prep"
    case newDocument   = "New document"
    case capture       = "Capture / OCR"
    case reminders     = "Reminders"
    case update        = "Update checker"
}

/// The app's outbound identity, driven entirely by BuildConfig.swift —
/// forks set their own values there (or leave them empty to hide the UI).
enum SupportLinks {
    static var donateURL: URL? {
        let raw = BuildConfig.donateURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    static var supportEmail: String {
        BuildConfig.supportEmail.trimmingCharacters(in: .whitespaces)
    }

    /// GitHub repo ("owner/name") whose Releases feed update checks.
    static var updateRepo: String {
        BuildConfig.updateRepo.trimmingCharacters(in: .whitespaces)
    }

    static var canDonate: Bool { donateURL != nil }
    static var canSendFeedback: Bool { !supportEmail.isEmpty }

    @MainActor
    static func openDonate() {
        guard let url = donateURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens a mail draft with the environment details a bug report needs.
    /// mailto: can't attach files, so version info rides in the body. The
    /// topic tags the subject so triage is possible from the inbox alone;
    /// errorDetails, when passed, is quoted at the top so the reporter can
    /// hit send without hand-copying anything.
    @MainActor
    static func sendFeedback(topic: FeedbackTopic = .general,
                             errorDetails: String? = nil) {
        guard canSendFeedback else { return }
        let subject: String
        switch topic {
        case .general:
            subject = "\(BuildConfig.appName) feedback"
        case .aiError:
            subject = "\(BuildConfig.appName) error report — \(topic.rawValue)"
        default:
            subject = "\(BuildConfig.appName) feedback — \(topic.rawValue)"
        }

        var body = ""
        if let errorDetails, !errorDetails.trimmingCharacters(in: .whitespaces).isEmpty {
            body += """
            What happened just before this?
            <briefly describe>

            Error reported by the app:
            \(errorDetails)


            """
        }
        body += """


        ---
        \(BuildConfig.appName) \(AppInfo.version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
