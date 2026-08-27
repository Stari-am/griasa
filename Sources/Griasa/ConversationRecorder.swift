import Foundation
import AVFoundation

/// Records a conversation session: your microphone and everything the Mac
/// plays (the other side of a call, a video, etc.) into a timestamped folder.
/// Optionally produces text transcripts of both tracks when the session ends.
@MainActor
final class ConversationRecorder {
    static let recordingsRoot: URL = {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Griasa Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private let micConsumerID = UUID()
    private var micFile: AVAudioFile?
    private var systemCapture: SystemAudioCapture?
    private(set) var currentFolder: URL?
    /// True when the session is recording system audio but the microphone
    /// couldn't be tapped — the caller surfaces this so the user isn't left
    /// with a silent half-recording they didn't know about.
    private(set) var micUnavailable = false

    /// Live tap for the system-audio (remote participants) track, used by
    /// realtime notes. Set before `start()`.
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = Self.recordingsRoot.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        currentFolder = folder
        micUnavailable = false

        // System audio (requires Screen Recording permission). Start it first so
        // a permission failure aborts the session before we touch the mic.
        let system = SystemAudioCapture(outputURL: folder.appendingPathComponent("system-audio.caf"))
        system.onPCMBuffer = { [weak self] buffer in
            // Fed here rather than through onSystemBuffer, which live notes
            // reassign to themselves — the watch has to see this input whether
            // live notes are on or not.
            SilenceWatch.shared.heard(buffer)
            self?.onSystemBuffer?(buffer)
        }
        try await system.start()
        systemCapture = system

        // Microphone track. A mic failure must NOT abandon the session: the
        // system capture is already running, and throwing here would leave it
        // orphaned (writing forever, no stop, no transcript) while the app
        // believes nothing is recording. Record system-only and flag it.
        let micURL = folder.appendingPathComponent("microphone.caf")
        var micFileRef: AVAudioFile?
        do {
            try MicCapture.shared.addConsumer(micConsumerID) { [weak self] buffer, _ in
                SilenceWatch.shared.heard(buffer)
                do {
                    if micFileRef == nil {
                        micFileRef = try AVAudioFile(forWriting: micURL, settings: buffer.format.settings)
                        Task { @MainActor [weak self] in self?.micFile = micFileRef }
                    }
                    try micFileRef?.write(from: buffer)
                } catch {
                    NSLog("Griasa: failed to write mic audio: %@", error.localizedDescription)
                }
            }
        } catch {
            micUnavailable = true
            NSLog("Griasa: microphone unavailable, recording system audio only: %@",
                  error.localizedDescription)
        }
    }

    /// Stops the session and returns the folder holding its audio files, so
    /// the caller can run transcription on it.
    func stop() async -> URL? {
        MicCapture.shared.removeConsumer(micConsumerID)
        await systemCapture?.stop()
        systemCapture = nil
        micFile = nil
        let folder = currentFolder
        currentFolder = nil
        return folder
    }
}
