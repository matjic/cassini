import Foundation

/// Resolves a `ring_time` (the 32-bit event-sequence cursor) to wall-clock time
/// via a time-sync anchor (spec §3.8).
///
/// `ring_time` increments at a fixed tick (default 100 ms/tick; 1 ms/tick in burst,
/// time-sync token `0xFD`), so within one power-on **epoch** a single anchor maps
/// the whole timeline linearly. But `ring_time` **resets** when the ring restarts,
/// so the same value can recur in a later epoch at a different real time. This
/// resolver tracks epochs: feed every record's `ring_time` in stream order via
/// `observe(_:)`; a large backward jump drops the now-stale anchor until the next
/// time-sync re-anchors the new epoch.
public final class RingTimeResolver {
    public struct Anchor: Equatable, Sendable {
        public let ringTime: UInt32
        public let unixMs: Double
        public let tickMs: Double
    }

    public private(set) var anchor: Anchor?
    private var lastSeen: UInt32?

    /// A backward jump larger than this means the counter rolled back to a new
    /// epoch (ring restart), not normal out-of-order jitter.
    public static let restartBackstep: UInt32 = 0x1_0000   // one session block (65536 ticks)

    public init() {}

    /// Adopt a time-sync (`0x42`) as the current epoch's anchor.
    public func setAnchor(ringTime: UInt32, unixSeconds: Int, tickMs: Double) {
        anchor = Anchor(ringTime: ringTime, unixMs: Double(unixSeconds) * 1000.0, tickMs: tickMs)
    }

    /// Feed each record's `ring_time` in stream order. Detects an epoch reset (a
    /// large backward jump) and drops the stale anchor until the next time-sync.
    public func observe(_ ringTime: UInt32) {
        if let last = lastSeen, ringTime &+ Self.restartBackstep < last {
            anchor = nil
        }
        lastSeen = ringTime
    }

    /// Wall-clock unix-ms for a `ring_time`; nil until the current epoch is anchored.
    public func unixMs(_ ringTime: UInt32) -> Double? {
        guard let a = anchor else { return nil }
        return a.unixMs + Double(Int64(ringTime) - Int64(a.ringTime)) * a.tickMs
    }

    /// Wall-clock `Date` for a `ring_time`; nil until anchored.
    public func date(_ ringTime: UInt32) -> Date? {
        unixMs(ringTime).map { Date(timeIntervalSince1970: $0 / 1000.0) }
    }

    /// Forget the anchor + stream position (new connection / explicit reset).
    public func reset() {
        anchor = nil
        lastSeen = nil
    }
}
