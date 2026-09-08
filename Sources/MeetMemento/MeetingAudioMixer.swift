import AVFoundation
import Foundation

enum MeetingAudioMixer {
    static func makeFullMeetingAudio(from sourceURLs: [URL], at outputURL: URL) async throws {
        let composition = AVMutableComposition()
        var addedTrack = false

        for sourceURL in sourceURLs where FileManager.default.fileExists(atPath: sourceURL.path) {
            let asset = AVURLAsset(url: sourceURL)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration > .zero,
                  let destinationTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }

            try destinationTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
            addedTrack = true
        }

        guard addedTrack else { throw CaptureError.noAudioReceived }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptureError.writerFailed("This Mac cannot create the full meeting audio file")
        }

        try? FileManager.default.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        await exporter.export()

        switch exporter.status {
        case .completed:
            return
        case .failed, .cancelled:
            throw exporter.error ?? CaptureError.writerFailed("Full meeting audio export failed")
        default:
            throw CaptureError.writerFailed("Full meeting audio export did not complete")
        }
    }
}
