import Foundation

struct TrashMoveResult {
    let movedIDs: Set<UUID>
    let failures: [String]
}

@MainActor
final class MeetingLibrary: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []
    let recordingsURL: URL

    init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = applicationSupport.appendingPathComponent("MeetMemento", isDirectory: true)
        let previousAppFolder = applicationSupport.appendingPathComponent("ZoomScribe", isDirectory: true)
        if !FileManager.default.fileExists(atPath: appFolder.path),
           FileManager.default.fileExists(atPath: previousAppFolder.path) {
            try? FileManager.default.moveItem(at: previousAppFolder, to: appFolder)
        }
        recordingsURL = appFolder.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
        reload()
    }

    func makeFolder(startedAt: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = recordingsURL.appendingPathComponent(formatter.string(from: startedAt), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func save(_ meeting: MeetingRecord) throws {
        let folder = recordingsURL.appendingPathComponent(meeting.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder.zoomScribe.encode(meeting)
        try data.write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
        if let transcript = meeting.transcript {
            try transcript.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        }
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: recordingsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        meetings = urls.compactMap { folder in
            let metadata = folder.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadata) else { return nil }
            return try? JSONDecoder.zoomScribe.decode(MeetingRecord.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func folder(for meeting: MeetingRecord) -> URL {
        recordingsURL.appendingPathComponent(meeting.folderName, isDirectory: true)
    }

    func fileURL(for meeting: MeetingRecord, kind: MeetingExportKind) -> URL? {
        let fileName: String?
        switch kind {
        case .audio:
            // System output is the clean playback track. Older recordings may
            // contain a raw system+microphone mix whose speaker bleed sounds like
            // echo, so only fall back to it when no system track is available.
            fileName = meeting.systemAudioFile ?? meeting.combinedAudioFile ?? meeting.microphoneFile
        case .video:
            fileName = meeting.videoFile
        case .transcript:
            fileName = meeting.transcriptFile
        }
        guard let fileName else { return nil }
        let url = folder(for: meeting).appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func moveToTrash(_ meeting: MeetingRecord) throws {
        let recordingFolder = folder(for: meeting)
        guard FileManager.default.fileExists(atPath: recordingFolder.path) else {
            reload()
            return
        }
        try FileManager.default.trashItem(at: recordingFolder, resultingItemURL: nil)
        reload()
    }

    func moveToTrash(_ meetings: [MeetingRecord]) -> TrashMoveResult {
        var movedIDs = Set<UUID>()
        var failures: [String] = []
        var seenIDs = Set<UUID>()

        for meeting in meetings where seenIDs.insert(meeting.id).inserted {
            let recordingFolder = folder(for: meeting)
            guard FileManager.default.fileExists(atPath: recordingFolder.path) else {
                movedIDs.insert(meeting.id)
                continue
            }
            do {
                try FileManager.default.trashItem(at: recordingFolder, resultingItemURL: nil)
                movedIDs.insert(meeting.id)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        reload()
        return TrashMoveResult(movedIDs: movedIDs, failures: failures)
    }
}

private extension JSONEncoder {
    static var zoomScribe: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var zoomScribe: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
