# The Voice Memos Library

How Voice Memos stores recordings and transcripts on macOS, and where each fact comes from.

## Overview

Voice Memos keeps its library in the `Recordings` folder of its group container,
`~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`.
The folder holds a Core Data SQLite database, `CloudRecordings.db`,
and the audio file of each recording that is on the Mac.

Apple doesn't document any of this.
The facts below come from the Core Data model in macOS,
from the Voice Memos framework, and from other projects,
as each section says.

### The database

The Core Data model is `VoiceMemos.momd` in the private `VoiceMemos.framework`
(`/System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework`).
Its current version, `VoiceMemos14`, has these entities:

| Entity | Class | Table |
| --- | --- | --- |
| `CloudRecording` | `RCCloudRecording` | `ZCLOUDRECORDING` |
| `Folder` | `RCRecordingsFolder` | `ZFOLDER` |

Every attribute is optional in the model.
TSRP reads these columns of `ZCLOUDRECORDING`:

| Column | Type | Meaning |
| --- | --- | --- |
| `Z_PK` | Integer | The primary key, which TSRP uses as the identifier |
| `ZUNIQUEID` | String | The identifier of the recording on every device |
| `ZENCRYPTEDTITLE` | String | The title, in plain text in the local database |
| `ZCUSTOMLABEL` | String | An older title, which can hold a date in place of one |
| `ZDATE` | Date | When the recording was made |
| `ZDURATION` | Double | The length, in seconds |
| `ZPATH` | String | The audio file, usually a name in the `Recordings` folder |
| `ZEVICTIONDATE` | Date | When the recording moved to Recently Deleted |
| `ZFOLDER` | Integer | The folder, a `Z_PK` of `ZFOLDER` |

Dates are seconds since 2001-01-01, as Core Data stores them.
`ZFOLDER` has `ZENCRYPTEDNAME`, the folder's name in plain text, and `ZRANK`, its position.
The built-in folders of Voice Memos, Favorites, Recently Deleted, and Captured on Watch,
are not rows of `ZFOLDER`.

The Voice Memos framework selects deleted recordings by `evictionDate != nil`,
as grapeot's [voice-memos-skill](https://github.com/grapeot/voice-memos-skill) found.
The same project found that `customLabel` can hold a date
when `encryptedTitle` holds the title, so TSRP prefers the title.

### The audio files

Recordings are MPEG-4 audio (`.m4a`) files or, in recent releases, QuickTime audio (`.qta`) files.
macOS declares their types as `com.apple.m4a-audio` (`audio/x-m4a`)
and `com.apple.quicktime-audio` (`audio/x-quicktime`).
Voice Memos can keep a recording's audio in iCloud alone,
which leaves no file or an empty one.

### Transcripts

Voice Memos writes a recording's transcript into its audio file, as track metadata.
The framework's `transcriptionIdentifier` function chooses the metadata identifier:
the key `tsrp` in the QuickTime user data key space for an `.m4a` file,
and the key `com.apple.VoiceMemos.tsrp` in the QuickTime metadata key space for a `.qta` file
(from a [decompiled framework](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/main/System/Library/PrivateFrameworks/VoiceMemos.framework/VoiceMemos.m)
of iOS 18.2).
In the file, these are:

- In an `.m4a` file, a `tsrp` atom in the track's user data,
  at `moov/trak/udta/tsrp` or `moov/trak/mdia/udta/tsrp`.
  Its payload is the JSON.
- In a `.qta` file, an item in the track's QuickTime metadata, `moov/trak/meta`.
  The `keys` atom lists `com.apple.VoiceMemos.tsrp` in the `mdta` namespace,
  and the `ilst` item whose type is that key's 1-based index holds a `data` atom.
  The JSON follows the `data` atom's type indicator and locale.

The JSON has two members.
`attributedString` is an `AttributedString` in its `Codable` encoding,
where each run of text, usually one word, has a `timeRange` attribute.
Foundation writes the runs either with their attributes inline
or with an `attributeTable` that the runs index;
a transcript with no speech is an empty string.
`locale` is a `Locale` in its `Codable` encoding.

A `timeRange` is a start and an end in seconds, not a start and a duration.
The framework's `RCTimeRange` functions compute a duration as the end minus the start,
and its `CMTimeRangeFromRCTimeRange` function makes the duration of a `CMTimeRange` the same way.
