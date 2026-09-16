import AppKit
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
        case .noDisplay: return "MeetMemento couldn’t find a screen to record."
        case .noAudioReceived: return "No meeting audio was captured."
        case .noVideoReceived: return "No Zoom video was captured."
        case .writerFailed(let message): return "MeetMemento couldn’t save the recording: \(message)"
        }
    }
}

/// Uses independent ScreenCaptureKit streams for Zoom video and system audio.
/// Zoom's audio can be produced by helper processes that are not represented by
/// Zoom's visible windows, so the audio stream captures every audible app while
/// a Zoom meeting is active and excludes MeetMemento itself. The video stream
/// remains scoped to Zoom's windows.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let audioOutputURL: URL
    private let videoOutputURL: URL
    private let videoQueue = DispatchQueue(label: "MeetMemento.ZoomVideo")
    private let audioQueue = DispatchQueue(label: "MeetMemento.SystemAudio")
    private let logQueue = DispatchQueue(label: "MeetMemento.CaptureDiagnostics")
    private let stateLock = NSLock()

    private var videoStream: SCStream?
    private var audioStream: SCStream?
    private var captureDisplayID: CGDirectDisplayID?
    private var captureDimensions: (width: Int, height: Int)?
    private var isStopping = false
    private var videoRestartInProgress = false
    private var videoMonitorTask: Task<Void, Never>?
    private var lastVideoCallbackAt = Date()
    private var lastVideoFilterRefreshAt = Date.distantPast

    private var audioWriter: AVAssetWriter?
    private var audioWriterInput: AVAssetWriterInput?
    private var audioFirstTimestamp: CMTime?
    private var appendedAudioSamples = 0
    private var audioWriterError: Error?

    private var movieWriter: AVAssetWriter?
    private var movieVideoInput: AVAssetWriterInput?
    private var moviePixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoTimelineStartUptime: TimeInterval = 0
    private var movieFirstTimestamp: CMTime?
    private var movieLastTimestamp: CMTime?
    private var lastVideoPixelBuffer: CVPixelBuffer?
    private var appendedVideoSamples = 0
    private var videoWriterError: Error?

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

        captureDisplayID = display.displayID
        captureDimensions = Self.outputDimensions(for: display)
        videoTimelineStartUptime = ProcessInfo.processInfo.systemUptime
        withLockedState {
            isStopping = false
            videoRestartInProgress = false
            lastVideoCallbackAt = Date()
            lastVideoFilterRefreshAt = Date()
        }
        log("Capture starting on display \(display.displayID); Zoom processes: \(Self.zoomProcessDescription(zoomApplications))")
        try prepareMovieWriter(for: display)

        let audioConfiguration = SCStreamConfiguration()
        audioConfiguration.capturesAudio = true
        audioConfiguration.excludesCurrentProcessAudio = true
        audioConfiguration.sampleRate = 48_000
        audioConfiguration.channelCount = 2
        // No screen output is attached to this stream. Small dimensions keep its
        // internal surface inexpensive while audio continues independently of
        // Zoom window and helper-process changes.
        audioConfiguration.width = 2
        audioConfiguration.height = 2
        audioConfiguration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        audioConfiguration.queueDepth = 3

        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
                || $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let audioFilter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let audioStream = SCStream(filter: audioFilter, configuration: audioConfiguration, delegate: self)
        try audioStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.audioStream = audioStream

        let videoStream = try makeVideoStream(
            content: content,
            display: display,
            zoomApplications: zoomApplications
        )
        self.videoStream = videoStream

        do {
            try await audioStream.startCapture()
            try await videoStream.startCapture()
            startVideoMonitor()
            log("Audio and video streams started")
        } catch {
            try? await audioStream.stopCapture()
            try? await videoStream.stopCapture()
            self.audioStream = nil
            self.videoStream = nil
            _ = await finishAudioWriter()
            _ = await finishMovieWriter()
            log("Capture startup failed: \(error.localizedDescription)")
            throw error
        }
    }

    func stop() async throws {
        let monitorTask = withLockedState {
            isStopping = true
            let task = videoMonitorTask
            videoMonitorTask = nil
            return task
        }
        monitorTask?.cancel()
        log("Capture stopping")

        // Stop producers first, then drain each serial sample queue before
        // finalizing. This prevents late buffers from racing with markAsFinished.
        if let videoStream { try? await videoStream.stopCapture() }
        if let audioStream { try? await audioStream.stopCapture() }
        videoStream = nil
        audioStream = nil

        let audioFinalizationError = await finishAudioWriter()
        let videoFinalizationError = await finishMovieWriter()
        log("Capture finalized with \(appendedVideoSamples) video frames and \(appendedAudioSamples) audio samples")
        logQueue.sync {}

        if let videoWriterError { throw videoWriterError }
        if let audioWriterError { throw audioWriterError }
        if let videoFinalizationError { throw videoFinalizationError }
        if let audioFinalizationError { throw audioFinalizationError }
        if appendedAudioSamples == 0 { throw CaptureError.noAudioReceived }
        if appendedVideoSamples == 0 { throw CaptureError.noVideoReceived }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if isCurrentVideoStream(stream) {
            requestVideoRestart(reason: "ScreenCaptureKit stopped the Zoom video stream: \(error.localizedDescription)")
        } else if stream === audioStream, !stoppingSnapshot() {
            log("System-audio stream stopped unexpectedly: \(error.localizedDescription)")
            audioQueue.async { [weak self] in
                guard let self, self.audioWriterError == nil else { return }
                self.audioWriterError = error
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        if outputType == .screen, isCurrentVideoStream(stream) {
            stateLock.lock()
            lastVideoCallbackAt = Date()
            stateLock.unlock()
        }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if outputType == .screen, stream === videoStream {
            do { try appendVideo(sampleBuffer) }
            catch { if videoWriterError == nil { videoWriterError = error } }
        } else if outputType == .audio, stream === audioStream {
            do { try appendAudio(sampleBuffer) }
            catch { if audioWriterError == nil { audioWriterError = error } }
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) throws {
        guard Self.isCompleteVideoFrame(sampleBuffer),
              let writer = movieWriter,
              let input = movieVideoInput,
              let adaptor = moviePixelBufferAdaptor,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Replacement ScreenCaptureKit streams can use different source-time
        // origins. Keep every frame on one monotonic meeting timeline so a
        // reconnect cannot reset or compress the saved movie.
        let timestamp = currentVideoTimelineTimestamp()
        try startMovieIfNeeded(writer: writer, at: timestamp)
        guard writer.status == .writing else {
            throw writer.error ?? CaptureError.writerFailed("Video saving stopped unexpectedly")
        }
        guard input.isReadyForMoreMediaData else { return }
        if let previousTimestamp = movieLastTimestamp,
           CMTimeCompare(timestamp, previousTimestamp) <= 0 {
            return
        }
        if adaptor.append(pixelBuffer, withPresentationTime: timestamp) {
            appendedVideoSamples += 1
            movieLastTimestamp = timestamp
            lastVideoPixelBuffer = pixelBuffer
        } else {
            throw writer.error ?? CaptureError.writerFailed("A video frame couldn’t be saved")
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) throws {
        if audioWriter == nil { try prepareAudioWriter(using: sampleBuffer) }
        guard let writer = audioWriter, let input = audioWriterInput else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Start the writer before consulting isReadyForMoreMediaData. On recent
        // macOS versions an input may report not-ready while its writer is still
        // .unknown, which previously prevented the audio file from ever starting.
        if audioFirstTimestamp == nil {
            guard writer.startWriting() else {
                throw writer.error ?? CaptureError.writerFailed("Meeting audio couldn’t start saving")
            }
            writer.startSession(atSourceTime: timestamp)
            audioFirstTimestamp = timestamp
        }
        guard writer.status == .writing else {
            throw writer.error ?? CaptureError.writerFailed("Meeting audio stopped saving unexpectedly")
        }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            appendedAudioSamples += 1
        } else {
            throw writer.error ?? CaptureError.writerFailed("Part of the meeting audio couldn’t be saved")
        }
    }

    private func startMovieIfNeeded(writer: AVAssetWriter, at _: CMTime) throws {
        guard movieFirstTimestamp == nil else { return }
        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.writerFailed("Video couldn’t start saving")
        }
        // Include the short interval before the first complete screen frame.
        writer.startSession(atSourceTime: .zero)
        movieFirstTimestamp = .zero
    }

    private func prepareAudioWriter(using sampleBuffer: CMSampleBuffer) throws {
        let writer = try AVAssetWriter(outputURL: audioOutputURL, fileType: .m4a)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: Self.audioSettings,
            sourceFormatHint: CMSampleBufferGetFormatDescription(sampleBuffer)
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.writerFailed("This Mac’s meeting-audio format isn’t supported") }
        writer.add(input)
        audioWriter = writer
        audioWriterInput = input
    }

    private func prepareMovieWriter(for display: SCDisplay) throws {
        let dimensions = Self.outputDimensions(for: display)
        let writer = try AVAssetWriter(outputURL: videoOutputURL, fileType: .mp4)
        // Do not set movieFragmentInterval here. On macOS 26 the H.264 pixel-
        // buffer writer accepts frames beyond the first fragment but only commits
        // the initial five seconds to the MP4. Normal finalization produces the
        // complete long-duration video.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 10,
                AVVideoMaxKeyFrameIntervalKey: 50
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // This is a durable meeting record, not a live broadcast. Real-time mode
        // permits the encoder to silently discard late frames; on long or static
        // calls that left only the first five-second fragments.
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = 600

        guard writer.canAdd(videoInput) else {
            throw CaptureError.writerFailed("This Mac cannot create the Zoom video file")
        }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height
            ]
        )
        movieWriter = writer
        movieVideoInput = videoInput
        moviePixelBufferAdaptor = adaptor
    }

    private func finishAudioWriter() async -> Error? {
        await withCheckedContinuation { continuation in
            audioQueue.async { [self] in
                guard let writer = audioWriter, audioFirstTimestamp != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                audioWriterInput?.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self else {
                        continuation.resume(returning: writer.error)
                        return
                    }
                    self.audioQueue.async {
                        continuation.resume(returning: writer.status == .completed
                            ? nil
                            : (writer.error ?? CaptureError.writerFailed("Meeting audio couldn’t finish saving")))
                    }
                }
            }
        }
    }

    private func finishMovieWriter() async -> Error? {
        await withCheckedContinuation { continuation in
            videoQueue.async { [self] in
                guard let writer = movieWriter, movieFirstTimestamp != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                // ScreenCaptureKit sends an idle status instead of another complete
                // pixel buffer when a Zoom window is unchanged. Append the last
                // picture at stop time so a static meeting still has the full
                // meeting duration instead of a five-second movie.
                var finalTimestamp = currentVideoTimelineTimestamp()
                if let lastTimestamp = movieLastTimestamp,
                   lastTimestamp.isNumeric,
                   CMTimeCompare(finalTimestamp, lastTimestamp) <= 0 {
                    finalTimestamp = CMTimeAdd(lastTimestamp, CMTime(value: 1, timescale: 30))
                }
                var finalFrameError: Error?
                if let pixelBuffer = lastVideoPixelBuffer,
                   let adaptor = moviePixelBufferAdaptor,
                   let input = movieVideoInput {
                    // Encoder backpressure is common directly after capture stops.
                    // Wait briefly instead of silently skipping the held frame,
                    // which was the direct cause of five-second static videos.
                    let readinessDeadline = Date().addingTimeInterval(10)
                    while !input.isReadyForMoreMediaData && Date() < readinessDeadline {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    if input.isReadyForMoreMediaData,
                       adaptor.append(pixelBuffer, withPresentationTime: finalTimestamp) {
                        appendedVideoSamples += 1
                        movieLastTimestamp = finalTimestamp
                        log("Extended video timeline to \(String(format: "%.2f", finalTimestamp.seconds)) seconds")
                    } else {
                        finalFrameError = writer.error
                            ?? CaptureError.writerFailed("The final video frame couldn’t be saved")
                        log("Could not extend video timeline: \(finalFrameError!.localizedDescription)")
                    }
                }
                if movieLastTimestamp?.isNumeric == true {
                    writer.endSession(atSourceTime: finalTimestamp)
                }
                movieVideoInput?.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self else {
                        continuation.resume(returning: writer.error)
                        return
                    }
                    self.videoQueue.async {
                        let writerError = writer.status == .completed
                            ? nil
                            : (writer.error ?? CaptureError.writerFailed("Video couldn’t finish saving"))
                        continuation.resume(returning: writerError ?? finalFrameError)
                    }
                }
            }
        }
    }

    private func currentVideoTimelineTimestamp() -> CMTime {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - videoTimelineStartUptime)
        return CMTime(seconds: elapsed, preferredTimescale: 600)
    }

    private func appendVideoKeepaliveFrame() {
        guard !stoppingSnapshot(),
              let writer = movieWriter,
              let input = movieVideoInput,
              let adaptor = moviePixelBufferAdaptor,
              let pixelBuffer = lastVideoPixelBuffer,
              movieFirstTimestamp != nil,
              writer.status == .writing,
              input.isReadyForMoreMediaData else { return }

        let timestamp = currentVideoTimelineTimestamp()
        if let lastTimestamp = movieLastTimestamp,
           timestamp.seconds - lastTimestamp.seconds < 1 {
            return
        }
        if adaptor.append(pixelBuffer, withPresentationTime: timestamp) {
            appendedVideoSamples += 1
            movieLastTimestamp = timestamp
        } else if videoWriterError == nil {
            videoWriterError = writer.error
                ?? CaptureError.writerFailed("The video timeline couldn’t be extended")
        }
    }

    private static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000
    ]

    private static func isCompleteVideoFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
              let attachment = attachments.first,
              let rawStatus = attachment[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return false
        }
        return status == .complete
    }

    private func makeVideoStream(
        content: SCShareableContent,
        display: SCDisplay,
        zoomApplications: [SCRunningApplication]
    ) throws -> SCStream {
        let dimensions = captureDimensions ?? Self.outputDimensions(for: display)
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        // Ten frames per second is smooth enough for slides, demos, and speaker
        // video while remaining sustainable for hours on Intel and Apple silicon.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.queueDepth = 5

        let filter = SCContentFilter(display: display, including: zoomApplications, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        return stream
    }

    private func startVideoMonitor() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.checkVideoHealth()
            }
        }
        stateLock.lock()
        videoMonitorTask?.cancel()
        videoMonitorTask = task
        stateLock.unlock()
    }

    private func checkVideoHealth() async {
        // ScreenCaptureKit may report an idle frame instead of a new image when
        // Zoom is visually static. Duplicate the last picture periodically so
        // long recordings and crash-recoverable fragments keep advancing.
        videoQueue.async { [weak self] in
            self?.appendVideoKeepaliveFrame()
        }

        let snapshot = withLockedState {
            (
                shouldStop: isStopping,
                secondsSinceCallback: Date().timeIntervalSince(lastVideoCallbackAt),
                secondsSinceFilterRefresh: Date().timeIntervalSince(lastVideoFilterRefreshAt),
                recoveryInProgress: videoRestartInProgress
            )
        }
        guard !snapshot.shouldStop, !snapshot.recoveryInProgress else { return }

        if snapshot.secondsSinceCallback > 10 {
            requestVideoRestart(reason: "No Zoom video callbacks arrived for \(Int(snapshot.secondsSinceCallback)) seconds")
        } else if snapshot.secondsSinceFilterRefresh > 12 {
            await refreshVideoFilter()
        }
    }

    private func refreshVideoFilter() async {
        guard let stream = currentVideoStream(), !stoppingSnapshot() else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let zoomApplications = content.applications.filter(Self.isZoomApplication)
            guard !zoomApplications.isEmpty else { return }
            let display = content.displays.first(where: { $0.displayID == captureDisplayID })
                ?? Self.captureDisplay(in: content, for: zoomApplications)
            guard let display else { throw CaptureError.noDisplay }
            let filter = SCContentFilter(display: display, including: zoomApplications, exceptingWindows: [])
            try await stream.updateContentFilter(filter)
            guard isCurrentVideoStream(stream) else { return }
            withLockedState { lastVideoFilterRefreshAt = Date() }
            log("Refreshed Zoom video filter; processes: \(Self.zoomProcessDescription(zoomApplications))")
        } catch {
            requestVideoRestart(reason: "Zoom video filter refresh failed: \(error.localizedDescription)")
        }
    }

    private func requestVideoRestart(reason: String) {
        stateLock.lock()
        guard !isStopping, !videoRestartInProgress else {
            stateLock.unlock()
            return
        }
        videoRestartInProgress = true
        let oldStream = videoStream
        videoStream = nil
        stateLock.unlock()

        log("Restarting Zoom video stream: \(reason)")
        Task { [weak self] in
            await self?.recoverVideoStream(oldStream: oldStream)
        }
    }

    private func recoverVideoStream(oldStream: SCStream?) async {
        if let oldStream { try? await oldStream.stopCapture() }
        var attempt = 0
        while !stoppingSnapshot() {
            attempt += 1
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                let zoomApplications = content.applications.filter(Self.isZoomApplication)
                guard !zoomApplications.isEmpty else { throw CaptureError.zoomNotRunning }
                let display = content.displays.first(where: { $0.displayID == captureDisplayID })
                    ?? Self.captureDisplay(in: content, for: zoomApplications)
                guard let display else { throw CaptureError.noDisplay }
                let replacement = try makeVideoStream(
                    content: content,
                    display: display,
                    zoomApplications: zoomApplications
                )

                let shouldInstall = withLockedState {
                    let install = !isStopping
                    if install {
                        videoStream = replacement
                        lastVideoCallbackAt = Date()
                        lastVideoFilterRefreshAt = Date()
                    }
                    return install
                }
                guard shouldInstall else {
                    try? await replacement.stopCapture()
                    break
                }

                do {
                    try await replacement.startCapture()
                } catch {
                    withLockedState {
                        if videoStream === replacement { videoStream = nil }
                    }
                    throw error
                }

                withLockedState { videoRestartInProgress = false }
                log("Zoom video stream recovered on attempt \(attempt); processes: \(Self.zoomProcessDescription(zoomApplications))")
                return
            } catch {
                log("Zoom video recovery attempt \(attempt) failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        withLockedState { videoRestartInProgress = false }
    }

    private func isCurrentVideoStream(_ stream: SCStream) -> Bool {
        withLockedState { stream === videoStream }
    }

    private func currentVideoStream() -> SCStream? {
        withLockedState { videoStream }
    }

    private func stoppingSnapshot() -> Bool {
        withLockedState { isStopping }
    }

    private func withLockedState<T>(_ operation: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }

    private func log(_ message: String) {
        let logURL = videoOutputURL.deletingLastPathComponent().appendingPathComponent("capture-diagnostics.log")
        logQueue.async {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try? data.write(to: logURL, options: .atomic)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {}
        }
    }

    private static func zoomProcessDescription(_ applications: [SCRunningApplication]) -> String {
        applications
            .map { "\($0.applicationName)[\($0.processID)]" }
            .sorted()
            .joined(separator: ", ")
    }

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

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
