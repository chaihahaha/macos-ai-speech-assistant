import Foundation
import AppKit
import AVFoundation
import MediaPlayer
import CoreGraphics
import ApplicationServices
import IOKit
import IOKit.hid
import CoreAudio

// ============================================================================
// HeadsetMonitor
//
// Watches *every* channel through which a Bluetooth headset button press can
// reach macOS, and prints a timestamped line for each signal:
//
//   1. IOHID        – raw HID input values/reports (the closest to "hardware")
//   2. CGEventTap   – NX_SYSDEFINED media keys + keyDown/keyUp/flagsChanged
//   3. NSEvent      – global + local monitors for the same event types
//   4. MPRemote     – every MPRemoteCommandCenter command
//   5. CoreAudio    – default input/output device changes (A2DP <-> HFP)
//
// Usage:
//   ./binaries/HeadsetMonitor            # run until Ctrl-C
//   ./binaries/HeadsetMonitor --check    # setup + device list, exit after 2 s
//
// Quit MyLlamaSpeechAssistant first: while it runs it owns "Now Playing" and
// may swallow media keys (and share the microphone / Bluetooth profile).
// ============================================================================

// MARK: - Logging

private let logLock = NSLock()
private let startedAt = Date()
private let wallClock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
private var channelCounts: [String: Int] = [:]
private var logFileHandle: FileHandle?

func log(_ channel: String, _ message: String) {
    logLock.lock()
    channelCounts[channel, default: 0] += 1
    let elapsed = String(format: "%8.3f", Date().timeIntervalSince(startedAt))
    let line = "[\(wallClock.string(from: Date())) +\(elapsed)s] [\(channel)] \(message)"
    print(line)
    fflush(stdout)
    if let handle = logFileHandle, let data = (line + "\n").data(using: .utf8) {
        try? handle.write(contentsOf: data)
    }
    logLock.unlock()
}

func openLogFile() {
    let cwd = FileManager.default.currentDirectoryPath
    let dir = URL(fileURLWithPath: cwd).appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    let url = dir.appendingPathComponent("headset_monitor_\(stamp).log")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    logFileHandle = try? FileHandle(forWritingTo: url)
    print("Logging to \(url.path)")
}

func hex(_ value: UInt32, width: Int = 4) -> String {
    String(format: "0x%0\(width)X", value)
}

// MARK: - HID helpers

func hidProperty(_ device: IOHIDDevice, _ key: String) -> Any? {
    IOHIDDeviceGetProperty(device, key as CFString)
}

func hidDeviceDescription(_ device: IOHIDDevice) -> String {
    let product = (hidProperty(device, kIOHIDProductKey) as? String) ?? "?"
    let manufacturer = (hidProperty(device, kIOHIDManufacturerKey) as? String) ?? "?"
    let transport = (hidProperty(device, kIOHIDTransportKey) as? String) ?? "?"
    let vendor = (hidProperty(device, kIOHIDVendorIDKey) as? NSNumber)?.intValue
    let productID = (hidProperty(device, kIOHIDProductIDKey) as? NSNumber)?.intValue
    let primaryPage = (hidProperty(device, kIOHIDPrimaryUsagePageKey) as? NSNumber)?.intValue
    let primaryUsage = (hidProperty(device, kIOHIDPrimaryUsageKey) as? NSNumber)?.intValue
    let vid = vendor.map { String(format: "0x%04X", $0) } ?? "?"
    let pid = productID.map { String(format: "0x%04X", $0) } ?? "?"
    let page = primaryPage.map { String($0, radix: 16) } ?? "?"
    let usage = primaryUsage.map { String($0, radix: 16) } ?? "?"
    return "\(manufacturer) / \(product) [transport=\(transport) vid=\(vid) pid=\(pid) primary=\(page)/\(usage)]"
}

func hidDeviceMatchesHeadset(_ device: IOHIDDevice) -> Bool {
    let product = ((hidProperty(device, kIOHIDProductKey) as? String) ?? "").lowercased()
    let manufacturer = ((hidProperty(device, kIOHIDManufacturerKey) as? String) ?? "").lowercased()
    let transport = ((hidProperty(device, kIOHIDTransportKey) as? String) ?? "").lowercased()
    let haystack = product + " " + manufacturer
    if haystack.contains("edifier") || haystack.contains("x fit") { return true }
    // macOS exposes Bluetooth headset controls as a generic HID device named
    // "Headset" with transport "Audio" (seen on this machine as
    // "Apple / Headset [transport=Audio primary=0x0C/0x01]").
    if transport == "audio" && product.contains("headset") { return true }
    return false
}

func hidUsageName(page: UInt32, usage: UInt32) -> String {
    if page == 0x0C {
        switch usage {
        case 0xB0: return "Play"
        case 0xB1: return "Pause"
        case 0xB2: return "Record"
        case 0xB3: return "FastForward"
        case 0xB4: return "Rewind"
        case 0xB5: return "ScanNextTrack"
        case 0xB6: return "ScanPreviousTrack"
        case 0xB7: return "Stop"
        case 0xCD: return "PlayPause"
        case 0xCF: return "VoiceCommand"
        case 0xE2: return "Mute"
        case 0xE9: return "VolumeIncrement"
        case 0xEA: return "VolumeDecrement"
        case 0x221: return "Search"
        case 0x223: return "Home"
        case 0x224: return "Back"
        case 0x225: return "Forward"
        case 0x226: return "Stop2"
        case 0x227: return "Refresh"
        case 0x22A: return "Bookmarks"
        case 0x279: return "MediaSelect"
        default: return "Consumer(\(String(format: "0x%X", usage)))"
        }
    }
    if page == 0x01 {
        switch usage {
        case 0x80: return "SystemControl"
        case 0x81: return "SystemPowerDown"
        case 0x82: return "SystemSleep"
        case 0x83: return "SystemWake"
        case 0x84: return "SystemContextMenu"
        case 0x85: return "SystemMainMenu"
        case 0x86: return "SystemAppMenu"
        case 0x87: return "SystemMenuHelp"
        case 0x88: return "SystemMenuExit"
        case 0x89: return "SystemMenuSelect"
        case 0x8A: return "SystemMenuRight"
        case 0x8B: return "SystemMenuLeft"
        case 0x8C: return "SystemMenuUp"
        case 0x8D: return "SystemMenuDown"
        default: return "Desktop(\(String(format: "0x%X", usage)))"
        }
    }
    return "page=\(String(page, radix: 16)) usage=\(String(usage, radix: 16))"
}

// MARK: - IOHID

var hidManager: IOHIDManager?
private var hidDevices: [String] = []

let hidDeviceMatchedCallback: IOHIDDeviceCallback = { _, _, _, device in
    log("IOHID", "DEVICE ADDED  \(hidDeviceDescription(device))")
    let desc = hidDeviceDescription(device)
    logLock.lock()
    hidDevices.append(desc)
    logLock.unlock()
}

let hidDeviceRemovedCallback: IOHIDDeviceCallback = { _, _, _, device in
    log("IOHID", "DEVICE REMOVED  \(hidDeviceDescription(device))")
}

let hidInputValueCallback: IOHIDValueCallback = { _, _, _, value in
    let element = IOHIDValueGetElement(value)
    let device = IOHIDElementGetDevice(element)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)
    let reportID = IOHIDElementGetReportID(element)
    let isHeadset = hidDeviceMatchesHeadset(device)
    let isMedia = page == 0x0C
    let isSystem = page == 0x01 && usage >= 0x80 && usage <= 0x9F

    guard isHeadset || isMedia || isSystem else { return }

    let deviceLabel = isHeadset ? "HEADSET" : "OTHER"
    log("IOHID", "\(deviceLabel) page=\(String(page, radix: 16)) usage=\(String(usage, radix: 16)) " +
        "\(hidUsageName(page: page, usage: usage)) value=\(intValue) reportID=\(reportID) " +
        "device=\(hidDeviceDescription(device))")
}

let hidInputReportCallback: IOHIDReportCallback = { _, _, _, type, reportID, report, length in
    // Raw reports are only interesting for the headset (other HID devices such
    // as the keyboard would flood the log).
    logLock.lock()
    let hasHeadset = hidDevices.contains { $0.lowercased().contains("edifier") || $0.lowercased().contains("x fit") }
    logLock.unlock()
    guard hasHeadset else { return }

    let bytes = UnsafeBufferPointer(start: UnsafePointer(report), count: Int(length))
    let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    log("IOHID-REPORT", "type=\(type.rawValue) reportID=\(reportID) len=\(length) bytes=[\(hexBytes)]")
}

func setupHID() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    hidManager = manager
    IOHIDManagerSetDeviceMatching(manager, nil)
    IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatchedCallback, nil)
    IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemovedCallback, nil)
    IOHIDManagerRegisterInputValueCallback(manager, hidInputValueCallback, nil)
    IOHIDManagerRegisterInputReportCallback(manager, hidInputReportCallback, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue as CFString)
    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    log("IOHID", "manager opened result=\(result)")
}

// MARK: - CGEvent tap

var eventTap: CFMachPort?
var eventTapSource: CFRunLoopSource?

func setupEventTap() {
    // CoreGraphics does not export a constant for NX_SYSDEFINED; the raw event
    // type is 14. keyDown/keyUp/flagsChanged are 10/11/12.
    let mask: CGEventMask =
        (CGEventMask(1) << 14) |
        (CGEventMask(1) << 10) |
        (CGEventMask(1) << 11) |
        (CGEventMask(1) << 12)

    let callback: CGEventTapCallBack = { _, type, event, _ in
        let raw = UInt32(truncatingIfNeeded: type.rawValue)
        if raw == 0xFFFF_FFFE || raw == 0xFFFF_FFFF {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("CGEventTap", "tap disabled by system -> re-enabled")
            return Unmanaged.passUnretained(event)
        }
        guard raw == 14 || raw == 10 || raw == 11 || raw == 12 else {
            return Unmanaged.passUnretained(event)
        }
        if let nsEvent = NSEvent(cgEvent: event) {
            logNSEvent(nsEvent, channel: "CGEventTap")
        }
        return Unmanaged.passUnretained(event)
    }

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: nil
    ) else {
        log("CGEventTap", "tapCreate FAILED (needs Accessibility permission)")
        return
    }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    eventTapSource = source
    CGEvent.tapEnable(tap: tap, enable: true)
    log("CGEventTap", "installed (NX_SYSDEFINED + keyDown/keyUp/flagsChanged, pass-through)")
}

func logNSEvent(_ event: NSEvent, channel: String) {
    switch event.type {
    case .systemDefined:
        let data1 = UInt32(truncatingIfNeeded: event.data1)
        let data2 = UInt32(truncatingIfNeeded: event.data2)
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let flags1 = data1 & 0x0000_FFFF
        var flags = flags1
        if flags == 0 { flags = data2 & 0xFFFF }
        let state = (flags & 0xFF00) >> 8
        let repeatFlag = flags & 0x00FF
        log(channel, "systemDefined subtype=\(event.subtype.rawValue) " +
            "keyCode=\(keyCode) state=\(hex(state, width: 2)) repeat=\(hex(repeatFlag, width: 2)) " +
            "data1=\(hex(data1, width: 8)) data2=\(hex(data2, width: 8))")
    case .keyDown, .keyUp:
        log(channel, "\(event.type == .keyDown ? "keyDown" : "keyUp") keyCode=\(event.keyCode) " +
            "chars=\(event.charactersIgnoringModifiers ?? "")")
    case .flagsChanged:
        log(channel, "flagsChanged keyCode=\(event.keyCode) flags=\(hex(UInt32(truncatingIfNeeded: event.modifierFlags.rawValue), width: 8))")
    default:
        break
    }
}

// MARK: - NSEvent monitors

var globalMonitor: Any?
var localMonitor: Any?

func setupNSEventMonitors() {
    let types: NSEvent.EventTypeMask = [.systemDefined, .keyDown, .keyUp, .flagsChanged]
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: types) { event in
        logNSEvent(event, channel: "NSEvent.global")
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: types) { event in
        logNSEvent(event, channel: "NSEvent.local")
        return event
    }
    log("NSEvent", "global + local monitors installed (global=\(globalMonitor != nil) local=\(localMonitor != nil))")
}

// MARK: - MPRemoteCommandCenter

var silentEngine: AVAudioEngine?
var silentPlayer: AVAudioPlayerNode?

/// SIGINT dispatch source must be retained while the run loop runs.
var signalSourceKeepAlive: DispatchSourceSignal?

func playbackStateName() -> String {
    switch MPNowPlayingInfoCenter.default().playbackState {
    case .playing: return "playing"
    case .paused: return "paused"
    case .stopped: return "stopped"
    default: return "other(\(MPNowPlayingInfoCenter.default().playbackState.rawValue))"
    }
}

/// Audible confirmation: one beep per command the Mac actually received. This
/// makes it obvious whether a tap reached the Mac at all.
func beep(for command: String) {
    let sound: String
    switch command {
    case "play": sound = "Glass"
    case "pause": sound = "Pop"
    case "togglePlayPause": sound = "Tink"
    case "nextTrack": sound = "Purr"
    case "previousTrack": sound = "Bottle"
    default: sound = "Funk"
    }
    NSSound(named: sound)?.play()
}

/// Behaves like a real media app: reflects transport changes in Now Playing so
/// the AVRCP state machine on the headset side stays in sync.
func applyTransportState(for command: String) {
    let center = MPNowPlayingInfoCenter.default()
    switch command {
    case "play":
        center.playbackState = .playing
    case "pause":
        center.playbackState = .paused
    case "togglePlayPause":
        center.playbackState = center.playbackState == .playing ? .paused : .playing
    default:
        break
    }
}

func setupRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()

    let commands: [(String, MPRemoteCommand)] = [
        ("play", center.playCommand),
        ("pause", center.pauseCommand),
        ("stop", center.stopCommand),
        ("togglePlayPause", center.togglePlayPauseCommand),
        ("nextTrack", center.nextTrackCommand),
        ("previousTrack", center.previousTrackCommand),
        ("seekForward", center.seekForwardCommand),
        ("seekBackward", center.seekBackwardCommand),
        ("skipForward", center.skipForwardCommand),
        ("skipBackward", center.skipBackwardCommand),
        ("changePlaybackPosition", center.changePlaybackPositionCommand),
        ("changePlaybackRate", center.changePlaybackRateCommand),
        ("like", center.likeCommand),
        ("dislike", center.dislikeCommand),
        ("bookmark", center.bookmarkCommand),
        ("rating", center.ratingCommand),
        ("changeShuffleMode", center.changeShuffleModeCommand),
        ("changeRepeatMode", center.changeRepeatModeCommand),
        ("enableLanguageOption", center.enableLanguageOptionCommand),
        ("disableLanguageOption", center.disableLanguageOptionCommand),
    ]

    for (name, command) in commands {
        command.isEnabled = true
        command.addTarget { _ in
            log("MPRemote", ">>> \(name) received (state before=\(playbackStateName()))")
            DispatchQueue.main.async {
                beep(for: name)
                applyTransportState(for: name)
                log("MPRemote", "    state after=\(playbackStateName())")
            }
            return .success
        }
    }
    log("MPRemote", "\(commands.count) commands registered")
}

func becomeNowPlaying() {
    MPRemoteCommandCenter.shared()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
        MPMediaItemPropertyTitle: "Headset Monitor",
        MPMediaItemPropertyArtist: "diagnostic",
        MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
    ]
    MPNowPlayingInfoCenter.default().playbackState = .playing

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = engine.outputNode.inputFormat(forBus: 0)
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
          let channels = buffer.floatChannelData else {
        log("CoreAudio", "cannot build silence buffer for format \(format)")
        return
    }
    buffer.frameLength = 1024
    let byteCount = Int(1024 * format.streamDescription.pointee.mBytesPerFrame)
    for channel in 0..<Int(format.channelCount) {
        memset(channels[channel], 0, byteCount)
    }
    do {
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.volume = 0.0
        player.play()
        silentEngine = engine
        silentPlayer = player
        log("CoreAudio", "silent Now-Playing playback started")
    } catch {
        log("CoreAudio", "silent playback failed: \(error)")
    }
}

// MARK: - CoreAudio default device monitoring

func audioDefaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr ? device : 0
}

func audioDeviceName(_ device: AudioDeviceID) -> String {
    guard device != 0 else { return "none" }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    // CoreAudio hands back a CFStringRef; use Unmanaged so Swift does not try
    // to pass a bridged class reference as a raw output buffer.
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &name) { pointer in
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
    }
    guard status == noErr, let name else { return "unknown" }
    return name.takeUnretainedValue() as String
}

func listenForDefaultDeviceChanges(_ selector: AudioObjectPropertySelector, label: String) {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        DispatchQueue.main
    ) { _, _ in
        let device = audioDefaultDevice(selector)
        log("CoreAudio", "\(label) changed -> \(audioDeviceName(device)) (id=\(device))")
    }
}

func logAudioDefaults() {
    let input = audioDefaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    let output = audioDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    let system = audioDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
    log("CoreAudio", "default input  = \(audioDeviceName(input)) (id=\(input))")
    log("CoreAudio", "default output = \(audioDeviceName(output)) (id=\(output))")
    log("CoreAudio", "system output  = \(audioDeviceName(system)) (id=\(system))")
}

// MARK: - Main

let arguments = CommandLine.arguments
let checkMode = arguments.contains("--check")
let duration: TimeInterval? = {
    guard let index = arguments.firstIndex(of: "--duration"),
          index + 1 < arguments.count,
          let value = TimeInterval(arguments[index + 1]) else { return nil }
    return value
}()

openLogFile()

if !checkMode {
    print("""
    ============================================================
     HeadsetMonitor  —  press single / double / triple on the headset
     Quit MyLlamaSpeechAssistant first.
     Stop with Ctrl-C.
    ============================================================
    """)
}

let runningApp = NSWorkspace.shared.runningApplications.first {
    ($0.localizedName ?? "").contains("MyLlamaSpeechAssistant")
}
if let runningApp {
    log("SETUP", "WARNING: \(runningApp.localizedName ?? "app") is running; it may own Now Playing and swallow media keys. Please quit it.")
}

log("SETUP", "AXIsProcessTrusted (Accessibility) = \(AXIsProcessTrusted())")
log("SETUP", "NOTE: the CGEvent tap needs Accessibility; IOHID needs Input Monitoring.")
log("SETUP", "Both permissions are granted to the *terminal app* that launches this binary.")

setupNSEventMonitors()
setupEventTap()
setupRemoteCommands()
becomeNowPlaying()
setupHID()
logAudioDefaults()
listenForDefaultDeviceChanges(kAudioHardwarePropertyDefaultInputDevice, label: "default input")
listenForDefaultDeviceChanges(kAudioHardwarePropertyDefaultOutputDevice, label: "default output")

DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    logLock.lock()
    let devices = hidDevices
    logLock.unlock()
    log("IOHID", "HID devices seen: \(devices.count)")
    for device in devices {
        log("IOHID", "  • \(device)")
    }
    let headsetSeen = devices.contains {
        let lower = $0.lowercased()
        return lower.contains("edifier") || lower.contains("x fit") ||
            (lower.contains("transport=audio") && lower.contains("headset"))
    }
    if devices.isEmpty {
        log("IOHID", "No HID devices at all — likely missing Input Monitoring permission.")
    } else if !headsetSeen {
        log("IOHID", "No EDIFIER/X Fit HID device: the headset's buttons are probably delivered over Bluetooth AVRCP/MediaRemote (watch MPRemote/CGEventTap/NSEvent).")
    } else {
        log("IOHID", "Headset HID interface found; raw reports/values from it will be logged.")
    }
}

if checkMode {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        log("SETUP", "check mode finished")
        logLock.lock()
        let counts = channelCounts
        logLock.unlock()
        log("SUMMARY", "\(counts)")
        exit(0)
    }
} else {
    signal(SIGINT, SIG_IGN)
    let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigSource.setEventHandler {
        logLock.lock()
        let counts = channelCounts
        logLock.unlock()
        log("SUMMARY", "signals per channel: \(counts)")
        log("SUMMARY", "log file: written under ./logs/")
        exit(0)
    }
    sigSource.resume()
    signalSourceKeepAlive = sigSource

    if let duration {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            logLock.lock()
            let counts = channelCounts
            logLock.unlock()
            log("SUMMARY", "duration \(Int(duration))s elapsed")
            log("SUMMARY", "signals per channel: \(counts)")
            exit(0)
        }
    }
}

// Keep the process alive; all callbacks are driven by the main run loop.
RunLoop.main.run()
