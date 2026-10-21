import IOBluetooth
import CoreAudio
import Foundation

func findEDIFIER() -> IOBluetoothDevice? {
    let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    return devices.first { ($0.name ?? "").uppercased().contains("EDIFIER") }
}
func audioDeviceCount() -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    return Int(size) / MemoryLayout<AudioDeviceID>.size
}
guard let dev = findEDIFIER() else { print("[bt] EDIFIER not paired"); exit(1) }
print("[bt] found \(dev.name ?? "?") connected=\(dev.isConnected()) audioDevices=\(audioDeviceCount())")
let result = dev.openConnection()
print("[bt] openConnection -> \(result)")
var connected = false
for i in 0..<30 {
    Thread.sleep(forTimeInterval: 0.5)
    if dev.isConnected() { print("[bt] connected after \(String(format: "%.1f", Double(i) * 0.5 + 0.5))s"); connected = true; break }
}
print("[bt] final connected=\(dev.isConnected()) audioDevices=\(audioDeviceCount())")
