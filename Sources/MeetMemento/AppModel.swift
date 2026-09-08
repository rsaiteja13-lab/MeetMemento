import AppKit
import Combine
import Foundation
import ScreenCaptureKit
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var captureState: CaptureState = .idle
    @Published var zoomState: ZoomMeetingState = .notRunning
    @Published var permissions = PermissionSnapshot()
    @Published var activeCapture: ActiveCapture?
    @Published var selectedMeetingID: UUID?
    @Published var statusMessage: String?

    let settings = AppSettings()
    let library = MeetingLibrary()
    let transcriber = SpeechTranscriber()
    private let calendarMatcher = CalendarEventMatcher()

    private let detector = ZoomMeetingDetector()
    private let captureController = MeetingCaptureController()
    private var detectorTimer: Timer?
    private var started = false
    private var missedMeetingChecks = 0
    private var suppressAutomaticRecordingUntilMeetingEnds = false
    private var activeMeetingTitle: String?

    var canStartRecording: Bool {
        activeCapture == nil && captureState != .starting && captureState != .stopping && captureState != .transcribing
    }

    var capturePermissionsReady: Bool {
        permissions.screenRecording
    }

    func start() {
        guard !started else { return }
        started = true
        refreshPermissions()
        refreshZoomState()
        // A one-second check catches brief calls and Zoom helper processes that
        // may exist for only a few seconds during short test meetings.
        detectorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshZoomState() }
        }
        if settings.consentAcknowledged {
            settings.applyLoginItemPreference()
        }
    }

    func completeOnboarding() async {
        settings.consentAcknowledged = true
        _ = Permissions.requestScreenRecording()
        settings.screenPermissionPromptAttempted = true
        settings.screenPermissionConfigured = true
        settings.applyLoginItemPreference()
        refreshPermissions()
    }

    func requestScreenRecordingAccess() {
        if settings.screenPermissionPromptAttempted {
            Permissions.openPrivacySettings(.screenCapture)
        } else {
            _ = Permissions.requestScreenRecording()
            settings.screenPermissionPromptAttempted = true
        }
        settings.screenPermissionConfigured = true
        refreshPermissions()
    }

    func requestMicrophoneAccess() async {
        let granted = await Permissions.requestMicrophone()
        permissions.microphone = granted
        if !granted {
            statusMessage = "Microphone access is needed to include your voice in meeting audio."
            Permissions.openPrivacySettings(.microphone)
        }
    }

    func requestSpeechAccess() async {
        let granted = await Permissions.requestSpeechRecognition()
        permissions.speechRecognition = granted
        if !granted {
            statusMessage = "Allow Speech Recognition in System Settings to create transcripts and summaries."
            Permissions.openPrivacySettings(.speechRecognition)
        }
    }

    func requestCalendarAccess() async {
        let granted = await Permissions.requestCalendar()
        permissions.calendar = granted
        if !granted {
            statusMessage = "Calendar access is optional. Without it, MeetMemento will name meetings from their transcript."
            Permissions.openPrivacySettings(.calendar)
        }
    }

    func refreshPermissions() {
        // Always trust macOS for the current executable. A persisted setup flag
        // can outlive a rebuilt or replaced app and otherwise report a stale
        // permission as granted, causing an automatic recording to fail silently.
        permissions = Permissions.snapshot()
    }

    func refreshZoomState() {
        zoomState = detector.currentState()

        if zoomState == .inMeeting {
            missedMeetingChecks = 0
            if settings.autoRecord,
               settings.consentAcknowledged,
               !capturePermissionsReady,
               activeCapture == nil {
                captureState = .failed("Screen Recording access needed")
                statusMessage = "Open System Settings and allow MeetMemento under Privacy & Security → Screen & System Audio Recording, then quit and reopen MeetMemento."
            } else if settings.autoRecord,
               settings.consentAcknowledged,
               capturePermissionsReady,
               !suppressAutomaticRecordingUntilMeetingEnds,
               canStartRecording {
                Task { await startRecording(triggeredAutomatically: true) }
            }
        } else {
            suppressAutomaticRecordingUntilMeetingEnds = false
            if captureState == .failed("Screen Recording access needed") {
                captureState = .idle
                statusMessage = nil
            }
            if captureState == .recording {
                // A short grace period avoids splitting a recording while Zoom rearranges windows.
                missedMeetingChecks += 1
                if missedMeetingChecks >= 3 {
                    Task { await stopRecording() }
                }
            }
        }
    }

    func startRecording(triggeredAutomatically: Bool = false) async {
        guard canStartRecording else { return }
        guard settings.consentAcknowledged else {
            statusMessage = "Acknowledge the recording consent reminder first."
            return
        }
        guard permissions.screenRecording else {
            captureState = .failed("Screen Recording access needed")
            return
        }
        captureState = .starting
        statusMessage = nil
        let startedAt = Date()
        activeMeetingTitle = calendarMatcher.title(forMeetingAt: startedAt)
        var captureFolder: URL?
        do {
            let folder = try library.makeFolder(startedAt: startedAt)
            captureFolder = folder
            let capture = try await captureController.start(
                in: folder,
                includeMicrophone: settings.includeMicrophone && permissions.microphone
            )
            activeCapture = capture
            settings.screenPermissionConfigured = true
            selectedMeetingID = nil
            captureState = .recording
            if triggeredAutomatically {
                notify(title: "Zoom recording started", body: "Confirm that everyone in the meeting has consented.")
            }
        } catch {
            if let captureFolder {
                try? FileManager.default.removeItem(at: captureFolder)
            }
            activeMeetingTitle = nil
            captureState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
            if isScreenPermissionError(error) {
                settings.screenPermissionConfigured = false
                permissions.screenRecording = false
            }
        }
    }

    func stopRecording() async {
        guard let capture = activeCapture else { return }
        if zoomState == .inMeeting {
            suppressAutomaticRecordingUntilMeetingEnds = true
        }
        captureState = .stopping
        let errors = await captureController.stop()
        let endedAt = Date()
        let videoExists = FileManager.default.fileExists(atPath: capture.videoURL.path)
        let systemAudioExists = FileManager.default.fileExists(atPath: capture.systemAudioURL.path)
        let microphoneExists = capture.microphoneURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        var combinedAudioFile: String?
        var saveErrors = errors.compactMap { error -> String? in
            if microphoneExists,
               let captureError = error as? CaptureError,
               case .noAudioReceived = captureError {
                return nil
            }
            return error.localizedDescription
        }
        if systemAudioExists && !microphoneExists {
            combinedAudioFile = capture.systemAudioURL.lastPathComponent
        } else if systemAudioExists || microphoneExists {
            let fullAudioURL = capture.folderURL.appendingPathComponent("full-meeting-audio.m4a")
            let sources = [
                systemAudioExists ? capture.systemAudioURL : nil,
                microphoneExists ? capture.microphoneURL : nil
            ].compactMap { $0 }
            do {
                try await MeetingAudioMixer.makeFullMeetingAudio(from: sources, at: fullAudioURL)
                combinedAudioFile = fullAudioURL.lastPathComponent
            } catch {
                saveErrors.append("Full meeting audio: \(error.localizedDescription)")
            }
        }

        var meeting = MeetingRecord(
            id: capture.id,
            title: activeMeetingTitle ?? "Zoom meeting",
            startedAt: capture.startedAt,
            endedAt: endedAt,
            folderName: capture.folderURL.lastPathComponent,
            videoFile: videoExists ? capture.videoURL.lastPathComponent : nil,
            systemAudioFile: systemAudioExists ? capture.systemAudioURL.lastPathComponent : nil,
            microphoneFile: microphoneExists ? capture.microphoneURL?.lastPathComponent : nil,
            combinedAudioFile: combinedAudioFile,
            transcriptFile: nil,
            transcript: nil,
            summaryFile: nil,
            summary: nil,
            transcriptionStatus: permissions.speechRecognition ? .pending : .permissionRequired,
            errorMessage: saveErrors.isEmpty ? nil : saveErrors.joined(separator: "\n")
        )

        activeCapture = nil
        activeMeetingTitle = nil
        missedMeetingChecks = 0
        do { try library.save(meeting) }
        catch { statusMessage = "Recording was saved, but its library entry failed: \(error.localizedDescription)" }
        selectedMeetingID = meeting.id

        if permissions.speechRecognition {
            captureState = .transcribing
            meeting = await transcribe(meeting)
        }
        captureState = .idle
        notify(title: "Zoom recording saved", body: meeting.transcriptionStatus == .complete ? "Your video, audio, transcript, and summary are ready." : "Your available video and audio files were saved.")
    }

    func retryTranscription(for meeting: MeetingRecord) async {
        guard captureState == .idle else { return }
        refreshPermissions()
        guard permissions.speechRecognition else {
            statusMessage = "Speech Recognition access is needed to create a transcript."
            return
        }
        captureState = .transcribing
        _ = await transcribe(meeting)
        captureState = .idle
    }

    func requestSpeechAndRetry(for meeting: MeetingRecord) async {
        if !permissions.speechRecognition {
            await requestSpeechAccess()
        }
        guard permissions.speechRecognition else { return }
        await retryTranscription(for: meeting)
    }

    func ensureSummary(for original: MeetingRecord) {
        guard original.summary == nil,
              let transcript = original.transcript,
              !transcript.isEmpty else { return }
        let summary = MeetingSummarizer.summarize(transcript)
        guard !summary.isEmpty else { return }
        var meeting = original
        meeting.summary = summary
        meeting.summaryFile = "summary.txt"
        do { try library.save(meeting) }
        catch { statusMessage = "The summary could not be saved: \(error.localizedDescription)" }
    }

    func download(_ kind: MeetingExportKind, for meeting: MeetingRecord) {
        guard let sourceURL = library.fileURL(for: meeting, kind: kind) else {
            statusMessage = "The \(kind.label.lowercased()) file is not available for this recording."
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let panel = NSSavePanel()
        panel.title = "Download Meeting \(kind.label)"
        panel.prompt = "Download"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "MeetMemento-\(formatter.string(from: meeting.startedAt))-\(kind.rawValue).\(sourceURL.pathExtension)"
        panel.begin { [weak self] response in
            guard response == .OK, let destinationURL = panel.url else { return }
            Task { @MainActor [weak self] in
                do {
                    if destinationURL.standardizedFileURL != sourceURL.standardizedFileURL,
                       FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    if destinationURL.standardizedFileURL != sourceURL.standardizedFileURL {
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    }
                    self?.statusMessage = "\(kind.label) downloaded."
                } catch {
                    self?.statusMessage = "The \(kind.label.lowercased()) could not be downloaded: \(error.localizedDescription)"
                }
            }
        }
    }

    func showInFinder(_ meeting: MeetingRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: meeting)])
    }

    func openRecordingsFolder() {
        NSWorkspace.shared.open(library.recordingsURL)
    }

    func openTrash() {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        NSWorkspace.shared.open(trashURL)
    }

    func rename(_ meeting: MeetingRecord, to proposedTitle: String) {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            statusMessage = "Enter a name for this recording."
            return
        }
        var updatedMeeting = meeting
        updatedMeeting.title = String(title.prefix(120))
        do {
            try library.save(updatedMeeting)
            statusMessage = "Recording renamed."
        } catch {
            statusMessage = "The recording could not be renamed: \(error.localizedDescription)"
        }
    }

    func moveToTrash(_ meeting: MeetingRecord) {
        guard captureState == .idle else {
            statusMessage = "Wait for the current recording or transcription to finish before deleting."
            return
        }
        do {
            try library.moveToTrash(meeting)
            if selectedMeetingID == meeting.id {
                selectedMeetingID = nil
            }
            statusMessage = "Recording moved to Trash. Open Recently Deleted in the sidebar to recover it."
        } catch {
            statusMessage = "The recording could not be moved to Trash: \(error.localizedDescription)"
        }
    }

    func exportAll(for meeting: MeetingRecord) {
        let panel = NSOpenPanel()
        panel.title = "Export Complete Meeting"
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the audio, video, transcript, summary, and recording details."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let destinationDirectory = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd_HH-mm"
                let baseName = "MeetMemento-\(formatter.string(from: meeting.startedAt))-\(self.safeFileName(meeting.title))"
                let destination = self.availableDestination(named: baseName, in: destinationDirectory)
                do {
                    try FileManager.default.copyItem(at: self.library.folder(for: meeting), to: destination)
                    self.statusMessage = "Complete meeting exported."
                } catch {
                    self.statusMessage = "The complete meeting could not be exported: \(error.localizedDescription)"
                }
            }
        }
    }

    func copyText(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "\(label) copied."
    }

    private func transcribe(_ original: MeetingRecord) async -> MeetingRecord {
        var meeting = original
        meeting.transcriptionStatus = .processing
        meeting.errorMessage = nil
        try? library.save(meeting)

        let folder = library.folder(for: meeting)
        var segments: [TranscriptSegment] = []
        var failures: [String] = []

        if let file = meeting.systemAudioFile {
            do {
                segments += try await transcribeTrack(fileURL: folder.appendingPathComponent(file), source: "Meeting")
            } catch { failures.append("Meeting audio: \(error.localizedDescription)") }
        }
        if let file = meeting.microphoneFile {
            do {
                segments += try await transcribeTrack(fileURL: folder.appendingPathComponent(file), source: "You")
            } catch { failures.append("Microphone: \(error.localizedDescription)") }
        }

        if segments.isEmpty {
            meeting.transcriptionStatus = .failed
            meeting.errorMessage = failures.joined(separator: "\n")
        } else {
            meeting.transcript = TranscriptFormatter.format(segments)
            meeting.transcriptFile = "transcript.txt"
            if meeting.title == "Zoom meeting",
               let discussionTitle = MeetingNamer.title(from: meeting.transcript ?? "") {
                meeting.title = discussionTitle
            }
            let summary = MeetingSummarizer.summarize(meeting.transcript ?? "")
            meeting.summary = summary.isEmpty ? nil : summary
            meeting.summaryFile = summary.isEmpty ? nil : "summary.txt"
            meeting.transcriptionStatus = .complete
            meeting.errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
        do { try library.save(meeting) }
        catch { statusMessage = "Transcript completed but could not be saved: \(error.localizedDescription)" }
        return meeting
    }

    private func transcribeTrack(fileURL: URL, source: String) async throws -> [TranscriptSegment] {
        let chunks = try await AudioChunker.makeChunks(from: fileURL)
        defer { AudioChunker.removeTemporaryChunks(chunks) }
        var combined: [TranscriptSegment] = []
        var firstMeaningfulError: Error?

        for chunk in chunks {
            do {
                let chunkSegments = try await transcriber.transcribe(fileURL: chunk.url, source: source)
                combined += chunkSegments.map {
                    TranscriptSegment(
                        source: $0.source,
                        timestamp: $0.timestamp + chunk.offset,
                        duration: $0.duration,
                        text: $0.text
                    )
                }
            } catch TranscriptionError.noSpeech {
                continue
            } catch {
                if firstMeaningfulError == nil { firstMeaningfulError = error }
            }
        }

        if combined.isEmpty {
            throw firstMeaningfulError ?? TranscriptionError.noSpeech
        }
        return combined
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func isScreenPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == -3801
    }

    private func safeFileName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Zoom-meeting" : cleaned).prefix(60))
    }

    private func availableDestination(named baseName: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

}
