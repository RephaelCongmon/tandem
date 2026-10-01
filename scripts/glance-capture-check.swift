import AppKit
import ScreenCaptureKit

// Glance capture check: puts a magenta panel (configured like the Glance overlay) on the main
// display for about two seconds and reports whether ScreenCaptureKit captures it with each
// filter Tandem uses. B, C and E must say "not captured" (A is the sanity check).
// Run it from Terminal, which needs Screen Recording permission:
//   swift scripts/glance-capture-check.swift

@MainActor
func run() async {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let screen = NSScreen.main else { print("no screen"); exit(2) }
    let rect = NSRect(x: screen.frame.minX + 120, y: screen.frame.minY + 160, width: 320, height: 200)
    let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
    panel.isOpaque = true
    panel.level = .floating
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.orderFrontRegardless()
    try? await Task.sleep(nanoseconds: 600_000_000)

    func capture(_ label: String, sharingType: NSWindow.SharingType, filter makeFilter: (SCShareableContent, SCDisplay) -> SCContentFilter) async {
        panel.sharingType = sharingType
        try? await Task.sleep(nanoseconds: 300_000_000)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { print(label, "no display: this process needs Screen Recording permission"); return }
            let filter = makeFilter(content, display)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width)
            configuration.height = Int(screen.frame.height)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let rep = NSBitmapImageRep(cgImage: image)
            // Panel center in image coordinates (top-left origin, 1 px per point here).
            let x = Int(rect.midX - screen.frame.minX)
            let y = Int(screen.frame.maxY - rect.midY)
            let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            let r = color?.redComponent ?? -1, g = color?.greenComponent ?? -1, b = color?.blueComponent ?? -1
            let magenta = r > 0.9 && g < 0.15 && b > 0.9
            print(String(format: "%@: pixel=(%.2f, %.2f, %.2f) → overlay %@", label, r, g, b, magenta ? "CAPTURED" : "not captured"))
        } catch {
            print(label, "error:", error.localizedDescription)
        }
    }

    let pid = ProcessInfo.processInfo.processIdentifier
    await capture("A no exclusion (sanity)", sharingType: .readOnly) { _, display in
        SCContentFilter(display: display, excludingWindows: [])
    }
    await capture("B exclude own app (Tandem default)", sharingType: .readOnly) { content, display in
        SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == pid }, exceptingWindows: [])
    }
    await capture("C exclude the window (own windows shared)", sharingType: .readOnly) { content, display in
        SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.windowID == CGWindowID(panel.windowNumber) })
    }
    await capture("D sharingType none only (informational)", sharingType: .none) { _, display in
        SCContentFilter(display: display, excludingWindows: [])
    }
    await capture("E the real overlay: sharingType none + window excluded", sharingType: .none) { content, display in
        SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.windowID == CGWindowID(panel.windowNumber) })
    }
    panel.orderOut(nil)
    exit(0)
}

Task { @MainActor in await run() }
RunLoop.main.run()
