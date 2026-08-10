import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            DictationSettings(state: state)
                .tabItem { Label("Dictation", systemImage: "mic") }
            RecordingSettings(state: state)
                .tabItem { Label("Meetings", systemImage: "record.circle") }
            AISettings(state: state)
                .tabItem { Label("AI & Actions", systemImage: "sparkles") }
            CaptureSettings()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            SnippetsSettings()
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            ProjectsSettings()
                .tabItem { Label("Projects", systemImage: "folder") }
            SystemSettings(state: state)
                .tabItem { Label("System", systemImage: "gearshape") }
        }
        // Fixed, screen-safe size; each tab scrolls internally if it overflows.
        .frame(width: 460, height: 380)
    }
}

/// Wraps a tab's Form so it never grows past the window and scrolls instead.
private struct SettingsTab<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

private struct DictationSettings: View {
    @ObservedObject var state: AppState
    var body: some View {
        SettingsTab {
            Section("Dictation") {
                Picker("Hold-to-talk key", selection: Binding(
                    get: { state.hotkeyChoice },
                    set: { state.hotkeyChoice = $0 }
                )) {
                    ForEach(HotkeyMonitor.Key.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                DictationLanguagePicker()
                TextField("Custom vocabulary", text: $state.customVocabulary)
                    .help("Comma-separated extra terms passed to the recognizer, added to the built-in tech/crypto list (GitHub, staking, jetton…). Useful for product names and jargon.")
                Toggle("Live typing while speaking", isOn: $state.liveTyping)
                    .help("Words appear in the target app as you speak (fast on-device recognizer); when you release the hotkey, the text is corrected in place with the polished Whisper + Claude version. Off = everything is pasted once at the end.")
                LabeledContent("Typing reliability") {
                    Button("Run test…") {
                        HubController.shared.open(.typingDiagnostics)
                    }
                    .help("Measures how much of what Griasa types actually lands in a given app, and whether that app allows atomic text replacement. Run it in any app where live typing misbehaves.")
                }
            }

            Section("Speech engine") {
                LabeledContent("Whisper (large-v3-turbo)") {
                    switch state.whisperSetup {
                    case .ready:
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .checking:
                        Text("Checking…").foregroundStyle(.secondary)
                    case .installingEngine:
                        Label("Installing engine…", systemImage: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    case .downloadingModel(let percent):
                        Label("Downloading model… \(percent)%", systemImage: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    case .fallback:
                        Label("Unavailable — Apple fallback", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .help("Installed automatically on first launch (whisper-cpp via Homebrew + the ggml-large-v3-turbo model). Until it's ready, the Apple recognizer is used.")
                if case .fallback(let reason) = state.whisperSetup {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry Whisper Setup") { state.setupWhisper() }
                }
                Toggle("Use Whisper for dictation", isOn: $state.useWhisperForDictation)
                    .help("Much higher accuracy and automatic language detection, at the cost of a moment of processing after you release the hotkey. Meetings always use Whisper when it's installed.")
            }
        }
    }
}

/// Picks dictation languages from what `SFSpeechRecognizer` actually supports.
///
/// This replaced a free-text field, which is how the setting ended up empty and
/// left dictation with no recognizer at all. Choosing from a list makes both a
/// typo'd locale code and an empty selection impossible: the last language
/// can't be removed.
private struct DictationLanguagePicker: View {
    @EnvironmentObject var state: AppState

    private var selected: [String] { AppState.parseLocales(state.dictationLocales) }

    private var summary: String {
        let names = selected.map(SpeechLocales.name(for:))
        if names.isEmpty { return "\(SpeechLocales.name(for: AppState.defaultDictationLocales)) (default)" }
        return names.joined(separator: ", ")
    }

    var body: some View {
        LabeledContent("Languages") {
            VStack(alignment: .leading, spacing: 4) {
                Menu {
                    ForEach(SpeechLocales.available) { choice in
                        Button {
                            state.toggleLocale(choice.id)
                        } label: {
                            if selected.contains(choice.id) {
                                Label(choice.name, systemImage: "checkmark")
                            } else {
                                Text(choice.name)
                            }
                        }
                    }
                } label: {
                    Text(summary).lineLimit(1)
                }
                .frame(maxWidth: 260)

                if selected.count > 2 {
                    Text("\(selected.count) languages run \(selected.count) recognizers on every phrase — pick only the ones you actually dictate in.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let unsupported = selected.first(where: { !SpeechLocales.isSupported($0) }) {
                    Text("\(SpeechLocales.name(for: unsupported)) isn't available on this Mac and will be skipped — add it under System Settings → Keyboard → Dictation.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .help("Languages recognized in parallel; the best-scoring one wins, per phrase for dictation and per 30-second chunk for meetings. Only languages this Mac's speech recognizer supports are listed.")
    }
}

private struct RecordingSettings: View {
    @ObservedObject var state: AppState
    @ObservedObject private var roster = ParticipantRoster.shared
    @AppStorage("prepBriefEnabled") private var prepBriefEnabled = true
    @AppStorage("prepLeadMinutes") private var prepLeadMinutes = 5
    var body: some View {
        SettingsTab {
            Section("Conversation recording") {
                Toggle("Start recording when Griasa launches", isOn: $state.autoRecordOnLaunch)
                Toggle("Transcribe meetings when recording stops", isOn: $state.transcribeRecordings)
                    .help("Speech-to-text runs on-device; with an Anthropic API key set, Claude then produces cleaned notes with a summary and action items.")
                Toggle("Open the transcript when it's ready", isOn: $state.openTranscriptWhenReady)
            }
            Section("Speakers & live notes") {
                TextField("Your name", text: $roster.myName)
                    .help("Used to label your microphone track in transcripts.")
                Toggle("Ask who was on the call, then name speakers", isOn: $state.askParticipants)
                    .help("After a recording, pick the participants; Claude attributes the transcript to their names using conversational cues.")
                Toggle("Show live notes while recording", isOn: $state.liveNotesEnabled)
                    .help("A floating window transcribes the call in real time and refreshes a running summary every minute. Requires Whisper.")
            }
            Section("Meeting prep") {
                Toggle("Show a brief before meetings", isOn: $prepBriefEnabled)
                    .help("Shortly before a calendar event with participants or a call link, the Prep tab opens quietly (without stealing focus): who's on the call, last meeting's summary, open promises. Needs Calendar access — granted on first use of “Prep Next Meeting” or the {slot} snippet.")
                Stepper("Lead time: \(prepLeadMinutes) min", value: $prepLeadMinutes, in: 1...30)
                    .help("How many minutes before the meeting the brief appears.")
            }
            Section("Folders") {
                TextField("Claude project folder", text: $state.claudeProjectFolder)
                    .help("Every finished meeting transcript is also copied here, so Claude (e.g. Claude Code in that project) can read your meetings. Leave empty to disable.")
                LabeledContent("Recordings folder") {
                    Button("Open") { state.openRecordingsFolder() }
                }
            }
        }
    }
}

private struct AISettings: View {
    @ObservedObject var state: AppState
    @ObservedObject private var presets = PresetStore.shared
    @ObservedObject private var templates = TemplateStore.shared
    @State private var editing: PromptPreset.ID?
    @State private var editingTemplate: DocTemplate.ID?
    @State private var promptsStatus = ""

    // Provider settings — keys mirror LLMConfig.config(for:).
    @AppStorage("llmProvider") private var providerRaw = LLMProvider.anthropic.rawValue
    @AppStorage("openAIKey") private var openAIKey = ""
    @AppStorage("geminiKey") private var geminiKey = ""
    @AppStorage("customBaseURL") private var customBaseURL = ""
    @AppStorage("customAPIKey") private var customAPIKey = ""
    @AppStorage("anthropicFastModel") private var anthropicFast = ""
    @AppStorage("anthropicSmartModel") private var anthropicSmart = ""
    @AppStorage("openAIFastModel") private var openAIFast = ""
    @AppStorage("openAISmartModel") private var openAISmart = ""
    @AppStorage("geminiFastModel") private var geminiFast = ""
    @AppStorage("geminiSmartModel") private var geminiSmart = ""
    @AppStorage("customFastModel") private var customFast = ""
    @AppStorage("customSmartModel") private var customSmart = ""
    @AppStorage("customContextLimit") private var customContextLimit = 24_000
    @AppStorage("claudeCLIFastModel") private var claudeCLIFast = ""
    @AppStorage("claudeCLISmartModel") private var claudeCLISmart = ""
    @AppStorage("codexCLIFastModel") private var codexCLIFast = ""
    @AppStorage("codexCLISmartModel") private var codexCLISmart = ""
    @AppStorage("claudeCLIPath") private var claudeCLIPath = ""
    @AppStorage("codexCLIPath") private var codexCLIPath = ""

    @State private var testResult = ""
    @State private var testing = false
    @State private var availableModels: [String] = []

    private var provider: LLMProvider { LLMProvider(rawValue: providerRaw) ?? .anthropic }

    var body: some View {
        SettingsTab {
            Section("AI provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }

                switch provider {
                case .anthropic:
                    SecureField("Anthropic API key", text: $state.anthropicAPIKey)
                        .help("Also read from the ANTHROPIC_API_KEY environment variable.")
                    modelFields(fast: $anthropicFast, smart: $anthropicSmart)
                case .openAI:
                    SecureField("OpenAI API key", text: $openAIKey)
                        .help("Also read from the OPENAI_API_KEY environment variable.")
                    modelFields(fast: $openAIFast, smart: $openAISmart)
                case .gemini:
                    SecureField("Gemini API key", text: $geminiKey)
                        .help("Also read from the GEMINI_API_KEY environment variable. Get one at aistudio.google.com.")
                    modelFields(fast: $geminiFast, smart: $geminiSmart)
                case .custom:
                    TextField("Base URL", text: $customBaseURL,
                              prompt: Text("http://localhost:11434/v1"))
                        .help("Any OpenAI-compatible endpoint. Ollama: http://localhost:11434/v1 · LM Studio: http://localhost:1234/v1")
                    SecureField("API key (optional)", text: $customAPIKey)
                        .help("Leave empty for Ollama and LM Studio.")
                    modelFields(fast: $customFast, smart: $customSmart)
                    TextField("Context limit (characters)", value: $customContextLimit,
                              format: .number)
                        .help("Meeting transcripts are trimmed to this before summarizing — local models rarely fit more than ~32k tokens of context.")
                    Text("Fully offline setup: Whisper transcribes locally, and with Ollama the AI features never leave this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .claudeCLI:
                    cliStatus(path: CLIRunner.locate(.claudeCLI),
                              installHint: "Install Claude Code (claude.com/product/claude-code) and log in with your Claude subscription — no API key needed.")
                    TextField("CLI path (optional)", text: $claudeCLIPath,
                              prompt: Text("~/.local/bin/claude"))
                        .help("Only needed if the claude binary isn't in a standard location.")
                    modelFields(fast: $claudeCLIFast, smart: $claudeCLISmart)
                    Text("Uses your Claude Pro/Max subscription via the claude CLI — models are aliases (haiku / sonnet / opus). Expect ~5–10 s per request. Dictation cleanup falls back to the local rule-based cleanup on CLI providers — subprocess latency is too high for the typing path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .codexCLI:
                    cliStatus(path: CLIRunner.locate(.codexCLI),
                              installHint: "Install the Codex CLI (npm i -g @openai/codex) and run `codex login` with your ChatGPT account.")
                    TextField("CLI path (optional)", text: $codexCLIPath,
                              prompt: Text("/opt/homebrew/bin/codex"))
                        .help("Only needed if the codex binary isn't in a standard location.")
                    modelFields(fast: $codexCLIFast, smart: $codexCLISmart)
                    Text("Uses your ChatGPT Plus/Pro subscription via `codex exec`. Leave models empty for the CLI's default. Expect ~5–10 s per request. Dictation cleanup falls back to the local rule-based cleanup on CLI providers — subprocess latency is too high for the typing path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(testing ? "Testing…" : "Test") { runTest() }
                        .disabled(testing)
                    if [.openAI, .gemini, .custom].contains(provider) {
                        Button("Load model list") { loadModels() }
                    }
                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("✓") ? .secondary : Color.red)
                            .lineLimit(2)
                    }
                }

                Text("Fast model handles quick tasks (dictation cleanup, reminder parsing, classification); smart model handles heavy ones (presets, summaries, Ask Project, meeting notes).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("AI formatting") {
                Toggle("Clean up dictation with AI", isOn: $state.aiFormattingEnabled)
                    .help("Without a configured provider, a local rule-based cleanup is used — dictation always works.")
            }
            Section("Prompt presets (selected text)") {
                ForEach($presets.presets) { $preset in
                    DisclosureGroup(isExpanded: Binding(
                        get: { editing == preset.id },
                        set: { editing = $0 ? preset.id : nil }
                    )) {
                        TextField("Name", text: $preset.name)
                        TextField("Emoji", text: $preset.emoji)
                        Toggle("Offer “Replace Selection”", isOn: $preset.replacesSelection)
                        HotkeyField(label: "Hotkey", stored: $preset.hotkey, fallback: "")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Instruction to Claude").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $preset.systemPrompt)
                                .font(.callout)
                                .frame(height: 90)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        }
                        Button(role: .destructive) { presets.delete(preset) } label: {
                            Label("Delete preset", systemImage: "trash")
                        }
                    } label: {
                        HStack {
                            Text("\(preset.emoji)  \(preset.name)")
                            Spacer()
                            if let combo = KeyCombo.parse(preset.hotkey) {
                                Text(combo.display).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button { presets.add() } label: { Label("Add preset", systemImage: "plus") }
                Text("Assign a hotkey no app uses for editing — global hotkeys can't be swallowed on macOS, so the frontmost app also sees the keystroke.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Document templates (New Document)") {
                ForEach($templates.templates) { $template in
                    DisclosureGroup(isExpanded: Binding(
                        get: { editingTemplate == template.id },
                        set: { editingTemplate = $0 ? template.id : nil }
                    )) {
                        TextField("Name", text: $template.name)
                        TextField("Emoji", text: $template.emoji)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Skeleton — headings the AI fills in; <!-- comments --> guide it and are removed from the result")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $template.skeleton)
                                .font(.callout.monospaced())
                                .frame(height: 140)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        }
                        Button(role: .destructive) { templates.delete(template) } label: {
                            Label("Delete template", systemImage: "trash")
                        }
                    } label: {
                        Text("\(template.emoji)  \(template.name)")
                    }
                }
                HStack {
                    Button { templates.add() } label: { Label("Add template", systemImage: "plus") }
                    Button("Restore defaults") { templates.restoreDefaults() }
                }
            }

            Section("System prompts") {
                Text("Every instruction Griasa sends to a model lives in one file — dictation cleanup, meeting notes, commitments, dossiers, inline answers. Export writes the current wording to a JSON file you can edit; any key you leave out keeps the shipped version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Export for editing") {
                        do {
                            let url = try Prompts.exportForEditing()
                            promptsStatus = "✓ Written to \(url.lastPathComponent)"
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } catch {
                            promptsStatus = "✗ \(error.localizedDescription)"
                        }
                    }
                    Button("Reload edits") {
                        let count = Prompts.reload()
                        promptsStatus = count == 0
                            ? "No overrides found — using the shipped prompts."
                            : "✓ \(count) prompt\(count == 1 ? "" : "s") overridden."
                    }
                    if !promptsStatus.isEmpty {
                        Text(promptsStatus)
                            .font(.caption)
                            .foregroundStyle(promptsStatus.hasPrefix("✗") ? Color.red : .secondary)
                    }
                }
            }
        }
    }

    /// Detection line for CLI providers — found (with path) or an install hint.
    @ViewBuilder
    private func cliStatus(path: String?, installHint: String) -> some View {
        if let path {
            Label {
                Text("Found: \(path)").font(.caption).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Label {
                Text(installHint).font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    /// Fast/smart fields with the provider's defaults as placeholders; empty
    /// means "use the default". After "Load model list", each field gets a
    /// picker of what the endpoint actually serves.
    @ViewBuilder
    private func modelFields(fast: Binding<String>, smart: Binding<String>) -> some View {
        modelField("Fast model", text: fast, fallback: provider.defaultFastModel)
        modelField("Smart model", text: smart, fallback: provider.defaultSmartModel)
    }

    @ViewBuilder
    private func modelField(_ label: String, text: Binding<String>, fallback: String) -> some View {
        HStack {
            TextField(label, text: text, prompt: Text(fallback))
            if !availableModels.isEmpty {
                Menu {
                    ForEach(availableModels, id: \.self) { model in
                        Button(model) { text.wrappedValue = model }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
    }

    private func runTest() {
        testing = true
        testResult = ""
        let selected = provider
        Task { @MainActor in
            testResult = await AIFormatter.test(provider: selected)
            testing = false
        }
    }

    private func loadModels() {
        // LLMConfig already resolves the base URL and key (incl. env
        // fallbacks) for every provider — no per-provider branching here.
        let config = LLMConfig.config(for: provider)
        let base = config.baseURL
        let key = config.apiKey
        testResult = ""
        Task { @MainActor in
            do {
                availableModels = try await AIFormatter.listModels(baseURL: base, apiKey: key)
                testResult = availableModels.isEmpty
                    ? "✗ The endpoint returned no models."
                    : "✓ \(availableModels.count) models loaded — use the pickers next to the fields."
            } catch {
                availableModels = []
                testResult = "✗ \(error.localizedDescription)"
            }
        }
    }
}

private struct CaptureSettings: View {
    // Keys and defaults mirror CaptureAction.storageKey / .defaultHotkey.
    @AppStorage("captureRemindHotkey") private var remindHotkey = "ctrl+opt+cmd+r"
    @AppStorage("captureOCRHotkey") private var ocrHotkey = "ctrl+opt+cmd+o"
    @AppStorage("captureReplyHotkey") private var replyHotkey = "ctrl+opt+cmd+y"

    var body: some View {
        SettingsTab {
            Section("Capture actions (work in any app)") {
                HotkeyField(label: "⏰ Remind me", stored: $remindHotkey, fallback: "ctrl+opt+cmd+r")
                HotkeyField(label: "🔤 OCR region", stored: $ocrHotkey, fallback: "ctrl+opt+cmd+o")
                HotkeyField(label: "💬 Draft reply", stored: $replyHotkey, fallback: "ctrl+opt+cmd+y")
                Text("Remind me uses your text selection, or lets you drag a screen region if nothing is selected. OCR region and Draft reply screenshot the screen and read it with on-device text recognition. Set a modifier to “None” to disable a hotkey.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Reminders") {
                LabeledContent("Apple Reminders access") {
                    Image(systemName: Permissions.remindersGranted ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(Permissions.remindersGranted ? .green : .orange)
                }
                Text("“Remind me” creates reminders in the Reminders app, so they sync to your iPhone and Watch. You'll be asked to grant access the first time; Griasa uses it only to add the reminders you ask for. This is the one permission the feature itself needs — every other Capture action works without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Convenience extra: when a reminder is captured in a browser, macOS asks once per browser for Automation access so Griasa can attach the page's address (with a jump-to-text link) to the reminder. Decline it and reminders work exactly the same — they just won't link back to the page. Other apps need nothing: the source app and window are noted automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Clipboard") {
                Text("Run any prompt preset on the current clipboard from the menu bar → “Run on clipboard”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProjectsSettings: View {
    @ObservedObject private var store = ProjectStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @AppStorage("captureAskProjectHotkey") private var askHotkey = "ctrl+opt+cmd+p"
    @State private var editing: Project.ID?

    var body: some View {
        SettingsTab {
            Section("Projects") {
                ForEach($store.projects) { $project in
                    DisclosureGroup(isExpanded: Binding(
                        get: { editing == project.id },
                        set: { editing = $0 ? project.id : nil }
                    )) {
                        TextField("Name", text: $project.name)
                        TextField("Emoji", text: $project.emoji)
                        TextField("What belongs here (guides auto-categorization)",
                                  text: $project.about, axis: .vertical)
                        ForEach(project.sourceFolders, id: \.self) { path in
                            HStack {
                                Text(path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    $project.wrappedValue.sourceFolders.removeAll { $0 == path }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button {
                            addSourceFolder(to: $project)
                        } label: {
                            Label("Add source folder…", systemImage: "folder.badge.plus")
                        }
                        Button(role: .destructive) { store.delete(project) } label: {
                            Label("Delete project (entries move to Inbox)", systemImage: "trash")
                        }
                    } label: {
                        Text("\(project.emoji)  \(project.name)")
                    }
                }
                Button { store.add() } label: { Label("Add project", systemImage: "plus") }
                Text("New dictations, meetings, and captures are filed automatically by Claude using each project's name and description. Each project mirrors its entries as Markdown in Documents/Griasa/Projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Ask Project") {
                HotkeyField(label: "🗂 Ask project", stored: $askHotkey, fallback: "ctrl+opt+cmd+p")
                Text("Opens a window where Claude answers questions using the project's entries plus the source folders above as context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("History") {
                Button("Categorize existing history") { history.categorizeAll() }
                if let status = history.categorizeStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Projects folder") {
                    Button("Open") {
                        try? FileManager.default.createDirectory(
                            at: ProjectFiles.root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(ProjectFiles.root)
                    }
                }
            }
        }
    }

    private func addSourceFolder(to project: Binding<Project>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let existing = Set(project.wrappedValue.sourceFolders)
        project.wrappedValue.sourceFolders
            .append(contentsOf: panel.urls.map(\.path).filter { !existing.contains($0) })
    }
}

private struct SnippetsSettings: View {
    @ObservedObject private var store = SnippetStore.shared
    @State private var editing: Snippet.ID?

    @AppStorage("snippetExpansionEnabled") private var expansionEnabled = true
    @AppStorage("meetLink") private var meetLink = ""
    @AppStorage("snippetWorkStart") private var workStart = 10
    @AppStorage("snippetWorkEnd") private var workEnd = 18
    @AppStorage("snippetMinSlotMinutes") private var minSlot = 30
    @AppStorage("snippetWeekdaysOnly") private var weekdaysOnly = true

    var body: some View {
        SettingsTab {
            Section("Snippets") {
                Toggle("Expand abbreviations while typing", isOn: $expansionEnabled)
                    .help("Type an abbreviation (e.g. \";meet\") in any app and it expands in place. Off = snippets stay available from the menu bar.")
                LabeledContent("Ask AI inline") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Type \(SnippetExpander.askOpener) your question \(SnippetExpander.askCloser) in any app — the whole thing is replaced by the answer.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Built in, so it needs no snippet of its own. Needs an AI provider; Escape or moving the caret cancels.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach($store.snippets) { $snippet in
                    DisclosureGroup(isExpanded: Binding(
                        get: { editing == snippet.id },
                        set: { editing = $0 ? snippet.id : nil }
                    )) {
                        TextField("Name", text: $snippet.name)
                        TextField("Abbreviation", text: $snippet.abbreviation,
                                  prompt: Text(";something"))
                            .help("What you type to trigger the expansion. Start with a character that never appears mid-word, like \";\". Leave empty for menu-only snippets.")
                        Toggle("Enabled", isOn: $snippet.enabled)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Template").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $snippet.template)
                                .font(.callout)
                                .frame(height: 70)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        }
                        Button(role: .destructive) { store.delete(snippet) } label: {
                            Label("Delete snippet", systemImage: "trash")
                        }
                    } label: {
                        HStack {
                            Text(snippet.name)
                                .foregroundStyle(snippet.enabled ? .primary : .secondary)
                            Spacer()
                            Text(snippet.abbreviation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button { store.add() } label: { Label("Add snippet", systemImage: "plus") }
                Text("Placeholders resolved at insert time: {date} {date+3d} {time} {time+2h} {clipboard} {meetlink} {slot} {slots:3} {commitments} {commitments:mine} {commitments:theirs} {ai: instruction}. They nest — {ai: Summarize in 3 bullets: {clipboard}} rewrites whatever you copied, right where you're typing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meeting link — {meetlink}") {
                TextField("My meeting room", text: $meetLink,
                          prompt: Text("https://meet.google.com/xxx-xxxx-xxx"))
                    .help("Your permanent Zoom Personal Meeting Room or reusable Google Meet link. {meetlink} pastes it into proposals.")
            }

            Section("Free time — {slot}") {
                Stepper("Workday starts at \(workStart):00", value: $workStart, in: 0...23)
                Stepper("Workday ends at \(workEnd):00", value: $workEnd, in: 1...24)
                Picker("Minimum slot", selection: $minSlot) {
                    Text("30 min").tag(30)
                    Text("45 min").tag(45)
                    Text("1 hour").tag(60)
                }
                Toggle("Weekdays only", isOn: $weekdaysOnly)
                Text("{slot} reads your calendars (read-only, asked on first use) and proposes the nearest gap in the next 7 days. Without Calendar access, every other snippet still works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SystemSettings: View {
    @ObservedObject var state: AppState
    @ObservedObject private var stats = UsageStats.shared
    var body: some View {
        SettingsTab {
            Section("Permissions") {
                permissionRow("Microphone", granted: Permissions.microphoneGranted,
                              detail: "Dictation and your side of meeting recordings. Without it, all text and screen features (OCR, captures, reminders, presets, projects) still work.")
                permissionRow("Speech recognition", granted: Permissions.speechGranted,
                              detail: "Apple's transcriber, used only as a fallback while local Whisper isn't installed. With Whisper set up, everything works without it.")
                permissionRow("Accessibility", granted: Permissions.accessibilityGranted,
                              detail: "Global hotkeys, reading your selection, and typing text at the cursor. Without it, every action is still available from the menu bar — use the clipboard or drag a screen region instead of a selection.")
                permissionRow("Screen recording", granted: Permissions.screenRecordingGranted,
                              detail: "System audio in meeting recordings, and reading the screen for OCR region / Draft reply. Without it, recordings capture your mic only, and text-selection features still work.")
                Button("Request Missing Permissions") { Permissions.requestAll() }
                Text("Each permission unlocks only the features listed next to it — nothing else stops working if you decline one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                LabeledContent("Version", value: AppInfo.version)
                if UpdateChecker.isConfigured {
                    Button("Check for Updates…") {
                        Task { await UpdateChecker.check(userInitiated: true) }
                    }
                    Text("Griasa also checks the GitHub Releases page once a day. Nothing is sent — it only reads the latest version number.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Update checks activate once a GitHub repository is set in BuildConfig.swift (updateRepo).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Support") {
                if let summary = stats.summary {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
                if SupportLinks.canSendFeedback {
                    Button("Send Feedback…") { SupportLinks.sendFeedback(topic: .settings) }
                        .help("Opens a mail draft with your app and macOS version pre-filled.")
                }
                if SupportLinks.canDonate {
                    Button("♥ Support Griasa") { SupportLinks.openDonate() }
                }
                Button("Open Welcome Guide") { HubController.shared.open(.welcome) }
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(name) {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(granted ? .green : .orange)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Modifier-preset picker + single-letter field, stored as "ctrl+opt+cmd+s".
private struct HotkeyField: View {
    let label: String
    @Binding var stored: String
    let fallback: String

    private static let modifierPresets: [(id: String, display: String)] = [
        ("", "None"),
        ("ctrl+opt+cmd", "⌃⌥⌘"),
        ("opt+cmd", "⌥⌘"),
        ("ctrl+opt", "⌃⌥"),
        ("ctrl+cmd", "⌃⌘"),
        ("shift+opt+cmd", "⇧⌥⌘"),
        ("ctrl+shift+cmd", "⌃⇧⌘"),
    ]

    private var parts: (mods: String, key: String) {
        let pieces = stored.lowercased().split(separator: "+").map(String.init)
        if pieces.count >= 2 {
            return (pieces.dropLast().joined(separator: "+"), pieces.last!)
        }
        // Empty / unset — default key letter comes from the fallback if any.
        let f = fallback.split(separator: "+").map(String.init)
        return ("", f.last ?? "s")
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(
                    get: { parts.mods },
                    set: { stored = $0.isEmpty ? "" : "\($0)+\(parts.key)" }
                )) {
                    ForEach(Self.modifierPresets, id: \.id) { preset in
                        Text(preset.display).tag(preset.id)
                    }
                }
                .labelsHidden()
                .frame(width: 90)

                TextField("", text: Binding(
                    get: { parts.key.uppercased() },
                    set: { newValue in
                        if let last = newValue.lowercased().last(where: { $0.isLetter || $0.isNumber }),
                           !parts.mods.isEmpty {
                            stored = "\(parts.mods)+\(last)"
                        }
                    }
                ))
                .frame(width: 36)
                .multilineTextAlignment(.center)
                .disabled(parts.mods.isEmpty)

                Text(KeyCombo.parse(stored)?.display ?? "—")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 60, alignment: .leading)
            }
        }
    }
}

