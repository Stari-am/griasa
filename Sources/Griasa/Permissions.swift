import AVFoundation
import Speech
import AppKit
import CoreGraphics
import EventKit

enum Permissions {
    /// Asks for everything Griasa needs on first launch:
    /// microphone, speech recognition, accessibility, and screen recording
    /// (the latter is what gates system-audio capture).
    static func requestAll() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        SFSpeechRecognizer.requestAuthorization { _ in }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        requestCalendarIfNeeded()
    }

    /// The pre-meeting brief is on by default and its watcher deliberately
    /// never prompts — a background timer must not throw a permission dialog at
    /// somebody mid-sentence. Which meant nothing ever asked: calendar access
    /// was only ever requested by the ";slots" snippet and the "Prep next
    /// meeting" menu item, so the automatic brief stayed dead until the user
    /// happened to trigger one of those. An app that has never asked does not
    /// even appear under Privacy & Security → Calendars, so it could not be
    /// granted by hand either.
    static func requestCalendarIfNeeded() {
        guard MeetingPrepWatcher.isEnabled,
              EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        // Held for the duration of the call: EKEventStore must outlive the
        // request, and a temporary would be released before it returns.
        let store = EKEventStore()
        Task { _ = try? await store.requestFullAccessToEvents() }
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    static var calendarGranted: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    static var speechGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }
    static var remindersGranted: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }
}
