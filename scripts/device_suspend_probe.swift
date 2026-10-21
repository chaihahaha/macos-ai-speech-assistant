import AVFoundation
import CoreAudio
import Foundation

func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var d = AudioDeviceID(0); var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d); return d
}
func setSuspended(_ d: AudioDeviceID, _ value: UInt32) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertySuspendedByUser, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v = value; let s = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectSetPropertyData(d, &a, 0, nil, s, &v)
}
func getSuspended(_ d: AudioDeviceID) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertySuspendedByUser, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0; var s = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &s, &v); return v
}
func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
print("[probe] output device \(out), suspended=\(getSuspended(out))")
let s1 = setSuspended(out, 1)
print("[probe] set suspended=1 -> \(s1), now \(getSuspended(out))")
wait(0.8)
let s2 = setSuspended(out, 0)
print("[probe] set suspended=0 -> \(s2), now \(getSuspended(out))")
wait(0.8)

let engine = AVAudioEngine()
let input = engine.inputNode
let fmt = input.inputFormat(forBus: 0)
print("[probe] input format=\(fmt)")
var frames = 0; var peak: Float = 0
input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { b, _ in
    frames += 1
    if let ch = b.floatChannelData { for i in 0..<Int(b.frameLength) { peak = max(peak, abs(ch[0][i])) } }
}
do { try engine.start(); print("[probe] engine started") } catch { print("[probe] start failed \(error)") }
wait(3)
print("[probe] RESULT callbacks=\(frames) peak=\(peak) running=\(engine.isRunning)")
input.removeTap(onBus: 0); engine.stop(); engine.reset()
