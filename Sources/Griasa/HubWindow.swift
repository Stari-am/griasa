import SwiftUI
import AppKit

/// One activity hosted in the shared hub window.
enum HubTab: String, Identifiable {
    case result
    case recording
    case reminder
    case participants
    case askProject
    case history
    case welcome
    case commitments
    case people
    case prep
    case newDocument
    case typingDiagnostics

    var id: String { rawValue }

    var fallbackTitle: String {
        switch self {
        case .result: return "✨ Result"
        case .recording: return "🎙 Recording"
        case .reminder: return "⏰ Reminder"
        case .participants: return "👥 Participants"
        case .askProject: return "🗂 Ask Project"
        case .history: return "🕘 History"
        case .welcome: return "👋 Welcome"
        case .commitments: return "✅ Commitments"
        case .people: return "📇 People"
        case .prep: return "📋 Prep"
        case .newDocument: return "📄 New Document"
        case .typingDiagnostics: return "⌨️ Typing Test"
        }
    }
}

/// The single floating panel every Griasa activity shares. Each activity
/// (action result, live recording, reminder composer, participants question,
/// Ask Project) opens as a tab here instead of spawning its own window, so a
/// busy moment — recording + a reminder + a preset result — is one window,
/// not three.
@MainActor
final class HubController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = HubController()

    @Published var openTabs: [HubTab] = []
    @Published var selected: HubTab?

    private var panel: NSPanel?

    /// The hub's window, for `--shoot` documentation screenshots.
    var window: NSWindow? { panel }

    /// Resizes the hub, keeping it centered — `--size 1100x760` for a screenshot
    /// that doesn't look cramped.
    func resize(to size: NSSize) {
        guard let panel else { return }
        var frame = panel.frame
        frame.origin.x -= (size.width - frame.width) / 2
        frame.origin.y -= (size.height - frame.height) / 2
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    /// Opens (or fronts) the hub with `tab` selected. `activate: false` shows
    /// the panel without making it key — background events (the pre-meeting
    /// brief) must never yank keyboard focus from what the user is typing.
    func open(_ tab: HubTab, activate: Bool = true) {
        if !openTabs.contains(tab) { openTabs.append(tab) }
        selected = tab
        present(activate: activate)
    }

    /// Removes a tab; hides the panel when the last one goes.
    func close(_ tab: HubTab) {
        openTabs.removeAll { $0 == tab }
        if selected == tab { selected = openTabs.last }
        if openTabs.isEmpty { panel?.orderOut(nil) }
    }

    /// The ✕ on a tab — routed through the owning flow so pending work is
    /// canceled properly (orphan clip cleanup, unblocking the meeting
    /// pipeline), not just hidden.
    func requestClose(_ tab: HubTab) {
        switch tab {
        case .result: PopupController.shared.close()
        case .recording: close(.recording)
        case .reminder: ReminderComposer.shared.cancel()
        case .participants: ParticipantsPrompt.shared.skip()
        case .askProject: close(.askProject)
        case .history: close(.history)
        case .welcome: close(.welcome)
        case .commitments: close(.commitments)
        case .people: close(.people)
        case .prep: close(.prep)
        case .newDocument: close(.newDocument)
        case .typingDiagnostics: close(.typingDiagnostics)
        }
    }

    private func present(activate: Bool = true) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            panel.title = "Griasa"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: HubView(hub: self))
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(
                    x: frame.midX - panel.frame.width / 2,
                    y: frame.midY + frame.height * 0.08))
            }
            self.panel = panel
        }
        if activate {
            panel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel?.orderFrontRegardless()
        }
    }

    /// Red close button on the panel: resolve flows that must not be left
    /// hanging (a pending participants question would stall the meeting
    /// pipeline forever), then let the panel hide. Other tabs survive and
    /// come back the next time the hub opens.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if openTabs.contains(.participants) { ParticipantsPrompt.shared.skip() }
        if openTabs.contains(.reminder) { ReminderComposer.shared.cancel() }
        return true
    }
}

struct HubView: View {
    @ObservedObject var hub: HubController
    @ObservedObject private var popup = PopupController.shared
    @ObservedObject private var state = AppState.shared

    private func title(for tab: HubTab) -> String {
        if tab == .result, !popup.title.isEmpty { return popup.title }
        return tab.fallbackTitle
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(hub.openTabs) { tab in
                    HStack(spacing: 5) {
                        Text(title(for: tab))
                            .lineLimit(1)
                        Button {
                            hub.requestClose(tab)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(hub.selected == tab ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { hub.selected = tab }
                }
                Spacer()
                if state.isRecording {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text("REC").font(.caption2.bold()).foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            // Hidden tabs stay mounted (their state survives switching) but
            // disabled, so their keyboard shortcuts (Esc/Enter) can't fire.
            ZStack {
                ForEach(hub.openTabs) { tab in
                    content(for: tab)
                        .opacity(hub.selected == tab ? 1 : 0)
                        .allowsHitTesting(hub.selected == tab)
                        .disabled(hub.selected != tab)
                }
                if hub.openTabs.isEmpty {
                    Text("Nothing open")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 440)
    }

    @ViewBuilder
    private func content(for tab: HubTab) -> some View {
        switch tab {
        case .result:
            PopupView(controller: popup)
        case .recording:
            LiveNotesView().environmentObject(LiveNotesController.shared)
        case .reminder:
            ReminderComposeView()
        case .participants:
            WhoIsWhoView(roster: ParticipantRoster.shared,
                         onDone: { ParticipantsPrompt.shared.finish($0) })
        case .askProject:
            AskProjectView()
        case .history:
            HistoryView().environmentObject(HistoryStore.shared)
        case .welcome:
            OnboardingView()
        case .commitments:
            CommitmentsView()
        case .people:
            PeopleView()
        case .prep:
            PrepView()
        case .newDocument:
            NewDocumentView()
        case .typingDiagnostics:
            TypingDiagnosticsView()
        }
    }
}
