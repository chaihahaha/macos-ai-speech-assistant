import AVFoundation
import CoreAudio
import Foundation

func allDevices() -> [AudioDeviceID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids
}
func name(_ d: AudioDeviceID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var n: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &n) { AudioObjectGetPropertyData(d, &a, 0, nil, &s, $0) }
    return st == noErr ? (n?.takeUnretainedValue() as String? ?? "?") : "?"
}
func hasChannels(_ d: AudioDeviceID, input: Bool) -> Bool {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr, size > 0 else { return false }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, raw) == noErr else { return false }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
}
func getDefault(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var d = AudioDeviceID(0); var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d); return d
}
func setDefault(_ sel: AudioObjectPropertySelector, _ d: AudioDeviceID) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id = d; let s = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, s, &id)
}
func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

let devices = allDevices()
let edifierIn = getDefault(kAudioHardwarePropertyDefaultInputDevice)
let edifierOut = getDefault(kAudioHardwarePropertyDefaultOutputDevice)
print("[probe] current input=\(name(edifierIn)) id=\(edifierIn), output=\(name(edifierOut)) id=\(edifierOut)")

let altIn = devices.first { $0 != edifierIn && hasChannels($0, input: true) }
let altOut = devices.first { $0 != edifierOut && hasChannels($0, input: false) && name($0).contains("Mac mini") }
    ?? devices.first { $0 != edifierOut && hasChannels($0, input: false) }
print("[probe] alt input=\(altIn.map { "\(name($0)) id=\($0)" } ?? "none"), alt output=\(altOut.map { "\(name($0)) id=\($0)" } ?? "none")")

if let altIn {
    print("[probe] set input -> \(name(altIn)): \(setDefault(kAudioHardwarePropertyDefaultInputDevice, altIn))")
}
if let altOut {
    print("[probe] set output -> \(name(altOut)): \(setDefault(kAudioHardwarePropertyDefaultOutputDevice, altOut))")
}
wait(0.6)
print("[probe] set input back: \(setDefault(kAudioHardwarePropertyDefaultInputDevice, edifierIn))")
print("[probe] set output back: \(setDefault(kAudioHardwarePropertyDefaultOutputDevice, edifierOut))")
wait(0.6)
print("[probe] now input=\(name(getDefault(kAudioHardwarePropertyDefaultInputDevice))) output=\(name(getDefault(kAudioHardwarePropertyDefaultOutputDevice)))")

let engine = AVAudioEngine()
let input = engine.inputNode
let fmt = input.inputFormat(forBus: 0)
print("[probe] input format=\(fmt)")
var frames = 0; var peak: Float = 0
input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { b, _ in
    frames += 1
    if let ch = b.floatChannelData { for i in 0..<Int(b.frameLength) { peak = max(peak, abs(ch[0][i])) } }
}
do { try engine.start() } catch { print("[probe] start failed \(error)") }
wait(3)
print("[probe] RESULT callbacks=\(frames) peak=\(peak) running=\(engine.isRunning)")
input.removeTap(onBus: 0); engine.stop(); engine.reset()
