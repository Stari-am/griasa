import Foundation

/// Which microphone Griasa records from. Foundation only, so `test.sh` can
/// reach the rule; CoreAudio lookups live in `AudioInputs`.
///
/// Until this existed Griasa always took the system's default input and said
/// nothing about which one that was. A call app or a virtual device
/// (Zoom, Teams, BlackHole) can become the default input, and so can the
/// microphone of a closed laptop, and the person only finds out afterwards that
/// their own side of the meeting is missing.
enum MicChoice {
    /// UserDefaults key. Empty means "follow the system default".
    static let key = "micDeviceUID"

    struct Device: Equatable {
        let uid: String
        let name: String
    }

    /// The device to record from: the chosen one while it is connected, the
    /// system default otherwise. A chosen microphone that is unplugged must not
    /// stop the recording, so it falls back rather than failing.
    static func resolve(chosen: String, available: [Device], systemDefault: Device?) -> Device? {
        if !chosen.isEmpty, let match = available.first(where: { $0.uid == chosen }) {
            return match
        }
        return systemDefault
    }

    /// Whether the chosen microphone is missing, so the panel can say so
    /// instead of quietly recording from something else.
    static func isMissing(chosen: String, available: [Device]) -> Bool {
        !chosen.isEmpty && !available.contains { $0.uid == chosen }
    }
}
