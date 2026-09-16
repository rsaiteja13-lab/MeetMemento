import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "waveform.and.mic")
                        .foregroundStyle(.white)
                        .font(.headline)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text("MeetMemento").font(.headline)
                    Text(settings.autoRecord ? "Automatic recording on" : "Manual recording")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle).font(.subheadline.weight(.semibold))
                Text(statusDetail).font(.caption).foregroundStyle(.secondary)
            }

            if model.captureState == .recording {
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Stop and Save", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            } else if !model.permissions.screenRecording {
                Button {
                    model.requestScreenRecordingAccess()
                } label: {
                    Label("Finish One-Time Setup", systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartRecording || !model.capturePermissionsReady)
            }

            Toggle("Record Zoom automatically", isOn: $settings.autoRecord)
            Divider()
            HStack {
                Button("Open MeetMemento") {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Recordings Folder") { model.openRecordingsFolder() }
            }
            Divider()
            Button("Quit MeetMemento") { NSApplication.shared.terminate(nil) }
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var statusColor: Color {
        if model.captureState == .recording { return .red }
        if !model.permissions.screenRecording { return .orange }
        return settings.autoRecord ? .green : .secondary
    }

    private var statusTitle: String {
        if model.captureState == .recording { return "Recording Zoom" }
        if !model.permissions.screenRecording { return "One-time setup needed" }
        return settings.autoRecord ? "Automatic recording is on" : "Automatic recording is off"
    }

    private var statusDetail: String {
        if model.captureState == .recording { return "Saving video, audio, and transcript." }
        if !model.permissions.screenRecording { return "Allow screen access to start recording." }
        return model.zoomState.label
    }
}
