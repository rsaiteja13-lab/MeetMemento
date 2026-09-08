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

        let summary = MeetingSummarizer.summarize(
            "[00:00] Meeting: We agreed to launch the pilot on Friday.\n\n" +
            "[00:12] You: Priya will prepare the customer list before Thursday.\n\n" +
            "[00:28] Meeting: The pilot will include twenty customers and run for two weeks."
        )
        precondition(!summary.isEmpty)
        precondition(summary.contains("pilot"))
        precondition(!summary.contains("[00:"))
        precondition(summary.split(separator: "\n").count <= 5)

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
        precondition(legacyMeeting.summary == nil)

        let generatedTitle = MeetingNamer.title(
            from: "[00:00] Meeting: Billing billing invoices invoices accruals adjustments."
        )
        precondition(generatedTitle == "Billing · Invoices · Accruals")
        print("MeetMemento checks passed")
    }
}
