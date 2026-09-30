import Foundation

/// Maps a transcriber's audio time (seconds of samples fed) to wall-clock dates.
///
/// Audio is fed back to back, so while the stream flows audio time tracks the clock. After a gap
/// (sharing paused, the link dropped) the next samples start a new anchor, so segments keep the
/// time they were actually spoken.
public struct AudioTimeline: Sendable {
    private var anchors: [(audio: Double, wall: Date)] = []
    public private(set) var fedSeconds: Double = 0
    /// Audio time of the newest non-silent audio.
    public private(set) var lastSoundAt: Double?
    /// A jump this large between expected and reported capture time starts a new anchor.
    public var resyncThreshold: TimeInterval = 0.75

    public init() {}

    /// Records `sampleCount` samples captured starting at `capturedAt`.
    public mutating func feed(sampleCount: Int, sampleRate: Int, capturedAt: Date, isSilent: Bool = false) {
        guard sampleCount > 0, sampleRate > 0 else { return }
        let expected = date(forAudioTime: fedSeconds)
        if anchors.isEmpty || abs(capturedAt.timeIntervalSince(expected)) > resyncThreshold {
            anchors.append((fedSeconds, capturedAt))
            if anchors.count > 512 { anchors.removeFirst(anchors.count - 512) }
        }
        let duration = Double(sampleCount) / Double(sampleRate)
        if !isSilent { lastSoundAt = fedSeconds + duration }
        fedSeconds += duration
    }

    public func date(forAudioTime time: Double) -> Date {
        guard let anchor = anchors.last(where: { $0.audio <= time + 0.0005 }) ?? anchors.first else {
            return Date(timeIntervalSince1970: 0).addingTimeInterval(time)
        }
        return anchor.wall.addingTimeInterval(time - anchor.audio)
    }

    public mutating func reset() {
        anchors.removeAll()
        fedSeconds = 0
        lastSoundAt = nil
    }
}
