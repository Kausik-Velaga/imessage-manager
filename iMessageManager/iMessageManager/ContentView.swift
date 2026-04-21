import SwiftUI

struct ContentView: View {
    @State private var chats: [ChatSummary] = []
    @State private var todos: [ConversationTodo] = []
    @State private var selectedChatID: ChatSummary.ID?
    @State private var selectedCategory: RelationshipCategory = .unknown
    @State private var conversationSort: ConversationSort = .latest
    @State private var selectedChatMessages: [ConversationMessage] = []
    @State private var isLoadingMessages = false
    @State private var messageErrorNotice: ErrorNotice?
    @State private var openAIAPIKey = ""
    @State private var isCategorizing = false
    @State private var classificationRationale: String?
    @State private var settingsMessage: String?
    @State private var errorNotice: ErrorNotice?

    private let messageDisplayLimit = 200

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
            if let selectedChat {
                ConversationDetailView(
                    chat: selectedChat,
                    messages: selectedChatMessages,
                    todos: todos.filter { $0.chatGuid == selectedChat.guid },
                    isLoadingMessages: isLoadingMessages,
                    messageErrorNotice: messageErrorNotice,
                    messageLimit: messageDisplayLimit,
                    onReloadMessages: {
                        loadMessages(for: selectedChat)
                    },
                    errorNotice: errorNotice,
                    onDismissError: {
                        errorNotice = nil
                    },
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
                .task(id: selectedChat.id) {
                    loadMessages(for: selectedChat)
                }
            } else if let errorNotice {
                ErrorNoticeView(notice: errorNotice) {
                    self.errorNotice = nil
                }
                .padding()
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

                if let errorNotice {
                    ErrorNoticeView(notice: errorNotice) {
                        self.errorNotice = nil
                    }
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
            errorNotice = nil
        } catch {
            presentError(error)
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
            errorNotice = nil
        } catch {
            presentError(error)
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
            errorNotice = nil
        } catch {
            settingsMessage = nil
            presentError(error)
        }
    }

    private func categorizeWithLLM(_ chat: ChatSummary) async {
        isCategorizing = true
        classificationRationale = nil
        errorNotice = nil

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
            errorNotice = nil
        } catch {
            presentError(error)
        }

        isCategorizing = false
    }

    private func loadMessages(for chat: ChatSummary) {
        selectedChatMessages = []
        isLoadingMessages = true
        messageErrorNotice = nil

        do {
            let chatDatabase = try ChatDatabase()
            selectedChatMessages = try chatDatabase.fetchMessages(for: chat.id, limit: messageDisplayLimit)
        } catch {
            messageErrorNotice = ErrorNotice(error)
        }

        isLoadingMessages = false
    }

    private func addTodo(title: String, chatGuid: String?) {
        do {
            let appDatabase = try AppDatabase()
            try appDatabase.addTodo(title: title, chatGuid: chatGuid)
            todos = try appDatabase.fetchTodos()
            errorNotice = nil
        } catch {
            presentError(error)
        }
    }

    private func toggleTodo(_ todo: ConversationTodo) {
        do {
            let appDatabase = try AppDatabase()
            try appDatabase.setTodoCompleted(!todo.isCompleted, id: todo.id)
            todos = try appDatabase.fetchTodos()
            errorNotice = nil
        } catch {
            presentError(error)
        }
    }

    private func deleteTodo(_ todo: ConversationTodo) {
        do {
            let appDatabase = try AppDatabase()
            try appDatabase.deleteTodo(id: todo.id)
            todos = try appDatabase.fetchTodos()
            errorNotice = nil
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        errorNotice = ErrorNotice(error)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct ErrorNotice: Identifiable {
    let id: UUID
    let title: String
    let message: String
    let recoverySuggestion: String?

    init(title: String, message: String, recoverySuggestion: String? = nil) {
        self.id = UUID()
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }

    init(_ error: Error) {
        if let openAIError = error as? OpenAIClient.ClientError {
            self = Self.openAI(openAIError)
        } else if let chatDatabaseError = error as? ChatDatabase.DatabaseError {
            self = Self.chatDatabase(chatDatabaseError)
        } else if let appDatabaseError = error as? AppDatabase.DatabaseError {
            self = Self.appDatabase(appDatabaseError)
        } else if let keychainError = error as? KeychainError {
            self = Self.keychain(keychainError)
        } else if let urlError = error as? URLError {
            self = Self.url(urlError)
        } else {
            self = ErrorNotice(
                title: "Something went wrong",
                message: Self.clean(Self.description(for: error))
            )
        }
    }

    private static func openAI(_ error: OpenAIClient.ClientError) -> ErrorNotice {
        switch error {
        case .missingAPIKey:
            return ErrorNotice(
                title: "OpenAI API key missing",
                message: "Add your API key in Settings before categorizing conversations."
            )
        case .invalidResponse:
            return ErrorNotice(
                title: "OpenAI response was not readable",
                message: "The request completed, but the app could not read the returned categorization."
            )
        case .invalidCategory(let category):
            return ErrorNotice(
                title: "OpenAI returned an unknown category",
                message: "'\(category)' is not one of the categories this app supports."
            )
        case .requestFailed(let message):
            let cleanMessage = cleanOpenAIMessage(message)
            let lowercasedMessage = cleanMessage.lowercased()

            if lowercasedMessage.contains("quota") || lowercasedMessage.contains("billing") {
                return ErrorNotice(
                    title: "OpenAI quota exceeded",
                    message: "Your OpenAI account does not currently have enough API quota for this request.",
                    recoverySuggestion: "Check your OpenAI plan and billing details, then try again."
                )
            }

            if lowercasedMessage.contains("api key") || lowercasedMessage.contains("authentication") {
                return ErrorNotice(
                    title: "OpenAI authentication failed",
                    message: cleanMessage,
                    recoverySuggestion: "Check the API key saved in Settings."
                )
            }

            return ErrorNotice(
                title: "OpenAI request failed",
                message: cleanMessage
            )
        }
    }

    private static func chatDatabase(_ error: ChatDatabase.DatabaseError) -> ErrorNotice {
        switch error {
        case .missingBundledDatabase:
            return ErrorNotice(
                title: "Message database missing",
                message: "The app could not find the bundled chat.db file."
            )
        case .openFailed(let message):
            return ErrorNotice(
                title: "Could not open message database",
                message: clean(message)
            )
        case .prepareFailed(let message):
            return ErrorNotice(
                title: "Could not read message database",
                message: clean(message)
            )
        }
    }

    private static func appDatabase(_ error: AppDatabase.DatabaseError) -> ErrorNotice {
        switch error {
        case .applicationSupportDirectoryMissing:
            return ErrorNotice(
                title: "Application Support unavailable",
                message: "The app could not locate your Application Support folder."
            )
        case .openFailed(let message):
            return ErrorNotice(
                title: "Could not open app database",
                message: clean(message)
            )
        case .prepareFailed(let message), .stepFailed(let message):
            return ErrorNotice(
                title: "Could not update app data",
                message: clean(message)
            )
        }
    }

    private static func keychain(_ error: KeychainError) -> ErrorNotice {
        switch error {
        case .unhandledStatus(let status):
            return ErrorNotice(
                title: "Could not update Keychain",
                message: "macOS Keychain returned status \(status)."
            )
        }
    }

    private static func url(_ error: URLError) -> ErrorNotice {
        ErrorNotice(
            title: "Network request failed",
            message: error.localizedDescription,
            recoverySuggestion: "Check your network connection and try again."
        )
    }

    private static func description(for error: Error) -> String {
        let localizedDescription = error.localizedDescription
        if localizedDescription.contains("The operation couldn't be completed")
            || localizedDescription.contains("The operation couldn’t be completed") {
            return String(describing: error)
        }

        return localizedDescription
    }

    private static func cleanOpenAIMessage(_ message: String) -> String {
        let cleanMessage = clean(message)
        guard let range = cleanMessage.range(of: " For more information", options: .caseInsensitive) else {
            return cleanMessage
        }

        return String(cleanMessage[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clean(_ message: String) -> String {
        message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }
}

private struct ErrorNoticeView: View {
    let notice: ErrorNotice
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.headline)

                Text(notice.message)
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)

                if let recoverySuggestion = notice.recoverySuggestion {
                    Text(recoverySuggestion)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
        }
        .font(.callout)
        .padding(12)
        .background(Color.red.opacity(0.08))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.24))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
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
    let messages: [ConversationMessage]
    let todos: [ConversationTodo]
    let isLoadingMessages: Bool
    let messageErrorNotice: ErrorNotice?
    let messageLimit: Int
    let onReloadMessages: () -> Void
    let errorNotice: ErrorNotice?
    let onDismissError: () -> Void
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

            if let errorNotice {
                ErrorNoticeView(notice: errorNotice, onDismiss: onDismissError)
            }

            ConversationMessagesView(
                messages: messages,
                isLoading: isLoadingMessages,
                errorNotice: messageErrorNotice,
                messageLimit: messageLimit,
                participantCount: chat.participantCount,
                onReload: onReloadMessages
            )
            .frame(minHeight: 220, maxHeight: 320)

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

private struct ConversationMessagesView: View {
    let messages: [ConversationMessage]
    let isLoading: Bool
    let errorNotice: ErrorNotice?
    let messageLimit: Int
    let participantCount: Int
    let onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Messages")
                        .font(.headline)

                    Text("Showing latest \(messageLimit) text messages and attachments.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Reload", action: onReload)
                    .disabled(isLoading)
            }

            if isLoading {
                ProgressView("Loading messages...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorNotice {
                ErrorNoticeView(notice: errorNotice)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if messages.isEmpty {
                ContentUnavailableView("No text messages", systemImage: "message")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    showSender: participantCount > 1
                                )
                                .id(message.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onAppear {
                        scrollToLatestMessage(using: proxy)
                    }
                }
            }
        }
    }

    private func scrollToLatestMessage(using proxy: ScrollViewProxy) {
        guard let lastMessageID = messages.last?.id else {
            return
        }

        proxy.scrollTo(lastMessageID, anchor: .bottom)
    }
}

private struct MessageBubbleView: View {
    let message: ConversationMessage
    let showSender: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isFromMe {
                Spacer(minLength: 80)
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                if !message.isFromMe && showSender, let senderHandle = message.senderHandle {
                    Text(senderHandle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(message.isFromMe ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if let date = message.date {
                    Text(Self.dateFormatter.string(from: date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560, alignment: message.isFromMe ? .trailing : .leading)

            if !message.isFromMe {
                Spacer(minLength: 80)
            }
        }
        .padding(.horizontal, 10)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
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
