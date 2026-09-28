import AppKit
import ApplicationServices

/// Media keys delivered as NX_SYSDEFINED (subtype 8) events. Raw values are NX_KEYTYPE_* codes.
enum MediaKey: Int {
    case volumeUp = 0            // NX_KEYTYPE_SOUND_UP
    case volumeDown = 1          // NX_KEYTYPE_SOUND_DOWN
    case brightnessUp = 2        // NX_KEYTYPE_BRIGHTNESS_UP
    case brightnessDown = 3      // NX_KEYTYPE_BRIGHTNESS_DOWN
    case mute = 7                // NX_KEYTYPE_MUTE
    case illuminationUp = 21     // NX_KEYTYPE_ILLUMINATION_UP
    case illuminationDown = 22   // NX_KEYTYPE_ILLUMINATION_DOWN
}

struct MediaKeyPress {
    let key: MediaKey
    let isDown: Bool
    let isRepeat: Bool
    /// Option+Shift held: quarter-size steps, like macOS.
    let fine: Bool
}

/// CGEventTap on NX_SYSDEFINED events, running on its own thread so a busy main thread can't
/// time the tap out (which would lag every key system-wide).
///
/// `handler` runs on the tap thread and returns true to swallow the event. Anything it doesn't
/// claim — and every event whenever the tap can't be created — passes through untouched.
final class MediaKeyTap {
    private let handler: (MediaKeyPress) -> Bool
    private var tap: CFMachPort?
    private var thread: Thread?
    private var retryTimer: Timer?
    /// Key codes whose key-down we swallowed; their key-up is swallowed too. Tap thread only.
    private var swallowed = Set<Int>()

    private static let sysDefinedType = CGEventType(rawValue: 14)! // NX_SYSDEFINED
    private static let auxControlSubtype: Int16 = 8                 // NX_SUBTYPE_AUX_CONTROL_BUTTONS

    init(handler: @escaping (MediaKeyPress) -> Bool) {
        self.handler = handler
    }

    /// Call on the main thread. Prompts for Accessibility once, then retries every few seconds
    /// until the process is trusted and the tap exists.
    func start() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts), createTap() { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted(), self.createTap() {
                timer.invalidate()
                self.retryTimer = nil
            }
        }
    }

    private func createTap() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1) << CGEventMask(Self.sysDefinedType.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: mediaKeyTapCallback, userInfo: refcon
        ) else { return false }
        tap = port

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let t = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        t.name = "NotchApp.MediaKeyTap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case Self.sysDefinedType:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == Self.auxControlSubtype else {
            return Unmanaged.passUnretained(event)
        }
        let data1 = ns.data1
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8   // 0xA down, 0xB up
        guard let key = MediaKey(rawValue: code), state == 0xA || state == 0xB else {
            return Unmanaged.passUnretained(event)
        }

        if state == 0xB {
            // Key-up: swallow only if we swallowed the matching key-down.
            return swallowed.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
        }

        let mods = event.flags
        let press = MediaKeyPress(key: key, isDown: true, isRepeat: flags & 0x1 != 0,
                                  fine: mods.contains(.maskAlternate) && mods.contains(.maskShift))
        if handler(press) {
            swallowed.insert(code)
            return nil
        }
        swallowed.remove(code)
        return Unmanaged.passUnretained(event)
    }
}

private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
