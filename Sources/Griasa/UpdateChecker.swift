import AppKit

/// Lightweight update check against the GitHub Releases feed — enough until
/// the app ships with Developer ID signing and Sparkle. Inert while
/// `BuildConfig.updateRepo` is empty.
@MainActor
enum UpdateChecker {
    static var isConfigured: Bool { !SupportLinks.updateRepo.isEmpty }

    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"

    /// Called at launch; hits the network at most once per day.
    static func checkAutomatically() {
        guard isConfigured else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        Task { await check(userInitiated: false) }
    }

    static func check(userInitiated: Bool) async {
        guard isConfigured else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        struct Release: Decodable {
            let tagName: String
            let htmlURL: String
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
            }
        }
        guard let url = URL(string: "https://api.github.com/repos/\(SupportLinks.updateRepo)/releases/latest") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName
            if latest.compare(AppInfo.version, options: .numeric) == .orderedDescending {
                // "Skip this version" is honored for background checks only —
                // an explicit menu click should always show what's out there.
                if !userInitiated,
                   UserDefaults.standard.string(forKey: skippedKey) == latest { return }
                offer(version: latest, pageURL: release.htmlURL)
            } else if userInitiated {
                inform("You're up to date",
                       "Griasa \(AppInfo.version) is the latest version.")
            }
        } catch {
            if userInitiated {
                inform("Update check failed", error.localizedDescription)
            }
        }
    }

    private static func offer(version: String, pageURL: String) {
        let alert = NSAlert()
        alert.messageText = "Griasa \(version) is available"
        alert.informativeText = "You have \(AppInfo.version). The download page opens in your browser."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: pageURL) { NSWorkspace.shared.open(url) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(version, forKey: skippedKey)
        default:
            break
        }
    }

    private static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
