import SwiftUI

@main
struct SolarLightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(settings: ChatSettings())
        }
    }
}
