import CoreAudio
import Foundation

/// Output volume / mute of the default output device via CoreAudio. Uses the main element when
/// the device has a master control, otherwise channels 1 and 2. Thread-safe (CoreAudio is).
final class SystemAudio {
    /// Called on the main queue when the default device's volume or mute changes, from any source.
    var onChange: (() -> Void)?

    private let queue = DispatchQueue.main
    private var watchedDevice = AudioObjectID(kAudioObjectUnknown)
    private var watchedAddresses: [AudioObjectPropertyAddress] = []
    private var changePending = false
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.coalesceChange()
    }
    private lazy var defaultDeviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.rewatch()
    }
    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    // MARK: Reading / writing

    var defaultDevice: AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &Self.defaultOutputAddress, 0, nil, &size, &id)
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Elements that carry a settable control for `selector`: [main] or the stereo channels.
    private func elements(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [UInt32] {
        if settable(device, selector, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { settable(device, selector, $0) }
    }

    private func settable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: UInt32) -> Bool {
        var addr = address(selector, element)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &addr, &ok) == noErr && ok.boolValue
    }

    private func address(_ selector: AudioObjectPropertySelector, _ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    func canSetVolume(_ device: AudioObjectID) -> Bool { !elements(device, kAudioDevicePropertyVolumeScalar).isEmpty }
    func canSetMute(_ device: AudioObjectID) -> Bool { !elements(device, kAudioDevicePropertyMute).isEmpty }

    /// Average of the controllable channels, 0...1.
    func volume(_ device: AudioObjectID) -> Float? {
        let values = elements(device, kAudioDevicePropertyVolumeScalar).compactMap { el -> Float? in
            var addr = address(kAudioDevicePropertyVolumeScalar, el)
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr ? v : nil
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    @discardableResult
    func setVolume(_ device: AudioObjectID, _ value: Float) -> Bool {
        var v = Float32(min(max(value, 0), 1))
        var ok = false
        for el in elements(device, kAudioDevicePropertyVolumeScalar) {
            var addr = address(kAudioDevicePropertyVolumeScalar, el)
            ok = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr || ok
        }
        return ok
    }

    func isMuted(_ device: AudioObjectID) -> Bool {
        guard let el = elements(device, kAudioDevicePropertyMute).first else { return false }
        var addr = address(kAudioDevicePropertyMute, el)
        var v = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr && v != 0
    }

    @discardableResult
    func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool {
        var v = UInt32(muted ? 1 : 0)
        var ok = false
        for el in elements(device, kAudioDevicePropertyMute) {
            var addr = address(kAudioDevicePropertyMute, el)
            ok = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr || ok
        }
        return ok
    }

    // MARK: Change listening

    /// Start listening. Call on the main thread. No callback fires until something changes.
    func startWatching() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &Self.defaultOutputAddress, queue, defaultDeviceListener)
        rewatch()
    }

    /// (Re)binds the per-device listeners to the current default output device.
    private func rewatch() {
        for var addr in watchedAddresses {
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &addr, queue, deviceListener)
        }
        watchedAddresses = []
        watchedDevice = AudioObjectID(kAudioObjectUnknown)
        guard let device = defaultDevice else { return }
        watchedDevice = device
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for el: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
                var addr = address(selector, el)
                guard AudioObjectHasProperty(device, &addr) else { continue }
                if AudioObjectAddPropertyListenerBlock(device, &addr, queue, deviceListener) == noErr {
                    watchedAddresses.append(addr)
                }
            }
        }
    }

    /// Left/right channel listeners fire back to back; collapse them into one callback.
    private func coalesceChange() {
        guard !changePending else { return }
        changePending = true
        queue.async { [weak self] in
            guard let self else { return }
            self.changePending = false
            self.onChange?()
        }
    }
}
