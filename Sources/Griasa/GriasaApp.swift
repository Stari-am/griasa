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
            Image(systemName: state.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            AppState.shared.bootstrap()
            if let tab = AppDelegate.tabToOpenOnLaunch {
                HubController.shared.open(tab)
                if let size = AppDelegate.shotSize { HubController.shared.resize(to: size) }
            }
            if let path = AppDelegate.shotPath {
                // Long enough for the stores to load and SwiftUI to lay out;
                // short enough that a failed shot is obvious rather than a hang.
                try? await Task.sleep(for: .seconds(3))
                var ok = false
                if let window = HubController.shared.window {
                    ok = await WindowShot.save(window: window, to: path)
                }
                exit(ok ? 0 : 1)
            }
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
