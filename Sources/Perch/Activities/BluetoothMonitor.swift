import Foundation
import IOBluetooth

/// Connect / disconnect of audio and input Bluetooth devices, via IOBluetooth user notifications.
/// Devices already connected when monitoring starts are recorded silently.
final class BluetoothMonitor: NSObject {
    enum Kind {
        case airpods, airpodsPro, airpodsMax, beats, headphones, keyboard, mouse, gamepad
        case watch, phone, tablet, other

        var symbol: String {
            switch self {
            case .airpods: "airpods"
            case .airpodsPro: "airpodspro"
            case .airpodsMax: "airpodsmax"
            case .beats: "beats.headphones"
            case .headphones: "headphones"
            case .keyboard: "keyboard"
            case .mouse: "magicmouse"
            case .gamepad: "gamecontroller"
            case .watch: "applewatch"
            case .phone: "iphone"
            case .tablet: "ipad"
            case .other: "wave.3.right"
            }
        }

        /// Audio / input accessories we announce. Phones, tablets and watches connect for
        /// Continuity / tethering all the time and are never announced.
        var isAccessory: Bool {
            switch self {
            case .watch, .phone, .tablet, .other: false
            default: true
            }
        }

        var isBudsWithCase: Bool { self == .airpods || self == .airpodsPro }
    }

    /// Per-component AirPods battery, from IOBluetoothDevice's `batteryPercentLeft/Right/Case`.
    struct Buds: Equatable {
        var left: Int?
        var right: Int?
        var chargingCase: Int?
        var hasBuds: Bool { left != nil || right != nil }
    }

    struct Device {
        let address: String
        let name: String
        let kind: Kind
        let battery: Int?
        var buds: Buds? = nil
    }

    enum Event {
        case connected(Device)
        case batteryUpdated(Device)
        case disconnected(Device)
    }

    var onEvent: ((Event) -> Void)?
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var startedAt = Date.distantFuture
    /// IOBluetooth replays connect notifications for already-connected devices right after
    /// registering; ignore anything inside this window.
    private static let launchGrace: TimeInterval = 3

    func start() {
        guard connectNote == nil else { return }
        startedAt = Date()
        for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where d.isConnected() {
            watchDisconnect(d)
        }
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceConnected(_:device:)))
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let addr = Self.address(device)
        guard disconnectNotes[addr] == nil else { return } // already known / duplicate
        watchDisconnect(device)
        guard Date().timeIntervalSince(startedAt) > Self.launchGrace, Self.isRelevant(device) else { return }
        onEvent?(.connected(Self.describe(device)))
        // Battery values usually arrive a moment after the link comes up.
        let initial = (Self.battery(device), Self.buds(device))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak device] in
            guard let self, let device, device.isConnected() else { return }
            let d = Self.describe(device)
            let changed = (d.battery != nil && d.battery != initial.0) || (d.buds != nil && d.buds != initial.1)
            if changed { self.onEvent?(.batteryUpdated(d)) }
        }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        disconnectNotes[Self.address(device)] = nil
        guard Self.isRelevant(device) else { return }
        let d = Self.describe(device)
        onEvent?(.disconnected(Device(address: d.address, name: d.name, kind: d.kind, battery: nil)))
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        let addr = Self.address(device)
        guard disconnectNotes[addr] == nil,
              let n = device.register(forDisconnectNotification: self,
                                      selector: #selector(deviceDisconnected(_:device:))) else { return }
        disconnectNotes[addr] = n
    }

    /// Number of connected devices we're tracking (any class).
    var connectedCount: Int { disconnectNotes.count }

    /// Currently connected audio / input devices, with fresh battery readings.
    func connectedDevices() -> [Device] {
        ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
            .filter { $0.isConnected() && Self.isRelevant($0) }
            .map(Self.describe)
    }

    // MARK: Classification

    private static func address(_ d: IOBluetoothDevice) -> String {
        d.addressString ?? d.nameOrAddress ?? "\(ObjectIdentifier(d).hashValue)"
    }

    static func describe(_ d: IOBluetoothDevice) -> Device {
        let raw = d.name ?? d.nameOrAddress ?? "Bluetooth Device"
        return Device(address: address(d), name: displayName(raw), kind: kind(d), battery: battery(d), buds: buds(d))
    }

    /// "Danu's AirPods Pro" -> "AirPods Pro".
    static func displayName(_ raw: String) -> String {
        for sep in ["'s ", "’s "] {
            if let r = raw.range(of: sep), r.upperBound < raw.endIndex {
                let rest = raw[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return raw
    }

    static func kind(_ d: IOBluetoothDevice) -> Kind {
        kind(name: d.name ?? "", major: Int(d.deviceClassMajor), minor: Int(d.deviceClassMinor),
             appleProductID: appleProductID(d))
    }

    /// Name first (most specific), then Apple product ID (survives renaming), then class of device.
    static func kind(name rawName: String, major: Int, minor: Int, appleProductID: Int?) -> Kind {
        let name = rawName.lowercased()
        if name.contains("airpods max") { return .airpodsMax }
        if name.contains("airpods pro") { return .airpodsPro }
        if name.contains("airpods") { return .airpods }
        if let pid = appleProductID, let k = appleKinds[pid] { return k }
        if name.contains("beats") { return .beats }
        if ["controller", "dualsense", "dualshock", "xbox", "joy-con", "gamepad"].contains(where: name.contains) {
            return .gamepad
        }
        if major == Int(kBluetoothDeviceClassMajorPeripheral) {
            if minor & 0x10 != 0 { return .keyboard }
            if minor & 0x20 != 0 { return .mouse }
            if (minor & 0x0F) == 0x01 || (minor & 0x0F) == 0x02 { return .gamepad }
        }
        if name.contains("keyboard") { return .keyboard }
        if name.contains("mouse") || name.contains("trackpad") { return .mouse }
        if major == Int(kBluetoothDeviceClassMajorAudio)
            || ["headphone", "buds", "wh-", "wf-"].contains(where: name.contains) {
            return .headphones
        }
        // Wearable/wristwatch (0x07/0x01), computer/wearable (0x01/0x06), computer/tablet (0x01/0x07).
        if (major == Int(kBluetoothDeviceClassMajorWearable) && minor == 0x01)
            || (major == Int(kBluetoothDeviceClassMajorComputer) && minor == 0x06)
            || name.contains("watch") {
            return .watch
        }
        if (major == Int(kBluetoothDeviceClassMajorComputer) && minor == 0x07) || name.contains("ipad") {
            return .tablet
        }
        if major == Int(kBluetoothDeviceClassMajorPhone) || name.contains("iphone") { return .phone }
        return .other
    }

    /// Well-known Apple (vendor 0x004C) Bluetooth product IDs, for AirPods that were renamed.
    private static let appleKinds: [Int: Kind] = [
        0x2002: .airpods, 0x200F: .airpods, 0x2013: .airpods,
        0x200E: .airpodsPro, 0x2014: .airpodsPro, 0x2024: .airpodsPro,
        0x200A: .airpodsMax,
    ]

    /// Product ID when the device reports Apple's Bluetooth vendor ID. Private getters, guarded.
    private static func appleProductID(_ d: IOBluetoothDevice) -> Int? {
        func int(_ key: String) -> Int? {
            guard d.responds(to: NSSelectorFromString(key)) else { return nil }
            return (d.value(forKey: key) as? NSNumber)?.intValue
        }
        guard int("vendorID") == 0x004C, let pid = int("productID"), pid != 0 else { return nil }
        return pid
    }

    /// Audio and input devices only.
    static func isRelevant(_ d: IOBluetoothDevice) -> Bool {
        let major = Int(d.deviceClassMajor)
        return major == Int(kBluetoothDeviceClassMajorAudio)
            || major == Int(kBluetoothDeviceClassMajorPeripheral)
            || kind(d).isAccessory
    }

    /// Battery % from IOBluetoothDevice's private `batteryPercent*` getters, when present.
    /// Every key is guarded with `responds(to:)` so KVC can never raise on an unknown key.
    static func battery(_ d: IOBluetoothDevice) -> Int? {
        if let c = percent(d, "batteryPercentCombined") { return c }
        let buds = [percent(d, "batteryPercentLeft"), percent(d, "batteryPercentRight")].compactMap { $0 }
        if let m = buds.min() { return m }
        return percent(d, "batteryPercentSingle") ?? percent(d, "headsetBattery")
    }

    /// Left / right / case for AirPods-style devices; nil when neither bud reports.
    static func buds(_ d: IOBluetoothDevice) -> Buds? {
        let b = Buds(left: percent(d, "batteryPercentLeft"), right: percent(d, "batteryPercentRight"),
                     chargingCase: percent(d, "batteryPercentCase"))
        return b.hasBuds ? b : nil
    }

    private static func percent(_ d: IOBluetoothDevice, _ key: String) -> Int? {
        guard d.responds(to: NSSelectorFromString(key)),
              let n = d.value(forKey: key) as? NSNumber else { return nil }
        let v = n.intValue
        return (1...100).contains(v) ? v : nil
    }
}
