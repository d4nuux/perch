import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: NotchController?
    private var menuBar: MenuBarItem?
    /// URLs delivered before the controller exists.
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = LaunchAtLogin.shared
        controller = NotchController()
        menuBar = MenuBarItem { [weak self] in
            guard let model = self?.controller?.model else { return }
            model.holdOpenUntil = Date().addingTimeInterval(5)
            model.open()
        }
        let urls = pendingURLs
        pendingURLs = []
        urls.forEach { URLRouter.handle($0, model: controller?.model) }
        OnboardingWindow.showIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller else { pendingURLs += urls; return }
        urls.forEach { URLRouter.handle($0, model: controller.model) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
