import AVFoundation
import Speech
import AppKit
import CoreGraphics
import EventKit
import UserNotifications

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

/// Every kind of access Griasa asks macOS for, with what it unlocks, where it
/// stands now, and how to ask or where to change it. The Settings list is
/// built from this, so a new kind of access is added in one place.
enum Access: String, CaseIterable, Identifiable {
    case microphone, speech, accessibility, screen, calendar, reminders, notifications, notes, iCloudDrive

    var id: String { rawValue }

    enum Status { case granted, notAsked, denied }

    var name: String {
        switch self {
        case .microphone: return "Microphone"
        case .speech: return "Speech recognition"
        case .accessibility: return "Accessibility"
        case .screen: return "Screen recording"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .notifications: return "Notifications"
        case .notes: return "Automation → Notes"
        case .iCloudDrive: return "iCloud Drive"
        }
    }

    var detail: String {
        switch self {
        case .microphone:
            return "Dictation and your side of meeting recordings. Without it, all text and screen features (OCR, captures, reminders, presets, projects) still work."
        case .speech:
            return "Apple's transcriber, used only as a fallback while local Whisper isn't installed. With Whisper set up, everything works without it."
        case .accessibility:
            return "Global hotkeys, reading your selection, and typing text at the cursor. Without it, every action is still available from the menu bar."
        case .screen:
            return "System audio in meeting recordings, and reading the screen for OCR region / Draft reply. Without it, recordings capture your mic only."
        case .calendar:
            return "Who is on the next call for the Prep brief, today's meetings in the morning brief and the widget, and free slots for the {slot} snippet."
        case .reminders:
            return "“Remind me”, and Settings → iPhone → Reminders, which keeps your dated promises in the list “Griasa”."
        case .notifications:
            return "The morning brief, the brief before a meeting, and notes arriving from the iPhone, as banners. Without it they still open in Griasa."
        case .notes:
            return "Writing the morning brief to the note “Griasa — Today”, when that is switched on in Settings → Meetings."
        case .iCloudDrive:
            return "Reading iCloud Drive → Griasa → Inbox, for notes and recordings from the iPhone (Settings → iPhone)."
        }
    }

    /// The Privacy & Security pane where it is changed.
    var settingsURL: URL? {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .speech: pane = "Privacy_SpeechRecognition"
        case .accessibility: pane = "Privacy_Accessibility"
        case .screen: pane = "Privacy_ScreenCapture"
        case .calendar: pane = "Privacy_Calendars"
        case .reminders: pane = "Privacy_Reminders"
        case .notes: pane = "Privacy_Automation"
        case .notifications: return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        case .iCloudDrive: return URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    /// Where it stands. Off the main thread: asking about Automation can block.
    func status() async -> Status {
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .accessibility:
            return Permissions.accessibilityGranted ? .granted : .denied
        case .screen:
            return Permissions.screenRecordingGranted ? .granted : .denied
        case .calendar, .reminders:
            switch EKEventStore.authorizationStatus(for: self == .calendar ? .event : .reminder) {
            case .fullAccess: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .notifications:
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .notes:
            return await Task.detached { Self.automation("com.apple.Notes", ask: false) }.value
        case .iCloudDrive:
            let drive = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            return (try? FileManager.default.contentsOfDirectory(atPath: drive.path)) != nil ? .granted : .denied
        }
    }

    /// Shows macOS's own question. For what macOS asks only once, a second
    /// time opens the pane where the answer is changed instead.
    func request() async {
        if await status() == .denied, self != .iCloudDrive {
            if let url = settingsURL { NSWorkspace.shared.open(url) }
            return
        }
        switch self {
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech: SFSpeechRecognizer.requestAuthorization { _ in }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screen: CGRequestScreenCaptureAccess()
        case .calendar: _ = try? await RemindersService.store.requestFullAccessToEvents()
        case .reminders: _ = await RemindersService.requestAccess()
        case .notifications: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        case .notes:
            // Notes must be running to be asked about.
            if let notes = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: notes, configuration: configuration)
            }
            _ = await Task.detached { Self.automation("com.apple.Notes", ask: true) }.value
        case .iCloudDrive:
            if let url = settingsURL { NSWorkspace.shared.open(url) }
        }
    }

    /// Whether Griasa may send Apple Events to the app with this bundle id.
    /// An app that is not running cannot be asked about and reads as not asked.
    private nonisolated static func automation(_ bundleID: String, ask: Bool) -> Status {
        var target = AEAddressDesc()
        let result: OSStatus = bundleID.withCString { pointer in
            guard AECreateDesc(typeApplicationBundleID, pointer, bundleID.utf8.count, &target) == noErr else { return -1 }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
        }
        switch result {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notAsked
        }
    }
}
