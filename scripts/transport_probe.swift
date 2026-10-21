import CoreAudio
import Foundation
func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var d = AudioDeviceID(0); var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d); return d
}
func transport(_ d: AudioDeviceID) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0; var s = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &s, &v); return v
}
func name(_ d: AudioDeviceID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var n: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &n) { AudioObjectGetPropertyData(d, &a, 0, nil, &s, $0) }
    return st == noErr ? (n?.takeUnretainedValue() as String? ?? "?") : "?"
}
func fourCC(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: bytes, encoding: .ascii) ?? "?"
}
let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
let inp = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
print("out \(name(out)) id=\(out) transport=0x\(String(transport(out), radix:16)) '\(fourCC(transport(out)))'")
print("in  \(name(inp)) id=\(inp) transport=0x\(String(transport(inp), radix:16)) '\(fourCC(transport(inp)))'")
print("kAudioDeviceTransportTypeBluetooth   = 0x\(String(kAudioDeviceTransportTypeBluetooth, radix:16)) '\(fourCC(kAudioDeviceTransportTypeBluetooth))'")
print("kAudioDeviceTransportTypeBluetoothLE = 0x\(String(kAudioDeviceTransportTypeBluetoothLE, radix:16)) '\(fourCC(kAudioDeviceTransportTypeBluetoothLE))'")
