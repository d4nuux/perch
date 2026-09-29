import AppKit
import Combine

/// Optional menu bar icon (AppSettings.menuBarIcon, default off): Open, Settings…, Quit.
final class MenuBarItem: NSObject {
    private var item: NSStatusItem?
    private var cancellable: AnyCancellable?
    private let openNotch: () -> Void

    init(openNotch: @escaping () -> Void) {
        self.openNotch = openNotch
        super.init()
        cancellable = AppSettings.shared.$menuBarIcon
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.setVisible(on) }
    }

    private func setVisible(_ on: Bool) {
        if on, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                accessibilityDescription: "Perch")
            image?.isTemplate = true
            i.button?.image = image
            i.menu = makeMenu()
            item = i
        } else if !on, let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(entry("Open Perch", #selector(openAction), ""))
        menu.addItem(entry("Settings…", #selector(settingsAction), ","))
        menu.addItem(.separator())
        menu.addItem(entry("Quit Perch", #selector(quitAction), "q"))
        return menu
    }

    private func entry(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
        m.target = self
        return m
    }

    @objc private func openAction() { openNotch() }
    @objc private func settingsAction() { SettingsWindow.show() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}
