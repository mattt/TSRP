import Foundation
import TSRP

// Checks TSRP against a real Voice Memos library and prints only counts,
// never titles, folder names, or transcript text.
//
// Usage: swift run Validate [path to the Recordings folder]

let root = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Store.defaultRoot
let store = Store(root: root)

do {
    try await store.checkAccess()
} catch {
    print("Can't read \(root.path): \(error.localizedDescription)")
    print("Give your terminal Full Disk Access, or pass the path of a copy of the Recordings folder.")
    exit(1)
}

func all(_ scope: Recording.FetchRequest.Scope) async throws -> [Recording] {
    var recordings: [Recording] = []
    var request = Recording.FetchRequest(scope: scope, limit: 500)
    while true {
        let result = try await store.search(request)
        recordings += result.recordings
        guard let cursor = result.nextCursor else { return recordings }
        request.cursor = cursor
    }
}

let folders = try await store.folders()
let library = try await all(.library)
let deleted = try await all(.recentlyDeleted)
print("Folders: \(folders.count) (\(folders.filter { $0.name == nil }.count) without a name)")
print("Recordings: \(library.count) in the library, \(deleted.count) in Recently Deleted")
print("  without a title: \(library.filter { $0.title == nil }.count)")
print("  without a date: \(library.filter { $0.date == nil }.count)")
print("  in a folder: \(library.filter { $0.folder != nil }.count)")

struct Counts {
    var files = 0
    var transcripts = 0
    var decoded = 0
    var empty = 0
    var withTimes = 0
    var failures: [String: Int] = [:]
    var durationMismatches = 0
}

var counts: [String: Counts] = [:]
var missing = 0
for recording in library {
    guard let file = await store.audioFile(for: recording) else {
        missing += 1
        continue
    }
    let type = file.url.pathExtension.lowercased()
    counts[type, default: Counts()].files += 1
    if let duration = recording.duration, let fileDuration = file.duration, abs(duration - fileDuration) > 1 {
        counts[type, default: Counts()].durationMismatches += 1
    }
    guard file.hasTranscript else { continue }
    counts[type, default: Counts()].transcripts += 1
    do {
        guard let transcript = try await store.transcript(for: recording) else { continue }
        counts[type, default: Counts()].decoded += 1
        if transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            counts[type, default: Counts()].empty += 1
        }
        if transcript.segments.contains(where: { $0.timeRange != nil }) {
            counts[type, default: Counts()].withTimes += 1
        }
    } catch {
        counts[type, default: Counts()].failures[String(describing: error), default: 0] += 1
    }
}

print("Audio files not on this Mac: \(missing)")
for (type, count) in counts.sorted(by: { $0.key < $1.key }) {
    print(".\(type): \(count.files) files, \(count.transcripts) with a transcript")
    print("  decoded: \(count.decoded) (\(count.empty) empty, \(count.withTimes) with time ranges)")
    print("  durations that differ from the database by more than 1 second: \(count.durationMismatches)")
    for (failure, number) in count.failures.sorted(by: { $0.key < $1.key }) {
        print("  failed to decode (\(failure)): \(number)")
    }
}
