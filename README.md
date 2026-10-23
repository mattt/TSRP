# TSRP

TSRP reads the Voice Memos library on macOS.
It lists folders and recordings,
searches recordings by title, folder, and date,
finds their audio files,
and decodes the transcripts that Voice Memos writes into them.

The name comes from `tsrp`,
the key under which Voice Memos stores a transcript in an audio file.

## Requirements

- macOS 15.1+
- Swift 6.1+ (Xcode 16.3+)

Your app needs read access to
`~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`,
through Full Disk Access or a security-scoped bookmark for that folder.
Grant access to the whole folder, not just `CloudRecordings.db`;
SQLite also reads the write-ahead log files next to it,
and the audio files, which hold the transcripts, are in the folder too.

## Installation

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/mattt/TSRP.git", from: "0.1.0")
```

Then add `.product(name: "TSRP", package: "TSRP")` to your target's dependencies.

## Usage

```swift
import TSRP

let store = Store()  // ~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings
try await store.checkAccess()

let result = try await store.search(.init(query: "standup"))
for recording in result.recordings {
    print(recording.id, recording.title ?? "Untitled", recording.date ?? .distantPast)

    guard let file = await store.audioFile(for: recording) else {
        continue  // The audio is only in iCloud.
    }
    print(file.url, file.contentType?.preferredMIMEType ?? "", file.duration ?? 0)

    if file.hasTranscript, let transcript = try await store.transcript(for: recording) {
        print(transcript.text)
        for segment in transcript.segments {
            print(segment.timeRange ?? 0 ... 0, segment.text)
        }
    }
}
```

`search(_:)` returns recordings newest first, 30 at a time by default.
To get the next page, pass the result's `nextCursor` back in the request.
A query matches titles, ignoring case and diacritics.
Recordings in Recently Deleted are left out
unless the request's `scope` is `.recentlyDeleted`.

Voice Memos can keep a recording's audio in iCloud alone,
so `audioFile(for:)` returns `nil` for a recording whose file is not on the Mac.
Recordings made in recent releases are QuickTime audio (`.qta`) files;
older ones are MPEG-4 audio (`.m4a`) files.
TSRP reads transcripts from both.

Each call opens the database read-only and closes it before returning.
TSRP never writes to the database or the audio files, or copies them.

## Development

```sh
swift test
swift format lint --strict --recursive .
```

The tests build synthetic libraries and audio files,
so they don't need access to your recordings.

To check TSRP against your own library, run:

```sh
swift run Validate
```

The tool prints only counts, never titles, folder names, or transcripts.
Your terminal needs Full Disk Access to run it.

The [format notes](Sources/TSRP/TSRP.docc/VoiceMemosLibrary.md)
describe the database and the audio files, and where each fact comes from.

## Acknowledgments

TSRP builds on the work of these projects:

- Thomas Countz's [transcript extractor](https://gist.github.com/Thomascountz/b84b68f0a7c6f2f851ebc5db152b676a):
  where an `.m4a` file keeps its transcript
- jwulff's [apple-voice-memo-mcp](https://github.com/jwulff/apple-voice-memo-mcp):
  the columns that hold titles, dates, and paths, and the transcript JSON
- grapeot's [voice-memos-skill](https://github.com/grapeot/voice-memos-skill):
  how Voice Memos marks recordings in Recently Deleted, and which title column comes first
- karbassi's [apple-voice-memos-cli](https://github.com/karbassi/apple-voice-memos-cli)
  and the [Chronicle plugin for Voice Memos](https://github.com/chronicle-app/chronicle/tree/main/plugins/apple-voice-memos):
  where a `.qta` file keeps its transcript, and transcripts with no speech

## License

TSRP is available under the MIT license.
See the [LICENSE](LICENSE.md) file for more info.
