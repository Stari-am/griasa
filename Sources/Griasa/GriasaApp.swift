import SwiftUI
import AppKit

@main
enum GriasaMain {
    static func main() async {
        let args = CommandLine.arguments
        // Headless mode: `Griasa --transcribe <recording folder>` runs the
        // meeting pipeline on an existing recording and exits.
        if let flagIndex = args.firstIndex(of: "--transcribe"), args.count > flagIndex + 1 {
            let folder = URL(fileURLWithPath: args[flagIndex + 1], isDirectory: true)
            let defaults = UserDefaults.standard
            let stored = AppState.parseLocales(defaults.string(forKey: "dictationLocales") ?? "")
            let locales = stored.isEmpty
                ? AppState.parseLocales(AppState.defaultDictationLocales)
                : stored
            let vocabulary = Vocabulary.combined(with: defaults.string(forKey: "customVocabulary") ?? "")
            // Provider config is read from UserDefaults inside AIFormatter.
            let output = await MeetingTranscriber.process(folder: folder,
                                                          localeIdentifiers: locales,
                                                          vocabulary: vocabulary)
            WhisperServer.shared.stop()
            print(output?.path ?? "NO_SPEECH")
            exit(output == nil ? 1 : 0)
        }
        // `Griasa --people-probe` merges and deletes an invented person against
        // the real stores, then checks nothing real moved.
        if args.contains("--people-probe") { await MainActor.run { PeopleProbe.run() } }
        // `Griasa --silence-probe` measures whether the app's own alert beep
        // comes back in through either recorded input, and exits.
        if args.contains("--silence-probe") { await SilenceProbe.run() }
        // `Griasa --open history` (or commitments, people, welcome…) launches
        // normally and opens that hub tab straight away, instead of making you
        // find it in the menu. Useful for screenshots, and for telling someone
        // exactly which screen you mean.
        if let flagIndex = args.firstIndex(of: "--open"), args.count > flagIndex + 1,
           let tab = HubTab(rawValue: args[flagIndex + 1]) {
            AppDelegate.tabToOpenOnLaunch = tab
        }
        // `--shoot <path>` writes a PNG of that tab and quits; `--size WxH`
        // sizes the window first. Documentation screenshots, reproducibly.
        if let flagIndex = args.firstIndex(of: "--shoot"), args.count > flagIndex + 1 {
            AppDelegate.shotPath = args[flagIndex + 1]
        }
        if let flagIndex = args.firstIndex(of: "--size"), args.count > flagIndex + 1 {
            let parts = args[flagIndex + 1].lowercased().split(separator: "x")
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                AppDelegate.shotSize = NSSize(width: w, height: h)
            }
        }
        // `--settings <tab name>` opens the Settings scene on that tab. SwiftUI
        // reads the selected index from UserDefaults when it builds the window,
        // so the index has to be written before the scene appears.
        if let flagIndex = args.firstIndex(of: "--settings"), args.count > flagIndex + 1 {
            let names = ["dictation", "meetings", "ai", "capture", "snippets", "projects", "system"]
            if let index = names.firstIndex(of: args[flagIndex + 1].lowercased()) {
                UserDefaults.standard.set(index, forKey: "com_apple_SwiftUI_Settings_selectedTabIndex")
                AppDelegate.openSettingsOnLaunch = true
            }
        }
        if args.contains("--demo-brief") { AppDelegate.demoBrief = true }
        GriasaApp.main()
    }
}

struct GriasaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
        } label: {
            MenuBarLabel(symbol: state.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

/// The menu-bar icon, wrapped so it can carry the `openSettings` environment
/// action. `--settings` needs to open that scene at launch, and the only public
/// opener is this action — the `showSettingsWindow:` selector silently does
/// nothing this early, and MenuBarExtra's *content* isn't built until someone
/// clicks the icon, whereas its label always is.
private struct MenuBarLabel: View {
    let symbol: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: symbol)
            .task {
                guard AppDelegate.openSettingsOnLaunch, !AppDelegate.settingsOpened else { return }
                AppDelegate.settingsOpened = true
                openSettings()
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `--open <tab>` before the app starts; opened once bootstrap has
    /// had a chance to load the stores, so the tab isn't drawn empty.
    nonisolated(unsafe) static var tabToOpenOnLaunch: HubTab?
    /// `--shoot <path>`: save a PNG of the opened tab, then quit.
    nonisolated(unsafe) static var shotPath: String?
    /// `--size WxH`: hub size to use before the shot.
    nonisolated(unsafe) static var shotSize: NSSize?
    /// `--settings <tab>`: open the Settings scene, and shoot that window.
    nonisolated(unsafe) static var openSettingsOnLaunch = false
    /// Guard so the label's task can't open Settings twice.
    nonisolated(unsafe) static var settingsOpened = false
    /// `--demo-brief`: fill the Prep tab from existing history and commitments,
    /// so the pre-meeting brief can be seen (and documented) without a calendar
    /// event and without granting Calendar access.
    nonisolated(unsafe) static var demoBrief = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            AppState.shared.bootstrap()
            if AppDelegate.demoBrief { DemoBrief.install() }
            if let tab = AppDelegate.tabToOpenOnLaunch {
                HubController.shared.open(tab)
                if let size = AppDelegate.shotSize { HubController.shared.resize(to: size) }
            }
            if let path = AppDelegate.shotPath {
                // Long enough for the stores to load, the Settings scene to
                // appear and SwiftUI to lay out; short enough that a failed
                // shot is obvious rather than a hang.
                try? await Task.sleep(for: .seconds(2))
                let target = AppDelegate.openSettingsOnLaunch
                    ? AppDelegate.settingsWindow()
                    : HubController.shared.window
                // Settings sizes itself to its content and then scrolls; give it
                // the requested height so nothing sits above the fold.
                if AppDelegate.openSettingsOnLaunch, let size = AppDelegate.shotSize {
                    target?.setContentSize(size)
                    try? await Task.sleep(for: .seconds(1))
                }
                try? await Task.sleep(for: .seconds(1))
                var ok = false
                if let target { ok = await WindowShot.save(window: target, to: path) }
                exit(ok ? 0 : 1)
            }
        }
    }

    /// The Settings window, identified by elimination: it is the visible window
    /// that isn't the hub panel and is big enough to be a real window rather
    /// than one of the slivers a MenuBarExtra app also owns.
    @MainActor
    private static func settingsWindow() -> NSWindow? {
        let hub = HubController.shared.window
        return NSApp.windows.first { window in
            window.isVisible && window !== hub
                && window.frame.width > 300 && window.frame.height > 200
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WhisperServer.shared.stop()
        Task { @MainActor in
            if AppState.shared.isRecording {
                await AppState.shared.stopRecording()
            }
        }
    }
}
