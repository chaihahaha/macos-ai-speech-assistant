import Foundation
import AppKit
import ApplicationServices
import MediaPlayer
import AVFoundation

/// Receives the hardware media keys (play/pause, next, previous) and forwards
/// them to the app as simple, *deduplicated* callbacks.
///
/// A single physical press can be delivered through up to four independent
/// channels: a `CGEvent` tap, the global `NSEvent` monitor, the local `NSEvent`
/// monitor and the `MPRemoteCommandCenter`. Without deduplication one press
/// fires the handler several times, which used to be papered over by a 500 ms
/// debounce in `ViewModel`. That debounce also swallowed legitimate rapid
/// presses, so duplicates are collapsed here (per action, 500 ms) and the
/// business logic responds to every real press immediately.
///
/// The CGEvent tap is the most reliable channel for Bluetooth headsets, which
/// often deliver only a subset of presses through the other channels. It needs
/// Accessibility permission; when it is unavailable we fall back gracefully.
@MainActor
final class MediaKeyController {
    enum Action: Hashable {
        case playPause
        case next
        case previous
    }

    private struct DecodedMediaKey {
        let code: Int
        let down: Bool
        let repeatFlag: Bool
    }

    /// See the type documentation. 500 ms matches the window the previous
    /// implementation used to hide duplicate deliveries.
    private static let dedupInterval: TimeInterval = 0.5

    /// `NX_KEYTYPE_*` codes carried by `NX_SYSDEFINED` events.
    private enum NXKey {
        static let play = 16
        static let next = 17
        static let previous = 18
    }

    /// Optional sink for diagnostics (the ViewModel writes these into the
    /// conversation log so headset-specific problems can be diagnosed later).
    var logHandler: ((String) -> Void)?

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
    private var eventTapSource: CFRunLoopSource?

    private var lastFireTime: [Action: Date] = [:]
    private var silentRestartCount = 0
    /// True while the recorder owns the input path.
    private var recordingActive = false
    /// True once the recorder has actually delivered its first buffer. Only then
    /// is it safe to start the output engine (input-first ordering).
    private var inputCaptureActive = false

    init() {
        setupRemoteCommands()
        setupEventMonitors()
        setupCGEventTap()
        log("[MediaKeys] initialized (Xcode accessibility trusted=\(AXIsProcessTrusted()))")
    }

    func setHandlers(playPause: @escaping () -> Void,
                     nextTrack: @escaping () -> Void,
                     previousTrack: @escaping () -> Void) {
        onPlayPause = playPause
        onNextTrack = nextTrack
        onPreviousTrack = previousTrack
    }

    private func log(_ message: String) {
        print(message)
        logHandler?(message)
    }

    /// Logged after the ViewModel installs `logHandler`, so it ends up in the
    /// conversation log. Tells us whether the app (not the terminal) is allowed
    /// to see system-defined media keys.
    func logDiagnostics() {
        log("[MediaKeys] diagnostics: accessibility=\(AXIsProcessTrusted()) " +
            "cgEventTap=\(eventTap != nil) globalMonitor=\(globalEventMonitor != nil) " +
            "localMonitor=\(localEventMonitor != nil)")
    }

    // MARK: - Dispatch

    /// Single funnel for every trigger. Deduplicates the same action fired twice
    /// within `dedupInterval` so one physical press results in one handler call.
    private func fire(_ action: Action, source: String) {
        let now = Date()
        if let last = lastFireTime[action], now.timeIntervalSince(last) < Self.dedupInterval {
            log("[MediaKeys] (\(source)) \(action) deduplicated (\(String(format: "%.3f", now.timeIntervalSince(last)))s)")
            return
        }
        lastFireTime[action] = now
        log("[MediaKeys] (\(source)) \(action) fired")

        switch action {
        case .playPause:
            onPlayPause?()
        case .next:
            onNextTrack?()
        case .previous:
            onPreviousTrack?()
        }
    }

    private func dispatchMediaKey(code: Int, source: String) {
        switch code {
        case NXKey.play:
            fire(.playPause, source: source)
        case NXKey.next:
            fire(.next, source: source)
        case NXKey.previous:
            fire(.previous, source: source)
        default:
            log("[MediaKeys] \(source): unknown keyCode=\(code), ignoring")
        }
    }

    // MARK: - Now Playing

    func becomeNowPlaying() {
        setNowPlayingInfo()
        startSilentPlayback()
        log("[MediaKeys] Now Playing activated, playbackState=.playing")
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
            log("[MediaKeys] Re-asserting Now Playing (was nil or not .playing)")
            setNowPlayingInfo()
        }
    }

    private func pingNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()

        // The keep-alive engine is what makes macOS treat us as the Now Playing
        // app — and for AVRCP headsets (e.g. EDIFIER X Fit) that is the *only*
        // way media keys reach us. The engine can die when the audio device is
        // reconfigured (Bluetooth A2DP <-> HFP when the mic opens), so restart
        // it when needed.
        if recordingActive && !inputCaptureActive {
            // Input not live yet: starting the output engine now would starve
            // the recorder's input tap (output-first ordering).
        } else if silentEngine?.isRunning != true {
            silentRestartCount += 1
            if silentRestartCount <= 3 || silentRestartCount % 60 == 0 {
                log("[MediaKeys] keep-alive engine not running (attempt \(silentRestartCount)); restarting")
            }
            silentPlayer?.stop()
            silentEngine?.stop()
            silentEngine = nil
            silentPlayer = nil
            startSilentPlayback()
        } else {
            silentRestartCount = 0
        }

        // Keep reporting playback so the system does not hand media keys to
        // another app.
        if center.playbackState != .playing {
            center.playbackState = .playing
        }

        guard var info = center.nowPlayingInfo else {
            log("[MediaKeys] nowPlayingInfo was nil, re-asserting!")
            setNowPlayingInfo()
            return
        }
        let t = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t + 0.5
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        center.nowPlayingInfo = info
    }

    func refreshNowPlaying() {
        MPNowPlayingInfoCenter.default().playbackState = .playing
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// Kept for API symmetry; the app intentionally stays `.playing` so macOS
    /// keeps routing the hardware media keys here.
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

    /// Call immediately before starting the recording engine: the output-only
    /// engine must not be running when the input engine starts.
    func pauseKeepAliveForRecording() {
        recordingActive = true
        inputCaptureActive = false
        stopSilentPlayback()
        log("[MediaKeys] keep-alive paused for recording")
    }

    /// Stop the recorder first, then bring the output-only A2DP keep-alive back.
    func resumeKeepAliveAfterRecording() {
        recordingActive = false
        inputCaptureActive = false
        // Restart unconditionally: the engine that ran during recording was bound
        // to the HFP (16 kHz) output; TTS needs the A2DP output back.
        stopSilentPlayback()
        startSilentPlayback()
        setPlaying()
        log("[MediaKeys] keep-alive resumed after recording")
    }

    func startSilentPlayback() {
        guard silentEngine == nil else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = engine.outputNode.inputFormat(forBus: 0)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        guard let silence = makeSilenceBuffer(format: format) else {
            log("[MediaKeys] Silent playback skipped: bad output format \(format)")
            return
        }

        do {
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.volume = 0.0
            player.play()
            silentEngine = engine
            silentPlayer = player
            log("[MediaKeys] Silent playback started (output-only engine)")
        } catch {
            log("[MediaKeys] Silent playback failed: \(error)")
        }
    }

    func stopSilentPlayback() {
        silentPlayer?.stop()
        silentEngine?.stop()
        silentEngine = nil
        silentPlayer = nil
        log("[MediaKeys] Silent playback stopped")
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

        center.stopCommand.addTarget { _ in .success }
        center.changePlaybackPositionCommand.addTarget { _ in .success }
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

        log("[MediaKeys] MPRemoteCommandCenter configured")
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

        log("[MediaKeys] Global + Local NSEvent monitors installed")
    }

    private func handleSystemEvent(_ event: NSEvent, source: String) {
        guard let key = Self.decodeMediaKey(event) else { return }
        guard key.down else { return }
        if key.repeatFlag {
            log("[MediaKeys] NSEvent(\(source)): keyCode=\(key.code) repeat ignored")
            return
        }
        log("[MediaKeys] NSEvent(\(source)): keyCode=\(key.code) DOWN")
        dispatchMediaKey(code: key.code, source: "NSEvent.\(source)")
    }

    /// Decodes an `NX_SYSDEFINED` event. The flags normally live in the low 16
    /// bits of `data1`, but some delivery paths surface them in `data2`; both
    /// layouts are accepted.
    private static func decodeMediaKey(_ event: NSEvent) -> DecodedMediaKey? {
        guard event.subtype.rawValue == 8 else { return nil }
        let data1 = UInt32(truncatingIfNeeded: event.data1)
        let code = Int((data1 & 0xFFFF_0000) >> 16)
        var flags = data1 & 0x0000_FFFF
        if flags == 0 {
            flags = UInt32(truncatingIfNeeded: event.data2)
        }
        let state = (flags & 0xFF00) >> 8
        let repeatFlag = (flags & 0x00FF) != 0
        return DecodedMediaKey(code: code, down: state == 0x0A, repeatFlag: repeatFlag)
    }

    // MARK: - CGEvent tap

    private func setupCGEventTap() {
        guard AXIsProcessTrusted() else {
            log("[MediaKeys] CGEvent tap unavailable: Accessibility permission not granted. " +
                "Grant it in System Settings ▸ Privacy & Security ▸ Accessibility for reliable Bluetooth media keys.")
            return
        }

        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<MediaKeyController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handleCGEventTap(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("[MediaKeys] CGEvent tap creation failed")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        log("[MediaKeys] CGEvent tap installed (NX_SYSDEFINED, pass-through)")
    }

    /// Runs on the main run loop; events are observed but **not** consumed so
    /// other apps keep receiving them.
    private func handleCGEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("[MediaKeys] CGEvent tap was disabled by the system; re-enabled")
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event),
              let key = Self.decodeMediaKey(nsEvent) else {
            return Unmanaged.passUnretained(event)
        }
        guard key.down, !key.repeatFlag else {
            return Unmanaged.passUnretained(event)
        }
        log("[MediaKeys] CGEventTap: keyCode=\(key.code) DOWN")
        dispatchMediaKey(code: key.code, source: "CGEventTap")
        return Unmanaged.passUnretained(event)
    }

    deinit {
        keepAliveTimer?.invalidate()
        silentPlayer?.stop()
        silentEngine?.stop()
        silentEngine = nil
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            eventTapSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
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
