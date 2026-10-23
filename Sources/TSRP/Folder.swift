import Foundation

/// A folder that the user made in Voice Memos.
///
/// The built-in folders of Voice Memos, such as Favorites and Recently Deleted,
/// are not rows in the database, so they are not folders here.
/// To read Recently Deleted, set ``Recording/FetchRequest/scope`` to ``Recording/FetchRequest/Scope/recentlyDeleted``.
public struct Folder: Identifiable, Sendable, Hashable {
    /// The identifier of a folder: its primary key in the database.
    public struct ID: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
        public let rawValue: Int64

        public init(rawValue: Int64) {
            self.rawValue = rawValue
        }

        public var description: String {
            String(rawValue)
        }
    }

    public let id: ID
    /// The name of the folder, or `nil` if the database has none for it.
    public let name: String?
}
