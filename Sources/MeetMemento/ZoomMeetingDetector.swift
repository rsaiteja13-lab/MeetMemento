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

        // Modern Zoom keeps `caphost` alive outside meetings, so it is not a
        // reliable meeting signal. Meeting-only helpers remain high-confidence.
        let hasMeetingHelper = applications.contains { app in
            let bundleID = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            return ZoomSignalClassifier.isMeetingHelper(
                bundleIdentifier: bundleID,
                localizedName: name
            )
        }

        if hasMeetingHelper { return .inMeeting }
        guard !zoomApps.isEmpty else { return .notRunning }

        let zoomPIDs = Set(zoomApps.map(\.processIdentifier))
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            .zero
        ) as? [[String: Any]] else {
            return .open
        }

        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  zoomPIDs.contains(ownerPID),
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }

            let title = (window[kCGWindowName as String] as? String ?? "").lowercased()
            let owner = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let isMeetingTitle = ZoomSignalClassifier.isMeetingWindowTitle(title)
            if owner.contains("zoom") && isMeetingTitle { return .inMeeting }
        }

        return .open
    }
}
