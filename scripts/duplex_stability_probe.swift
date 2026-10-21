import AVFoundation
import CoreAudio
import Foundation
import Darwin

setbuf(stdout, nil)

func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var d = AudioDeviceID(0); var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d); return d
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
print("[duplex] output rate before=\(rate(out))")
let st = setRate(out, 16000)
print("[duplex] set 16000 status=\(st)")
wait(1.2)
print("[duplex] output rate after wait=\(rate(out))")

let engine = AVAudioEngine()
let input = engine.inputNode
let fmt = input.inputFormat(forBus: 0)
let outFmt = engine.outputNode.inputFormat(forBus: 0)
print("[duplex] inputFormat=\(fmt) outputNode=\(outFmt)")
var frames = 0; var peak: Float = 0
input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { b, _ in
    frames += 1
    if let ch = b.floatChannelData { for i in 0..<Int(b.frameLength) { peak = max(peak, abs(ch[0][i])) } }
}
let playerFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: playerFmt)
let silence = AVAudioPCMBuffer(pcmFormat: playerFmt, frameCapacity: 1024)!
player.scheduleBuffer(silence, at: nil, options: .loops)
player.volume = 0
do { try engine.start(); player.play(); print("[duplex] engine started") } catch { print("[duplex] start failed \(error)") }
wait(4)
print("[duplex] RESULT callbacks=\(frames) peak=\(peak) running=\(engine.isRunning)")
player.stop(); input.removeTap(onBus: 0); engine.stop(); engine.reset()
_ = setRate(out, 44100)
wait(1.0)
print("[duplex] restored rate=\(rate(out))")
