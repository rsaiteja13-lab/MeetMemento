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
        // reliable meeting signal. The older CptHost helper was meeting-only.
        let hasLegacyMeetingHelper = applications.contains { app in
            let bundleID = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            return name == "cpthost"
                || bundleID.contains("zoom") && bundleID.contains("cpthost")
        }

        if hasLegacyMeetingHelper { return .inMeeting }
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
            let isMeetingTitle = title.contains("zoom meeting")
                || title.hasPrefix("meeting")
                || title.contains("in-meeting")
                || title.contains("participants")
                || title.contains("waiting room")
                || title.contains("screen share")
            if owner.contains("zoom") && isMeetingTitle { return .inMeeting }
        }

        return .open
    }
}
