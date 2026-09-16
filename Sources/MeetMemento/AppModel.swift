import AppKit
import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import UserNotifications

enum PermissionSetupPhase: Equatable {
    case ready
    case microphone
    case speechRecognition
    case calendar
    case screenRecording
    case needsSystemSettings
    case complete
}

@MainActor
final class AppModel: ObservableObject {
    @Published var captureState: CaptureState = .idle
    @Published var zoomState: ZoomMeetingState = .notRunning
    @Published var permissions = PermissionSnapshot()
    @Published var activeCapture: ActiveCapture?
    @Published var selectedMeetingID: UUID?
    @Published var statusMessage: String?
    @Published var permissionSetupPhase: PermissionSetupPhase = .ready

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
    private var activeRecordingWasTriggeredAutomatically = false
    private var didAuditSavedVideos = false

    var canStartRecording: Bool {
        activeCapture == nil && captureState != .starting && captureState != .stopping && captureState != .transcribing
    }

    var capturePermissionsReady: Bool {
        permissions.screenRecording
    }

    var essentialPermissionsReady: Bool {
        permissions.screenRecording
            && (!settings.includeMicrophone || permissions.microphone)
            && permissions.speechRecognition
    }

    func start() {
        guard !started else { return }
        started = true
        refreshPermissions()
        finishPermissionSetupIfReady()
        refreshZoomState()
        // A one-second check catches brief calls and Zoom helper processes that
        // may exist for only a few seconds during short test meetings.
        detectorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshZoomState() }
        }
        if settings.consentAcknowledged {
            settings.applyLoginItemPreference()
        }
        if !didAuditSavedVideos {
            didAuditSavedVideos = true
            Task {
                await recoverInterruptedRecordings()
                await auditSavedVideos()
            }
        }
    }

    func completeOnboarding() async {
        guard permissionSetupPhase == .ready || permissionSetupPhase == .needsSystemSettings else { return }
        settings.consentAcknowledged = true

        // Request permissions that can display normal macOS consent sheets
        // first. Screen Recording is last because macOS may send the user to
        // System Settings and require the app to be reopened.
        permissionSetupPhase = .microphone
        if settings.includeMicrophone {
            permissions.microphone = await Permissions.requestMicrophone()
        }

        permissionSetupPhase = .speechRecognition
        permissions.speechRecognition = await Permissions.requestSpeechRecognition()

        permissionSetupPhase = .calendar
        permissions.calendar = await Permissions.requestCalendar()

        permissionSetupPhase = .screenRecording
        permissions.screenRecording = Permissions.requestScreenRecording()
        settings.screenPermissionPromptAttempted = true
        settings.screenPermissionConfigured = true
        settings.applyLoginItemPreference()
        refreshPermissions()

        if essentialPermissionsReady {
            settings.onboardingCompleted = true
            permissionSetupPhase = .complete
            statusMessage = nil
        } else {
            permissionSetupPhase = .needsSystemSettings
            statusMessage = missingPermissionMessage
            openFirstMissingRequiredPermission()
        }
    }

    func finishPermissionSetupIfReady() {
        guard settings.consentAcknowledged, essentialPermissionsReady else { return }
        settings.onboardingCompleted = true
        permissionSetupPhase = .complete
        statusMessage = nil
    }

    func openFirstMissingRequiredPermission() {
        if !permissions.screenRecording {
            Permissions.openPrivacySettings(.screenCapture)
        } else if settings.includeMicrophone && !permissions.microphone {
            Permissions.openPrivacySettings(.microphone)
        } else if !permissions.speechRecognition {
            Permissions.openPrivacySettings(.speechRecognition)
        }
    }

    var missingPermissionMessage: String {
        if !permissions.screenRecording {
            return "Allow MeetMemento under Screen & System Audio Recording, then return here."
        }
        if settings.includeMicrophone && !permissions.microphone {
            return "Allow MeetMemento to use the microphone, then return here."
        }
        if !permissions.speechRecognition {
            return "Allow MeetMemento under Speech Recognition, then return here."
        }
        return "MeetMemento is ready."
    }

    func requestScreenRecordingAccess() {
        // The persisted "prompt attempted" flag can outlive a replaced build or
        // a manually reset TCC record. Always ask macOS for the current signed
        // executable; macOS itself suppresses duplicate prompts after a decision.
        let granted = Permissions.requestScreenRecording()
        settings.screenPermissionPromptAttempted = true
        settings.screenPermissionConfigured = true
        refreshPermissions()
        if !granted && !permissions.screenRecording {
            Permissions.openPrivacySettings(.screenCapture)
        }
    }

    func requestMicrophoneAccess() async {
        let granted = await Permissions.requestMicrophone()
        permissions.microphone = granted
        if !granted {
            statusMessage = "Allow microphone access to include your voice in meeting audio."
            Permissions.openPrivacySettings(.microphone)
        }
    }

    func requestSpeechAccess() async {
        let granted = await Permissions.requestSpeechRecognition()
        permissions.speechRecognition = granted
        if !granted {
            statusMessage = "Allow Speech Recognition to create transcripts."
            Permissions.openPrivacySettings(.speechRecognition)
        }
    }

    func requestCalendarAccess() async {
        let granted = await Permissions.requestCalendar()
        permissions.calendar = granted
        if !granted {
            statusMessage = "Calendar access is optional. Without it, MeetMemento creates meeting names from the transcript."
            Permissions.openPrivacySettings(.calendar)
        }
    }

    func refreshPermissions() {
        // Always trust macOS for the current executable. A persisted setup flag
        // can outlive a rebuilt or replaced app and otherwise report a stale
        // permission as granted, causing an automatic recording to fail silently.
        permissions = Permissions.snapshot()
        finishPermissionSetupIfReady()
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
                statusMessage = "Allow MeetMemento under Privacy & Security → Screen & System Audio Recording, then reopen the app."
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
            if captureState == .recording, activeRecordingWasTriggeredAutomatically {
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
            statusMessage = "Confirm the recording consent reminder before starting."
            return
        }
        refreshPermissions()
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
            var capture = try await captureController.start(
                in: folder,
                includeMicrophone: settings.includeMicrophone && permissions.microphone
            )
            if settings.includeMicrophone && !permissions.microphone {
                capture.startupWarnings.append(
                    "Microphone access is not currently granted, so your voice was not captured separately."
                )
            }
            activeCapture = capture
            activeRecordingWasTriggeredAutomatically = triggeredAutomatically
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
            activeRecordingWasTriggeredAutomatically = false
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
        let videoValidation = await MeetingVideoValidator.validate(
            url: capture.videoURL,
            expectedDuration: endedAt.timeIntervalSince(capture.startedAt)
        )
        let systemAudioDuration = await mediaDuration(of: capture.systemAudioURL)
        let microphoneDuration: TimeInterval
        if let microphoneURL = capture.microphoneURL {
            microphoneDuration = await mediaDuration(of: microphoneURL)
        } else {
            microphoneDuration = 0
        }
        let systemAudioExists = systemAudioDuration > 0.5
        let microphoneExists = microphoneDuration > 0.5

        var combinedAudioFile: String?
        var saveErrors = capture.startupWarnings + errors.compactMap { error -> String? in
            if microphoneExists,
               let captureError = error as? CaptureError,
               case .noAudioReceived = captureError {
                return nil
            }
            return error.localizedDescription
        }
        if let videoWarning = videoValidation.warning,
           !saveErrors.contains(videoWarning) {
            saveErrors.append(videoWarning)
        }
        if !systemAudioExists,
           !saveErrors.contains(where: { $0.localizedCaseInsensitiveContains("meeting audio") }) {
            saveErrors.append("Meeting audio wasn’t captured or couldn’t be saved.")
        }
        if capture.microphoneURL != nil,
           !microphoneExists,
           !saveErrors.contains(where: { $0.localizedCaseInsensitiveContains("microphone") }) {
            saveErrors.append("Microphone capture started but did not produce a playable audio track.")
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
            videoFile: videoValidation.isPlayable ? capture.videoURL.lastPathComponent : nil,
            systemAudioFile: systemAudioExists ? capture.systemAudioURL.lastPathComponent : nil,
            microphoneFile: microphoneExists ? capture.microphoneURL?.lastPathComponent : nil,
            combinedAudioFile: combinedAudioFile,
            transcriptFile: nil,
            transcript: nil,
            transcriptionStatus: permissions.speechRecognition ? .pending : .permissionRequired,
            errorMessage: saveErrors.isEmpty ? nil : saveErrors.joined(separator: "\n")
        )

        activeCapture = nil
        activeMeetingTitle = nil
        activeRecordingWasTriggeredAutomatically = false
        missedMeetingChecks = 0
        do { try library.save(meeting) }
        catch { statusMessage = "The recording was saved, but MeetMemento couldn’t add it to your library: \(error.localizedDescription)" }
        selectedMeetingID = meeting.id

        if permissions.speechRecognition {
            captureState = .transcribing
            meeting = await transcribe(meeting)
        }
        captureState = .idle
        let readyItems = [
            meeting.videoFile == nil ? nil : "video",
            meeting.combinedAudioFile == nil ? nil : "audio",
            meeting.transcriptFile == nil ? nil : "transcript"
        ].compactMap { $0 }
        notify(
            title: "Zoom recording saved",
            body: readyItems.isEmpty
                ? "Some recording files need attention. Open MeetMemento for details."
                : "Your \(readyItems.joined(separator: ", ")) \(readyItems.count == 1 ? "is" : "are") ready."
        )
    }

    func retryTranscription(for meeting: MeetingRecord) async {
        guard captureState == .idle else { return }
        refreshPermissions()
        guard permissions.speechRecognition else {
            statusMessage = "Allow Speech Recognition to create a transcript."
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

    func download(_ kind: MeetingExportKind, for meeting: MeetingRecord) {
        guard let sourceURL = library.fileURL(for: meeting, kind: kind) else {
            statusMessage = "The \(kind.label.lowercased()) file is not available for this recording."
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let panel = NSSavePanel()
        panel.title = "Save Meeting \(kind.label)"
        panel.prompt = "Save"
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
                    self?.statusMessage = "\(kind.label) saved."
                } catch {
                    self?.statusMessage = "The \(kind.label.lowercased()) couldn’t be saved: \(error.localizedDescription)"
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
            statusMessage = "Enter a name for this meeting."
            return
        }
        var updatedMeeting = meeting
        updatedMeeting.title = String(title.prefix(120))
        do {
            try library.save(updatedMeeting)
            statusMessage = "Meeting renamed."
        } catch {
            statusMessage = "The meeting couldn’t be renamed: \(error.localizedDescription)"
        }
    }

    func moveToTrash(_ meeting: MeetingRecord) {
        guard captureState == .idle else {
            statusMessage = "Wait until recording and transcription finish before deleting this meeting."
            return
        }
        do {
            try library.moveToTrash(meeting)
            if selectedMeetingID == meeting.id {
                selectedMeetingID = nil
            }
            statusMessage = "Meeting moved to Trash. Open Recently Deleted in the sidebar to recover it."
        } catch {
            statusMessage = "The meeting couldn’t be moved to Trash: \(error.localizedDescription)"
        }
    }

    func exportAll(for meeting: MeetingRecord) {
        let panel = NSOpenPanel()
        panel.title = "Export All Meeting Files"
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the audio, video, transcript, and recording details."
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
                    self.statusMessage = "Meeting files exported."
                } catch {
                    self.statusMessage = "The meeting files couldn’t be exported: \(error.localizedDescription)"
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
        let recordingErrors = meeting.errorMessage.map { [$0] } ?? []
        meeting.transcriptionStatus = .processing
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
            meeting.errorMessage = (recordingErrors + failures).joined(separator: "\n")
        } else {
            meeting.transcript = TranscriptFormatter.format(segments)
            meeting.transcriptFile = "transcript.txt"
            if meeting.title == "Zoom meeting",
               let discussionTitle = MeetingNamer.title(from: meeting.transcript ?? "") {
                meeting.title = discussionTitle
            }
            meeting.transcriptionStatus = .complete
            let allErrors = recordingErrors + failures
            meeting.errorMessage = allErrors.isEmpty ? nil : allErrors.joined(separator: "\n")
        }
        do { try library.save(meeting) }
        catch { statusMessage = "The transcript was created but couldn’t be saved: \(error.localizedDescription)" }
        return meeting
    }

    private func auditSavedVideos() async {
        let savedMeetings = library.meetings
        for original in savedMeetings {
            guard let videoFile = original.videoFile else { continue }
            let videoURL = library.folder(for: original).appendingPathComponent(videoFile)
            let validation = await MeetingVideoValidator.validate(
                url: videoURL,
                expectedDuration: original.duration
            )
            guard !validation.isPlayable || validation.warning != nil else { continue }

            var meeting = original
            if !validation.isPlayable {
                // Keep the raw file in the recording folder for possible future
                // recovery, but never offer a corrupt file as a working video.
                meeting.videoFile = nil
            }
            if let warning = validation.warning,
               meeting.errorMessage?.contains(warning) != true {
                meeting.errorMessage = [meeting.errorMessage, warning]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
            try? library.save(meeting)
        }
    }

    private func recoverInterruptedRecordings() async {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(
            at: library.recordingsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        var recoveredMeetings: [MeetingRecord] = []
        for folder in folders {
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  !fileManager.fileExists(atPath: folder.appendingPathComponent("metadata.json").path),
                  let startedAt = formatter.date(from: folder.lastPathComponent) else { continue }

            let videoURL = folder.appendingPathComponent("zoom-screen.mp4")
            let systemAudioURL = folder.appendingPathComponent("meeting-audio.m4a")
            let microphoneURL = folder.appendingPathComponent("my-microphone.caf")
            let combinedAudioURL = folder.appendingPathComponent("full-meeting-audio.m4a")

            let videoExists = fileIsNonempty(videoURL)
            let systemAudioExists = fileIsNonempty(systemAudioURL)
            let microphoneExists = fileIsNonempty(microphoneURL)
            let combinedAudioExists = fileIsNonempty(combinedAudioURL)
            guard videoExists || systemAudioExists || microphoneExists || combinedAudioExists else { continue }

            let mediaURLs = [systemAudioURL, microphoneURL, combinedAudioURL].filter(fileIsNonempty)
            var durations: [TimeInterval] = []
            for mediaURL in mediaURLs {
                durations.append(await mediaDuration(of: mediaURL))
            }
            let mediaDuration = durations.max() ?? 0
            let latestModification = ([videoURL] + mediaURLs).compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.max() ?? startedAt
            let endedAt = mediaDuration > 0.5
                ? startedAt.addingTimeInterval(mediaDuration)
                : max(startedAt, latestModification)

            let videoValidation = videoExists
                ? await MeetingVideoValidator.validate(
                    url: videoURL,
                    expectedDuration: max(0, endedAt.timeIntervalSince(startedAt))
                )
                : MeetingVideoValidation(isPlayable: false, duration: 0, warning: nil)
            // Do not turn empty placeholders from a failed capture start into
            // visible meetings. Keep those files untouched for diagnostics.
            guard mediaDuration > 0.5 || videoValidation.isPlayable else { continue }

            var warnings = ["MeetMemento recovered this recording after the app closed unexpectedly."]
            if let videoWarning = videoValidation.warning {
                warnings.append(videoWarning)
            }
            if !systemAudioExists && microphoneExists {
                warnings.append("Zoom system audio was not finalized, but your microphone audio is available.")
            }

            let hasTranscribableAudio = systemAudioExists || microphoneExists || combinedAudioExists
            let meeting = MeetingRecord(
                id: UUID(),
                title: calendarMatcher.title(forMeetingAt: startedAt) ?? "Recovered Zoom meeting",
                startedAt: startedAt,
                endedAt: endedAt,
                folderName: folder.lastPathComponent,
                videoFile: videoValidation.isPlayable ? videoURL.lastPathComponent : nil,
                systemAudioFile: systemAudioExists ? systemAudioURL.lastPathComponent : nil,
                microphoneFile: microphoneExists ? microphoneURL.lastPathComponent : nil,
                combinedAudioFile: combinedAudioExists ? combinedAudioURL.lastPathComponent : nil,
                transcriptFile: nil,
                transcript: nil,
                transcriptionStatus: hasTranscribableAudio
                    ? (permissions.speechRecognition ? .pending : .permissionRequired)
                    : .failed,
                errorMessage: warnings.joined(separator: "\n")
            )
            do {
                try library.save(meeting)
                recoveredMeetings.append(meeting)
            } catch {
                statusMessage = "MeetMemento found an interrupted recording but couldn’t restore it: \(error.localizedDescription)"
            }
        }

        if let latest = recoveredMeetings.max(by: { $0.startedAt < $1.startedAt }) {
            selectedMeetingID = latest.id
            statusMessage = recoveredMeetings.count == 1
                ? "An interrupted recording was recovered. Its available audio is ready, and you can retry transcription."
                : "\(recoveredMeetings.count) interrupted recordings were recovered."
        }
    }

    private func fileIsNonempty(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    private func mediaDuration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
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
