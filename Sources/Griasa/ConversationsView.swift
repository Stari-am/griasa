import SwiftUI
import AppKit

/// Where something else in the app asks the Conversations tab to show a chat,
/// or to start an import.
@MainActor
final class ConversationsNavigator: ObservableObject {
    static let shared = ConversationsNavigator()

    struct Target: Equatable {
        var chat: Int64
        var day: String?
        var nonce = UUID()
    }

    @Published var target: Target?
    @Published var importing = false

    /// Opens the tab at a chat, and at a day of it if one is given.
    func show(chat: Int64, day: String?) {
        guard ManagedPolicy.live.conversationsEnabled else { return }
        target = Target(chat: chat, day: day)
        HubController.shared.open(.conversations)
    }

    func startImport() {
        guard ManagedPolicy.live.conversationsEnabled else { return }
        importing = true
        HubController.shared.open(.conversations)
    }
}

/// What the tab reads from the store. Errors become a line of text, never
/// message content.
@MainActor
final class ConversationsModel: ObservableObject {
    typealias Day = (day: String, state: DayState, summary: String?, count: Int)

    @Published var chats: [(id: Int64, ref: ChatRef, last: Date?)] = []
    @Published var selected: Int64?
    @Published var days: [Day] = []
    @Published var authors: [(id: String?, name: String)] = []
    @Published var results: [(chat: Int64, day: String, messageID: String)] = []
    @Published var reviewCount = 0
    @Published var error: String?

    private(set) var store: ConversationStore?

    init() {
        do { store = try ConversationStore.live() }
        catch { self.error = error.localizedDescription }
        reload()
    }

    func reload() {
        guard let store else { return }
        do {
            chats = try store.chatList()
            reviewCount = try store.reviewCount()
            if let selected, !chats.contains(where: { $0.id == selected }) { self.selected = nil }
            if selected == nil { selected = chats.first?.id }
            try loadSelected()
        } catch { self.error = error.localizedDescription }
    }

    func select(_ chat: Int64?) {
        selected = chat
        results = []
        do { try loadSelected() } catch { self.error = error.localizedDescription }
    }

    private func loadSelected() throws {
        guard let store, let selected else { days = []; authors = []; return }
        days = try store.days(chat: selected)
        authors = try store.authors(chat: selected)
    }

    func search(_ query: String) {
        guard let store else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = trimmed.isEmpty ? [] : ((try? store.search(trimmed, limit: 50)) ?? [])
    }

    func messages(chat: Int64, day: String) -> [StoredMessage] {
        (try? store?.messages(chat: chat, day: day)) ?? []
    }

    func delete(_ chat: Int64) {
        do {
            try store?.deleteChat(chat)
            // The promises taken from it stay: they are the person's list now.
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func title(of chat: Int64) -> String {
        chats.first { $0.id == chat }?.ref.title ?? ""
    }
}

/// The "💬 Conversations" hub tab.
struct ConversationsView: View {
    @StateObject private var model = ConversationsModel()
    @ObservedObject private var nav = ConversationsNavigator.shared
    @ObservedObject private var processor = ConversationProcessor.shared
    @ObservedObject private var commitments = CommitmentStore.shared
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var scrollTo: String?
    @State private var confirmDelete = false

    var body: some View {
        if !ManagedPolicy.live.conversationsEnabled {
            EmptyStateView(icon: "lock", title: "Conversations are turned off",
                           message: "Your organization has turned off reading chats in Griasa.")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            toolbar
            if let progress = processor.progress { progressBar(progress) }
            Divider()
            if model.chats.isEmpty {
                EmptyStateView(icon: "bubble.left.and.bubble.right", title: "No chats yet",
                               message: "Import a Telegram export and Griasa reads each day: a short summary, and the promises people made in it. Nothing leaves your Mac except what the AI provider you chose sees.")
            } else {
                HStack(spacing: 0) {
                    chatList.frame(width: 210)
                    Divider()
                    detail
                }
            }
        }
        .sheet(isPresented: $nav.importing) {
            ConversationImportView(onClose: { nav.importing = false; model.reload() })
        }
        .onAppear { processor.resume(); apply(nav.target) }
        .onChange(of: nav.target) { _, new in apply(new) }
        .onChange(of: processor.progress?.done) { _, _ in model.reload() }
        .alert("Delete this chat?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = model.selected { model.delete(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its messages, summaries and the search index are erased from this Mac. Promises already taken from it stay on your list.")
        }
    }

    private func apply(_ target: ConversationsNavigator.Target?) {
        guard let target else { return }
        model.reload()
        model.select(target.chat)
        query = ""
        if let day = target.day { expanded.insert(day); scrollTo = day }
        nav.target = nil
    }

    // MARK: Pieces

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search messages", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { model.search(query) }
                    .onChange(of: query) { _, new in if new.isEmpty { model.results = [] } }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            Button("Import Chats…") { nav.importing = true }
        }
        .padding(10)
    }

    private func progressBar(_ p: (done: Int, total: Int)) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
            Text("Reading day \(min(p.done + 1, p.total)) of \(p.total)")
                .font(.caption).foregroundStyle(.secondary)
            Button("Cancel") { processor.cancel() }.controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private var chatList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.chats, id: \.id) { chat in
                    let open = openCount(chat.id)
                    Button { model.select(chat.id); query = "" } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(chat.ref.title.isEmpty ? "Untitled chat" : chat.ref.title).lineLimit(1)
                                if let last = chat.last {
                                    Text(last.formatted(.relative(presentation: .named)))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if open > 0 {
                                Text("\(open)")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                                    .help("\(open) open promise\(open == 1 ? "" : "s")")
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(model.selected == chat.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                reviewSection
            }
            .padding(8)
        }
    }

    /// Batches an assistant sent that wait for the person's yes. The count is
    /// real; the list and accept/reject belong to Task 8, which fills
    /// `reviewList` in below.
    private var reviewSection: some View {
        Group {
            if model.reviewCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Divider().padding(.vertical, 4)
                    Label("To review · \(model.reviewCount)", systemImage: "tray")
                        .font(.caption.weight(.semibold))
                    reviewList
                }
                .padding(.horizontal, 8)
            }
        }
    }

    /// Task 8 hook: replace with the pending batches and their Accept / Reject.
    private var reviewList: some View {
        Text("Chats sent by an assistant are waiting here for your yes.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private var detail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if !model.results.isEmpty {
                        searchResults
                    } else if let chat = model.selected {
                        header(chat)
                        whoIsThis(chat)
                        ForEach(model.days, id: \.day) { day in
                            DayBlock(model: model, chat: chat, day: day,
                                     promises: promises(chat: chat, day: day.day),
                                     expanded: binding(day.day))
                                .id(day.day)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: scrollTo) { _, day in
                guard let day else { return }
                // After the days are laid out.
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(day, anchor: .top) } }
                scrollTo = nil
            }
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(model.results.count) message\(model.results.count == 1 ? "" : "s") found")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(model.results.enumerated()), id: \.offset) { _, hit in
                Button {
                    model.select(hit.chat)
                    expanded.insert(hit.day); scrollTo = hit.day
                } label: {
                    Text("\(model.title(of: hit.chat)) · \(hit.day)")
                        .padding(.vertical, 3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func header(_ chat: Int64) -> some View {
        HStack {
            Text(model.title(of: chat)).font(.headline)
            Spacer()
            Button("Delete chat…", role: .destructive) { confirmDelete = true }
                .controlSize(.small)
        }
    }

    /// Authors the app could not place among the people it knows. Linking one
    /// stores the account id on the person, so it never needs asking again.
    @ViewBuilder
    private func whoIsThis(_ chat: Int64) -> some View {
        let source = model.chats.first { $0.id == chat }?.ref.source ?? ""
        let people = PersonStore.shared.people.map { (name: $0.name, handles: $0.handles) }
        let open = model.authors.compactMap { a -> (id: String, name: String, options: [String])? in
            guard let id = a.id else { return nil }
            switch ChatIdentity.person(forAuthorID: id, name: a.name, source: source, people: people) {
            case .unknown: return (id, a.name, PersonStore.shared.allNames)
            case .ambiguous(let names): return (id, a.name, names)
            default: return nil
            }
        }
        if !open.isEmpty {
            HubCard(icon: "person.fill.questionmark", title: "Who is this?", tint: .orange) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(open, id: \.id) { author in
                        HStack {
                            Text(author.name.isEmpty ? author.id : author.name)
                            Spacer()
                            Menu("Link to…") {
                                ForEach(author.options, id: \.self) { person in
                                    Button(person) {
                                        PersonStore.shared.setHandle(author.id, source: source, for: person)
                                        model.reload()
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
            }
        }
    }

    // MARK: Data

    private func openCount(_ chat: Int64) -> Int {
        commitments.commitments.filter { $0.sourceChatID == String(chat) && !$0.done }.count
    }

    private func promises(chat: Int64, day: String) -> [Commitment] {
        commitments.commitments.filter { $0.sourceChatID == String(chat) && $0.sourceChatDay == day }
    }

    private func binding(_ day: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(day) },
                set: { if $0 { expanded.insert(day) } else { expanded.remove(day) } })
    }
}

/// One day of a chat: its summary and promises, and the messages on request.
private struct DayBlock: View {
    @ObservedObject var model: ConversationsModel
    let chat: Int64
    let day: ConversationsModel.Day
    let promises: [Commitment]
    @Binding var expanded: Bool

    @State private var messages: [StoredMessage] = []

    var body: some View {
        HubCard(icon: "calendar", title: day.day, tint: .blue, content: {
            VStack(alignment: .leading, spacing: 6) {
                if let summary = day.summary, !summary.isEmpty {
                    Text(summary).fixedSize(horizontal: false, vertical: true)
                } else if day.state == .pending || day.state == .processing {
                    Text("Waiting to be read").foregroundStyle(.secondary)
                } else if day.state == .failed {
                    Text("Could not be read; it will be tried again.").foregroundStyle(.secondary)
                }
                ForEach(promises) { item in
                    Label(item.isMine ? item.text : "\(item.owner): \(item.text)",
                          systemImage: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.callout)
                        .foregroundStyle(item.done ? .secondary : .primary)
                }
                DisclosureGroup("\(day.count) message\(day.count == 1 ? "" : "s")", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(messages, id: \.sourceMessageID) { m in
                            (Text(m.isMine ? "Me" : m.authorName).bold() + Text("  \(m.text)"))
                                .font(.callout).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }, trailing: {
            if day.state == .failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
        })
        .onChange(of: expanded, initial: true) { _, open in
            if open && messages.isEmpty { messages = model.messages(chat: chat, day: day.day) }
        }
    }
}
