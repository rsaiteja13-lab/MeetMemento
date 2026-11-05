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
    @Published var meetingState: MeetingState = .notRunning
    @Published var detectedMeetingTarget: MeetingCaptureTarget?
    @Published var permissions = PermissionSnapshot()
    @Published var activeCapture: ActiveCapture?
    @Published var selectedMeetingID: UUID?
    @Published var statusMessage: String?
    @Published var permissionSetupPhase: PermissionSetupPhase = .ready

    let settings = AppSettings()
    let library = MeetingLibrary()
    let transcriber = SpeechTranscriber()
    private let calendarMatcher = CalendarEventMatcher()

    private let detector = MeetingDetector()
    private let captureController = MeetingCaptureController()
    private var detectorTimer: Timer?
    private var healthTimer: Timer?
    private var permissionRefreshTimer: Timer?
    private var applicationActivationObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var permissionRelaunchTask: Task<Void, Never>?
    private var captureStartupWatchdogTask: Task<Void, Never>?
    private var started = false
    private var waitingForScreenSettings = false
    private var screenSettingsWereOpened = false
    private var attemptedScreenPermissionRelaunch = false
    private var confirmedMeetingChecks = 0
    private var missedMeetingChecks = 0
    private var lastDetectedMeetingIdentity: String?
    private var suppressAutomaticRecordingUntilMeetingEnds = false
    private var activeMeetingTitle: String?
    private var pendingCaptureFolderURL: URL?
    private var activeRecordingWasTriggeredAutomatically = false
    private var didAuditSavedVideos = false
    private var lastReportedMeetingState: MeetingState?
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]

    var canStartRecording: Bool {
        activeCapture == nil && captureState != .starting && captureState != .stopping && captureState != .transcribing
    }

    var capturePermissionsReady: Bool {
        permissions.screenRecording
    }

    var essentialPermissionsReady: Bool {
        missingRequiredPermission == nil
    }

    var missingRequiredPermission: RequiredPermission? {
        permissions.firstMissingRequiredPermission(includeMicrophone: settings.includeMicrophone)
    }

    var permissionActionTitle: String {
        switch missingRequiredPermission {
        case .screenRecording:
            return settings.screenPermissionRelaunchAttemptedForCurrentBuild
                ? "Fix Screen Access"
                : "Open Screen Settings"
        case .microphone: return "Allow Microphone"
        case .speechRecognition: return "Allow Transcription"
        case nil: return "Access Confirmed"
        }
    }

    func start() {
        guard !started else { return }
        started = true
        refreshPermissions()
        finishPermissionSetupIfReady()
        observePermissionChanges()
        AppDiagnostics.shared.record(
            "App started from \(Bundle.main.bundleURL.path); automatic=\(settings.autoRecord); screen=\(permissions.screenRecording); microphone=\(permissions.microphone); speech=\(permissions.speechRecognition)"
        )
        refreshMeetingState()
        // Poll every second, then require stable evidence before starting or
        // stopping so transient helper windows cannot create recording loops.
        detectorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMeetingState() }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordHealthCheck() }
        }
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
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
        let screenPromptWasPreviouslyAttempted = settings.screenPermissionPromptAttempted
        if permissions.screenRecording {
            // Nothing to present. The current executable already has access.
        } else if screenPromptWasPreviouslyAttempted {
            // macOS has already shown its one-time Screen Recording prompt.
            // Open the relevant pane directly without also asking macOS to
            // display the redundant "Open System Settings" alert.
            openScreenRecordingSettings()
        } else {
            settings.screenPermissionPromptAttempted = true
            waitingForScreenSettings = true
            screenSettingsWereOpened = false
            attemptedScreenPermissionRelaunch = false
            permissions.screenRecording = Permissions.requestScreenRecording()
        }
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
        }
    }

    func finishPermissionSetupIfReady() {
        guard settings.consentAcknowledged, essentialPermissionsReady else { return }
        settings.onboardingCompleted = true
        permissionSetupPhase = .complete
        statusMessage = nil
    }

    func openFirstMissingRequiredPermission() {
        Task { await resolveNextMissingPermission() }
    }

    func resolveNextMissingPermission() async {
        refreshPermissions()
        switch missingRequiredPermission {
        case .screenRecording:
            requestScreenRecordingAccess()
        case .microphone:
            await requestMicrophoneAccess()
        case .speechRecognition:
            await requestSpeechAccess()
        case nil:
            finishPermissionSetupIfReady()
        }
    }

    var missingPermissionMessage: String {
        if !permissions.screenRecording {
            if settings.screenPermissionRelaunchAttemptedForCurrentBuild {
                return "macOS still has an older MeetMemento approval. Switch MeetMemento off and back on once in Screen & System Audio Recording."
            }
            return "Turn on MeetMemento under Screen & System Audio Recording. When you return, MeetMemento will reopen once to apply access."
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
        refreshPermissions()
        guard !permissions.screenRecording else {
            finishPermissionSetupIfReady()
            return
        }

        if settings.screenPermissionPromptAttempted {
            // After the first system prompt, restoration is performed in the
            // privacy pane. Calling CGRequestScreenCaptureAccess here as well
            // opens a second, redundant macOS window.
            openScreenRecordingSettings()
        } else {
            settings.screenPermissionPromptAttempted = true
            waitingForScreenSettings = true
            screenSettingsWereOpened = false
            attemptedScreenPermissionRelaunch = false
            _ = Permissions.requestScreenRecording()
        }
        settings.screenPermissionConfigured = true
        refreshPermissions()
    }

    func handleApplicationDidBecomeActive() {
        refreshPermissions()
        guard waitingForScreenSettings, screenSettingsWereOpened else { return }
        guard !permissions.screenRecording else {
            clearScreenPermissionRecoveryState()
            return
        }
        guard !attemptedScreenPermissionRelaunch else { return }

        attemptedScreenPermissionRelaunch = true
        statusMessage = "Applying screen access… MeetMemento will reopen automatically."
        permissionRelaunchTask?.cancel()
        permissionRelaunchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.refreshPermissions()
            guard self?.permissions.screenRecording == false else {
                self?.clearScreenPermissionRecoveryState()
                return
            }
            self?.relaunchToApplyScreenPermission()
        }
    }

    func requestMicrophoneAccess() async {
        let granted = await Permissions.requestMicrophone()
        permissions.microphone = granted
        if !granted {
            statusMessage = "Allow microphone access to include your voice in meeting audio."
            Permissions.openPrivacySettings(.microphone)
        }
        refreshPermissions()
    }

    func requestSpeechAccess() async {
        let granted = await Permissions.requestSpeechRecognition()
        permissions.speechRecognition = granted
        if !granted {
            statusMessage = "Allow Speech Recognition to create transcripts."
            Permissions.openPrivacySettings(.speechRecognition)
        }
        refreshPermissions()
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
        let currentPermissions = Permissions.snapshot()
        if currentPermissions != permissions {
            permissions = currentPermissions
            AppDiagnostics.shared.record(
                "Permissions refreshed; screen=\(permissions.screenRecording); microphone=\(permissions.microphone); speech=\(permissions.speechRecognition)"
            )
        }
        if permissions.screenRecording {
            clearScreenPermissionRecoveryState()
            if captureState == .failed("Screen Recording access needed") {
                captureState = .idle
            }
        }
        reconcilePermissionSetupState()
    }

    private func reconcilePermissionSetupState() {
        if settings.consentAcknowledged, essentialPermissionsReady {
            finishPermissionSetupIfReady()
        } else if settings.consentAcknowledged,
                  permissionSetupPhase == .complete || permissionSetupPhase == .ready {
            permissionSetupPhase = .needsSystemSettings
        }
    }

    private func openScreenRecordingSettings() {
        waitingForScreenSettings = true
        screenSettingsWereOpened = false
        attemptedScreenPermissionRelaunch = false
        statusMessage = missingPermissionMessage
        Permissions.openPrivacySettings(.screenCapture)
    }

    private func observePermissionChanges() {
        guard applicationActivationObserver == nil else { return }
        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleApplicationDidBecomeActive() }
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.bundleIdentifier == "com.apple.systempreferences" else { return }
            Task { @MainActor in
                guard self?.waitingForScreenSettings == true else { return }
                self?.screenSettingsWereOpened = true
            }
        }
    }

    private func clearScreenPermissionRecoveryState() {
        waitingForScreenSettings = false
        screenSettingsWereOpened = false
        attemptedScreenPermissionRelaunch = false
        permissionRelaunchTask?.cancel()
        permissionRelaunchTask = nil
    }

    private func relaunchToApplyScreenPermission() {
        AppDiagnostics.shared.record("Relaunching once so macOS can apply Screen Recording access")
        settings.markScreenPermissionRelaunchAttempted()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    self.attemptedScreenPermissionRelaunch = false
                    self.statusMessage = "MeetMemento couldn’t reopen automatically: \(error.localizedDescription). Reopen it once to apply screen access."
                    AppDiagnostics.shared.record("Permission relaunch failed: \(error.localizedDescription)")
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    func refreshMeetingState() {
        let detection = detector.currentDetection()
        meetingState = detection.state
        detectedMeetingTarget = detection.target
        if lastReportedMeetingState != meetingState {
            let provider = detection.target?.displayName ?? detection.openApplicationName ?? "none"
            AppDiagnostics.shared.record("Meeting state changed to \(meetingState.label); provider=\(provider)")
            lastReportedMeetingState = meetingState
        }

        if meetingState == .inMeeting {
            let detectionIdentity = detection.target.map { target in
                let windows = target.windowIdentifiers.sorted().map(String.init).joined(separator: ",")
                return "\(target.provider.rawValue):\(windows)"
            }
            if detectionIdentity != nil, detectionIdentity == lastDetectedMeetingIdentity {
                confirmedMeetingChecks += 1
            } else {
                confirmedMeetingChecks = detectionIdentity == nil ? 0 : 1
                lastDetectedMeetingIdentity = detectionIdentity
            }
            missedMeetingChecks = 0
            if settings.captureStartupSuppressedUntilMeetingEnds,
               activeCapture == nil {
                captureState = .failed("Screen capture could not start for this meeting")
                statusMessage = "MeetMemento recovered from repeated macOS screen-capture stalls. It will automatically try again when the next meeting starts."
            } else if settings.autoRecord,
               settings.consentAcknowledged,
               !capturePermissionsReady,
               activeCapture == nil {
                captureState = .failed("Screen Recording access needed")
                statusMessage = "Allow MeetMemento under Privacy & Security → Screen & System Audio Recording, then reopen the app."
            } else if settings.autoRecord,
               settings.consentAcknowledged,
               capturePermissionsReady,
               !suppressAutomaticRecordingUntilMeetingEnds,
               MeetingLifecyclePolicy.shouldStart(after: confirmedMeetingChecks),
               canStartRecording {
                AppDiagnostics.shared.record("Automatic recording requested")
                Task { await startRecording(triggeredAutomatically: true) }
            }
        } else {
            confirmedMeetingChecks = 0
            lastDetectedMeetingIdentity = nil
            missedMeetingChecks += 1
            let meetingEndConfirmed = MeetingLifecyclePolicy.hasConfirmedMeetingEnded(
                after: missedMeetingChecks
            )
            if meetingEndConfirmed {
                suppressAutomaticRecordingUntilMeetingEnds = false
            }
            if settings.captureStartupSuppressedUntilMeetingEnds, meetingEndConfirmed {
                settings.clearCaptureStartupRecoveryState()
                if captureState == .failed("Screen capture could not start for this meeting") {
                    captureState = .idle
                    statusMessage = nil
                }
            }
            if captureState == .failed("Screen Recording access needed") {
                captureState = .idle
                statusMessage = nil
            }
            if captureState == .recording, activeRecordingWasTriggeredAutomatically {
                // A long grace period avoids splitting a recording while a meeting app
                // replaces, minimizes, or briefly hides its meeting window. An
                // automatically confirmed end must not arm the manual-stop suppression
                // flag; if detection was wrong and the meeting reappears, recording must
                // recover instead of remaining Ready for the rest of the call.
                if MeetingLifecyclePolicy.shouldStop(after: missedMeetingChecks) {
                    AppDiagnostics.shared.record(
                        "Meeting absence confirmed after \(missedMeetingChecks) checks; saving automatic recording"
                    )
                    Task { await stopRecording(suppressAutomaticRestart: false) }
                }
            }
        }
    }

    func startRecording(triggeredAutomatically: Bool = false) async {
        guard canStartRecording else { return }
        guard settings.consentAcknowledged else {
            statusMessage = "Confirm the recording consent reminder before starting."
            AppDiagnostics.shared.record("Recording did not start because consent is incomplete")
            return
        }
        refreshPermissions()
        guard permissions.screenRecording else {
            captureState = .failed("Screen Recording access needed")
            AppDiagnostics.shared.record("Recording did not start because Screen Recording access is unavailable")
            return
        }
        let refreshedDetection = detector.currentDetection()
        let target = detectedMeetingTarget
            ?? refreshedDetection.target
            ?? (triggeredAutomatically ? nil : detector.frontmostCaptureTarget())
        guard let target else {
            statusMessage = triggeredAutomatically
                ? "The meeting window disappeared before recording could start."
                : "Join a meeting or bring its window to the front, then try again."
            AppDiagnostics.shared.record("Recording did not start because no meeting capture target was available")
            return
        }
        captureState = .starting
        statusMessage = nil
        let startedAt = Date()
        armCaptureStartupWatchdog(startedAt: startedAt)
        AppDiagnostics.shared.record("Recording startup entered; automatic=\(triggeredAutomatically)")
        activeMeetingTitle = calendarMatcher.title(forMeetingAt: startedAt)
            ?? suggestedMeetingTitle(for: target)
        var captureFolder: URL?
        do {
            let folder = try library.makeFolder(startedAt: startedAt)
            captureFolder = folder
            pendingCaptureFolderURL = folder
            var capture = try await captureController.start(
                in: folder,
                includeMicrophone: settings.includeMicrophone && permissions.microphone,
                target: target
            )
            if settings.includeMicrophone && !permissions.microphone {
                capture.startupWarnings.append(
                    "Microphone access is not currently granted, so your voice was not captured separately."
                )
            }
            activeCapture = capture
            pendingCaptureFolderURL = nil
            activeRecordingWasTriggeredAutomatically = triggeredAutomatically
            settings.screenPermissionConfigured = true
            settings.clearCaptureStartupRecoveryState()
            captureStartupWatchdogTask?.cancel()
            captureStartupWatchdogTask = nil
            selectedMeetingID = nil
            captureState = .recording
            AppDiagnostics.shared.record(
                "Recording started; provider=\(target.displayName); automatic=\(triggeredAutomatically); microphone=\(capture.microphoneURL != nil)"
            )
            if triggeredAutomatically {
                notify(title: "Meeting recording started", body: "Confirm that everyone in the meeting has consented.")
            }
        } catch {
            captureStartupWatchdogTask?.cancel()
            captureStartupWatchdogTask = nil
            pendingCaptureFolderURL = nil
            if let captureFolder, folderContainsRecoverableMedia(captureFolder) {
                await recoverInterruptedRecordings()
            } else if let captureFolder {
                try? FileManager.default.removeItem(at: captureFolder)
            }
            activeMeetingTitle = nil
            activeRecordingWasTriggeredAutomatically = false
            if triggeredAutomatically {
                suppressAutomaticRecordingUntilMeetingEnds = true
            }
            captureState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
            AppDiagnostics.shared.record("Recording startup failed: \(error.localizedDescription)")
            if isScreenPermissionError(error) {
                settings.screenPermissionConfigured = false
                permissions.screenRecording = false
            }
        }
    }

    private func armCaptureStartupWatchdog(startedAt: Date) {
        captureStartupWatchdogTask?.cancel()
        captureStartupWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(CaptureStartupRecoveryPolicy.timeout))
            guard !Task.isCancelled, let self else { return }
            let elapsed = Date().timeIntervalSince(startedAt)
            guard CaptureStartupRecoveryPolicy.shouldRecover(
                state: self.captureState,
                elapsed: elapsed
            ) else { return }
            self.recoverFromCaptureStartupStall()
        }
    }

    private func recoverFromCaptureStartupStall() {
        let shouldRetry = settings.registerCaptureStartupRecoveryAttempt()
        if !shouldRetry {
            settings.captureStartupSuppressedUntilMeetingEnds = true
        }
        statusMessage = shouldRetry
            ? "Screen capture took too long to start. MeetMemento is recovering automatically…"
            : "macOS screen capture stalled repeatedly. MeetMemento is reopening safely and will retry with the next meeting."
        AppDiagnostics.shared.record(
            "Capture startup watchdog fired after \(Int(CaptureStartupRecoveryPolicy.timeout)) seconds; retry=\(shouldRetry)"
        )

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = NSApp.isActive
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                if let error {
                    self.settings.captureStartupSuppressedUntilMeetingEnds = true
                    self.captureState = .failed("Screen capture recovery failed")
                    self.statusMessage = "MeetMemento couldn’t reopen automatically: \(error.localizedDescription)"
                    AppDiagnostics.shared.record("Capture startup recovery relaunch failed: \(error.localizedDescription)")
                } else {
                    AppDiagnostics.shared.record("Capture startup recovery relaunched MeetMemento")
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    func stopRecording(suppressAutomaticRestart: Bool = true) async {
        guard let capture = activeCapture else { return }
        if suppressAutomaticRestart,
           (meetingState == .inMeeting || activeRecordingWasTriggeredAutomatically) {
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
        // Keep system output and microphone as separate source tracks. Mixing a
        // speaker-fed microphone into system audio creates a delayed duplicate of
        // the remote participants (audible echo). The clean system track is the
        // default playback audio; the microphone remains available in Export All.
        if systemAudioExists {
            combinedAudioFile = capture.systemAudioURL.lastPathComponent
        } else if microphoneExists {
            combinedAudioFile = capture.microphoneURL?.lastPathComponent
        }

        let meeting = MeetingRecord(
            id: capture.id,
            title: activeMeetingTitle ?? "Meeting",
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
        do { try library.save(meeting) }
        catch { statusMessage = "The recording was saved, but MeetMemento couldn’t add it to your library: \(error.localizedDescription)" }
        selectedMeetingID = meeting.id

        captureState = .idle
        let readyItems = [
            meeting.videoFile == nil ? nil : "video",
            meeting.combinedAudioFile == nil ? nil : "audio"
        ].compactMap { $0 }
        notify(
            title: "Meeting recording saved",
            body: readyItems.isEmpty
                ? "Some recording files need attention. Open MeetMemento for details."
                : permissions.speechRecognition
                    ? "Your \(readyItems.joined(separator: ", ")) \(readyItems.count == 1 ? "is" : "are") ready. The transcript is being created in the background."
                    : "Your \(readyItems.joined(separator: ", ")) \(readyItems.count == 1 ? "is" : "are") ready."
        )
        AppDiagnostics.shared.record(
            "Recording saved; video=\(meeting.videoFile != nil); audio=\(meeting.combinedAudioFile != nil); transcriptPending=\(permissions.speechRecognition); warnings=\(saveErrors.count)"
        )
        if permissions.speechRecognition {
            queueTranscription(for: meeting, notifyWhenComplete: true)
        }
    }

    func retryTranscription(for meeting: MeetingRecord) async {
        refreshPermissions()
        guard permissions.speechRecognition else {
            statusMessage = "Allow Speech Recognition to create a transcript."
            return
        }
        guard transcriptionTasks[meeting.id] == nil else {
            statusMessage = "The transcript is already being created."
            return
        }
        statusMessage = "Creating the transcript in the background…"
        queueTranscription(for: meeting, notifyWhenComplete: true)
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
        let synchronizedAudioURL = kind == .video
            ? library.fileURL(for: meeting, kind: .audio)
            : nil

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
                        if kind == .video, let synchronizedAudioURL {
                            try await MeetingMediaComposer.exportVideoWithAudio(
                                videoURL: sourceURL,
                                audioURL: synchronizedAudioURL,
                                destinationURL: destinationURL
                            )
                        } else {
                            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        }
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
        _ = moveToTrash([meeting])
    }

    @discardableResult
    func moveToTrash(_ meetings: [MeetingRecord]) -> Set<UUID> {
        guard captureState == .idle else {
            statusMessage = "Wait until the current recording finishes before deleting recordings."
            return []
        }
        let uniqueMeetings = meetings.reduce(into: [MeetingRecord]()) { result, meeting in
            if !result.contains(where: { $0.id == meeting.id }) { result.append(meeting) }
        }
        guard !uniqueMeetings.isEmpty else { return [] }

        let result = library.moveToTrash(uniqueMeetings)
        if let selectedMeetingID, result.movedIDs.contains(selectedMeetingID) {
            self.selectedMeetingID = nil
        }
        let movedCount = result.movedIDs.count
        let failedCount = result.failures.count
        if failedCount == 0 {
            statusMessage = movedCount == 1
                ? "Meeting moved to Trash. Open Recently Deleted in the sidebar to recover it."
                : "\(movedCount) meetings moved to Trash. Open Recently Deleted in the sidebar to recover them."
        } else if movedCount > 0 {
            statusMessage = "\(movedCount) meetings moved to Trash; \(failedCount) couldn’t be moved."
        } else {
            statusMessage = "The selected meetings couldn’t be moved to Trash: \(result.failures.first ?? "Unknown error")"
        }
        return result.movedIDs
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
        var usedSeparateSourceTracks = false

        // Transcribe the source tracks separately. A pre-mixed system+microphone
        // file can contain speaker bleed twice, which creates both audible echo
        // and duplicated transcript phrases.
        if let file = meeting.systemAudioFile {
            usedSeparateSourceTracks = true
            do {
                segments += try await transcribeTrack(
                    fileURL: folder.appendingPathComponent(file),
                    source: "Meeting"
                )
            } catch { failures.append("Meeting audio: \(error.localizedDescription)") }
        }
        if let file = meeting.microphoneFile {
            usedSeparateSourceTracks = true
            do {
                segments += try await transcribeTrack(
                    fileURL: folder.appendingPathComponent(file),
                    source: "You"
                )
            } catch { failures.append("Microphone: \(error.localizedDescription)") }
        }
        if !usedSeparateSourceTracks, let file = meeting.combinedAudioFile {
            do {
                segments += try await transcribeTrack(
                    fileURL: folder.appendingPathComponent(file),
                    source: "Meeting"
                )
            } catch { failures.append("Meeting audio: \(error.localizedDescription)") }
        }

        if segments.isEmpty {
            meeting.transcriptionStatus = .failed
            meeting.errorMessage = (recordingErrors + failures).joined(separator: "\n")
        } else {
            meeting.transcript = TranscriptFormatter.format(segments)
            meeting.transcriptFile = "transcript.txt"
            if isGenericMeetingTitle(meeting.title),
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

    private func queueTranscription(for meeting: MeetingRecord, notifyWhenComplete: Bool) {
        guard transcriptionTasks[meeting.id] == nil else { return }
        let meetingID = meeting.id
        transcriptionTasks[meetingID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let completedMeeting = await self.transcribe(meeting)
            self.transcriptionTasks[meetingID] = nil
            if completedMeeting.transcriptionStatus == .complete {
                self.statusMessage = nil
                self.recordTranscriptReady(completedMeeting)
                if notifyWhenComplete {
                    self.notify(
                        title: "Transcript ready",
                        body: "The transcript for \(completedMeeting.title) is ready."
                    )
                }
            } else {
                self.statusMessage = "The recording was saved, but the transcript could not be completed. You can retry it later."
                AppDiagnostics.shared.record(
                    "Transcript failed for \(meetingID.uuidString); recording remains available"
                )
            }
        }
    }

    private func recordTranscriptReady(_ meeting: MeetingRecord) {
        AppDiagnostics.shared.record("Transcript ready for \(meeting.id.uuidString)")
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
                  folder.standardizedFileURL != pendingCaptureFolderURL?.standardizedFileURL,
                  !fileManager.fileExists(atPath: folder.appendingPathComponent("metadata.json").path),
                  let startedAt = formatter.date(from: folder.lastPathComponent) else { continue }

            let modernVideoURL = folder.appendingPathComponent("meeting-screen.mp4")
            let legacyVideoURL = folder.appendingPathComponent("zoom-screen.mp4")
            let videoURL = fileIsNonempty(modernVideoURL) ? modernVideoURL : legacyVideoURL
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
                warnings.append("Meeting system audio was not finalized, but your microphone audio is available.")
            }

            let hasTranscribableAudio = systemAudioExists || microphoneExists || combinedAudioExists
            let preferredAudioFile = systemAudioExists
                ? systemAudioURL.lastPathComponent
                : (combinedAudioExists
                    ? combinedAudioURL.lastPathComponent
                    : (microphoneExists ? microphoneURL.lastPathComponent : nil))
            let meeting = MeetingRecord(
                id: UUID(),
                title: calendarMatcher.title(forMeetingAt: startedAt) ?? "Recovered meeting",
                startedAt: startedAt,
                endedAt: endedAt,
                folderName: folder.lastPathComponent,
                videoFile: videoValidation.isPlayable ? videoURL.lastPathComponent : nil,
                systemAudioFile: systemAudioExists ? systemAudioURL.lastPathComponent : nil,
                microphoneFile: microphoneExists ? microphoneURL.lastPathComponent : nil,
                combinedAudioFile: preferredAudioFile,
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
        for meeting in recoveredMeetings where meeting.transcriptionStatus == .pending {
            queueTranscription(for: meeting, notifyWhenComplete: true)
        }
    }

    private func folderContainsRecoverableMedia(_ folder: URL) -> Bool {
        [
            "meeting-screen.mp4",
            "zoom-screen.mp4",
            "meeting-audio.m4a",
            "my-microphone.caf",
            "full-meeting-audio.m4a"
        ].contains { fileIsNonempty(folder.appendingPathComponent($0)) }
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
        var consecutiveTimeouts = 0

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
                consecutiveTimeouts = 0
            } catch TranscriptionError.noSpeech {
                continue
            } catch TranscriptionError.timedOut {
                if firstMeaningfulError == nil { firstMeaningfulError = TranscriptionError.timedOut }
                consecutiveTimeouts += 1
                if consecutiveTimeouts >= 2 { break }
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

    private func recordHealthCheck() {
        AppDiagnostics.shared.record(
            "Heartbeat; meeting=\(meetingState.label); provider=\(detectedMeetingTarget?.displayName ?? "none"); capture=\(captureState.label); automatic=\(settings.autoRecord); suppressed=\(suppressAutomaticRecordingUntilMeetingEnds); screen=\(permissions.screenRecording)"
        )
    }

    private func isScreenPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == -3801
    }

    private func suggestedMeetingTitle(for target: MeetingCaptureTarget) -> String {
        guard var title = target.detectedWindowTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return target.defaultMeetingTitle }
        let lowercased = title.lowercased()
        let genericSignals = [
            "zoom meeting", "zoom webinar", "google meet", "teams meeting",
            "meeting | microsoft teams", "webex meeting", "slack huddle",
            "jitsi meet", "whereby"
        ]
        if genericSignals.contains(lowercased)
            || lowercased.hasPrefix("meet -")
            || lowercased == target.displayName.lowercased() {
            return target.defaultMeetingTitle
        }
        for suffix in [
            " - Google Meet", " | Microsoft Teams", " - Microsoft Teams",
            " - Zoom Meeting", " - Zoom", " - Webex", " | Webex",
            " - Slack", " | Slack"
        ] where title.lowercased().hasSuffix(suffix.lowercased()) {
            title.removeLast(suffix.count)
            break
        }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? target.defaultMeetingTitle : String(cleaned.prefix(120))
    }

    private func isGenericMeetingTitle(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "meeting"
            || normalized == "recovered meeting"
            || MeetingProvider.allCases.contains { normalized == "\($0.displayName.lowercased()) meeting" }
    }

    private func safeFileName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Meeting" : cleaned).prefix(60))
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
