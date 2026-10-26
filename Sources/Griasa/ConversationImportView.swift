import SwiftUI
import AppKit

/// "Import Chats…": a Telegram Desktop export → chosen chats → the pipeline.
struct ConversationImportView: View {
    let onClose: () -> Void

    private enum Step { case choose, loading, pickMe, list, done(String) }

    @State private var step = Step.choose
    @State private var error: String?
    @State private var exportMe: String?
    @State private var chats: [ExportedChat] = []
    @State private var ticked: Set<String> = []
    @State private var counts: [String: Int] = [:]
    @State private var byDays = true
    @State private var amount = ConversationImportRules.defaultDays
    @State private var meID = ""
    @State private var importing = false

    private let source = "telegram"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Telegram chats").font(.headline)
            switch step {
            case .choose: choose
            case .loading: ProgressView("Reading the export…")
            case .pickMe: pickMe
            case .list: list
            case .done(let text):
                Text(text).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done", action: onClose).keyboardShortcut(.defaultAction) }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 520, height: 460, alignment: .topLeading)
    }

    // MARK: Steps

    private var choose: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("In Telegram Desktop: Settings → Advanced → Export Telegram data (or a chat's menu → Export chat history), format JSON. Then choose the export folder or its result.json.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose export…", action: chooseFile)
                Spacer()
                Button("Cancel", action: onClose)
            }
        }
    }

    private var pickMe: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which participant are you?").font(.subheadline.weight(.semibold))
            Text("This export does not say. Griasa uses the answer to tell your promises from other people's, and remembers it for Telegram.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $meID) {
                ForEach(ConversationImportRules.participants(of: chats), id: \.id) { p in
                    Text(p.name.isEmpty ? p.id : p.name).tag(p.id)
                }
            }
            .labelsHidden().pickerStyle(.radioGroup)
            Spacer()
            HStack {
                Button("Cancel", action: onClose)
                Spacer()
                Button("Continue") {
                    UserDefaults.standard.set(meID, forKey: ConversationImportRules.meKey(source: source))
                    step = .list
                }
                .disabled(meID.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Take")
                Picker("", selection: $byDays) {
                    Text("the last N days").tag(true)
                    Text("the last N messages").tag(false)
                }
                .labelsHidden().fixedSize()
                TextField("", value: $amount, format: .number).frame(width: 60)
                Spacer()
            }
            .onChange(of: byDays) { _, days in
                amount = days ? ConversationImportRules.defaultDays : ConversationImportRules.defaultMessages
                recount()
            }
            .onChange(of: amount) { _, _ in recount() }

            List(chats, id: \.ref.sourceChatID) { chat in
                let key = ConversationImportRules.key(chat.ref)
                Toggle(isOn: Binding(get: { ticked.contains(key) },
                                     set: { if $0 { ticked.insert(key) } else { ticked.remove(key) } })) {
                    HStack {
                        Text(chat.ref.title.isEmpty ? "Untitled chat" : chat.ref.title).lineLimit(1)
                        Spacer()
                        Text("\(counts[key] ?? 0) of \(chat.messageCount)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let last = chat.lastMessage {
                            Text(last.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(chat.messageCount == 0)
            }
            HStack {
                Button("Cancel", action: onClose)
                Spacer()
                Button(importing ? "Importing…" : "Import \(ticked.count) chat\(ticked.count == 1 ? "" : "s")",
                       action: runImport)
                    .disabled(ticked.isEmpty || importing).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Work

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Telegram export folder or its result.json"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            url.appendPathComponent("result.json")
        }
        error = nil
        step = .loading
        let file = url
        Task {
            do {
                let read = try await Task.detached { try TelegramExport.read(file) }.value
                loaded(me: read.me?.id, chats: read.chats)
            } catch {
                self.error = error.localizedDescription
                step = .choose
            }
        }
    }

    private func loaded(me: String?, chats: [ExportedChat]) {
        guard !chats.isEmpty else {
            error = "There are no chats with messages in this export."
            step = .choose
            return
        }
        self.chats = chats
        exportMe = me
        let known = Set(((try? ConversationStore.live().chatList()) ?? []).map { ConversationImportRules.key($0.ref) })
        ticked = Set(chats.filter { ConversationImportRules.preTicked($0, known: known) }
            .map { ConversationImportRules.key($0.ref) })
        recount()
        let people = ConversationImportRules.participants(of: chats)
        meID = people.first?.id ?? ""
        let remembered = UserDefaults.standard.string(forKey: ConversationImportRules.meKey(source: source))
        switch ConversationImportRules.resolveMe(exportMe: me, remembered: remembered, participants: people.map(\.id)) {
        case .known(let id): meID = id; step = .list
        case .ask: step = .pickMe
        }
    }

    private func recount() {
        let window = ConversationImportRules.window(days: byDays, amount: amount)
        let now = Date()
        counts = Dictionary(uniqueKeysWithValues: chats.map {
            (ConversationImportRules.key($0.ref), ConversationImportRules.keptCount($0, window: window, now: now))
        })
    }

    private func runImport() {
        importing = true
        error = nil
        let window = ConversationImportRules.window(days: byDays, amount: amount)
        let now = Date()
        Task { @MainActor in
            do {
                let store = try ConversationStore.live()
                var days: [(Int64, String)] = []
                var messages = 0, taken = 0
                for chat in chats where ticked.contains(ConversationImportRules.key(chat.ref)) {
                    let part = TelegramExport.limited(chat, to: window, now: now)
                    for batch in ConversationImportRules.batches(part, myID: meID.isEmpty ? nil : meID, source: source) {
                        switch ConversationIngest.validate([batch]) {
                        case .failure(let why): throw why
                        case .success(let ok):
                            for b in ok { days += try ConversationIngest.accept(into: store, batch: b, timeZone: .current,
                                                                  retentionDays: ManagedPolicy.live.conversationRetentionDays) }
                        }
                        messages += batch.messages.count
                        await Task.yield()
                    }
                    taken += 1
                }
                ConversationProcessor.shared.enqueue(days)
                let unique = Set(days.map { "\($0.0)|\($0.1)" }).count
                step = .done(unique == 0
                    ? "Nothing new: those messages were already imported."
                    : "Imported \(messages) messages from \(taken) chat\(taken == 1 ? "" : "s"). \(unique) day\(unique == 1 ? "" : "s") will be read in the background; summaries and promises appear in the tab as they finish.")
            } catch {
                self.error = error.localizedDescription
            }
            importing = false
        }
    }
}
