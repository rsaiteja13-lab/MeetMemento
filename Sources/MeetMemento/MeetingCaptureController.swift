import Foundation

final class MeetingCaptureController {
    private var systemAudio: SystemAudioCapture?
    private var microphone: MicrophoneCapture?

    func start(in folderURL: URL, includeMicrophone: Bool) async throws -> ActiveCapture {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let videoURL = folderURL.appendingPathComponent("zoom-screen.mp4")
        let systemAudioURL = folderURL.appendingPathComponent("meeting-audio.m4a")
        let microphoneURL = includeMicrophone ? folderURL.appendingPathComponent("my-microphone.caf") : nil

        if let microphoneURL {
            let microphone = MicrophoneCapture(outputURL: microphoneURL)
            do {
                try microphone.start()
                self.microphone = microphone
            } catch {
                // Zoom output is still useful if the microphone is temporarily unavailable.
                self.microphone = nil
            }
        }

        let systemAudio = SystemAudioCapture(audioOutputURL: systemAudioURL, videoOutputURL: videoURL)
        do {
            try await systemAudio.start()
            self.systemAudio = systemAudio
        } catch {
            try? await microphone?.stop()
            self.microphone = nil
            throw error
        }

        return ActiveCapture(
            id: UUID(),
            startedAt: Date(),
            folderURL: folderURL,
            videoURL: videoURL,
            systemAudioURL: systemAudioURL,
            microphoneURL: self.microphone == nil ? nil : microphoneURL
        )
    }

    func stop() async -> [Error] {
        var errors: [Error] = []
        if let systemAudio {
            do { try await systemAudio.stop() }
            catch { errors.append(error) }
        }
        if let microphone {
            do { try await microphone.stop() }
            catch { errors.append(error) }
        }
        self.systemAudio = nil
        self.microphone = nil
        return errors
    }
}
