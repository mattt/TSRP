@testable import TSRP
import Foundation
import Testing

@Suite struct TranscriptTests {
    @Test("The attribute table form decodes into text, segments, and a locale")
    func table() throws {
        let transcript = try Transcript(data: Transcripts.table)
        #expect(transcript.text == "Hello there. General Kenobi")
        #expect(transcript.locale == Locale(identifier: "en_US"))
        #expect(transcript.segments.map(\.text) == ["Hello ", "there. ", "General ", "Kenobi"])
        #expect(transcript.segments.map(\.timeRange) == [0 ... 0.4, 0.4 ... 0.9, 1.2 ... 1.6, 1.6 ... 2.1])
    }

    @Test("The inline form decodes, including text that is not ASCII")
    func inline() throws {
        let transcript = try Transcript(data: Transcripts.inline)
        #expect(transcript.text == "Bonjour à tous")
        #expect(transcript.locale?.identifier == "fr_CA")
        #expect(transcript.segments.map(\.timeRange) == [0 ... 0.5, 0.5 ... 1.25])
    }

    @Test("A recording with no speech has an empty transcript")
    func empty() throws {
        let transcript = try Transcript(data: Transcripts.empty)
        #expect(transcript.text.isEmpty)
        #expect(transcript.segments.isEmpty)
    }

    @Test("Foundation's own encoding decodes, in both forms")
    func foundationEncoding() throws {
        // Distinct attributes give the inline form; repeated ones give the attribute table.
        for times in [[[0.0, 1.0], [1.0, 2.0], [2.0, 3.0]], [[0.0, 1.0], [1.0, 2.0], [0.0, 1.0]]] {
            var string = AttributedString()
            for (index, time) in times.enumerated() {
                var run = AttributedString("word\(index) ")
                run[TestTimeRange.self] = time
                string += run
            }
            let data = try JSONEncoder().encode(TestPayload(attributedString: string, locale: Locale(identifier: "de_DE")))
            let transcript = try Transcript(data: data)
            #expect(transcript.text == "word0 word1 word2 ")
            #expect(transcript.locale?.identifier == "de_DE")
            #expect(transcript.segments.map(\.timeRange) == times.map { $0[0] ... $0[1] })
        }
    }

    @Test("Unknown attributes are ignored, and odd time ranges are left out")
    func lenient() throws {
        let data = Data(
            #"{"attributedString":["a ",{"timeRange":[2,1],"confidence":0.5},"b",{"timeRange":[1]},"c",{"other":true}]}"#.utf8
        )
        let transcript = try Transcript(data: data)
        #expect(transcript.text == "a bc")
        #expect(transcript.locale == nil)
        #expect(transcript.segments.map(\.timeRange) == [nil, nil, nil])
    }

    @Test("Data that is not a transcript throws", arguments: ["not json", #"{"other":1}"#, #"{"attributedString":{"runs":[1]}}"#])
    func malformed(json: String) {
        #expect(throws: VoiceMemosError.malformedTranscript) {
            try Transcript(data: Data(json.utf8))
        }
    }
}

// MARK: -

/// An attribute with the same name as the one Voice Memos writes, to encode test transcripts with Foundation.
enum TestTimeRange: CodableAttributedStringKey {
    typealias Value = [Double]
    static let name = "timeRange"
}

struct TestAttributes: AttributeScope {
    let timeRange: TestTimeRange
}

struct TestPayload: Encodable {
    var attributedString: AttributedString
    var locale: Locale

    enum CodingKeys: String, CodingKey {
        case attributedString
        case locale
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attributedString, forKey: .attributedString, configuration: TestAttributes.self)
        try container.encode(locale, forKey: .locale)
    }
}
