import AppKit
import CoreGraphics
import IOKit

// MARK: - DDC/CI over IOAVService (Apple Silicon)

/// One external display's DDC/CI channel: the `DCPAVServiceProxy` (Location = External) wrapped
/// in an IOAVService. Calls block for tens of milliseconds; use from a background queue only.
final class DDCService {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let api: (create: CreateFn, read: I2CFn, write: I2CFn)? = {
        let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        guard let c = dlsym(h, "IOAVServiceCreateWithService"),
              let r = dlsym(h, "IOAVServiceReadI2C"),
              let w = dlsym(h, "IOAVServiceWriteI2C") else { return nil }
        return (unsafeBitCast(c, to: CreateFn.self), unsafeBitCast(r, to: I2CFn.self), unsafeBitCast(w, to: I2CFn.self))
    }()

    /// EDID-derived identity of the framebuffer this proxy belongs to (0 when unknown).
    struct Identity { var vendor: UInt32 = 0, product: UInt32 = 0, serial: UInt32 = 0, name = "" }

    let identity: Identity
    private let service: CFTypeRef

    private init(service: CFTypeRef, identity: Identity) {
        self.service = service
        self.identity = identity
    }

    private static let chip: UInt32 = 0x37      // DDC/CI 7-bit address
    private static let host: UInt32 = 0x51      // source address / "offset" argument
    private static let dest: UInt8 = 0x6E       // 0x37 << 1

    /// Walks the IOService plane in order. Each framebuffer (`AppleCLCD2` / `IOMobileFramebufferShim`)
    /// precedes its `DCPAVServiceProxy`, so a proxy takes the last framebuffer's DisplayAttributes.
    static func discover() -> [DDCService] {
        guard let api else { return [] }
        var iter = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var found: [DDCService] = []
        var lastIdentity = Identity()
        while true {
            let entry = IOIteratorNext(iter)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuf)
            let name = String(cString: nameBuf)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                lastIdentity = identity(of: entry)
            } else if name == "DCPAVServiceProxy" {
                let loc = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                guard loc == "External", let svc = api.create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                found.append(DDCService(service: svc, identity: lastIdentity))
            }
        }
        return found
    }

    private static func identity(of entry: io_registry_entry_t) -> Identity {
        guard let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let p = attrs["ProductAttributes"] as? [String: Any] else { return Identity() }
        func u(_ k: String) -> UInt32 { (p[k] as? NSNumber)?.uint32Value ?? 0 }
        return Identity(vendor: u("LegacyManufacturerID"), product: u("ProductID"), serial: u("SerialNumber"),
                        name: p["ProductName"] as? String ?? "")
    }

    /// VCP read: (current, max). nil when the display doesn't answer or the reply is malformed.
    func read(vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let api = Self.api else { return nil }
        var req: [UInt8] = [0x82, 0x01, vcp, 0]
        req[3] = Self.dest ^ UInt8(Self.host) ^ req[0] ^ req[1] ^ req[2]
        for _ in 0..<3 {
            usleep(10_000)
            guard api.write(service, Self.chip, Self.host, &req, UInt32(req.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard api.read(service, Self.chip, 0, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
            // Reply: 6E 88 02 <result> <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>
            guard let i = (0..<(reply.count - 7)).first(where: { reply[$0] == 0x02 && reply[$0 + 2] == vcp }),
                  reply[i + 1] == 0 else { continue }
            let max = UInt16(reply[i + 4]) << 8 | UInt16(reply[i + 5])
            let cur = UInt16(reply[i + 6]) << 8 | UInt16(reply[i + 7])
            guard max > 0, cur <= max else { continue }
            return (cur, max)
        }
        return nil
    }

    /// VCP set. Only used for brightness (0x10) on an explicit key press.
    @discardableResult
    func write(vcp: UInt8, value: UInt16) -> Bool {
        guard let api = Self.api else { return false }
        var pkt: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        pkt[5] = pkt[0..<5].reduce(Self.dest ^ UInt8(Self.host), ^)
        usleep(10_000)
        return api.write(service, Self.chip, Self.host, &pkt, UInt32(pkt.count)) == kIOReturnSuccess
    }
}

// MARK: - BetterDisplay CLI

/// BetterDisplay's CLI: the app binary run with `get`/`set` talks to the running instance.
enum BetterDisplayCLI {
    static let bundleID = "pro.betterdisplay.BetterDisplay"
    static let binary = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary) }
    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// 0...1, or nil.
    static func brightness(_ display: CGDirectDisplayID) -> Float? {
        run(["get", "-displayID=\(display)", "-brightness"]).flatMap { Float($0) }.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
    }

    @discardableResult
    static func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        run(["set", "-displayID=\(display)", "-brightness=\(String(format: "%.3f", value))"]) != nil
    }

    private static func run(_ args: [String]) -> String? {
        guard isInstalled, isRunning else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Bounded: the CLI answers in well under 100 ms; don't hang the worker if it doesn't.
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning, Date() < deadline { usleep(5_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.lowercased().contains("fail") || s.lowercased().contains("error") ? nil : s
    }
}

// MARK: - Controller

enum ExternalBrightnessMode: String, CaseIterable, Identifiable {
    case off, ddc, betterDisplay, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .ddc: "DDC"
        case .betterDisplay: "BetterDisplay"
        case .auto: "Auto"
        }
    }
}

/// Brightness of external displays. `canControl` is cheap and thread-safe (the tap thread asks it);
/// all I/O runs on a private serial queue. DDC writes are coalesced — only the newest target is
/// written, at most one every `minWriteInterval` — and the last value is cached, so key repeat
/// never waits on the bus. Discovery re-runs on display reconfiguration and mode changes only.
final class ExternalBrightness {
    private enum Backend { case ddc(DDCService, max: UInt16), betterDisplay }

    private struct Entry {
        var backend: Backend
        var level: Float?           // cached 0...1
        var lastTouch = Date.distantPast
    }

    private let queue = DispatchQueue(label: "NotchApp.ExternalBrightness", qos: .userInitiated)
    private let lock = NSLock()
    private var mode: ExternalBrightnessMode = .off     // guarded by lock
    private var entries: [CGDirectDisplayID: Entry] = [:] // guarded by lock
    private var pendingWrite: [CGDirectDisplayID: Float] = [:] // queue only
    private var writing = Set<CGDirectDisplayID>()      // queue only
    private var generation = 0                           // queue only
    private var observers: [NSObjectProtocol] = []
    private var discoverWork: DispatchWorkItem?          // main only

    /// Min spacing of DDC writes (monitors drop or queue faster ones).
    private static let minWriteInterval: TimeInterval = 0.06
    /// A cached level older than this is re-read first (the monitor's own buttons may have moved it).
    private static let staleAfter: TimeInterval = 10

    init() {
        CGDisplayRegisterReconfigurationCallback(externalReconfigCallback,
                                                 Unmanaged.passUnretained(self).toOpaque())
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == BetterDisplayCLI.bundleID else { return }
                self?.rediscover()
            })
        }
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rediscover()
        })
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(externalReconfigCallback, Unmanaged.passUnretained(self).toOpaque())
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func setMode(_ m: ExternalBrightnessMode) {
        lock.lock(); let changed = mode != m; mode = m; lock.unlock()
        if changed { rediscover() }
    }

    /// Tap thread safe.
    func canControl(_ display: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return mode != .off && entries[display] != nil
    }

    /// Steps the display's brightness. `done` gets the new level on the main queue (nil = failed).
    func step(_ display: CGDirectDisplayID, by delta: Float, stepper: @escaping (Float, Float) -> Float,
              done: @escaping (Float?) -> Void) {
        queue.async { [self] in
            lock.lock(); let entry = entries[display]; lock.unlock()
            guard var entry else { DispatchQueue.main.async { done(nil) }; return }
            if entry.level == nil || Date().timeIntervalSince(entry.lastTouch) > Self.staleAfter {
                if let fresh = readLevel(entry.backend, display) { entry.level = fresh }
            }
            guard let current = entry.level else { DispatchQueue.main.async { done(nil) }; return }
            let target = stepper(current, delta)
            entry.level = target
            entry.lastTouch = Date()
            lock.lock(); if entries[display] != nil { entries[display] = entry }; lock.unlock()
            DispatchQueue.main.async { done(target) }
            enqueueWrite(display, target)
        }
    }

    // MARK: Queue

    private func readLevel(_ backend: Backend, _ display: CGDirectDisplayID) -> Float? {
        switch backend {
        case let .ddc(svc, _):
            return svc.read(vcp: 0x10).map { Float($0.current) / Float($0.max) }
        case .betterDisplay:
            return BetterDisplayCLI.brightness(display)
        }
    }

    private func enqueueWrite(_ display: CGDirectDisplayID, _ value: Float) {
        pendingWrite[display] = value
        guard !writing.contains(display) else { return }
        writing.insert(display)
        drain(display)
    }

    /// Writes the newest pending value, then comes back after `minWriteInterval` for anything newer.
    private func drain(_ display: CGDirectDisplayID) {
        guard let value = pendingWrite.removeValue(forKey: display) else { writing.remove(display); return }
        lock.lock(); let backend = entries[display]?.backend; lock.unlock()
        switch backend {
        case let .ddc(svc, max):
            svc.write(vcp: 0x10, value: UInt16((value * Float(max)).rounded()))
        case .betterDisplay:
            BetterDisplayCLI.set(display, value)
        case nil:
            break
        }
        queue.asyncAfter(deadline: .now() + Self.minWriteInterval) { [weak self] in self?.drain(display) }
    }

    // MARK: Discovery

    /// Main thread. Debounced: display changes arrive as bursts of callbacks, and DCP needs a moment.
    fileprivate func rediscover(after delay: TimeInterval = 0.3) {
        discoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.discover() }
        discoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func discover() {
        queue.async { [self] in
            generation += 1
            let gen = generation
            lock.lock(); let m = mode; lock.unlock()
            var result: [CGDirectDisplayID: Entry] = [:]
            let externals = Self.externalDisplays()
            let bdRunning = BetterDisplayCLI.isInstalled && BetterDisplayCLI.isRunning
            if m != .off, !externals.isEmpty {
                if m == .ddc || m == .auto {
                    for (id, svc) in Self.match(DDCService.discover(), to: externals) {
                        // Read probe: only displays that actually answer DDC count as controllable.
                        if let r = svc.read(vcp: 0x10) {
                            result[id] = Entry(backend: .ddc(svc, max: r.max), level: Float(r.current) / Float(r.max),
                                               lastTouch: Date())
                        }
                    }
                }
                if (m == .betterDisplay || m == .auto) && bdRunning {
                    // Read probe: BetterDisplay must know the display.
                    for id in externals where result[id] == nil {
                        if let v = BetterDisplayCLI.brightness(id) {
                            result[id] = Entry(backend: .betterDisplay, level: v, lastTouch: Date())
                        }
                    }
                }
            }
            guard gen == generation else { return }
            lock.lock(); entries = result; lock.unlock()
        }
    }

    private static func externalDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    /// Pairs services with displays by EDID vendor/product(/serial); a single leftover pair is
    /// matched as-is (common when the registry has no DisplayAttributes).
    private static func match(_ services: [DDCService], to displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCService] {
        var out: [CGDirectDisplayID: DDCService] = [:]
        var freeServices = services
        for d in displays {
            let v = CGDisplayVendorNumber(d), p = CGDisplayModelNumber(d), s = CGDisplaySerialNumber(d)
            let candidates = freeServices.indices.filter {
                let i = freeServices[$0].identity
                return i.vendor == v && i.product == p && (s == 0 || i.serial == 0 || i.serial == s)
            }
            if candidates.count == 1 { out[d] = freeServices.remove(at: candidates[0]) }
        }
        let leftDisplays = displays.filter { out[$0] == nil }
        if leftDisplays.count == 1, freeServices.count == 1 { out[leftDisplays[0]] = freeServices[0] }
        return out
    }
}

private func externalReconfigCallback(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags,
                                      userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
    let me = Unmanaged<ExternalBrightness>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { me.rediscover(after: 1.0) }
}
