import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case zoomNotRunning
    case noDisplay
    case noAudioReceived
    case noVideoReceived
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .zoomNotRunning: return "Zoom is not running."
        case .noDisplay: return "No display is available for Zoom capture."
        case .noAudioReceived: return "No Zoom audio was received."
        case .noVideoReceived: return "No Zoom video frames were received."
        case .writerFailed(let message): return "The recording could not be written: \(message)"
        }
    }
}

/// Captures only Zoom's windows and application audio. Unrelated apps on the
/// selected display are excluded from the stream.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let audioOutputURL: URL
    private let videoOutputURL: URL
    private let queue = DispatchQueue(label: "MeetMemento.ZoomCapture")
    private var stream: SCStream?

    private var audioWriter: AVAssetWriter?
    private var audioWriterInput: AVAssetWriterInput?
    private var audioFirstTimestamp: CMTime?

    private var movieWriter: AVAssetWriter?
    private var movieVideoInput: AVAssetWriterInput?
    private var movieFirstTimestamp: CMTime?
    private var movieLastTimestamp: CMTime?
    private var appendedVideoSamples = 0
    private var writerError: Error?
    private var nativeScreenRecorder: AnyObject?

    init(audioOutputURL: URL, videoOutputURL: URL) {
        self.audioOutputURL = audioOutputURL
        self.videoOutputURL = videoOutputURL
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let zoomApplications = content.applications.filter(Self.isZoomApplication)
        guard !zoomApplications.isEmpty else {
            throw CaptureError.zoomNotRunning
        }
        guard let display = Self.captureDisplay(in: content, for: zoomApplications) else {
            throw CaptureError.noDisplay
        }

        let dimensions = Self.outputDimensions(for: display)

        // The filter keeps the recording scoped to Zoom. Its audio is captured
        // before macOS routes it to speakers, AirPods, Bluetooth, or a dock.
        let filter = SCContentFilter(display: display, including: zoomApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        if #available(macOS 15.0, *) {
            let recorder = NativeScreenRecorder(outputURL: videoOutputURL)
            try recorder.add(to: stream)
            nativeScreenRecorder = recorder
        } else {
            // On macOS 13 and 14, keep video in its own fragmented writer. Keeping
            // Zoom audio in the separate audio writer prevents one encoder from
            // invalidating both files if a media timestamp changes mid-meeting.
            try prepareMovieWriter(width: dimensions.width, height: dimensions.height)
        }

        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async throws {
        var captureStopError: Error?
        var nativeRecordingError: Error?
        if let stream {
            if #available(macOS 15.0, *),
               let recorder = nativeScreenRecorder as? NativeScreenRecorder {
                do { try recorder.remove(from: stream) }
                catch { nativeRecordingError = error }
            }
            do { try await stream.stopCapture() }
            catch { captureStopError = error }

            if #available(macOS 15.0, *),
               let recorder = nativeScreenRecorder as? NativeScreenRecorder {
                let completionError = await recorder.waitForCompletion()
                if nativeRecordingError == nil {
                    nativeRecordingError = completionError
                }
            }
        }
        stream = nil
        nativeScreenRecorder = nil

        let finalizationError = await withCheckedContinuation { continuation in
            queue.async { [self] in
                finishWriters { error in continuation.resume(returning: error) }
            }
        }

        if let writerError { throw writerError }
        if let captureStopError { throw captureStopError }
        if let nativeRecordingError { throw nativeRecordingError }
        if let finalizationError { throw finalizationError }
        if audioFirstTimestamp == nil { throw CaptureError.noAudioReceived }
        if appendedVideoSamples == 0 { throw CaptureError.noVideoReceived }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, writerError == nil else { return }
            writerError = error
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            switch outputType {
            case .screen:
                try appendVideo(sampleBuffer)
            case .audio:
                try appendAudio(sampleBuffer)
            case .microphone:
                break
            @unknown default:
                break
            }
        } catch {
            if writerError == nil {
                writerError = error
            }
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) throws {
        if nativeScreenRecorder != nil {
            appendedVideoSamples += 1
            return
        }
        guard let writer = movieWriter, let input = movieVideoInput else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        try startMovieIfNeeded(writer: writer, at: timestamp)
        guard writer.status == .writing else {
            throw writer.error ?? CaptureError.writerFailed("Video writer stopped unexpectedly")
        }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            appendedVideoSamples += 1
            movieLastTimestamp = timestamp
        } else {
            throw writer.error ?? CaptureError.writerFailed("Video append failed")
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) throws {
        if audioWriter == nil { try prepareAudioWriter(using: sampleBuffer) }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if let writer = audioWriter, let input = audioWriterInput, input.isReadyForMoreMediaData {
            if audioFirstTimestamp == nil {
                audioFirstTimestamp = timestamp
                guard writer.startWriting() else {
                    throw writer.error ?? CaptureError.writerFailed("Audio writer could not start")
                }
                writer.startSession(atSourceTime: timestamp)
            }
            if !input.append(sampleBuffer) {
                throw writer.error ?? CaptureError.writerFailed("Audio append failed")
            }
        }

    }

    private func startMovieIfNeeded(writer: AVAssetWriter, at timestamp: CMTime) throws {
        guard movieFirstTimestamp == nil else { return }
        movieFirstTimestamp = timestamp
        if writer.startWriting() {
            writer.startSession(atSourceTime: timestamp)
        } else {
            throw writer.error ?? CaptureError.writerFailed("Video writer could not start")
        }
    }

    private func prepareAudioWriter(using sampleBuffer: CMSampleBuffer) throws {
        let writer = try AVAssetWriter(outputURL: audioOutputURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: Self.audioSettings,
            sourceFormatHint: CMSampleBufferGetFormatDescription(sampleBuffer)
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.writerFailed("Unsupported Zoom audio format") }
        writer.add(input)
        audioWriter = writer
        audioWriterInput = input
    }

    private func prepareMovieWriter(width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: videoOutputURL, fileType: .mp4)
        // Fragmented output keeps already-written sections independently
        // playable if a meeting, encoder, or app ends unexpectedly.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw CaptureError.writerFailed("This Mac cannot create the Zoom video file")
        }
        writer.add(videoInput)
        movieWriter = writer
        movieVideoInput = videoInput
    }

    private func finishWriters(completion: @escaping (Error?) -> Void) {
        let earlierError = writerError

        func finishMovie(after audioError: Error?) {
            guard let writer = movieWriter, movieFirstTimestamp != nil else {
                completion(earlierError ?? audioError)
                return
            }
            if let lastTimestamp = movieLastTimestamp, lastTimestamp.isNumeric {
                writer.endSession(atSourceTime: lastTimestamp)
            }
            movieVideoInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self else {
                    completion(audioError)
                    return
                }
                self.queue.async {
                    let movieError = writer.status == .completed
                        ? nil
                        : (writer.error ?? CaptureError.writerFailed("Video finalization failed"))
                    completion(earlierError ?? audioError ?? movieError)
                }
            }
        }

        guard let writer = audioWriter, audioFirstTimestamp != nil else {
            finishMovie(after: nil)
            return
        }
        audioWriterInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else {
                completion(writer.error)
                return
            }
            self.queue.async {
                let audioError = writer.status == .completed
                    ? nil
                    : (writer.error ?? CaptureError.writerFailed("Audio finalization failed"))
                finishMovie(after: audioError)
            }
        }
    }

    private static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000
    ]

    private static func isZoomApplication(_ application: SCRunningApplication) -> Bool {
        let bundleID = application.bundleIdentifier.lowercased()
        let name = application.applicationName.lowercased()
        return bundleID == "us.zoom.xos"
            || bundleID.contains("zoom")
            || name == "zoom"
            || name == "zoom.us"
            || name == "zoom workplace"
            || name == "caphost"
            || name == "cpthost"
    }

    private static func captureDisplay(
        in content: SCShareableContent,
        for zoomApplications: [SCRunningApplication]
    ) -> SCDisplay? {
        guard !content.displays.isEmpty else { return nil }
        let processIDs = Set(zoomApplications.map(\.processID))
        guard let largestZoomWindow = content.windows
            .filter({ window in
                guard let owner = window.owningApplication else { return false }
                return processIDs.contains(owner.processID) && window.isOnScreen
            })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else {
            return content.displays.first
        }

        return content.displays.max { left, right in
            left.frame.intersection(largestZoomWindow.frame).area
                < right.frame.intersection(largestZoomWindow.frame).area
        }
    }

    private static func outputDimensions(for display: SCDisplay) -> (width: Int, height: Int) {
        let sourceWidth = max(2, display.width)
        let sourceHeight = max(2, display.height)
        let scale = min(1, min(1_920 / Double(sourceWidth), 1_080 / Double(sourceHeight)))
        let width = max(2, Int(Double(sourceWidth) * scale) / 2 * 2)
        let height = max(2, Int(Double(sourceHeight) * scale) / 2 * 2)
        return (width, height)
    }
}

/// Uses ScreenCaptureKit's recorder on modern macOS releases. Apple owns the
/// audio/video interleaving and file finalization in this path, avoiding the
/// timestamp coupling that can leave a hand-built MP4 without its movie index.
@available(macOS 15.0, *)
private final class NativeScreenRecorder: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "MeetMemento.NativeRecording")
    private let configuration: SCRecordingOutputConfiguration
    private lazy var output = SCRecordingOutput(configuration: configuration, delegate: self)
    private var completionError: Error?
    private var didComplete = false
    private var waiter: CheckedContinuation<Error?, Never>?

    init(outputURL: URL) {
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = outputURL
        configuration.outputFileType = .mp4
        if configuration.availableVideoCodecTypes.contains(.h264) {
            configuration.videoCodecType = .h264
        }
        self.configuration = configuration
        super.init()
    }

    func add(to stream: SCStream) throws {
        try stream.addRecordingOutput(output)
    }

    func remove(from stream: SCStream) throws {
        try stream.removeRecordingOutput(output)
    }

    func waitForCompletion() async -> Error? {
        await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                if didComplete {
                    continuation.resume(returning: completionError)
                    return
                }
                waiter = continuation
                stateQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let self, let waiter = self.waiter else { return }
                    self.waiter = nil
                    self.didComplete = true
                    waiter.resume(returning: CaptureError.writerFailed("Screen recording did not finish in time"))
                }
            }
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        complete(with: nil)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        complete(with: error)
    }

    private func complete(with error: Error?) {
        stateQueue.async { [self] in
            guard !didComplete else { return }
            didComplete = true
            completionError = error
            let continuation = waiter
            waiter = nil
            continuation?.resume(returning: error)
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
