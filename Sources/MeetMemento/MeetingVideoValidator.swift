import AVFoundation
import Foundation

struct MeetingVideoValidation: Sendable {
    let isPlayable: Bool
    let duration: TimeInterval
    let warning: String?
}

enum MeetingVideoValidator {
    static func validate(url: URL, expectedDuration: TimeInterval) async -> MeetingVideoValidation {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return MeetingVideoValidation(
                isPlayable: false,
                duration: 0,
                warning: "The meeting video wasn’t saved. The audio and transcript are still available."
            )
        }

        do {
            let asset = AVURLAsset(url: url)
            async let playable = asset.load(.isPlayable)
            async let durationValue = asset.load(.duration)
            async let videoTracks = asset.loadTracks(withMediaType: .video)
            let (isPlayable, duration, tracks) = try await (playable, durationValue, videoTracks)
            let seconds = duration.isNumeric ? duration.seconds : 0

            guard isPlayable, !tracks.isEmpty, seconds.isFinite, seconds > 0.5 else {
                return MeetingVideoValidation(
                    isPlayable: false,
                    duration: max(0, seconds),
                    warning: "The meeting video wasn’t saved correctly and can’t be played. The audio and transcript are still available."
                )
            }

            // Allow for the normal delay between meeting detection and the first
            // ScreenCaptureKit frame, but flag a recorder that stopped materially
            // before the meeting ended.
            let allowedDifference = max(15, min(60, expectedDuration * 0.08))
            let substantiallyShort = expectedDuration >= 30 && seconds + allowedDifference < expectedDuration
            return MeetingVideoValidation(
                isPlayable: true,
                duration: seconds,
                warning: substantiallyShort
                    ? "The meeting video ended early. The full audio and transcript are available."
                    : nil
            )
        } catch {
            return MeetingVideoValidation(
                isPlayable: false,
                duration: 0,
                warning: "The meeting video wasn’t saved correctly and can’t be played. The audio and transcript are still available."
            )
        }
    }
}
