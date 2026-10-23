import Foundation

/// An error that occurs when TSRP reads the Voice Memos library.
///
/// The error descriptions are in English; TSRP does not localize them.
public enum VoiceMemosError: LocalizedError, Hashable {
    /// The folder does not contain a `CloudRecordings.db` database.
    case storeNotFound
    /// The folder, the database, or its write-ahead log files cannot be read.
    case storeNotReadable
    /// The database does not have the table and columns that TSRP reads.
    case unsupportedSchema
    /// Voice Memos holds a lock on the database.
    case databaseBusy
    /// The operation did not finish within ``Store/Configuration/timeLimit``.
    case timedOut
    /// SQLite reported an error, with its message.
    case queryFailed(String)
    /// The limit of a fetch request is not positive.
    case invalidLimit(Int)
    /// The database has no recording with the identifier.
    case recordingNotFound(Recording.ID)
    /// The audio file of the recording is not on this Mac,
    /// for example because Voice Memos keeps it only in iCloud.
    case audioFileNotFound(Recording.ID)
    /// The audio file is not a QuickTime or MPEG-4 file that TSRP can read.
    case malformedAudioFile
    /// The transcript in an audio file is not in the format that TSRP reads.
    case malformedTranscript

    public var errorDescription: String? {
        switch self {
        case .storeNotFound:
            return "The selected folder does not contain a Voice Memos library."
        case .storeNotReadable:
            return "The Voice Memos library cannot be read. The database and its write-ahead log files must be readable."
        case .unsupportedSchema:
            return "The Voice Memos library uses an unsupported schema."
        case .databaseBusy:
            return "Voice Memos is using the library. Try again later."
        case .timedOut:
            return "Reading the Voice Memos library stopped at the time limit."
        case .queryFailed(let message):
            return "The Voice Memos library cannot be read: \(message)"
        case .invalidLimit(let limit):
            return "The limit must be a positive number, not \(limit)."
        case .recordingNotFound(let id):
            return "No recording has the identifier \(id)."
        case .audioFileNotFound(let id):
            return "The audio file of the recording with the identifier \(id) is not on this Mac."
        case .malformedAudioFile:
            return "The audio file is damaged or is not a QuickTime or MPEG-4 file."
        case .malformedTranscript:
            return "The transcript in the audio file is damaged or in an unknown format."
        }
    }
}
