import Foundation
import AppKit

let names = [
    "com.apple.siri.internal.activation",
    "com.apple.siri.invoke",
    "com.apple.siri.activation",
    "com.apple.Siri.running",
]
for name in names {
    DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { note in
        print("[siri-probe] DISTRIBUTED NOTIFICATION: \(note.name.rawValue)")
    }
}
NotificationCenter.default.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
    if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        print("[siri-probe] APP LAUNCHED: \(app.bundleIdentifier ?? "?") / \(app.localizedName ?? "?")")
    }
}
print("[siri-probe] observing for 6s, activating Siri once...")
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"Siri\" to activate"]
    try? p.run()
    print("[siri-probe] activated Siri")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"System Events\" to key code 53"]
    try? p.run()
    print("[siri-probe] sent Escape")
}
RunLoop.main.run(until: Date().addingTimeInterval(6))
print("[siri-probe] done")
