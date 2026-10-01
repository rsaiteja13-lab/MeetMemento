import AppKit
import CoreGraphics
import Foundation

struct ZoomMeetingDetector {
    func currentState() -> ZoomMeetingState {
        let applications = NSWorkspace.shared.runningApplications
        let zoomApps = applications.filter { app in
            let bundleID = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            return bundleID == "us.zoom.xos" || name == "zoom" || name == "zoom workplace" || name == "zoom.us"
        }

        // Modern Zoom can leave helper processes alive after a meeting. Treat
        // them as meeting signals only while they own a real window or during
        // the short startup period before that window becomes discoverable.
        let meetingHelpers = applications.filter { app in
            let bundleID = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            return ZoomSignalClassifier.isMeetingHelper(
                bundleIdentifier: bundleID,
                localizedName: name
            )
        }

        guard !zoomApps.isEmpty || !meetingHelpers.isEmpty else { return .notRunning }

        let meetingHelperPIDs = Set(meetingHelpers.map(\.processIdentifier))
        let zoomPIDs = Set((zoomApps + meetingHelpers).map(\.processIdentifier))
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            .zero
        ) as? [[String: Any]] else {
            return meetingHelperWasJustLaunched(meetingHelpers) ? .inMeeting : .open
        }

        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  zoomPIDs.contains(ownerPID),
                  let layer = window[kCGWindowLayer as String] as? Int else { continue }

            let title = (window[kCGWindowName as String] as? String ?? "").lowercased()
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            if ZoomSignalClassifier.isMeetingWindow(
                ownedByMeetingHelper: meetingHelperPIDs.contains(ownerPID),
                title: title,
                layer: layer,
                width: width,
                height: height
            ) {
                return .inMeeting
            }
        }

        return meetingHelperWasJustLaunched(meetingHelpers) ? .inMeeting : .open
    }

    private func meetingHelperWasJustLaunched(_ helpers: [NSRunningApplication]) -> Bool {
        helpers.contains { helper in
            guard let launchedAt = helper.launchDate else { return false }
            let age = Date().timeIntervalSince(launchedAt)
            return age >= 0 && age < 2 * 60
        }
    }
}
