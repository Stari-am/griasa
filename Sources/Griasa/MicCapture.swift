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

    /// Rebuilt at every start, deliberately — see `startIfNeeded`.
    private var engine = AVAudioEngine()

    /// The configuration-change registration for the current engine. Held so it
    /// can be taken off the old one: a notification about an engine that has
    /// been replaced would restart a capture that is already running on another.
    private var configurationObserver: NSObjectProtocol?

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

    private init() { observeConfigurationChanges() }

    /// Sleep and wake, AirPods connecting, plugging into a dock: the input
    /// device changes and the engine stops itself. Untreated, the recording goes
    /// silent with no error and the next teardown removes a tap the engine no
    /// longer owns.
    private func observeConfigurationChanges() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.restartAfterConfigurationChange() }
        }
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

        // A new engine every time, and this is the whole fix.
        //
        // An `AVAudioEngine` caches its input node's format and does not let go
        // of it. Keeping one for the life of the app means that after any input
        // device change — AirPods connecting is the everyday one — the node
        // still describes the device that was there at launch. `installTap` with
        // no format takes the node's idea, so the tap is built for a device that
        // is no longer attached, and **no audio arrives at all**.
        //
        // Measured on this machine, both shapes of the same fault: with the node
        // at 48 kHz against hardware at 24 kHz, `start()` threw -10868; in a
        // second attempt it returned successfully and delivered zero buffers for
        // three seconds. A fresh engine built at the moment of use reads the
        // device that is actually there, and records. Building one costs
        // microseconds and happens once per recording or dictation.
        engine = AVAudioEngine()
        observeConfigurationChanges()
        let input = engine.inputNode

        let hardware = input.inputFormat(forBus: 0)
        guard AudioFormatMatch.usable(rate: hardware.sampleRate,
                                      channels: hardware.channelCount) else {
            throw NSError(domain: "Griasa", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No microphone input available (check Microphone permission in System Settings → Privacy & Security)."
            ])
        }

        // With a fresh engine these two agree. They are compared anyway, because
        // when they disagree the tap records silence and says nothing — and a
        // meeting recorded with one side missing is only discovered afterwards,
        // when there is nothing left to do about it. Refusing is worse than
        // recording and better than pretending.
        let node = input.outputFormat(forBus: 0)
        guard AudioFormatMatch.agree(rate: hardware.sampleRate, channels: hardware.channelCount,
                                     otherRate: node.sampleRate, otherChannels: node.channelCount) else {
            throw NSError(domain: "Griasa", code: 2, userInfo: [
                NSLocalizedDescriptionKey: """
                The microphone changed while Griasa was not listening and the audio engine \
                still describes the old one (hardware \(Int(hardware.sampleRate)) Hz, \
                engine \(Int(node.sampleRate)) Hz). Nothing would be recorded from it.
                """
            ])
        }

        // No format passed, deliberately: nil means "whatever this bus uses", so
        // there is nothing to disagree with. Passing the node's cached format
        // crashed the app twice in a week — `installTap` raises an NSException
        // for a mismatch, and an NSException from a C++ library cannot be caught
        // in Swift, so `try` around it is worthless. Nothing downstream is
        // affected: every consumer takes its format from `buffer.format`.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, time in
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
