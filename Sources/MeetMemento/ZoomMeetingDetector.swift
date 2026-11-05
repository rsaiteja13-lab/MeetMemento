import AppKit
import CoreGraphics
import Foundation

struct MeetingDetector {
    private struct Candidate {
        let match: MeetingWindowMatch
        let ownerPID: pid_t
        let windowID: CGWindowID
        let title: String
        let bundleIdentifier: String
        let localizedName: String
    }

    func currentDetection() -> MeetingDetection {
        let applications = NSWorkspace.shared.runningApplications
        // NSWorkspace can briefly return the same process more than once while
        // an application is launching, terminating, or replacing a helper.
        // Dictionary(uniqueKeysWithValues:) traps on that perfectly valid
        // transient state and used to crash MeetMemento during a meeting.
        let applicationsByPID = applications.reduce(into: [pid_t: NSRunningApplication]()) {
            $0[$1.processIdentifier] = $1
        }
        let dedicatedMeetingApps = applications.compactMap { app -> (NSRunningApplication, MeetingProvider)? in
            let bundleID = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            guard let provider = MeetingSignalClassifier.applicationProvider(
                bundleIdentifier: bundleID,
                localizedName: name
            ) else { return nil }
            return (app, provider)
        }

        let meetingHelpers = applications.filter { app in
            let bundleID = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            return MeetingSignalClassifier.isMeetingHelper(
                bundleIdentifier: bundleID,
                localizedName: name
            )
        }
        let meetingHelperPIDs = Set(meetingHelpers.map(\.processIdentifier))
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            .zero
        ) as? [[String: Any]] else {
            return MeetingDetection(
                state: dedicatedMeetingApps.isEmpty ? .notRunning : .open,
                target: nil,
                openApplicationName: dedicatedMeetingApps.first?.1.displayName
            )
        }

        var candidates: [Candidate] = []
        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  let owner = applicationsByPID[ownerPID],
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }

            let title = window[kCGWindowName as String] as? String ?? ""
            let ownedByMeetingHelper = meetingHelperPIDs.contains(ownerPID)
            let isOnScreen = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if ownedByMeetingHelper,
               !MeetingSignalClassifier.isVisibleMeetingHelperWindow(
                    isOnScreen: isOnScreen,
                    alpha: alpha
               ) { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            guard width >= 160, height >= 90,
                  let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            let bundleID = owner.bundleIdentifier ?? ""
            let name = owner.localizedName ?? ""
            guard let match = MeetingSignalClassifier.windowMatch(
                bundleIdentifier: bundleID,
                localizedName: name,
                title: title,
                ownedByMeetingHelper: ownedByMeetingHelper
            ) else { continue }
            candidates.append(Candidate(
                match: match,
                ownerPID: ownerPID,
                windowID: windowID,
                title: title,
                bundleIdentifier: bundleID,
                localizedName: name
            ))
        }

        if let candidate = candidates.max(by: { $0.match.score < $1.match.score }) {
            let browserMeeting = MeetingSignalClassifier.isBrowser(
                bundleIdentifier: candidate.bundleIdentifier,
                localizedName: candidate.localizedName
            )
            let captureOnlyDetectedWindow = browserMeeting || candidate.match.provider == .other
            let matchingNativePIDs = dedicatedMeetingApps.compactMap { app, provider in
                provider == candidate.match.provider ? Int32(app.processIdentifier) : nil
            }
            let processIdentifiers = browserMeeting
                ? [Int32(candidate.ownerPID)]
                : Array(Set(matchingNativePIDs + [Int32(candidate.ownerPID)]
                    + (candidate.match.provider == .zoom
                        ? meetingHelpers.map { Int32($0.processIdentifier) }
                        : [])))
            return MeetingDetection(
                state: .inMeeting,
                target: MeetingCaptureTarget(
                    provider: candidate.match.provider,
                    displayName: candidate.match.provider == .other
                        ? candidate.localizedName
                        : candidate.match.provider.displayName,
                    processIdentifiers: processIdentifiers,
                    windowIdentifiers: [UInt32(candidate.windowID)],
                    capturesWindowsOnly: captureOnlyDetectedWindow,
                    detectedWindowTitle: candidate.title
                ),
                openApplicationName: candidate.match.provider == .other
                    ? candidate.localizedName
                    : candidate.match.provider.displayName
            )
        }

        return MeetingDetection(
            state: dedicatedMeetingApps.isEmpty ? .notRunning : .open,
            target: nil,
            openApplicationName: dedicatedMeetingApps.first?.1.displayName
        )
    }

    func frontmostCaptureTarget() -> MeetingCaptureTarget? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            .zero
        ) as? [[String: Any]] else { return nil }
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let applicationsByPID = NSWorkspace.shared.runningApplications.reduce(
            into: [pid_t: NSRunningApplication]()
        ) {
            $0[$1.processIdentifier] = $1
        }
        guard let window = windows.first(where: { window in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ownProcessID,
                  let application = applicationsByPID[ownerPID],
                  application.activationPolicy == .regular,
                  (window[kCGWindowLayer as String] as? Int) == 0 else { return false }
            return Self.area(of: window) >= 160.0 * 90.0
        }),
              let processID = window[kCGWindowOwnerPID as String] as? pid_t,
              let application = applicationsByPID[processID],
              Self.area(of: window) >= 160.0 * 90.0,
              let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }

        let bundleID = application.bundleIdentifier ?? ""
        let localizedName = application.localizedName ?? "Meeting app"
        let title = window[kCGWindowName as String] as? String
        let provider = MeetingSignalClassifier.windowMatch(
            bundleIdentifier: bundleID,
            localizedName: localizedName,
            title: title ?? ""
        )?.provider ?? MeetingSignalClassifier.applicationProvider(
            bundleIdentifier: bundleID,
            localizedName: localizedName
        ) ?? .other
        return MeetingCaptureTarget(
            provider: provider,
            displayName: provider == .other ? localizedName : provider.displayName,
            processIdentifiers: [Int32(processID)],
            windowIdentifiers: [UInt32(windowID)],
            capturesWindowsOnly: true,
            detectedWindowTitle: title
        )
    }

    private static func area(of window: [String: Any]) -> Double {
        let bounds = window[kCGWindowBounds as String] as? [String: Any]
        let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
        let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
        return width * height
    }
}

typealias ZoomMeetingDetector = MeetingDetector
