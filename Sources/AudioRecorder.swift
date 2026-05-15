import AVFoundation
import Foundation
import SpeechVAD

@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0
    
    /// Called when speech ends (silence after speech detected by VAD)
    var onSpeechEnded: (() -> Void)?
    
    private var audioEngine: AVAudioEngine?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let targetSampleRate: Double
    
    // VAD
    private let vadProcessor: StreamingVADProcessor
    private var speechActive = false
    
    init(targetSampleRate: Double = 16000, vadProcessor: StreamingVADProcessor) {
        self.targetSampleRate = targetSampleRate
        self.vadProcessor = vadProcessor
    }
    
    func startRecording() {
        print("[AudioRecorder] startRecording called")
        lock.lock()
        samples.removeAll()
        lock.unlock()
        
        speechActive = false
        vadProcessor.reset()
        print("[AudioRecorder] VAD reset")
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return }
        
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else { return }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.targetSampleRate / hwFormat.sampleRate
            )
            guard frameCount > 0,
                  let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
            else { return }
            
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if error != nil { return }
            
            if let channelData = converted.floatChannelData?[0] {
                let count = Int(converted.frameLength)
                let ptr = UnsafeBufferPointer(start: channelData, count: count)
                let audioChunk = Array(ptr)
                
                var sum: Float = 0
                for s in audioChunk { sum += s * s }
                let rms = sqrt(sum / max(Float(count), 1))
                
                self.lock.lock()
                self.samples.append(contentsOf: audioChunk)
                self.lock.unlock()
                
                DispatchQueue.main.async {
                    self.audioLevel = rms
                }
                
                // VAD processing
                let events = self.vadProcessor.process(samples: audioChunk)
                for event in events {
                    switch event {
                    case .speechStarted(let time):
                        print("[VAD] Speech started at \(String(format: "%.2f", time))s")
                        self.speechActive = true
                    case .speechEnded(let segment):
                        print("[VAD] Speech ended at \(String(format: "%.2f", segment.endTime))s (duration: \(String(format: "%.2f", segment.duration))s)")
                        self.speechActive = false
                        DispatchQueue.main.async {
                            self.onSpeechEnded?()
                        }
                    }
                }
            }
        }
        
        do {
            try engine.start()
            audioEngine = engine
            isRecording = true
        } catch {
            inputNode.removeTap(onBus: 0)
        }
    }
    
    func stopRecording() -> [Float] {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        audioLevel = 0
        
        lock.lock()
        let result = samples
        samples.removeAll()
        lock.unlock()
        return result
    }
}