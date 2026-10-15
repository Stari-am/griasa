import Foundation

/// `Griasa --long-meeting-eval N [--cloud <providerRaw>]` — a dev-only probe that
/// answers one question before the long-meeting path ships: is the notes and
/// promise result of reading a meeting in parts on the local model at least as
/// good as today's single pass, and how near is it to a cloud model reading the
/// whole transcript?
///
/// For each of the N longest meetings that still have `transcript-raw.txt` it
/// writes, under `dist/eval-2026-10/<entry-id>/` (relative to the directory it
/// is run from): `single.md`, `chunked.md`, `cloud.md`, `promises-{single,chunked,cloud}.json`
/// and `timing.json`. Local runs always use Griasa's own engine, whatever
/// provider is selected. Nothing in any store is written. Standard output has
/// counts and seconds only — never transcript text or names; the content is in
/// the files, on this Mac.
@MainActor
enum LongMeetingEval {
    private struct Variant {
        var seconds: Double?
        var promisesSeconds: Double?
        var promises: Int?
        var error: String?
    }

    static func run(count: Int, cloudRaw: String?) async -> Never {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/eval-2026-10", isDirectory: true)

        guard let local = LLMConfig.ownEngine() else {
            print("No local model is downloaded for Griasa's own engine — nothing to evaluate.")
            exit(2)
        }
        var cloud: LLMConfig?
        if let cloudRaw {
            guard let provider = LLMProvider(rawValue: cloudRaw), provider != .custom else {
                print("--cloud needs a provider name such as anthropic, openAI, gemini, claudeCLI, codexCLI.")
                exit(2)
            }
            cloud = LLMConfig.config(for: provider)
        } else {
            let current = LLMConfig.current()
            cloud = current.runsOnThisMac ? nil : current
        }
        if let candidate = cloud, !candidate.isConfigured { cloud = nil }
        print("local model: Griasa's own engine · cloud reference: \(cloud.map { $0.provider.rawValue } ?? "none (no cloud provider configured)")")

        // The N longest by the transcript on disk.
        let meetings: [(entry: HistoryEntry, raw: String)] = HistoryStore.shared.entries
            .filter { $0.kind == .meeting }
            .compactMap { entry in
                guard let path = entry.filePath, let raw = MeetingTranscriber.rawTranscript(besideNotes: path)
                else { return nil }
                return (entry, raw)
            }
            .sorted { $0.raw.count > $1.raw.count }
            .prefix(count).map { $0 }
        print("meetings: \(meetings.count)\n")

        let myName = ParticipantRoster.shared.myName
        for (index, meeting) in meetings.enumerated() {
            let raw = meeting.raw
            let participants = meeting.entry.participants ?? []
            let hasNotes = raw.contains("📝 NOTE:")
            let folder = root.appendingPathComponent(meeting.entry.id.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let chunkCount = TranscriptChunker.chunks(raw).count

            var single = Variant(), chunked = Variant(), reference = Variant()
            var droppedActions = 0

            func timed<T>(_ work: () async throws -> T) async -> (T?, Double, String?) {
                let started = Date()
                do {
                    let value = try await work()
                    return (value, Date().timeIntervalSince(started), nil)
                } catch {
                    return (nil, Date().timeIntervalSince(started), error.localizedDescription)
                }
            }
            func save(_ text: String, _ name: String) {
                try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            func promises(of notes: String, config: LLMConfig, inParts: Bool, name: String,
                          into variant: inout Variant) async {
                let (found, seconds, error) = await timed {
                    try await CommitmentExtractor.findCommitments(
                        markdown: notes, rawTranscript: raw, participants: participants, myName: myName,
                        sourceTitle: "eval", sourceEntryID: nil, config: config, inParts: inParts)
                }
                variant.promisesSeconds = seconds
                if let error { variant.error = (variant.error.map { $0 + " · " } ?? "") + "promises: " + error }
                guard let found else { return }
                variant.promises = found.commitments.count
                let list: [[String: Any]] = found.commitments.map { item in
                    ["text": item.text, "owner": item.owner, "mine": item.isMine,
                     "dueHint": item.dueHint ?? NSNull(), "quote": item.sourceQuote ?? NSNull(),
                     "at": item.sourceAt ?? NSNull()]
                }
                let document: [String: Any] = [
                    "promises": list, "requests": found.requests, "proposed": found.proposed,
                    "droppedForNoQuote": found.unquoted, "unreadableReplies": found.unreadable,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: document,
                                                          options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: folder.appendingPathComponent(name))
                }
            }

            // 1. Today's local single pass, truncated as today.
            let (singleNotes, singleSeconds, singleError) = await timed {
                try await MeetingTranscriber.aiFormat(
                    raw: raw, participants: participants, myName: myName, hasNotes: hasNotes,
                    allowCloudFallback: false, config: local, mode: .singlePass)
            }
            single.seconds = singleSeconds
            single.error = singleError
            if let singleNotes {
                save(singleNotes, "single.md")
                await promises(of: singleNotes, config: local, inParts: false, name: "promises-single.json", into: &single)
            }

            // 2. The new path.
            let (chunkedOutput, chunkedSeconds, chunkedError) = await timed {
                try await LongMeetingNotes.make(raw: raw, participants: participants, myName: myName,
                                                hasNotes: hasNotes, allowCloudFallback: false, config: local)
            }
            chunked.seconds = chunkedSeconds
            chunked.error = chunkedError
            if let chunkedOutput {
                droppedActions = chunkedOutput.droppedActions
                save(chunkedOutput.markdown, "chunked.md")
                await promises(of: chunkedOutput.markdown, config: local, inParts: true,
                               name: "promises-chunked.json", into: &chunked)
            }

            // 3. A cloud model reading the whole transcript in one request.
            if let cloud {
                let (cloudNotes, cloudSeconds, cloudError) = await timed {
                    try await MeetingTranscriber.aiFormat(
                        raw: raw, participants: participants, myName: myName, hasNotes: hasNotes,
                        allowCloudFallback: false, config: cloud, mode: .singlePass)
                }
                reference.seconds = cloudSeconds
                reference.error = cloudError
                if let cloudNotes {
                    save(cloudNotes, "cloud.md")
                    await promises(of: cloudNotes, config: cloud, inParts: false,
                                   name: "promises-cloud.json", into: &reference)
                }
            }

            func json(_ v: Variant) -> [String: Any] {
                ["notesSeconds": v.seconds.map { ($0 * 10).rounded() / 10 } ?? NSNull(),
                 "promisesSeconds": v.promisesSeconds.map { ($0 * 10).rounded() / 10 } ?? NSNull(),
                 "promises": v.promises ?? NSNull(), "error": v.error ?? NSNull()]
            }
            let timing: [String: Any] = [
                "rawChars": raw.count, "chunks": chunkCount, "unquotedActionsDroppedInChunkedNotes": droppedActions,
                "single": json(single), "chunked": json(chunked), "cloud": json(reference),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: timing, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("timing.json"))
            }

            func cell(_ v: Variant) -> String {
                guard let seconds = v.seconds else { return "failed" }
                return String(format: "%.0fs+%.0fs", seconds, v.promisesSeconds ?? 0)
            }
            func count(_ v: Variant) -> String { v.promises.map(String.init) ?? "-" }
            print("\(index + 1). \(meeting.entry.id.uuidString.prefix(8)) · \(raw.count) chars, \(chunkCount) chunks"
                  + " · notes+promises seconds: single \(cell(single)), chunked \(cell(chunked)), cloud \(cell(reference))"
                  + " · promises: single \(count(single)), chunked \(count(chunked)), cloud \(count(reference))")
        }

        LlamaServer.shared.stop()
        print("\nfiles: \(root.path)/<entry-id>/ — nothing in any store was changed.")
        exit(0)
    }
}
