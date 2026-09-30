import CryptoKit
import Foundation

public enum FileTools {
    /// Lowercase hex SHA-256 of a file, read in 1 MB pieces.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex SHA-256 of `data`.
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Unpacks a zip made by `ditto -c -k` into `folder`.
    public static func unzip(_ archive: URL, to folder: URL, timeout: TimeInterval = 600) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let result = await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, folder.path], timeout: timeout),
              result.status == 0 else {
            throw UpdateError.invalidPackage("\(archive.lastPathComponent) couldn't be unpacked.")
        }
    }

    /// Zips `item` (a file or folder, kept as the top level) with `ditto -c -k --keepParent`,
    /// preserving code signatures.
    public static func zip(_ item: URL, to archive: URL, timeout: TimeInterval = 600) async throws {
        try? FileManager.default.removeItem(at: archive)
        guard let result = await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", item.path, archive.path], timeout: timeout),
              result.status == 0 else {
            throw UpdateError.installFailed("Couldn't pack \(item.lastPathComponent).")
        }
    }
}
