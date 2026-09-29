import Foundation

enum ZoomSignalClassifier {
    static func isMeetingHelper(bundleIdentifier: String, localizedName: String) -> Bool {
        let bundleID = bundleIdentifier.lowercased()
        let name = localizedName.lowercased()
        let normalizedName = name.replacingOccurrences(of: " ", with: "")

        return normalizedName == "cpthost"
            || normalizedName == "zccimeetinghost"
            || bundleID.contains("zoom") && (
                bundleID.contains("cpthost")
                    || bundleID.contains("zccimeetinghost")
            )
    }

    static func isMeetingWindowTitle(_ value: String) -> Bool {
        let title = value.lowercased()
        return title.contains("zoom meeting")
            || title.contains("zoom webinar")
            || title.hasPrefix("meeting")
            || title.contains("in-meeting")
            || title.contains("participants")
            || title.contains("waiting room")
            || title.contains("screen share")
            || title.contains("webinar")
    }
}
