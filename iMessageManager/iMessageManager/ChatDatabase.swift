import Foundation
import SQLite3

struct ChatSummary: Identifiable {
    let id: Int64
    let guid: String
    let displayName: String
    let chatIdentifier: String?
    let serviceName: String?
    let participantHandles: [String]
    let resolvedContactCount: Int
    let participantCount: Int
    let isArchived: Bool
    var relationshipCategory: RelationshipCategory
    let messageCount: Int
    let sentCount: Int
    let receivedCount: Int
    let firstInteractionDate: Date?
    let lastInteractionDate: Date?

    var interactionSpanInDays: Int {
        guard let firstInteractionDate, let lastInteractionDate else {
            return 0
        }

        let seconds = max(0, lastInteractionDate.timeIntervalSince(firstInteractionDate))
        return max(1, Int(seconds / 86_400))
    }

    var messagesPerMonth: Double {
        guard messageCount > 0 else {
            return 0
        }

        return Double(messageCount) / max(Double(interactionSpanInDays) / 30.0, 1.0)
    }
}

struct ConversationMessageSample {
    let text: String
    let isFromMe: Bool
    let date: Date?
}

struct ConversationMessage: Identifiable {
    let id: Int64
    let text: String
    let isFromMe: Bool
    let date: Date?
    let senderHandle: String?
}

final class ChatDatabase {
    enum DatabaseError: Error {
        case missingBundledDatabase
        case openFailed(String)
        case prepareFailed(String)
    }

    private var db: OpaquePointer?

    init() throws {
        guard let url = Bundle.main.url(forResource: "chat", withExtension: "db") else {
            throw DatabaseError.missingBundledDatabase
        }

        let databaseURI = "file:\(url.path)?mode=ro&immutable=1"

        let result = sqlite3_open_v2(
            databaseURI,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        )


        if result != SQLITE_OK {
            throw DatabaseError.openFailed("\(Self.errorMessage(db)): \(url.path)")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func fetchChats(
        categories: [String: RelationshipCategory] = [:],
        contactResolver: ContactResolver = .empty
    ) throws -> [ChatSummary] {
        let sql = """
        SELECT
            c.ROWID,
            c.display_name,
            c.chat_identifier,
            c.guid,
            c.service_name,
            (
                SELECT COUNT(*)
                FROM chat_handle_join chj
                WHERE chj.chat_id = c.ROWID
            ) AS participant_count,
            c.is_archived,
            (
                SELECT GROUP_CONCAT(id, char(10))
                FROM (
                    SELECT h.id
                    FROM chat_handle_join chj
                    JOIN handle h ON h.ROWID = chj.handle_id
                    WHERE chj.chat_id = c.ROWID
                    ORDER BY h.id COLLATE NOCASE
                )
            ) AS participant_handles,
            (
                SELECT COUNT(*)
                FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                WHERE cmj.chat_id = c.ROWID
            ) AS message_count,
            (
                SELECT COUNT(*)
                FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                WHERE cmj.chat_id = c.ROWID
                    AND m.is_from_me = 1
            ) AS sent_count,
            (
                SELECT COUNT(*)
                FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                WHERE cmj.chat_id = c.ROWID
                    AND m.is_from_me = 0
            ) AS received_count,
            (
                SELECT MIN(m.date)
                FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                WHERE cmj.chat_id = c.ROWID
                    AND m.date IS NOT NULL
            ) AS first_message_date,
            (
                SELECT MAX(m.date)
                FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                WHERE cmj.chat_id = c.ROWID
                    AND m.date IS NOT NULL
            ) AS last_message_date
        FROM chat c
        ORDER BY COALESCE(NULLIF(c.display_name, ''), NULLIF(c.chat_identifier, ''), c.guid) COLLATE NOCASE
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(Self.errorMessage(db))
        }

        defer {
            sqlite3_finalize(statement)
        }

        var chats: [ChatSummary] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let explicitDisplayName = Self.string(statement, 1)
            let chatIdentifier = Self.string(statement, 2)
            let guid = Self.string(statement, 3) ?? "chat-\(id)"
            let serviceName = Self.string(statement, 4)
            let participantCount = Int(sqlite3_column_int(statement, 5))
            let isArchived = sqlite3_column_int(statement, 6) != 0
            let participantHandles = Self.participantHandles(
                from: Self.string(statement, 7),
                fallbackChatIdentifier: chatIdentifier
            )
            let messageCount = Int(sqlite3_column_int(statement, 8))
            let sentCount = Int(sqlite3_column_int(statement, 9))
            let receivedCount = Int(sqlite3_column_int(statement, 10))
            let firstInteractionDate = Self.appleDate(statement, 11)
            let lastInteractionDate = Self.appleDate(statement, 12)
            let participantLabels = participantHandles.map { handle in
                contactResolver.displayName(for: handle) ?? handle
            }
            let resolvedContactCount = participantHandles.filter {
                contactResolver.displayName(for: $0) != nil
            }.count
            let displayName = Self.displayName(
                explicitDisplayName: explicitDisplayName,
                chatIdentifier: chatIdentifier,
                guid: guid,
                participantLabels: participantLabels
            )

            chats.append(
                ChatSummary(
                    id: id,
                    guid: guid,
                    displayName: displayName,
                    chatIdentifier: chatIdentifier,
                    serviceName: serviceName,
                    participantHandles: participantHandles,
                    resolvedContactCount: resolvedContactCount,
                    participantCount: participantCount,
                    isArchived: isArchived,
                    relationshipCategory: categories[guid] ?? .unknown,
                    messageCount: messageCount,
                    sentCount: sentCount,
                    receivedCount: receivedCount,
                    firstInteractionDate: firstInteractionDate,
                    lastInteractionDate: lastInteractionDate
                )
            )
        }

        return chats
    }

    func fetchMessageSamples(for chatID: Int64, limit: Int = 30) throws -> [ConversationMessageSample] {
        let rawLimit = max(limit * 4, limit)
        let sql = """
        SELECT m.text, m.attributedBody, m.cache_has_attachments, m.is_from_me, m.date
        FROM chat_message_join cmj
        JOIN message m ON m.ROWID = cmj.message_id
        WHERE cmj.chat_id = ?
            AND m.is_system_message = 0
            AND m.is_empty = 0
            AND (
                (m.text IS NOT NULL AND TRIM(m.text) != '')
                OR m.attributedBody IS NOT NULL
                OR m.cache_has_attachments = 1
            )
        ORDER BY COALESCE(m.date, 0) DESC, m.ROWID DESC
        LIMIT ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(Self.errorMessage(db))
        }

        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_int64(statement, 1, chatID)
        sqlite3_bind_int(statement, 2, Int32(rawLimit))

        var messages: [ConversationMessageSample] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard messages.count < limit else {
                break
            }

            guard let text = Self.messageText(
                text: Self.string(statement, 0),
                attributedBody: Self.data(statement, 1),
                hasAttachment: sqlite3_column_int(statement, 2) != 0
            ) else {
                continue
            }

            messages.append(
                ConversationMessageSample(
                    text: Self.truncated(text, maxLength: 500),
                    isFromMe: sqlite3_column_int(statement, 3) != 0,
                    date: Self.appleDate(statement, 4)
                )
            )
        }

        return messages.reversed()
    }

    func fetchMessages(for chatID: Int64, limit: Int = 200) throws -> [ConversationMessage] {
        let rawLimit = max(limit * 4, limit)
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.cache_has_attachments, m.is_from_me, m.date, h.id
        FROM chat_message_join cmj
        JOIN message m ON m.ROWID = cmj.message_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE cmj.chat_id = ?
            AND m.is_system_message = 0
            AND m.is_empty = 0
            AND (
                (m.text IS NOT NULL AND TRIM(m.text) != '')
                OR m.attributedBody IS NOT NULL
                OR m.cache_has_attachments = 1
            )
        ORDER BY COALESCE(m.date, 0) DESC, m.ROWID DESC
        LIMIT ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(Self.errorMessage(db))
        }

        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_int64(statement, 1, chatID)
        sqlite3_bind_int(statement, 2, Int32(rawLimit))

        var messages: [ConversationMessage] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard messages.count < limit else {
                break
            }

            guard let text = Self.messageText(
                text: Self.string(statement, 1),
                attributedBody: Self.data(statement, 2),
                hasAttachment: sqlite3_column_int(statement, 3) != 0
            ) else {
                continue
            }

            messages.append(
                ConversationMessage(
                    id: sqlite3_column_int64(statement, 0),
                    text: text,
                    isFromMe: sqlite3_column_int(statement, 4) != 0,
                    date: Self.appleDate(statement, 5),
                    senderHandle: Self.nonEmpty(Self.string(statement, 6))
                )
            )
        }

        return messages.reversed()
    }

    private static func string(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else {
            return nil
        }

        return String(cString: text)
    }

    private static func data(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            return nil
        }

        let byteCount = sqlite3_column_bytes(statement, column)
        guard byteCount > 0 else {
            return nil
        }

        return Data(bytes: bytes, count: Int(byteCount))
    }

    private static func appleDate(_ statement: OpaquePointer?, _ column: Int32) -> Date? {
        let value = sqlite3_column_int64(statement, column)
        guard value > 0 else {
            return nil
        }

        let seconds: TimeInterval
        if value > 100_000_000_000_000 {
            seconds = Double(value) / 1_000_000_000
        } else if value > 100_000_000_000 {
            seconds = Double(value) / 1_000
        } else {
            seconds = Double(value)
        }

        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static func displayName(
        explicitDisplayName: String?,
        chatIdentifier: String?,
        guid: String?,
        participantLabels: [String]
    ) -> String {
        if let explicitDisplayName = nonEmpty(explicitDisplayName) {
            return explicitDisplayName
        }

        if participantLabels.count == 1 {
            return participantLabels[0]
        }

        if participantLabels.count > 1 {
            return summarizedParticipants(participantLabels)
        }

        if let chatIdentifier = nonEmpty(chatIdentifier) {
            return chatIdentifier
        }

        if let guid = nonEmpty(guid) {
            return guid
        }

        return "(Unnamed chat)"
    }

    private static func participantHandles(from value: String?, fallbackChatIdentifier: String?) -> [String] {
        let handles = value?
            .split(separator: "\n")
            .map(String.init)
            .compactMap { nonEmpty($0) } ?? []

        if !handles.isEmpty {
            return handles
        }

        guard let fallbackChatIdentifier = nonEmpty(fallbackChatIdentifier) else {
            return []
        }

        if fallbackChatIdentifier.contains("@") || fallbackChatIdentifier.filter(\.isNumber).count >= 7 {
            return [fallbackChatIdentifier]
        }

        return []
    }

    private static func messageText(text: String?, attributedBody: Data?, hasAttachment: Bool) -> String? {
        if let text = nonEmpty(text) {
            return text
        }

        if let text = attributedBodyText(attributedBody) {
            return text
        }

        if hasAttachment {
            return "[Attachment]"
        }

        return nil
    }

    private static func attributedBodyText(_ data: Data?) -> String? {
        guard let data else {
            return nil
        }

        let allowedClasses: [AnyClass] = [
            NSAttributedString.self,
            NSMutableAttributedString.self,
            NSString.self,
            NSArray.self,
            NSDictionary.self,
            NSNumber.self,
            NSData.self,
            NSURL.self
        ]

        if let object = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: allowedClasses, from: data) {
            if let attributedString = object as? NSAttributedString {
                return nonEmpty(attributedString.string)
            }

            if let string = object as? String {
                return nonEmpty(string)
            }
        }

        return archivedAttributedStringText(data)
    }

    private static func archivedAttributedStringText(_ data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else {
            return nil
        }

        for object in objects {
            guard let dictionary = object as? [String: Any],
                  let stringReference = dictionary["NSString"],
                  let stringIndex = keyedArchiveIndex(stringReference),
                  objects.indices.contains(stringIndex),
                  let text = objects[stringIndex] as? String,
                  let nonEmptyText = nonEmpty(text) else {
                continue
            }

            return nonEmptyText
        }

        return nil
    }

    private static func keyedArchiveIndex(_ value: Any) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }

        for child in Mirror(reflecting: value).children {
            if let index = child.value as? Int {
                return index
            }

            if let index = child.value as? UInt32 {
                return Int(index)
            }

            if let index = child.value as? UInt64 {
                return Int(index)
            }
        }

        let description = String(describing: value)
        guard let valueRange = description.range(of: "value") else {
            return nil
        }

        return firstInteger(in: description[valueRange.upperBound...])
    }

    private static func firstInteger<S: StringProtocol>(in value: S) -> Int? {
        var digits = ""

        for character in value {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                return Int(digits)
            }
        }

        return Int(digits)
    }

    private static func summarizedParticipants(_ participants: [String]) -> String {
        if participants.count <= 3 {
            return participants.joined(separator: ", ")
        }

        let visibleParticipants = participants.prefix(2).joined(separator: ", ")
        return "\(visibleParticipants), +\(participants.count - 2)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty else {
            return nil
        }

        return trimmedValue
    }

    private static func truncated(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else {
            return value
        }

        return String(value.prefix(maxLength)) + "..."
    }

    private static func errorMessage(_ db: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }

        return String(cString: message)
    }
}
