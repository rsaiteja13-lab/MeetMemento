import AVFoundation
import Foundation

final class MicrophoneCapture: @unchecked Sendable {
    private let outputURL: URL
    private let engine = AVAudioEngine()
    private let controlQueue = DispatchQueue(label: "MeetMemento.MicrophoneControl")
    private let fileLock = NSLock()
    private let recordingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private var file: AVAudioFile?
    private var writeError: Error?
    private var configurationObserver: NSObjectProtocol?
    private var pendingRestart: DispatchWorkItem?
    private var tapInstalled = false
    private var isActive = false
    private var ignoreConfigurationChangesUntil = Date.distantPast

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() throws {
        try controlQueue.sync {
            guard !isActive else { return }
            file = try AVAudioFile(forWriting: outputURL, settings: recordingFormat.settings)
            isActive = true
            do {
                try installTapAndStartEngine()
                observeInputDeviceChanges()
            } catch {
                isActive = false
                file = nil
                throw error
            }
        }
    }

    func stop() async throws {
        let finalError: Error? = controlQueue.sync {
            isActive = false
            pendingRestart?.cancel()
            pendingRestart = nil
            if let configurationObserver {
                NotificationCenter.default.removeObserver(configurationObserver)
                self.configurationObserver = nil
            }
            engine.stop()
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            fileLock.lock()
            file = nil
            let error = writeError
            fileLock.unlock()
            return error
        }
        if let finalError { throw finalError }
    }

    private func observeInputDeviceChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRestartForCurrentInput()
        }
    }

    private func scheduleRestartForCurrentInput() {
        controlQueue.async { [weak self] in
            guard let self, self.isActive, Date() >= self.ignoreConfigurationChangesUntil else { return }
            self.pendingRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.restartForCurrentInput(attempt: 0) }
            self.pendingRestart = work
            self.controlQueue.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    private func restartForCurrentInput(attempt: Int) {
        guard isActive else { return }
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        do {
            try installTapAndStartEngine()
        } catch {
            // Bluetooth inputs can briefly disappear while macOS changes audio profiles.
            if attempt < 4 {
                controlQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.restartForCurrentInput(attempt: attempt + 1)
                }
            } else {
                setWriteError(error)
            }
        }
    }

    private func installTapAndStartEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            throw CaptureError.writerFailed("No microphone format is available")
        }

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                let converted = try Self.convert(buffer, with: converter, to: self.recordingFormat)
                guard converted.frameLength > 0 else { return }
                self.fileLock.lock()
                defer { self.fileLock.unlock() }
                try self.file?.write(from: converted)
            } catch {
                self.setWriteError(error)
            }
        }
        tapInstalled = true
        ignoreConfigurationChangesUntil = Date().addingTimeInterval(1.5)
        engine.prepare()
        try engine.start()
    }

    private func setWriteError(_ error: Error) {
        fileLock.lock()
        if writeError == nil { writeError = error }
        fileLock.unlock()
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CaptureError.writerFailed("The microphone audio could not be converted")
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw conversionError ?? CaptureError.writerFailed("The microphone audio could not be converted")
        }
        return output
    }
}
