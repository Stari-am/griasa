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
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
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
