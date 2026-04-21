import SwiftUI

struct ContentView: View {
    @State private var chats: [ChatSummary] = []
    @State private var todos: [ConversationTodo] = []
    @State private var selectedChatID: ChatSummary.ID?
    @State private var selectedCategory: RelationshipCategory = .unknown
    @State private var conversationSort: ConversationSort = .latest
    @State private var openAIAPIKey = ""
    @State private var isCategorizing = false
    @State private var classificationRationale: String?
    @State private var settingsMessage: String?
    @State private var errorMessage: String?

    private var selectedChat: ChatSummary? {
        chats.first { $0.id == selectedChatID }
    }

    private var chatNamesByGuid: [String: String] {
        Dictionary(uniqueKeysWithValues: chats.map { ($0.guid, $0.displayName) })
    }

    private var hasOpenAIAPIKey: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        TabView {
            categoriesView
                .tabItem {
                    Label("Categories", systemImage: "person.2")
                }

            statisticsView
                .tabItem {
                    Label("Statistics", systemImage: "chart.bar")
                }

            todosView
                .tabItem {
                    Label("Todos", systemImage: "checklist")
                }

            settingsView
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            await loadData()
        }
    }

    private var categoriesView: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Category", selection: $selectedCategory) {
                    ForEach(RelationshipCategory.allCases) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                ConversationSortPicker(selection: $conversationSort)
                .padding(.horizontal)

                List(filteredChats, selection: $selectedChatID) { chat in
                    ChatRow(chat: chat)
                }
                .navigationTitle("Conversations")
            }
        } detail: {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding()
            } else if let selectedChat {
                ConversationDetailView(
                    chat: selectedChat,
                    todos: todos.filter { $0.chatGuid == selectedChat.guid },
                    onCategoryChange: { category in
                        setCategory(category, for: selectedChat)
                    },
                    onAddTodo: { title in
                        addTodo(title: title, chatGuid: selectedChat.guid)
                    },
                    onToggleTodo: toggleTodo,
                    onDeleteTodo: deleteTodo,
                    hasOpenAIAPIKey: hasOpenAIAPIKey,
                    isCategorizing: isCategorizing,
                    classificationRationale: classificationRationale,
                    onCategorizeWithLLM: {
                        Task {
                            await categorizeWithLLM(selectedChat)
                        }
                    }
                )
            } else {
                ContentUnavailableView("Select a conversation", systemImage: "message")
            }
        }
    }

    private var statisticsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConversationSortPicker(selection: $conversationSort)
                .padding([.horizontal, .top])

            List(sortedChats(chats)) { chat in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(chat.displayName)
                            .font(.headline)
                        Spacer()
                        Text(chat.relationshipCategory.displayName)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 16) {
                        StatLabel(title: "Messages", value: "\(chat.messageCount)")
                        StatLabel(title: "Sent", value: "\(chat.sentCount)")
                        StatLabel(title: "Received", value: "\(chat.receivedCount)")
                        StatLabel(title: "Monthly", value: chat.messagesPerMonth.formatted(.number.precision(.fractionLength(1))))

                        if let lastInteractionDate = chat.lastInteractionDate {
                            StatLabel(title: "Last", value: Self.dateFormatter.string(from: lastInteractionDate))
                        }
                    }
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Statistics")
    }

    private var todosView: some View {
        TodoListView(
            title: "All Todos",
            todos: todos,
            chatNamesByGuid: chatNamesByGuid,
            onAddTodo: { title in
                addTodo(title: title, chatGuid: nil)
            },
            onToggleTodo: toggleTodo,
            onDeleteTodo: deleteTodo
        )
        .padding()
    }

    private var settingsView: some View {
        Form {
            Section("OpenAI") {
                SecureField("API key", text: $openAIAPIKey)

                HStack {
                    Button("Save Key", action: saveOpenAIAPIKey)

                    Button("Clear Key") {
                        openAIAPIKey = ""
                        saveOpenAIAPIKey()
                    }
                }

                Text("Used globally for LLM categorization. Conversation text is only sent when you click Categorize with LLM.")
                    .foregroundStyle(.secondary)

                if let settingsMessage {
                    Text(settingsMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var filteredChats: [ChatSummary] {
        sortedChats(chats.filter { $0.relationshipCategory == selectedCategory })
    }

    private func loadData() async {
        do {
            let appDatabase = try AppDatabase()
            let categories = try appDatabase.fetchCategories()
            openAIAPIKey = KeychainStore.openAIAPIKey() ?? ""
            let contactResolver = await ContactResolver.load()
            let chatDatabase = try ChatDatabase()
            chats = try chatDatabase.fetchChats(
                categories: categories,
                contactResolver: contactResolver
            )
            todos = try appDatabase.fetchTodos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func sortedChats(_ chats: [ChatSummary]) -> [ChatSummary] {
        switch conversationSort {
        case .latest:
            return chats.sorted {
                ($0.lastInteractionDate ?? .distantPast) > ($1.lastInteractionDate ?? .distantPast)
            }
        case .earliest:
            return chats.sorted {
                ($0.lastInteractionDate ?? .distantFuture) < ($1.lastInteractionDate ?? .distantFuture)
            }
        case .name:
            return chats.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .mostMessages:
            return chats.sorted {
                $0.messageCount > $1.messageCount
            }
        }
    }

    private func setCategory(_ category: RelationshipCategory, for chat: ChatSummary) {
        do {
            try setCategory(category, for: chat, shouldSwitchCategory: true)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func setCategory(_ category: RelationshipCategory, for chat: ChatSummary, shouldSwitchCategory: Bool) throws {
        let appDatabase = try AppDatabase()
        try appDatabase.setCategory(category, for: chat.guid)

        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index].relationshipCategory = category
        }

        if shouldSwitchCategory {
            selectedCategory = category
        }
    }

    private func saveOpenAIAPIKey() {
        do {
            try KeychainStore.setOpenAIAPIKey(openAIAPIKey)
            settingsMessage = hasOpenAIAPIKey ? "OpenAI API key saved." : "OpenAI API key cleared."
            errorMessage = nil
        } catch {
            settingsMessage = nil
            errorMessage = String(describing: error)
        }
    }

    private func categorizeWithLLM(_ chat: ChatSummary) async {
        isCategorizing = true
        classificationRationale = nil

        do {
            guard hasOpenAIAPIKey else {
                throw OpenAIClient.ClientError.missingAPIKey
            }

            let chatDatabase = try ChatDatabase()
            let messages = try chatDatabase.fetchMessageSamples(for: chat.id)
            let client = OpenAIClient(apiKey: openAIAPIKey)
            let classification = try await client.classifyConversation(chat: chat, messages: messages)

            try setCategory(classification.category, for: chat, shouldSwitchCategory: true)
            classificationRationale = classification.rationale
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }

        isCategorizing = false
    }

    private func addTodo(title: String, chatGuid: String?) {
        do {
            let appDatabase = try AppDatabase()
            try appDatabase.addTodo(title: title, chatGuid: chatGuid)
            todos = try appDatabase.fetchTodos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func toggleTodo(_ todo: ConversationTodo) {
        do {
            let appDatabase = try AppDatabase()
            try appDatabase.setTodoCompleted(!todo.isCompleted, id: todo.id)
            todos = try appDatabase.fetchTodos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func deleteTodo(_ todo: ConversationTodo) {
        do {
            let appDatabase = try AppDatabase()
            try appDatabase.deleteTodo(id: todo.id)
            todos = try appDatabase.fetchTodos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct ConversationSortPicker: View {
    @Binding var selection: ConversationSort

    var body: some View {
        Picker("Sort", selection: $selection) {
            ForEach(ConversationSort.allCases) { sort in
                Text(sort.displayName).tag(sort)
            }
        }
        .pickerStyle(.segmented)
    }
}

private struct ChatRow: View {
    let chat: ChatSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chat.displayName)
                .font(.headline)

            HStack(spacing: 8) {
                if let serviceName = chat.serviceName {
                    Text(serviceName)
                }

                Text("\(chat.participantCount) participant\(chat.participantCount == 1 ? "" : "s")")
                Text("\(chat.messageCount) messages")

                if chat.resolvedContactCount == 0 && !chat.participantHandles.isEmpty {
                    Text("Unmatched")
                }

                if let lastInteractionDate = chat.lastInteractionDate {
                    Text(Self.dateFormatter.string(from: lastInteractionDate))
                }

                if chat.isArchived {
                    Text("Archived")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct ConversationDetailView: View {
    let chat: ChatSummary
    let todos: [ConversationTodo]
    let onCategoryChange: (RelationshipCategory) -> Void
    let onAddTodo: (String) -> Void
    let onToggleTodo: (ConversationTodo) -> Void
    let onDeleteTodo: (ConversationTodo) -> Void
    let hasOpenAIAPIKey: Bool
    let isCategorizing: Bool
    let classificationRationale: String?
    let onCategorizeWithLLM: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(chat.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("\(chat.messageCount) messages · \(chat.sentCount) sent · \(chat.receivedCount) received")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Category", selection: Binding(
                    get: { chat.relationshipCategory },
                    set: onCategoryChange
                )) {
                    ForEach(RelationshipCategory.allCases) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                .frame(width: 220)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("LLM Categorization")
                    .font(.headline)

                Text("Sends a small recent message sample for this conversation to OpenAI and applies one category.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        onCategorizeWithLLM()
                    } label: {
                        if isCategorizing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Categorize with LLM")
                        }
                    }
                    .disabled(isCategorizing || !hasOpenAIAPIKey)

                    if let classificationRationale, !classificationRationale.isEmpty {
                        Text(classificationRationale)
                            .foregroundStyle(.secondary)
                    }
                }

                if !hasOpenAIAPIKey {
                    Text("Add your OpenAI API key in Settings before categorizing.")
                        .foregroundStyle(.secondary)
                }
            }

            TodoListView(
                title: "Conversation Todos",
                todos: todos,
                chatNamesByGuid: [:],
                onAddTodo: onAddTodo,
                onToggleTodo: onToggleTodo,
                onDeleteTodo: onDeleteTodo
            )

            Spacer()
        }
        .padding()
    }
}

private struct TodoListView: View {
    let title: String
    let todos: [ConversationTodo]
    let chatNamesByGuid: [String: String]
    let onAddTodo: (String) -> Void
    let onToggleTodo: (ConversationTodo) -> Void
    let onDeleteTodo: (ConversationTodo) -> Void

    @State private var newTodoTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            HStack {
                TextField("New todo", text: $newTodoTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTodo)

                Button("Add", action: addTodo)
                    .keyboardShortcut(.return, modifiers: .command)
            }

            if todos.isEmpty {
                ContentUnavailableView("No todos", systemImage: "checkmark.circle")
            } else {
                List(todos) { todo in
                    HStack(alignment: .top) {
                        Button {
                            onToggleTodo(todo)
                        } label: {
                            Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(todo.title)
                                .strikethrough(todo.isCompleted)
                                .foregroundStyle(todo.isCompleted ? .secondary : .primary)

                            if let chatGuid = todo.chatGuid,
                               let chatName = chatNamesByGuid[chatGuid] {
                                Text(chatName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button("Delete") {
                            onDeleteTodo(todo)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func addTodo() {
        onAddTodo(newTodoTitle)
        newTodoTitle = ""
    }
}

private struct StatLabel: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}

#Preview {
    ContentView()
}
