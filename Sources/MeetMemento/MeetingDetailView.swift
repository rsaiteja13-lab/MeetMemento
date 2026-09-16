import AVKit
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let meeting: MeetingRecord
    @ViewState private var isRenaming = false
    @ViewState private var proposedTitle = ""
    @ViewState private var showDeleteConfirmation = false

    private var durationText: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = meeting.duration >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: meeting.duration) ?? "0m"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MeetingHeroHeader(meeting: meeting, durationText: durationText)

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
                        Label("Export All Files", systemImage: "square.and.arrow.up")
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
                            "No audio was saved for this meeting. Check microphone access in MeetMemento Settings before your next call.",
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
                            Label("Meeting video", systemImage: "play.rectangle.fill")
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
                } else if meeting.errorMessage?.localizedCaseInsensitiveContains("video") == true {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Meeting video", systemImage: "play.rectangle.fill")
                            .font(.headline)
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            Text("The meeting video wasn’t saved correctly. Any available audio and transcript are still available.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
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
                            Text("Allow Speech Recognition to create a transcript from the saved audio.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Button(model.permissions.speechRecognition ? "Try Transcript Again" : "Allow Speech Recognition") {
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
            Text("“\(meeting.title)” and its audio, video, and transcript will be moved together. You can recover it from macOS Trash.")
        }
    }
}

private struct MeetingHeroHeader: View {
    let meeting: MeetingRecord
    let durationText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.white.opacity(0.16))
                    Image(systemName: meeting.videoFile == nil ? "waveform" : "video.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 62, height: 62)

                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(meeting.startedAt, format: .dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                }
                Spacer(minLength: 12)
                Text(durationText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.15), in: Capsule())
            }

            HStack(spacing: 8) {
                MeetingMediaBadge(
                    label: "Video",
                    icon: "video.fill",
                    isAvailable: meeting.videoFile != nil
                )
                MeetingMediaBadge(
                    label: "Audio",
                    icon: "waveform",
                    isAvailable: meeting.combinedAudioFile != nil
                        || meeting.systemAudioFile != nil
                        || meeting.microphoneFile != nil
                )
                MeetingMediaBadge(
                    label: "Transcript",
                    icon: "text.quote",
                    isAvailable: !(meeting.transcript?.isEmpty ?? true)
                )
            }
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [Color.indigo, Color.purple.opacity(0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .shadow(color: .indigo.opacity(0.18), radius: 14, y: 7)
    }
}

private struct MeetingMediaBadge: View {
    let label: String
    let icon: String
    let isAvailable: Bool

    var body: some View {
        Label(label, systemImage: isAvailable ? icon : "minus.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(isAvailable ? 0.95 : 0.58))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(isAvailable ? 0.14 : 0.08), in: Capsule())
    }
}

private struct RenameRecordingSheet: View {
    @Binding var title: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Rename meeting")
                    .font(.title2.bold())
                Text("Choose a name that will make this meeting easy to find later.")
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
    @ViewState private var player: AVPlayer
    @ViewState private var isPlaying = false
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
    @ViewState private var player: AVPlayer
    @ViewState private var state: VideoState = .checking
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
                    Text("Preparing meeting video…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.88))
            case .playable:
                ScrollFriendlyVideoPlayer(player: player)
                    .background(Color.black)
            case .failed:
                VStack(spacing: 12) {
                    Image(systemName: "film.stack.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.orange)
                    Text("Meeting video unavailable")
                        .font(.headline)
                    Text("This video wasn’t saved correctly. The meeting audio and transcript may still be available.")
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

/// AVPlayerView normally turns a wheel or trackpad gesture over the video into
/// timeline seeking. In a meeting-detail page that makes ordinary scrolling feel
/// broken. Preserve all player controls, but route wheel gestures to the outer
/// SwiftUI ScrollView instead.
private struct ScrollFriendlyVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = ScrollForwardingAVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private final class ScrollForwardingAVPlayerView: AVPlayerView {
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
                return event
            }
            self.scrollMeetingPage(with: event)
            // Consume the event before AVPlayerView can turn it into seeking.
            return nil
        }
    }

    deinit {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scrollMeetingPage(with: event)
    }

    private func scrollMeetingPage(with event: NSEvent) {
        var ancestor = superview
        while let view = ancestor, !(view is NSScrollView) {
            ancestor = view.superview
        }
        guard let scrollView = ancestor as? NSScrollView,
              let documentView = scrollView.documentView else { return }

        let clipView = scrollView.contentView
        let currentOrigin = clipView.bounds.origin
        let minY = documentView.bounds.minY
        let maxY = max(minY, documentView.bounds.maxY - clipView.bounds.height)
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let nextY = min(max(currentOrigin.y - event.scrollingDeltaY * multiplier, minY), maxY)
        clipView.scroll(to: NSPoint(x: currentOrigin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
    }
}
