import AVFoundation
import AppKit
import CoreGraphics
import EventKit
import Foundation
import Speech
import UserNotifications

enum Permissions {
    static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speechRecognition: SFSpeechRecognizer.authorizationStatus() == .authorized,
            calendar: calendarAccessGranted
        )
    }

    static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static func requestSpeechRecognition() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static var speechRecognitionStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static var calendarAccessGranted: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }

    static func requestCalendar() async -> Bool {
        if calendarAccessGranted { return true }
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToEvents()) == true
        }
        return await withCheckedContinuation { continuation in
            store.requestAccess(to: .event) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    static func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func openPrivacySettings(_ pane: PrivacyPane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane.rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }

    enum PrivacyPane: String {
        case screenCapture = "ScreenCapture"
        case microphone = "Microphone"
        case speechRecognition = "SpeechRecognition"
        case calendar = "Calendars"
    }
}
