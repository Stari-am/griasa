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

    /// Sound has to keep going for this long before it counts as a conversation
    /// resuming, rather than as one loud noise.
    ///
    /// The number comes from a measurement. Every alert sound on macOS is
    /// between a third of a second and 2.16 s long (Funk, the longest), and the
    /// question this feature puts on screen plays one of them to reach somebody
    /// in another room. That beep came straight back in through the
    /// system-audio capture at -16.9 dBFS — 23 dB above the speech threshold —
    /// and, being indistinguishable from speech, made the question vanish about
    /// a second after it appeared, every time, before anyone could read it.
    /// 4 s clears the longest alert sound with room to spare, and still gets
    /// out of the way almost at once when people really do start talking.
    static let resumeAfter: TimeInterval = 4
    /// A gap longer than this ends the run. Speech pauses between words; it
    /// does not go quiet for two thirds of a second and remain one sound.
    static let runGap: TimeInterval = 0.6

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
    ///   - soundRun: how long the most recent unbroken stretch of sound lasted.
    ///   - asking: seconds the question has been on screen, or nil if it isn't.
    func decide(silentFor: TimeInterval, soundRun: TimeInterval,
                asking: TimeInterval?) -> Decision {
        // A conversation that has genuinely resumed saves the recording, and is
        // checked before anything else: stopping a recording that is once again
        // capturing speech would be the worst failure this feature could have.
        //
        // "Genuinely" is the part that had to be added. Sound still arriving is
        // not enough on its own — one noise was enough to cancel the question,
        // and the loudest noise available was the question's own beep.
        if silentFor <= Self.runGap, soundRun >= Self.resumeAfter { return .keepWatching }
        guard let asking else {
            return silentFor >= silenceAfter ? .ask : .keepWatching
        }
        // Do not cut a sound off half way through. If something is arriving
        // right now, give it another second to turn into a conversation.
        if asking >= replyWithin {
            return silentFor <= Self.runGap ? .ask : .stopAutomatically
        }
        return .ask
    }
}
