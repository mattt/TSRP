import Foundation

/// Read-only access to the Voice Memos library.
///
/// A store reads the `CloudRecordings.db` database in the `Recordings` folder,
/// `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`,
/// and the audio files beside it.
/// It never writes to the database or the files, copies them, or changes the journal mode.
///
/// A store runs one operation at a time on a private dispatch queue,
/// outside Swift's cooperative thread pool.
/// Each operation opens its own read-only connection and closes it before it returns,
/// so a store holds no connection between operations.
/// Operations run as part of the calling task: canceling the task stops SQL statements.
///
/// The caller must have access to the `Recordings` folder, for example through Full Disk Access
/// or a security-scoped bookmark of the folder; TSRP does not request permissions.
/// The access must cover the folder and not only the database file,
/// because SQLite also reads the `-wal` and `-shm` files next to it,
/// and the audio files, which hold the transcripts, are in the folder too.
/// Keep any security scope active until each call returns or throws.
public actor Store {
    /// Limits on the work that a store does in the database.
    public struct Configuration: Sendable, Hashable {
        /// The time limit for each operation.
        ///
        /// A running statement holds a read transaction, which can delay the WAL checkpoints of Voice Memos.
        /// When the limit passes, the operation throws ``VoiceMemosError/timedOut``.
        public let timeLimit: Duration

        /// The default limit: 10 seconds for each operation.
        public static let `default` = Configuration(validTimeLimit: .seconds(10))

        /// Creates limits for a store.
        /// - Parameter timeLimit: The time limit for each operation. A value that is not positive
        ///   uses the default limit.
        public init(timeLimit: Duration = Configuration.default.timeLimit) {
            self.init(validTimeLimit: timeLimit > .zero ? timeLimit : Configuration.default.timeLimit)
        }

        private init(validTimeLimit: Duration) {
            timeLimit = validTimeLimit
        }
    }

    /// The recordings that match a search.
    public struct SearchResult: Sendable, Hashable {
        /// The matching recordings, newest first.
        public let recordings: [Recording]
        /// The position after which the next page starts, or `nil` if no more recordings match.
        /// Set ``Recording/FetchRequest/cursor`` to this value to continue the search.
        public let nextCursor: Recording.FetchRequest.Cursor?
        /// The request that selected the recordings.
        public let request: Recording.FetchRequest
    }

    /// The `Recordings` folder for the user who runs the process,
    /// `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`.
    ///
    /// The location is in the user's home folder, also in a sandboxed app.
    public static var defaultRoot: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true)
    }

    /// The `Recordings` folder, which contains `CloudRecordings.db` and the audio files.
    public nonisolated let root: URL
    /// The limits that apply to each operation.
    public nonisolated let configuration: Configuration

    private nonisolated let queue = DispatchSerialQueue(label: "me.mattt.TSRP.store")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Creates a store for a `Recordings` folder, without reading it.
    ///
    /// Call ``checkAccess()`` to check that the folder can be read.
    /// - Parameters:
    ///   - root: The `Recordings` folder.
    ///   - configuration: The limits that apply to each operation.
    public init(root: URL = Store.defaultRoot, configuration: Configuration = .default) {
        self.root = root
        self.configuration = configuration
    }

    /// Checks that the store can open the database and read its schema.
    ///
    /// Call it after the caller gets access to the `Recordings` folder,
    /// such as after the user grants it.
    /// - Throws: A ``VoiceMemosError`` if the folder or the database can't be read,
    ///   or if the database has an unsupported schema; or `CancellationError`.
    public func checkAccess() throws {
        try withDatabase { _ in }
    }

    /// Returns the folders that the user made, in the order Voice Memos shows them.
    /// - Throws: A ``VoiceMemosError`` if the database can't be read, or `CancellationError`.
    public func folders() throws -> [Folder] {
        try withDatabase { try $0.folders() }
    }

    /// Returns the recordings that match a request, newest first.
    /// - Parameter request: The filters and pagination.
    /// - Throws: ``VoiceMemosError/invalidLimit(_:)`` if the request's limit is not positive,
    ///   another ``VoiceMemosError`` if the database can't be read, or `CancellationError`.
    public func search(_ request: Recording.FetchRequest = .init()) throws -> SearchResult {
        let (recordings, nextCursor) = try withDatabase { try $0.search(request) }
        return SearchResult(recordings: recordings, nextCursor: nextCursor, request: request)
    }

    /// Returns a recording, from the library or from Recently Deleted.
    /// - Throws: ``VoiceMemosError/recordingNotFound(_:)`` if the database has no such recording,
    ///   another ``VoiceMemosError`` if the database can't be read, or `CancellationError`.
    public func recording(for id: Recording.ID) throws -> Recording {
        try withDatabase { try $0.recording(for: id) }
    }

    /// Returns the audio file of a recording, if it is on this Mac.
    ///
    /// The store reads only the file's movie header, not its audio.
    /// - Returns: The file, or `nil` if it is not on this Mac.
    ///   A path that leads out of the `Recordings` folder finds no file.
    public func audioFile(for recording: Recording) -> AudioFile? {
        fileURL(for: recording).flatMap(AudioFile.init(url:))
    }

    /// Returns the transcript that Voice Memos made of a recording.
    /// - Returns: The transcript, or `nil` if the audio file has none.
    /// - Throws: ``VoiceMemosError/audioFileNotFound(_:)`` if the audio file is not on this Mac,
    ///   ``VoiceMemosError/malformedAudioFile`` or ``VoiceMemosError/malformedTranscript``
    ///   if the file or the transcript is damaged, or an error from the file system.
    public func transcript(for recording: Recording) throws -> Transcript? {
        guard let file = audioFile(for: recording) else {
            throw VoiceMemosError.audioFileNotFound(recording.id)
        }
        return try Transcript(contentsOf: file.url)
    }

    /// The location of a recording's audio file in the `Recordings` folder.
    ///
    /// The database usually records a file name, but it can record an absolute path
    /// into the folder; only its file name is used then.
    private func fileURL(for recording: Recording) -> URL? {
        guard let path = recording.path, !path.isEmpty else { return nil }
        let folder = root.standardizedFileURL.resolvingSymlinksInPath()
        let relativePath = path.hasPrefix("/") ? (path as NSString).lastPathComponent : path
        let url = folder.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(folder.path + "/") else { return nil }
        return url
    }

    /// Opens a connection for one operation and closes it before returning.
    private func withDatabase<T>(_ body: (Database) throws -> T) throws -> T {
        let database = try Database(root: root, timeLimit: configuration.timeLimit)
        defer { database.close() }
        return try body(database)
    }
}
