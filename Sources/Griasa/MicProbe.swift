import AVFoundation
import Foundation

/// `Griasa --mic-probe [seconds]` — opens the microphone exactly the way a
/// recording does and says what actually arrived.
///
/// Written because "the microphone is not recording" was true for weeks without
/// anything saying so: the tap opened against a format the hardware had left
/// behind, and delivered nothing. The numbers below are the ones that told the
/// story — the device's own rate, the rate the audio engine believes in, and
/// whether a single buffer ever arrived.
enum MicProbe {
    static func run(seconds: Double) async -> Never {
        let id = UUID()
        let started = Date()
        let counted = OSAllocatedUnfairLockBox()

        print("microphone probe — \(Int(seconds))s")
        do {
            try MicCapture.shared.addConsumer(id) { buffer, _ in
                counted.add(buffer)
            }
        } catch {
            print("  the microphone could not be opened:")
            print("  \(error.localizedDescription)")
            print("\n  RESULT: nothing would have been recorded from you.")
            exit(1)
        }
        try? await Task.sleep(for: .seconds(seconds))
        MicCapture.shared.removeConsumer(id)

        let (buffers, frames, peak, format) = counted.read()
        let elapsed = Date().timeIntervalSince(started)
        print("  buffers: \(buffers) in \(String(format: "%.1f", elapsed))s")
        print("  format:  \(format ?? "none arrived")")
        if let format, buffers > 0 {
            _ = format
            print("  audio:   \(String(format: "%.2f", Double(frames) / max(elapsed, 0.001) / 1000)) k frames/s")
            print("  peak:    \(String(format: "%.4f", peak)) (\(peak > 0.001 ? "sound is arriving" : "silent — the tap is open but the device is giving nothing"))")
        }
        print("\n  RESULT: \(buffers > 0 && peak > 0.001 ? "the microphone is recording." : buffers > 0 ? "the microphone is open but silent." : "NOTHING arrived — a recording would have your side missing.")")
        exit(buffers > 0 && peak > 0.001 ? 0 : 1)
    }
}

/// Counters written from the audio thread and read once at the end.
final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var frames: Int64 = 0
    private var peak: Float = 0
    private var format: String?

    func add(_ buffer: AVAudioPCMBuffer) {
        var localPeak: Float = 0
        if let data = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    localPeak = max(localPeak, abs(data[channel][frame]))
                }
            }
        }
        lock.withLock {
            buffers += 1
            frames += Int64(buffer.frameLength)
            peak = max(peak, localPeak)
            if format == nil {
                format = "\(buffer.format.channelCount) ch, \(Int(buffer.format.sampleRate)) Hz"
            }
        }
    }

    func read() -> (Int, Int64, Float, String?) {
        lock.withLock { (buffers, frames, peak, format) }
    }
}
