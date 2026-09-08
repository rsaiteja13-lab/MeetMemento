import AVKit
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let meeting: MeetingRecord
    @State private var isRenaming = false
    @State private var proposedTitle = ""
    @State private var showDeleteConfirmation = false

    private var durationText: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = meeting.duration >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: meeting.duration) ?? "0m"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(meeting.title)
                        .font(.largeTitle.bold())
                    Text(meeting.startedAt, format: .dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
                        .foregroundStyle(.secondary)
                    Text(durationText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        proposedTitle = meeting.title
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        model.exportAll(for: meeting)
                    } label: {
                        Label("Export Complete Meeting", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        model.showInFinder(meeting)
                    } label: {
                        Label("Show Files", systemImage: "folder")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(model.captureState != .idle)
                }

                if let message = model.statusMessage {
                    Label(message, systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Full meeting audio", systemImage: "waveform")
                            .font(.headline)
                        Spacer()
                        if model.library.fileURL(for: meeting, kind: .audio) != nil {
                            Button("Download Audio") { model.download(.audio, for: meeting) }
                        }
                    }
                    if let audioURL = model.library.fileURL(for: meeting, kind: .audio) {
                        MeetingAudioPlayer(url: audioURL)
                            .id(audioURL)
                    } else {
                        Label(
                            "Audio was not captured for this recording. Allow Microphone access before the next meeting to include your voice.",
                            systemImage: "mic.slash"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

                if let videoFile = meeting.videoFile {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Zoom screen recording", systemImage: "play.rectangle.fill")
                                .font(.headline)
                            Spacer()
                            Button("Download Video") { model.download(.video, for: meeting) }
                        }
                        MeetingVideoPlayer(
                            url: model.library.folder(for: meeting).appendingPathComponent(videoFile)
                        )
                        .frame(minHeight: 240, idealHeight: 340, maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                } else if meeting.errorMessage?.contains("Zoom video") == true {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Zoom screen recording", systemImage: "play.rectangle.fill")
                            .font(.headline)
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            Text("The video did not finish correctly. Your full audio, transcript, and summary remain available.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Summary", systemImage: "list.bullet.rectangle")
                            .font(.headline)
                        Spacer()
                        if let summary = meeting.summary, !summary.isEmpty {
                            Button("Copy") { model.copyText(summary, label: "Summary") }
                        }
                        if model.library.fileURL(for: meeting, kind: .summary) != nil {
                            Button("Download Summary") { model.download(.summary, for: meeting) }
                        }
                    }
                    if let summary = meeting.summary, !summary.isEmpty {
                        Text(summary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineSpacing(5)
                    } else {
                        Text("A summary will be created automatically when the transcript is ready.")
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    Label("Transcript", systemImage: "text.quote")
                        .font(.headline)
                    Spacer()
                    if let transcript = meeting.transcript, !transcript.isEmpty {
                        Button("Copy") { model.copyText(transcript, label: "Transcript") }
                    }
                    if model.library.fileURL(for: meeting, kind: .transcript) != nil {
                        Button("Download Transcript") { model.download(.transcript, for: meeting) }
                    }
                }

                if let transcript = meeting.transcript, !transcript.isEmpty {
                    Text(transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.body)
                        .lineSpacing(5)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text(meeting.transcriptionStatus.label)
                            .font(.title2.bold())
                        if let error = meeting.errorMessage {
                            Text(error)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("Allow Speech Recognition to create a transcript and summary from the saved audio.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Button(model.permissions.speechRecognition ? "Try Transcription Again" : "Allow Speech Recognition") {
                            Task { await model.requestSpeechAndRetry(for: meeting) }
                        }
                        .disabled(model.captureState != .idle)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                if let warning = meeting.errorMessage, meeting.transcript != nil {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(28)
        }
        .navigationTitle(meeting.title)
        .onAppear { model.ensureSummary(for: meeting) }
        .sheet(isPresented: $isRenaming) {
            RenameRecordingSheet(
                title: $proposedTitle,
                onCancel: { isRenaming = false },
                onSave: {
                    model.rename(meeting, to: proposedTitle)
                    isRenaming = false
                }
            )
        }
        .confirmationDialog(
            "Move recording to Trash?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                model.moveToTrash(meeting)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(meeting.title)” and its audio, video, transcript, and summary will be moved together. You can recover it from macOS Trash.")
        }
    }
}

private struct RenameRecordingSheet: View {
    @Binding var title: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Rename recording")
                    .font(.title2.bold())
                Text("Use a name that will make this meeting easy to find later.")
                    .foregroundStyle(.secondary)
            }
            TextField("Meeting name", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSave)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct MeetingAudioPlayer: View {
    @State private var player: AVPlayer
    @State private var isPlaying = false
    let url: URL

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if isPlaying {
                    player.pause()
                } else {
                    if let duration = player.currentItem?.duration,
                       duration.isNumeric,
                       player.currentTime() >= duration {
                        player.seek(to: .zero)
                    }
                    player.play()
                }
                isPlaying.toggle()
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button {
                player.pause()
                player.seek(to: .zero)
                isPlaying = false
            } label: {
                Label("Restart", systemImage: "backward.end.fill")
            }

            Spacer()
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onDisappear { player.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard notification.object as AnyObject? === player.currentItem else { return }
            isPlaying = false
        }
    }
}

private struct MeetingVideoPlayer: View {
    @State private var player: AVPlayer
    @State private var state: VideoState = .checking
    let url: URL

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        Group {
            switch state {
            case .checking:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing video preview…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.88))
            case .playable:
                VideoPlayer(player: player)
                    .background(Color.black)
            case .failed:
                VStack(spacing: 12) {
                    Image(systemName: "film.stack.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.orange)
                    Text("Video preview unavailable")
                        .font(.headline)
                    Text("This video did not finish saving. The meeting audio, transcript, and summary may still be available above and below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
            }
        }
        .task(id: url) {
            let asset = AVURLAsset(url: url)
            do {
                let isPlayable = try await asset.load(.isPlayable)
                state = isPlayable ? .playable : .failed
            } catch {
                state = .failed
            }
        }
        .onDisappear { player.pause() }
    }

    private enum VideoState {
        case checking
        case playable
        case failed
    }
}
