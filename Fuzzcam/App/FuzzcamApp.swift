import SwiftUI

@main
struct FuzzcamApp: App {

    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: model)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Window("Fuzzcam", id: "preview") {
            PreviewWindowView(model: model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 680, height: 520)

        Window("Fuzzcam Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Set Up Fuzzcam", id: "onboarding") {
            OnboardingView(model: model)
        }
        .windowResizability(.contentSize)
    }

    /// The icon carries the one piece of state worth glancing at: whether apps
    /// are actually receiving video.
    private var menuBarSymbol: String {
        if model.virtualCamera.isActive { return "video.fill" }
        if model.isCapturing { return "video" }
        return "video.slash"
    }
}
