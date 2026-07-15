import Foundation
import AppKit
import MediaPlayer

@MainActor
final class MediaKeyController {
    private var onPlayPause: (() -> Void)?
    private var onNextTrack: (() -> Void)?
    private var onPreviousTrack: (() -> Void)?
    private var eventMonitor: Any?
    private var keepAliveTimer: Timer?

    init() {
        setupRemoteCommands()
        setupGlobalMonitor()
    }

    func setHandlers(playPause: @escaping () -> Void,
                     nextTrack: @escaping () -> Void,
                     previousTrack: @escaping () -> Void) {
        onPlayPause = playPause
        onNextTrack = nextTrack
        onPreviousTrack = previousTrack
    }

    func becomeNowPlaying() {
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
        print("[MediaKeys] Now Playing activated, playbackState=.playing")

        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pingNowPlaying() }
        }
    }

    private func pingNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        if var info = center.nowPlayingInfo {
            let t = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t + 2.0
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            center.nowPlayingInfo = info
        }
    }

    func refreshNowPlaying() {
        MPNowPlayingInfoCenter.default().playbackState = .playing
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    func setPaused() {
        MPNowPlayingInfoCenter.default().playbackState = .paused
    }

    func setPlaying() {
        MPNowPlayingInfoCenter.default().playbackState = .playing
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
            self?.dispatchOnMainActor { $0.onPlayPause?() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.dispatchOnMainActor { $0.onPlayPause?() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.dispatchOnMainActor { $0.onPlayPause?() }
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            print("[MediaKeys] MPRemote: nextTrack")
            self?.dispatchOnMainActor { $0.onNextTrack?() }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.dispatchOnMainActor { $0.onPreviousTrack?() }
            return .success
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        print("[MediaKeys] MPRemoteCommandCenter configured")
    }

    private func dispatchOnMainActor(_ block: @escaping (MediaKeyController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            block(self)
        }
    }

    // MARK: - Fallback: Global Event Monitor for media keys

    private func setupGlobalMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleSystemDefinedEvent(event)
        }
        print("[MediaKeys] Global event monitor installed")
    }

    private func handleSystemDefinedEvent(_ event: NSEvent) {
        guard event.subtype.rawValue == 8 else { return }

        let keyCode = (event.data1 & 0xFFFF_0000) >> 16
        let keyState = (event.data2 & 0xFF00) >> 8

        // Only process key-down events (not repeats)
        guard keyState == 0xA else { return }

        // NX_KEYTYPE values
        let NX_KEYTYPE_PLAY: Int = 16
        let NX_KEYTYPE_NEXT: Int = 17
        let NX_KEYTYPE_PREVIOUS: Int = 18

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch keyCode {
            case NX_KEYTYPE_PLAY:
                print("[MediaKeys] NSEvent: play/pause")
                self.onPlayPause?()
            case NX_KEYTYPE_NEXT:
                print("[MediaKeys] NSEvent: nextTrack")
                self.onNextTrack?()
            case NX_KEYTYPE_PREVIOUS:
                print("[MediaKeys] NSEvent: previousTrack")
                self.onPreviousTrack?()
            default:
                break
            }
        }
    }

    deinit {
        keepAliveTimer?.invalidate()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
    }
}
