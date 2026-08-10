import SwiftUI
import AppKit
import AVFoundation

/// Accumulates audio buffers for one track and flushes ~fixed-length chunks to
/// a temp file for incremental transcription. Thread-safe: buffers arrive on
/// audio threads, flush is called from the notes loop.
final class LiveChunker: @unchecked Sendable {
    private let sessionStart: Date
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?
    private var chunkStart: TimeInterval = 0
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 16000

    init(sessionStart: Date) { self.sessionStart = sessionStart }

    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(frames) / sampleRate
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        do {
            if file == nil {
                let newURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("griasa-live-\(UUID().uuidString).caf")
                file = try AVAudioFile(forWriting: newURL, settings: buffer.format.settings)
                url = newURL
                sampleRate = buffer.format.sampleRate
                chunkStart = Date().timeIntervalSince(sessionStart)
                frames = 0
            }
            try file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            NSLog("Griasa: live chunk write failed: %@", error.localizedDescription)
        }
    }

    /// Closes the current chunk and returns it for transcription, resetting
    /// for the next window. Returns nil if too short to bother.
    func flush(minSeconds: Double) -> (url: URL, start: TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        guard let url, Double(frames) / sampleRate >= minSeconds else { return nil }
        file = nil
        let result = (url, chunkStart)
        self.url = nil
        frames = 0
        return result
    }
}

struct LiveSegment: Identifiable {
    let id = UUID()
    let start: TimeInterval
    let speaker: String
    let text: String
}

/// A note the user typed by hand during the recording. Saved into the
/// transcript at its timecode with the "📝 NOTE" marker, which the summary
/// prompts treat as high-signal input.
struct LiveNote: Identifiable, Sendable {
    let id = UUID()
    let time: TimeInterval
    let text: String

    var stamp: String {
        String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60)
    }
}

/// Drives realtime transcription + a periodically-refreshed running summary
/// while a recording is in progress. Requires the Whisper server.
@MainActor
final class LiveNotesController: ObservableObject {
    static let shared = LiveNotesController()

    @Published var segments: [LiveSegment] = []
    @Published var notes: [LiveNote] = []
    @Published var summary: String = ""
    @Published var isRunning = false
    @Published var isSummarizing = false
    /// The toggle in the recording tab: refresh the summary automatically
    /// every minute, or only when the user presses the refresh button.
    @Published var autoSummarize: Bool = UserDefaults.standard.object(forKey: "liveAutoSummary") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSummarize, forKey: "liveAutoSummary") }
    }

    private let windowSeconds = 18.0
    private let summaryEverySeconds = 60.0

    private var micChunker: LiveChunker?
    private var systemChunker: LiveChunker?
    private let micConsumerID = UUID()
    private var loop: Task<Void, Never>?
    private var sessionStart = Date()
    private var lastSummaryAt = Date.distantPast
    private var lastSummarizedCount = 0
    private var vocabulary: [String] = []
    private var myLabel = "You"
    private var themLabel = "Them"

    var canSummarize: Bool { AIFormatter.isConfigured }

    /// Called by AppState.startRecording when live notes are enabled.
    func start(vocabulary: [String], myName: String, recorder: ConversationRecorder) {
        guard WhisperTranscriber.isAvailable else { return }
        let start = Date()
        sessionStart = start
        segments = []
        notes = []
        summary = ""
        lastSummaryAt = .distantPast
        lastSummarizedCount = 0
        self.vocabulary = vocabulary
        self.myLabel = myName.isEmpty ? "You" : myName
        isRunning = true

        let mic = LiveChunker(sessionStart: start)
        let sys = LiveChunker(sessionStart: start)
        micChunker = mic
        systemChunker = sys

        try? MicCapture.shared.addConsumer(micConsumerID) { buffer, _ in
            mic.append(buffer)
        }
        recorder.onSystemBuffer = { buffer in sys.append(buffer) }

        HubController.shared.open(.recording)
        loop = Task { [weak self] in await self?.run() }
    }

    /// Adds a hand-typed note at the current point of the recording.
    func addNote(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        notes.append(LiveNote(time: max(0, Date().timeIntervalSince(sessionStart)), text: clean))
        notes.sort { $0.time < $1.time }
    }

    /// Snapshot handed to the meeting pipeline when the recording stops.
    func sessionNotes() -> [LiveNote] { notes }

    func stop() {
        loop?.cancel()
        loop = nil
        MicCapture.shared.removeConsumer(micConsumerID)
        // Final flush.
        Task { [weak self] in
            await self?.drain(minSeconds: 1.0)
            await MainActor.run { self?.isRunning = false }
        }
    }

    private func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(windowSeconds * 1_000_000_000))
            if Task.isCancelled { break }
            await drain(minSeconds: windowSeconds * 0.5)
            await maybeSummarize()
        }
    }

    private func drain(minSeconds: Double) async {
        await transcribeChunk(from: micChunker, speaker: myLabel, minSeconds: minSeconds)
        await transcribeChunk(from: systemChunker, speaker: themLabel, minSeconds: minSeconds)
    }

    private func transcribeChunk(from chunker: LiveChunker?, speaker: String, minSeconds: Double) async {
        guard let chunker, let chunk = chunker.flush(minSeconds: minSeconds) else { return }
        let text = await WhisperTranscriber.transcribeText(audio: chunk.url, vocabulary: vocabulary)
        try? FileManager.default.removeItem(at: chunk.url)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        segments.append(LiveSegment(start: chunk.start, speaker: speaker, text: clean))
        segments.sort { $0.start < $1.start }
    }

    private func maybeSummarize() async {
        guard autoSummarize,
              segments.count + notes.count > lastSummarizedCount,
              Date().timeIntervalSince(lastSummaryAt) >= summaryEverySeconds else { return }
        await summarize(interactive: false)
    }

    /// The refresh button in the recording tab — summarize on demand,
    /// regardless of the auto toggle and timers.
    func summarizeNow() {
        Task { await summarize(interactive: true) }
    }

    /// `interactive` gates the cloud-fallback dialog: the periodic auto
    /// refresh must never pop an alert every minute.
    private func summarize(interactive: Bool) async {
        guard AIFormatter.isConfigured, !isSummarizing,
              !(segments.isEmpty && notes.isEmpty) else { return }
        lastSummaryAt = Date()
        lastSummarizedCount = segments.count + notes.count
        isSummarizing = true

        // Interleave speech and typed notes chronologically; the 📝 NOTE
        // marker tells the prompt which lines are the user's own words.
        let lines = (segments.map { (time: $0.start, line: "\($0.speaker): \($0.text)") }
                     + notes.map { (time: $0.time, line: "📝 NOTE: \($0.text)") })
            .sorted { $0.time < $1.time }
        let transcript = lines.map(\.line).joined(separator: "\n")

        var system = Prompts.text(.liveSummary)
        if !notes.isEmpty {
            system += "\n\n\n" + Prompts.text(.liveSummaryNotes)
        }
        if let result = try? await AIFormatter.complete(
            system: system, user: transcript, tier: .smart,
            maxTokens: 4096, allowCloudFallback: interactive) {
            summary = result
        }
        isSummarizing = false
    }
}

struct LiveNotesView: View {
    @EnvironmentObject var live: LiveNotesController
    @State private var noteDraft = ""

    private var summaryAttributed: AttributedString {
        (try? AttributedString(markdown: live.summary,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(live.summary)
    }

    /// Speech segments and typed notes interleaved chronologically.
    private enum Row: Identifiable {
        case seg(LiveSegment)
        case note(LiveNote)
        var id: UUID {
            switch self {
            case .seg(let s): return s.id
            case .note(let n): return n.id
            }
        }
        var time: TimeInterval {
            switch self {
            case .seg(let s): return s.start
            case .note(let n): return n.time
            }
        }
    }

    private var rows: [Row] {
        (live.segments.map(Row.seg) + live.notes.map(Row.note))
            .sorted { $0.time < $1.time }
    }

    private func stamp(_ t: TimeInterval) -> String {
        "\(Int(t) / 60):\(String(format: "%02d", Int(t) % 60))"
    }

    var body: some View {
        HSplitView {
            // Live transcript + note input
            VStack(alignment: .leading, spacing: 6) {
                Label("Transcript", systemImage: "text.alignleft").font(.headline)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(rows) { row in
                                rowView(row)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(row.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: live.segments.count + live.notes.count) { _, _ in
                        if let last = rows.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                Divider()
                HStack {
                    TextField("Add a note — saved into the transcript at this timecode",
                              text: $noteDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addNote)
                    Button("Add", action: addNote)
                        .disabled(noteDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
            .frame(minWidth: 300)

            // Running summary
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Live summary", systemImage: "sparkles").font(.headline)
                    if live.isSummarizing { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle("Auto", isOn: $live.autoSummarize)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Refresh the summary automatically every minute")
                    Button {
                        live.summarizeNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Summarize now")
                    .disabled(live.isSummarizing || !live.canSummarize
                              || (live.segments.isEmpty && live.notes.isEmpty))
                }
                Divider()
                ScrollView {
                    if live.summary.isEmpty {
                        Text(emptySummaryHint)
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(summaryAttributed).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                Button("Copy Summary") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(live.summary, forType: .string)
                }
                .disabled(live.summary.isEmpty)
            }
            .padding(12)
            .frame(minWidth: 260)
        }
        .frame(minWidth: 620, minHeight: 380)
    }

    private var emptySummaryHint: String {
        if !live.isRunning { return "Not recording." }
        if !live.canSummarize { return "Configure an AI provider in Settings → AI & Actions to get a live summary." }
        return live.autoSummarize
            ? "The summary updates every minute as the conversation develops…"
            : "Auto-summary is off — press ⟳ to summarize on demand."
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .seg(let seg):
            VStack(alignment: .leading, spacing: 1) {
                Text("\(seg.speaker) · \(stamp(seg.start))")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(seg.text).font(.callout).textSelection(.enabled)
            }
        case .note(let note):
            HStack(alignment: .top, spacing: 6) {
                Text("📝")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Note · \(stamp(note.time))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(note.text).font(.callout).italic().textSelection(.enabled)
                }
            }
            .padding(6)
            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func addNote() {
        live.addNote(noteDraft)
        noteDraft = ""
    }
}
