import AppKit

/// Per-panel UI state: which display a notch panel sits on and how big its notch is.
/// Injected as an environment object into that panel's NotchView (one per screen).
final class NotchScreen: ObservableObject {
    @Published var displayID: CGDirectDisplayID
    @Published var notchSize: CGSize
    /// No hardware notch on this screen; drawn as a pill hanging from the menu bar.
    @Published var isSimulated: Bool
    /// Pointer is over the collapsed notch (drives the hover grow).
    @Published var isHovering = false

    init(displayID: CGDirectDisplayID, notchSize: CGSize, isSimulated: Bool) {
        self.displayID = displayID
        self.notchSize = notchSize
        self.isSimulated = isSimulated
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }

    /// Hardware notch size, or nil if the screen has none.
    var hardwareNotchSize: CGSize? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }

    /// Menu bar height on this screen (0 if it can't be derived, e.g. auto-hidden menu bar).
    var menuBarHeight: CGFloat {
        let h = frame.maxY - visibleFrame.maxY
        return h > 0 ? h : NSStatusBar.system.thickness
    }
}

enum Screens {
    static let simulatedBaseSize = CGSize(width: 185, height: 32)

    /// Screens the notch should appear on, per settings. Order: first entry is the "primary" panel.
    static func targets(_ s: DisplaySettings) -> [NSScreen] {
        let all = NSScreen.screens
        guard !all.isEmpty else { return [] }
        let usable: (NSScreen) -> Bool = { $0.hardwareNotchSize != nil || s.simulateNotch }
        var picked: [NSScreen]
        switch s.showOn {
        case .builtIn:
            picked = [all.first(where: \.isBuiltIn) ?? all[0]]
        case .main:
            // screens[0] is the menu-bar ("main") display. NSScreen.main follows key focus.
            picked = [all[0]]
        case .all:
            // Put the notched/built-in screen first so it owns the shared context panel.
            picked = all.sorted { a, b in
                (a.hardwareNotchSize != nil ? 0 : 1, a.isBuiltIn ? 0 : 1)
                    < (b.hardwareNotchSize != nil ? 0 : 1, b.isBuiltIn ? 0 : 1)
            }
        case .specific:
            let match = all.first { $0.displayID == s.specificDisplayID && $0.localizedName == s.specificDisplayName }
                ?? all.first { $0.localizedName == s.specificDisplayName }
            picked = [match ?? all[0]]
        }
        return picked.filter(usable)
    }

    /// Notch size for `screen` with the user's offsets applied. A hardware notch never shrinks
    /// below the physical cutout (the camera housing would show through).
    static func notchSize(for screen: NSScreen, _ s: DisplaySettings) -> (size: CGSize, simulated: Bool) {
        let dw = CGFloat(s.widthOffset), dh = CGFloat(s.heightOffset)
        if let hw = screen.hardwareNotchSize {
            return (CGSize(width: max(hw.width, hw.width + dw), height: max(hw.height, hw.height + dh)), false)
        }
        let mb = screen.menuBarHeight
        let base = mb > 0 ? min(max(mb, 24), 40) : simulatedBaseSize.height
        return (CGSize(width: simulatedBaseSize.width + dw, height: max(20, base + dh)), true)
    }
}
