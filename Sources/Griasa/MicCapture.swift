import AVFoundation
import os

/// Single shared microphone tap. Both the dictation engine and the conversation
/// recorder consume buffers from here, so they can run at the same time without
/// fighting over the input device.
///
/// Rewritten after a crash report: SIGSEGV with the program counter at zero, on
/// `com.apple.audio.IOThread.client`. A null program counter is not a null
/// object being read — it is CoreAudio calling a function pointer that no longer
/// exists, which for a tap means the block was freed while a message to it was
/// already in flight.
///
/// Three things in the old version made that reachable, and all three are fixed
/// below: the engine was mutated from whichever thread happened to call in
/// (AVAudioEngine is not thread-safe), the tap was removed *before* the engine
/// was stopped, and the flag saying whether a tap existed was read under a lock
/// but written outside one.
final class MicCapture {
    static let shared = MicCapture()

    typealias Consumer = (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let engine = AVAudioEngine()

    /// Every engine mutation is serialised here: installTap, removeTap, start
    /// and stop happen on one thread, in order, never overlapping each other.
    private let queue = DispatchQueue(label: "griasa.miccapture")

    /// Read by the audio thread on every buffer; written twice per recording.
    ///
    /// An unfair lock rather than NSLock: uncontended it never enters the
    /// kernel, and it guards a single dictionary assignment. The textbook answer
    /// for a real-time thread is a lock-free swap of an immutable snapshot; this
    /// is the version that fits in one file and cannot be got subtly wrong. The
    /// callback copies the dictionary out — copy-on-write makes that a retain,
    /// not an allocation — and calls consumers with nothing held.
    private let consumers = OSAllocatedUnfairLock(initialState: [UUID: Consumer]())

    /// Confined to `queue`. Previously this was read under the consumer lock and
    /// written outside it, so a start and a stop could interleave and leave the
    /// engine stopped with a live consumer, or believing a tap was installed
    /// when `engine.start()` had thrown.
    private var running = false

    private init() {
        // Sleep and wake, AirPods connecting, plugging into a dock: the input
        // device changes, the engine stops itself, and the format the tap was
        // installed with stops matching. Untreated, the recording goes silent
        // with no error and the next teardown removes a tap the engine no
        // longer owns. The crash arrived at 04:37, which is exactly when this
        // happens without anybody touching the machine.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.restartAfterConfigurationChange() }
        }
    }

    /// The native format of the input device. Only valid once the engine has an
    /// input.
    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func addConsumer(_ id: UUID, _ consumer: @escaping Consumer) throws {
        consumers.withLock { $0[id] = consumer }
        do {
            try queue.sync { try startIfNeeded() }
        } catch {
            // A consumer that is registered against an engine that failed to
            // start would keep the next stop from ever running.
            consumers.withLock { _ = $0.removeValue(forKey: id) }
            throw error
        }
    }

    func removeConsumer(_ id: UUID) {
        consumers.withLock { _ = $0.removeValue(forKey: id) }
        queue.sync { stopIfIdle() }
    }

    // MARK: - Queue-confined

    private func startIfNeeded() throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "Griasa", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No microphone input available (check Microphone permission in System Settings → Privacy & Security)."
            ])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else { return }
            let sinks = self.consumers.withLock { $0 }
            for sink in sinks.values { sink(buffer, time) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    /// Emptiness is re-checked here rather than trusted from the caller: a
    /// consumer can be added between a removal and this running.
    private func stopIfIdle() {
        guard running, consumers.withLock({ $0.isEmpty }) else { return }
        teardown()
    }

    private func restartAfterConfigurationChange() {
        guard running else { return }
        teardown()
        guard !consumers.withLock({ $0.isEmpty }) else { return }
        do {
            try startIfNeeded()
        } catch {
            NSLog("Griasa: microphone did not come back after an audio device change: %@",
                  error.localizedDescription)
        }
    }

    /// Stop, then remove — never the other way round. Removing a tap from a
    /// running engine races the message already on its way to the block, and
    /// that race is the crash this file was rewritten for. `stop()` returns with
    /// the IO thread halted, after which the block has no caller left.
    private func teardown() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        running = false
    }
}
