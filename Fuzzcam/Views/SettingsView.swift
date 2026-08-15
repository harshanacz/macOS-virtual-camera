import SwiftUI

/// Native macOS settings window.
///
/// Everything a normal user needs is on the first three tabs. Diagnostics live
/// under Advanced, off by default, because nobody choosing "make me look
/// blurry on calls" needs to see frame latency.
struct SettingsView: View {

    @Bindable var model: AppModel

    @Environment(\.openWindow) private var openWindowAction

    var body: some View {
        TabView {
            cameraTab.tabItem { Label("Camera", systemImage: "video") }
            qualityTab.tabItem { Label("Quality", systemImage: "slider.horizontal.3") }
            virtualCameraTab.tabItem { Label("Virtual Camera", systemImage: "sparkles.tv") }
            advancedTab.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 480, height: 400)
    }

    // MARK: - Camera

    private var cameraTab: some View {
        Form {
            Picker("Camera", selection: cameraSelection) {
                if model.cameras.isEmpty {
                    Text("No camera found").tag(String?.none)
                }
                ForEach(model.cameras) { camera in
                    Text(camera.name).tag(String?.some(camera.id))
                }
            }

            Toggle("Reconnect automatically", isOn: $model.configuration.automaticallyReconnect)
                .help("Reopen the camera by itself when it is unplugged and plugged back in, or when another app releases it.")

            LabeledContent("Status", value: model.statusLine)

            if let error = model.currentError {
                Section {
                    Text(error.recoverySuggestion).foregroundStyle(.secondary)
                    if error.needsPrivacySettings {
                        Button("Open Privacy Settings…") { CameraPermission.openPrivacySettings() }
                    } else {
                        Button("Try Again") { model.retry() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Quality

    private var qualityTab: some View {
        Form {
            Picker("Webcam Quality", selection: presetSelection) {
                ForEach(QualityPreset.allCases, id: \.self) { preset in
                    Text("\(preset.displayName) — \(preset.summary)").tag(preset)
                }
            }
            .help(model.configuration.preset.summary)

            LabeledContent("") {
                Text(model.configuration.preset.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Processing") {
                Text(model.processingDescription).foregroundStyle(.secondary)
            }

            Picker("Frame rate", selection: $model.configuration.frameRate) {
                ForEach(OutputFrameRate.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }

            Section("Detail") {
                slider("Sharpness", value: $model.configuration.sharpness)
                    .help("Below the midpoint softens the image; above it sharpens. The default sits low because cheap webcams are not sharp.")
                slider("Compression", value: $model.configuration.compression)
                    .help("Simulates the blocking and banding of a low-bitrate webcam.")
                slider("Noise", value: $model.configuration.noise)
                    .help("Adds animated sensor grain.")
            }

            Section {
                Toggle("Add blur", isOn: $model.configuration.blurEnabled)
                if model.configuration.blurEnabled {
                    LabeledContent("Blur radius") {
                        Slider(value: $model.configuration.blurRadius, in: 0...24)
                    }
                }
            } footer: {
                Text("Blur is off by default. Fuzzcam reduces quality by throwing away resolution, which looks like a bad webcam rather than a blurred face.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Virtual camera

    private var virtualCameraTab: some View {
        Form {
            Toggle("Publish virtual camera", isOn: $model.configuration.virtualCameraEnabled)

            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.virtualCamera.isActive ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.virtualCamera.displayText)
                }
            }

            TextField("Name", text: $model.configuration.virtualCameraName)
                .help("The name meeting apps show in their camera list.")

            LabeledContent("Output", value: "\(VirtualCameraFormat.width) × \(VirtualCameraFormat.height)")

            Section {
                Button("Install or Update Extension") { model.installExtension() }
                Button("Set-Up Guide…") { openWindow("onboarding") }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Renaming the camera takes effect the next time the extension starts.")
                    Text("Fuzzcam must stay running for meeting apps to receive your video. Closing this window is fine — quitting is not.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if !model.isSharedStoreAvailable {
                Text("The App Group container is unavailable, so settings cannot be shared with the camera extension. Check the app-group entitlement.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        Form {
            Toggle("Show developer metrics in preview", isOn: $model.configuration.showDeveloperMetrics)

            Section("Pipeline") {
                LabeledContent("Input", value: dimensions(model.metrics.inputSize))
                LabeledContent("Processing", value: dimensions(model.metrics.processingSize))
                LabeledContent("Output", value: dimensions(model.metrics.outputSize))
                LabeledContent("Frame rate", value: String(format: "%.1f fps", model.metrics.framesPerSecond))
                LabeledContent("Latency", value: String(format: "%.2f ms", model.metrics.latencyMilliseconds))
                LabeledContent("Dropped", value: "\(model.metrics.droppedFrames)")
            }

            Section("Virtual camera") {
                LabeledContent("Frames delivered", value: "\(model.virtualCamera.framesDelivered)")
                LabeledContent("Frames dropped", value: "\(model.virtualCamera.framesDropped)")
                LabeledContent("Extension ID", value: FuzzcamIdentifiers.extensionBundleID)
            }

            Section {
                Text("Fuzzcam processes your camera locally on your Mac. Video is not uploaded or recorded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0...1)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dimensions(_ size: CGSize) -> String {
        size.width > 0 ? "\(Int(size.width)) × \(Int(size.height))" : "—"
    }

    private func openWindow(_ id: String) {
        openWindowAction(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var cameraSelection: Binding<String?> {
        Binding(
            get: { model.selectedCamera?.id },
            set: { model.configuration.selectedCameraUniqueID = $0 }
        )
    }

    private var presetSelection: Binding<QualityPreset> {
        Binding(
            get: { model.configuration.preset },
            set: { model.selectPreset($0) }
        )
    }
}
