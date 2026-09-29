import Foundation
import Speech

enum TranscriptionError: LocalizedError {
    case recognizerUnavailable
    case noSpeech
    case timedOut

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "A transcript isn’t available for the current language."
        case .noSpeech: return "No speech was detected in this audio."
        case .timedOut: return "Speech recognition stopped responding. The recording is still available."
        }
    }
}

private final class RecognitionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var completed = false

    init(_ continuation: CheckedContinuation<[TranscriptSegment], Error>) {
        self.continuation = continuation
    }

    func attach(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        if completed {
            lock.unlock()
            task.cancel()
            return
        }
        recognitionTask = task
        lock.unlock()
    }

    func finish(_ result: Result<[TranscriptSegment], Error>) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        let task = recognitionTask
        recognitionTask = nil
        lock.unlock()

        task?.cancel()
        continuation.resume(with: result)
    }
}

final class SpeechTranscriber {
    private static let recognitionTimeout: TimeInterval = 75
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
            let completion = RecognitionCompletion(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    completion.finish(.failure(error))
                    return
                }
                guard let result, result.isFinal else { return }
                let segments = result.bestTranscription.segments.map { segment in
                    TranscriptSegment(
                        source: source,
                        timestamp: segment.timestamp,
                        duration: segment.duration,
                        text: segment.substring
                    )
                }
                if segments.isEmpty {
                    completion.finish(.failure(TranscriptionError.noSpeech))
                } else {
                    completion.finish(.success(segments))
                }
            }
            completion.attach(task)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + Self.recognitionTimeout
            ) {
                completion.finish(.failure(TranscriptionError.timedOut))
            }
        }
    }
}
