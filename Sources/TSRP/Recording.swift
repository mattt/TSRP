import Foundation

/// A recording in the Voice Memos library.
///
/// A recording is a row of the database.
/// Its audio file can be on this Mac or only in iCloud;
/// use ``Store/audioFile(for:)`` to find it.
public struct Recording: Identifiable, Sendable, Hashable {
    /// The identifier of a recording: its primary key in the database.
    ///
    /// The identifier is stable while the database exists,
    /// but it is not the same on other devices. For that, use ``Recording/uniqueID``.
    public struct ID: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
        public let rawValue: Int64

        public init(rawValue: Int64) {
            self.rawValue = rawValue
        }

        /// Creates an identifier from its description, such as `"42"`.
        public init?(_ description: String) {
            guard let rawValue = Int64(description.trimmingCharacters(in: .whitespaces)) else { return nil }
            self.rawValue = rawValue
        }

        public var description: String {
            String(rawValue)
        }
    }

    public let id: ID
    /// The identifier that Voice Memos gives the recording on every device.
    public let uniqueID: String?
    /// The title that Voice Memos shows, or `nil` if the database has none for the recording.
    public let title: String?
    /// When the recording was made.
    public let date: Date?
    /// The length of the recording, in seconds, as the database records it.
    public let duration: TimeInterval?
    /// The folder that holds the recording, or `nil` if it is in no folder.
    public let folder: Folder?
    /// When the recording moved to Recently Deleted, or `nil` if it is in the library.
    public let deletionDate: Date?
    /// The path of the audio file, as the database records it.
    ///
    /// The path is usually a file name in the `Recordings` folder.
    /// Use ``Store/audioFile(for:)`` to find the file.
    public let path: String?

    /// Whether the recording is in Recently Deleted.
    public var isRecentlyDeleted: Bool {
        deletionDate != nil
    }
}

extension Recording {
    /// The filters and pagination of a search for recordings.
    public struct FetchRequest: Sendable, Hashable {
        /// The part of the library that a search reads.
        public enum Scope: Sendable, Hashable {
            /// The recordings that are not in Recently Deleted.
            case library
            /// The recordings in Recently Deleted.
            case recentlyDeleted
        }

        /// A position in the results, after which the next page starts.
        ///
        /// Pass a cursor from ``Store/SearchResult/nextCursor`` back in a request
        /// with the same filters.
        public struct Cursor: Sendable, Hashable, CustomStringConvertible, LosslessStringConvertible {
            let date: Double
            let id: Int64

            init(date: Double, id: Int64) {
                self.date = date
                self.id = id
            }

            public init?(_ description: String) {
                let parts = description.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, let date = Double(parts[0]), let id = Int64(parts[1]) else {
                    return nil
                }
                self.init(date: date, id: id)
            }

            public var description: String {
                "\(date):\(id)"
            }
        }

        /// Text to find in titles, ignoring case and diacritics.
        public var query: String?
        /// The folder to read, or `nil` for all folders.
        public var folder: Folder.ID?
        /// The earliest recording date to include.
        public var startDate: Date?
        /// The recording date before which to stop; recordings made at this time are left out.
        public var endDate: Date?
        /// The part of the library to read.
        public var scope: Scope
        /// The largest number of recordings to return. The value must be positive.
        public var limit: Int
        /// The position after which this page starts, or `nil` for the first page.
        public var cursor: Cursor?

        /// Creates a request.
        public init(
            query: String? = nil,
            folder: Folder.ID? = nil,
            startDate: Date? = nil,
            endDate: Date? = nil,
            scope: Scope = .library,
            limit: Int = 30,
            cursor: Cursor? = nil
        ) {
            self.query = query
            self.folder = folder
            self.startDate = startDate
            self.endDate = endDate
            self.scope = scope
            self.limit = limit
            self.cursor = cursor
        }
    }
}
