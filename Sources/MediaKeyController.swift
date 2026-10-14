import Foundation
import AppKit
import MediaPlayer
import AVFoundation

/// Receives the hardware media keys (play/pause, next, previous) and forwards
/// them to the app as simple, *deduplicated* callbacks.
///
/// Why the deduplication exists: a single physical media-key press can be
/// delivered to us through up to three independent channels — the global
/// `NSEvent` monitor, the local `NSEvent` monitor and the `MPRemoteCommandCenter`
/// (via `playCommand` / `pauseCommand` / `togglePlayPauseCommand`). Without
/// deduplication one press fires the handler two or three times, which used to
/// be papered over by a 500 ms debounce in `ViewModel`. That debounce also
/// swallowed legitimate rapid presses, so the fix is to deduplicate the
/// *duplicate deliveries of one press* here (a short window) and let the
/// business logic respond to every real press immediately.
@MainActor
final class MediaKeyController {
    enum Action: Hashable {
        case playPause
        case next
        case previous
    }

    /// Window within which repeat deliveries of the same action are treated as
    /// one physical key press. The original code used 500 ms for this in
    /// `ViewModel` because one press can be delivered through several channels;
    /// we keep the same empirically-safe width but collapse the duplicates at
    /// the source, so the business logic no longer has to debounce (and no
    /// longer swallows legitimate presses for *every* state).
    private static let dedupInterval: TimeInterval = 0.5

    private var onPlayPause: (() -> Void)?
    private var onNextTrack: (() -> Void)?
    private var onPreviousTrack: (() -> Void)?

    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var spaceKeyMonitor: Any?
    private var keepAliveTimer: Timer?
    private var silentEngine: AVAudioEngine?
    private var silentPlayer: AVAudioPlayerNode?
    private var eventTap: CFMachPort?

    private var lastFireTime: [Action: Date] = [:]

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

    // MARK: - Dispatch

    /// Single funnel for every trigger (NSEvent, MPRemote, Space). Deduplicates
    /// the same action fired twice within `dedupInterval` so one physical press
    /// results in exactly one handler call.
    private func fire(_ action: Action, source: String) {
        let now = Date()
        if let last = lastFireTime[action], now.timeIntervalSince(last) < Self.dedupInterval {
            print("[MediaKeys] (\(source)) \(action) deduplicated (\(String(format: "%.3f", now.timeIntervalSince(last)))s)")
            return
        }
        lastFireTime[action] = now
        print("[MediaKeys] (\(source)) \(action) fired")

        switch action {
        case .playPause:
            onPlayPause?()
        case .next:
            onNextTrack?()
        case .previous:
            onPreviousTrack?()
        }
    }

    // MARK: - Now Playing

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
        guard var info = center.nowPlayingInfo else {
            print("[MediaKeys] nowPlayingInfo was nil, re-asserting!")
            setNowPlayingInfo()
            return
        }
        let playing = center.playbackState == .playing
        if playing {
            let t = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t + 0.5
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        center.nowPlayingInfo = info
    }

    func refreshNowPlaying() {
        MPNowPlayingInfoCenter.default().playbackState = .playing
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    func setPaused() {
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .paused
        if var info = center.nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
            center.nowPlayingInfo = info
        }
    }

    func setPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .playing
        if var info = center.nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            center.nowPlayingInfo = info
        }
    }

    // MARK: - Silent playback (keeps the app registered as "Now Playing")

    func startSilentPlayback() {
        guard silentEngine == nil else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = engine.outputNode.inputFormat(forBus: 0)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        guard let silence = makeSilenceBuffer(format: format) else {
            print("[MediaKeys] Silent playback skipped: bad output format")
            return
        }

        do {
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.volume = 0.0
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
        if let silence = makeSilenceBuffer(format: format) {
            do {
                try engine.start()
                player.scheduleBuffer(silence, at: nil, options: .loops)
                player.volume = 0.0
                player.play()
                silentEngine = engine
                silentPlayer = player
                print("[MediaKeys] Silent playback started (lazy)")
            } catch {
                print("[MediaKeys] Silent playback failed: \(error)")
            }
        }
        return engine
    }

    private func makeSilenceBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
              let channelData = silence.floatChannelData else {
            return nil
        }
        silence.frameLength = 1024
        let byteCount = Int(1024 * format.streamDescription.pointee.mBytesPerFrame)
        for channel in 0..<Int(format.channelCount) {
            memset(channelData[channel], 0, byteCount)
        }
        return silence
    }

    func resignNowPlaying() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Remote command center

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        let playPause: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            self?.dispatchOnMainActor { $0.fire(.playPause, source: "MPRemote") }
            return .success
        }
        center.playCommand.addTarget(handler: playPause)
        center.pauseCommand.addTarget(handler: playPause)
        center.togglePlayPauseCommand.addTarget(handler: playPause)

        let next: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            self?.dispatchOnMainActor { $0.fire(.next, source: "MPRemote") }
            return .success
        }
        center.nextTrackCommand.addTarget(handler: next)
        center.seekForwardCommand.addTarget(handler: next)
        center.skipForwardCommand.addTarget(handler: next)

        let previous: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            self?.dispatchOnMainActor { $0.fire(.previous, source: "MPRemote") }
            return .success
        }
        center.previousTrackCommand.addTarget(handler: previous)
        center.seekBackwardCommand.addTarget(handler: previous)
        center.skipBackwardCommand.addTarget(handler: previous)

        center.stopCommand.addTarget { _ in
            print("[MediaKeys] MPRemote: stopCommand")
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { _ in
            return .success
        }
        center.likeCommand.addTarget { _ in .success }
        center.dislikeCommand.addTarget { _ in .success }
        center.bookmarkCommand.addTarget { _ in .success }

        // Only advertise the commands we actually handle, otherwise macOS may
        // grey out / reroute media keys.
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.stopCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.seekForwardCommand.isEnabled = true
        center.seekBackwardCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = false
        center.likeCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
        center.bookmarkCommand.isEnabled = false

        print("[MediaKeys] MPRemoteCommandCenter configured")
    }

    private func dispatchOnMainActor(_ block: @escaping (MediaKeyController) -> Void) {
        if Thread.isMainThread {
            block(self)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            block(self)
        }
    }

    // MARK: - NSEvent monitors

    private func setupEventMonitors() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleSystemEvent(event, source: "Global")
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleSystemEvent(event, source: "Local")
            return event
        }

        // Space bar acts as play/pause, but must never be hijacked while the
        // user is typing into one of the app's text fields.
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49 else { return event }
            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }
            self?.fire(.playPause, source: "Space")
            return nil
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

        // Ignore key-up and auto-repeat; only the initial key-down matters.
        guard keyState == 0x0A, !keyRepeat else {
            if keyState == 0x0A && keyRepeat {
                print("[MediaKeys] NSEvent(\(source)): keyCode=\(keyCode) repeat ignored")
            }
            return
        }

        print("[MediaKeys] NSEvent(\(source)): keyCode=\(keyCode) (0x\(String(keyCode, radix: 16))) state=\(stateLabel)")

        let NX_KEYTYPE_PLAY: Int = 16
        let NX_KEYTYPE_NEXT: Int = 17
        let NX_KEYTYPE_PREVIOUS: Int = 18

        switch keyCode {
        case NX_KEYTYPE_PLAY:
            fire(.playPause, source: "NSEvent.\(source)")
        case NX_KEYTYPE_NEXT:
            fire(.next, source: "NSEvent.\(source)")
        case NX_KEYTYPE_PREVIOUS:
            fire(.previous, source: "NSEvent.\(source)")
        default:
            print("[MediaKeys] unknown keyCode=\(keyCode), ignoring")
        }
    }

    private func setupCGEventTap() {
        // CGEvent tap intentionally disabled: it requires Accessibility
        // permission and can freeze the whole session if the tap callback is
        // slow. NSEvent monitors + MPRemoteCommandCenter are sufficient.
        print("[MediaKeys] CGEvent tap skipped (using NSEvent monitors + MPRemote)")
    }

    deinit {
        keepAliveTimer?.invalidate()
        silentPlayer?.stop()
        silentEngine?.stop()
        silentEngine = nil
        if let tap = eventTap { CFMachPortInvalidate(tap) }
        if let m = globalEventMonitor { NSEvent.removeMonitor(m) }
        if let m = localEventMonitor { NSEvent.removeMonitor(m) }
        if let m = spaceKeyMonitor { NSEvent.removeMonitor(m) }
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
