import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Automatically record detected Zoom meetings", isOn: $settings.autoRecord)
                Toggle("Include my microphone", isOn: $settings.includeMicrophone)
                Toggle("Launch MeetMemento when I log in", isOn: $settings.launchAtLogin)
            }

            Section("Permissions") {
                PermissionRow(title: "Screen Recording", granted: model.permissions.screenRecording) {
                    Permissions.openPrivacySettings(.screenCapture)
                }
                PermissionRow(title: "Microphone", granted: model.permissions.microphone) {
                    Task { await model.requestMicrophoneAccess() }
                }
                PermissionRow(title: "Speech Recognition", granted: model.permissions.speechRecognition) {
                    Task { await model.requestSpeechAccess() }
                }
                PermissionRow(title: "Calendar (optional)", granted: model.permissions.calendar) {
                    Task { await model.requestCalendarAccess() }
                }
                Button("Refresh Permission Status") { model.refreshPermissions() }
            }

            Section("Privacy") {
                Text("Recordings remain on this Mac. If on-device recognition is unavailable for your language, macOS may use Apple’s speech service to transcribe audio.")
                    .foregroundStyle(.secondary)
                Text("Calendar naming uses events available in the macOS Calendar app, including Outlook calendars connected there. Without Calendar access, titles are generated from the discussion transcript.")
                    .foregroundStyle(.secondary)
                Button("Open Recordings Folder") { model.openRecordingsFolder() }
            }

            if let error = settings.loginItemError {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 500)
        .padding()
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Spacer()
            if !granted { Button("Open Settings", action: action) }
        }
    }
}
