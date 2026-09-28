import Foundation
import IOBluetooth

/// Connect / disconnect of audio and input Bluetooth devices, via IOBluetooth user notifications.
/// Devices already connected when monitoring starts are recorded silently.
final class BluetoothMonitor: NSObject {
    enum Kind {
        case airpods, airpodsPro, airpodsMax, headphones, keyboard, mouse, gamepad, other

        var symbol: String {
            switch self {
            case .airpods: "airpods"
            case .airpodsPro: "airpods.pro"
            case .airpodsMax: "airpodsmax"
            case .headphones: "headphones"
            case .keyboard: "keyboard"
            case .mouse: "magicmouse"
            case .gamepad: "gamecontroller"
            case .other: "wave.3.right"
            }
        }
    }

    struct Device {
        let address: String
        let name: String
        let kind: Kind
        let battery: Int?
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
        let initial = Self.battery(device)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak device] in
            guard let self, let device, device.isConnected() else { return }
            let d = Self.describe(device)
            if d.battery != nil, d.battery != initial { self.onEvent?(.batteryUpdated(d)) }
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

    // MARK: Classification

    private static func address(_ d: IOBluetoothDevice) -> String {
        d.addressString ?? d.nameOrAddress ?? "\(ObjectIdentifier(d).hashValue)"
    }

    static func describe(_ d: IOBluetoothDevice) -> Device {
        let raw = d.name ?? d.nameOrAddress ?? "Bluetooth Device"
        return Device(address: address(d), name: displayName(raw), kind: kind(d), battery: battery(d))
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
        let name = (d.name ?? "").lowercased()
        if name.contains("airpods max") { return .airpodsMax }
        if name.contains("airpods pro") { return .airpodsPro }
        if name.contains("airpods") { return .airpods }
        if ["controller", "dualsense", "dualshock", "xbox", "joy-con", "gamepad"].contains(where: name.contains) {
            return .gamepad
        }
        let major = Int(d.deviceClassMajor), minor = Int(d.deviceClassMinor)
        if major == Int(kBluetoothDeviceClassMajorPeripheral) {
            if minor & 0x10 != 0 { return .keyboard }
            if minor & 0x20 != 0 { return .mouse }
            if (minor & 0x0F) == 0x01 || (minor & 0x0F) == 0x02 { return .gamepad }
        }
        if name.contains("keyboard") { return .keyboard }
        if name.contains("mouse") || name.contains("trackpad") { return .mouse }
        if major == Int(kBluetoothDeviceClassMajorAudio)
            || ["beats", "headphone", "buds", "wh-", "wf-"].contains(where: name.contains) {
            return .headphones
        }
        return .other
    }

    /// Audio and input devices only.
    static func isRelevant(_ d: IOBluetoothDevice) -> Bool {
        let major = Int(d.deviceClassMajor)
        return major == Int(kBluetoothDeviceClassMajorAudio)
            || major == Int(kBluetoothDeviceClassMajorPeripheral)
            || kind(d) != .other
    }

    /// Battery % from IOBluetoothDevice's private `batteryPercent*` getters, when present.
    /// Every key is guarded with `responds(to:)` so KVC can never raise on an unknown key.
    static func battery(_ d: IOBluetoothDevice) -> Int? {
        func value(_ key: String) -> Int? {
            guard d.responds(to: NSSelectorFromString(key)),
                  let n = d.value(forKey: key) as? NSNumber else { return nil }
            let v = n.intValue
            return (1...100).contains(v) ? v : nil
        }
        if let c = value("batteryPercentCombined") { return c }
        let buds = [value("batteryPercentLeft"), value("batteryPercentRight")].compactMap { $0 }
        if let m = buds.min() { return m }
        return value("batteryPercentSingle") ?? value("headsetBattery")
    }
}
