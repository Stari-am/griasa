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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            AppState.shared.bootstrap()
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
