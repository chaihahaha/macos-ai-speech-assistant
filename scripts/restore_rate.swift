import CoreAudio
import Foundation

func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var d = AudioDeviceID(0); var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d); return d
}
func rate(_ d: AudioDeviceID, input: Bool = false) -> Float64 {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var r: Float64 = 0; var s = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &s, &r); return r
}
func setRate(_ d: AudioDeviceID, _ r: Float64) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v = r; let s = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectSetPropertyData(d, &a, 0, nil, s, &v)
}
let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
print("before: out scope=\(rate(out)) global=\(rate(out, input: false))")
for attempt in 1...3 {
    let st = setRate(out, 44100)
    Thread.sleep(forTimeInterval: 0.5)
    print("attempt \(attempt): status=\(st) out=\(rate(out))")
    if rate(out) >= 44000 { break }
}
