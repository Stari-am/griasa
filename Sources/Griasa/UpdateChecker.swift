import AppKit

/// Looks at the GitHub Releases feed for a newer version: at launch and then
/// once a day while the app runs, never during a recording. Inert while
/// `BuildConfig.updateRepo` is empty. The rules are in `UpdateRules`.
@MainActor
enum UpdateChecker {
    static var isConfigured: Bool { !SupportLinks.updateRepo.isEmpty }

    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"
    private static var timer: Timer?

    /// Called at launch: checks now if a day has passed, and keeps asking
    /// every hour after that.
    static func checkAutomatically() {
        guard isConfigured else { return }
        checkIfDue()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: UpdateRules.tick, repeats: true) { _ in
            Task { @MainActor in checkIfDue() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func checkIfDue() {
        // A window over a call is the one thing worse than a late update:
        // try again on a later tick.
        guard !AppState.shared.isRecording else { return }
        let stamp = UserDefaults.standard.double(forKey: lastCheckKey)
        let last = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        guard UpdateRules.isDue(lastCheck: last, now: Date()) else { return }
        Task { await check(userInitiated: false) }
    }

    static var install: UpdateRules.Install {
        UpdateRules.install(appPath: Bundle.main.bundlePath) { FileManager.default.fileExists(atPath: $0) }
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
            let latest = UpdateRules.version(fromTag: release.tagName)
            if UpdateRules.isNewer(latest, than: AppInfo.version) {
                // "Skip this version" is honored for background checks only —
                // an explicit menu click should always show what's out there.
                if !userInitiated,
                   UserDefaults.standard.string(forKey: skippedKey) == latest { return }
                // A recording may have started while the request was out.
                if !userInitiated, AppState.shared.isRecording { return }
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
        let brew: String? = { if case .homebrew(let brew) = install { return brew } else { return nil } }()
        if brew != nil {
            alert.informativeText = "You have \(AppInfo.version), installed with Homebrew. Griasa quits, Terminal runs “brew upgrade --cask griasa”, and Griasa opens again when it is done."
            alert.addButton(withTitle: "Update with Homebrew")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Skip This Version")
            alert.addButton(withTitle: "What's New")
        } else {
            alert.informativeText = "You have \(AppInfo.version). The download page opens in your browser."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Skip This Version")
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let brew {
                updateWithHomebrew(brew: brew)
            } else if let url = URL(string: pageURL) {
                NSWorkspace.shared.open(url)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(version, forKey: skippedKey)
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            if let url = URL(string: pageURL) { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    /// Hands the update to Terminal, where the user sees what brew does, and
    /// quits so the app is not replaced while it runs.
    private static func updateWithHomebrew(brew: String) {
        guard !AppState.shared.isRecording else {
            inform("Finish the recording first",
                   "Griasa has to quit to be updated. Stop the recording, then choose Check for Updates… in Settings.")
            return
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "am.stari.griasa"
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Update Griasa.command")
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        do {
            try UpdateRules.homebrewScript(brew: brew, bundleID: bundleID)
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            inform("Couldn't start the update", "Run “brew upgrade --cask griasa” in Terminal. (\(error.localizedDescription))")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let open: (Error?) -> Void = { error in
            Task { @MainActor in
                if let error {
                    inform("Couldn't open Terminal", "Run “brew upgrade --cask griasa” in Terminal. (\(error.localizedDescription))")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
        if let terminal {
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration) { _, error in open(error) }
        } else {
            NSWorkspace.shared.open(script, configuration: configuration) { _, error in open(error) }
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
