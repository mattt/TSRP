import Foundation

/// The movie header (`moov` atom) of a QuickTime or MPEG-4 file.
///
/// Voice Memos writes `.m4a` (MPEG-4 audio) and `.qta` (QuickTime audio) files.
/// Both are trees of atoms, each with a 32-bit size, a four-character type, and a payload.
/// The movie header holds the duration and the metadata, including the transcript;
/// the audio is in a separate `mdat` atom, which this type never reads.
struct MovieHeader {
    /// The key of the transcript in an `.m4a` file: a user data atom.
    static let userDataTranscriptKey = "tsrp"
    /// The key of the transcript in a `.qta` file: a QuickTime metadata item in the `mdta` namespace.
    static let metadataTranscriptKey = "com.apple.VoiceMemos.tsrp"
    /// The largest movie header that TSRP reads. A larger one belongs to a damaged file.
    static let maximumSize = 64 * 1024 * 1024

    /// The payload of the `moov` atom.
    private let bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Reads the movie header of a file, without reading the media data.
    /// - Returns: The header, or `nil` if the file is empty or has no `moov` atom.
    /// - Throws: ``VoiceMemosError/malformedAudioFile`` if the atoms are damaged,
    ///   or an error from the file system.
    init?(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()

        var offset: UInt64 = 0
        while offset + 8 <= length {
            try handle.seek(toOffset: offset)
            let header = [UInt8](try handle.read(upToCount: 16) ?? Data())
            guard header.count >= 8 else { throw VoiceMemosError.malformedAudioFile }

            var size = UInt64(Self.integer(header, at: 0, length: 4))
            var headerSize: UInt64 = 8
            if size == 1 {
                guard header.count >= 16 else { throw VoiceMemosError.malformedAudioFile }
                size = Self.integer(header, at: 8, length: 8)
                headerSize = 16
            } else if size == 0 {
                size = length - offset  // To the end of the file.
            }
            guard size >= headerSize, size <= length - offset else {
                throw VoiceMemosError.malformedAudioFile
            }

            if header[4 ..< 8].elementsEqual("moov".utf8) {
                let payloadSize = size - headerSize
                guard payloadSize <= Self.maximumSize else { throw VoiceMemosError.malformedAudioFile }
                try handle.seek(toOffset: offset + headerSize)
                let payload = [UInt8](try handle.read(upToCount: Int(payloadSize)) ?? Data())
                guard payload.count == Int(payloadSize) else { throw VoiceMemosError.malformedAudioFile }
                self.init(bytes: payload)
                return
            }
            offset += size
        }
        return nil
    }

    /// The duration of the movie, in seconds, from its `mvhd` atom.
    var duration: TimeInterval? {
        guard let header = children(ofType: "mvhd", in: 0 ..< bytes.count).first, header.count >= 1 else {
            return nil
        }
        // Version 0 stores 32-bit times; version 1 stores 64-bit creation,
        // modification, and duration values.
        let isVersion1 = bytes[header.lowerBound] == 1
        let timescaleOffset = header.lowerBound + (isVersion1 ? 20 : 12)
        let durationLength = isVersion1 ? 8 : 4
        guard timescaleOffset + 4 + durationLength <= header.upperBound else { return nil }
        let timescale = Self.integer(bytes, at: timescaleOffset, length: 4)
        let duration = Self.integer(bytes, at: timescaleOffset + 4, length: durationLength)
        guard timescale > 0 else { return nil }
        return TimeInterval(duration) / TimeInterval(timescale)
    }

    /// The transcript JSON that Voice Memos wrote into the file, from the first track that has one.
    ///
    /// An `.m4a` file keeps it in a `tsrp` atom in the track's user data,
    /// which files place in the track (`trak/udta`) or in its media (`trak/mdia/udta`).
    /// A `.qta` file keeps it in the track's QuickTime metadata (`trak/meta`),
    /// under the key `com.apple.VoiceMemos.tsrp`.
    var transcriptData: Data? {
        for track in children(ofType: "trak", in: 0 ..< bytes.count) {
            let media = children(ofType: "mdia", in: track)
            let userData = (children(ofType: "udta", in: track) + media.flatMap { children(ofType: "udta", in: $0) })
            for container in userData {
                if let payload = children(ofType: Self.userDataTranscriptKey, in: container).first {
                    return Data(bytes[payload])
                }
            }
            for metadata in children(ofType: "meta", in: track) {
                if let value = metadataValue(forKey: Self.metadataTranscriptKey, in: metadata) {
                    return Data(bytes[value])
                }
            }
        }
        return nil
    }

    // MARK: Metadata

    /// The value of a QuickTime metadata item in the `mdta` namespace.
    ///
    /// A `keys` atom lists the keys, and each item in the `ilst` atom has, as its type,
    /// the 1-based index of its key. The item holds a `data` atom whose payload
    /// starts with a type indicator and a locale, 4 bytes each, before the value.
    private func metadataValue(forKey key: String, in metadata: Range<Int>) -> Range<Int>? {
        let start = metadataChildrenStart(metadata)
        guard let keys = children(ofType: "keys", in: start ..< metadata.upperBound).first,
            let list = children(ofType: "ilst", in: start ..< metadata.upperBound).first,
            keys.count >= 8
        else { return nil }

        // After the version and flags, a count, then each key's size, namespace, and name.
        let count = Self.integer(bytes, at: keys.lowerBound + 4, length: 4)
        var index: UInt64?
        var offset = keys.lowerBound + 8
        var number: UInt64 = 1
        while number <= count, offset + 8 <= keys.upperBound {
            let size = Int(Self.integer(bytes, at: offset, length: 4))
            guard size >= 8, size <= keys.upperBound - offset else { return nil }
            if bytes[(offset + 4) ..< (offset + 8)].elementsEqual("mdta".utf8),
                bytes[(offset + 8) ..< (offset + size)].elementsEqual(key.utf8)
            {
                index = number
                break
            }
            offset += size
            number += 1
        }
        guard let index else { return nil }

        for item in atoms(in: list) where item.type == index {
            guard let data = children(ofType: "data", in: item.payload).first, data.count >= 8 else {
                return nil
            }
            return (data.lowerBound + 8) ..< data.upperBound
        }
        return nil
    }

    /// Where the children of a `meta` atom start.
    ///
    /// An ISO `meta` atom starts with a version and flags, which are zero;
    /// a QuickTime one starts with its first child, whose size is not.
    private func metadataChildrenStart(_ metadata: Range<Int>) -> Int {
        if metadata.count >= 4, Self.integer(bytes, at: metadata.lowerBound, length: 4) == 0 {
            return metadata.lowerBound + 4
        }
        return metadata.lowerBound
    }

    // MARK: Atoms

    private struct Atom {
        /// The four-character type, as a big-endian integer.
        let type: UInt64
        let payload: Range<Int>
    }

    /// The payloads of the atoms of a type within a range.
    private func children(ofType type: String, in range: Range<Int>) -> [Range<Int>] {
        let code = type.utf8.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return atoms(in: range).filter { $0.type == code }.map(\.payload)
    }

    /// The atoms within a range, up to the first one whose size is damaged.
    private func atoms(in range: Range<Int>) -> [Atom] {
        var atoms: [Atom] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Self.integer(bytes, at: offset, length: 4)
            var headerSize = 8
            if size == 1 {
                // A size of 1 marks an extended header whose 64-bit size follows the type.
                guard offset + 16 <= range.upperBound else { break }
                size = Self.integer(bytes, at: offset + 8, length: 8)
                headerSize = 16
            } else if size == 0 {
                size = UInt64(range.upperBound - offset)  // To the end of the container.
            }
            // Compare against the remaining bytes, so a damaged size can't overflow.
            guard size >= UInt64(headerSize), size <= UInt64(range.upperBound - offset) else { break }
            let end = offset + Int(size)
            atoms.append(Atom(type: Self.integer(bytes, at: offset + 4, length: 4), payload: (offset + headerSize) ..< end))
            offset = end
        }
        return atoms
    }

    /// A big-endian unsigned integer. The caller checks that the bytes are in bounds.
    private static func integer(_ bytes: [UInt8], at offset: Int, length: Int) -> UInt64 {
        bytes[offset ..< (offset + length)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}
