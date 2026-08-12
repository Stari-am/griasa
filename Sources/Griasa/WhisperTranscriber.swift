import Foundation
import AVFoundation

/// Local Whisper (whisper.cpp) transcription — much higher accuracy than the
/// Apple recognizer, with true automatic language detection built into the
/// model. The tech/crypto vocabulary is passed as an initial prompt.
///
/// Timeline correctness: whisper.cpp's built-in `--vad` concatenates speech
/// chunks and re-times them continuously, so text after a long pause gets a
/// too-early timestamp (upstream issue ggml-org/whisper.cpp#3634). To keep
/// segments in true chronological order, Griasa instead runs Silero VAD
/// itself (`whisper-vad-speech-segments`), slices each speech region out of
/// the audio, transcribes regions individually via the warm `whisper-server`,
/// and stamps each with the region's real start time.
enum WhisperTranscriber {
    static let modelURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Griasa/ggml-large-v3-turbo.bin")

    /// Silero VAD model — lets Whisper skip silence entirely, which is the
    /// main defense against hallucination/repetition loops on quiet tracks
    /// (a mostly-silent mic while the other side talks, and vice versa).
    static let vadModelURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Griasa/ggml-silero-v5.1.2.bin")

    static var binaryPath: String? {
        for path in ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    static var isAvailable: Bool {
        binaryPath != nil && FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// Transcribes an audio file, returning timestamped segments. Language is
    /// detected automatically by the model (`-l auto`).
    static func transcribeSegments(audio url: URL, vocabulary: [String]) async -> [TranscriptSegment] {
        guard isAvailable, FileManager.default.fileExists(atPath: url.path) else { return [] }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("griasa-whisper-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Whisper wants 16 kHz mono PCM; afconvert ships with macOS.
        let wav = workDir.appendingPathComponent("audio.wav")
        guard await run("/usr/bin/afconvert",
                        ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", url.path, wav.path]) else {
            return []
        }

        // Preferred path: our own VAD regions + warm server, with true offsets.
        if let regions = await speechRegions(wav: wav), !regions.isEmpty,
           await WhisperServer.shared.ensureRunning(vocabulary: vocabulary) {
            var segments: [TranscriptSegment] = []
            for (index, region) in regions.enumerated() {
                let slice = workDir.appendingPathComponent("region-\(index).wav")
                guard extractRegion(from: wav, region: region, to: slice) else { continue }
                if let text = await WhisperServer.shared.transcribe(wav: slice), !text.isEmpty {
                    segments.append(TranscriptSegment(start: region.start, text: text))
                }
            }
            return TranscriptCleaner.clean(segments)
        }

        // Fallback: single-pass CLI with whisper's built-in VAD (timestamps
        // can drift across long silences — upstream #3634).
        guard let binary = binaryPath else { return [] }
        let outPrefix = workDir.appendingPathComponent("out")
        let prompt = "Glossary: " + vocabulary.joined(separator: ", ") + "."
        var arguments = [
            "-m", modelURL.path,
            "-f", wav.path,
            "-l", "auto",
            "--prompt", prompt,
            "--suppress-nst",  // suppress non-speech tokens
        ] + Self.loopGuards + [
            "-oj",
            "-of", outPrefix.path,
            "-np",  // no progress prints
        ]
        if FileManager.default.fileExists(atPath: vadModelURL.path) {
            arguments += ["--vad", "-vm", vadModelURL.path]
        }
        guard await run(binary, arguments) else { return [] }

        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: outPrefix.path + ".json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let transcription = json["transcription"] as? [[String: Any]]
        else { return [] }

        var segments: [TranscriptSegment] = []
        for item in transcription {
            guard let text = (item["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let offsets = item["offsets"] as? [String: Any]
            let fromMS = (offsets?["from"] as? NSNumber)?.doubleValue ?? 0
            segments.append(TranscriptSegment(start: fromMS / 1000.0, text: text))
        }
        return TranscriptCleaner.clean(segments)
    }

    /// Decoder settings that keep Whisper out of its repetition loop, where it
    /// emits the same phrase until the segment ends. A carried-over text context
    /// is what feeds the loop (whisper.cpp #1017 traces it to `--prompt`
    /// specifically), so the context is bounded rather than unlimited; the
    /// entropy threshold is what detects a degenerate run of tokens and forces a
    /// re-decode at a higher temperature, so it is raised off its default.
    ///
    /// Temperature fallback is deliberately left enabled — the entropy check has
    /// nothing to escalate to without it, so `--no-fallback` would quietly turn
    /// this guard off.
    private static let loopGuards = ["-mc", "64", "-et", "2.6"]

    /// Convenience: full text of a file (for dictation). Uses the warm server
    /// directly when it's already up (near-instant); otherwise the CLI path.
    static func transcribeText(audio url: URL, vocabulary: [String]) async -> String {
        if await WhisperServer.shared.isUp() {
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("griasa-dictate-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }
            let wav = workDir.appendingPathComponent("audio.wav")
            if await run("/usr/bin/afconvert",
                         ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", url.path, wav.path]),
               let text = await WhisperServer.shared.transcribe(wav: wav), !text.isEmpty {
                let cleaned = TranscriptCleaner.clean([TranscriptSegment(start: 0, text: text)])
                    .map(\.text).joined(separator: " ")
                return deloop(cleaned)
            }
        }
        let segments = await transcribeSegments(audio: url, vocabulary: vocabulary)
        return deloop(segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// No decoder setting makes looping impossible, and a loop reaching the
    /// user's document is the worst outcome this app has — one spoken sentence
    /// arrived seven times. So the transcript is checked here as well, where the
    /// behavior is testable and the trace records what was removed.
    private static func deloop(_ text: String) -> String {
        let result = SpeechRepetition.collapse(text)
        if result.dropped > 0 {
            TypingTrace.log("whisper loop collapsed — dropped \(result.dropped) repeat(s), \(text.count) -> \(result.text.count) chars")
        }
        return result.text
    }

    // MARK: - VAD regions

    struct SpeechRegion {
        var start: Double
        var end: Double
        var duration: Double { end - start }
    }

    private static var vadToolPath: String? {
        for path in ["/opt/homebrew/bin/whisper-vad-speech-segments", "/usr/local/bin/whisper-vad-speech-segments"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Runs Silero VAD over the file and returns merged, padded speech
    /// regions in seconds on the original timeline. Nil when the tool or VAD
    /// model is unavailable.
    static func speechRegions(wav: URL) async -> [SpeechRegion]? {
        guard let tool = vadToolPath,
              FileManager.default.fileExists(atPath: vadModelURL.path) else { return nil }

        guard let output = await runCapturingOutput(tool, ["-vm", vadModelURL.path, "-f", wav.path]) else {
            return nil
        }
        // Lines look like: "Speech segment 12: start = 20042.00, end = 20077.00"
        var raw: [SpeechRegion] = []
        for line in output.split(separator: "\n") {
            guard line.contains("start ="),
                  let startRange = line.range(of: "start = "),
                  let endRange = line.range(of: "end = ") else { continue }
            let startText = line[startRange.upperBound...].prefix(while: { $0 != "," })
            let endText = line[endRange.upperBound...]
            guard let start = Double(startText.trimmingCharacters(in: .whitespaces)),
                  let end = Double(endText.trimmingCharacters(in: .whitespaces)), end > start else { continue }
            raw.append(SpeechRegion(start: start, end: end))
        }
        guard !raw.isEmpty else { return [] }

        // The tool prints whisper's internal 10 ms units; detect the scale
        // against the real file duration to be robust across versions.
        let duration = audioDuration(of: wav)
        let maxEnd = raw.map(\.end).max() ?? 0
        var scale = 1.0
        if duration > 0 {
            for candidate in [1.0, 0.01, 0.001] where maxEnd * candidate <= duration * 1.05 {
                scale = candidate
                break
            }
        }
        var regions = raw.map { SpeechRegion(start: $0.start * scale, end: $0.end * scale) }

        // Pad, merge close regions, drop blips, split very long ones.
        let pad = 0.25, mergeGap = 1.0, minDuration = 0.2, maxDuration = 30.0
        regions = regions.map {
            SpeechRegion(start: max(0, $0.start - pad),
                         end: duration > 0 ? min(duration, $0.end + pad) : $0.end + pad)
        }
        var merged: [SpeechRegion] = []
        for region in regions {
            if var last = merged.last, region.start - last.end < mergeGap {
                last.end = max(last.end, region.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(region)
            }
        }
        var final: [SpeechRegion] = []
        for region in merged where region.duration >= minDuration {
            var cursor = region.start
            while region.end - cursor > maxDuration {
                final.append(SpeechRegion(start: cursor, end: cursor + maxDuration))
                cursor += maxDuration
            }
            final.append(SpeechRegion(start: cursor, end: region.end))
        }
        return final
    }

    private static func audioDuration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Copies one time region of a WAV file into a new WAV file.
    private static func extractRegion(from wav: URL, region: SpeechRegion, to output: URL) -> Bool {
        guard let source = try? AVAudioFile(forReading: wav) else { return false }
        let sampleRate = source.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(region.start * sampleRate)
        let frameCount = AVAudioFrameCount(max(0, region.duration) * sampleRate)
        guard frameCount > 0, startFrame < source.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frameCount)
        else { return false }
        source.framePosition = startFrame
        do {
            try source.read(into: buffer, frameCount: frameCount)
            let sink = try AVAudioFile(forWriting: output,
                                       settings: source.fileFormat.settings,
                                       commonFormat: source.processingFormat.commonFormat,
                                       interleaved: source.processingFormat.isInterleaved)
            try sink.write(from: buffer)
            return true
        } catch {
            return false
        }
    }

    private static func runCapturingOutput(_ launchPath: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: p.terminationStatus == 0
                    ? String(data: data, encoding: .utf8) : nil)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private static func run(_ launchPath: String, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                NSLog("Griasa: failed to launch %@: %@", launchPath, error.localizedDescription)
                continuation.resume(returning: false)
            }
        }
    }
}
