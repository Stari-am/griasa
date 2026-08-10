import SwiftUI
import AppKit

/// First-launch welcome guide: what to try first, and a live permission
/// checklist with deep links into System Settings. Lives in the hub
/// (`HubTab.welcome`); reopenable from Settings → System.
struct OnboardingView: View {
    // TCC statuses aren't observable — poll them once a second while visible
    // so rows flip to green as the user grants things in System Settings.
    @State private var micGranted = Permissions.microphoneGranted
    @State private var axGranted = Permissions.accessibilityGranted
    @State private var screenGranted = Permissions.screenRecordingGranted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Griasa 🎙")
                        .font(.title.bold())
                    Text("Dictation, meeting notes, and AI actions — all running on your Mac.")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Try it now", systemImage: "1.circle.fill")
                            .font(.headline)
                        Text("Click into any text field, **hold Right ⌥ (Option)** and speak, then release. Polished text appears where your cursor is. On the very first run, Whisper downloads its speech model in the background — dictation works meanwhile via the Apple recognizer.")
                        Text("Recording a meeting: menu bar icon → Start Recording. When you stop, you get a Markdown transcript with a summary and action items.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Permissions", systemImage: "2.circle.fill")
                            .font(.headline)
                        Text("Griasa asks for three system permissions. Each unlocks only what's listed — everything else keeps working if you decline.")
                            .foregroundStyle(.secondary)

                        permissionRow(
                            "Microphone",
                            granted: micGranted,
                            pane: "Privacy_Microphone",
                            detail: "Dictation and your side of meeting recordings. Without it, all text and screen features still work.")
                        permissionRow(
                            "Accessibility",
                            granted: axGranted,
                            pane: "Privacy_Accessibility",
                            detail: "Global hotkeys, reading your selection, typing text at the cursor. Without it, every action is still available from the menu bar.")
                        permissionRow(
                            "Screen recording",
                            granted: screenGranted,
                            pane: "Privacy_ScreenCapture",
                            detail: "System audio in meetings (Zoom, Meet…) and screen OCR. Without it, recordings capture your mic only.")

                        Text("Reminders access is asked for later, the first time you use “Remind me”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                HStack {
                    Spacer()
                    Button("Done") {
                        HubController.shared.close(.welcome)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .onReceive(timer) { _ in
            micGranted = Permissions.microphoneGranted
            axGranted = Permissions.accessibilityGranted
            screenGranted = Permissions.screenRecordingGranted
        }
    }

    private func permissionRow(_ name: String, granted: Bool, pane: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name).fontWeight(.medium)
                    Spacer()
                    if !granted {
                        Button("Open Settings…") {
                            openPrivacyPane(pane)
                        }
                        .controlSize(.small)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
