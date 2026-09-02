import AVFoundation
import AppKit
import SwiftUI
import os

/// Watches both recorded inputs and asks whether to carry on when neither has
/// carried speech for a while.
///
/// This exists because a session ran from 19:00 to 05:48 and wrote 8.6 GB —
/// macOS flagged the process for exceeding its disk-write limit. Nothing in the
/// app had any opinion about a recording that nobody was speaking into.
///
/// The question is a small floating window rather than a system notification,
/// for two reasons: a notification needs a permission this app does not
/// otherwise ask for, and one that gets swiped away takes the decision with it,
/// while this feature has to keep a countdown running until somebody answers or
/// the time runs out.
@MainActor
final class SilenceWatch {
    nonisolated static let shared = SilenceWatch()

    /// Nonisolated so the singleton can be built without hopping to the main
    /// actor: `heard` is called from two audio threads and must not be the
    /// thing that first constructs this.
    nonisolated private init() {}

    /// When sound last arrived, and when the stretch it belongs to began. The
    /// second date is what makes a beep distinguishable from a conversation.
    private struct Heard {
        var last: Date
        var runStarted: Date
        /// Length of the most recent unbroken stretch of sound.
        var run: TimeInterval { last.timeIntervalSince(runStarted) }

        static func now() -> Heard { let now = Date(); return Heard(last: now, runStarted: now) }
        static let never = Heard(last: .distantPast, runStarted: .distantPast)
    }

    /// Written from two audio callbacks and read from a timer on the main
    /// thread. An unfair lock rather than a mutex: two stores, no syscall,
    /// no chance of a priority inversion parking the audio thread.
    private nonisolated let sound = OSAllocatedUnfairLock(initialState: Heard.never)

    private var loop: Task<Void, Never>?
    private var askingSince: Date?

    /// Called from the microphone tap and from the system-audio handler. Cheap
    /// and non-blocking: a sum over the buffer and, at most, one lock.
    nonisolated func heard(_ buffer: AVAudioPCMBuffer) {
        guard Self.level(of: buffer) >= AudioLevel.speechThreshold else { return }
        let now = Date()
        sound.withLock { heard in
            // A gap ends the run, so the length recorded is the length of one
            // continuous noise and not of everything since the recording began.
            if now.timeIntervalSince(heard.last) > SilenceClock.runGap {
                heard.runStarted = now
            }
            heard.last = now
        }
    }

    /// The level `heard` judges, on its own so a diagnostic can measure exactly
    /// what the watch measures rather than an approximation of it.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return AudioLevel.floor }
        if let float = buffer.floatChannelData {
            return AudioLevel.dBFS(float[0], count: frames)
        }
        if let int16 = buffer.int16ChannelData {
            return AudioLevel.dBFS(int16[0], count: frames)
        }
        // An unexpected format must not silently mean "silent forever" and stop
        // somebody's meeting. Treat it as sound.
        return 0
    }

    /// What the watch currently believes, read the way `tick` reads it. Exists
    /// for `--silence-probe`, so a live check measures the real state two audio
    /// threads wrote rather than a re-implementation of it.
    nonisolated func snapshot() -> (silentFor: TimeInterval, soundRun: TimeInterval) {
        let heard = sound.withLock { $0 }
        return (Date().timeIntervalSince(heard.last), heard.run)
    }

    func start() {
        stop()
        guard AppState.shared.silenceWatchEnabled else { return }
        sound.withLock { $0 = .now() }
        askingSince = nil
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self?.tick()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        askingSince = nil
        SilencePrompt.shared.hide()
    }

    private func tick() {
        let state = AppState.shared
        guard state.isRecording, state.silenceWatchEnabled else { return }

        let clock = SilenceClock(silenceAfter: Double(state.silenceWatchMinutes) * 60,
                                 replyWithin: Double(state.silenceReplyMinutes) * 60)
        let heard = sound.withLock { $0 }
        let silentFor = Date().timeIntervalSince(heard.last)
        let asking = askingSince.map { Date().timeIntervalSince($0) }

        switch clock.decide(silentFor: silentFor, soundRun: heard.run, asking: asking) {
        case .keepWatching:
            if askingSince != nil {
                // Speech resumed on its own; take the question away.
                askingSince = nil
                SilencePrompt.shared.hide()
            }
        case .ask:
            if askingSince == nil {
                askingSince = Date()
                SilencePrompt.shared.show(silentMinutes: state.silenceWatchMinutes,
                                          onKeep: { [weak self] in self?.keepRecording() },
                                          onStop: { [weak self] in self?.stopRecording(automatic: false) })
            }
            let remaining = clock.replyWithin - (asking ?? 0)
            SilencePrompt.shared.countdown(seconds: Int(remaining.rounded(.up)))
        case .stopAutomatically:
            stopRecording(automatic: true)
        }
    }

    /// "Keep recording" — the clock restarts from now, so the same stretch of
    /// silence produces the same question again rather than never asking twice.
    private func keepRecording() {
        askingSince = nil
        sound.withLock { $0 = .now() }
        SilencePrompt.shared.hide()
    }

    private func stopRecording(automatic: Bool) {
        let minutes = AppState.shared.silenceWatchMinutes
        stop()
        Task {
            await AppState.shared.stopRecording(
                autoStoppedAfterSilence: automatic ? minutes : nil)
        }
    }
}

/// The question itself. Borderless, non-activating and floating, so it appears
/// over whatever the user is doing without taking keyboard focus — the same
/// rule the snippet HUD and the meeting brief follow.
@MainActor
final class SilencePrompt: ObservableObject {
    static let shared = SilencePrompt()

    @Published fileprivate var silentMinutes = 0
    @Published fileprivate var remaining = 0
    fileprivate var onKeep: () -> Void = {}
    fileprivate var onStop: () -> Void = {}

    private var window: NSPanel?

    /// The panel, for `--silence-probe` to click. Not used by the app itself.
    var probePanel: NSPanel? { window }

    func show(silentMinutes: Int, onKeep: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.silentMinutes = silentMinutes
        self.onKeep = onKeep
        self.onStop = onStop
        let panel = ensureWindow()
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2,
                                         y: screen.maxY - panel.frame.height - 80))
        }
        panel.orderFrontRegardless()
        // The user is by definition not looking at the screen — nobody has
        // spoken for minutes. A sound is the only part of this that can reach
        // someone in another room.
        NSSound.beep()
    }

    func countdown(seconds: Int) {
        remaining = max(0, seconds)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func ensureWindow() -> NSPanel {
        if let window { return window }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 128),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: SilencePromptView(prompt: self))
        window = panel
        return panel
    }
}

private struct SilencePromptView: View {
    @ObservedObject var prompt: SilencePrompt

    private var countdownText: String {
        let minutes = prompt.remaining / 60
        let seconds = prompt.remaining % 60
        return minutes > 0 ? "\(minutes) min \(seconds) s" : "\(seconds) s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Still recording, nobody talking")
                .font(.headline)
            Text("No speech on the microphone or from the Mac for \(prompt.silentMinutes) min. "
                 + "Stopping in \(countdownText).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Stop and save") { prompt.onStop() }
                Spacer()
                // Prominent rather than `.keyboardShortcut(.defaultAction)`:
                // this panel is borderless, so it can never become the key
                // window, and a synthetic Return was measured reaching nothing.
                // Marking it the default action would promise a key that does
                // not work; this gives the same emphasis and promises nothing.
                Button("Keep recording") { prompt.onKeep() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
