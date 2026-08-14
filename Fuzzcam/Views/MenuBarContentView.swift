import SwiftUI

/// The menu that drops down from the status item.
///
/// Plain `.menu` style, so this is a real AppKit menu: no custom window, no
/// focus stealing, and it behaves like every other menu-bar utility.
struct MenuBarContentView: View {

    @Bindable var model: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)

        if let error = model.currentError {
            Text(error.recoverySuggestion)
            if error.needsPrivacySettings {
                Button("Open Privacy Settings…") { CameraPermission.openPrivacySettings() }
            } else {
                Button("Try Again") { model.retry() }
            }
        }

        Divider()

        Menu("Camera") {
            if model.cameras.isEmpty {
                Text("No cameras found")
            } else {
                ForEach(model.cameras) { camera in
                    Button {
                        model.selectCamera(camera)
                    } label: {
                        checked(camera.name, isOn: camera.id == model.selectedCamera?.id)
                    }
                }
            }
        }

        Menu("Quality") {
            ForEach(QualityPreset.allCases, id: \.self) { preset in
                Button {
                    model.selectPreset(preset)
                } label: {
                    checked(preset.displayName, isOn: preset == model.configuration.preset)
                }
            }
        }

        Divider()

        Text("Virtual Camera: \(model.virtualCamera.displayText)")

        if !model.virtualCamera.isActive {
            Button("Set Up Virtual Camera…") { open("onboarding") }
        }

        #if DEBUG
        // DEVELOPMENT ONLY: a window for OBS to capture until the camera
        // extension can be notarized. Absent from release builds.
        Button(model.isDevCameraOutputRunning
               ? "Stop Development Camera Output"
               : "Start Development Camera Output…") {
            model.toggleDevCameraOutput()
        }
        #endif

        Button("Preview…") { open("preview") }

        Button("Settings…") { open("settings") }
            .keyboardShortcut(",")

        Divider()

        Button("Quit Fuzzcam") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// AppKit menus render `Label`'s image as a leading icon, which is how the
    /// selected camera and preset get their checkmark without a custom view.
    @ViewBuilder
    private func checked(_ title: String, isOn: Bool) -> some View {
        if isOn {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    /// An `LSUIElement` app is never frontmost, so a newly opened window would
    /// appear behind whatever the user was doing without this activation.
    private func open(_ id: String) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
