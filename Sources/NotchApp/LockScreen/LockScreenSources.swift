import AppKit
import CoreAudio
import CoreBluetooth
import EventKit
import IOBluetooth
import IOKit.pwr_mgt

// Small, self-contained data sources used only while the lock-screen widgets are showing.
// None of them prompt for any permission.

// MARK: - Output volume (CoreAudio, default output device, scalar)

final class LockVolume {
    /// Main queue. nil = the default device has no settable volume.
    var onChange: ((Float?) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var watched: [AudioObjectPropertyAddress] = []
    private var running = false
    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        self.onChange?(self.volume())
    }
    private lazy var defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.rewatch()
    }
    private static var defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        guard !running else { return }
        running = true
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput,
                                            .main, defaultListener)
        rewatch()
    }

    func stop() {
        guard running else { return }
        running = false
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput,
                                               .main, defaultListener)
        unwatch()
    }

    deinit { stop() }

    func set(_ value: Float) {
        guard let dev = currentDevice() else { return }
        var v = Float32(min(max(value, 0), 1))
        for el in elements(dev) {
            var a = addr(el)
            AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    func volume() -> Float? {
        guard let dev = currentDevice() else { return nil }
        let vals = elements(dev).compactMap { el -> Float? in
            var a = addr(el)
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
        }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Float(vals.count)
    }

    private func rewatch() {
        unwatch()
        guard running, let dev = currentDevice() else { onChange?(nil); return }
        device = dev
        for el in elements(dev) {
            var a = addr(el)
            if AudioObjectAddPropertyListenerBlock(dev, &a, .main, volumeListener) == noErr { watched.append(a) }
        }
        onChange?(volume())
    }

    private func unwatch() {
        for var a in watched { AudioObjectRemovePropertyListenerBlock(device, &a, .main, volumeListener) }
        watched = []
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func currentDevice() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput,
                                             0, nil, &size, &id)
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private func addr(_ el: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: el)
    }

    /// [main] if it has a settable volume, else the settable stereo channels.
    private func elements(_ dev: AudioObjectID) -> [UInt32] {
        func settable(_ el: UInt32) -> Bool {
            var a = addr(el)
            guard AudioObjectHasProperty(dev, &a) else { return false }
            var ok: DarwinBoolean = false
            return AudioObjectIsPropertySettable(dev, &a, &ok) == noErr && ok.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(settable)
    }
}

// MARK: - Bluetooth device batteries

struct LockBTDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let battery: Int
}

enum LockBluetooth {
    /// Connected devices that report a battery level. Returns [] without Bluetooth permission
    /// (checked via CBManager.authorization, which never prompts).
    static func devices() -> [LockBTDevice] {
        guard CBManager.authorization == .allowedAlways else { return [] }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.filter { $0.isConnected() }.compactMap { d in
            guard let b = battery(d) else { return nil }
            let raw = d.name ?? d.nameOrAddress ?? "Device"
            return LockBTDevice(id: d.addressString ?? raw, name: shortName(raw), symbol: symbol(d), battery: b)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Private `batteryPercent*` getters, each guarded with responds(to:) so KVC can't raise.
    private static func battery(_ d: IOBluetoothDevice) -> Int? {
        func value(_ key: String) -> Int? {
            guard d.responds(to: NSSelectorFromString(key)),
                  let n = d.value(forKey: key) as? NSNumber else { return nil }
            let v = n.intValue
            return (1...100).contains(v) ? v : nil
        }
        if let c = value("batteryPercentCombined") { return c }
        if let m = [value("batteryPercentLeft"), value("batteryPercentRight")].compactMap({ $0 }).min() { return m }
        return value("batteryPercentSingle") ?? value("headsetBattery")
    }

    /// "Danu's AirPods Pro" -> "AirPods Pro".
    private static func shortName(_ raw: String) -> String {
        for sep in ["'s ", "’s "] {
            if let r = raw.range(of: sep) {
                let rest = raw[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return raw
    }

    private static func symbol(_ d: IOBluetoothDevice) -> String {
        let n = (d.name ?? "").lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpods.pro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if ["controller", "dualsense", "xbox", "gamepad"].contains(where: n.contains) { return "gamecontroller" }
        if Int(d.deviceClassMajor) == Int(kBluetoothDeviceClassMajorAudio) { return "headphones" }
        return "wave.3.right"
    }
}

// MARK: - Next calendar event (read-only, existing access only)

struct LockEvent: Equatable {
    let title: String
    let start: Date
    let end: Date
    let color: CGColor
}

/// Reads today's next (or current) timed event. Never requests access: returns nil unless
/// full calendar access was already granted.
final class LockEventReader {
    private var store: EKEventStore?
    private let queue = DispatchQueue(label: "notchapp.lockscreen.events", qos: .utility)

    /// Calls `completion` on the main queue.
    func fetchNext(_ completion: @escaping (LockEvent?) -> Void) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            store = nil
            completion(nil)
            return
        }
        let s = store ?? EKEventStore()
        store = s
        queue.async {
            let now = Date()
            let cal = Calendar.current
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
            let ev = s.events(matching: s.predicateForEvents(withStart: now, end: end, calendars: nil))
                .filter { e in
                    !e.isAllDay && e.status != .canceled && (e.endDate ?? .distantPast) > now
                        && e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined
                }
                .min { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            let result = ev.map { e in
                LockEvent(title: (e.title?.isEmpty == false ? e.title! : "Untitled"),
                          start: e.startDate ?? now, end: e.endDate ?? now,
                          color: e.calendar?.cgColor ?? NSColor.systemBlue.cgColor)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// MARK: - Keep display awake

/// Holds a PreventUserIdleDisplaySleep assertion while `held` is true.
final class LockKeepAwake {
    private var id = IOPMAssertionID(0)

    var held: Bool {
        get { id != 0 }
        set {
            if newValue, id == 0 {
                var newID = IOPMAssertionID(0)
                let r = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    "NotchApp lock screen widgets" as CFString, &newID)
                if r == kIOReturnSuccess { id = newID }
            } else if !newValue, id != 0 {
                IOPMAssertionRelease(id)
                id = 0
            }
        }
    }

    deinit { held = false }
}
