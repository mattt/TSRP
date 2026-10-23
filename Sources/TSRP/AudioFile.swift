import Foundation
import UniformTypeIdentifiers

/// The audio file of a recording, on this Mac.
public struct AudioFile: Sendable, Hashable {
    /// The location of the file.
    public let url: URL
    /// The type of the file: MPEG-4 audio (`.m4a`) or QuickTime audio (`.qta`).
    ///
    /// Use its `preferredMIMEType` to describe the file to other software.
    public let contentType: UTType?
    /// The size of the file, in bytes.
    public let size: Int
    /// The duration of the audio, in seconds, from the file's movie header.
    public let duration: TimeInterval?
    /// Whether Voice Memos wrote a transcript into the file.
    public let hasTranscript: Bool

    /// Reads the movie header of a file.
    ///
    /// A file whose movie header can't be read has no duration and no transcript.
    /// - Returns: The file, or `nil` if it is missing or empty. iCloud can leave an empty file
    ///   in place of a recording whose audio it keeps in the cloud.
    init?(url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else { return nil }
        self.url = url
        self.size = size
        contentType = UTType(filenameExtension: url.pathExtension)
        let header = try? MovieHeader(contentsOf: url)
        duration = header?.duration
        hasTranscript = header?.transcriptData != nil
    }
}
