import Foundation

/// Builders for the atoms of QuickTime and MPEG-4 files.
///
/// The movies have a movie header and one track, but no real audio:
/// their `mdat` atoms hold a few bytes of padding.
enum Atoms {
    /// An atom with a 32-bit size.
    static func atom(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        integer(UInt64(8 + payload.count), length: 4) + Array(type.utf8) + payload
    }

    /// An atom whose type is a 32-bit integer, as metadata items are.
    static func atom(_ type: UInt32, _ payload: [UInt8]) -> [UInt8] {
        integer(UInt64(8 + payload.count), length: 4) + integer(UInt64(type), length: 4) + payload
    }

    /// An atom with a 64-bit extended size.
    static func extendedAtom(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        integer(1, length: 4) + Array(type.utf8) + integer(UInt64(16 + payload.count), length: 8) + payload
    }

    /// A big-endian unsigned integer.
    static func integer(_ value: UInt64, length: Int) -> [UInt8] {
        (0 ..< length).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    /// A version 0 movie header with a duration.
    static func movieHeader(duration: UInt32, timescale: UInt32) -> [UInt8] {
        // Version and flags, creation and modification times, timescale, duration, then the rest.
        let fields = [UInt8](repeating: 0, count: 12) + integer(UInt64(timescale), length: 4) + integer(UInt64(duration), length: 4)
        return atom("mvhd", fields + [UInt8](repeating: 0, count: 80))
    }

    /// A version 1 movie header, with 64-bit times and duration.
    static func movieHeaderVersion1(duration: UInt64, timescale: UInt32) -> [UInt8] {
        let fields = [1, 0, 0, 0] + [UInt8](repeating: 0, count: 16) + integer(UInt64(timescale), length: 4) + integer(duration, length: 8)
        return atom("mvhd", fields + [UInt8](repeating: 0, count: 80))
    }

    /// A file with a file type atom, a movie header with one track, and media data.
    static func movie(
        brand: String = "M4A ",
        header: [UInt8] = movieHeader(duration: 2_500, timescale: 1_000),
        track: [UInt8]
    ) -> [UInt8] {
        atom("ftyp", Array(brand.utf8) + integer(0, length: 4))
            + atom("moov", header + atom("trak", track))
            + atom("mdat", [UInt8](repeating: 0, count: 16))
    }

    /// The parts of a track that hold no metadata.
    static let trackHeader = atom("tkhd", [UInt8](repeating: 0, count: 84))
    static let mediaHeader = atom("mdhd", [UInt8](repeating: 0, count: 24)) + atom("hdlr", [UInt8](repeating: 0, count: 25))

    /// A track with a `tsrp` atom in its user data, as in an `.m4a` file.
    static func userDataTrack(_ transcript: Data, inMedia: Bool = false) -> [UInt8] {
        let userData = atom("udta", atom("tsrp", Array(transcript)))
        if inMedia {
            return trackHeader + atom("mdia", mediaHeader + userData)
        }
        return trackHeader + atom("mdia", mediaHeader) + userData
    }

    /// A track with QuickTime metadata items, as in a `.qta` file.
    ///
    /// - Parameters:
    ///   - items: The keys and values, in order. A key's namespace defaults to `mdta`.
    ///   - versioned: Whether the `meta` atom starts with a version and flags, as an ISO one does.
    static func metadataTrack(_ items: [(key: String, namespace: String, value: Data)], versioned: Bool = false) -> [UInt8] {
        let keyEntries = items.flatMap { atom($0.namespace, Array($0.key.utf8)) }
        let keys = atom("keys", integer(0, length: 4) + integer(UInt64(items.count), length: 4) + keyEntries)
        let list = atom(
            "ilst",
            items.enumerated().flatMap { index, item in
                // A data atom: a type indicator (0, raw data), a locale, and the value.
                atom(UInt32(index + 1), atom("data", integer(0, length: 4) + integer(0, length: 4) + Array(item.value)))
            }
        )
        let handler = atom("hdlr", integer(0, length: 8) + Array("mdta".utf8) + [UInt8](repeating: 0, count: 13))
        let metadata = atom("meta", (versioned ? integer(0, length: 4) : []) + handler + keys + list)
        return trackHeader + atom("mdia", mediaHeader) + metadata
    }

    /// A track with the transcript under `com.apple.VoiceMemos.tsrp`, after another item.
    static func metadataTrack(_ transcript: Data, versioned: Bool = false) -> [UInt8] {
        metadataTrack(
            [
                (key: "com.apple.quicktime.location.ISO6709", namespace: "mdta", value: Data("+37.3349-122.0090/".utf8)),
                (key: "com.apple.VoiceMemos.tsrp", namespace: "mdta", value: transcript),
            ],
            versioned: versioned
        )
    }
}

/// Transcript JSON in the forms that Foundation writes.
enum Transcripts {
    /// The form with an attribute table, which Foundation writes when runs share attributes.
    static let table = Data(
        #"""
        {"attributedString":{"runs":["Hello ",0,"there. ",1,"General ",2,"Kenobi",3],
        "attributeTable":[{"timeRange":[0,0.4]},{"timeRange":[0.4,0.9]},{"timeRange":[1.2,1.6]},{"timeRange":[1.6,2.1]}]},
        "locale":{"identifier":"en_US","current":0}}
        """#.utf8
    )

    /// The form with attributes inline.
    static let inline = Data(
        #"{"attributedString":["Bonjour ",{"timeRange":[0,0.5]},"à tous",{"timeRange":[0.5,1.25]}],"locale":{"identifier":"fr_CA","current":0}}"#.utf8
    )

    /// A recording with no speech.
    static let empty = Data(#"{"attributedString":"","locale":{"identifier":"en_US","current":0}}"#.utf8)
}
