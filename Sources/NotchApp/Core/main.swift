import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = LaunchAtLogin.shared
        controller = NotchController()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
