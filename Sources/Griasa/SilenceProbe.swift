import AVFoundation
import AppKit
import os

/// `Griasa --silence-probe` answers one question with a measurement: when the
/// app plays its own alert sound, does that sound come back in through either
/// recorded input — and at what level?
///
/// It exists because the silence question was dismissing itself a second after
/// appearing, and the two candidate paths (ScreenCaptureKit, which is
/// configured to exclude this process, and the microphone hearing the speakers)
/// cannot be told apart by reading the code.
enum SilenceProbe {
    private final class Peaks {
        private let state = OSAllocatedUnfairLock(initialState: [String: Float]())
        func note(_ source: String, _ level: Float) {
            state.withLock { $0[source] = max($0[source] ?? AudioLevel.floor, level) }
        }
        func takeAndReset() -> [String: Float] {
            state.withLock { current in
                let snapshot = current
                current = [:]
                return snapshot
            }
        }
    }

    static func run() async -> Never {
        let peaks = Peaks()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("griasa-silence-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var systemStarted = false
        let system = SystemAudioCapture(outputURL: folder.appendingPathComponent("system.caf"))
        system.onPCMBuffer = { buffer in
            peaks.note("system audio", SilenceWatch.level(of: buffer))
        }
        do {
            try await system.start()
            systemStarted = true
        } catch {
            print("system audio capture failed: \(error.localizedDescription)")
        }

        var micStarted = false
        let micID = UUID()
        do {
            try MicCapture.shared.addConsumer(micID) { buffer, _ in
                peaks.note("microphone", SilenceWatch.level(of: buffer))
            }
            micStarted = true
        } catch {
            print("microphone unavailable: \(error.localizedDescription)")
        }

        print("threshold for \"somebody is talking\": \(AudioLevel.speechThreshold) dBFS")
        print("system audio capture: \(systemStarted ? "running (excludesCurrentProcessAudio = true)" : "NOT running")")
        print("microphone: \(micStarted ? "running" : "NOT running")")

        // Let the streams settle, then take a quiet baseline to compare against.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        _ = peaks.takeAndReset()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        report("baseline, no beep", peaks.takeAndReset())

        NSSound.beep()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        report("after NSSound.beep()", peaks.takeAndReset())

        // Phase 2: the same beep, but judged by the watch's real state and the
        // real clock. This is the part that says whether the question survives.
        print("\n--- the question, against a real beep ---")
        system.onPCMBuffer = { SilenceWatch.shared.heard($0) }
        if micStarted {
            MicCapture.shared.removeConsumer(micID)
            try? MicCapture.shared.addConsumer(micID) { buffer, _ in
                SilenceWatch.shared.heard(buffer)
            }
        }
        let clock = SilenceClock(silenceAfter: 60, replyWithin: 60)
        var dismissed = false
        let askingFrom = Date()
        NSSound.beep()
        for step in 1...16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let seen = SilenceWatch.shared.snapshot()
            let decision = clock.decide(silentFor: seen.silentFor,
                                        soundRun: seen.soundRun,
                                        asking: Date().timeIntervalSince(askingFrom))
            if decision == .keepWatching { dismissed = true }
            if step % 4 == 0 || decision == .keepWatching {
                print(String(format: "  t+%.1fs  silent for %5.2fs, run %5.2fs → %@",
                             Double(step) * 0.5, seen.silentFor, seen.soundRun,
                             "\(decision)"))
            }
        }
        print(dismissed
              ? "  FAIL: the question would have been dismissed by its own beep"
              : "  PASS: the question stayed up for the whole 8s after the beep")

        if micStarted { MicCapture.shared.removeConsumer(micID) }
        if systemStarted { await system.stop() }
        try? FileManager.default.removeItem(at: folder)
        await MainActor.run { probeClicks() }
        exit(dismissed ? 1 : 0)
    }

    private static let clicked = OSAllocatedUnfairLock(initialState: false)

    /// Phase 3: is the panel actually clickable? The report was "I cannot click
    /// any button", which the one-second lifetime explains on its own — but a
    /// borderless non-activating panel is also the classic place for a click to
    /// be swallowed, so this presses the button for real.
    ///
    /// It sweeps the button row rather than trusting one computed point, and
    /// clicks each point twice: if only the second click works, the first one is
    /// being spent making the window key, which is a different defect from the
    /// button never receiving anything.
    @MainActor private static func probeClicks() {
        // Nothing has started the AppKit event loop in probe mode — the app
        // exits before GriasaApp.main() runs. Without this, posted clicks reach
        // the window server (the cursor moves) and are never dequeued or
        // dispatched to the panel, so every button looks broken. That produced
        // one false "the button is broken" verdict before it was caught.
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()

        SilencePrompt.shared.show(silentMinutes: 1,
                                  onKeep: { clicked.withLock { $0 = true } },
                                  onStop: {})
        guard let panel = SilencePrompt.shared.probePanel,
              // The flip to CoreGraphics coordinates is against the PRIMARY
              // display, whose top-left is the global origin — not against
              // NSScreen.main, which is merely the one with the key window.
              let primary = NSScreen.screens.first else {
            print("\n--- clicking ---\n  no panel to click")
            return
        }
        let frame = panel.frame
        print("\n--- clicking ---")
        print("  panel \(Int(frame.width))x\(Int(frame.height)) at "
            + "\(Int(frame.minX)),\(Int(frame.minY))  visible: \(panel.isVisible)  "
            + "canBecomeKey: \(panel.canBecomeKey)  ignoresMouse: \(panel.ignoresMouseEvents)")

        // A synthetic click needs Accessibility, and this is a different bundle
        // id from the shipping app. Without this line a missing permission would
        // read as "the button is broken".
        print("  posting process is Accessibility-trusted: \(AXIsProcessTrusted())")
        let before = NSEvent.mouseLocation
        // Aimed at the panel itself, not at the middle of the screen: a probe
        // has no business clicking on whatever the user happens to have open.
        click(at: CGPoint(x: primary.frame.maxX - 2, y: primary.frame.maxY - 2))
        pump(0.2)
        let after = NSEvent.mouseLocation
        let cursorMoved = abs(after.x - before.x) > 1 || abs(after.y - before.y) > 1
        print("  synthetic events are being delivered (cursor moved): \(cursorMoved)")
        guard cursorMoved else {
            print("  INCONCLUSIVE: the clicks never left this process — grant Accessibility "
                + "to Griasa Dev and run again")
            SilencePrompt.shared.hide()
            return
        }

        var report: [String] = []
        for dx in stride(from: 20.0, through: 120.0, by: 20.0) {
            for dy in stride(from: 14.0, through: 44.0, by: 10.0) {
                let point = NSPoint(x: frame.maxX - dx, y: frame.minY + dy)
                let flipped = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
                for attempt in 1...2 {
                    clicked.withLock { $0 = false }
                    click(at: flipped)
                    pump(0.25)
                    if clicked.withLock({ $0 }) {
                        report.append("reached the button at inset \(Int(dx)),\(Int(dy)) "
                                    + "on click \(attempt)")
                        break
                    }
                }
                if !report.isEmpty { break }
            }
            if !report.isEmpty { break }
        }

        if let hit = report.first {
            print("  PASS: \(hit)")
        } else {
            print("  FAIL: 2 clicks at each of 24 points across the button row reached nothing")
        }

        // "Keep recording" is marked as the default action. A borderless panel
        // can never be the key window, so whether Return actually reaches it is
        // a question worth answering rather than assuming.
        clicked.withLock { $0 = false }
        for down in [true, false] {
            if let key = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down) {
                key.post(tap: .cghidEventTap)
            }
            pump(0.1)
        }
        pump(0.4)
        print(clicked.withLock { $0 }
              ? "  Return also presses the default button"
              : "  Return does NOT press the default button (the panel is never key)")
        SilencePrompt.shared.hide()
    }

    /// Dequeues and dispatches AppKit events for a while — what NSApp.run
    /// would be doing if this were the real app.
    @MainActor private static func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let event = NSApp.nextEvent(matching: .any,
                                              until: Date().addingTimeInterval(0.01),
                                              inMode: .default, dequeue: true) else { continue }
            NSApp.sendEvent(event)
        }
    }

    @MainActor private static func click(at point: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(40_000)
        }
    }

    private static func report(_ label: String, _ peaks: [String: Float]) {
        print("\n\(label):")
        if peaks.isEmpty { print("  (no buffers arrived)") }
        for source in peaks.keys.sorted() {
            let level = peaks[source] ?? AudioLevel.floor
            let verdict = level >= AudioLevel.speechThreshold
                ? "COUNTS AS SPEECH — re-arms the silence clock"
                : "below threshold — ignored"
            print(String(format: "  %-13s loudest buffer %7.1f dBFS   %@",
                         (source as NSString).utf8String!, level, verdict))
        }
    }
}
