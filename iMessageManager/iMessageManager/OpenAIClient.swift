import Foundation

struct ConversationClassification {
    let category: RelationshipCategory
    let rationale: String
}

struct OpenAIClient {
    enum ClientError: Error {
        case missingAPIKey
        case invalidResponse
        case requestFailed(String)
        case invalidCategory(String)
    }

    let apiKey: String
    let model: String

    init(apiKey: String, model: String = "gpt-5-mini") {
        self.apiKey = apiKey
        self.model = model
    }

    func classifyConversation(chat: ChatSummary, messages: [ConversationMessageSample]) async throws -> ConversationClassification {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(chat: chat, messages: messages))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.requestFailed(Self.errorMessage(from: data) ?? "OpenAI request failed with status \(httpResponse.statusCode).")
        }

        guard let outputText = Self.outputText(from: data) else {
            throw ClientError.invalidResponse
        }

        return try Self.classification(from: outputText)
    }

    private func requestBody(chat: ChatSummary, messages: [ConversationMessageSample]) -> [String: Any] {
        [
            "model": model,
            "reasoning": [
                "effort": "minimal"
            ],
            "instructions": """
            Categorize an iMessage conversation into exactly one category.

            Allowed category raw values:
            \(RelationshipCategory.llmCategoryDescriptions)

            Use these rules:
            - closeFriend: frequent personal conversation with clear closeness.
            - friend: personal relationship, but not clearly close family or close friend.
            - family: relatives or family logistics.
            - acquaintance: weak tie, light social context, or infrequent personal contact.
            - professional: ongoing work, recruiting, advising, client, colleague, investor, or collaborator relationship.
            - transactional: service provider, vendor, appointment, support, logistics, delivery, booking, purchase, or one-off operational thread.
            - group: group chat where the group itself is the primary relationship.
            - unknown: insufficient evidence.

            Return only compact JSON with this exact shape:
            {"category":"friend","rationale":"short reason"}
            """,
            "input": classificationInput(chat: chat, messages: messages),
            "max_output_tokens": 220
        ]
    }

    private func classificationInput(chat: ChatSummary, messages: [ConversationMessageSample]) -> String {
        let messageLines = messages.map { message in
            let sender = message.isFromMe ? "Me" : "Other"
            return "- \(sender): \(message.text)"
        }
        .joined(separator: "\n")

        return """
        Conversation:
        Name: \(chat.displayName)
        Service: \(chat.serviceName ?? "unknown")
        Participant count: \(chat.participantCount)
        Total messages: \(chat.messageCount)
        Sent by me: \(chat.sentCount)
        Received: \(chat.receivedCount)

        Recent message sample:
        \(messageLines.isEmpty ? "(No text messages available.)" : messageLines)
        """
    }

    private static func classification(from outputText: String) throws -> ConversationClassification {
        guard let data = outputText.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCategory = object["category"] as? String else {
            throw ClientError.invalidResponse
        }

        guard let category = RelationshipCategory(rawValue: rawCategory) else {
            throw ClientError.invalidCategory(rawCategory)
        }

        let rationale = (object["rationale"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ConversationClassification(category: category, rationale: rationale)
    }

    private static func outputText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let outputText = object["output_text"] as? String {
            return outputText
        }

        guard let output = object["output"] as? [[String: Any]] else {
            return nil
        }

        let texts = output.flatMap { item -> [String] in
            guard let content = item["content"] as? [[String: Any]] else {
                return []
            }

            return content.compactMap { contentItem in
                contentItem["text"] as? String
            }
        }

        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }

        return message
    }
}
