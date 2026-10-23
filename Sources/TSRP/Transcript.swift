import Foundation

/// A transcript that Voice Memos made of a recording.
///
/// Voice Memos writes the transcript into the recording's audio file as JSON.
/// The JSON holds an `attributedString` in the `Codable` encoding of `AttributedString`,
/// where each run of text, usually one word, has a `timeRange` attribute,
/// and the `locale` in the `Codable` encoding of `Locale`:
///
/// ```json
/// {
///   "attributedString": {
///     "runs": ["Hello ", 0, "world", 1],
///     "attributeTable": [{"timeRange": [0.0, 0.4]}, {"timeRange": [0.4, 0.9]}]
///   },
///   "locale": {"identifier": "en_US", "current": 0}
/// }
/// ```
///
/// A recording in which Voice Memos heard no speech has an empty transcript.
public struct Transcript: Sendable, Hashable {
    /// A run of text, usually one word, with when it was spoken.
    public struct Segment: Sendable, Hashable {
        /// The text, including any space that follows it.
        public let text: String
        /// When the text was spoken, in seconds from the start of the recording,
        /// or `nil` if the transcript doesn't say.
        public let timeRange: ClosedRange<TimeInterval>?
    }

    /// The text of the transcript: the text of every segment, joined.
    public let text: String
    /// The locale of the speech, or `nil` if the transcript doesn't say.
    public let locale: Locale?
    /// The runs of text, in order.
    public let segments: [Segment]

    /// Decodes the transcript JSON that Voice Memos writes into an audio file.
    /// - Throws: ``VoiceMemosError/malformedTranscript`` if the data is not a transcript.
    public init(data: Data) throws {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw VoiceMemosError.malformedTranscript
        }
        let string = payload.attributedString
        segments = string.runs.map { run in
            let range = run[TimeRangeAttribute.self]
            return Segment(
                text: String(string[run.range].characters),
                timeRange: range.flatMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0] ... $0[1] : nil }
            )
        }
        text = String(string.characters)
        locale = payload.locale
    }

    /// Reads the transcript in an audio file.
    /// - Returns: The transcript, or `nil` if the file has none.
    /// - Throws: ``VoiceMemosError/malformedAudioFile`` if the file is damaged,
    ///   ``VoiceMemosError/malformedTranscript`` if the transcript is,
    ///   or an error from the file system.
    public init?(contentsOf url: URL) throws {
        guard let data = try MovieHeader(contentsOf: url)?.transcriptData else { return nil }
        try self.init(data: data)
    }
}

// MARK: - Decoding

/// The JSON object that Voice Memos writes.
private struct Payload: Decodable {
    var attributedString: AttributedString
    var locale: Locale?

    enum CodingKeys: String, CodingKey {
        case attributedString
        case locale
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A transcript with no speech is a plain string, usually empty.
        if let string = try? container.decode(String.self, forKey: .attributedString) {
            attributedString = AttributedString(string)
        } else {
            attributedString = try container.decode(
                AttributedString.self,
                forKey: .attributedString,
                configuration: TranscriptAttributes.self
            )
        }
        locale = try? container.decodeIfPresent(Locale.self, forKey: .locale)
    }
}

/// The attributes of the runs of a transcript.
/// Decoding ignores attributes that are not in the scope.
private struct TranscriptAttributes: AttributeScope {
    let timeRange: TimeRangeAttribute
}

/// When a run of text was spoken: its start and end, in seconds.
///
/// Voice Memos keeps time ranges as a start and an end, not a start and a duration:
/// its `RCTimeRange` functions compute a duration as the end minus the start.
private enum TimeRangeAttribute: CodableAttributedStringKey {
    typealias Value = [Double]
    static let name = "timeRange"
}
