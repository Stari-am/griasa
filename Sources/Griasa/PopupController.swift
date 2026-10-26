import SwiftUI
import AppKit

/// Result view for selection actions (summary / grammar fix) — lives in the
/// hub window's "Result" tab.
@MainActor
final class PopupController: ObservableObject {
    static let shared = PopupController()

    @Published var title = ""
    @Published var isLoading = false
    @Published var resultText = ""
    /// Whether to offer the "Replace Selection" button (edits, not summaries).
    @Published var canReplace = false

    /// The app that had focus before the popup, so "Replace selection" can
    /// paste back into it.
    private var sourceApp: NSRunningApplication?

    /// A promise found in captured text, offered under the result until the
    /// person tracks it or moves on. Nothing is added without the button.
    @Published var promiseOffer: CapturedPromise?
    @Published var promiseTracked = false
    private var promiseSource = ""

    func offer(_ promise: CapturedPromise, from origin: ReminderSource?) {
        promiseOffer = promise
        promiseTracked = false
        promiseSource = origin.map { $0.appName + ($0.detail.map { " — \($0)" } ?? "") } ?? "Captured text"
    }

    func trackPromise() {
        guard let promise = promiseOffer else { return }
        CommitmentStore.shared.add(Commitment(
            text: promise.task, owner: promise.owner, isMine: promise.isMine,
            dueHint: promise.dueHint, dueDate: promise.dueDate,
            sourceTitle: promiseSource, sourceQuote: promise.quote))
        promiseTracked = true
    }

    private func clearOffer() {
        promiseOffer = nil
        promiseTracked = false
    }

    func showLoading(title: String, canReplace: Bool, sourceApp: NSRunningApplication?) {
        self.title = title
        self.canReplace = canReplace
        self.sourceApp = sourceApp
        clearOffer()
        isLoading = true
        resultText = ""
        present()
    }

    func showResult(_ text: String) {
        isLoading = false
        resultText = text
    }

    func showMessage(title: String, message: String) {
        clearOffer()
        self.title = title
        self.canReplace = false
        isLoading = false
        resultText = message
        present()
    }

    func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
    }

    /// Grammar mode: put the corrected text back over the (still active)
    /// selection in the original app.
    func replaceSelection() {
        guard !resultText.isEmpty else { return }
        let text = resultText
        let app = sourceApp
        close()
        Task { @MainActor in
            app?.activate()
            try? await Task.sleep(nanoseconds: 350_000_000)
            TextInserter.insert(text)
        }
    }

    func close() {
        HubController.shared.close(.result)
    }

    private func present() {
        HubController.shared.open(.result)
    }
}

struct PopupView: View {
    @ObservedObject var controller: PopupController

    private var attributedResult: AttributedString {
        (try? AttributedString(
            markdown: controller.resultText,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(controller.resultText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(controller.title)
                .font(.title3.bold())

            Divider()

            if controller.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(attributedResult)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
            }

            if let promise = controller.promiseOffer, !controller.isLoading {
                PromiseOfferRow(controller: controller, promise: promise)
            }

            Divider()

            HStack {
                Button("Copy") { controller.copyResult() }
                    .disabled(controller.isLoading || controller.resultText.isEmpty)
                Button("Copy Rich Text") { Exporter.copyRichText(markdown: controller.resultText) }
                    .disabled(controller.isLoading || controller.resultText.isEmpty)
                Menu("Export…") {
                    ForEach(Exporter.Format.allCases) { format in
                        Button(format.rawValue) {
                            Exporter.save(title: controller.title, markdown: controller.resultText, format: format)
                        }
                    }
                }
                .frame(width: 100)
                .disabled(controller.isLoading || controller.resultText.isEmpty)
                if controller.canReplace {
                    Button("Replace Selection") { controller.replaceSelection() }
                        .disabled(controller.isLoading || controller.resultText.isEmpty)
                }
                Spacer()
                Button("Close") { controller.close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 320)
    }
}

/// "Looks like a promise" under a Remind me result, with mine/theirs to fix
/// before tracking it.
private struct PromiseOfferRow: View {
    @ObservedObject var controller: PopupController
    let promise: CapturedPromise

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Looks like a promise").font(.caption.bold()).foregroundStyle(.secondary)
            Text("\(promise.owner) — \(promise.task)" + (promise.dueHint.map { " · \($0)" } ?? ""))
            HStack {
                Picker("", selection: Binding(
                    get: { controller.promiseOffer?.isMine ?? false },
                    set: { mine in
                        controller.promiseOffer?.isMine = mine
                        if mine { controller.promiseOffer?.owner = ParticipantRoster.shared.myName.isEmpty
                            ? "You" : ParticipantRoster.shared.myName }
                    })) {
                    Text("Mine").tag(true)
                    Text("Theirs").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .disabled(controller.promiseTracked)
                Spacer()
                if controller.promiseTracked {
                    Text("Added to Commitments").foregroundStyle(.secondary)
                } else {
                    Button("Track as promise") { controller.trackPromise() }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
