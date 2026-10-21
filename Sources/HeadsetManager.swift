import CoreAudio
import Foundation
import IOBluetooth

/// Manages the Bluetooth headset at the *system audio device* level.
///
/// Why this exists: when the earbuds disconnect (or their audio profiles drop),
/// macOS silently switches the default input to a virtual device (silence) and
/// the default output to the Mac speakers. The app then "records" nothing,
/// speaks into the wrong device, and media keys stop belonging to the headset.
/// This helper detects that state, reconnects the paired headset, and pins the
/// headset as the default input/output again.
final class HeadsetManager {
    static let shared = HeadsetManager()

    /// Case-insensitive fragment of the paired device name.
    var nameFragment = "EDIFIER"

    private var savedOutputRate: Float64?

    private init() {}

    private var pairedDevice: IOBluetoothDevice? {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.first { ($0.name ?? "").uppercased().contains(nameFragment.uppercased()) }
    }

    var isConnected: Bool {
        pairedDevice?.isConnected() ?? false
    }

    // MARK: - CoreAudio helpers

    private func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private func deviceName(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (name?.takeUnretainedValue() as String? ?? "") : ""
    }

    private func hasChannels(_ device: AudioDeviceID, input: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    @discardableResult
    private func setDefault(_ selector: AudioObjectPropertySelector, _ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id) == noErr
    }

    private func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private func nominalRate(_ device: AudioDeviceID) -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
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
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    /// Force the headset output into HFP (16 kHz) so a duplex engine can open
    /// the microphone's SCO link instead of binding to A2DP (44.1 kHz).
    func forceHFPOutput() {
        let output = defaultOutputDevice()
        guard output != 0 else { return }
        let current = nominalRate(output)
        guard current > 0, current != 16000 else { return }
        savedOutputRate = current
        let ok = setNominalRate(output, 16000)
        print("[Headset] force HFP output rate \(Int(current)) -> 16000 ok=\(ok)")
    }

    /// Restore the A2DP output rate when the conversation ends.
    func restoreOutputRate() {
        defer { savedOutputRate = nil }
        guard let saved = savedOutputRate else { return }
        let output = defaultOutputDevice()
        guard output != 0 else { return }
        let ok = setNominalRate(output, saved)
        print("[Headset] restore output rate \(Int(saved)) ok=\(ok)")
    }

    // MARK: - Public API

    /// True when the headset is present as both an input and an output device.
    var isAudioAvailable: Bool {
        let devices = allDevices()
        let fragment = nameFragment.uppercased()
        let hasInput = devices.contains { deviceName($0).uppercased().contains(fragment) && hasChannels($0, input: true) }
        let hasOutput = devices.contains { deviceName($0).uppercased().contains(fragment) && hasChannels($0, input: false) }
        return hasInput && hasOutput
    }

    /// Set the headset as the system default input and output.
    @discardableResult
    func pinDefaults() -> Bool {
        let devices = allDevices()
        let fragment = nameFragment.uppercased()
        guard let input = devices.first(where: { deviceName($0).uppercased().contains(fragment) && hasChannels($0, input: true) }),
              let output = devices.first(where: { deviceName($0).uppercased().contains(fragment) && hasChannels($0, input: false) }) else {
            return false
        }
        // Only touch the system defaults when they actually differ. Re-setting the
        // same device causes needless reconfiguration (and audible switching).
        let currentInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let currentOutput = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let inputOK = currentInput == input || setDefault(kAudioHardwarePropertyDefaultInputDevice, input)
        let outputOK = currentOutput == output || setDefault(kAudioHardwarePropertyDefaultOutputDevice, output)
        return inputOK && outputOK
    }

    /// Make sure the headset audio device is available and pinned, reconnecting
    /// the paired device if necessary.
    func ensureReady(maxWait: TimeInterval = 10) async -> Bool {
        if pinDefaults() { return true }

        if let device = pairedDevice, !device.isConnected() {
            print("[Headset] reconnecting \(device.name ?? "?")")
            _ = device.openConnection()
        }

        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if pinDefaults() { return true }
            if let device = pairedDevice, !device.isConnected() {
                _ = device.openConnection()
            }
        }
        print("[Headset] audio device not available after \(Int(maxWait))s")
        return false
    }

    /// Harder reset used after a capture failure: drop and reopen the Bluetooth
    /// link, then wait for the audio devices to come back.
    func reconnect(maxWait: TimeInterval = 12) async -> Bool {
        guard let device = pairedDevice else { return false }
        if device.isConnected() {
            _ = device.closeConnection()
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        _ = device.openConnection()

        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if pinDefaults() { return true }
            if let device = pairedDevice, !device.isConnected() {
                _ = device.openConnection()
            }
        }
        return false
    }
}
