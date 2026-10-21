import Foundation
import AppKit
import CoreGraphics

func windowOwners() -> [String] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { $0[kCGWindowOwnerName as String] as? String }
}

let baseline = Set(windowOwners())
print("[siri-probe] baseline owners sample: \(Array(baseline).sorted().prefix(12))")

DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"Siri\" to activate"]
    try? p.run(); print("[siri-probe] Siri activated")
}
var seen = baseline
for i in 0..<20 {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.25) {
        let owners = Set(windowOwners())
        let new = owners.subtracting(seen)
        if !new.isEmpty {
            print("[siri-probe] NEW window owners at +\(String(format: "%.2f", 1.0 + Double(i) * 0.25))s: \(Array(new).sorted())")
            seen = owners
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"System Events\" to key code 53"]
    try? p.run(); print("[siri-probe] Escape sent")
}
RunLoop.main.run(until: Date().addingTimeInterval(6.5))
print("[siri-probe] done")
