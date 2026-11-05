import Foundation

enum MeetingProvider: String, CaseIterable, Equatable {
    case zoom
    case googleMeet
    case microsoftTeams
    case webex
    case slack
    case discord
    case skype
    case whatsApp
    case faceTime
    case ringCentral
    case goTo
    case jitsi
    case whereby
    case other

    var displayName: String {
        switch self {
        case .zoom: return "Zoom"
        case .googleMeet: return "Google Meet"
        case .microsoftTeams: return "Microsoft Teams"
        case .webex: return "Webex"
        case .slack: return "Slack Huddle"
        case .discord: return "Discord"
        case .skype: return "Skype"
        case .whatsApp: return "WhatsApp"
        case .faceTime: return "FaceTime"
        case .ringCentral: return "RingCentral"
        case .goTo: return "GoTo Meeting"
        case .jitsi: return "Jitsi Meet"
        case .whereby: return "Whereby"
        case .other: return "Meeting"
        }
    }
}

struct MeetingWindowMatch: Equatable {
    let provider: MeetingProvider
    let score: Int
}

struct MeetingCaptureTarget: Equatable {
    let provider: MeetingProvider
    let displayName: String
    let processIdentifiers: [Int32]
    let windowIdentifiers: [UInt32]
    let capturesWindowsOnly: Bool
    let detectedWindowTitle: String?

    var defaultMeetingTitle: String { "\(displayName) meeting" }
}

struct MeetingDetection: Equatable {
    let state: MeetingState
    let target: MeetingCaptureTarget?
    let openApplicationName: String?
}

enum MeetingSignalClassifier {
    private static let browserTokens = [
        "com.google.chrome", "com.microsoft.edgemac", "org.mozilla.firefox",
        "com.apple.safari", "com.brave.browser", "com.operasoftware.opera",
        "com.vivaldi.vivaldi", "chrome", "edge", "firefox", "safari", "brave",
        "opera", "vivaldi", "arc"
    ]

    private static let endedTokens = [
        "meeting has ended", "webinar has ended", "you have left", "post-meeting",
        "meeting feedback", "call ended", "rate your call", "how was the call",
        "meeting recap", "meeting notes"
    ]

    static func isBrowser(bundleIdentifier: String, localizedName: String) -> Bool {
        let identity = "\(bundleIdentifier) \(localizedName)".lowercased()
        return browserTokens.contains { identity.contains($0) }
    }

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

    static func isVisibleMeetingHelperWindow(isOnScreen: Bool, alpha: Double) -> Bool {
        isOnScreen && alpha > 0.01
    }

    static func applicationProvider(
        bundleIdentifier: String,
        localizedName: String
    ) -> MeetingProvider? {
        let identity = "\(bundleIdentifier) \(localizedName)".lowercased()
        if isBrowser(bundleIdentifier: bundleIdentifier, localizedName: localizedName) { return nil }
        if identity.contains("zoom") || identity.contains("cpthost") { return .zoom }
        if identity.contains("microsoft.teams") || identity.contains("msteams") || identity.contains("microsoft teams") { return .microsoftTeams }
        if identity.contains("webex") || identity.contains("cisco.webex") { return .webex }
        if identity.contains("slack") { return .slack }
        if identity.contains("discord") { return .discord }
        if identity.contains("skype") { return .skype }
        if identity.contains("whatsapp") { return .whatsApp }
        if identity.contains("facetime") { return .faceTime }
        if identity.contains("ringcentral") { return .ringCentral }
        if identity.contains("gotomeeting") || identity.contains("goto meeting") { return .goTo }
        if identity.contains("jitsi") { return .jitsi }
        if identity.contains("whereby") { return .whereby }
        return nil
    }

    static func windowMatch(
        bundleIdentifier: String,
        localizedName: String,
        title rawTitle: String,
        ownedByMeetingHelper: Bool = false
    ) -> MeetingWindowMatch? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty,
              !endedTokens.contains(where: title.contains) else { return nil }

        if ownedByMeetingHelper {
            return MeetingWindowMatch(provider: .zoom, score: 150)
        }
        if title.contains("zoom meeting") { return .init(provider: .zoom, score: 145) }
        if title.contains("zoom webinar") { return .init(provider: .zoom, score: 142) }
        if title.contains("waiting room")
            && applicationProvider(bundleIdentifier: bundleIdentifier, localizedName: localizedName) == .zoom {
            return .init(provider: .zoom, score: 138)
        }
        if (title.contains("google meet") || title.contains("meet.google.com") || title.hasPrefix("meet -"))
            && !title.contains("help") {
            return .init(provider: .googleMeet, score: 140)
        }
        if title.contains("teams meeting")
            || title.contains("meeting | microsoft teams")
            || title.contains("meeting - microsoft teams")
            || title.contains("live event | microsoft teams") {
            return .init(provider: .microsoftTeams, score: 140)
        }
        if title.contains("webex") && containsCallSignal(title) {
            return .init(provider: .webex, score: 135)
        }
        if title.contains("huddle")
            && (title.contains("slack")
                || applicationProvider(bundleIdentifier: bundleIdentifier, localizedName: localizedName) == .slack) {
            return .init(provider: .slack, score: 134)
        }
        if title.contains("jitsi meet") || title.contains("meet.jit.si") {
            return .init(provider: .jitsi, score: 132)
        }
        if title.contains("whereby") && containsCallSignal(title) {
            return .init(provider: .whereby, score: 130)
        }
        if title.contains("ringcentral") && containsCallSignal(title) {
            return .init(provider: .ringCentral, score: 130)
        }
        if (title.contains("goto meeting") || title.contains("gotomeeting")) && containsCallSignal(title) {
            return .init(provider: .goTo, score: 130)
        }
        if ["video call", "voice call", "conference call", "in a call", "meeting room", "live webinar"]
            .contains(where: title.contains) {
            return .init(provider: .other, score: 102)
        }

        guard let provider = applicationProvider(
            bundleIdentifier: bundleIdentifier,
            localizedName: localizedName
        ) else { return nil }

        switch provider {
        case .zoom:
            if title.hasPrefix("meeting") || title.contains("in-meeting") || title.contains("screen share") {
                return .init(provider: .zoom, score: 120)
            }
        case .microsoftTeams:
            if containsCallSignal(title) && title != "microsoft teams" {
                return .init(provider: .microsoftTeams, score: 118)
            }
        case .webex:
            if containsCallSignal(title) && title != "webex" {
                return .init(provider: .webex, score: 118)
            }
        case .slack:
            if title.contains("huddle") || title.contains("call") {
                return .init(provider: .slack, score: 116)
            }
        case .discord, .skype, .whatsApp, .ringCentral, .goTo, .jitsi, .whereby:
            if containsCallSignal(title) {
                return .init(provider: provider, score: 112)
            }
        case .faceTime:
            if title != "facetime" && (containsCallSignal(title) || title.split(separator: " ").count <= 6) {
                return .init(provider: .faceTime, score: 108)
            }
        case .googleMeet, .other:
            break
        }
        return nil
    }

    static func isMeetingWindowTitle(_ value: String) -> Bool {
        let title = value.lowercased()
        return title.contains("zoom meeting")
            || title.contains("zoom webinar")
            || title.contains("google meet")
            || title.contains("teams meeting")
            || title.contains("webex meeting")
            || title.contains("slack huddle")
            || title.contains("jitsi meet")
            || title.contains("whereby")
            || title.hasPrefix("meeting")
            || title.contains("in-meeting")
            || title.contains("waiting room")
            || title.contains("screen share")
            || title.contains("webinar")
    }

    static func isMeetingWindow(
        ownedByMeetingHelper: Bool,
        title: String,
        layer: Int,
        width: Double,
        height: Double
    ) -> Bool {
        guard layer == 0, width >= 160, height >= 90 else { return false }
        return ownedByMeetingHelper || isMeetingWindowTitle(title)
    }

    private static func containsCallSignal(_ value: String) -> Bool {
        ["meeting", "webinar", "call", "huddle", "live event", "screen share", "presenting", "waiting room"]
            .contains(where: value.contains)
    }
}

// Compatibility wrapper retained for existing lightweight checks.
enum ZoomSignalClassifier {
    static func isMeetingHelper(bundleIdentifier: String, localizedName: String) -> Bool {
        MeetingSignalClassifier.isMeetingHelper(
            bundleIdentifier: bundleIdentifier,
            localizedName: localizedName
        )
    }

    static func isMeetingWindowTitle(_ value: String) -> Bool {
        MeetingSignalClassifier.isMeetingWindowTitle(value)
    }

    static func isMeetingWindow(
        ownedByMeetingHelper: Bool,
        title: String,
        layer: Int,
        width: Double,
        height: Double
    ) -> Bool {
        MeetingSignalClassifier.isMeetingWindow(
            ownedByMeetingHelper: ownedByMeetingHelper,
            title: title,
            layer: layer,
            width: width,
            height: height
        )
    }
}
