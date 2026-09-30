import AppKit
import Foundation
import TandemCore

/// Quits Tandem and reopens `app` (a newly installed copy) once this process has exited, with
/// the same launch arguments.
enum AppRelauncher {
    static func relaunch(into app: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let arguments = CommandLine.arguments.dropFirst().map(shellQuoted).joined(separator: " ")
        var script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open -n \(shellQuoted(app.path))"
        if !arguments.isEmpty { script += " --args \(arguments)" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed("The update is installed, but Tandem couldn't restart itself. Quit and reopen it.")
        }
        NSApp.terminate(nil)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
