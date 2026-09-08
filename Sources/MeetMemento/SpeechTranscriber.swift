import Foundation
import Speech

enum TranscriptionError: LocalizedError {
    case recognizerUnavailable
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "Speech recognition is unavailable for the current language."
        case .noSpeech: return "No recognizable speech was found in this audio track."
        }
    }
}

final class SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer?

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    var usesOnDeviceRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition == true
    }

    func transcribe(fileURL: URL, source: String) async throws -> [TranscriptSegment] {
        guard let recognizer, recognizer.isAvailable else { throw TranscriptionError.recognizerUnavailable }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        return try await withCheckedThrowingContinuation { continuation in
            var completed = false
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                guard !completed else { return }
                if let error {
                    completed = true
                    task?.cancel()
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                completed = true
                let segments = result.bestTranscription.segments.map { segment in
                    TranscriptSegment(
                        source: source,
                        timestamp: segment.timestamp,
                        duration: segment.duration,
                        text: segment.substring
                    )
                }
                task?.finish()
                if segments.isEmpty {
                    continuation.resume(throwing: TranscriptionError.noSpeech)
                } else {
                    continuation.resume(returning: segments)
                }
            }
        }
    }
}
