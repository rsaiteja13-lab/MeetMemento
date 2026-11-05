import AVFoundation
import Foundation

enum MeetingMediaCompositionError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

enum MeetingMediaComposer {
    static func synchronizedAsset(videoURL: URL, audioURL: URL?) async throws -> AVAsset {
        let videoAsset = AVURLAsset(url: videoURL)
        guard try await videoAsset.load(.isPlayable) else {
            throw MeetingMediaCompositionError.failed("The meeting video is not playable")
        }
        guard let audioURL else { return videoAsset }

        let audioAsset = AVURLAsset(url: audioURL)
        guard try await audioAsset.load(.isPlayable),
              let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            return videoAsset
        }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        guard videoDuration.isNumeric, videoDuration > .zero,
              audioDuration.isNumeric, audioDuration > .zero else {
            return videoAsset
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MeetingMediaCompositionError.failed("The video and audio tracks could not be combined")
        }

        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideoTrack,
            at: .zero
        )
        videoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        let synchronizedAudioDuration = CMTimeCompare(audioDuration, videoDuration) < 0
            ? audioDuration
            : videoDuration
        try audioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: synchronizedAudioDuration),
            of: sourceAudioTrack,
            at: .zero
        )
        return composition
    }

    static func exportVideoWithAudio(
        videoURL: URL,
        audioURL: URL,
        destinationURL: URL
    ) async throws {
        let asset = try await synchronizedAsset(videoURL: videoURL, audioURL: audioURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MeetingMediaCompositionError.failed("This Mac cannot export the meeting video with audio")
        }
        guard exporter.supportedFileTypes.contains(.mp4) else {
            throw MeetingMediaCompositionError.failed("This recording cannot be exported as an MP4 with audio")
        }

        exporter.outputURL = destinationURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()

        switch exporter.status {
        case .completed:
            return
        case .failed, .cancelled:
            throw exporter.error ?? MeetingMediaCompositionError.failed("Video and audio export failed")
        default:
            throw MeetingMediaCompositionError.failed("Video and audio export did not complete")
        }
    }
}
