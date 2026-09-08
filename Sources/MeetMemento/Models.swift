import Foundation

enum CaptureState: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case transcribing
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .starting: return "Starting…"
        case .recording: return "Recording"
        case .stopping: return "Saving…"
        case .transcribing: return "Transcribing…"
        case .failed(let message): return message
        }
    }
}

enum ZoomMeetingState: Equatable {
    case notRunning
    case open
    case inMeeting

    var label: String {
        switch self {
        case .notRunning: return "Zoom is not open"
        case .open: return "Zoom is open"
        case .inMeeting: return "Zoom meeting detected"
        }
    }
}

enum TranscriptionStatus: String, Codable {
    case pending
    case processing
    case complete
    case permissionRequired
    case failed

    var label: String {
        switch self {
        case .pending: return "Waiting"
        case .processing: return "Transcribing"
        case .complete: return "Transcript ready"
        case .permissionRequired: return "Speech access needed"
        case .failed: return "Transcription failed"
        }
    }
}

struct MeetingRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date
    let folderName: String
    var videoFile: String?
    var systemAudioFile: String?
    var microphoneFile: String?
    var combinedAudioFile: String?
    var transcriptFile: String?
    var transcript: String?
    var summaryFile: String?
    var summary: String?
    var transcriptionStatus: TranscriptionStatus
    var errorMessage: String?

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

enum MeetingExportKind: String, CaseIterable, Identifiable {
    case audio
    case video
    case transcript
    case summary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .audio: return "Audio"
        case .video: return "Video"
        case .transcript: return "Transcript"
        case .summary: return "Summary"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: return "waveform"
        case .video: return "video.fill"
        case .transcript: return "text.quote"
        case .summary: return "list.bullet.rectangle"
        }
    }
}

struct TranscriptSegment: Sendable {
    let source: String
    let timestamp: TimeInterval
    let duration: TimeInterval
    let text: String
}

struct PermissionSnapshot: Equatable {
    var screenRecording = false
    var microphone = false
    var speechRecognition = false
    var calendar = false

    var captureReady: Bool { screenRecording }
    var allReady: Bool { screenRecording && microphone && speechRecognition }
}

struct ActiveCapture {
    let id: UUID
    let startedAt: Date
    let folderURL: URL
    let videoURL: URL
    let systemAudioURL: URL
    let microphoneURL: URL?
}
