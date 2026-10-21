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
print("[pin] all devices:")
for d in devices { print("[pin]   \(name(d)) id=\(d) in=\(hasChannels(d, input: true)) out=\(hasChannels(d, input: false))") }
guard let edIn = devices.first(where: { name($0).uppercased().contains("EDIFIER") && hasChannels($0, input: true) }),
      let edOut = devices.first(where: { name($0).uppercased().contains("EDIFIER") && hasChannels($0, input: false) }) else {
    print("[pin] EDIFIER input/output not found"); exit(1)
}
print("[pin] edifier input id=\(edIn), output id=\(edOut)")
print("[pin] set default input: \(setDefault(kAudioHardwarePropertyDefaultInputDevice, edIn))")
print("[pin] set default output: \(setDefault(kAudioHardwarePropertyDefaultOutputDevice, edOut))")
wait(0.8)
print("[pin] now input=\(name(getDefault(kAudioHardwarePropertyDefaultInputDevice))) output=\(name(getDefault(kAudioHardwarePropertyDefaultOutputDevice)))")

let engine = AVAudioEngine()
let input = engine.inputNode
let fmt = input.inputFormat(forBus: 0)
print("[pin] input format=\(fmt)")
var frames = 0; var peak: Float = 0
input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { b, _ in
    frames += 1
    if let ch = b.floatChannelData { for i in 0..<Int(b.frameLength) { peak = max(peak, abs(ch[0][i])) } }
}
do { try engine.start() } catch { print("[pin] start failed \(error)") }
wait(3)
print("[pin] RESULT callbacks=\(frames) peak=\(peak) running=\(engine.isRunning)")
input.removeTap(onBus: 0); engine.stop(); engine.reset()
