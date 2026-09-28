import os
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

/// CGEventTap on NX_SYSDEFINED events (plus keyDown/keyUp for the brightness key codes some
/// keyboards send instead — see `keyCodeKeys`), running on its own thread so a busy main thread can't
/// time the tap out (which would lag every key system-wide).
///
/// `handler` runs on the tap thread and returns true to swallow the event. Anything it doesn't
/// claim — and every event whenever the tap can't be created — passes through untouched.
final class MediaKeyTap {
    private let handler: (MediaKeyPress) -> Bool
    private var tap: CFMachPort?  // guarded by `lock`
    private var thread: Thread?
    private var retryTimer: Timer?
    /// Key codes whose key-down we swallowed; their key-up is swallowed too. Tap thread only.
    private var swallowed = Set<Int>()
    /// Regular key codes some keyboards emit for the brightness keys instead of (or alongside)
    /// NX_SYSDEFINED — e.g. Apple Silicon / Magic Keyboard report 144/145 in keyDown events.
    private static let keyCodeKeys: [Int64: MediaKey] = [144: .brightnessUp, 145: .brightnessDown]
    /// Key-code keys whose key-down we swallowed. Tap thread only.
    private var swallowedKeyCodes = Set<Int64>()
    /// Last decision per key and which path produced it. If a keyboard sends both an NX_SYSDEFINED
    /// event and a keyDown for one press, the second copy reuses the decision instead of stepping
    /// twice. Tap thread only.
    private var lastDecision: [MediaKey: (time: UInt64, viaKeyCode: Bool, swallowed: Bool)] = [:]
    private static let duplicateWindowNs: UInt64 = 25_000_000

    private static let sysDefinedType = CGEventType(rawValue: 14)! // NX_SYSDEFINED
    private static let auxControlSubtype: Int16 = 8                 // NX_SUBTYPE_AUX_CONTROL_BUTTONS

    init(handler: @escaping (MediaKeyPress) -> Bool) {
        self.handler = handler
    }

    /// Call on the main thread. Never prompts (onboarding / Settings › Permissions request
    /// Accessibility); retries every few seconds until the process is trusted and the tap exists.
    /// Once it exists, a health check (every 30s and on wake) re-creates it if it died.
    /// AXIsProcessTrusted, logging each change so permission problems show up in Console.
    private func trusted() -> Bool {
        let t = AXIsProcessTrusted()
        if t != loggedTrust {
            loggedTrust = t
            Self.log.notice("accessibility trusted: \(t, privacy: .public)")
        }
        return t
    }

    func start() {
        guard !started else { return }
        started = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.checkHealth() }
        if trusted(), createTap() { schedule(health: true) } else { schedule(health: false) }
    }

    private var started = false
    private var wakeObserver: NSObjectProtocol?
    /// The only timer: 3s creation retry while there's no tap, 30s health check while there is.
    private var timerIsHealth: Bool?
    private let lock = NSLock()
    /// Run loop of the current tap thread (set from that thread). Guarded by `lock`, as is `tap`.
    private var tapRunLoop: CFRunLoop?

    private func schedule(health: Bool) {
        guard timerIsHealth != health else { return }
        timerIsHealth = health
        retryTimer?.invalidate()
        let t = Timer(timeInterval: health ? 30 : 3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.checkHealth()
        }
        t.tolerance = health ? 10 : 1
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    /// Main thread. Cheap: two CF calls while the tap is healthy.
    private func checkHealth() {
        if let port = currentTap() {
            if CFMachPortIsValid(port) {
                if CGEvent.tapIsEnabled(tap: port) { return }
                CGEvent.tapEnable(tap: port, enable: true)
                if CGEvent.tapIsEnabled(tap: port) { return }
            }
            destroyTap()
        }
        if trusted(), createTap() { schedule(health: true) } else { schedule(health: false) }
    }

    private func currentTap() -> CFMachPort? {
        lock.lock(); defer { lock.unlock() }
        return tap
    }

    /// Main thread. Invalidating the port removes its source, so the tap thread's run loop exits.
    private func destroyTap() {
        lock.lock()
        let port = tap, rl = tapRunLoop
        tap = nil; tapRunLoop = nil
        lock.unlock()
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let rl { CFRunLoopStop(rl) }
        thread = nil
    }

    private static let log = Logger(subsystem: "NotchApp", category: "MediaKeyTap")
    private var loggedTrust: Bool?


    private func createTap() -> Bool {
        guard currentTap() == nil else { return true }
        let sysMask = CGEventMask(1) << CGEventMask(Self.sysDefinedType.rawValue)
        let keyMask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
            | CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        func make(_ mask: CGEventMask) -> CFMachPort? {
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                              eventsOfInterest: mask, callback: mediaKeyTapCallback, userInfo: refcon)
        }
        // If keyboard events can't be tapped, keep the media-key tap alone.
        guard let port = make(sysMask | keyMask) ?? make(sysMask) else {
            Self.log.error("tapCreate failed although trusted")
            return false
        }
        Self.log.notice("media key tap created")
        lock.lock(); tap = port; lock.unlock()

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let t = Thread { [weak self] in
            let rl = CFRunLoopGetCurrent()
            if let self {
                self.lock.lock()
                let current = self.tap === port
                if current { self.tapRunLoop = rl }
                self.lock.unlock()
                guard current else { return } // destroyed before this thread started
            }
            CFRunLoopAddSource(rl, source, .commonModes)
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
            if let tap = currentTap() { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case Self.sysDefinedType:
            break
        case .keyDown, .keyUp:
            return handleKeyCode(type: type, event: event)
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
        if decide(press, viaKeyCode: false) {
            swallowed.insert(code)
            return nil
        }
        swallowed.remove(code)
        return Unmanaged.passUnretained(event)
    }

    private func handleKeyCode(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = Self.keyCodeKeys[code] else { return Unmanaged.passUnretained(event) }
        if type == .keyUp {
            return swallowedKeyCodes.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
        }
        let mods = event.flags
        let press = MediaKeyPress(key: key, isDown: true,
                                  isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                  fine: mods.contains(.maskAlternate) && mods.contains(.maskShift))
        if decide(press, viaKeyCode: true) {
            swallowedKeyCodes.insert(code)
            return nil
        }
        swallowedKeyCodes.remove(code)
        return Unmanaged.passUnretained(event)
    }

    /// Runs `handler` unless this is the other path's copy of a press we just decided on.
    private func decide(_ press: MediaKeyPress, viaKeyCode: Bool) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if let last = lastDecision[press.key], last.viaKeyCode != viaKeyCode,
           now &- last.time < Self.duplicateWindowNs {
            lastDecision[press.key] = nil  // pair consumed
            return last.swallowed
        }
        let swallow = handler(press)
        lastDecision[press.key] = (now, viaKeyCode, swallow)
        return swallow
    }
}

private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
