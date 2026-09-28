import AppKit
import Combine

/// Replaces the system volume / brightness / keyboard-backlight HUDs. (Owned by the HUD agent.)
///
/// Media keys are intercepted by `MediaKeyTap`. While `settings.hudEnabled` is on, keys we can
/// service are swallowed (so the system OSD never appears), the change is applied here, and a notch
/// HUD is shown. Keys we can't service — or all keys when disabled — pass through to macOS.
final class HUDService {
    private let context: NotchContext
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

    /// `settings.hudEnabled`, mirrored for the tap thread.
    private let enabledLock = NSLock()
    private var _enabled = true
    private var enabled: Bool {
        get { enabledLock.lock(); defer { enabledLock.unlock() }; return _enabled }
        set { enabledLock.lock(); _enabled = newValue; enabledLock.unlock() }
    }

    /// `model.isExpanded`, mirrored for the tap thread. While open, keys go to macOS so the
    /// user still gets the system OSD (our HUD has nowhere to draw).
    private var _expanded = false
    private var expanded: Bool {
        get { enabledLock.lock(); defer { enabledLock.unlock() }; return _expanded }
        set { enabledLock.lock(); _expanded = newValue; enabledLock.unlock() }
    }

    private static let step: Float = 1.0 / 16.0
    private static let hudDuration: TimeInterval = 1.5
    private static let extraWidth: CGFloat = 220

    init(context: NotchContext) {
        self.context = context

        context.settings.$hudEnabled
            .sink { [weak self] on in self?.enabled = on }
            .store(in: &cancellables)
        context.model.$isExpanded
            .sink { [weak self] open in self?.expanded = open }
            .store(in: &cancellables)

        audio.onChange = { [weak self] in self?.volumeChangedExternally() }
        audio.startWatching()

        let tap = MediaKeyTap { [weak self] press in self?.handle(press) ?? false }
        self.tap = tap
        tap.start()
    }

    // MARK: Key handling (tap thread)

    /// Applies the key's effect. Returns true only when the change was actually made.
    private func handle(_ press: MediaKeyPress) -> Bool {
        guard enabled, !expanded else { return false }
        let step = press.fine ? Self.step / 4 : Self.step
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

    // MARK: External volume changes (main thread)

    private func volumeChangedExternally() {
        guard context.settings.hudEnabled, let dev = audio.defaultDevice, let v = audio.volume(dev) else { return }
        let state = levels[.volume]!
        let muted = audio.isMuted(dev)
        // Our own key presses echo back here; skip if nothing new.
        if abs(state.level - Double(v)) < 0.0005, state.muted == muted { return }
        present(.volume, level: Double(v), muted: muted)
    }

    // MARK: Presentation

    private func show(_ kind: HUDKind, level: Double, muted: Bool) {
        DispatchQueue.main.async { [weak self] in self?.present(kind, level: level, muted: muted) }
    }

    /// Main thread.
    private func present(_ kind: HUDKind, level: Double, muted: Bool) {
        guard let state = levels[kind] else { return }
        state.level = level
        state.muted = muted
        let model = context.model
        guard !model.isExpanded else { return }
        model.present(LiveActivity(key: kind.key, extraWidth: Self.extraWidth) {
            HUDIcon(state: state)
        } trailing: {
            HUDBar(state: state)
        }, duration: Self.hudDuration)
    }
}
