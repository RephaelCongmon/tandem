import Foundation
import os

/// Holds screenshot bytes. By default images live only in memory for the
/// session ("not for saving"); users can opt into keeping them on disk so
/// thread history keeps its pictures across launches.
public final class SnapshotStore: @unchecked Sendable {
    private struct Entry {
        var data: Data
        var mimeType: String
        var lastAccess: UInt64
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var variants: [String: AIImage] = [:]
    private var memoryBytes = 0
    private var accessCounter: UInt64 = 0
    private let directory: URL?
    private let memoryLimitBytes: Int
    private var keepOnDisk: Bool
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Snapshots")

    public init(directory: URL?, keepOnDisk: Bool, memoryLimitBytes: Int = 768 * 1024 * 1024) {
        self.directory = directory
        self.keepOnDisk = keepOnDisk
        self.memoryLimitBytes = memoryLimitBytes
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public var isKeepingOnDisk: Bool {
        lock.lock()
        defer { lock.unlock() }
        return keepOnDisk
    }

    /// Switching off deletes every image already written to disk.
    public func setKeepOnDisk(_ keep: Bool) {
        lock.lock()
        keepOnDisk = keep
        let snapshot = entries
        lock.unlock()
        guard let directory else { return }
        if keep {
            for (id, entry) in snapshot { write(entry.data, id: id, directory: directory) }
        } else {
            removeAllFiles(in: directory)
        }
    }

    public func put(_ data: Data, id: UUID, mimeType: String = "image/jpeg") {
        lock.lock()
        accessCounter += 1
        if let old = entries[id] { memoryBytes -= old.data.count }
        entries[id] = Entry(data: data, mimeType: mimeType, lastAccess: accessCounter)
        memoryBytes += data.count
        invalidateVariants(for: id)
        let keep = keepOnDisk
        evictIfNeeded()
        lock.unlock()
        if keep, let directory { write(data, id: id, directory: directory) }
    }

    public func data(for id: UUID) -> Data? {
        lock.lock()
        if var entry = entries[id] {
            accessCounter += 1
            entry.lastAccess = accessCounter
            entries[id] = entry
            lock.unlock()
            return entry.data
        }
        let keep = keepOnDisk
        lock.unlock()
        guard keep, let directory, let data = try? Data(contentsOf: fileURL(id, in: directory)) else { return nil }
        put(data, id: id)
        return data
    }

    public func contains(_ id: UUID) -> Bool {
        lock.lock()
        let inMemory = entries[id] != nil
        let keep = keepOnDisk
        lock.unlock()
        if inMemory { return true }
        guard keep, let directory else { return false }
        return FileManager.default.fileExists(atPath: fileURL(id, in: directory).path)
    }

    /// The image re-encoded so its long edge is at most `maxDimension` (cached).
    public func aiImage(for id: UUID, maxDimension: Int, quality: Double = 0.88) -> AIImage? {
        let key = "\(id.uuidString)-\(maxDimension)"
        lock.lock()
        if let cached = variants[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let data = data(for: id), let size = ImageCodec.pixelSize(of: data) else { return nil }
        let result: AIImage
        if max(size.width, size.height) <= maxDimension || maxDimension <= 0 {
            result = AIImage(data: data, mimeType: "image/jpeg", width: size.width, height: size.height)
        } else {
            guard let image = ImageCodec.decode(data),
                  let encoded = ImageCodec.jpeg(image, quality: quality, maxDimension: maxDimension) else { return nil }
            result = AIImage(data: encoded.data, mimeType: "image/jpeg", width: encoded.width, height: encoded.height)
        }
        lock.lock()
        variants[key] = result
        lock.unlock()
        return result
    }

    public func remove(_ ids: [UUID]) {
        lock.lock()
        for id in ids {
            if let entry = entries.removeValue(forKey: id) { memoryBytes -= entry.data.count }
            invalidateVariants(for: id)
        }
        lock.unlock()
        guard let directory else { return }
        for id in ids { try? FileManager.default.removeItem(at: fileURL(id, in: directory)) }
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll()
        variants.removeAll()
        memoryBytes = 0
        lock.unlock()
        if let directory { removeAllFiles(in: directory) }
    }

    // MARK: Private

    private func invalidateVariants(for id: UUID) {
        let prefix = id.uuidString
        variants = variants.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Must be called with the lock held.
    private func evictIfNeeded() {
        guard memoryBytes > memoryLimitBytes else { return }
        let ordered = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (id, entry) in ordered where memoryBytes > memoryLimitBytes * 3 / 4 {
            entries[id] = nil
            memoryBytes -= entry.data.count
            invalidateVariants(for: id)
        }
        log.info("Evicted snapshots to stay under the memory budget")
    }

    private func fileURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func write(_ data: Data, id: UUID, directory: URL) {
        do {
            try data.write(to: fileURL(id, in: directory), options: [.atomic])
        } catch {
            log.error("Couldn't persist snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeAllFiles(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jpg" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
