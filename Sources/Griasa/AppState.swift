import SwiftUI
import AppKit

enum WhisperSetupStatus: Equatable {
    case checking
    case installingEngine
    case downloadingModel(percent: Int)
    case ready
    case fallback(String)

    /// Line shown in the menu while setup is in flight or degraded; nil when ready.
    var menuText: String? {
        switch self {
        case .checking, .ready: return nil
        case .installingEngine: return "Setting up Whisper speech engine…"
        case .downloadingModel(let percent): return "Downloading speech model… \(percent)%"
        case .fallback(let reason): return "Whisper unavailable — using Apple recognizer. \(reason)"
        }
    }
}

enum DictationStatus: Equatable {
    case idle
    case listening
    case processing

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening…"
        case .processing: return "Formatting…"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var dictationStatus: DictationStatus = .idle
    @Published var isRecording = false
    @Published var recordingStartedAt: Date?
    @Published var isProcessingRecording = false
    @Published var lastMeetingTranscript: URL?
    @Published var lastTranscript: String = ""
    @Published var lastError: String?
    @Published var whisperSetup: WhisperSetupStatus = .checking

    // MARK: - Settings (persisted)
    @AppStorage("hotkey") var hotkeyRaw: String = HotkeyMonitor.Key.rightOption.rawValue
    @AppStorage("aiFormattingEnabled") var aiFormattingEnabled: Bool = true
    @AppStorage("anthropicAPIKey") var anthropicAPIKey: String = ""
    @AppStorage("autoRecordOnLaunch") var autoRecordOnLaunch: Bool = false
    @AppStorage("transcribeRecordings") var transcribeRecordings: Bool = true
    @AppStorage("openTranscriptWhenReady") var openTranscriptWhenReady: Bool = true
    @AppStorage("askParticipants") var askParticipants: Bool = true
    @AppStorage("liveNotesEnabled") var liveNotesEnabled: Bool = false
    @AppStorage("dictationLocales") var dictationLocales: String = AppState.defaultDictationLocales
    @AppStorage("customVocabulary") var customVocabulary: String = ""
    @AppStorage("useWhisperForDictation") var useWhisperForDictation: Bool = true
    @AppStorage("liveTyping") var liveTyping: Bool = true

    @AppStorage("claudeProjectFolder") var claudeProjectFolder: String = "~/work/wispr/transcripts"

    /// Shipped default, and the fallback whenever the setting is unusable.
    static let defaultDictationLocales = "en-US"

    /// Languages recognized in parallel; the best-scoring one wins.
    ///
    /// Never empty. An emptied Languages field used to produce an empty list,
    /// which built no recognizers and failed with "No speech recognizer
    /// available for ." — dictation dead, and the message unable to say why.
    var localeList: [String] {
        let parsed = Self.parseLocales(dictationLocales)
        return parsed.isEmpty ? Self.parseLocales(Self.defaultDictationLocales) : parsed
    }

    static func parseLocales(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { SpeechLocales.normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
    }

    /// Adds or removes a dictation language, refusing to remove the last one —
    /// an empty list is what left dictation with no recognizer at all.
    func toggleLocale(_ identifier: String) {
        var list = Self.parseLocales(dictationLocales)
        let id = SpeechLocales.normalize(identifier)
        if let index = list.firstIndex(of: id) {
            guard list.count > 1 else { return }
            list.remove(at: index)
        } else {
            list.append(id)
        }
        dictationLocales = list.joined(separator: ", ")
    }

    var vocabularyList: [String] {
        Vocabulary.combined(with: customVocabulary)
    }

    let dictation = DictationEngine()
    let recorder = ConversationRecorder()
    private var hotkey: HotkeyMonitor?
    private var processingWatchdog: Task<Void, Never>?
    private var actionHotkeys: ActionHotkeys?

    var hotkeyChoice: HotkeyMonitor.Key {
        get { HotkeyMonitor.Key(rawValue: hotkeyRaw) ?? .rightOption }
        set { hotkeyRaw = newValue.rawValue; installHotkey() }
    }

    var menuBarSymbol: String {
        if isRecording { return "record.circle.fill" }
        switch dictationStatus {
        case .idle: return "mic"
        case .listening: return "mic.fill"
        case .processing: return "ellipsis.circle"
        }
    }

    func bootstrap() {
        Permissions.requestAll()
        installHotkey()
        setupWhisper()
        // Straight into the session, with no per-partial main-actor hop: those
        // hops had no FIFO guarantee, and a transposed pair left Griasa's model
        // of the field describing something that wasn't there.
        dictation.onPartial = { text in TypingSession.shared.submit(text) }
        actionHotkeys = ActionHotkeys(
            onPreset: { id in Task { @MainActor in AppState.shared.runPreset(id: id) } },
            onCapture: { action in Task { @MainActor in CaptureController.run(action) } })
        SnippetExpander.shared.start()
        MeetingPrepWatcher.shared.start()
        if autoRecordOnLaunch {
            Task { await startRecording() }
        }
        // First launch: open the welcome guide so permissions get explained
        // before anything mysteriously "doesn't work".
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "welcomeShown") {
            defaults.set(true, forKey: "welcomeShown")
            HubController.shared.open(.welcome)
        }
        UpdateChecker.checkAutomatically()
    }

    /// First-launch provisioning: install whisper-cpp and download the model
    /// automatically so the app works at full quality out of the box. Dictation
    /// and recording stay usable throughout via the Apple-recognizer fallback.
    func setupWhisper() {
        Task { await WhisperInstaller.downloadVADModelIfNeeded() }
        if WhisperTranscriber.isAvailable {
            whisperSetup = .ready
            prewarmWhisperServer()
            return
        }
        Task { @MainActor in
            if WhisperTranscriber.binaryPath == nil {
                guard WhisperInstaller.brewPath != nil else {
                    whisperSetup = .fallback("Homebrew not found — install it, then run: brew install whisper-cpp")
                    return
                }
                whisperSetup = .installingEngine
                guard await WhisperInstaller.installEngine() else {
                    whisperSetup = .fallback("`brew install whisper-cpp` failed — try it in a terminal.")
                    return
                }
            }
            if !FileManager.default.fileExists(atPath: WhisperTranscriber.modelURL.path) {
                whisperSetup = .downloadingModel(percent: 0)
                do {
                    try await WhisperInstaller.downloadModel { percent in
                        Task { @MainActor in
                            if case .downloadingModel = AppState.shared.whisperSetup {
                                AppState.shared.whisperSetup = .downloadingModel(percent: percent)
                            }
                        }
                    }
                } catch {
                    whisperSetup = .fallback("Model download failed: \(error.localizedDescription) Use Settings → Retry.")
                    return
                }
            }
            whisperSetup = WhisperTranscriber.isAvailable
                ? .ready
                : .fallback("Setup finished but Whisper still isn't usable — use Settings → Retry.")
            if case .ready = whisperSetup {
                prewarmWhisperServer()
            }
        }
    }

    /// Keeps the whisper-server loaded so dictation is near-instant and
    /// meeting regions transcribe without per-call model loads.
    private func prewarmWhisperServer() {
        let vocabulary = vocabularyList
        Task.detached(priority: .utility) {
            _ = await WhisperServer.shared.ensureRunning(vocabulary: vocabulary)
        }
    }

    private func installHotkey() {
        hotkey = HotkeyMonitor(key: hotkeyChoice,
                               onPress: { [weak self] in Task { @MainActor in self?.beginDictation() } },
                               onRelease: { [weak self] in Task { @MainActor in await self?.endDictation() } })
    }

    // MARK: - Dictation

    /// A transcription that never returns leaves `dictationStatus` at
    /// `.processing`, and from then on every hotkey press is refused by
    /// `beginDictation`'s guard — the app looks dead with nothing on screen to
    /// say why. Whisper over HTTP allows itself ten minutes and a CLI provider
    /// can hang indefinitely, so recovery cannot depend on those calls
    /// returning.
    private func startProcessingWatchdog() {
        processingWatchdog?.cancel()
        processingWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled, dictationStatus == .processing else { return }
            TypingTrace.log("processing watchdog fired — transcription never returned, resetting to idle")
            lastError = "Transcription timed out — dictation is ready again."
            TypingSession.shared.end()
            dictationStatus = .idle
        }
    }

    func beginDictation() {
        guard dictationStatus == .idle else {
            TypingTrace.log("beginDictation ignored, status=\(dictationStatus)")
            return
        }
        TypingSession.shared.begin(liveTyping: liveTyping)
        do {
            try dictation.start(localeIdentifiers: localeList, vocabulary: vocabularyList)
            dictationStatus = .listening
            lastError = nil
            TypingTrace.log("dictation started, locales=\(localeList.joined(separator: ", "))")
        } catch {
            TypingSession.shared.end()
            lastError = "Dictation failed to start: \(error.localizedDescription)"
            TypingTrace.log("dictation FAILED to start: \(error.localizedDescription)")
        }
    }

    func endDictation() async {
        guard dictationStatus == .listening else {
            TypingTrace.log("endDictation ignored, status=\(dictationStatus)")
            // Idle means nothing is in flight, so a session still open here is a
            // leak — and it leaves a global key monitor behind with it.
            if dictationStatus == .idle { TypingSession.shared.end() }
            return
        }
        dictationStatus = .processing
        startProcessingWatchdog()
        var raw = await dictation.stop()
        TypingTrace.log("apple raw=\(raw.count) chars")

        // Prefer Whisper's transcription of the captured audio — much more
        // accurate than the live Apple result, with built-in language detection.
        if useWhisperForDictation, WhisperTranscriber.isAvailable, let audioURL = dictation.lastAudioURL {
            let whisperText = await WhisperTranscriber.transcribeText(audio: audioURL, vocabulary: vocabularyList)
            if !whisperText.isEmpty {
                TypingTrace.log("whisper=\(whisperText.count) chars (replacing apple's \(raw.count))")
                raw = whisperText
            }
            try? FileManager.default.removeItem(at: audioURL)
        }

        guard !raw.isEmpty else {
            // Nothing final — keep whatever live typing already produced.
            let live = TypingSession.shared.typedText()
            TypingSession.shared.end()
            if !live.isEmpty { lastTranscript = live }
            processingWatchdog?.cancel()
            dictationStatus = .idle
            return
        }
        let targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        var formatted = await AIFormatter.format(raw,
                                                 targetApp: targetApp,
                                                 aiEnabled: aiFormattingEnabled)
        // Cleanup adds punctuation and fixes words; it never has a reason to
        // double the length. When it does, the model has started writing rather
        // than cleaning — a small or garbled transcript invites exactly that —
        // and the user's own words are the safer answer.
        let ceiling = raw.count * 2 + 40
        if formatted.count > ceiling {
            TypingTrace.log("cleanup rejected — grew \(raw.count) -> \(formatted.count) chars, over ceiling \(ceiling); using raw")
            formatted = raw
        }
        lastTranscript = formatted
        UsageStats.shared.recordDictation(formatted)
        HistoryStore.shared.add(kind: .dictation, title: "Dictation", text: formatted)
        let outcome = TypingSession.shared.finish(with: formatted)
        TypingTrace.log("formatted=\(formatted.count) chars, outcome=\(outcome)")
        switch outcome {
        case .nothingTyped:
            TextInserter.insert(formatted)
        case .corrected:
            break  // the live text was replaced in place
        case .keptAsTyped:
            // The user typed or switched away mid-dictation. Their text stands;
            // the polished version is in History and the HUD said so.
            break
        }
        processingWatchdog?.cancel()
        dictationStatus = .idle
    }

    // MARK: - Prompt presets on selected text

    func runPreset(id: UUID) {
        guard let preset = PresetStore.shared.presets.first(where: { $0.id == id }) else { return }
        runPreset(preset)
    }

    func runPreset(_ preset: PromptPreset) {
        MenuBarPanel.dismiss()
        Task { @MainActor in
            let sourceApp = NSWorkspace.shared.frontmostApplication
            guard let text = await SelectionGrabber.grab(), text.count >= 3 else {
                PopupController.shared.showMessage(
                    title: preset.name,
                    message: "No text selected. Select some text, then trigger the action again.")
                return
            }
            guard AIFormatter.isConfigured else {
                PopupController.shared.showMessage(
                    title: preset.name,
                    message: "Configure an AI provider in Settings → AI & Actions to use this feature.")
                return
            }
            PopupController.shared.showLoading(title: "\(preset.emoji) \(preset.name)",
                                               canReplace: preset.replacesSelection,
                                               sourceApp: sourceApp)
            let result = await SelectionAI.run(preset: preset, text: text)
            if let result {
                PopupController.shared.showResult(result)
                HistoryStore.shared.add(kind: .action, title: preset.name, text: result)
            } else {
                PopupController.shared.showResult("Request failed — check your network connection and API key.")
            }
        }
    }

    // MARK: - Snippets (menu path; typing path lives in SnippetExpander)

    func insertSnippet(_ snippet: Snippet) {
        MenuBarPanel.dismiss()
        Task { @MainActor in
            // Give focus a beat to return to the app the user was in.
            try? await Task.sleep(nanoseconds: 250_000_000)
            do {
                let text = try await SnippetEngine.render(snippet.template)
                TextInserter.insert(text)
            } catch {
                PopupController.shared.showMessage(title: snippet.name,
                                                   message: error.localizedDescription)
            }
        }
    }

    // MARK: - Conversation recording

    func startRecording() async {
        guard !isRecording else { return }
        do {
            try await recorder.start()
            isRecording = true
            recordingStartedAt = Date()
            lastError = recorder.micUnavailable
                ? "Recording without a microphone — only the other side of the call will be captured. Check Microphone permission in System Settings → Privacy & Security."
                : nil
            if liveNotesEnabled {
                LiveNotesController.shared.start(vocabulary: vocabularyList,
                                                 myName: ParticipantRoster.shared.myName,
                                                 recorder: recorder)
            }
        } catch {
            lastError = "Recording failed to start: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        if liveNotesEnabled { LiveNotesController.shared.stop() }
        let folder = await recorder.stop()
        recorder.onSystemBuffer = nil
        isRecording = false
        recordingStartedAt = nil

        guard transcribeRecordings, let folder else { return }

        // Notes typed in the live window ride into the final transcript at
        // their timecodes.
        let meetingNotes = liveNotesEnabled ? LiveNotesController.shared.sessionNotes() : []

        // Ask who was on the call, so the AI can name the speakers — unless
        // disabled or there's no provider to attribute with.
        if askParticipants, AIFormatter.isConfigured {
            ParticipantsPrompt.shared.ask { [weak self] names in
                ParticipantRoster.shared.remember(names)
                self?.runMeetingPipeline(folder: folder, participants: names, notes: meetingNotes)
            }
        } else {
            runMeetingPipeline(folder: folder, participants: [], notes: meetingNotes)
        }
    }

    private func runMeetingPipeline(folder: URL, participants: [String], notes: [LiveNote]) {
        isProcessingRecording = true
        let locales = localeList
        let vocabulary = vocabularyList
        let myName = ParticipantRoster.shared.myName
        Task.detached(priority: .userInitiated) {
            let url = await MeetingTranscriber.process(folder: folder,
                                                       localeIdentifiers: locales,
                                                       vocabulary: vocabulary,
                                                       participants: participants,
                                                       myName: myName,
                                                       notes: notes)
            await MainActor.run {
                let state = AppState.shared
                state.isProcessingRecording = false
                state.lastMeetingTranscript = url
                if let url {
                    state.copyToClaudeProject(url)
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        let title = MeetingTranscriber.title(fromMarkdown: text)
                        let entryID = HistoryStore.shared.add(
                            kind: .meeting, title: title, text: text, filePath: url.path,
                            participants: participants.isEmpty ? nil : participants)
                        // Quietly pull out who promised what — the list in the
                        // Commitments tab just grows, nothing pops up.
                        Task {
                            try? await CommitmentExtractor.extract(
                                markdown: text, participants: participants, myName: myName,
                                sourceTitle: title, sourceEntryID: entryID)
                        }
                    }
                    if state.openTranscriptWhenReady {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    state.lastError = "No speech was detected in the recording."
                }
            }
        }
    }

    /// Prompts for a recording folder and runs the full meeting pipeline on it
    /// — for sessions that were interrupted (a crash mid-recording) or never
    /// processed. Defaults the panel to the recordings root.
    func pickAndProcessRecording() {
        let panel = NSOpenPanel()
        panel.title = "Process a recording"
        panel.message = "Pick a recording folder to transcribe and summarize."
        panel.prompt = "Process"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = ConversationRecorder.recordingsRoot
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        processRecordingFolder(folder)
    }

    /// Transcribes and summarizes an existing recording folder, reusing the
    /// normal meeting pipeline (history entry + retrospective commitments).
    func processRecordingFolder(_ folder: URL) {
        guard !isProcessingRecording else { return }
        let hasAudio = ["microphone.caf", "system-audio.caf"].contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        guard hasAudio else {
            lastError = "That folder has no recording audio (microphone.caf / system-audio.caf)."
            return
        }
        if askParticipants, AIFormatter.isConfigured {
            ParticipantsPrompt.shared.ask { [weak self] names in
                ParticipantRoster.shared.remember(names)
                self?.runMeetingPipeline(folder: folder, participants: names, notes: [])
            }
        } else {
            runMeetingPipeline(folder: folder, participants: [], notes: [])
        }
    }

    func openRecordingsFolder() {
        NSWorkspace.shared.open(ConversationRecorder.recordingsRoot)
    }

    /// Copies a finished meeting transcript into the configured Claude project
    /// folder so Claude Code sessions in that project can read it.
    func copyToClaudeProject(_ transcript: URL) {
        let path = claudeProjectFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // The session folder name is the recording timestamp.
            let sessionName = transcript.deletingLastPathComponent().lastPathComponent
            let dest = dir.appendingPathComponent("\(sessionName) meeting.md")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: transcript, to: dest)
        } catch {
            lastError = "Couldn't copy transcript to project folder: \(error.localizedDescription)"
        }
    }
}
