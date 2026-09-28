import CoreGraphics
import Foundation
import ObjectiveC

/// Built-in display brightness through the private DisplayServices framework.
final class DisplayBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getFn: GetFn?
    private let setFn: SetFn?

    init() {
        let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        getFn = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        setFn = dlsym(h, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
    }

    /// The built-in panel even when an external monitor is main; main display if there is none.
    private var display: CGDirectDisplayID { Self.builtInDisplay ?? CGMainDisplayID() }

    /// nil when the display isn't controllable (e.g. lid closed with only an external monitor).
    var brightness: Float? {
        guard let getFn else { return nil }
        var v: Float = -1
        guard getFn(display, &v) == 0, v >= 0, v <= 1 else { return nil }
        return v
    }

    func set(_ value: Float) -> Bool {
        guard let setFn else { return false }
        markOwnChange()
        return setFn(display, min(max(value, 0), 1)) == 0
    }

    // MARK: Changes made elsewhere

    private typealias RegisterFn = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFString,
                                                   CFNotificationCallback) -> Int32
    /// Our own sets echo back as notifications (possibly out of order during key repeat), so
    /// anything arriving this soon after one of ours is ignored.
    private static let echoWindow: TimeInterval = 0.6
    private let lock = NSLock()
    private var lastOwnChange = Date.distantPast
    fileprivate var onUserChange: ((Float) -> Void)?

    private func markOwnChange() {
        lock.lock(); lastOwnChange = Date(); lock.unlock()
    }

    fileprivate func received(_ value: Float) {
        lock.lock()
        let echo = Date().timeIntervalSince(lastOwnChange) < Self.echoWindow
        lock.unlock()
        guard !echo, value.isFinite, value >= 0, value <= 1 else { return }
        DispatchQueue.main.async { [weak self] in self?.onUserChange?(value) }
    }

    /// Calls `handler` on the main queue when the built-in display's brightness is changed by the
    /// user outside NotchApp (Control Center slider, System Settings). Push-only: DisplayServices'
    /// "DisplayServicesUserBrightness" notification, which CoreBrightness posts for user-level
    /// brightness sets. If the symbol is missing this does nothing (no polling fallback).
    /// Call once; the registration lives for the process.
    func observeUserChanges(_ handler: @escaping (Float) -> Void) {
        guard onUserChange == nil else { return }
        onUserChange = handler
        let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        guard let sym = dlsym(h, "DisplayServicesRegisterForNotification") else { return }
        let register = unsafeBitCast(sym, to: RegisterFn.self)
        // Retained for the process lifetime: DisplayServices keeps the raw pointer.
        let observer = UnsafeRawPointer(Unmanaged.passRetained(self).toOpaque())
        _ = register(Self.builtInDisplay ?? display, observer,
                     "DisplayServicesUserBrightness" as CFString, displayBrightnessCallback)
    }

    private static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

/// DisplayServices calls this on its own serial queue with userInfo {"value": brightness}.
private func displayBrightnessCallback(center: CFNotificationCenter?, observer: UnsafeMutableRawPointer?,
                                       name: CFNotificationName?, object: UnsafeRawPointer?,
                                       userInfo: CFDictionary?) {
    guard let observer, let info = userInfo as? [String: Any] else { return }
    let raw = info["value"]
    let value = (raw as? NSNumber)?.floatValue ?? (raw as? String).flatMap(Float.init)
    guard let value else { return }
    Unmanaged<DisplayBrightness>.fromOpaque(observer).takeUnretainedValue().received(value)
}

/// Keyboard backlight through CoreBrightness' `KeyboardBrightnessClient` (private ObjC class).
final class KeyboardBacklight {
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private let client: NSObject?
    private let keyboardID: UInt64?
    private let getSel = NSSelectorFromString("brightnessForKeyboard:")
    private let setSel = NSSelectorFromString("setBrightness:forKeyboard:")

    init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type,
              cls.instancesRespond(to: getSel), cls.instancesRespond(to: setSel),
              cls.instancesRespond(to: idsSel) else {
            client = nil; keyboardID = nil; return
        }
        let c = cls.init()
        let ids = c.perform(idsSel)?.takeRetainedValue() as? [NSNumber]
        client = c
        keyboardID = ids?.first?.uint64Value
    }

    var brightness: Float? {
        guard let client, let keyboardID else { return nil }
        let fn = unsafeBitCast(client.method(for: getSel), to: GetFn.self)
        let v = fn(client, getSel, keyboardID)
        return v.isFinite && v >= 0 && v <= 1 ? v : nil
    }

    func set(_ value: Float) -> Bool {
        guard let client, let keyboardID else { return false }
        let fn = unsafeBitCast(client.method(for: setSel), to: SetFn.self)
        return fn(client, setSel, min(max(value, 0), 1), keyboardID)
    }
}
