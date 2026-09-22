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
    private var micTrack: MicTrack?
    private var systemCapture: SystemAudioCapture?
    private(set) var currentFolder: URL?
    /// Why the microphone is not being recorded, in a sentence meant for the
    /// person in the meeting; nil when it is. The caller surfaces this, so a
    /// half-recording is never something you find out about afterwards.
    private(set) var micFailure: String?

    /// How long a silent tap is given before it is called a failure. Long enough
    /// for a Bluetooth headset to bring its link up, short enough to still be
    /// the first thing you see when you look at the menu.
    private static let firstSoundDeadline: TimeInterval = 6

    /// Live tap for the system-audio (remote participants) track, used by
    /// realtime notes. Set before `start()`.
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called when the microphone turns out not to be recording. Separate from
    /// reading `micFailure` after `start()`, because the worst case is only
    /// known seconds later: a tap that opened and then delivered nothing.
    var onMicFailure: ((String) -> Void)?

    func start() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = Self.recordingsRoot.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        currentFolder = folder
        micFailure = nil

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
        let track = MicTrack(url: folder.appendingPathComponent("microphone.caf"))
        micTrack = track
        do {
            try MicCapture.shared.addConsumer(micConsumerID) { buffer, _ in
                SilenceWatch.shared.heard(buffer)
                track.write(buffer)
            }
        } catch {
            micFailure = "Recording without a microphone — only the other side of the call is being captured. \(error.localizedDescription)"
            NSLog("Griasa: microphone unavailable, recording system audio only: %@",
                  error.localizedDescription)
            return
        }

        // A tap that opens and then delivers nothing is the failure that costs a
        // meeting: measured on this machine, `start()` returned successfully and
        // no buffer ever arrived. Nothing throws, nothing is logged, and the
        // recording is half a conversation. So the first sound is waited for, and
        // its absence is reported like any other failure.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstSoundDeadline))
            // Compared against this session's own folder, not merely "something
            // is recording": a session started in the meantime is a different
            // microphone with its own answer.
            guard let self, self.currentFolder == folder, self.micFailure == nil,
                  !track.heardAnything else { return }
            let message = "The microphone is open but no sound has arrived from it — only the other side of the call is being recorded. Check the input device in System Settings → Sound."
            self.micFailure = message
            self.onMicFailure?(message)
            NSLog("Griasa: microphone opened but delivered no audio")
        }
    }

    /// Stops the session and returns the folder holding its audio files, so
    /// the caller can run transcription on it.
    func stop() async -> URL? {
        MicCapture.shared.removeConsumer(micConsumerID)
        await systemCapture?.stop()
        systemCapture = nil
        micTrack?.close()
        micTrack = nil
        let folder = currentFolder
        currentFolder = nil
        return folder
    }
}


/// The microphone file, and whatever it takes to keep writing to it.
///
/// Its own object because the format can change underneath a recording. The
/// file's format is fixed by the first buffer, and a device that changes
/// mid-call — a headset moving into call mode halves its rate — then produces
/// buffers the file refuses. That used to end the microphone track silently,
/// part-way through: the writes threw once per buffer into a log nobody reads,
/// and what survived was the first few seconds of somebody's meeting.
///
/// Everything here is called from the audio thread, so it holds its own lock
/// rather than relying on where it is called from.
private final class MicTrack {
    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var received = false

    init(url: URL) { self.url = url }

    /// Whether any audio has arrived at all, for the caller's deadline.
    var heardAnything: Bool { lock.withLock { received } }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            do {
                let file = try openIfNeeded(for: buffer)
                received = true
                let target = file.processingFormat
                if AudioFormatMatch.agree(rate: buffer.format.sampleRate,
                                          channels: buffer.format.channelCount,
                                          otherRate: target.sampleRate,
                                          otherChannels: target.channelCount) {
                    try file.write(from: buffer)
                } else {
                    try writeConverted(buffer, to: file, target: target)
                }
            } catch {
                NSLog("Griasa: failed to write mic audio: %@", error.localizedDescription)
            }
        }
    }

    func close() { lock.withLock { file = nil; converter = nil } }

    private func openIfNeeded(for buffer: AVAudioPCMBuffer) throws -> AVAudioFile {
        if let file { return file }
        let opened = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        file = opened
        return opened
    }

    /// Resamples into the format the file was opened with, so the track stays
    /// one continuous recording rather than stopping at the device change.
    private func writeConverted(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile,
                                target: AVAudioFormat) throws {
        if converter?.inputFormat != buffer.format || converter?.outputFormat != target {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else {
            throw NSError(domain: "Griasa", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "no converter from \(buffer.format) to \(target)"
            ])
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw NSError(domain: "Griasa", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "could not allocate a converted buffer"
            ])
        }
        var handed = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if handed { status.pointee = .noDataNow; return nil }
            handed = true
            status.pointee = .haveData
            return buffer
        }
        if let failure { throw failure }
        guard output.frameLength > 0 else { return }
        try file.write(from: output)
    }
}
