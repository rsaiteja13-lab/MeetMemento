import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @ViewState private var acceptsResponsibility = false
    @ViewState private var requesting = false

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            VStack(spacing: 9) {
                Text("Welcome to MeetMemento")
                    .font(.largeTitle.bold())
                Text("Automatically save your Zoom video, full meeting audio, and a searchable transcript.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                PermissionExplanation(icon: "rectangle.inset.filled.and.person.filled", title: "Zoom video and audio", detail: "Captures the Zoom screen and meeting audio whether you use speakers, AirPods, or another headset.")
                PermissionExplanation(icon: "mic.fill", title: "Your voice", detail: "Includes your side of the conversation and follows the microphone you’re currently using.")
                PermissionExplanation(icon: "text.quote", title: "Searchable transcript", detail: "Turns the saved audio into a transcript. Your recording stays on this Mac.")
            }
            .frame(maxWidth: 560)

            Toggle(isOn: $acceptsResponsibility) {
                Text("I’ll notify participants and obtain any consent required by local law or workplace policy.")
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: 600)

            Button(requesting ? setupButtonTitle : "Set Up MeetMemento") {
                requesting = true
                Task {
                    await model.completeOnboarding()
                    requesting = false
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!acceptsResponsibility || requesting)

            Text("Start once, then approve each macOS request as it appears. MeetMemento checks completion automatically and won’t ask again unless access changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(48)
    }

    private var setupButtonTitle: String {
        switch model.permissionSetupPhase {
        case .microphone: return "Requesting microphone…"
        case .speechRecognition: return "Requesting transcript access…"
        case .calendar: return "Requesting calendar…"
        case .screenRecording: return "Requesting screen access…"
        case .needsSystemSettings: return "Finish in System Settings…"
        case .complete: return "You’re all set"
        case .ready: return "Preparing MeetMemento…"
        }
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
