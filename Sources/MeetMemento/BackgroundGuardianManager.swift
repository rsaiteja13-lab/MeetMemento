import Foundation

enum BackgroundGuardianError: LocalizedError {
    case helperMissing
    case launchctlFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "The background guardian is missing from this app build."
        case .launchctlFailed(let status):
            return "macOS couldn’t start the background guardian (status \(status))."
        }
    }
}

enum BackgroundGuardianManager {
    private static let label = "com.meetmemento.mac.keeper"

    static func install(for appURL: URL, forceReload: Bool) throws {
        let helperURL = appURL.appendingPathComponent("Contents/Resources/MeetMementoKeeper")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw BackgroundGuardianError.helperMissing
        }

        let launchAgentsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: launchAgentsURL,
            withIntermediateDirectories: true
        )
        let plistURL = launchAgentsURL.appendingPathComponent("\(label).plist")
        let properties: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helperURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "ThrottleInterval": 5
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: properties,
            format: .xml,
            options: 0
        )
        let existingData = try? Data(contentsOf: plistURL)
        let serviceTarget = "gui/\(getuid())/\(label)"
        let domainTarget = "gui/\(getuid())"
        let isLoaded = runLaunchctl(["print", serviceTarget]) == 0

        if !forceReload, existingData == data, isLoaded { return }

        if isLoaded {
            _ = runLaunchctl(["bootout", serviceTarget])
        }
        try data.write(to: plistURL, options: .atomic)
        let status = runLaunchctl(["bootstrap", domainTarget, plistURL.path])
        guard status == 0 else { throw BackgroundGuardianError.launchctlFailed(status) }
    }

    static func uninstall() {
        let launchAgentsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = launchAgentsURL.appendingPathComponent("\(label).plist")
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
