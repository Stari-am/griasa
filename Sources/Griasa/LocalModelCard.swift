import SwiftUI

@MainActor
enum LocalModelCard {
    /// Probes first: the state from launch may be stale — Ollama started
    /// since, or a model arrived — and a card offering a download the Mac no
    /// longer needs is worse than no card. Concurrent refreshes are shared.
    static func showIfNeeded() {
        // Cloud users never see it (also checked in `shouldOfferCard`, after the probe).
        guard LLMConfig.current().provider == .custom else { return }
        Task { @MainActor in
            await LocalModelSetup.shared.refresh()
            guard LocalModelSetup.shared.shouldOfferCard else { return }
            HubController.shared.open(.localModel, activate: false)
        }
    }
}

/// The one question local AI asks. No model or engine names: the people this
/// is for should not need to know what either is.
struct LocalModelCardView: View {
    @ObservedObject private var setup = LocalModelSetup.shared

    @AppStorage("customBaseURL") private var customBaseURL = ""
    @AppStorage("customFastModel") private var customFast = ""
    @AppStorage("customSmartModel") private var customSmart = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if LocalRefreshGate.isHandConfigured(typedBaseURL: customBaseURL, typedModelNames: [customFast, customSmart]) {
                // Defensive: a typed server is theirs, so there is nothing to offer.
                Text("Griasa uses your own server — nothing to set up.")
                Button("Close") { HubController.shared.close(.localModel) }
            } else {
            switch setup.state {
            case .needsConsent(let entry, _):
                Text("Summaries and promises on this Mac").font(.title2.bold())
                Text("Griasa needs to download its AI model once — \(gb(entry.pinned.size)), about \(minutes(entry.pinned.size)) minutes. Nothing leaves this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if ManagedPolicy.live.anyCloudAllowed {
                        Button("Use a cloud provider instead…") {
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        }.buttonStyle(.link)
                    }
                    Spacer()
                    Button("Not now") { setup.decline(); HubController.shared.close(.localModel) }
                    Button("Download") { setup.consent() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            case .noSpace(let needed):
                Text("Not enough space for local AI").font(.title2.bold())
                Text("The AI model needs about \(needed) GB free. Free up space, and Griasa will offer it again in a few days.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    // Same rule as the download question: only where the organization allows the cloud.
                    if ManagedPolicy.live.anyCloudAllowed {
                        Button("Use a cloud provider instead…") {
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        }.buttonStyle(.link)
                    }
                    Spacer()
                    Button("Close") { setup.decline(); HubController.shared.close(.localModel) }
                }
            case .installing, .downloading:
                Text("Downloading the AI model…").font(.title2.bold())
                if case .downloading(let p) = setup.state { ProgressView(value: Double(p), total: 100) }
                else { ProgressView() }
                if setup.waitingForNetwork {
                    Text("Waiting for the network — the download continues from where it stopped.")
                        .foregroundStyle(.secondary)
                }
                Text("You can close this — it keeps going, and meetings recorded meanwhile get their summaries when it is done.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .ready:
                Text("Local AI is ready").font(.title2.bold())
                Button("Done") { HubController.shared.close(.localModel) }.keyboardShortcut(.defaultAction)
            case .failed(let message):
                Text("The download did not finish").font(.title2.bold())
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await setup.refresh(); setup.consent() } }
            case .checking:
                ProgressView()
            }
            }
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
        // Opened from the menu before anything has probed this Mac, the card
        // would sit on a spinner forever; refresh is a no-op while busy.
        .task { if case .checking = setup.state { await setup.refresh() } }
    }

    private func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
    /// At ~10 MB/s, rounded to 5 minutes; honest enough for a promise.
    private func minutes(_ bytes: Int64) -> Int { max(5, Int((Double(bytes) / 10e6 / 60 / 5).rounded(.up)) * 5) }
}
