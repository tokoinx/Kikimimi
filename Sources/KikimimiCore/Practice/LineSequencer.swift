import Foundation

/// 練習で、次に何をするか (どの行を流すか・待つか・止めるか) を決める。
///
/// 音を流すのはアプリの側 (再生の係)。ここは並んだ行と設定を知っていて、いまの行・その行を流した回数・続けて流している最中か、
/// だけを持つ。アプリは、利用者の操作と再生の係の知らせをここに渡し、返ってきた `Action` のとおりにする。
///
/// - `start(_:)`: 行をクリックした。その行を流す。
/// - `lineFinished(_:token:)`: 流した行が終わりまで来た。次は、間 (待つ)・同じ行をもう一度・次の行・止める のどれか。
///   決まり: 間を「行の長さだけ」にしていて、このあとに流すものがあれば、先に待つ。そのあと、流した回数が設定の回数に
///   届いていなければ (止めるまでなら、いつも) 同じ行をもう一度。届いていて「自動で次へ」なら次の行 (回数は 0 から)。
///   どれでもなければ止める。このあとに流すものがないとき (最後の行の最後の 1 回など) は、間を入れずにすぐ止める。
/// - `waitFinished(token:)`: 待ち終わった。次を決める (待つあいだに設定が変わっていれば、新しい設定で決める)。
/// - `stop()`: 利用者が止めた。
/// - `next(from:)` / `previous(from:)` / `replay(from:)`: 上下の矢印などのキー。回数は 0 から数え直す。
///
/// 流す・待つの指示には番号 (token) が付く。指示を出すたびに番号は変わり、知らせには受け取った番号を付けて返してもらう。
/// 番号が違う知らせ (止めたあとや別の行に移ったあとに遅れて届いたもの) には何もしない。だから、古い知らせで再生がまた始まることはない。
///
/// 長さのない行 (終わりが始まりと同じか前) と知らない id では、何もしない (落ちない)。次・前の行を探すときと、
/// 自動で次へ進むときは、長さのない行を飛ばす。
public struct LineSequencer: Hashable, Sendable {
    /// アプリにしてほしいこと
    public enum Action: Hashable, Sendable {
        /// 何もしない (いまのままでよい)
        case nothing
        /// この行を、始まりから終わりまで流す。終わったら `lineFinished(line.id, token: token)` を呼ぶ
        case play(PracticeLine, token: Int)
        /// この秒数だけ何も流さずに待つ。待ち終わったら `waitFinished(token: token)` を呼ぶ
        case wait(TimeInterval, token: Int)
        /// 続けて流すのをやめる (流し終わった・いまの行がなくなった)。再生が動いていれば止める
        case stop
    }

    /// いましていること
    public enum Phase: Hashable, Sendable {
        /// 何もしていない
        case idle
        /// 行を流している
        case playing
        /// 1 回流したあとの間を待っている
        case waiting
    }

    /// 並んだ行 (始まりの順)
    public private(set) var lines: [PracticeLine]
    /// 設定 (いつも候補の値に直してある)
    public private(set) var settings: PracticeSettings
    /// いまの行。止めたあとも残し、次・前の行はここから探す
    public private(set) var currentID: UUID?
    /// いまの行を流し終えた回数 (今の続きの中で)
    public private(set) var playsDone = 0
    /// いましていること
    public private(set) var phase: Phase = .idle
    /// 最後に出した指示の番号
    public private(set) var token = 0

    public init(lines: [PracticeLine] = [], settings: PracticeSettings = PracticeSettings()) {
        self.lines = lines
        self.settings = settings.normalized()
    }

    /// 続けて流している最中 (流している・間を待っている)
    public var isActive: Bool { phase != .idle }

    /// いまの行
    public var currentLine: PracticeLine? {
        guard let currentID else { return nil }
        return lines.first { $0.id == currentID }
    }

    // MARK: 利用者の操作

    /// 行を流してと頼まれた (クリック)。知らない id や長さのない行なら何もしない (いまの続きもそのまま)
    public mutating func start(_ id: UUID) -> Action {
        guard let i = lines.firstIndex(where: { $0.id == id }), lines[i].isPlayable else { return .nothing }
        return begin(lines[i])
    }

    /// 利用者が止めた。このあとに届く古い知らせには何もしない。いまの行は覚えておく
    public mutating func stop() {
        phase = .idle
        playsDone = 0
        token &+= 1
    }

    /// いまの行も忘れて、はじめの状態に戻す (行と設定はそのまま)
    public mutating func reset() {
        stop()
        currentID = nil
    }

    /// 次の行 (下の矢印)。もとにする行は、いまの行、なければ position (再生の位置の行)。どちらもなければ最初の行を流す。
    /// 最後の行なら何もしない
    public mutating func next(from position: UUID? = nil) -> Action {
        guard let base = baseIndex(position) else { return playFirst() }
        guard let i = playableIndex(after: base) else { return .nothing }
        return begin(lines[i])
    }

    /// 前の行 (上の矢印)。もとにする行は `next(from:)` と同じ。どちらもなければ最初の行を流す。最初の行なら何もしない
    public mutating func previous(from position: UUID? = nil) -> Action {
        guard let base = baseIndex(position) else { return playFirst() }
        guard let i = playableIndex(before: base) else { return .nothing }
        return begin(lines[i])
    }

    /// もとにする行をもう一度流す。もとにする行は `next(from:)` と同じ。どちらもなければ最初の行を流す
    public mutating func replay(from position: UUID? = nil) -> Action {
        guard let base = baseIndex(position) else { return playFirst() }
        guard lines[base].isPlayable else { return .nothing }
        return begin(lines[base])
    }

    // MARK: 再生の係からの知らせ

    /// 流した行が終わりまで来た。id と token は、流す指示のものを返す
    public mutating func lineFinished(_ id: UUID, token: Int) -> Action {
        guard phase == .playing, token == self.token, id == currentID, let line = currentLine else { return .nothing }
        playsDone += 1
        let following = followingStep()
        if case .end = following {
            return finish()
        }
        let gap = settings.gapSeconds(lineDuration: line.duration)
        if gap > 0 {
            phase = .waiting
            self.token &+= 1
            return .wait(gap, token: self.token)
        }
        return perform(following)
    }

    /// 間を待ち終わった。token は、待つ指示のものを返す
    public mutating func waitFinished(token: Int) -> Action {
        guard phase == .waiting, token == self.token, currentLine != nil else { return .nothing }
        return perform(followingStep())
    }

    // MARK: 行と設定が変わった

    /// 設定を変える。続けて流している最中でもよい。新しい設定は、次に決めるときから使う
    public mutating func update(settings: PracticeSettings) {
        self.settings = settings.normalized()
    }

    /// 行を入れ替える (文字起こしの途中で行が増えたときなど)。いまの行がなくなった (または長さがなくなった) ら、
    /// いまの行を忘れて止める。流している最中だったときだけ `.stop` を返し、ほかは `.nothing`
    @discardableResult
    public mutating func update(lines: [PracticeLine]) -> Action {
        self.lines = lines
        guard let currentID else { return .nothing }
        if let line = lines.first(where: { $0.id == currentID }), line.isPlayable { return .nothing }
        let wasActive = isActive
        reset()
        return wasActive ? .stop : .nothing
    }

    // MARK: 中のしくみ

    /// 1 回流したあとに続くこと
    private enum Step {
        case again
        case advance(Int)
        case end
    }

    private func followingStep() -> Step {
        if settings.repeatsUntilStopped || playsDone < settings.repeatCount { return .again }
        if settings.autoAdvance, let i = currentIndex.flatMap({ playableIndex(after: $0) }) { return .advance(i) }
        return .end
    }

    private mutating func perform(_ step: Step) -> Action {
        switch step {
        case .again:
            guard let line = currentLine else { return finish() }
            return play(line)
        case .advance(let i):
            return begin(lines[i])
        case .end:
            return finish()
        }
    }

    /// 行を新しく流し始める (回数は 0 から)
    private mutating func begin(_ line: PracticeLine) -> Action {
        currentID = line.id
        playsDone = 0
        return play(line)
    }

    private mutating func play(_ line: PracticeLine) -> Action {
        phase = .playing
        token &+= 1
        return .play(line, token: token)
    }

    /// 流し終えた。いまの行は覚えておく
    private mutating func finish() -> Action {
        phase = .idle
        token &+= 1
        return .stop
    }

    private mutating func playFirst() -> Action {
        guard let i = lines.firstIndex(where: { $0.isPlayable }) else { return .nothing }
        return begin(lines[i])
    }

    private var currentIndex: Int? {
        guard let currentID else { return nil }
        return lines.firstIndex { $0.id == currentID }
    }

    /// もとにする行の位置: いまの行、なければ position の行 (知らない id なら、ないとみなす)
    private func baseIndex(_ position: UUID?) -> Int? {
        if let i = currentIndex { return i }
        guard let position else { return nil }
        return lines.firstIndex { $0.id == position }
    }

    private func playableIndex(after i: Int) -> Int? {
        var j = i + 1
        while j < lines.count {
            if lines[j].isPlayable { return j }
            j += 1
        }
        return nil
    }

    private func playableIndex(before i: Int) -> Int? {
        var j = i - 1
        while j >= 0 {
            if lines[j].isPlayable { return j }
            j -= 1
        }
        return nil
    }
}
