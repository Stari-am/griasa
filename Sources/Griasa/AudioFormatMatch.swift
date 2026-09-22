import Foundation

/// Whether two audio formats are the same one, for the two places where being
/// wrong costs a recording rather than an error.
///
/// Foundation only, so `test.sh` can reach it: AVFoundation's own types cannot
/// be constructed for a format that no device on the machine offers, and every
/// case worth checking here is exactly that.
///
/// Measured on a Mac with AirPods Pro, September 2026. A tap whose format does
/// not match the live hardware produces **no audio at all**, and it fails in two
/// different ways: `AVAudioEngine.start()` threw -10868 when the node was at
/// 48 kHz against hardware at 24 kHz, and in another attempt reported success
/// and then delivered zero buffers for three seconds. The second shape is the
/// dangerous one — nothing is thrown, nothing is logged, and the meeting is
/// recorded with one side missing.
enum AudioFormatMatch {
    /// Both parts matter. A device in a transitional state reports a rate and no
    /// channels, and one that has switched profile — Bluetooth moving into call
    /// mode is the everyday case — reports the same channel count at half the
    /// rate.
    /// One `usable` call, not two: with both equalities required, a usable
    /// format on either side makes the other one usable as well. The second
    /// call was written first and survived a mutation — it could be deleted
    /// without a check noticing, which is the definition of code that is not
    /// doing anything.
    static func agree(rate: Double, channels: UInt32,
                      otherRate: Double, otherChannels: UInt32) -> Bool {
        usable(rate: rate, channels: channels)
            && rate == otherRate
            && channels == otherChannels
    }

    /// A format that describes no audio. Worth its own answer: "the microphone
    /// is not there" and "the microphone is there and disagrees with itself" are
    /// different sentences to show somebody.
    static func usable(rate: Double, channels: UInt32) -> Bool {
        rate > 0 && channels > 0
    }
}
