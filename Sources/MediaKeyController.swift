import Foundation
import AppKit
import MediaPlayer
import AVFoundation

@MainActor
final class MediaKeyController {
    private var onPlayPause: (() -> Void)?
    private var onNextTrack: (() -> Void)?
    private var onPreviousTrack: (() -> Void)?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var keepAliveTimer: Timer?
    private var silentEngine: AVAudioEngine?
    private var silentPlayer: AVAudioPlayerNode?
    private var eventTap: CFMachPort?

    init() {
        setupRemoteCommands()
        setupEventMonitors()
        setupCGEventTap()
    }

    func setHandlers(playPause: @escaping () -> Void,
                     nextTrack: @escaping () -> Void,
                     previousTrack: @escaping () -> Void) {
        onPlayPause = playPause
        onNextTrack = nextTrack
        onPreviousTrack = previousTrack
    }

    func becomeNowPlaying() {
        setNowPlayingInfo()
        startSilentPlayback()
        print("[MediaKeys] Now Playing activated, playbackState=.playing")
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pingNowPlaying() }
        }
    }

    private func setNowPlayingInfo() {
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyTitle: "Speech Assistant",
            MPMediaItemPropertyArtist: "AI Conversation",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackProgress: 0.0,
        ]

        if let img = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: nil) {
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 200, height: 200)) { _ in img }
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    func assertNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        if center.nowPlayingInfo == nil || center.playbackState != .playing {
            print("[MediaKeys] Re-asserting Now Playing (was nil or not .playing)")
            setNowPlayingInfo()
        }
    }

    private func pingNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        if var info = center.nowPlayingInfo {
            let t = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t + 0.5
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            center.nowPlayingInfo = info
        } else {
            print("[MediaKeys] nowPlayingInfo was nil, re-asserting!")
            setNowPlayingInfo()
        }
    }

    func refreshNowPlaying() {
        MPNowPlayingInfoCenter.default().playbackState = .playing
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    func setPaused() { MPNowPlayingInfoCenter.default().playbackState = .paused }
    func setPlaying() { MPNowPlayingInfoCenter.default().playbackState = .playing }

    func startSilentPlayback() {
        guard silentEngine == nil else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = engine.outputNode.inputFormat(forBus: 0)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        silence.frameLength = 1024
        memset(silence.floatChannelData?[0], 0, Int(1024 * format.streamDescription.pointee.mBytesPerFrame))

        do {
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.volume = 0.01
            player.play()
            silentEngine = engine
            silentPlayer = player
            print("[MediaKeys] Silent playback started")
        } catch {
            print("[MediaKeys] Silent playback failed: \(error)")
        }
    }

    func stopSilentPlayback() {
        silentPlayer?.stop()
        silentEngine?.stop()
        silentEngine = nil
        silentPlayer = nil
        print("[MediaKeys] Silent playback stopped")
    }

    func sharedAudioEngine() -> AVAudioEngine {
        if let engine = silentEngine { return engine }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = engine.outputNode.inputFormat(forBus: 0)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        silence.frameLength = 1024
        memset(silence.floatChannelData?[0], 0, Int(1024 * format.streamDescription.pointee.mBytesPerFrame))
        do {
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.volume = 0.01
            player.play()
            silentEngine = engine
            silentPlayer = player
            print("[MediaKeys] Silent playback started (lazy)")
        } catch {
            print("[MediaKeys] Silent playback failed: \(error)")
        }
        return engine
    }

    func resignNowPlaying() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            print("[MediaKeys] MPRemote: playCommand")
            self?.dispatchOnMainActor { $0.onPlayPause?() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            print("[MediaKeys] MPRemote: pauseCommand")
            self?.dispatchOnMainActor { $0.onPlayPause?() }
            return .success
        }
        center.stopCommand.addTarget { _ in
            print("[MediaKeys] MPRemote: stopCommand")
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            print("[MediaKeys] MPRemote: togglePlayPauseCommand")
            self?.dispatchOnMainActor { $0.onPlayPause?() }
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            print("[MediaKeys] MPRemote: nextTrackCommand")
            self?.dispatchOnMainActor { $0.onNextTrack?() }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            print("[MediaKeys] MPRemote: previousTrackCommand")
            self?.dispatchOnMainActor { $0.onPreviousTrack?() }
            return .success
        }

        center.seekForwardCommand.addTarget { [weak self] _ in
            print("[MediaKeys] MPRemote: seekForwardCommand")
            self?.dispatchOnMainActor { $0.onNextTrack?() }
            return .success
        }

        center.seekBackwardCommand.addTarget { [weak self] _ in
            print("[MediaKeys] MPRemote: seekBackwardCommand")
            self?.dispatchOnMainActor { $0.onPreviousTrack?() }
            return .success
        }

        center.skipForwardCommand.addTarget { [weak self] _ in
            print("[MediaKeys] MPRemote: skipForwardCommand")
            self?.dispatchOnMainActor { $0.onNextTrack?() }
            return .success
        }

        center.skipBackwardCommand.addTarget { [weak self] _ in
            print("[MediaKeys] MPRemote: skipBackwardCommand")
            self?.dispatchOnMainActor { $0.onPreviousTrack?() }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { _ in
            print("[MediaKeys] MPRemote: changePlaybackPosition")
            return .success
        }

        center.likeCommand.addTarget { _ in
            print("[MediaKeys] MPRemote: likeCommand")
            return .success
        }
        center.dislikeCommand.addTarget { _ in
            print("[MediaKeys] MPRemote: dislikeCommand")
            return .success
        }
        center.bookmarkCommand.addTarget { _ in
            print("[MediaKeys] MPRemote: bookmarkCommand")
            return .success
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.seekForwardCommand.isEnabled = true
        center.seekBackwardCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        print("[MediaKeys] MPRemoteCommandCenter configured (all commands)")
    }

    private func dispatchOnMainActor(_ block: @escaping (MediaKeyController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            block(self)
        }
    }

    private func setupEventMonitors() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleSystemEvent(event, source: "Global")
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleSystemEvent(event, source: "Local")
            return event
        }
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 {
                print("[MediaKeys] NSEvent: Space key")
                DispatchQueue.main.async { self?.onPlayPause?() }
                return nil
            }
            return event
        }
        print("[MediaKeys] Global + Local event monitors installed")
    }

    private func handleSystemEvent(_ event: NSEvent, source: String) {
        guard event.subtype.rawValue == 8 else { return }

        let keyCode = (event.data1 & 0xFFFF_0000) >> 16
        let keyState = (event.data2 & 0xFF00) >> 8
        let keyRepeat = (event.data2 & 0x00FF) != 0

        let stateLabel: String = {
            switch keyState {
            case 0x0A: return "DOWN"
            case 0x0B: return "UP"
            default: return String(format: "0x%02X", keyState)
            }
        }()

        print("[MediaKeys] NSEvent(\(source)): keyCode=\(keyCode) (0x\(String(keyCode, radix: 16))) state=\(stateLabel) repeat=\(keyRepeat)")

        guard keyState == 0x0A, !keyRepeat else { return }

        let NX_KEYTYPE_PLAY: Int = 16
        let NX_KEYTYPE_NEXT: Int = 17
        let NX_KEYTYPE_PREVIOUS: Int = 18

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch keyCode {
            case NX_KEYTYPE_PLAY:
                print("[MediaKeys] => NSEvent: PLAY triggered")
                self.onPlayPause?()
            case NX_KEYTYPE_NEXT:
                print("[MediaKeys] => NSEvent: NEXT triggered")
                self.onNextTrack?()
            case NX_KEYTYPE_PREVIOUS:
                print("[MediaKeys] => NSEvent: PREVIOUS triggered")
                self.onPreviousTrack?()
            default:
                print("[MediaKeys] => NSEvent: unknown keyCode=\(keyCode), ignoring")
            }
        }
    }

    private func setupCGEventTap() {
        // CGEvent tap disabled in favor of NSEvent monitors + MPRemote
        print("[MediaKeys] CGEvent tap skipped (using NSEvent monitors)")
    }

    deinit {
        keepAliveTimer?.invalidate()
        silentPlayer?.stop()
        silentEngine?.stop()
        silentEngine = nil
        if let tap = eventTap { CFMachPortInvalidate(tap) }
        if let m = globalEventMonitor { NSEvent.removeMonitor(m) }
        if let m = localEventMonitor { NSEvent.removeMonitor(m) }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.seekForwardCommand.removeTarget(nil)
        center.seekBackwardCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
    }
}
