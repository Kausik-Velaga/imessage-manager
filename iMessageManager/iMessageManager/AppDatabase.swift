import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct ConversationTodo: Identifiable {
    let id: Int64
    let chatGuid: String?
    var title: String
    var isCompleted: Bool
    let createdAt: Date
}

final class AppDatabase {
    enum DatabaseError: Error {
        case applicationSupportDirectoryMissing
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
    }

    private var db: OpaquePointer?

    init() throws {
        let databaseURL = try Self.databaseURL()
        let result = sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        if result != SQLITE_OK {
            throw DatabaseError.openFailed(Self.errorMessage(db))
        }

        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    func fetchCategories() throws -> [String: RelationshipCategory] {
        let sql = "SELECT chat_guid, category FROM conversation_categories"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var categories: [String: RelationshipCategory] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guid = Self.string(statement, 0),
                  let rawCategory = Self.string(statement, 1),
                  let category = RelationshipCategory(rawValue: rawCategory) else {
                continue
            }

            categories[guid] = category
        }

        return categories
    }

    func setCategory(_ category: RelationshipCategory, for chatGuid: String) throws {
        let sql = """
        INSERT INTO conversation_categories (chat_guid, category)
        VALUES (?, ?)
        ON CONFLICT(chat_guid) DO UPDATE SET category = excluded.category
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, chatGuid, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, category.rawValue, -1, sqliteTransient)

        try step(statement)
    }

    func fetchTodos() throws -> [ConversationTodo] {
        let sql = """
        SELECT id, chat_guid, title, is_completed, created_at
        FROM todos
        ORDER BY is_completed ASC, created_at DESC
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var todos: [ConversationTodo] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let title = Self.string(statement, 2) else {
                continue
            }

            todos.append(
                ConversationTodo(
                    id: sqlite3_column_int64(statement, 0),
                    chatGuid: Self.string(statement, 1),
                    title: title,
                    isCompleted: sqlite3_column_int(statement, 3) != 0,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                )
            )
        }

        return todos
    }

    func addTodo(title: String, chatGuid: String?) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return
        }

        let sql = """
        INSERT INTO todos (chat_guid, title, is_completed, created_at)
        VALUES (?, ?, 0, ?)
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        if let chatGuid {
            sqlite3_bind_text(statement, 1, chatGuid, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 1)
        }

        sqlite3_bind_text(statement, 2, trimmedTitle, -1, sqliteTransient)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)

        try step(statement)
    }

    func setTodoCompleted(_ isCompleted: Bool, id: Int64) throws {
        let sql = "UPDATE todos SET is_completed = ? WHERE id = ?"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, isCompleted ? Int32(1) : Int32(0))
        sqlite3_bind_int64(statement, 2, id)

        try step(statement)
    }

    func deleteTodo(id: Int64) throws {
        let sql = "DELETE FROM todos WHERE id = ?"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, id)

        try step(statement)
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS conversation_categories (
            chat_guid TEXT PRIMARY KEY NOT NULL,
            category TEXT NOT NULL
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS todos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_guid TEXT,
            title TEXT NOT NULL,
            is_completed INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        )
        """)
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)

        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? Self.errorMessage(db)
            sqlite3_free(error)
            throw DatabaseError.stepFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(Self.errorMessage(db))
        }

        return statement
    }

    private func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(Self.errorMessage(db))
        }
    }

    private static func databaseURL() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DatabaseError.applicationSupportDirectoryMissing
        }

        let directoryURL = applicationSupportURL.appendingPathComponent("iMessageManager", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("app.sqlite")
    }

    private static func string(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else {
            return nil
        }

        return String(cString: text)
    }

    private static func errorMessage(_ db: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }

        return String(cString: message)
    }
}
