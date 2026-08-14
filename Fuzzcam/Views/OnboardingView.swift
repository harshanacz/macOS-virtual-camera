import SwiftUI

/// First-launch walkthrough, and the place the menu sends people when the
/// virtual camera is not working yet.
///
/// Five short steps, no jargon. Nothing here mentions CoreMediaIO, App Groups
/// or pixel buffers — a person who wants to look worse on calls should not have
/// to learn what a sink stream is.
struct OnboardingView: View {

    @Bindable var model: AppModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    step(
                        number: 1,
                        title: "Allow camera access",
                        detail: "Fuzzcam needs your camera to make a lower-quality copy of it.",
                        state: cameraStepState
                    ) {
                        if model.permission != .authorized {
                            Button("Open Privacy Settings…") { CameraPermission.openPrivacySettings() }
                        }
                    }

                    step(
                        number: 2,
                        title: "Add the Fuzzcam camera",
                        detail: "macOS asks you to approve this once, in System Settings → General → Login Items & Extensions → Camera Extensions.",
                        state: extensionStepState
                    ) {
                        HStack {
                            Button("Install Camera Extension") { model.installExtension() }
                            Button("Open System Settings…") { openExtensionSettings() }
                                .buttonStyle(.link)
                        }
                    }

                    step(
                        number: 3,
                        title: "Open your meeting app",
                        detail: "Google Meet, Zoom, Teams, Discord, FaceTime — anything that uses a camera.",
                        state: .neutral
                    ) { EmptyView() }

                    step(
                        number: 4,
                        title: "Pick “\(model.configuration.virtualCameraName)” as your camera",
                        detail: "It appears in the camera list alongside your real one.",
                        state: .neutral
                    ) { EmptyView() }

                    step(
                        number: 5,
                        title: "Choose how rough you want to look",
                        detail: "Set the quality from the Fuzzcam menu at any time — the change is instant.",
                        state: .neutral
                    ) { EmptyView() }
                }
                .padding(22)
            }

            Divider()

            footer
        }
        .frame(width: 560, height: 580)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "video.badge.waveform")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to Fuzzcam")
                    .font(.title2.weight(.semibold))
                Text("A deliberately worse webcam, for when you would rather not be in high definition.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
    }

    private var footer: some View {
        HStack {
            Text("Video never leaves your Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") {
                model.completeOnboarding()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    enum StepState {
        case neutral, pending, done

        var symbol: String {
            switch self {
            case .neutral: return "circle"
            case .pending: return "exclamationmark.circle.fill"
            case .done:    return "checkmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .neutral: return .secondary
            case .pending: return .orange
            case .done:    return .green
            }
        }
    }

    private var cameraStepState: StepState {
        model.permission == .authorized ? .done : .pending
    }

    private var extensionStepState: StepState {
        model.virtualCamera.isActive ? .done : .pending
    }

    @ViewBuilder
    private func step<Actions: View>(
        number: Int,
        title: String,
        detail: String,
        state: StepState,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: state.symbol)
                .font(.system(size: 18))
                .foregroundStyle(state.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(number). \(title)")
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
    }

    /// Deep-links to the pane where camera extensions are approved. macOS has
    /// moved this pane between releases, so a failure falls back to opening
    /// System Settings at all rather than doing nothing.
    private func openExtensionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
