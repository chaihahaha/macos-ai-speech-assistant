import AVFoundation
import CoreAudio
import Foundation

func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var d = AudioDeviceID(0); var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d); return d
}
func name(_ d: AudioDeviceID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var n: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &n) { AudioObjectGetPropertyData(d, &a, 0, nil, &s, $0) }
    return st == noErr ? (n?.takeUnretainedValue() as String? ?? "?") : "?"
}
func rate(_ d: AudioDeviceID) -> Float64 {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var r: Float64 = 0; var s = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &s, &r); return r
}
func setRate(_ d: AudioDeviceID, _ v: Float64) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var r = v; let s = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectSetPropertyData(d, &a, 0, nil, s, &r)
}
func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
print("[rate] output=\(name(out)) id=\(out) rate=\(rate(out))")
let engine0 = AVAudioEngine()
print("[rate] BEFORE outputNode=\(engine0.outputNode.inputFormat(forBus: 0))")
let st = setRate(out, 16000)
print("[rate] set 16000 status=\(st); device rate now=\(rate(out))")
wait(1.0)
print("[rate] after 1s device rate=\(rate(out))")
let engine = AVAudioEngine()
print("[rate] AFTER outputNode=\(engine.outputNode.inputFormat(forBus: 0)) inputNode=\(engine.inputNode.inputFormat(forBus: 0))")
_ = setRate(out, 44100)
wait(0.5)
print("[rate] restored device rate=\(rate(out))")
