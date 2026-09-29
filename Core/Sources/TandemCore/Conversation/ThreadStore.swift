import Foundation
import os

/// Persists threads as one JSON file each, written atomically off the main thread
/// and coalesced so streaming tokens don't cause a write per token.
public final class ThreadStore: @unchecked Sendable {
    private let directory: URL
    private let ioQueue = DispatchQueue(label: "tandem.threadstore", qos: .utility)
    private var pendingWrites: [UUID: ChatThread] = [:]
    private var scheduled = false
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let coalesceInterval: TimeInterval
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Threads")

    public init(directory: URL, coalesceInterval: TimeInterval = 0.75) {
        self.directory = directory
        self.coalesceInterval = coalesceInterval
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads every thread, newest first. Corrupt files are moved aside, not lost.
    public func loadAll() -> [ChatThread] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var threads: [ChatThread] = []
        for file in files where file.pathExtension == "json" {
            do {
                var thread = try decoder.decode(ChatThread.self, from: Data(contentsOf: file))
                // A crash mid-stream leaves messages "streaming"; mark them interrupted.
                for index in thread.messages.indices where thread.messages[index].isStreaming {
                    thread.messages[index].status = .cancelled
                }
                threads.append(thread)
            } catch {
                log.error("Unreadable thread file \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                let quarantine = file.deletingPathExtension().appendingPathExtension("corrupt")
                try? FileManager.default.moveItem(at: file, to: quarantine)
            }
        }
        return threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Schedules a coalesced write.
    public func save(_ thread: ChatThread) {
        lock.lock()
        pendingWrites[thread.id] = thread
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        ioQueue.asyncAfter(deadline: .now() + coalesceInterval) { [weak self] in self?.flushPending() }
    }

    /// Writes everything pending now (call on quit).
    public func flush() {
        ioQueue.sync { flushPending() }
    }

    public func delete(_ id: UUID) {
        lock.lock()
        pendingWrites[id] = nil
        lock.unlock()
        ioQueue.async { [directory] in
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
        }
    }

    public func deleteAll() {
        lock.lock()
        pendingWrites.removeAll()
        lock.unlock()
        ioQueue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" || file.pathExtension == "corrupt" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func flushPending() {
        lock.lock()
        let writes = pendingWrites
        pendingWrites.removeAll()
        scheduled = false
        lock.unlock()
        for (id, thread) in writes {
            do {
                let data = try encoder.encode(thread)
                try data.write(to: directory.appendingPathComponent("\(id.uuidString).json"), options: [.atomic])
            } catch {
                log.error("Couldn't save thread: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
