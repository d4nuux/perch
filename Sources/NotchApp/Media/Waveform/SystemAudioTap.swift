import AudioToolbox
import CoreAudio
import Foundation

/// Captures system audio output through a Core Audio process tap (macOS 14.4+) wrapped in a private
/// aggregate device. `onSamples` is called on a Core Audio IO thread with interleaved or mono Float32
/// frames (first channel only is passed — enough for a visualizer). No audio is played or muted.
@available(macOS 14.4, *)
final class SystemAudioTap {
    enum TapError: Error { case status(String, OSStatus) }

    /// IO thread. `samples` are mono Float32; `count` frames; `sampleRate` Hz.
    var onSamples: ((UnsafePointer<Float>, Int, Double) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "notchapp.waveform.io", qos: .userInteractive)
    private var mono = [Float](repeating: 0, count: 4096)
    private(set) var sampleRate: Double = 48_000

    func start() throws {
        guard procID == nil else { return }
        do { try setUp() } catch { stop(); throw error }
    }

    private func setUp() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        desc.name = "NotchApp Visualizer"
        try check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(desc, &tapID))

        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check("kAudioTapPropertyFormat", AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &fmt))
        if fmt.mSampleRate > 0 { sampleRate = fmt.mSampleRate }

        // Tap-only private aggregate: doesn't add the output device as a sub-device, so the user's
        // real output path (calls, Bluetooth) is untouched.
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchApp Visualizer",
            kAudioAggregateDeviceUIDKey: "local.notchapp.visualizer.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check("AudioHardwareCreateAggregateDevice",
                  AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID))

        let interleaved = fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        try check("AudioDeviceCreateIOProcIDWithBlock",
                  AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, input, _, _, _ in
            self?.handle(input, interleaved: interleaved)
        })
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, procID))
    }

    private func handle(_ input: UnsafePointer<AudioBufferList>, interleaved: Bool) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buf = list.first, let data = buf.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        let total = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        let stride = interleaved ? Int(max(buf.mNumberChannels, 1)) : 1
        let frames = min(total / stride, mono.count)
        guard frames > 0 else { return }
        mono.withUnsafeMutableBufferPointer { m in
            if stride == 1 {
                m.baseAddress!.update(from: floats, count: frames)
            } else {
                // Average L/R.
                for i in 0..<frames {
                    var s: Float = 0
                    for c in 0..<stride { s += floats[i * stride + c] }
                    m[i] = s / Float(stride)
                }
            }
            onSamples?(UnsafePointer(m.baseAddress!), frames, sampleRate)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func check(_ what: String, _ s: OSStatus) throws {
        if s != noErr { throw TapError.status(what, s) }
    }
}
