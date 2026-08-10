import Foundation
import AVFoundation
import Speech

struct TranscriptSegment {
    let start: TimeInterval
    let text: String
}

/// Transcribes a recorded audio file on-device, in ~30-second chunks so that
/// long meetings don't hit the recognizer's single-request limits.
///
/// Language detection works per chunk: each chunk is recognized in every
/// configured language in parallel and the highest-confidence result wins, so
/// a meeting that switches languages mid-way still transcribes correctly.
/// The tech/crypto vocabulary is passed as contextual hints to every request.
enum FileTranscriber {
    static func transcribeSegments(audio url: URL,
                                   localeIdentifiers: [String],
                                   vocabulary: [String]) async -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else { return [] }

        let recognizers = localeIdentifiers.compactMap { identifier -> SFSpeechRecognizer? in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
                  recognizer.isAvailable else { return nil }
            return recognizer
        }
        guard !recognizers.isEmpty else { return [] }

        let format = file.processingFormat
        guard format.sampleRate > 0 else { return [] }
        let chunkFrames = AVAudioFrameCount(format.sampleRate * 30)
        var segments: [TranscriptSegment] = []
        var offsetFrames: AVAudioFramePosition = 0

        while offsetFrames < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                break
            }
            if buffer.frameLength == 0 { break }

            let text = await recognizeBest(buffer: buffer, recognizers: recognizers, vocabulary: vocabulary)
            if !text.isEmpty {
                segments.append(TranscriptSegment(
                    start: Double(offsetFrames) / format.sampleRate,
                    text: text
                ))
            }
            offsetFrames += AVAudioFramePosition(buffer.frameLength)
        }
        return TranscriptCleaner.clean(segments)
    }

    /// Runs the chunk through every language's recognizer concurrently and
    /// returns the highest-confidence transcription.
    private static func recognizeBest(buffer: AVAudioPCMBuffer,
                                      recognizers: [SFSpeechRecognizer],
                                      vocabulary: [String]) async -> String {
        await withTaskGroup(of: (text: String, score: Double).self) { group in
            for recognizer in recognizers {
                group.addTask {
                    await recognize(buffer: buffer, recognizer: recognizer, vocabulary: vocabulary)
                }
            }
            var best: (text: String, score: Double) = ("", -1)
            for await candidate in group where !candidate.text.isEmpty && candidate.score > best.score {
                best = candidate
            }
            return best.text
        }
    }

    private static func recognize(buffer: AVAudioPCMBuffer,
                                  recognizer: SFSpeechRecognizer,
                                  vocabulary: [String]) async -> (text: String, score: Double) {
        await withCheckedContinuation { continuation in
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = false
            request.taskHint = .dictation
            request.contextualStrings = vocabulary
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            request.append(buffer)
            request.endAudio()

            let resumed = ResumeGuard()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if resumed.claim() {
                        continuation.resume(returning: (
                            result.bestTranscription.formattedString,
                            SpeechScoring.score(result)
                        ))
                    }
                } else if error != nil {
                    if resumed.claim() {
                        continuation.resume(returning: ("", 0))
                    }
                }
            }
        }
    }
}

/// Thread-safe one-shot flag so a recognition callback can't resume a
/// continuation twice.
final class ResumeGuard {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
