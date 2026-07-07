import Foundation
import AppKit
import MediaPlayer

@MainActor
final class MediaKeyController {
    private var onPlayPause: (() -> Void)?
    private var onNextTrack: (() -> Void)?
    private var onPreviousTrack: (() -> Void)?

    init() {
        setupRemoteCommands()
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
            MPMediaItemPropertyTitle: "My Llama Speech Assistant",
            MPMediaItemPropertyArtist: "AI Conversation"
        ]
        if let img = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: nil) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: img.size
            ) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    func resignNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlayPause?() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlayPause?() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlayPause?() }
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onNextTrack?() }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPreviousTrack?() }
            return .success
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
    }

    deinit {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
    }
}
