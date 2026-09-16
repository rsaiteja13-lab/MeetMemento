import AVFoundation
import Foundation

struct AudioChunk: Sendable {
    let url: URL
    let offset: TimeInterval
    let isTemporary: Bool
}

enum AudioChunker {
    private static let chunkDuration: TimeInterval = 50

    static func makeChunks(from sourceURL: URL) async throws -> [AudioChunk] {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > chunkDuration else {
            return [AudioChunk(url: sourceURL, offset: 0, isTemporary: false)]
        }

        let temporaryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetMemento-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)

        var chunks: [AudioChunk] = []
        var offset: TimeInterval = 0
        do {
            while offset < duration {
                let length = min(chunkDuration, duration - offset)
                let destination = temporaryFolder.appendingPathComponent(String(format: "chunk-%05.0f.m4a", offset))
                try await export(
                    asset: asset,
                    to: destination,
                    range: CMTimeRange(
                        start: CMTime(seconds: offset, preferredTimescale: 600),
                        duration: CMTime(seconds: length, preferredTimescale: 600)
                    )
                )
                chunks.append(AudioChunk(url: destination, offset: offset, isTemporary: true))
                offset += length
            }
            return chunks
        } catch {
            try? FileManager.default.removeItem(at: temporaryFolder)
            throw error
        }
    }

    static func removeTemporaryChunks(_ chunks: [AudioChunk]) {
        guard let folder = chunks.first(where: \.isTemporary)?.url.deletingLastPathComponent() else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func export(asset: AVAsset, to destination: URL, range: CMTimeRange) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptureError.writerFailed("This audio format can’t be prepared for a transcript")
        }
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.timeRange = range
        await exporter.export()
        switch exporter.status {
        case .completed:
            return
        case .failed, .cancelled:
            throw exporter.error ?? CaptureError.writerFailed("Audio couldn’t be prepared for a transcript")
        default:
            throw CaptureError.writerFailed("Audio preparation didn’t finish")
        }
    }
}
