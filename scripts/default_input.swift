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
func sampleRate(_ d: AudioDeviceID, input: Bool) -> Double {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var r: Float64 = 0; var s = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &s, &r)
    return r
}
let inDev = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
let outDev = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
print("default input : \(name(inDev)) id=\(inDev) sr=\(sampleRate(inDev, input: true))")
print("default output: \(name(outDev)) id=\(outDev) sr=\(sampleRate(outDev, input: false))")
