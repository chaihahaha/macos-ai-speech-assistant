import CoreAudio
import Foundation

/// Bluetooth headsets expose separate input/output endpoints. After a few
/// A2DP <-> HFP switches macOS stops activating the headset microphone: the
/// 16 kHz input endpoint exists but delivers pure silence, and the next engine
/// falls back to the 44.1 kHz output endpoint and stalls.
///
/// Setting the Bluetooth output device's nominal sample rate to 16 kHz makes the
/// device negotiate HFP. The original rate is restored after recording.
final class AudioRoute {
    private var savedRate: Float64?
    private var device: AudioDeviceID?

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : 0
    }

    private func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    private func nominalRate(_ device: AudioDeviceID) -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    @discardableResult
    private func setNominalRate(_ device: AudioDeviceID, _ rate: Float64) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        let size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        return status == noErr
    }

    /// Call right after pausing the output keep-alive, before the recorder starts.
    func preferHFPForInput() {
        let output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        guard output != 0, transportType(output) == kAudioDeviceTransportTypeBluetooth else { return }
        let current = nominalRate(output)
        guard current > 0, current != 16000 else { return }
        savedRate = current
        device = output
        let ok = setNominalRate(output, 16000)
        print("[AudioRoute] forcing HFP: output device \(output) rate \(Int(current)) -> 16000 (ok=\(ok))")
    }

    /// Call after the recorder stopped, before resuming the A2DP keep-alive.
    func restoreOutputRate() {
        defer { device = nil; savedRate = nil }
        guard let device, let savedRate else { return }
        let ok = setNominalRate(device, savedRate)
        print("[AudioRoute] restoring output rate \(Int(savedRate)) (ok=\(ok))")
    }
}
