import Foundation

struct CategorizationCostEstimate {
    let modelName: String
    let sampleMessageLimit: Int
    let totalConversations: Int
    let conversationsWithMessageSamples: Int
    let totalSampleMessages: Int
    let estimatedInputTokens: Int
    let estimatedOutputTokens: Int
    let standardCost: Double
    let batchCost: Double

    var averageSampleMessagesPerConversation: Double {
        guard totalConversations > 0 else {
            return 0
        }

        return Double(totalSampleMessages) / Double(totalConversations)
    }
}

enum CategorizationCostEstimator {
    static let modelName = "gpt-5-mini"
    static let inputDollarsPerMillionTokens = 0.25
    static let outputDollarsPerMillionTokens = 2.00

    private static let batchDiscount = 0.5
    private static let fixedInputTokensPerConversation = 1_200
    private static let conservativeOutputTokensPerConversation = 300
    private static let estimatedCharactersPerToken = 3.0

    static func estimate(
        chats: [ChatSummary],
        chatDatabase: ChatDatabase,
        sampleMessageLimit: Int
    ) throws -> CategorizationCostEstimate {
        var conversationsWithMessageSamples = 0
        var totalSampleMessages = 0
        var estimatedInputTokens = 0

        for chat in chats {
            let messages = try chatDatabase.fetchMessageSamples(for: chat.id, limit: sampleMessageLimit)

            if !messages.isEmpty {
                conversationsWithMessageSamples += 1
            }

            totalSampleMessages += messages.count
            estimatedInputTokens += Self.estimatedInputTokens(for: messages)
        }

        let estimatedOutputTokens = chats.count * conservativeOutputTokensPerConversation
        let standardCost = Self.standardCost(inputTokens: estimatedInputTokens, outputTokens: estimatedOutputTokens)

        return CategorizationCostEstimate(
            modelName: modelName,
            sampleMessageLimit: sampleMessageLimit,
            totalConversations: chats.count,
            conversationsWithMessageSamples: conversationsWithMessageSamples,
            totalSampleMessages: totalSampleMessages,
            estimatedInputTokens: estimatedInputTokens,
            estimatedOutputTokens: estimatedOutputTokens,
            standardCost: standardCost,
            batchCost: standardCost * batchDiscount
        )
    }

    static func estimate(
        chat _: ChatSummary,
        messages: [ConversationMessageSample],
        sampleMessageLimit: Int
    ) -> CategorizationCostEstimate {
        let estimatedInputTokens = Self.estimatedInputTokens(for: messages)
        let estimatedOutputTokens = conservativeOutputTokensPerConversation
        let standardCost = Self.standardCost(inputTokens: estimatedInputTokens, outputTokens: estimatedOutputTokens)

        return CategorizationCostEstimate(
            modelName: modelName,
            sampleMessageLimit: sampleMessageLimit,
            totalConversations: 1,
            conversationsWithMessageSamples: messages.isEmpty ? 0 : 1,
            totalSampleMessages: messages.count,
            estimatedInputTokens: estimatedInputTokens,
            estimatedOutputTokens: estimatedOutputTokens,
            standardCost: standardCost,
            batchCost: standardCost * batchDiscount
        )
    }

    private static func estimatedInputTokens(for messages: [ConversationMessageSample]) -> Int {
        let messageCharacterCount = messages.reduce(0) { total, message in
            total + message.text.count
        }
        let messageTokens = Int(ceil(Double(messageCharacterCount) / estimatedCharactersPerToken))

        return fixedInputTokensPerConversation + messageTokens
    }

    private static func standardCost(inputTokens: Int, outputTokens: Int) -> Double {
        let inputCost = Double(inputTokens) / 1_000_000 * inputDollarsPerMillionTokens
        let outputCost = Double(outputTokens) / 1_000_000 * outputDollarsPerMillionTokens

        return inputCost + outputCost
    }
}
