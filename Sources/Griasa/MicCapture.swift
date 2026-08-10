import AVFoundation

/// Single shared microphone tap. Both the dictation engine and the conversation
/// recorder consume buffers from here, so they can run at the same time without
/// fighting over the input device.
final class MicCapture {
    static let shared = MicCapture()

    typealias Consumer = (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let engine = AVAudioEngine()
    private var consumers: [UUID: Consumer] = [:]
    private let lock = NSLock()
    private var tapInstalled = false

    /// The native format of the input device. Only valid once the engine has an input.
    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func addConsumer(_ id: UUID, _ consumer: @escaping Consumer) throws {
        lock.lock()
        consumers[id] = consumer
        let needsStart = !tapInstalled
        lock.unlock()
        if needsStart {
            try startEngine()
        }
    }

    func removeConsumer(_ id: UUID) {
        lock.lock()
        consumers.removeValue(forKey: id)
        let idle = consumers.isEmpty
        lock.unlock()
        if idle {
            stopEngine()
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "Griasa", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No microphone input available (check Microphone permission in System Settings → Privacy & Security)."
            ])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else { return }
            self.lock.lock()
            let sinks = Array(self.consumers.values)
            self.lock.unlock()
            for sink in sinks { sink(buffer, time) }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }
}
