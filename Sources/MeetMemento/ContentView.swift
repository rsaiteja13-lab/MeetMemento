import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: MeetingLibrary
    @State private var searchText = ""
    @State private var meetingPendingDeletion: MeetingRecord?

    var body: some View {
        Group {
            if settings.consentAcknowledged {
                mainView
            } else {
                OnboardingView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private var filteredMeetings: [MeetingRecord] {
        guard !searchText.isEmpty else { return library.meetings }
        return library.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || ($0.transcript?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var mainView: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SidebarBrand()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                List(selection: $model.selectedMeetingID) {
                    ForEach(calendarGroups) { month in
                        Section {
                            ForEach(month.days) { day in
                                Text(day.date, format: .dateTime.weekday(.wide).day())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                                ForEach(day.meetings) { meeting in
                                    MeetingRow(meeting: meeting) {
                                        meetingPendingDeletion = meeting
                                    }
                                        .tag(meeting.id)
                                        .contextMenu {
                                            RecordingContextMenu(meeting: meeting) {
                                                meetingPendingDeletion = meeting
                                            }
                                        }
                                }
                            }
                        } header: {
                            Text(month.date, format: .dateTime.month(.wide).year())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if filteredMeetings.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: searchText.isEmpty ? "waveform.badge.plus" : "magnifyingglass")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(searchText.isEmpty ? "No recordings yet" : "No matches")
                                .font(.subheadline.weight(.semibold))
                            Text(searchText.isEmpty ? "Your Zoom meetings will appear here." : "Try a different search.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $searchText, prompt: "Search meetings")
                .onDeleteCommand {
                    guard model.captureState == .idle,
                          let id = model.selectedMeetingID,
                          let meeting = library.meetings.first(where: { $0.id == id }) else { return }
                    meetingPendingDeletion = meeting
                }

                Button {
                    model.openTrash()
                } label: {
                    Label("Recently Deleted", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .help("Open macOS Trash to recover a deleted recording")

                Divider()
                SidebarRecorderCard()
                    .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 380)
        } detail: {
            ZStack {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                if model.captureState == .recording, model.selectedMeetingID == nil {
                    ActiveRecordingView()
                } else if let id = model.selectedMeetingID,
                   let meeting = library.meetings.first(where: { $0.id == id }) {
                    MeetingDetailView(meeting: meeting)
                } else {
                    HomeDashboardView()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ToolbarRecorderStatus()
                Button {
                    model.openRecordingsFolder()
                } label: {
                    Label("Recordings Folder", systemImage: "folder")
                }
                if model.captureState == .recording {
                    Button { Task { await model.stopRecording() } } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .help("Stop and save this recording")
                } else {
                    Button { Task { await model.startRecording() } } label: {
                        Image(systemName: "record.circle")
                            .foregroundStyle(.red)
                    }
                        .accessibilityLabel("Start a manual recording")
                        .help("Start a manual recording")
                        .disabled(!model.canStartRecording || !model.permissions.screenRecording)
                }
            }
        }
        .tint(.indigo)
        .confirmationDialog(
            "Move recording to Trash?",
            isPresented: Binding(
                get: { meetingPendingDeletion != nil },
                set: { if !$0 { meetingPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: meetingPendingDeletion
        ) { meeting in
            Button("Move to Trash", role: .destructive) {
                model.moveToTrash(meeting)
                meetingPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                meetingPendingDeletion = nil
            }
        } message: { meeting in
            Text("“\(meeting.title)” and its audio, video, transcript, and summary will be moved together. You can recover it from macOS Trash.")
        }
    }

    private var calendarGroups: [RecordingMonthGroup] {
        let calendar = Calendar.current
        let byMonth = Dictionary(grouping: filteredMeetings) { meeting in
            let components = calendar.dateComponents([.year, .month], from: meeting.startedAt)
            return calendar.date(from: components) ?? calendar.startOfDay(for: meeting.startedAt)
        }
        return byMonth.keys.sorted(by: >).map { monthDate in
            let byDay = Dictionary(grouping: byMonth[monthDate] ?? []) {
                calendar.startOfDay(for: $0.startedAt)
            }
            let days = byDay.keys.sorted(by: >).map { dayDate in
                RecordingDayGroup(
                    date: dayDate,
                    meetings: (byDay[dayDate] ?? []).sorted { $0.startedAt > $1.startedAt }
                )
            }
            return RecordingMonthGroup(date: monthDate, days: days)
        }
    }
}

private struct RecordingContextMenu: View {
    @EnvironmentObject private var model: AppModel
    let meeting: MeetingRecord
    let onDelete: () -> Void

    var body: some View {
        Group {
            Button {
                model.showInFinder(meeting)
            } label: {
                Label("Show Files", systemImage: "folder")
            }
            Button {
                model.exportAll(for: meeting)
            } label: {
                Label("Export Complete Meeting", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Move to Trash…", systemImage: "trash")
            }
            .disabled(model.captureState != .idle)
        }
    }
}

private struct RecordingMonthGroup: Identifiable {
    let date: Date
    let days: [RecordingDayGroup]
    var id: Date { date }
}

private struct RecordingDayGroup: Identifiable {
    let date: Date
    let meetings: [MeetingRecord]
    var id: Date { date }
}

private struct ActiveRecordingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(.red.opacity(0.1))
                    .frame(width: 126, height: 126)
                Circle()
                    .fill(.red.opacity(0.16))
                    .frame(width: 94, height: 94)
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(.red)
            }

            VStack(spacing: 8) {
                Text("Recording your Zoom meeting")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                if let capture = model.activeCapture {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedText(context.date.timeIntervalSince(capture.startedAt)))
                            .font(.title2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("You can close this window. MeetMemento will keep recording in the background.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                CaptureTile(icon: "video.fill", title: "Zoom video", isAvailable: true)
                CaptureTile(icon: "waveform", title: "Meeting audio", isAvailable: true)
                CaptureTile(icon: "mic.fill", title: "Your voice", isAvailable: model.permissions.microphone)
                CaptureTile(icon: "text.quote", title: "Transcript", isAvailable: model.permissions.speechRecognition)
            }
            .frame(maxWidth: 720)

            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stop and Save", systemImage: "stop.fill")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            Label("Record only with the consent required in your location.", systemImage: "person.2.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func elapsedText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

private struct CaptureTile: View {
    let icon: String
    let title: String
    let isAvailable: Bool

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: isAvailable ? icon : "\(icon).slash")
                .font(.title2)
                .foregroundStyle(isAvailable ? .indigo : .secondary)
            Text(title)
                .font(.caption.weight(.medium))
            Text(isAvailable ? "Capturing" : "Unavailable")
                .font(.caption2)
                .foregroundStyle(isAvailable ? .green : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.indigo.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: meeting.videoFile == nil ? "waveform" : "video.fill")
                    .foregroundStyle(.indigo)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(meeting.startedAt, format: .dateTime.hour().minute())
                    Text("·")
                    Text(durationText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Label(
                    meeting.transcriptionStatus.label,
                    systemImage: meeting.transcriptionStatus == .complete ? "checkmark.circle.fill" : "waveform"
                )
                .font(.caption2)
                .foregroundStyle(meeting.transcriptionStatus == .failed ? .red : .secondary)
            }
            Spacer(minLength: 4)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Move this recording to Trash")
            .disabled(meeting.transcriptionStatus == .processing)
        }
        .padding(.vertical, 5)
    }

    private var durationText: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = meeting.duration >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: meeting.duration) ?? "0s"
    }
}

private struct SidebarBrand: View {
    var body: some View {
        HStack(spacing: 10) {
            BrandMark(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("MeetMemento")
                    .font(.headline.weight(.bold))
                Text("Your private meeting memory")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(
                    LinearGradient(
                        colors: [.indigo, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "waveform.and.mic")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .indigo.opacity(0.2), radius: 5, y: 2)
    }
}

private struct SidebarRecorderCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: statusColor.opacity(0.45), radius: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.bold))
                    Text(statusDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !model.permissions.screenRecording {
                Button {
                    model.requestScreenRecordingAccess()
                } label: {
                    Label("Finish one-time setup", systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }

            Toggle("Always record Zoom meetings", isOn: $settings.autoRecord)
                .font(.caption)
        }
        .padding(12)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusColor: Color {
        if model.captureState == .recording { return .red }
        if !model.permissions.screenRecording { return .orange }
        return settings.autoRecord ? .green : .secondary
    }

    private var statusTitle: String {
        if model.captureState == .recording { return "Recording now" }
        if !model.permissions.screenRecording { return "One-time setup needed" }
        return settings.autoRecord ? "Always-on is active" : "Automatic recording is off"
    }

    private var statusDetail: String {
        if model.captureState == .recording { return "Saving Zoom video and audio" }
        if !model.permissions.screenRecording { return "Grant screen access once" }
        return model.zoomState.label
    }
}

private struct ToolbarRecorderStatus: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        if model.captureState == .recording { return .red }
        if !model.permissions.screenRecording { return .orange }
        return settings.autoRecord ? .green : .secondary
    }

    private var label: String {
        if model.captureState == .recording { return "Recording" }
        if !model.permissions.screenRecording { return "Setup needed" }
        return settings.autoRecord ? "Monitoring Zoom" : "Manual mode"
    }
}

private struct HomeDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    BrandMark(size: 66)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your meetings, remembered.")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("MeetMemento quietly captures Zoom and keeps everything organized on this Mac.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                RecorderHeroCard()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    FeatureCard(icon: "video.fill", title: "Complete recording", detail: "Zoom video and system audio")
                    FeatureCard(icon: "text.quote", title: "Searchable memory", detail: "Transcript and summary")
                    FeatureCard(icon: "calendar", title: "Easy to revisit", detail: "Grouped by month and day")
                }

                if needsSetup {
                    PermissionSetupCard()
                }

                if let message = model.statusMessage {
                    Label(message, systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: 820)
            .padding(40)
        }
    }

    private var needsSetup: Bool {
        !model.permissions.screenRecording
            || !model.permissions.microphone
            || !model.permissions.speechRecognition
            || !model.permissions.calendar
    }
}

private struct RecorderHeroCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.16))
                    .frame(width: 52, height: 52)
                Image(systemName: statusIcon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.title3.weight(.bold))
                Text(statusDetail)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.permissions.screenRecording {
                Button("Finish Setup") { model.requestScreenRecordingAccess() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            } else {
                Toggle("Always record", isOn: $settings.autoRecord)
                    .toggleStyle(.switch)
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [statusColor.opacity(0.12), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(statusColor.opacity(0.15)))
    }

    private var statusColor: Color {
        if !model.permissions.screenRecording { return .orange }
        return settings.autoRecord ? .green : .indigo
    }

    private var statusIcon: String {
        if !model.permissions.screenRecording { return "lock.trianglebadge.exclamationmark" }
        return settings.autoRecord ? "checkmark.shield.fill" : "record.circle"
    }

    private var statusTitle: String {
        if !model.permissions.screenRecording { return "Complete the one-time recording setup" }
        return settings.autoRecord ? "Always-on recording is active" : "Automatic recording is off"
    }

    private var statusDetail: String {
        if !model.permissions.screenRecording { return "MeetMemento needs macOS screen access once, then it stays quiet." }
        return model.zoomState == .inMeeting
            ? "A Zoom meeting is ready to record."
            : "MeetMemento is monitoring Zoom in the background."
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.indigo)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color(nsColor: .separatorColor).opacity(0.45)))
    }
}

private struct PermissionSetupCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Make every recording complete")
                    .font(.headline)
                Text("Screen access is required. The other options enrich audio, transcripts, summaries, and names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.permissions.screenRecording {
                PermissionActionRow(icon: "rectangle.inset.filled.and.person.filled", title: "Screen and Zoom audio", detail: "Required for automatic recording", button: "Set Up") {
                    model.requestScreenRecordingAccess()
                }
            }
            if settings.includeMicrophone && !model.permissions.microphone {
                PermissionActionRow(icon: "mic.fill", title: "Your microphone", detail: "Includes your side of the conversation", button: "Allow") {
                    Task { await model.requestMicrophoneAccess() }
                }
            }
            if !model.permissions.speechRecognition {
                PermissionActionRow(icon: "text.quote", title: "Speech Recognition", detail: "Creates transcripts and summaries", button: "Allow") {
                    Task { await model.requestSpeechAccess() }
                }
            }
            if !model.permissions.calendar {
                PermissionActionRow(icon: "calendar", title: "Calendar", detail: "Uses Outlook event names when available", button: "Connect") {
                    Task { await model.requestCalendarAccess() }
                }
            }
        }
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct PermissionActionRow: View {
    let icon: String
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action)
                .controlSize(.small)
        }
    }
}
