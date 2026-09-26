// Lists on-screen windows of one process: "<window id> layer=<n> <x>,<y> <w>x<h> <title>".
// Use it to find the E2E app's windows by pid (the installed App Store copy has the same owner name).
// Usage: swift winpid.swift <pid>
import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
guard let ws = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in ws where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    print("\(w[kCGWindowNumber as String] as? Int ?? -1) layer=\(w[kCGWindowLayer as String] as? Int ?? -1) \(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) \(w[kCGWindowName as String] as? String ?? "")")
}
