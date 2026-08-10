import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Captures everything the Mac is playing (calls, videos, other apps) via
/// ScreenCaptureKit's audio stream and writes it to an audio file. Requires
/// Screen Recording permission.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let outputURL: URL
    private var stream: SCStream?
    private var file: AVAudioFile?
    private let sampleQueue = DispatchQueue(label: "griasa.systemaudio")

    /// Optional live tap (deep-copied buffers) for realtime notes.
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Griasa", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "No display found for system audio capture."
            ])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // We only want audio; keep the mandatory video leg as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        sampleQueue.sync { file = nil } // flushes and closes
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = sampleBuffer.asPCMBuffer else { return }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: outputURL, settings: pcm.format.settings)
            }
            try file?.write(from: pcm)
        } catch {
            NSLog("Griasa: failed to write system audio: %@", error.localizedDescription)
        }
        if let onPCMBuffer, let copy = pcm.deepCopy() { onPCMBuffer(copy) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Griasa: system audio stream stopped: %@", error.localizedDescription)
    }
}

extension AVAudioPCMBuffer {
    /// A standalone copy — the buffer from a CMSampleBuffer is backed by that
    /// sample buffer's memory, so it must be copied before handing to another
    /// consumer that reads it asynchronously.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        out.frameLength = frameLength
        let channels = Int(format.channelCount)
        if let src = floatChannelData, let dst = out.floatChannelData {
            for ch in 0..<channels {
                memcpy(dst[ch], src[ch], Int(frameLength) * MemoryLayout<Float>.size)
            }
        } else if let src = int16ChannelData, let dst = out.int16ChannelData {
            for ch in 0..<channels {
                memcpy(dst[ch], src[ch], Int(frameLength) * MemoryLayout<Int16>.size)
            }
        } else {
            return nil
        }
        return out
    }
}

extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate,
                                             channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}
