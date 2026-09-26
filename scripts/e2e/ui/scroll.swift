// Posts 5 scroll-wheel events at a screen point (points, not pixels), e.g. to scroll a Form in a sheet.
// Usage: swift scroll.swift <x> <y> <lines per event; negative scrolls down>
import CoreGraphics
import Foundation
let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!, dy = Int32(CommandLine.arguments[3])!
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(200_000)
for _ in 0..<5 { CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap); usleep(50_000) }
