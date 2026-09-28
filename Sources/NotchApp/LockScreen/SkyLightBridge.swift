import AppKit
import os

/// Thin, defensive wrapper around the private SkyLight calls used to put a window into a space
/// that sits at the lock-screen absolute level. Every symbol is resolved with dlsym; if anything is
/// missing or a call fails, `isAvailable` goes false and the feature disables itself (logged once).
///
/// Technique (same as Lakr233/SkyLightWindow): create one space, set its absolute level to 400
/// (NotificationCenterAtScreenLock), show it, then move window numbers into it.
final class SkyLightBridge {
    static let shared = SkyLightBridge()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    static let symbolNames = [
        "SLSMainConnectionID", "SLSSpaceCreate", "SLSSpaceSetAbsoluteLevel",
        "SLSShowSpaces", "SLSSpaceAddWindowsAndRemoveFromSpaces",
    ]
    /// kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock
    private static let lockScreenLevel: Int32 = 400

    private let log = Logger(subsystem: "NotchApp", category: "LockScreen")
    private var mainConnectionID: MainConnectionID?
    private var spaceCreate: SpaceCreate?
    private var setAbsoluteLevel: SpaceSetAbsoluteLevel?
    private var showSpaces: ShowSpaces?
    private var addWindows: SpaceAddWindows?

    private var connection: Int32 = 0
    private var space: Int32 = 0
    private var disabledReason: String?
    private var warnedAddWindows = false

    private init() {
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY)
                ?? dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            disable("dlopen SkyLight failed")
            return
        }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        mainConnectionID = sym("SLSMainConnectionID", MainConnectionID.self)
        spaceCreate = sym("SLSSpaceCreate", SpaceCreate.self)
        setAbsoluteLevel = sym("SLSSpaceSetAbsoluteLevel", SpaceSetAbsoluteLevel.self)
        showSpaces = sym("SLSShowSpaces", ShowSpaces.self)
        addWindows = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", SpaceAddWindows.self)

        let missing = zip(Self.symbolNames, [mainConnectionID != nil, spaceCreate != nil,
                                             setAbsoluteLevel != nil, showSpaces != nil, addWindows != nil])
            .filter { !$0.1 }.map(\.0)
        if !missing.isEmpty { disable("missing symbols: \(missing.joined(separator: ", "))") }
    }

    var isAvailable: Bool { disabledReason == nil }

    /// Lazily creates and shows the lock-level space (once per process). Returns false on failure.
    private func ensureSpace() -> Bool {
        guard isAvailable else { return false }
        if space != 0 { return true }
        guard let mainConnectionID, let spaceCreate, let setAbsoluteLevel, let showSpaces else { return false }
        connection = mainConnectionID()
        guard connection != 0 else { disable("SLSMainConnectionID returned 0"); return false }
        let s = spaceCreate(connection, 1, 0)
        guard s != 0 else { disable("SLSSpaceCreate returned 0"); return false }
        if setAbsoluteLevel(connection, s, Self.lockScreenLevel) != 0 {
            disable("SLSSpaceSetAbsoluteLevel failed"); return false
        }
        if showSpaces(connection, [NSNumber(value: s)] as CFArray) != 0 {
            disable("SLSShowSpaces failed"); return false
        }
        space = s
        return true
    }

    /// Moves `window` into the lock-level space. The window must be ordered in (windowNumber > 0).
    @discardableResult
    func delegate(_ window: NSWindow) -> Bool {
        guard ensureSpace(), let addWindows, window.windowNumber > 0 else { return false }
        let r = addWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        if r != 0, !warnedAddWindows {
            warnedAddWindows = true
            log.error("SLSSpaceAddWindowsAndRemoveFromSpaces returned \(r, privacy: .public)")
        }
        return r == 0
    }

    private func disable(_ reason: String) {
        guard disabledReason == nil else { return }
        disabledReason = reason
        log.error("Lock screen widgets disabled: \(reason, privacy: .public)")
    }
}
