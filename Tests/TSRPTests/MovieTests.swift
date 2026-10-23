@testable import TSRP
import AVFoundation
import Foundation
import Testing

@Suite struct MovieTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tsrp-movie-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: Transcripts

    @Test("An .m4a transcript is found in the track's user data", arguments: [false, true])
    func userData(inMedia: Bool) throws {
        let url = try write("a.m4a", Atoms.movie(track: Atoms.userDataTrack(Transcripts.table, inMedia: inMedia)))
        #expect(try MovieHeader(contentsOf: url)?.transcriptData == Transcripts.table)
        #expect(try Transcript(contentsOf: url)?.text == "Hello there. General Kenobi")
    }

    @Test("A .qta transcript is found in the track's QuickTime metadata", arguments: [false, true])
    func metadata(versioned: Bool) throws {
        let url = try write("a.qta", Atoms.movie(brand: "qt  ", track: Atoms.metadataTrack(Transcripts.inline, versioned: versioned)))
        #expect(try MovieHeader(contentsOf: url)?.transcriptData == Transcripts.inline)
        #expect(try Transcript(contentsOf: url)?.text == "Bonjour à tous")
    }

    @Test("A metadata item needs the transcript key in the mdta namespace")
    func metadataKey() throws {
        let other = Atoms.metadataTrack([(key: "com.apple.VoiceMemos.tsrp", namespace: "udta", value: Transcripts.table)])
        #expect(try MovieHeader(contentsOf: try write("a.qta", Atoms.movie(track: other)))?.transcriptData == nil)
        let unrelated = Atoms.metadataTrack([(key: "com.apple.VoiceMemos.other", namespace: "mdta", value: Transcripts.table)])
        #expect(try MovieHeader(contentsOf: try write("b.qta", Atoms.movie(track: unrelated)))?.transcriptData == nil)
    }

    @Test("A file without a transcript has none")
    func noTranscript() throws {
        let url = try write("a.m4a", Atoms.movie(track: Atoms.trackHeader + Atoms.atom("mdia", Atoms.mediaHeader)))
        #expect(try MovieHeader(contentsOf: url)?.transcriptData == nil)
        #expect(try Transcript(contentsOf: url) == nil)
    }

    @Test("A transcript written by AVFoundation as track metadata is found")
    func avFoundation() async throws {
        let url = folder.appendingPathComponent("written.mov")
        try await writeMovie(to: url, transcript: Transcripts.table)
        #expect(try MovieHeader(contentsOf: url)?.transcriptData == Transcripts.table)
        #expect(try MovieHeader(contentsOf: url)?.duration.map { abs($0 - 0.5) < 0.1 } == true)
    }

    // MARK: Movie headers

    @Test("The duration comes from the movie header, in either version")
    func duration() throws {
        let version0 = try write("a.m4a", Atoms.movie(header: Atoms.movieHeader(duration: 90_000, timescale: 600), track: Atoms.trackHeader))
        #expect(try MovieHeader(contentsOf: version0)?.duration == 150)
        let version1 = try write(
            "b.m4a",
            Atoms.movie(header: Atoms.movieHeaderVersion1(duration: 44_100 * 3_600, timescale: 44_100), track: Atoms.trackHeader)
        )
        #expect(try MovieHeader(contentsOf: version1)?.duration == 3_600)
    }

    @Test("Atoms with 64-bit sizes are read")
    func extendedSize() throws {
        let bytes =
            Atoms.atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0])
            + Atoms.extendedAtom("mdat", [UInt8](repeating: 0, count: 32))
            + Atoms.extendedAtom("moov", Atoms.movieHeader(duration: 1_000, timescale: 1_000) + Atoms.atom("trak", Atoms.userDataTrack(Transcripts.empty)))
        let url = try write("a.m4a", bytes)
        #expect(try MovieHeader(contentsOf: url)?.duration == 1)
        #expect(try MovieHeader(contentsOf: url)?.transcriptData == Transcripts.empty)
    }

    @Test("A file without a movie header has none, and a damaged one throws")
    func damaged() throws {
        #expect(try MovieHeader(contentsOf: try write("a.m4a", Atoms.atom("ftyp", Array("M4A ".utf8)))) == nil)
        let truncated = Array(Atoms.movie(track: Atoms.trackHeader).prefix(60))
        #expect(throws: VoiceMemosError.malformedAudioFile) {
            try MovieHeader(contentsOf: try write("b.m4a", truncated))
        }
        // A child atom whose size runs past its container stops the search without a crash.
        let overrun = Atoms.movie(track: Atoms.integer(0xFFFF_FFF0, length: 4) + Array("udta".utf8))
        #expect(try MovieHeader(contentsOf: try write("c.m4a", overrun))?.transcriptData == nil)
    }

    @Test("Audio files describe their type, size, duration, and transcript")
    func audioFile() throws {
        let m4a = try write("a.m4a", Atoms.movie(track: Atoms.userDataTrack(Transcripts.table)))
        let file = try #require(AudioFile(url: m4a))
        #expect(file.contentType?.preferredMIMEType == "audio/x-m4a")
        #expect(file.duration == 2.5)
        #expect(file.hasTranscript)
        #expect(file.size == (try Data(contentsOf: m4a)).count)

        let qta = try write("b.qta", Atoms.movie(brand: "qt  ", track: Atoms.trackHeader))
        #expect(AudioFile(url: qta)?.contentType?.preferredMIMEType == "audio/x-quicktime")
        #expect(AudioFile(url: qta)?.hasTranscript == false)

        // iCloud can leave an empty file for a recording whose audio is in the cloud.
        #expect(AudioFile(url: try write("c.m4a", [])) == nil)
        #expect(AudioFile(url: folder.appendingPathComponent("missing.m4a")) == nil)
    }
}

// MARK: -

/// Writes half a second of silent audio to a QuickTime movie
/// with the transcript as a track metadata item, as Voice Memos does for a `.qta` file.
private func writeMovie(to url: URL, transcript: Data) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    var description = AudioStreamBasicDescription(
        mSampleRate: 8_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var format: CMAudioFormatDescription?
    #expect(
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr
    )

    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
    let item = AVMutableMetadataItem()
    item.keySpace = .quickTimeMetadata
    item.key = "com.apple.VoiceMemos.tsrp" as NSString
    item.value = transcript as NSData
    item.dataType = kCMMetadataBaseDataType_RawData as String
    input.metadata = [item]
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    let frames = 4_000
    var block: CMBlockBuffer?
    #expect(
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: frames * 2,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frames * 2,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == noErr
    )
    let buffer = try #require(block)
    #expect(CMBlockBufferFillDataBytes(with: 0, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: frames * 2) == noErr)
    var sample: CMSampleBuffer?
    #expect(
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: buffer,
            formatDescription: try #require(format),
            sampleCount: frames,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sample
        ) == noErr
    )

    while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(input.append(try #require(sample)))
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}
