import SwiftUI

@main
struct OverboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Overboard", systemImage: "sailboat.fill") {
            Button("Quit Overboard") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
