import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var acceptsResponsibility = false
    @State private var requesting = false

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            VStack(spacing: 9) {
                Text("Welcome to MeetMemento")
                    .font(.largeTitle.bold())
                Text("Automatically preserve your Zoom screen, full meeting audio, and a searchable transcript.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                PermissionExplanation(icon: "rectangle.inset.filled.and.person.filled", title: "Zoom Video & Audio", detail: "Records Zoom’s windows and audio while excluding unrelated apps. Sound capture is independent of speakers, AirPods, or Bluetooth.")
                PermissionExplanation(icon: "mic.fill", title: "Your Microphone", detail: "Follows the Mac’s current default input and reconnects if that device changes.")
                PermissionExplanation(icon: "text.quote", title: "Speech Recognition", detail: "Creates the transcript. Video, audio, and transcripts are stored in your Mac’s Application Support folder.")
            }
            .frame(maxWidth: 560)

            Toggle(isOn: $acceptsResponsibility) {
                Text("I understand that recording laws vary, and I will notify participants and obtain any consent required where I am.")
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: 600)

            Button(requesting ? "Preparing MeetMemento…" : "Continue") {
                requesting = true
                Task {
                    await model.completeOnboarding()
                    requesting = false
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!acceptsResponsibility || requesting)

            Text("MeetMemento requests screen access once. Microphone, transcript, and calendar enhancements can be enabled individually from the dashboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(48)
    }
}

private struct PermissionExplanation: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 28)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
