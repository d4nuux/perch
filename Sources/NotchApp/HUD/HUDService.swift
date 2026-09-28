import AppKit
import Combine

/// Replaces the system volume / brightness / keyboard-backlight HUDs. (Owned by the HUD agent.)
///
/// Media keys are intercepted by `MediaKeyTap`. While `settings.hudEnabled` and the per-HUD toggle
/// in `HUDSettings` are on, keys we can service are swallowed (so the system OSD never appears),
/// the change is applied here, and a notch HUD is shown. Keys we can't service — or keys of a
/// disabled HUD — pass through to macOS.
///
/// Also shown without a key press: volume/mute changed anywhere, the default output device
/// changing, and user brightness changes from Control Center / System Settings.
final class HUDService {
    private let context: NotchContext
    private let hud = HUDSettings.shared
    private let audio = SystemAudio()
    private let display = DisplayBrightness()
    private let keyboard = KeyboardBacklight()
    private var tap: MediaKeyTap?
    private var cancellables = Set<AnyCancellable>()

    private let levels: [HUDKind: HUDLevel] = [
        .volume: HUDLevel(kind: .volume),
        .brightness: HUDLevel(kind: .brightness),
        .keyboard: HUDLevel(kind: .keyboard),
    ]

    /// What the tap thread needs to decide, mirrored from main-thread state.
    private struct Gate {
        var master = true
        var expanded = false
        var volume = true, brightness = true, keyboard = true
    }
    private let gateLock = NSLock()
    private var _gate = Gate()
    private var gate: Gate {
        get { gateLock.lock(); defer { gateLock.unlock() }; return _gate }
    }
    private func updateGate(_ change: (inout Gate) -> Void) {
        gateLock.lock(); change(&_gate); gateLock.unlock()
    }

    private static let step: Float = 1.0 / 16.0
    /// Device-change HUD lingers a bit longer than a level change: the name needs reading.
    private static let announceExtra: TimeInterval = 0.8
    private var announceUntil = Date.distantPast
    private var deviceChangeWork: DispatchWorkItem?

    init(context: NotchContext) {
        self.context = context

        // While the notch is open, keys go to macOS so the user still gets the system OSD
        // (our HUD has nowhere to draw).
        context.settings.$hudEnabled
            .sink { [weak self] on in self?.updateGate { $0.master = on } }
            .store(in: &cancellables)
        context.model.$isExpanded
            .sink { [weak self] open in self?.updateGate { $0.expanded = open } }
            .store(in: &cancellables)
        hud.$volumeEnabled.sink { [weak self] on in self?.updateGate { $0.volume = on } }.store(in: &cancellables)
        hud.$brightnessEnabled.sink { [weak self] on in self?.updateGate { $0.brightness = on } }.store(in: &cancellables)
        hud.$keyboardEnabled.sink { [weak self] on in self?.updateGate { $0.keyboard = on } }.store(in: &cancellables)

        refreshDevice()
        audio.onChange = { [weak self] in self?.volumeChangedExternally() }
        audio.onDeviceChange = { [weak self] in self?.outputDeviceChanged() }
        audio.startWatching()

        display.observeUserChanges { [weak self] value in self?.brightnessChangedExternally(value) }

        let tap = MediaKeyTap { [weak self] press in self?.handle(press) ?? false }
        self.tap = tap
        tap.start()
    }

    // MARK: Key handling (tap thread)

    /// Applies the key's effect. Returns true only when the change was actually made; anything
    /// else (disabled, unsupported device, API failure) returns false and macOS handles the key.
    private func handle(_ press: MediaKeyPress) -> Bool {
        let g = gate
        guard g.master else { return false }
        let step = press.fine ? Self.step / 4 : Self.step
        switch press.key {
        case .volumeUp, .volumeDown, .mute: guard g.volume else { return false }
        case .brightnessUp, .brightnessDown: guard g.brightness else { return false }
        case .illuminationUp, .illuminationDown: guard g.keyboard else { return false }
        }
        switch press.key {
        case .volumeUp: return changeVolume(by: step)
        case .volumeDown: return changeVolume(by: -step)
        case .mute: return press.isRepeat ? isControllable() : toggleMute()
        case .brightnessUp: return changeBacklight(.brightness, by: step)
        case .brightnessDown: return changeBacklight(.brightness, by: -step)
        case .illuminationUp: return changeBacklight(.keyboard, by: step)
        case .illuminationDown: return changeBacklight(.keyboard, by: -step)
        }
    }

    /// Moves to the next multiple of `delta` in its direction, like macOS does.
    private static func stepped(_ value: Float, by delta: Float) -> Float {
        let n = value / abs(delta)
        let snapped = delta > 0 ? (n + 0.001).rounded(.down) + 1 : (n - 0.001).rounded(.up) - 1
        return min(max(snapped * abs(delta), 0), 1)
    }

    private func isControllable() -> Bool {
        guard let dev = audio.defaultDevice else { return false }
        return audio.canSetMute(dev)
    }

    private func changeVolume(by delta: Float) -> Bool {
        guard let dev = audio.defaultDevice, let current = audio.volume(dev) else { return false }
        let muted = audio.isMuted(dev)
        let target = Self.stepped(current, by: delta)
        // Volume up while muted unmutes, as macOS does.
        if delta > 0, muted { audio.setMuted(dev, false) }
        if target != current, !audio.setVolume(dev, target) { return false }
        let nowMuted = delta > 0 ? false : muted
        show(.volume, level: Double(target), muted: nowMuted)
        return true
    }

    private func toggleMute() -> Bool {
        guard let dev = audio.defaultDevice, audio.canSetMute(dev) else { return false }
        let muted = !audio.isMuted(dev)
        guard audio.setMuted(dev, muted) else { return false }
        show(.volume, level: Double(audio.volume(dev) ?? 0), muted: muted)
        return true
    }

    private func changeBacklight(_ kind: HUDKind, by delta: Float) -> Bool {
        let current = kind == .brightness ? display.brightness : keyboard.brightness
        guard let current else { return false }
        let target = Self.stepped(current, by: delta)
        let ok = kind == .brightness ? display.set(target) : keyboard.set(target)
        guard ok else { return false }
        show(kind, level: Double(target), muted: false)
        return true
    }

    // MARK: External changes (main thread)

    private var wantsExternal: Bool { context.settings.hudEnabled }

    private func volumeChangedExternally() {
        guard wantsExternal, hud.volumeEnabled, let dev = audio.defaultDevice, let v = audio.volume(dev) else { return }
        let state = levels[.volume]!
        let muted = audio.isMuted(dev)
        // Our own key presses echo back here; skip if nothing new.
        if abs(state.level - Double(v)) < 0.0005, state.muted == muted { return }
        present(.volume, level: Double(v), muted: muted)
    }

    private func refreshDevice() {
        levels[.volume]!.device = audio.defaultDevice.map { audio.outputInfo($0) }
    }

    /// AirPods connecting can flip the default device more than once; show only where it settles.
    private func outputDeviceChanged() {
        deviceChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let before = self.levels[.volume]!.device
            self.refreshDevice()
            guard let dev = self.audio.defaultDevice, let info = self.levels[.volume]!.device, info != before,
                  self.wantsExternal, self.hud.volumeEnabled, self.hud.showDeviceChanges else { return }
            self.announceUntil = Date().addingTimeInterval(self.hud.duration + Self.announceExtra)
            self.present(.volume, level: Double(self.audio.volume(dev) ?? 0), muted: self.audio.isMuted(dev))
        }
        deviceChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func brightnessChangedExternally(_ value: Float) {
        guard wantsExternal, hud.brightnessEnabled else { return }
        if abs(levels[.brightness]!.level - Double(value)) < 0.0005, context.model.activity?.key == HUDKind.brightness.key {
            return
        }
        present(.brightness, level: Double(value), muted: false)
    }

    // MARK: Presentation

    private func show(_ kind: HUDKind, level: Double, muted: Bool) {
        DispatchQueue.main.async { [weak self] in self?.present(kind, level: level, muted: muted) }
    }

    /// Main thread.
    private func present(_ kind: HUDKind, level: Double, muted: Bool) {
        guard let state = levels[kind] else { return }
        let announcing = kind == .volume && Date() < announceUntil
        state.level = level
        state.muted = muted
        state.announcing = announcing
        let model = context.model
        let duration = hud.duration + (announcing ? Self.announceExtra : 0)
        model.present(LiveActivity(key: kind.key,
                                   extraWidth: HUDLayout.extraWidth(settings: hud, forceLabel: announcing)) {
            HUDLeading(state: state)
        } trailing: {
            HUDTrailing(state: state)
        }, duration: duration)
    }
}
