import Foundation

/// Level measurement and the silence decision, kept free of AVFoundation and
/// AppKit so both can be tested in isolation — the same reason
/// PartialStabilizer lives on its own. SilenceWatch is the glue that feeds
/// real buffers in and puts a window on screen.

enum AudioLevel {
    /// Root-mean-square of the samples, in dBFS: 0 is full scale, quieter is
    /// more negative. Digital silence has no logarithm, so it reports a floor
    /// rather than -infinity — a caller comparing against a threshold should
    /// not have to special-case a non-finite value.
    static let floor: Float = -160

    static func dBFS(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return floor }
        var sum: Double = 0
        for i in 0..<count {
            let sample = Double(samples[i])
            sum += sample * sample
        }
        return dBFS(meanSquare: sum / Double(count))
    }

    /// Int16 buffers are normalised to ±1 first, so the threshold means the
    /// same thing whichever format the input device happens to hand us.
    static func dBFS(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return floor }
        var sum: Double = 0
        let scale = 1.0 / Double(Int16.max)
        for i in 0..<count {
            let sample = Double(samples[i]) * scale
            sum += sample * sample
        }
        return dBFS(meanSquare: sum / Double(count))
    }

    static func dBFS(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return floor }
            return dBFS(base, count: buffer.count)
        }
    }

    private static func dBFS(meanSquare: Double) -> Float {
        guard meanSquare > 0 else { return floor }
        return max(floor, Float(10 * log10(meanSquare)))
    }

    /// Anything at or above this counts as somebody talking.
    ///
    /// Chosen against the two things that actually occur: a quiet room through
    /// a Mac's own microphone sits around -55 to -45 dBFS, and speech at a
    /// normal distance sits around -30 to -10. -40 is the gap between them.
    /// Higher and a soft speaker on a laptop mic reads as silence; lower and
    /// room tone keeps the recording alive all night, which is the bug this
    /// exists to stop.
    static let speechThreshold: Float = -40
}

/// When to ask, and when to stop without an answer. Pure arithmetic on
/// durations so the awkward cases are decided here, in something that can be
/// tested, rather than inside a timer callback.
struct SilenceClock {
    /// Silence this long triggers the question.
    let silenceAfter: TimeInterval
    /// The question waits this long for an answer before stopping the recording.
    let replyWithin: TimeInterval

    enum Decision: Equatable {
        /// Nothing to do — either there is sound, or the silence is still young.
        case keepWatching
        /// Show the question, or keep showing it.
        case ask
        /// Nobody answered. Stop and process.
        case stopAutomatically
    }

    /// - Parameters:
    ///   - silentFor: seconds since the last buffer above the speech threshold,
    ///     from either input.
    ///   - asking: seconds the question has been on screen, or nil if it isn't.
    func decide(silentFor: TimeInterval, asking: TimeInterval?) -> Decision {
        // Sound came back. This is deliberately checked before the countdown:
        // if the meeting resumes while the question is up, the recording must
        // survive, and the question must go away on its own. Stopping a
        // recording that is once again capturing speech would be the worst
        // failure this feature could have.
        if silentFor < silenceAfter { return .keepWatching }
        if let asking { return asking >= replyWithin ? .stopAutomatically : .ask }
        return .ask
    }
}
