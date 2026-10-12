import SwiftUI
import AppKit

/// The first thing a new install shows: a small card under Griasa's menu-bar
/// icon saying "it's up here", three things to try, and the way to the full
/// permissions guide. Griasa has no window and no Dock icon, so without this
/// the first launch looks like nothing happened at all.
///
/// Also shown whenever Griasa is opened again while it is already running —
/// from Launchpad, Spotlight or Finder — because that is exactly what somebody
/// does when they cannot find it.
@MainActor
final class FirstRunCoachmark {
    static let shared = FirstRunCoachmark()

    private var panel: NSPanel?

    /// Waits a moment first: the status item is placed after launch, and a card
    /// positioned before that would point at where it is not.
    func show() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            present()
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func present() {
        dismiss()
        let item = Self.statusItemFrame()
        let screen = NSScreen.screens.first { item.map($0.frame.intersects) ?? false }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        // Measure the card with an arrow, then lay it out for real: whether
        // there is an arrow is only known after placement.
        let size = NSHostingView(rootView: card(arrowX: 0, iconHidden: false)).fittingSize
        let placement = FirstRunPlacement.place(item: item, screen: screen.visibleFrame,
                                                notch: Self.notch(on: screen), card: size)
        let view = NSHostingView(rootView: card(arrowX: placement.arrowX,
                                                iconHidden: placement.iconHidden))
        let final = view.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: final),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = view
        // Without an arrow the card's height differs; keep its top edge where
        // the placement put it.
        panel.setFrameOrigin(NSPoint(x: placement.origin.x,
                                     y: placement.origin.y + size.height - final.height))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func card(arrowX: CGFloat?, iconHidden: Bool) -> FirstRunCard {
        FirstRunCard(arrowX: arrowX, iconHidden: iconHidden,
                     hotkey: AppState.shared.hotkeyChoice.displayName,
                     onGuide: { [weak self] in
                         self?.dismiss()
                         HubController.shared.open(.welcome)
                     },
                     onDone: { [weak self] in self?.dismiss() })
    }

    /// The menu-bar icon's frame. MenuBarExtra gives no handle to its status
    /// item, but the item is drawn in a window of its own whose class name says
    /// what it is.
    private static func statusItemFrame() -> CGRect? {
        NSApp.windows.first { $0.className.contains("NSStatusBarWindow") }?.frame
    }

    /// The camera housing on a notched built-in display, in screen coordinates.
    private static func notch(on screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let top = screen.safeAreaInsets.top
        return CGRect(x: left.maxX, y: screen.frame.maxY - top,
                      width: right.minX - left.maxX, height: top)
    }
}

private struct FirstRunCard: View {
    let arrowX: CGFloat?
    let iconHidden: Bool
    let hotkey: String
    let onGuide: () -> Void
    let onDone: () -> Void

    private let width: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            if let arrowX {
                Arrow()
                    .fill(.regularMaterial)
                    .frame(width: 20, height: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: arrowX - 10)
            }
            content
                .padding(16)
                .frame(width: width, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
        .frame(width: width)
        .padding(.bottom, 2)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(iconHidden ? "Griasa is running — its icon is hidden" : "Griasa lives up here")
                        .font(.headline)
                    Text(iconHidden
                         ? "The menu bar is full, so macOS put the icon behind the camera. Hold ⌘ and drag other icons out of the bar to make room."
                         : "No window, no Dock icon — click the bubble in the menu bar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                row("record.circle", "**Record a meeting** — Start Recording in that menu.")
                row("keyboard", "**Dictate anywhere** — hold \(hotkey) and speak.")
                row("checklist", "**Promises** from every call land in Commitments.")
            }
            HStack {
                Spacer()
                Button("Got it", action: onDone)
                Button("Set up permissions…", action: onGuide)
                    .buttonStyle(.borderedProminent)
            }
            Text("Lost it later? Open Griasa again and this card comes back.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func row(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The pointer at the top of the card.
private struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
