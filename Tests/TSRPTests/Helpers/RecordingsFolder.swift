@testable import TSRP
import Foundation
import SQLite3

/// A synthetic `Recordings` folder with a `CloudRecordings.db` database and a writer connection to it.
///
/// The database uses WAL journal mode and disables automatic checkpoints,
/// so that readers must read recent rows from the write-ahead log, as they do while Voice Memos runs.
/// Every row is made up; none comes from a real Voice Memos library.
/// Deinitialization closes the writer and removes the folder.
final class RecordingsFolder {
    let root: URL
    private(set) var writer: OpaquePointer?

    /// The database file.
    var database: URL { root.appendingPathComponent("CloudRecordings.db") }

    /// The tables of the current model, `VoiceMemos14`, with the columns that TSRP reads and some it doesn't.
    static let schema = """
        CREATE TABLE ZFOLDER (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
            ZCOUNTOFRECORDINGS INTEGER, ZRANK INTEGER, ZENCRYPTEDNAME VARCHAR, ZUUID VARCHAR);
        CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
            ZFLAGS INTEGER, ZSHAREDFLAGS INTEGER, ZFOLDER INTEGER, ZDATE TIMESTAMP, ZEVICTIONDATE TIMESTAMP,
            ZDURATION FLOAT, ZLOCALDURATION FLOAT, ZCUSTOMLABEL VARCHAR, ZCUSTOMLABELFORSORTING VARCHAR,
            ZENCRYPTEDTITLE VARCHAR, ZPATH VARCHAR, ZUNIQUEID VARCHAR);
        """

    /// Creates an empty folder with a database, and runs the schema SQL on it.
    init(schema: String = RecordingsFolder.schema) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tsrp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open(database.path, &writer) == SQLITE_OK else {
            throw VoiceMemosError.storeNotReadable
        }
        try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try execute(schema)
    }

    deinit {
        sqlite3_close(writer)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs SQL on the writer connection.
    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(writer, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw VoiceMemosError.queryFailed(message.map { String(cString: $0) } ?? "")
        }
    }

    /// Closes the writer connection, which checkpoints the log into the main file.
    func closeWriter() {
        sqlite3_close(writer)
        writer = nil
    }

    /// Writes a file at a path relative to the folder.
    func write(_ path: String, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: root.appendingPathComponent(path))
    }

    /// Adds a recording. Dates are seconds since 2001-01-01, as Core Data stores them.
    func addRecording(
        id: Int,
        date: Double?,
        title: String? = nil,
        label: String? = nil,
        duration: Double? = nil,
        path: String? = nil,
        folder: Int? = nil,
        evicted: Double? = nil
    ) throws {
        func sql(_ value: String?) -> String {
            value.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
        }
        func sql(_ value: Double?) -> String {
            value.map { String($0) } ?? "NULL"
        }
        try execute(
            """
            INSERT INTO ZCLOUDRECORDING (Z_PK, Z_ENT, Z_OPT, ZFLAGS, ZFOLDER, ZDATE, ZEVICTIONDATE, ZDURATION,
                ZCUSTOMLABEL, ZENCRYPTEDTITLE, ZPATH, ZUNIQUEID)
            VALUES (\(id), 1, 1, 0, \(folder.map(String.init) ?? "NULL"), \(sql(date)), \(sql(evicted)), \(sql(duration)),
                \(sql(label)), \(sql(title)), \(sql(path)), 'UUID-\(id)');
            """
        )
    }

    /// Adds a folder.
    func addFolder(id: Int, name: String?, rank: Int) throws {
        let name = name.map { "'\($0)'" } ?? "NULL"
        try execute("INSERT INTO ZFOLDER (Z_PK, Z_ENT, Z_OPT, ZRANK, ZENCRYPTEDNAME, ZUUID) VALUES (\(id), 2, 1, \(rank), \(name), 'F-\(id)');")
    }
}
