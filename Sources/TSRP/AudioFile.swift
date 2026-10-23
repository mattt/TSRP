import Foundation
import UniformTypeIdentifiers

/// The audio file of a recording, on this Mac.
public struct AudioFile: Sendable, Hashable {
    /// The location of the file.
    public let url: URL
    /// The type of the file: MPEG-4 audio (`.m4a`) or QuickTime audio (`.qta`).
    ///
    /// macOS declares QuickTime audio (`com.apple.quicktime-audio`) in macOS 26 and later.
    /// In earlier releases, a `.qta` file has a dynamic type that conforms to `public.audio`.
    public let contentType: UTType?
    /// The size of the file, in bytes.
    public let size: Int
    /// The duration of the audio, in seconds, from the file's movie header.
    public let duration: TimeInterval?
    /// Whether Voice Memos wrote a transcript into the file.
    public let hasTranscript: Bool

    /// The MIME type of the file: `audio/x-m4a` or `audio/x-quicktime`, as macOS declares them.
    ///
    /// The type for QuickTime audio is the one that macOS 26 declares;
    /// TSRP supplies it in earlier releases, which declare none.
    public var mimeType: String? {
        if let mimeType = contentType?.preferredMIMEType {
            return mimeType
        }
        return url.pathExtension.lowercased() == "qta" ? "audio/x-quicktime" : nil
    }

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
        contentType = UTType(filenameExtension: url.pathExtension, conformingTo: .audio)
        let header = try? MovieHeader(contentsOf: url)
        duration = header?.duration
        hasTranscript = header?.transcriptData != nil
    }
}
