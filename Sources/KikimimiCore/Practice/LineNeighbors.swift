import Foundation

/// 練習で流す 1 行 (文字起こしの区間 1 つ分の、id と時刻だけ)
public struct PracticeLine: Hashable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval

    public init(id: UUID, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.start = start
        self.end = end
    }

    public init(_ segment: TranscriptSegment) {
        self.init(id: segment.id, start: segment.start, end: segment.end)
    }

    /// 行の長さ (秒)。終わりが始まりより前なら 0
    public var duration: TimeInterval { max(0, end - start) }

    /// 流せる行か (長さがあり、時刻が数である)
    public var isPlayable: Bool { start.isFinite && end.isFinite && end > start }
}

/// 並んだ行の、前と次の行と、ある時刻の行を探す
public enum LineNeighbors {
    /// id の 1 つ前の id。先頭の行や、ない id なら nil
    public static func previous<ID: Equatable>(of id: ID, in ids: [ID]) -> ID? {
        guard let i = ids.firstIndex(of: id), i > 0 else { return nil }
        return ids[i - 1]
    }

    /// id の 1 つ後の id。最後の行や、ない id なら nil
    public static func next<ID: Equatable>(of id: ID, in ids: [ID]) -> ID? {
        guard let i = ids.firstIndex(of: id), i + 1 < ids.count else { return nil }
        return ids[i + 1]
    }

    /// 時刻 t の行の位置: 始まりが t より前か同じ行のうち、最後のもの。最初の行より前なら nil。
    /// 行は始まりの順に並んでいること (二分探索で探す)。始まりが同じ行が続くときは、その最後の行
    public static func index<C: RandomAccessCollection>(at t: TimeInterval, in lines: C,
                                                        start: (C.Element) -> TimeInterval) -> C.Index? {
        guard t.isFinite else { return nil }
        // 始まりが t より後の、最初の行を探す
        var low = lines.startIndex
        var high = lines.endIndex
        while low < high {
            let mid = lines.index(low, offsetBy: lines.distance(from: low, to: high) / 2)
            if start(lines[mid]) <= t {
                low = lines.index(after: mid)
            } else {
                high = mid
            }
        }
        guard low != lines.startIndex else { return nil }
        return lines.index(before: low)
    }

    /// 時刻 t の区間の位置 (`index(at:in:start:)` の区間用)
    public static func index(at t: TimeInterval, in segments: [TranscriptSegment]) -> Int? {
        index(at: t, in: segments) { $0.start }
    }

    /// 時刻 t の行の位置 (`index(at:in:start:)` の行用)
    public static func index(at t: TimeInterval, in lines: [PracticeLine]) -> Int? {
        index(at: t, in: lines) { $0.start }
    }
}
