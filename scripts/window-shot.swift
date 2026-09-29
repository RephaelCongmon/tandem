#!/usr/bin/env swift
// Captures the largest on-screen window of a process: window-shot.swift <pid> <out.png>
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else {
    print("usage: window-shot.swift <pid> <out.png>")
    exit(1)
}
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
let candidates = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
let best = candidates.max { a, b in
    let ra = a[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let rb = b[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (ra["Width"] ?? 0) * (ra["Height"] ?? 0) < (rb["Width"] ?? 0) * (rb["Height"] ?? 0)
}
guard let window = best, let id = window[kCGWindowNumber as String] as? Int else {
    print("no window for pid \(pid)")
    exit(2)
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-x", "-o", "-l\(id)", args[2]]
try task.run()
task.waitUntilExit()
print("captured window \(id) -> \(args[2])")
