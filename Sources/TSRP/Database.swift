import Foundation
import SQLite3

/// A read-only connection to the database that Voice Memos keeps
/// in `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`.
///
/// The database is a Core Data store. Recordings are rows of `ZCLOUDRECORDING`
/// (entity `CloudRecording`, class `RCCloudRecording`), and the folders that the user
/// makes are rows of `ZFOLDER` (entity `Folder`, class `RCRecordingsFolder`).
/// Every attribute is optional in the model, so queries read the columns that the
/// tables have and NULL in place of any they lack.
///
/// The connection reads the live database and its write-ahead log, without a copy.
/// Use a connection from one thread at a time, and close it when you finish.
final class Database {
    /// The name of the database file in the `Recordings` folder.
    static let fileName = "CloudRecordings.db"

    /// The `Recordings` folder.
    let root: URL
    /// The database file.
    let databaseURL: URL
    /// The names of the columns of `ZCLOUDRECORDING`.
    private(set) var recordingColumns: Set<String> = []
    /// The names of the columns of `ZFOLDER`, or none if the table doesn't exist.
    private(set) var folderColumns: Set<String> = []

    private var connection: OpaquePointer?
    /// The time at which statements stop.
    private let deadline: ContinuousClock.Instant

    /// Opens a read-only connection to the database in a `Recordings` folder and reads its schema.
    ///
    /// The caller must have access to the folder.
    /// Keep any security scope active until ``close()`` returns.
    /// - Throws: A ``VoiceMemosError`` if the database can't be found or read,
    ///   or has an unsupported schema; or `CancellationError`.
    init(root: URL, timeLimit: Duration) throws {
        try Task.checkCancellation()
        self.root = root
        databaseURL = root.appendingPathComponent(Self.fileName)
        deadline = ContinuousClock.now.advanced(by: timeLimit)

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            let canList = (try? fileManager.contentsOfDirectory(atPath: root.path)) != nil
            throw canList ? VoiceMemosError.storeNotFound : VoiceMemosError.storeNotReadable
        }
        do {
            try open(immutable: false)
        } catch VoiceMemosError.storeNotReadable where !fileManager.fileExists(atPath: databaseURL.path + "-wal") {
            // A reader of a WAL-mode database needs the `-shm` file, and SQLite can't create it
            // in a folder that is read-only. Without a log, every record is in the main file,
            // so reading the main file alone loses nothing.
            try open(immutable: true)
        }
    }

    deinit {
        close()
    }

    /// Closes the connection. Later calls do nothing.
    func close() {
        sqlite3_close(connection)
        connection = nil
    }

    /// Opens the database and reads its schema.
    ///
    /// With `immutable`, SQLite ignores the write-ahead log and never touches the `-wal`
    /// and `-shm` files, so it sees only the records in the main file.
    private func open(immutable: Bool) throws {
        var filename = databaseURL.path
        var flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE
        if immutable {
            var components = URLComponents()
            components.scheme = "file"
            components.path = databaseURL.path
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let uri = components.string else {
                throw VoiceMemosError.storeNotReadable
            }
            filename = uri
            flags |= SQLITE_OPEN_URI
        }

        guard sqlite3_open_v2(filename, &connection, flags, nil) == SQLITE_OK else {
            close()
            throw VoiceMemosError.storeNotReadable
        }
        sqlite3_busy_timeout(connection, 1000)
        sqlite3_progress_handler(
            connection,
            1000,
            { context in
                guard let context else { return 1 }
                return Unmanaged<Database>.fromOpaque(context).takeUnretainedValue().shouldStop ? 1 : 0
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        sqlite3_create_function_v2(
            connection,
            "tsrp_contains",
            2,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil,
            containsText,
            nil,
            nil,
            nil
        )

        do {
            // The first statement reads the file, so its failure means the database is not readable.
            do {
                recordingColumns = try columns(of: "ZCLOUDRECORDING")
            } catch VoiceMemosError.queryFailed {
                throw VoiceMemosError.storeNotReadable
            }
            guard recordingColumns.isSuperset(of: ["Z_PK", "ZDATE", "ZPATH", "ZEVICTIONDATE"]) else {
                throw VoiceMemosError.unsupportedSchema
            }
            folderColumns = try columns(of: "ZFOLDER")
        } catch {
            close()
            throw error
        }
    }

    private func columns(of table: String) throws -> Set<String> {
        Set(try query("SELECT name FROM pragma_table_info(?)", [.text(table)]) { $0.text(0) }.compactMap { $0 })
    }

    // MARK: Statements

    /// Runs a statement and transforms each row of its result.
    @discardableResult
    func query<T>(
        _ sql: String,
        _ bindings: [Binding] = [],
        transform: (Row) throws -> T
    ) throws -> [T] {
        guard let connection else { throw VoiceMemosError.storeNotReadable }
        try checkBudget()

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try checkResult(sqlite3_prepare_v2(connection, sql, -1, &statement, nil))

        for (offset, binding) in bindings.enumerated() {
            try checkResult(binding.bind(to: statement, at: Int32(offset + 1)))
        }

        var results: [T] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            results.append(try transform(Row(statement: statement)))
            try checkBudget()
            result = sqlite3_step(statement)
        }
        try checkResult(result)
        return results
    }

    /// Throws if the task is canceled or the time limit has passed.
    /// - Throws: `CancellationError` or ``VoiceMemosError/timedOut``.
    func checkBudget() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw VoiceMemosError.timedOut }
    }

    /// Whether the progress handler should interrupt the running statement.
    private var shouldStop: Bool {
        Task.isCancelled || ContinuousClock.now >= deadline
    }

    /// Converts a SQLite result code to an error.
    private func checkResult(_ result: Int32) throws {
        switch result & 0xff {
        case SQLITE_OK, SQLITE_DONE:
            return
        case SQLITE_INTERRUPT:
            try checkBudget()
            throw VoiceMemosError.queryFailed(String(cString: sqlite3_errmsg(connection)))
        case SQLITE_BUSY, SQLITE_LOCKED:
            throw VoiceMemosError.databaseBusy
        default:
            throw VoiceMemosError.queryFailed(String(cString: sqlite3_errmsg(connection)))
        }
    }
}

// MARK: - Recordings

extension Database {
    /// The folders that the user made, in the order Voice Memos shows them.
    func folders() throws -> [Folder] {
        guard folderColumns.contains("Z_PK") else { return [] }
        let name = folderNameExpression("f")
        let rank = folderColumns.contains("ZRANK") ? "f.ZRANK" : "0"
        return try query("SELECT f.Z_PK, \(name) FROM ZFOLDER f ORDER BY \(rank), \(name) COLLATE NOCASE, f.Z_PK") { row in
            Folder(id: Folder.ID(rawValue: row.integer(0) ?? 0), name: row.text(1))
        }
    }

    /// The recordings that match a request, newest first,
    /// and the cursor of the next page if more recordings match.
    func search(_ request: Recording.FetchRequest) throws -> (recordings: [Recording], nextCursor: Recording.FetchRequest.Cursor?) {
        guard request.limit > 0 else { throw VoiceMemosError.invalidLimit(request.limit) }

        var conditions = [request.scope == .library ? "r.ZEVICTIONDATE IS NULL" : "r.ZEVICTIONDATE IS NOT NULL"]
        var bindings: [Binding] = []
        if let query = request.query, !query.isEmpty {
            conditions.append("tsrp_contains(\(titleExpression), ?)")
            bindings.append(.text(query))
        }
        if let folder = request.folder {
            guard recordingColumns.contains("ZFOLDER") else { return ([], nil) }
            conditions.append("r.ZFOLDER = ?")
            bindings.append(.integer(folder.rawValue))
        }
        if let startDate = request.startDate {
            conditions.append("r.ZDATE >= ?")
            bindings.append(.double(startDate.timeIntervalSinceReferenceDate))
        }
        if let endDate = request.endDate {
            conditions.append("r.ZDATE < ?")
            bindings.append(.double(endDate.timeIntervalSinceReferenceDate))
        }
        if let cursor = request.cursor {
            conditions.append("(\(sortDate) < ? OR (\(sortDate) = ? AND r.Z_PK < ?))")
            bindings += [.double(cursor.date), .double(cursor.date), .integer(cursor.id)]
        }
        // Read one more row than the limit, to know whether another page follows.
        // A limit of Int64.max reads every row, so it has no row to add.
        let limit = Int64(clamping: request.limit)
        bindings.append(.integer(limit == .max ? limit : limit + 1))

        let rows = try query(
            """
            \(selectClause)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(sortDate) DESC, r.Z_PK DESC
            LIMIT ?
            """,
            bindings,
            transform: Self.recording
        )
        guard rows.count > request.limit else { return (rows, nil) }
        let page = Array(rows.prefix(request.limit))
        let last = page[page.count - 1]
        let cursor = Recording.FetchRequest.Cursor(
            date: last.date?.timeIntervalSinceReferenceDate ?? Self.missingDate,
            id: last.id.rawValue
        )
        return (page, cursor)
    }

    /// The recording with an identifier, in the library or in Recently Deleted.
    func recording(for id: Recording.ID) throws -> Recording {
        let rows = try query("\(selectClause) WHERE r.Z_PK = ?", [.integer(id.rawValue)], transform: Self.recording)
        guard let recording = rows.first else { throw VoiceMemosError.recordingNotFound(id) }
        return recording
    }

    /// The date by which recordings sort. Recordings without a date sort last.
    private var sortDate: String {
        "IFNULL(r.ZDATE, \(Self.missingDate))"
    }

    /// The sort date of a recording without a date, earlier than any real date.
    private static let missingDate = -1.0e300

    /// The select list and source tables of a recording query, in the column order
    /// that ``recording(_:)`` reads.
    private var selectClause: String {
        let hasFolders = recordingColumns.contains("ZFOLDER") && folderColumns.contains("Z_PK")
        return """
            SELECT r.Z_PK, \(column("ZUNIQUEID")), \(titleExpression), r.ZDATE, \(column("ZDURATION")),
                r.ZPATH, r.ZEVICTIONDATE, \(hasFolders ? "f.Z_PK" : "NULL"), \(hasFolders ? folderNameExpression("f") : "NULL")
            FROM ZCLOUDRECORDING r
            \(hasFolders ? "LEFT JOIN ZFOLDER f ON f.Z_PK = r.ZFOLDER" : "")
            """
    }

    /// A SQL expression for a recording's title.
    ///
    /// The local database keeps the title as plain text in `ZENCRYPTEDTITLE`, despite its name,
    /// and `ZCUSTOMLABEL` can keep a date in its place,
    /// so the encrypted title comes first, when it is text, and the label is the fallback.
    private var titleExpression: String {
        var candidates: [String] = []
        if recordingColumns.contains("ZENCRYPTEDTITLE") {
            candidates.append("CASE WHEN typeof(r.ZENCRYPTEDTITLE) = 'text' THEN NULLIF(r.ZENCRYPTEDTITLE, '') END")
        }
        if recordingColumns.contains("ZCUSTOMLABEL") {
            candidates.append("CASE WHEN typeof(r.ZCUSTOMLABEL) = 'text' THEN NULLIF(r.ZCUSTOMLABEL, '') END")
        }
        switch candidates.count {
        case 0: return "NULL"
        case 1: return candidates[0]
        default: return "COALESCE(\(candidates.joined(separator: ", ")))"
        }
    }

    /// A SQL expression for a folder's name, which is plain text in `ZENCRYPTEDNAME`, despite its name.
    private func folderNameExpression(_ alias: String) -> String {
        guard folderColumns.contains("ZENCRYPTEDNAME") else { return "NULL" }
        return "CASE WHEN typeof(\(alias).ZENCRYPTEDNAME) = 'text' THEN NULLIF(\(alias).ZENCRYPTEDNAME, '') END"
    }

    /// A column of `ZCLOUDRECORDING`, or NULL if the table doesn't have it.
    private func column(_ name: String) -> String {
        recordingColumns.contains(name) ? "r.\(name)" : "NULL"
    }

    /// Reads the current row of a statement prepared with ``selectClause``.
    private static func recording(_ row: Row) -> Recording {
        let folder = row.integer(7).map { Folder(id: Folder.ID(rawValue: $0), name: row.text(8)) }
        return Recording(
            id: Recording.ID(rawValue: row.integer(0) ?? 0),
            uniqueID: row.text(1),
            title: row.text(2),
            date: row.double(3).map(Date.init(timeIntervalSinceReferenceDate:)),
            duration: row.double(4),
            folder: folder,
            deletionDate: row.double(6).map(Date.init(timeIntervalSinceReferenceDate:)),
            path: row.text(5)
        )
    }
}

// MARK: - Values

extension Database {
    /// A value bound to a `?` placeholder in a prepared statement.
    enum Binding {
        case text(String)
        case double(Double)
        case integer(Int64)

        func bind(to statement: OpaquePointer?, at index: Int32) -> Int32 {
            switch self {
            case .text(let string):
                return sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
            case .double(let double):
                return sqlite3_bind_double(statement, index, double)
            case .integer(let integer):
                return sqlite3_bind_int64(statement, index, integer)
            }
        }
    }

    /// The current row of a prepared statement.
    ///
    /// The accessors return `nil` for `NULL` values, and ``text(_:)`` also for empty strings
    /// and values that are not text.
    struct Row {
        let statement: OpaquePointer?

        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
                let cString = sqlite3_column_text(statement, column)
            else { return nil }
            let string = String(cString: cString)
            return string.isEmpty ? nil : string
        }

        func integer(_ column: Int32) -> Int64? {
            isNull(column) ? nil : sqlite3_column_int64(statement, column)
        }

        func double(_ column: Int32) -> Double? {
            isNull(column) ? nil : sqlite3_column_double(statement, column)
        }

        private func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The SQL function `tsrp_contains(text, query)`:
/// whether the text contains the query, ignoring case and diacritics.
/// SQLite's `LIKE` ignores case only for ASCII letters.
private let containsText: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = {
    context,
    count,
    arguments in
    guard count == 2, let arguments,
        let text = sqlite3_value_text(arguments[0]),
        let query = sqlite3_value_text(arguments[1])
    else {
        sqlite3_result_int(context, 0)
        return
    }
    let found = String(cString: text).range(
        of: String(cString: query),
        options: [.caseInsensitive, .diacriticInsensitive]
    )
    sqlite3_result_int(context, found == nil ? 0 : 1)
}
