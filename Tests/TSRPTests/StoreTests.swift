@testable import TSRP
import Foundation
import Testing

@Suite struct StoreTests {
    let folder: RecordingsFolder
    let store: Store

    /// A library with two folders, five recordings, and one in Recently Deleted.
    init() throws {
        folder = try RecordingsFolder()
        try folder.addFolder(id: 1, name: "Work", rank: 1)
        try folder.addFolder(id: 2, name: "Café", rank: 0)
        try folder.addRecording(id: 1, date: 800_000_000, title: "Grocery list", label: "2026-05-08 10:13", duration: 2.5, path: "one.m4a")
        try folder.addRecording(id: 2, date: 800_000_100, label: "Placeholder", duration: 2.5, path: "two.qta", folder: 1)
        try folder.addRecording(id: 3, date: 800_000_200, title: "Résumé notes", duration: 1, path: "/Users/someone/Recordings/three.m4a", folder: 2)
        try folder.addRecording(id: 4, date: 800_000_300, title: "Old idea", path: "four.m4a", evicted: 800_000_400)
        try folder.addRecording(id: 5, date: 800_000_400, title: "Escape", path: "../escape.m4a")
        try folder.addRecording(id: 6, date: nil, title: "No date", path: "six.m4a")
        try folder.write("one.m4a", Atoms.movie(track: Atoms.trackHeader))
        try folder.write("two.qta", Atoms.movie(brand: "qt  ", track: Atoms.metadataTrack(Transcripts.inline)))
        try folder.write("three.m4a", Atoms.movie(track: Atoms.userDataTrack(Transcripts.table)))
        try folder.write("four.m4a", [])
        store = Store(root: folder.root)
    }

    func identifiers(_ request: Recording.FetchRequest = .init()) async throws -> [Int64] {
        try await store.search(request).recordings.map(\.id.rawValue)
    }

    // MARK: Listing

    @Test("Recordings are listed newest first, without Recently Deleted, and those without a date last")
    func listing() async throws {
        #expect(try await identifiers() == [5, 3, 2, 1, 6])
        #expect(try await identifiers(.init(scope: .recentlyDeleted)) == [4])
    }

    @Test("A recording has its title, date, duration, folder, and path")
    func values() async throws {
        let recordings = try await store.search().recordings
        let resume = try #require(recordings.first { $0.id.rawValue == 3 })
        #expect(resume.title == "Résumé notes")
        #expect(resume.uniqueID == "UUID-3")
        #expect(resume.date == Date(timeIntervalSinceReferenceDate: 800_000_200))
        #expect(resume.duration == 1)
        #expect(resume.folder == Folder(id: Folder.ID(rawValue: 2), name: "Café"))
        #expect(resume.path == "/Users/someone/Recordings/three.m4a")
        #expect(!resume.isRecentlyDeleted)
        // The encrypted title comes before the custom label, which is the fallback.
        #expect(recordings.first { $0.id.rawValue == 1 }?.title == "Grocery list")
        #expect(recordings.first { $0.id.rawValue == 2 }?.title == "Placeholder")
    }

    @Test("Folders are listed in the order Voice Memos shows them")
    func folders() async throws {
        #expect(try await store.folders().map(\.name) == ["Café", "Work"])
    }

    // MARK: Filters

    @Test("A query matches titles, ignoring case and diacritics")
    func query() async throws {
        #expect(try await identifiers(.init(query: "RESUME")) == [3])
        #expect(try await identifiers(.init(query: "grocery")) == [1])
        #expect(try await identifiers(.init(query: "placeholder")) == [2])
        #expect(try await identifiers(.init(query: "%")) == [])
    }

    @Test("Folder and date filters select recordings")
    func filters() async throws {
        #expect(try await identifiers(.init(folder: Folder.ID(rawValue: 1))) == [2])
        let start = Date(timeIntervalSinceReferenceDate: 800_000_100)
        let end = Date(timeIntervalSinceReferenceDate: 800_000_400)
        #expect(try await identifiers(.init(startDate: start, endDate: end)) == [3, 2])
    }

    @Test("Cursors page through the results, including recordings without a date")
    func paging() async throws {
        var request = Recording.FetchRequest(limit: 2)
        var pages: [[Int64]] = []
        while true {
            let result = try await store.search(request)
            pages.append(result.recordings.map(\.id.rawValue))
            guard let cursor = result.nextCursor else { break }
            // A cursor survives a round trip through its description.
            request.cursor = Recording.FetchRequest.Cursor(cursor.description)
        }
        #expect(pages == [[5, 3], [2, 1], [6]])
    }

    @Test("The largest limit returns every recording")
    func largestLimit() async throws {
        let result = try await store.search(.init(limit: .max))
        #expect(result.recordings.map(\.id.rawValue) == [5, 3, 2, 1, 6])
        #expect(result.nextCursor == nil)
    }

    @Test("A limit that is not positive throws")
    func invalidLimit() async {
        await #expect(throws: VoiceMemosError.invalidLimit(0)) {
            try await store.search(.init(limit: 0))
        }
    }

    // MARK: Recordings and files

    @Test("A recording is found by its identifier, also in Recently Deleted")
    func recording() async throws {
        #expect(try await store.recording(for: Recording.ID(rawValue: 4)).isRecentlyDeleted)
        #expect(Recording.ID(" 4") == Recording.ID(rawValue: 4))
        await #expect(throws: VoiceMemosError.recordingNotFound(Recording.ID(rawValue: 99))) {
            try await store.recording(for: Recording.ID(rawValue: 99))
        }
    }

    @Test("Audio files are found in the folder, by file name for an absolute path, and never outside it")
    func audioFiles() async throws {
        func file(_ id: Int64) async throws -> AudioFile? {
            await store.audioFile(for: try await store.recording(for: Recording.ID(rawValue: id)))
        }
        #expect(try await file(1)?.hasTranscript == false)
        #expect(try await file(2)?.hasTranscript == true)
        #expect(try await file(3)?.url.lastPathComponent == "three.m4a")
        #expect(try await file(4) == nil)  // Empty, as iCloud leaves it.
        #expect(try await file(5) == nil)  // Outside the folder.
        #expect(try await file(6) == nil)  // Missing.
    }

    @Test("Transcripts are read from .m4a and .qta files")
    func transcripts() async throws {
        func transcript(_ id: Int64) async throws -> Transcript? {
            try await store.transcript(for: try await store.recording(for: Recording.ID(rawValue: id)))
        }
        #expect(try await transcript(1) == nil)
        #expect(try await transcript(2)?.text == "Bonjour à tous")
        #expect(try await transcript(3)?.text == "Hello there. General Kenobi")
        await #expect(throws: VoiceMemosError.audioFileNotFound(Recording.ID(rawValue: 6))) {
            try await transcript(6)
        }
    }

    // MARK: Access

    @Test("Rows in the write-ahead log are read, also from a folder that is read-only")
    func writeAheadLog() async throws {
        try folder.addRecording(id: 7, date: 800_000_500, title: "Only in the log")
        #expect(FileManager.default.fileExists(atPath: folder.database.path + "-wal"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.root.path)
        #expect(try await identifiers().first == 7)
    }

    @Test("A read-only folder without a log is read from the main file")
    func readOnlyWithoutLog() async throws {
        // The system SQLite keeps the log files after the last connection closes, so remove them.
        folder.closeWriter()
        try FileManager.default.removeItem(atPath: folder.database.path + "-wal")
        try FileManager.default.removeItem(atPath: folder.database.path + "-shm")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.root.path)
        #expect(try await identifiers() == [5, 3, 2, 1, 6])
        #expect(!FileManager.default.fileExists(atPath: folder.database.path + "-shm"))
    }

    @Test("A folder without a database, or with another schema, throws")
    func access() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("tsrp-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        await #expect(throws: VoiceMemosError.storeNotFound) {
            try await Store(root: empty).checkAccess()
        }

        let other = try RecordingsFolder(schema: "CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZDATE TIMESTAMP);")
        await #expect(throws: VoiceMemosError.unsupportedSchema) {
            try await Store(root: other.root).checkAccess()
        }
    }

    @Test("A library without folders still lists recordings")
    func withoutFolders() async throws {
        let library = try RecordingsFolder(
            schema: "CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZDATE TIMESTAMP, ZEVICTIONDATE TIMESTAMP, ZPATH VARCHAR);"
        )
        try library.execute("INSERT INTO ZCLOUDRECORDING VALUES (1, 800000000, NULL, 'a.m4a');")
        let store = Store(root: library.root)
        #expect(try await store.folders() == [])
        let recording = try #require(try await store.search().recordings.first)
        #expect(recording.title == nil && recording.folder == nil && recording.duration == nil)
        #expect(try await store.search(.init(folder: Folder.ID(rawValue: 1))).recordings == [])
    }
}
