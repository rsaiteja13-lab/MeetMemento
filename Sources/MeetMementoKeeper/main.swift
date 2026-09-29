import AppKit
import Foundation

@main
enum MeetMementoKeeper {
    private static let mainBundleIdentifier = "com.meetmemento.mac"
    private static let checkInterval: TimeInterval = 3
    private static let heartbeatTimeout: TimeInterval = 6 * 60
    private static var lastWakeAt = Date()

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            guard containingAppURL.pathExtension == "app" else {
                fputs("MeetMementoKeeper could not resolve its containing app.\n", stderr)
                exit(1)
            }
            print("MeetMementoKeeper self-test passed")
            return
        }

        record("Background guardian started")
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            lastWakeAt = Date()
            record("Background guardian noticed system wake")
        }
        ensureMainAppIsRunning()
        Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { _ in
            ensureMainAppIsRunning()
        }
        RunLoop.main.run()
    }

    private static var containingAppURL: URL {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func ensureMainAppIsRunning() {
        let runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: mainBundleIdentifier
        )
        if !runningApplications.isEmpty {
            if heartbeatIsStale {
                record("Background guardian is restarting an unresponsive app")
                runningApplications.forEach { $0.forceTerminate() }
            }
            return
        }

        let appURL = containingAppURL
        guard appURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: appURL.path) else {
            record("Background guardian could not find the main app")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                record("Background guardian could not relaunch the app: \(error.localizedDescription)")
            } else {
                record("Background guardian relaunched the app")
            }
        }
    }

    private static var heartbeatIsStale: Bool {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let logURL = applicationSupport
            .appendingPathComponent("MeetMemento", isDirectory: true)
            .appendingPathComponent("app-diagnostics.log")
        guard let values = try? logURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate else { return false }
        let latestKnownActivity = max(modifiedAt, lastWakeAt)
        return Date().timeIntervalSince(latestKnownActivity) > heartbeatTimeout
    }

    private static func record(_ message: String) {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let appFolder = applicationSupport.appendingPathComponent("MeetMemento", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        let logURL = appFolder.appendingPathComponent("app-diagnostics.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? data.write(to: logURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
