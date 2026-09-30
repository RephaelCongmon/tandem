import Foundation

/// Unpacks, checks and installs a downloaded Tandem release.
public enum UpdateInstaller {
    /// Unpacks the release archive next to it and returns the app inside, after checking it is
    /// the expected app and version, signed by the expected team.
    public static func prepare(
        archive: URL,
        expectedVersion: AppVersion,
        bundleIdentifier: String,
        teamIdentifier: String
    ) async throws -> URL {
        let fileManager = FileManager.default
        let folder = archive.deletingLastPathComponent().appendingPathComponent("unpacked", isDirectory: true)
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let result = await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, folder.path], timeout: 300),
              result.status == 0 else {
            throw UpdateError.invalidPackage("The download couldn't be unpacked.")
        }
        let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.invalidPackage("The download doesn't contain an app.")
        }
        let info = Bundle(url: app)?.infoDictionary ?? [:]
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError.invalidPackage("The download contains a different app.")
        }
        guard let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), version == expectedVersion else {
            throw UpdateError.invalidPackage("The download isn't version \(expectedVersion).")
        }
        try CodeSignature.verify(appAt: app, bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier)
        return app
    }

    /// Where an update of the app at `current` should go: the same place when Tandem can
    /// replace it there, otherwise Applications (e.g. when it runs from a disk image).
    public static func installLocation(
        for current: URL,
        isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) },
        isOnReadOnlyVolume: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false },
        applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        userApplications: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    ) -> URL {
        let name = "Tandem.app"
        let translocated = current.path.contains("/AppTranslocation/")
        if !translocated, !isOnReadOnlyVolume(current), isWritable(current.deletingLastPathComponent()) {
            return current
        }
        if isWritable(applications) { return applications.appendingPathComponent(name) }
        return userApplications.appendingPathComponent(name)
    }

    /// Puts `newApp` at `target`, replacing whatever is there in one step.
    public static func install(_ newApp: URL, at target: URL) throws {
        let fileManager = FileManager.default
        let parent = target.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            // Stage on the target's volume so the final swap is a rename.
            let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true)
            defer { try? fileManager.removeItem(at: staging) }
            let staged = staging.appendingPathComponent(target.lastPathComponent)
            try fileManager.copyItem(at: newApp, to: staged)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: target)
            }
        } catch {
            throw UpdateError.installFailed("Couldn't install the update in \(parent.path): \(error.localizedDescription)")
        }
    }
}
