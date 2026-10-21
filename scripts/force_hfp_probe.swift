import AVFoundation
import CoreAudio
import Foundation

func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var d = AudioDeviceID(0); var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d)
    return d
}
func name(_ d: AudioDeviceID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var n: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &n) { AudioObjectGetPropertyData(d, &a, 0, nil, &s, $0) }
    return st == noErr ? (n?.takeUnretainedValue() as String? ?? "?") : "?"
}
func nominalRate(_ d: AudioDeviceID) -> Float64 {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var r: Float64 = 0; var s = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &s, &r); return r
}
func setNominalRate(_ d: AudioDeviceID, _ rate: Float64) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var r = rate; let s = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectSetPropertyData(d, &a, 0, nil, s, &r)
}
func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
let inD = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
print("[probe] output=\(name(out)) id=\(out) rate=\(nominalRate(out))")
print("[probe] input =\(name(inD)) id=\(inD) rate=\(nominalRate(inD))")

let status = setNominalRate(out, 16000)
print("[probe] set output rate 16000 -> OSStatus \(status); now \(nominalRate(out))")
wait(0.8)

let engine = AVAudioEngine()
let input = engine.inputNode
let fmt = input.inputFormat(forBus: 0)
print("[probe] input format after rate change=\(fmt)")
var frames = 0; var peak: Float = 0
input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
    frames += 1
    if let ch = buffer.floatChannelData { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[0][i])) } }
}
do { try engine.start(); print("[probe] engine started") } catch { print("[probe] start failed \(error)") }
wait(3)
print("[probe] RESULT callbacks=\(frames) peak=\(peak) running=\(engine.isRunning)")
input.removeTap(onBus: 0); engine.stop(); engine.reset()

let restore = setNominalRate(out, 44100)
print("[probe] restore output rate 44100 -> OSStatus \(restore); now \(nominalRate(out))")
