import Foundation

final class AppDiagnostics: @unchecked Sendable {
    static let shared = AppDiagnostics()

    private let queue = DispatchQueue(label: "MeetMemento.AppDiagnostics")
    private let logURL: URL
    private let previousLogURL: URL
    private let maximumLogSize: UInt64 = 1_000_000

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let appFolder = applicationSupport.appendingPathComponent("MeetMemento", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        logURL = appFolder.appendingPathComponent("app-diagnostics.log")
        previousLogURL = appFolder.appendingPathComponent("app-diagnostics.previous.log")
    }

    func record(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        queue.async { [logURL, previousLogURL, maximumLogSize] in
            let size = (try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if UInt64(max(0, size)) >= maximumLogSize {
                try? FileManager.default.removeItem(at: previousLogURL)
                try? FileManager.default.moveItem(at: logURL, to: previousLogURL)
            }
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try? data.write(to: logURL, options: .atomic)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }
}
