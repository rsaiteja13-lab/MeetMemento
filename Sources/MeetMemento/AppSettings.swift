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
        static let screenPermissionRelaunchVersion = "screenPermissionRelaunchVersionV1"
        static let loginItemRegistrationPath = "loginItemRegistrationPathV1"
        static let guardianRegistrationVersion = "guardianRegistrationVersionV1"
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

    var screenPermissionRelaunchAttemptedForCurrentBuild: Bool {
        defaults.string(forKey: Key.screenPermissionRelaunchVersion) == currentBuildVersion
    }

    func markScreenPermissionRelaunchAttempted() {
        defaults.set(currentBuildVersion, forKey: Key.screenPermissionRelaunchVersion)
    }

    private var currentBuildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private func updateLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin {
                let currentPath = Bundle.main.bundleURL.standardizedFileURL.path
                let registeredPath = defaults.string(forKey: Key.loginItemRegistrationPath)
                let currentVersion = currentBuildVersion
                let registeredGuardianVersion = defaults.string(
                    forKey: Key.guardianRegistrationVersion
                )
                let registrationChanged = registeredPath != currentPath
                    || registeredGuardianVersion != currentVersion
                if SMAppService.mainApp.status == .enabled,
                   registrationChanged {
                    try SMAppService.mainApp.unregister()
                }
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                }
                try BackgroundGuardianManager.install(
                    for: Bundle.main.bundleURL,
                    forceReload: registrationChanged
                )
                defaults.set(currentPath, forKey: Key.loginItemRegistrationPath)
                defaults.set(currentVersion, forKey: Key.guardianRegistrationVersion)
                if SMAppService.mainApp.status == .requiresApproval {
                    loginItemError = "Allow MeetMemento under General → Login Items so automatic recording can stay available."
                    AppDiagnostics.shared.record("Background launch is waiting for approval in Login Items")
                    return
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                BackgroundGuardianManager.uninstall()
                defaults.removeObject(forKey: Key.loginItemRegistrationPath)
                defaults.removeObject(forKey: Key.guardianRegistrationVersion)
            }
            loginItemError = nil
            AppDiagnostics.shared.record(
                "Persistent background launch \(launchAtLogin ? "enabled" : "disabled") for \(Bundle.main.bundleURL.path)"
            )
        } catch {
            loginItemError = "MeetMemento couldn’t update Launch at Login: \(error.localizedDescription)"
            AppDiagnostics.shared.record("Launch-at-login update failed: \(error.localizedDescription)")
        }
    }
}
