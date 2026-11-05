import Foundation

@main
struct MeetMementoChecks {
    static func main() {
        let segments = [
            TranscriptSegment(source: "You", timestamp: 4, duration: 1, text: "Good"),
            TranscriptSegment(source: "Meeting", timestamp: 1, duration: 1, text: "Hello"),
            TranscriptSegment(source: "You", timestamp: 5, duration: 1, text: "morning"),
            TranscriptSegment(source: "Meeting", timestamp: 2, duration: 1, text: "team"),
            TranscriptSegment(source: "Meeting", timestamp: 35, duration: 1, text: "Next")
        ]
        let expected = "[00:00] Meeting: Hello team\n\n[00:00] You: Good morning\n\n[00:30] Meeting: Next"
        precondition(TranscriptFormatter.format(segments) == expected)
        precondition(TranscriptFormatter.format([]) == "")

        let legacyMetadata = """
        {
          "endedAt":"2026-09-06T19:13:10Z",
          "folderName":"2026-09-07_00-42-52",
          "id":"D9EC3C5F-1D36-4624-BBD0-AB69F40E81BB",
          "startedAt":"2026-09-06T19:12:52Z",
          "title":"Zoom meeting",
          "transcriptionStatus":"permissionRequired",
          "videoFile":"zoom-screen.mp4"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyMeeting = try! decoder.decode(MeetingRecord.self, from: Data(legacyMetadata.utf8))
        precondition(legacyMeeting.combinedAudioFile == nil)
        let generatedTitle = MeetingNamer.title(
            from: "[00:00] Meeting: Billing billing invoices invoices accruals adjustments."
        )
        precondition(generatedTitle == "Billing · Invoices · Accruals")
        precondition(ZoomSignalClassifier.isMeetingHelper(
            bundleIdentifier: "us.zoom.CptHost",
            localizedName: "CptHost"
        ))
        precondition(ZoomSignalClassifier.isMeetingHelper(
            bundleIdentifier: "us.zoom.zCCIMeetingHost",
            localizedName: "zCCIMeetingHost"
        ))
        precondition(!ZoomSignalClassifier.isMeetingHelper(
            bundleIdentifier: "us.zoom.caphost",
            localizedName: "caphost"
        ))
        precondition(!MeetingSignalClassifier.isVisibleMeetingHelperWindow(isOnScreen: false, alpha: 1))
        precondition(!MeetingSignalClassifier.isVisibleMeetingHelperWindow(isOnScreen: true, alpha: 0))
        precondition(MeetingSignalClassifier.isVisibleMeetingHelperWindow(isOnScreen: true, alpha: 1))
        precondition(ZoomSignalClassifier.isMeetingWindowTitle("Zoom Webinar"))
        precondition(!ZoomSignalClassifier.isMeetingWindowTitle("Zoom Workplace"))
        precondition(ZoomSignalClassifier.isMeetingWindow(
            ownedByMeetingHelper: true,
            title: "Project discussion",
            layer: 0,
            width: 800,
            height: 600
        ))
        precondition(!ZoomSignalClassifier.isMeetingWindow(
            ownedByMeetingHelper: true,
            title: "",
            layer: 0,
            width: 1,
            height: 1
        ))
        precondition(!ZoomSignalClassifier.isMeetingWindow(
            ownedByMeetingHelper: false,
            title: "Zoom Workplace",
            layer: 0,
            width: 800,
            height: 600
        ))
        precondition(MeetingSignalClassifier.windowMatch(
            bundleIdentifier: "com.google.Chrome",
            localizedName: "Google Chrome",
            title: "Product review - Google Meet"
        )?.provider == .googleMeet)
        precondition(MeetingSignalClassifier.windowMatch(
            bundleIdentifier: "com.microsoft.teams2",
            localizedName: "Microsoft Teams",
            title: "Weekly planning | Microsoft Teams meeting"
        )?.provider == .microsoftTeams)
        precondition(MeetingSignalClassifier.windowMatch(
            bundleIdentifier: "com.cisco.webexmeetingsapp",
            localizedName: "Webex",
            title: "Customer call - Webex Meeting"
        )?.provider == .webex)
        precondition(MeetingSignalClassifier.windowMatch(
            bundleIdentifier: "com.google.Chrome",
            localizedName: "Google Chrome",
            title: "Meeting notes - Google Docs"
        ) == nil)
        precondition(MeetingSignalClassifier.windowMatch(
            bundleIdentifier: "com.microsoft.teams2",
            localizedName: "Microsoft Teams",
            title: "Microsoft Teams"
        ) == nil)
        precondition(MeetingSignalClassifier.windowMatch(
            bundleIdentifier: "com.example.newcallingapp",
            localizedName: "New Calling App",
            title: "Video call with Priya"
        )?.provider == .other)

        let noAccess = PermissionSnapshot()
        precondition(noAccess.firstMissingRequiredPermission(includeMicrophone: true) == .screenRecording)
        let screenOnly = PermissionSnapshot(screenRecording: true)
        precondition(screenOnly.firstMissingRequiredPermission(includeMicrophone: true) == .microphone)
        precondition(screenOnly.firstMissingRequiredPermission(includeMicrophone: false) == .speechRecognition)
        let ready = PermissionSnapshot(screenRecording: true, microphone: true, speechRecognition: true)
        precondition(ready.firstMissingRequiredPermission(includeMicrophone: true) == nil)
        precondition(!CaptureStartupRecoveryPolicy.shouldRecover(state: .starting, elapsed: 19.9))
        precondition(CaptureStartupRecoveryPolicy.shouldRecover(state: .starting, elapsed: 20))
        precondition(!CaptureStartupRecoveryPolicy.shouldRecover(state: .recording, elapsed: 60))
        precondition(!MeetingLifecyclePolicy.shouldStart(after: 1))
        precondition(MeetingLifecyclePolicy.shouldStart(after: 2))
        precondition(!MeetingLifecyclePolicy.shouldStop(after: 8))
        precondition(!MeetingLifecyclePolicy.shouldStop(after: 19))
        precondition(MeetingLifecyclePolicy.shouldStop(after: 20))
        precondition(!MeetingLifecyclePolicy.hasConfirmedMeetingEnded(after: 11))
        precondition(MeetingLifecyclePolicy.hasConfirmedMeetingEnded(after: 12))
        print("MeetMemento checks passed")
    }
}
