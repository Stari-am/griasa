import AVFoundation
import Speech

/// Streams microphone audio into Apple's speech recognizer while the hotkey is
/// held, then returns the best transcription on release.
///
/// Automatic language detection: Apple's recognizer needs a fixed locale per
/// request, so one recognition "leg" runs per configured language in parallel
/// on the same audio, and the final result is picked by recognition
/// confidence. Every leg gets the tech/crypto vocabulary as contextual hints.
///
/// `@unchecked Sendable` because the mutable state here is confined to the
/// serial `stateQueue` — the recognizer's callbacks, the partial stream and the
/// finalization all run there — and the compiler cannot see a dispatch queue as
/// an isolation domain the way it sees an actor. The word to weigh is
/// *unchecked*: this is a claim about the code, not something proven by it, so
/// anything added below has to keep its mutations on `stateQueue`.
final class DictationEngine: @unchecked Sendable {
    private final class RecognitionLeg {
        let localeID: String
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var text = ""
        var score = 0.0
        var finished = false
        init(localeID: String) { self.localeID = localeID }
    }

    private let consumerID = UUID()
    private var legs: [RecognitionLeg] = []
    private var continuation: CheckedContinuation<String, Never>?
    private let stateQueue = DispatchQueue(label: "griasa.dictation.state")

    private(set) var detectedLocale: String?
    /// The captured utterance audio, kept so a higher-quality engine (Whisper)
    /// can re-transcribe it after the hotkey is released. Caller deletes it.
    private(set) var lastAudioURL: URL?
    private var audioFile: AVAudioFile?

    /// Fired with the stabilized partial transcription while the user is
    /// speaking (live typing). Called on an arbitrary queue.
    var onPartial: ((String) -> Void)?
    /// Locks the language leg and freezes settled words, so the two
    /// recognizers can't leapfrog each other and force the line to be retyped.
    /// Touched on `stateQueue` only.
    private var stabilizer = PartialStabilizer()

    /// Filters a locale list down to the ones this Mac can actually recognize,
    /// recording a reason for each rejection.
    private static func usableLocales(_ identifiers: [String], rejections: inout [String]) -> [String] {
        var usable: [String] = []
        for identifier in identifiers {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) else {
                rejections.append("\(identifier): locale not supported by this Mac")
                continue
            }
            guard recognizer.isAvailable else {
                rejections.append("\(identifier): recognizer exists but reports unavailable"
                    + " (on-device \(recognizer.supportsOnDeviceRecognition ? "supported" : "unsupported"))")
                continue
            }
            usable.append(identifier)
        }
        return usable
    }

    func start(localeIdentifiers: [String], vocabulary: [String]) throws {
        detectedLocale = nil
        lastAudioURL = nil
        audioFile = nil
        // Enqueued before any recognition callback can be, so it lands first.
        stateQueue.async { self.stabilizer.reset() }
        var newLegs: [RecognitionLeg] = []

        // Why each locale was skipped, so a total failure can say what's wrong
        // instead of just that it happened.
        var rejections: [String] = []

        var usable = Self.usableLocales(localeIdentifiers, rejections: &rejections)
        if usable.isEmpty {
            // A configuration problem must degrade, not kill the app's main
            // feature. An emptied Languages field left dictation with no
            // recognizer at all and an error that couldn't even name a locale.
            let fallbacks = [Locale.current.identifier, "en-US"]
                .filter { !localeIdentifiers.contains($0) }
            usable = Self.usableLocales(fallbacks, rejections: &rejections)
            if !usable.isEmpty {
                TypingTrace.log("configured locales unusable — fell back to \(usable.joined(separator: ","))")
            }
        }

        for identifier in usable {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) else { continue }
            let leg = RecognitionLeg(localeID: identifier)
            leg.request.shouldReportPartialResults = true
            leg.request.taskHint = .dictation
            leg.request.contextualStrings = vocabulary
            if recognizer.supportsOnDeviceRecognition {
                leg.request.requiresOnDeviceRecognition = true
            }
            leg.task = recognizer.recognitionTask(with: leg.request) { [weak self, weak leg] result, error in
                guard let self, let leg else { return }
                self.stateQueue.async {
                    if let result {
                        leg.text = result.bestTranscription.formattedString
                        if result.isFinal {
                            leg.score = SpeechScoring.score(result)
                            leg.finished = true
                            self.finishIfAllLegsDone()
                        } else {
                            self.emitPartial()
                        }
                    }
                    if let error {
                        // A leg that dies here goes silent for the rest of the
                        // utterance, and the trace showed ru-RU at 0 characters
                        // while en-US guessed at Russian speech. Whether that
                        // leg failed or simply heard nothing must be visible.
                        TypingTrace.log("leg \(leg.localeID) ended with error: \(error.localizedDescription)")
                        leg.finished = true
                        self.finishIfAllLegsDone()
                    }
                }
            }
            newLegs.append(leg)
        }

        guard !newLegs.isEmpty else {
            let authorization: String
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: authorization = "authorized"
            case .denied: authorization = "DENIED — turn Griasa on in System Settings → Privacy & Security → Speech Recognition"
            case .restricted: authorization = "restricted by this Mac's policy"
            case .notDetermined: authorization = "not yet asked — quit and reopen Griasa to get the prompt"
            @unknown default: authorization = "unknown"
            }
            let detail = "Speech Recognition permission: \(authorization). "
                + (rejections.isEmpty ? "" : rejections.joined(separator: "; ") + ". ")
                + "If permission is fine, the language assets may be missing — add the language under"
                + " System Settings → Keyboard → Dictation, then try again."
            TypingTrace.log("dictation start rejected — \(detail)")
            throw NSError(domain: "Griasa", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No speech recognizer available for \(localeIdentifiers.joined(separator: ", ")). \(detail)"
            ])
        }
        TypingTrace.log("recognizers ready: \(newLegs.map(\.localeID).joined(separator: ","))"
            + (rejections.isEmpty ? "" : " | skipped: \(rejections.joined(separator: "; "))"))
        legs = newLegs

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("griasa-dictation-\(UUID().uuidString).caf")
        lastAudioURL = audioURL

        let captured = newLegs
        var fileRef: AVAudioFile?
        // Measured, because the gap between pressing the hotkey and audio
        // actually flowing is speech the user loses — and it feeds the
        // recognizers silence, which is enough for a leg to declare "no speech
        // detected" and die for the rest of the utterance.
        let micStart = Date()
        defer {
            TypingTrace.log("mic tap ready in \(Int(Date().timeIntervalSince(micStart) * 1000)) ms")
        }
        try MicCapture.shared.addConsumer(consumerID) { [weak self] buffer, _ in
            for leg in captured {
                leg.request.append(buffer)
            }
            do {
                if fileRef == nil {
                    fileRef = try AVAudioFile(forWriting: audioURL, settings: buffer.format.settings)
                    self?.audioFile = fileRef
                }
                try fileRef?.write(from: buffer)
            } catch {
                NSLog("Griasa: failed to write dictation audio: %@", error.localizedDescription)
            }
        }
    }

    /// Stops capture and waits (bounded) for all language legs to finalize,
    /// then returns the highest-confidence transcription.
    func stop() async -> String {
        MicCapture.shared.removeConsumer(consumerID)
        audioFile = nil // closes the capture file

        let text: String = await withCheckedContinuation { cont in
            stateQueue.async {
                self.continuation = cont
                for leg in self.legs {
                    leg.request.endAudio()
                }
                // Don't wait forever for every leg's final result.
                self.stateQueue.asyncAfter(deadline: .now() + 2.0) {
                    self.finish()
                }
                self.finishIfAllLegsDone()
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Must be called on `stateQueue`.
    private func emitPartial() {
        guard continuation == nil else { return } // stopped; no more live updates
        let snapshot = legs.map { (locale: $0.localeID, text: $0.text) }
        guard let stable = stabilizer.absorb(legs: snapshot) else {
            let why = stabilizer.diverged ? "recognizer re-worded committed text" : "nothing agreed yet"
            TypingTrace.log("partial held — \(why) (legs=\(snapshot.map { "\($0.locale):\($0.text.count)" }.joined(separator: " ")))")
            return
        }
        TypingTrace.log("partial emit \(stable.count) chars, locked=\(stabilizer.lockedLocale ?? "none")")
        onPartial?(stable)
    }

    /// Must be called on `stateQueue`.
    private func finishIfAllLegsDone() {
        guard !legs.isEmpty, legs.allSatisfy({ $0.finished }) else { return }
        finish()
    }

    /// Must be called on `stateQueue`.
    private func finish() {
        guard let cont = continuation else { return }
        continuation = nil

        let best = legs
            .filter { !$0.text.isEmpty }
            .max { ($0.score, Double($0.text.count)) < ($1.score, Double($1.text.count)) }
        detectedLocale = best?.localeID

        for leg in legs {
            leg.task?.cancel()
            leg.task = nil
        }
        legs = []
        cont.resume(returning: best?.text ?? "")
    }
}

enum SpeechScoring {
    /// Length-weighted average segment confidence — the wrong-language leg
    /// scores noticeably lower than the right one.
    static func score(_ result: SFSpeechRecognitionResult) -> Double {
        let segments = result.bestTranscription.segments
        guard !segments.isEmpty else { return 0 }
        var weighted = 0.0
        var total = 0.0
        for segment in segments {
            let weight = Double(max(segment.substring.count, 1))
            weighted += Double(segment.confidence) * weight
            total += weight
        }
        return total > 0 ? weighted / total : 0
    }
}
