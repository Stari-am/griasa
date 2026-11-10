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
    @ObservedObject private var localModel = LocalModelSetup.shared
    @AppStorage("customBaseURL") private var customBaseURL = ""
    @AppStorage("customFastModel") private var customFast = ""
    @AppStorage("customSmartModel") private var customSmart = ""
    @AppStorage("llmProvider") private var providerRaw = ""
    @Environment(\.openSettings) private var openSettings

    /// Reads `providerRaw` so the menu redraws when the provider changes.
    private var onLocalProvider: Bool {
        _ = providerRaw
        return LLMConfig.current().provider == .custom
    }

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

            if case .downloading(let p) = localModel.state {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(localModel.waitingForNetwork
                         ? "Local AI model: waiting for the network… \(p)%"
                         : localModel.resuming ? "Resuming download… \(p)%"
                         : "Downloading local AI model… \(p)%").font(.caption).foregroundStyle(.secondary)
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

            MicPicker(recordingSince: state.recordingStartedAt)

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
                Button("☀️ Today") {
                    MenuBarPanel.dismiss()
                    HubController.shared.open(.today)
                }
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
                Button {
                    MenuBarPanel.dismiss()
                    HubController.shared.open(.decisions)
                } label: {
                    Text("🪧  Decisions")
                }
                Button {
                    MenuBarPanel.dismiss()
                    HubController.shared.open(.team)
                } label: {
                    Text("🧑‍🤝‍🧑  My team")
                }
                // Only for people on the local provider who did not set it up by hand.
                if !localModel.isReady, onLocalProvider,
                   !LocalRefreshGate.isHandConfigured(typedBaseURL: customBaseURL,
                                                      typedModelNames: [customFast, customSmart]) {
                    Button("🧠  Local AI…") {
                        MenuBarPanel.dismiss()
                        HubController.shared.open(.localModel)
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
                Button("📥  Import Meeting Notes…") {
                    MenuBarPanel.dismiss()
                    HubController.shared.open(.importNotes)
                }
                if ManagedPolicy.live.conversationsEnabled {
                    Button("💬  Import Chats…") {
                        MenuBarPanel.dismiss()
                        ConversationsNavigator.shared.startImport()
                    }
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
        // Found it: the hint has done its job.
        .onAppear { FirstRunCoachmark.shared.dismiss() }
    }
}

/// Which microphone recording and dictation use, and, while recording, whether
/// the person's own voice is arriving. Without it the only way to learn that
/// the wrong input was picked was an empty side of the transcript afterwards.
struct MicPicker: View {
    let recordingSince: Date?
    @AppStorage(MicChoice.key) private var chosenUID = ""
    @State private var devices: [MicChoice.Device] = []
    @State private var systemDefault: MicChoice.Device?

    private var missing: Bool { MicChoice.isMissing(chosen: chosenUID, available: devices) }
    private var current: MicChoice.Device? {
        MicChoice.resolve(chosen: chosenUID, available: devices, systemDefault: systemDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Menu {
                Button {
                    choose("")
                } label: {
                    check(chosenUID.isEmpty,
                          "System default" + (systemDefault.map { " (\($0.name))" } ?? ""))
                }
                Divider()
                ForEach(devices, id: \.uid) { device in
                    Button { choose(device.uid) } label: { check(chosenUID == device.uid, device.name) }
                }
                Divider()
                Button("Sound Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } label: {
                Label("Mic: \(current?.name ?? "none found")", systemImage: "mic")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The microphone Griasa records your side of a call from")

            if missing {
                Text("The chosen microphone is not connected, so the system default is used.")
                    .font(.caption).foregroundStyle(.orange)
            } else if let since = recordingSince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    voiceStatus(since: since, now: context.date)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func voiceStatus(since: Date, now: Date) -> some View {
        if let heard = MicCapture.shared.lastVoiceAt, now.timeIntervalSince(heard) < 5 {
            Label("Mic is picking up sound", systemImage: "waveform")
                .font(.caption).foregroundStyle(.green)
        } else if now.timeIntervalSince(since) > 15 && MicCapture.shared.lastVoiceAt == nil {
            Text("No sound from this mic yet. If you have been speaking, pick another one.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func check(_ on: Bool, _ title: String) -> some View {
        on ? AnyView(Label(title, systemImage: "checkmark")) : AnyView(Text(title))
    }

    private func choose(_ uid: String) {
        guard uid != chosenUID else { return }
        chosenUID = uid
        MicCapture.shared.useChosenDevice()
        refresh()
    }

    private func refresh() {
        devices = AudioInputs.all()
        systemDefault = AudioInputs.systemDefault()
    }
}
