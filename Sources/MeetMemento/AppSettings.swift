import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let autoRecord = "autoRecord"
        static let includeMicrophone = "includeMicrophone"
        static let consentAcknowledged = "recordingConsentAcknowledgedV1"
        static let onboardingCompleted = "onboardingCompletedV2"
        static let launchAtLogin = "launchAtLogin"
        static let screenPermissionConfigured = "screenPermissionConfiguredV1"
        static let screenPermissionPromptAttempted = "screenPermissionPromptAttemptedV1"
    }

    @Published var autoRecord: Bool {
        didSet { defaults.set(autoRecord, forKey: Key.autoRecord) }
    }

    @Published var includeMicrophone: Bool {
        didSet { defaults.set(includeMicrophone, forKey: Key.includeMicrophone) }
    }

    @Published var consentAcknowledged: Bool {
        didSet { defaults.set(consentAcknowledged, forKey: Key.consentAcknowledged) }
    }

    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            guard consentAcknowledged else { return }
            updateLoginItem()
        }
    }

    @Published var screenPermissionConfigured: Bool {
        didSet { defaults.set(screenPermissionConfigured, forKey: Key.screenPermissionConfigured) }
    }

    @Published var screenPermissionPromptAttempted: Bool {
        didSet { defaults.set(screenPermissionPromptAttempted, forKey: Key.screenPermissionPromptAttempted) }
    }

    @Published private(set) var loginItemError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let existingUser = defaults.bool(forKey: Key.consentAcknowledged)
        defaults.register(defaults: [
            Key.autoRecord: true,
            Key.includeMicrophone: true,
            Key.launchAtLogin: true,
            // Existing installations already completed the consent screen. New
            // installations enter the coordinated first-run permission flow.
            Key.onboardingCompleted: existingUser,
            Key.screenPermissionConfigured: existingUser,
            Key.screenPermissionPromptAttempted: existingUser
        ])
        autoRecord = defaults.bool(forKey: Key.autoRecord)
        includeMicrophone = defaults.bool(forKey: Key.includeMicrophone)
        consentAcknowledged = defaults.bool(forKey: Key.consentAcknowledged)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        screenPermissionConfigured = defaults.bool(forKey: Key.screenPermissionConfigured)
        screenPermissionPromptAttempted = defaults.bool(forKey: Key.screenPermissionPromptAttempted)
    }

    func applyLoginItemPreference() {
        if launchAtLogin { updateLoginItem() }
    }

    private func updateLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "MeetMemento couldn’t update Launch at Login: \(error.localizedDescription)"
        }
    }
}
