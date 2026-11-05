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
        case .transcribing: return "Creating transcript…"
        case .failed(let message): return message
        }
    }
}

enum CaptureStartupRecoveryPolicy {
    static let timeout: TimeInterval = 20

    static func shouldRecover(state: CaptureState, elapsed: TimeInterval) -> Bool {
        state == .starting && elapsed >= timeout
    }
}

enum MeetingLifecyclePolicy {
    /// A transient helper/window must survive two polls before it can start a recording.
    static let startConfirmationChecks = 2
    /// Window replacements, system wake, full-screen changes, and minimized calls can
    /// temporarily remove a meeting window from the window list. Twenty one-second
    /// polls are deliberately conservative: saving a few seconds late is safer than
    /// losing the rest of a long meeting.
    static let stopGraceChecks = 20
    /// Do not allow a stopped session to restart until the old meeting is conclusively gone.
    static let endedConfirmationChecks = 12

    static func shouldStart(after consecutiveMeetingChecks: Int) -> Bool {
        consecutiveMeetingChecks >= startConfirmationChecks
    }

    static func shouldStop(after consecutiveMissingChecks: Int) -> Bool {
        consecutiveMissingChecks >= stopGraceChecks
    }

    static func hasConfirmedMeetingEnded(after consecutiveMissingChecks: Int) -> Bool {
        consecutiveMissingChecks >= endedConfirmationChecks
    }
}

enum MeetingState: Equatable {
    case notRunning
    case open
    case inMeeting

    var label: String {
        switch self {
        case .notRunning: return "Ready for meetings"
        case .open: return "Meeting app is open"
        case .inMeeting: return "Meeting detected"
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
        case .pending: return "Transcript queued"
        case .processing: return "Creating transcript"
        case .complete: return "Transcript ready"
        case .permissionRequired: return "Transcript access"
        case .failed: return "No transcript"
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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .audio: return "Audio"
        case .video: return "Video"
        case .transcript: return "Transcript"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: return "waveform"
        case .video: return "video.fill"
        case .transcript: return "text.quote"
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

    func firstMissingRequiredPermission(includeMicrophone: Bool) -> RequiredPermission? {
        if !screenRecording { return .screenRecording }
        if includeMicrophone && !microphone { return .microphone }
        if !speechRecognition { return .speechRecognition }
        return nil
    }
}

enum RequiredPermission: Equatable {
    case screenRecording
    case microphone
    case speechRecognition
}

struct ActiveCapture {
    let id: UUID
    let startedAt: Date
    let folderURL: URL
    let videoURL: URL
    let systemAudioURL: URL
    let microphoneURL: URL?
    var startupWarnings: [String]
}
