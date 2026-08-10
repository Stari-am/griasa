import SwiftUI
import AppKit

/// The "📄 New Document" hub tab: pick a template, talk (or paste) a brief,
/// get a filled-in draft.
struct NewDocumentView: View {
    @ObservedObject private var store = TemplateStore.shared

    @State private var selectedID: UUID?
    @State private var brief = ""
    @State private var generating = false
    @State private var result: String?
    @State private var errorText: String?
    @State private var copied = false
    @State private var saved = false

    private var selected: DocTemplate? {
        store.templates.first { $0.id == selectedID } ?? store.templates.first
    }

    var body: some View {
        if let result {
            resultView(result)
        } else {
            composeView
        }
    }

    // MARK: - Compose

    private var composeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Template")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            templatePicker

            Text("Brief")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $brief)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if brief.isEmpty {
                        Text("Describe the idea in your own words — or hold your dictation key and just talk. The more context, the fewer TBDs.")
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 120)

            HStack {
                if !AIFormatter.isConfigured {
                    Text("Needs an AI provider —")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                } else if generating {
                    ProgressView().controlSize(.small)
                    Text("Writing your \(selected?.name ?? "document")…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button {
                    generate()
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(generating || !AIFormatter.isConfigured
                          || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    private var templatePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.templates) { template in
                    Button {
                        selectedID = template.id
                    } label: {
                        VStack(spacing: 4) {
                            Text(template.emoji).font(.title2)
                            Text(template.name).font(.caption)
                        }
                        .frame(width: 92, height: 58)
                        .background(selected?.id == template.id
                                    ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                    : AnyShapeStyle(.quaternary.opacity(0.5)),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selected?.id == template.id ? Color.accentColor : .clear,
                                          lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func generate() {
        guard let template = selected else { return }
        generating = true
        errorText = nil
        Task { @MainActor in
            defer { generating = false }
            do {
                let text = try await DocGenerator.generate(template: template, brief: brief)
                withAnimation(.snappy) { result = text }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: - Result

    private func resultView(_ text: String) -> some View {
        VStack(spacing: 0) {
            TextEditor(text: Binding(get: { result ?? "" }, set: { result = $0 }))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)

            Divider()

            HStack {
                Button {
                    result = nil  // brief is kept — iterate cheaply
                } label: {
                    Label("New draft", systemImage: "chevron.left")
                }
                Spacer()
                Text("\(text.split(whereSeparator: \.isWhitespace).count) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    flash($copied)
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    let title = "\(selected?.name ?? "Document"): \(firstHeading(of: text))"
                    HistoryStore.shared.add(kind: .document, title: title, text: text)
                    flash($saved)
                } label: {
                    Label(saved ? "Saved" : "Save to History",
                          systemImage: saved ? "checkmark" : "tray.and.arrow.down")
                }
                .help("Lands in History and gets filed into a project automatically")
            }
            .padding(10)
            .background(.bar)
        }
    }

    private func firstHeading(of text: String) -> String {
        for line in text.split(separator: "\n") where line.hasPrefix("#") {
            return line.drop(while: { $0 == "#" || $0 == " " })
                .trimmingCharacters(in: .whitespaces)
        }
        return "Untitled"
    }

    private func flash(_ flag: Binding<Bool>) {
        withAnimation(.snappy) { flag.wrappedValue = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { flag.wrappedValue = false }
        }
    }
}
