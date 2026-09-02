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
    @State private var calendarGranted = Permissions.calendarGranted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Griasa 👋")
                        .font(.title.bold())
                    Text("What was promised, by whom, and what you walk into next — kept on this Mac.")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Try it now", systemImage: "1.circle.fill")
                            .font(.headline)

                        Text("**Record a conversation.** Menu bar icon → Start Recording. Griasa captures your microphone *and* what the Mac is playing, so the other side of a Zoom or Meet call is in the transcript too. When you stop, you get Markdown notes with a summary — and the promises made in that call, split into what you took on and what you are waiting on.")
                        Text("**Then look at ✅ Commitments and 👥 People.** Everything found in that recording is filed against the person who said it, so a page per colleague builds itself as you record.")
                        Text("**Before your next call, the 📋 Prep tab opens on its own** a few minutes ahead: who is on it, what each of you owes the other, and what you last discussed with exactly these people. It never takes keyboard focus, so it cannot interrupt what you are typing.")
                        Text("**Dictation:** click into any text field, **hold Right ⌥ (Option)** and speak, then release. On the very first run Whisper downloads its speech model in the background; dictation works meanwhile via the Apple recognizer.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Permissions", systemImage: "2.circle.fill")
                            .font(.headline)
                        Text("Each one unlocks only what is listed against it — everything else keeps working if you decline.")
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
                        // Asked for at launch rather than at first use, because the
                        // brief is on by default and has to know about a meeting
                        // before the meeting — there is no later moment to ask.
                        permissionRow(
                            "Calendar",
                            granted: calendarGranted,
                            pane: "Privacy_Calendars",
                            detail: "The pre-meeting brief, and abbreviations that expand to your real free slots. Read-only: Griasa never writes to your calendar. Without it the Prep tab stays empty — or turn the brief off in Settings → Meetings and you will not be asked again.")

                        Text("Reminders access is asked for later, the first time you use “Remind me”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Optional: the assistant you already have open", systemImage: "3.circle.fill")
                            .font(.headline)
                        Text("Griasa can answer questions from Claude, Codex, Cursor or anything else that speaks MCP — what is open, who owes what, what the next meeting holds — without you opening Griasa. **Off until you switch it on** in Settings → System → AI assistants (MCP), which will also copy a ready configuration for your client.")
                        Text("Reading only: an assistant can change nothing. But what it reads goes wherever that assistant sends its context, which is why a meeting's summary and its transcript are separate questions — asking about promises cannot pull whole conversations into a cloud model by accident.")
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
            calendarGranted = Permissions.calendarGranted
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
