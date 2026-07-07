import Foundation
import AppKit
import MediaPlayer

@MainActor
final class MediaKeyController {
    private var onPlayPause: (() -> Void)?
    private var onNextTrack: (() -> Void)?
    private var onPreviousTrack: (() -> Void)?
    private var eventMonitor: Any?

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

        print("[MediaKeys] Setting Now Playing info")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Must set playbackState AFTER nowPlayingInfo
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MPNowPlayingInfoCenter.default().playbackState = .playing
            print("[MediaKeys] Now Playing activated, playbackState=.playing")
        }
    }

    func resignNowPlaying() {
        print("[MediaKeys] Resigning Now Playing")
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                print("[MediaKeys] MPRemote: play")
                self?.onPlayPause?()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                print("[MediaKeys] MPRemote: pause")
                self?.onPlayPause?()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                print("[MediaKeys] MPRemote: togglePlayPause")
                self?.onPlayPause?()
            }
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                print("[MediaKeys] MPRemote: nextTrack")
                self?.onNextTrack?()
            }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                print("[MediaKeys] MPRemote: previousTrack")
                self?.onPreviousTrack?()
            }
            return .success
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        print("[MediaKeys] MPRemoteCommandCenter configured")
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

        Task { @MainActor [weak self] in
            switch keyCode {
            case NX_KEYTYPE_PLAY:
                print("[MediaKeys] NSEvent: play/pause")
                self?.onPlayPause?()
            case NX_KEYTYPE_NEXT:
                print("[MediaKeys] NSEvent: nextTrack")
                self?.onNextTrack?()
            case NX_KEYTYPE_PREVIOUS:
                print("[MediaKeys] NSEvent: previousTrack")
                self?.onPreviousTrack?()
            default:
                break
            }
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            print("[MediaKeys] Event monitor removed")
        }

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
    }
}
