import SwiftUI
import AppKit

/// Standalone window for "Ask Project": pick a project, ask a question, and
/// Claude answers using the project's Markdown entries plus attached source
/// folders as context. Single question → answer, no chat history.
@MainActor
final class AskProjectWindowController {
    static let shared = AskProjectWindowController()

    func show() {
        HubController.shared.open(.askProject)
    }
}

struct AskProjectView: View {
    @ObservedObject private var store = ProjectStore.shared
    @State private var projectID = Project.inboxID
    @State private var question = ""
    @State private var answer = ""
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Project", selection: $projectID) {
                ForEach(store.projects) { project in
                    Text("\(project.emoji) \(project.name)").tag(project.id)
                }
                Text("📥 \(Project.inboxName)").tag(Project.inboxID)
            }
            .frame(maxWidth: 280)

            HStack {
                TextField("Ask about this project…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                Button("Ask", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the project and thinking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(answer.isEmpty && !loading
                     ? "The answer will appear here. Context: this project's history entries plus any source folders attached in Settings → Projects."
                     : answer)
                    .textSelection(.enabled)
                    .foregroundStyle(answer.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                }
                .disabled(answer.isEmpty)
                Button("Copy Rich Text") { Exporter.copyRichText(markdown: answer) }
                    .disabled(answer.isEmpty)
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 500, minHeight: 380)
        .onAppear {
            if let first = store.projects.first { projectID = first.id }
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !loading else { return }
        guard AIFormatter.isConfigured else {
            answer = "Configure an AI provider in Settings → AI & Actions to use this feature."
            return
        }
        let folderName = store.displayName(for: projectID)
        let sources = store.project(projectID)?.sourceFolders ?? []
        loading = true
        answer = ""
        Task {
            let context = await Task.detached(priority: .userInitiated) {
                ProjectContext.build(projectFolderName: folderName, sourceFolders: sources)
            }.value
            let result = await ProjectAI.ask(question: q, context: context)
            answer = result ?? "Request failed — check your network connection and API key."
            loading = false
            if let result {
                HistoryStore.shared.add(kind: .action, title: "Ask: \(folderName)",
                                        text: result, projectID: projectID)
            }
        }
    }
}
