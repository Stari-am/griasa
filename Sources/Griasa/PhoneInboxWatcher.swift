import AVFoundation
import Foundation

/// Picks up what the iPhone puts in iCloud Drive → Griasa → Inbox and files it
/// as a meeting (see `PhoneInbox`). Audio becomes text on this Mac, with the
/// same speech engine as dictation; only that text goes on to the summary.
@MainActor
final class PhoneInboxWatcher: ObservableObject {
    static let shared = PhoneInboxWatcher()
    static let enabledKey = "phoneInboxEnabled"

    @Published private(set) var working: String?
    @Published private(set) var lastImported: String?
    @Published private(set) var problem: String?

    private var timer: Timer?
    private var busy = false
    /// Files already taken this session, by path and date: if moving one out
    /// of the inbox fails, it must not be filed again every thirty seconds.
    private var handled: Set<String> = []

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var folder: URL { PhoneInbox.folder(home: FileManager.default.homeDirectoryForCurrentUser) }
    /// iCloud Drive is on when its folder exists.
    var hasICloudDrive: Bool {
        FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().deletingLastPathComponent().path)
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await scan() }
    }

    func setEnabled(_ on: Bool) async {
        guard on else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            problem = nil
            return
        }
        guard hasICloudDrive else {
            problem = "iCloud Drive is off on this Mac. Turn it on in System Settings → Apple Account → iCloud → iCloud Drive."
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            problem = "Couldn't make the Inbox folder in iCloud Drive: \(error.localizedDescription)"
            return
        }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        problem = nil
        await scan()
    }

    func scan() async {
        guard enabled, !busy else { return }
        busy = true
        defer { busy = false; working = nil }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        let now = Date()
        for name in names.sorted() {
            // Still in iCloud only: ask for it, and take it on a later pass.
            if let target = PhoneInbox.placeholderTarget(name), PhoneInbox.kind(of: target) != .skip {
                try? manager.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(target))
                continue
            }
            let kind = PhoneInbox.kind(of: name)
            guard kind != .skip else { continue }
            let url = folder.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey])
            guard values?.isDirectory != true,
                  PhoneInbox.isSettled(modified: values?.contentModificationDate ?? now, now: now) else { continue }
            let key = url.path + "|" + String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            guard handled.insert(key).inserted else { continue }
            working = name
            let date = values?.creationDate ?? values?.contentModificationDate ?? now
            if let title = await take(url, kind: kind, date: date) {
                move(url, into: PhoneInbox.importedFolder)
                lastImported = title
                Notifier.post(title: "From your iPhone", body: title, opens: .commitments)
            } else {
                move(url, into: PhoneInbox.failedFolder)
                problem = "Nothing could be read from “\(name)”. It is in Inbox → \(PhoneInbox.failedFolder)."
            }
        }
    }

    /// Reads one file and files it. The title, or nil when there was no text.
    private func take(_ url: URL, kind: PhoneInbox.Kind, date: Date) async -> String? {
        let state = AppState.shared
        let body: String
        switch kind {
        case .text:
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            body = ImportedNotes.clean(text)
        case .audio:
            let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            if seconds > PhoneInbox.conversationSeconds {
                body = await conversation(url, vocabulary: state.vocabularyList, locales: state.localeList)
            } else if WhisperTranscriber.isAvailable {
                body = await WhisperTranscriber.transcribeText(audio: url, vocabulary: state.vocabularyList)
            } else {
                body = await FileTranscriber.transcribeSegments(audio: url, localeIdentifiers: state.localeList,
                                                                vocabulary: state.vocabularyList)
                    .map(\.text).joined(separator: " ")
            }
        case .skip:
            return nil
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let title = PhoneInbox.title(from: kind == .audio && body.hasPrefix("#") ? MeetingTranscriber.title(fromMarkdown: body) : body)
        let people = PhoneInbox.mentionedPeople(in: body, known: PersonStore.shared.allNames)
        MeetingImport.file(body: body + ImportedNotes.provenance(source: "iPhone"), title: title, date: date,
                           participants: people)
        return title
    }

    /// A long recording — a call — is written up as a meeting is: a summary
    /// with what was promised, or the plain transcript without a model.
    private func conversation(_ url: URL, vocabulary: [String], locales: [String]) async -> String {
        let segments = WhisperTranscriber.isAvailable
            ? await WhisperTranscriber.transcribeSegments(audio: url, vocabulary: vocabulary, meeting: true)
            : await FileTranscriber.transcribeSegments(audio: url, localeIdentifiers: locales, vocabulary: vocabulary)
        let raw = segments.map { "[\(Int($0.start) / 60):\(String(format: "%02d", Int($0.start) % 60))] \($0.text)" }
            .joined(separator: "\n")
        guard !raw.isEmpty else { return "" }
        if AIFormatter.isConfigured,
           let notes = try? await MeetingTranscriber.aiFormat(raw: raw, participants: [],
                                                               myName: ParticipantRoster.shared.myName, hasNotes: false) {
            return notes
        }
        return "## Transcript\n\n" + raw
    }

    private func move(_ url: URL, into sub: String) {
        let manager = FileManager.default
        let target = folder.appendingPathComponent(sub, isDirectory: true)
        try? manager.createDirectory(at: target, withIntermediateDirectories: true)
        let taken = Set((try? manager.contentsOfDirectory(atPath: target.path)) ?? [])
        let name = PhoneInbox.freeName(url.lastPathComponent, taken: taken)
        try? manager.moveItem(at: url, to: target.appendingPathComponent(name))
    }
}
