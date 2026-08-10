import SwiftUI
import AppKit

/// Closes the MenuBarExtra panel so it stops covering the window the user is
/// acting on — capture actions (region drag, window OCR) and result popups
/// overlay the screen. A no-op when an action is triggered by a hotkey, since
/// the panel isn't open then.
enum MenuBarPanel {
    @MainActor
    static func dismiss() {
        // Primary: match Apple's private MenuBarExtra window class.
        let named = NSApp.windows.filter { $0.isVisible && $0.className.contains("MenuBarExtra") }
        if !named.isEmpty {
            named.forEach { $0.close() }
            return
        }
        // Fallback if the private class name ever changes: the panel is untitled
        // and floats at/above status-bar level, unlike our titled result/Settings
        // windows. Must NOT touch NSStatusBarWindow — that's the tray icon
        // itself; closing it leaves the icon dead to clicks.
        for window in NSApp.windows
        where window.isVisible
            && !window.styleMask.contains(.titled)
            && window.level.rawValue >= NSWindow.Level.statusBar.rawValue
            && !window.className.contains("StatusBar") {
            window.close()
        }
    }
}

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var presets = PresetStore.shared
    @ObservedObject private var snippets = SnippetStore.shared
    @ObservedObject private var stats = UsageStats.shared
    @ObservedObject private var commitmentStore = CommitmentStore.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Dictation status
            HStack {
                Image(systemName: state.dictationStatus == .listening ? "mic.fill" : "mic")
                    .foregroundStyle(state.dictationStatus == .listening ? .red : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dictation: \(state.dictationStatus.label)")
                        .font(.headline)
                    Text("Hold \(state.hotkeyChoice.displayName) and speak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let setupText = state.whisperSetup.menuText {
                HStack(spacing: 6) {
                    if case .fallback = state.whisperSetup {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(setupText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !state.lastTranscript.isEmpty {
                Text(state.lastTranscript)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            // Conversation recording
            HStack {
                Image(systemName: state.isRecording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(state.isRecording ? .red : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.isRecording ? "Recording conversation…" : "Conversation recording off")
                        .font(.headline)
                    if let started = state.recordingStartedAt {
                        Text("Started \(started.formatted(date: .omitted, time: .shortened)) — mic + system audio")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Captures your mic and everything the Mac plays")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button(state.isRecording ? "Stop Recording" : "Start Recording") {
                Task {
                    if state.isRecording {
                        await state.stopRecording()
                    } else {
                        await state.startRecording()
                    }
                }
            }
            .keyboardShortcut("r")

            if state.liveNotesEnabled && state.isRecording {
                Button("Show Live Notes") { HubController.shared.open(.recording) }
            }

            if state.isProcessingRecording {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing and summarizing meeting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let transcript = state.lastMeetingTranscript {
                Button("Open Last Meeting Transcript") {
                    NSWorkspace.shared.open(transcript)
                }
            }

            HStack {
                Button("History…") { HistoryWindowController.shared.show() }
                Button("Recordings Folder") { state.openRecordingsFolder() }
            }
            Button("Process a Recording Folder…") {
                MenuBarPanel.dismiss()
                state.pickAndProcessRecording()
            }
            .help("Transcribe and summarize an existing recording — e.g. a session that was interrupted before it finished.")
            .disabled(state.isProcessingRecording)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Apply to selected text (any app)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(presets.presets) { preset in
                    Button {
                        state.runPreset(preset)
                    } label: {
                        HStack {
                            Text("\(preset.emoji)  \(preset.name)")
                            Spacer()
                            if let combo = KeyCombo.parse(preset.hotkey) {
                                Text(combo.display).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Capture (any app)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(CaptureAction.allCases) { action in
                    Button {
                        CaptureController.run(action)
                    } label: {
                        HStack {
                            Text("\(action.emoji)  \(action.title)")
                            Spacer()
                            if let combo = KeyCombo.parse(action.currentHotkey) {
                                Text(combo.display).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Menu("Run on clipboard") {
                    ForEach(presets.presets) { preset in
                        Button("\(preset.emoji)  \(preset.name)") {
                            CaptureController.runPresetOnClipboard(preset)
                        }
                    }
                }
                if !snippets.active.isEmpty {
                    Menu("Insert snippet") {
                        ForEach(snippets.active) { snippet in
                            Button {
                                state.insertSnippet(snippet)
                            } label: {
                                HStack {
                                    Text(snippet.name)
                                    Spacer()
                                    if !snippet.abbreviation.isEmpty {
                                        Text(snippet.abbreviation).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Assistant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    MenuBarPanel.dismiss()
                    HubController.shared.open(.commitments)
                } label: {
                    HStack {
                        Text("✅  Commitments")
                        Spacer()
                        if commitmentStore.openCount > 0 {
                            Text("\(commitmentStore.openCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("📇  People") {
                    MenuBarPanel.dismiss()
                    HubController.shared.open(.people)
                }
                Button("📋  Prep Next Meeting") {
                    MenuBarPanel.dismiss()
                    MeetingPrepWatcher.shared.prepNextMeeting()
                }
                Button("📄  New Document…") {
                    MenuBarPanel.dismiss()
                    HubController.shared.open(.newDocument)
                }
            }

            if let error = state.lastError {
                Divider()
                // Diagnoses can run several lines (which recognizer failed and
                // why, what to grant where). Truncating them to one line hides
                // exactly the part that tells the user what to do.
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Divider()

            if let summary = stats.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Settings…") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                if SupportLinks.canSendFeedback {
                    Button {
                        MenuBarPanel.dismiss()
                        SupportLinks.sendFeedback(topic: .menu)
                    } label: {
                        Image(systemName: "envelope")
                    }
                    .help("Send feedback or report a problem")
                }
                if SupportLinks.canDonate {
                    Button {
                        MenuBarPanel.dismiss()
                        SupportLinks.openDonate()
                    } label: {
                        Image(systemName: "heart")
                    }
                    .help("Support Griasa development")
                }
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}
