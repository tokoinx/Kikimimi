import Foundation
import KikimimiCore
import Observation

/// 聞き取りの練習: 1 行を続けて流す (速さ・繰り返し・言ってみる間・自動で次へ)、文字を隠す、書き取り。
///
/// 次に何をするかは LineSequencer が決め、ここはそのとおりに再生の係 (PlayerController) を動かす:
/// - `.play` は player.playLine。行の終わりまで来たら、再生の係が onLineFinished で知らせ、lineFinished(_:token:) に渡す。
/// - `.wait` は、止められる待ち (Task.sleep)。待ち終わったら waitFinished(token:) に渡す。
/// - `.stop` は、鳴っていれば止める。
///
/// 続けて流すのを終わりにするもの (どれも stop か、同じ後始末の endSequence を通る):
/// 行をもう一度押す・ほかの行を押す (新しく始める)・スペースキーと再生ボタン (togglePlay)・つまみと「ここから続けて再生」
/// (player.seek)・ジョブを選ぶ (select)・ジョブを消す (選び直しになる)・音声を閉じる (player.unload)・マイクの録音を始める。
/// 再生ボタン・つまみ・音声を閉じる は、再生の係が onUserControl で知らせる (そのときは再生の係には触らない: 係が自分で動かす)。
///
/// 行は、選んでいるジョブの一覧の行 (対訳なら対訳の行、そうでなければ区間) を、検索で絞る前の順に並べたもの。
/// 一覧が変わったと知らされたら、印を付けるだけにして、次に要るときに作り直す (続けて流している最中だけは、その場で作り直す:
/// いまの行がなくなっていれば止める)。再生位置ごとの手間はない
@MainActor
@Observable
final class PracticeController {
    /// 一覧をその行へ動かしてほしい (キーと自動で次へで始めた行)。serial は頼むたびに変わる
    struct ScrollRequest: Equatable {
        var id: UUID
        var serial: Int
    }

    /// 行の文字の隠し方 (行の body が見る)
    struct RowConcealment: Equatable {
        /// 隠す対象の行 (目のボタンを出す)
        var canHide = false
        /// 「この行を見る」で見せている
        var revealed = false
        /// 原文を隠す
        var hidesSource = false
        /// 日本語訳の列を隠す
        var hidesTranslation = false

        static let visible = RowConcealment()
    }

    /// 再生の記録 (確認用。いちばん新しい 40 件)
    struct Event {
        enum Kind {
            case started
            case finished
        }

        var kind: Kind
        var id: UUID
        var time: Date
    }

    /// 練習の設定。UserDefaults の "practice" に JSON で保存する。隠し方は、起動のたびに「隠さない」から始める。
    /// 変えるとすぐ効く: 速さは再生の係へすぐ渡し、ほかは次に決めるときから
    var settings: PracticeSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    /// 隠し方 (settings.hide の写し)。行はこれだけを見る (速さなど、ほかの設定を変えても行を描き直さない)
    private(set) var hideMode: PracticeSettings.Hide = .nothing
    /// 結果の下に書き取りの欄を出す (UserDefaults の "practiceDictation")
    var showsDictation: Bool {
        didSet {
            if showsDictation != oldValue { UserDefaults.standard.set(showsDictation, forKey: Self.dictationKey) }
        }
    }
    /// 続けて流している行 (流している・間を待っている)。何もしていなければ nil。行の「再生中」の見た目はこれに従う
    private(set) var activeLineID: UUID?
    /// 間を待っている (声に出して言ってみる時間)
    private(set) var isWaiting = false
    /// 最後に始めた行。止めたあとも残す (キーと書き取りの欄が使う)
    private(set) var currentLineID: UUID?
    /// 一覧を動かしてほしい行 (CurrentLineTracker が見る)
    private(set) var scrollRequest: ScrollRequest?
    /// 「この行を見る」で見せた行 (一覧ごと: ジョブを選ぶと忘れる。隠し方を変えても忘れる)
    let reveal = RowReveal()
    /// 書き取りの欄の中身 (打っている文と、答え合わせの結果)。欄だけが見る
    let dictation = DictationState()

    @ObservationIgnored private let player: PlayerController
    @ObservationIgnored private var sequencer: LineSequencer
    /// 流している行の指示の番号 (行の終わりの知らせに付けて返す)。流していなければ nil
    @ObservationIgnored private var playToken: Int?
    /// 流している行を始めた時刻 (uptime の秒) と、その行が鳴るはずの長さ (秒、いまの速さで)
    @ObservationIgnored private var playStarted: (uptime: TimeInterval, expected: TimeInterval)?
    @ObservationIgnored private var waitTask: Task<Void, Never>?
    /// 行を取るジョブ (選んでいるジョブ)
    @ObservationIgnored private weak var job: Job?
    @ObservationIgnored private var jobID: UUID?
    /// 一覧が対訳で出ている (行は対訳の行)
    @ObservationIgnored private var bilingual = false
    @ObservationIgnored private let rowCache = TranscriptRowCache()
    @ObservationIgnored private var rows: [TranscriptListItem] = []
    @ObservationIgnored private var rowIndex: [UUID: Int] = [:]
    /// 一覧が変わったので、次に要るときに行を作り直す
    @ObservationIgnored private var rowsStale = true
    @ObservationIgnored private var scrollSerial = 0
    @ObservationIgnored private(set) var events: [Event] = []

    static let settingsKey = "practice"
    static let dictationKey = "practiceDictation"

    init(player: PlayerController) {
        self.player = player
        let d = UserDefaults.standard
        var loaded = PracticeSettings.load(jsonString: d.string(forKey: Self.settingsKey))
        loaded.hide = .nothing
        settings = loaded
        showsDictation = d.object(forKey: Self.dictationKey) as? Bool ?? false
        sequencer = LineSequencer(settings: loaded)
        player.rate = loaded.rate
        player.onLineFinished = { [weak self] id in
            self?.playerFinishedLine(id)
        }
        player.onUserControl = { [weak self] in
            self?.endSequence()
        }
    }

    /// 設定が決まりの値から変わっている (「練習」のボタンに色を付ける)
    var isCustomized: Bool {
        settings != PracticeSettings() || showsDictation
    }

    // MARK: 行

    /// ジョブを選んだ (AppModel.select)。別のジョブなら、続けて流すのをやめ、いまの行・見せた行・書き取りを忘れる
    func select(_ job: Job?) {
        guard job?.id != jobID else {
            self.job = job
            return
        }
        stop()
        sequencer.reset()
        self.job = job
        jobID = job?.id
        rows = []
        rowIndex = [:]
        rowsStale = true
        reveal.reset(forget: true)
        sync()
    }

    /// 一覧が出た・一覧の行が変わった (一覧の見えない部品から)。行は次に要るときに作り直す
    func rowsChanged(job: Job, bilingual: Bool) {
        if job.id != jobID { select(job) }
        self.job = job
        self.bilingual = bilingual
        rowsStale = true
        // 続けて流している最中: いまの行がなくなっていれば、すぐ止める
        if sequencer.isActive { refreshRows() }
    }

    /// いまの行の始まり (書き取りの欄が出す)
    var currentLineStart: TimeInterval? {
        guard let id = currentLineID, let i = rowIndex[id], i < rows.count else { return nil }
        return rows[i].start
    }

    /// 行の文 (対訳の行なら、まとめた原文)
    func text(of id: UUID) -> String? {
        ensureRows()
        guard let i = rowIndex[id], i < rows.count else { return nil }
        return rows[i].text
    }

    private func ensureRows() {
        if rowsStale { refreshRows() }
    }

    private func refreshRows() {
        rowsStale = false
        if let job, let transcript = job.transcript {
            rows = rowCache.items(of: transcript, job: job.id, done: job.status == .done, bilingual: bilingual, query: "")
        } else {
            rows = []
        }
        var index: [UUID: Int] = [:]
        index.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() where index[row.id] == nil {
            index[row.id] = i
        }
        rowIndex = index
        let action = sequencer.update(lines: rows.map { PracticeLine(id: $0.id, start: $0.start, end: $0.end) })
        perform(action, scroll: false)
    }

    /// 再生位置にある行 (いまの行がないときの、次・前・もう一度のもと)
    private func lineAtPlaybackPosition() -> UUID? {
        guard let job, job.url != nil, player.url == job.url else { return nil }
        guard let i = LineNeighbors.index(at: player.currentTime, in: sequencer.lines) else { return nil }
        return sequencer.lines[i].id
    }

    // MARK: 使う人の操作

    /// 行を押した: その行を続けて流している (流している・間を待っている) なら止め、そうでなければその行から始める
    func toggleLine(_ id: UUID) {
        ensureRows()
        if activeLineID == id {
            stop()
            return
        }
        var action = sequencer.start(id)
        if action == .nothing {
            // 一覧の行と、こちらの行がずれていた (知らせの前に押された): 作り直して、もう一度
            refreshRows()
            action = sequencer.start(id)
        }
        perform(action, scroll: false)
    }

    /// 次の行 (下の矢印)。いまの行がなければ再生位置の行から、それもなければ最初の行
    func next() {
        ensureRows()
        perform(sequencer.next(from: lineAtPlaybackPosition()), scroll: true)
    }

    /// 前の行 (上の矢印)。最初の行なら何もしない
    func previous() {
        ensureRows()
        perform(sequencer.previous(from: lineAtPlaybackPosition()), scroll: true)
    }

    /// いまの行をもう一度 (左の矢印・「もう一度聞く」)
    func replay() {
        ensureRows()
        perform(sequencer.replay(from: lineAtPlaybackPosition()), scroll: true)
    }

    /// 続けて流すのをやめる。鳴っている行も止める。いまの行は覚えておく
    func stop() {
        endSequence()
        if player.playingLineID != nil { player.stopLine() }
    }

    /// 再生 / 一時停止 (スペースキー・再生ボタン・メニュー)。続けて流している最中なら、それを終わりにする:
    /// 間を待っているあいだは止めるだけ (ふつうの再生を始めない)。行を流しているあいだは、再生の係がその場で止める
    func togglePlay() {
        if sequencer.phase == .waiting {
            stop()
            return
        }
        // 再生の係が onUserControl で知らせてくるので、続けて流すのはそこで終わりになる
        player.togglePlay()
    }

    /// 速さを変える
    func setRate(_ rate: Double) {
        var s = settings
        s.rate = rate
        settings = s
    }

    // MARK: 書き取り

    /// 書き取りの欄で Return を押した: 打った文を、いまの行の文と比べる (その行は一覧でも見せる)。
    /// もう比べてあり、そのあと打ち直していなければ、次の行へ進む (欄を空にして、次の行を流す)
    func submitDictation() {
        guard let id = currentLineID else { return }
        if dictation.result != nil {
            dictation.clear()
            next()
            return
        }
        guard let expected = text(of: id) else { return }
        dictation.setResult(DictationCheck.check(typed: dictation.typed, expected: expected))
        reveal.reveal(id)
    }

    // MARK: 行の文字を隠す

    /// 行の文字を隠すか (行の body から呼ぶ。隠し方と、隠す対象の行だけは、その行の見せたかを見る)
    func concealment(of item: TranscriptListItem) -> RowConcealment {
        let hide = hideMode
        guard HiddenText.canHide(hide, language: item.language) else { return .visible }
        let revealed = reveal.cell(for: item.id).isRevealed
        return RowConcealment(canHide: true, revealed: revealed,
                              hidesSource: HiddenText.hidesSource(hide, language: item.language, revealed: revealed),
                              hidesTranslation: HiddenText.hidesTranslation(hide, language: item.language,
                                                                            revealed: revealed))
    }

    // MARK: 再生の係と待ちからの知らせ

    private func playerFinishedLine(_ id: UUID) {
        guard let token = playToken else { return }
        playToken = nil
        record(.finished, id)
        // 鳴るはずの長さの 4 分の 1 にも届かずに終わった (音声の長さがまだわからず、行がファイルの外にあったなど):
        // 繰り返すと、すぐ終わる再生が続くだけなので、続けて流すのをやめる
        if let started = playStarted,
           ProcessInfo.processInfo.systemUptime - started.uptime < started.expected * 0.25 {
            playStarted = nil
            endSequence()
            return
        }
        playStarted = nil
        let before = sequencer.currentID
        perform(sequencer.lineFinished(id, token: token), scroll: false, scrollIfMovedFrom: before)
    }

    private func waitDidFinish(token: Int) {
        waitTask = nil
        let before = sequencer.currentID
        perform(sequencer.waitFinished(token: token), scroll: false, scrollIfMovedFrom: before)
    }

    /// 続けて流すのを終わりにする (再生の係には触らない: 再生ボタンなどで、係が自分で動かすとき)
    private func endSequence() {
        waitTask?.cancel()
        waitTask = nil
        playToken = nil
        playStarted = nil
        sequencer.stop()
        sync()
    }

    // MARK: 決まったことをする

    /// scroll: 始めた行が見えるように一覧を動かす (キー)。scrollIfMovedFrom: その行から別の行へ移ったときだけ動かす (自動で次へ)
    private func perform(_ action: LineSequencer.Action, scroll: Bool, scrollIfMovedFrom before: UUID? = nil) {
        switch action {
        case .nothing:
            break
        case .play(let line, let token):
            waitTask?.cancel()
            waitTask = nil
            playToken = token
            player.playLine(id: line.id, start: line.start, end: line.end)
            if player.playingLineID == line.id {
                record(.started, line.id)
                playStarted = (ProcessInfo.processInfo.systemUptime, expectedPlayLength(line))
                if scroll || (before != nil && before != line.id) { requestScroll(line.id) }
            } else {
                // 流せなかった (音声を開いていない・行がファイルの外): 待ち続けないよう、やめる
                playToken = nil
                sequencer.stop()
            }
        case .wait(let seconds, let token):
            playToken = nil
            waitTask?.cancel()
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            waitTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self?.waitDidFinish(token: token)
            }
        case .stop:
            waitTask?.cancel()
            waitTask = nil
            playToken = nil
            if player.playingLineID != nil { player.stopLine() }
        }
        sync()
    }

    /// 見えている状態を、決める係に合わせる (変わったものだけ書く: 書くと、見ている部品が描き直される)
    private func sync() {
        let active = sequencer.isActive ? sequencer.currentID : nil
        if activeLineID != active { activeLineID = active }
        let waiting = sequencer.phase == .waiting
        if isWaiting != waiting { isWaiting = waiting }
        if currentLineID != sequencer.currentID {
            currentLineID = sequencer.currentID
            dictation.clear()
        }
    }

    /// 1 行を流すのにかかるはずの秒 (前後に広げる分も入れ、ファイルの終わりで切り、いまの速さで割る)
    private func expectedPlayLength(_ line: PracticeLine) -> TimeInterval {
        let from = max(0, line.start - PlayerController.lineLeadIn)
        var to = max(line.end, line.start) + PlayerController.lineTail
        if player.duration > 0 { to = min(to, player.duration) }
        let rate = player.rate > 0 ? player.rate : 1.0
        return max(0, to - from) / rate
    }

    private func requestScroll(_ id: UUID) {
        scrollSerial += 1
        scrollRequest = ScrollRequest(id: id, serial: scrollSerial)
    }

    private func record(_ kind: Event.Kind, _ id: UUID) {
        events.append(Event(kind: kind, id: id, time: Date()))
        if events.count > 40 { events.removeFirst(events.count - 40) }
    }

    private func settingsDidChange(from old: PracticeSettings) {
        // 候補にない値は、近い候補に直す (直すと、もう一度ここへ来ることがある。何度来ても同じことをするだけ)
        let normalized = settings.normalized()
        if normalized != settings { settings = normalized }
        guard settings != old else { return }
        // 隠し方は保存するが、起動のたびに「隠さない」から始める
        UserDefaults.standard.set(settings.jsonString(), forKey: Self.settingsKey)
        if player.rate != settings.rate { player.rate = settings.rate }
        sequencer.update(settings: settings)
        if hideMode != settings.hide {
            hideMode = settings.hide
            reveal.reset(forget: false)
        }
    }

    // MARK: 画面の重さの確認 (--selftest-ui-load) だけで使う

    /// 行を流さずに、いまの行にする (書き取りの欄の絵のため)
    func selfTestSetCurrentLine(_ id: UUID) {
        stop()
        ensureRows()
        _ = sequencer.start(id)
        sequencer.stop()
        sync()
    }

    /// はじめの状態に戻す (いまの行・見せた行・書き取りを忘れる。設定はそのまま)
    func selfTestForget() {
        stop()
        sequencer.reset()
        reveal.reset(forget: true)
        dictation.clear()
        sync()
    }
}

/// 「この行を見る」で見せた行。行は自分の RevealCell (行の id ごと) だけを見るので、1 行を見せても、描き直すのはその行だけ
/// (RowHighlight と同じしくみ)
@MainActor
@Observable
final class RowReveal {
    @ObservationIgnored private var cells: [UUID: RevealCell] = [:]

    /// 行の Cell (無ければ作る)。行の body から呼ぶ (足しても、何も描き直さない)
    func cell(for id: UUID) -> RevealCell {
        if let cell = cells[id] { return cell }
        let cell = RevealCell()
        cells[id] = cell
        return cell
    }

    func reveal(_ id: UUID) {
        let cell = cell(for: id)
        if !cell.isRevealed { cell.isRevealed = true }
    }

    func toggle(_ id: UUID) {
        let cell = cell(for: id)
        cell.isRevealed.toggle()
    }

    /// 見せた行をすべて隠し直す。forget なら Cell も捨てる (別のジョブの一覧になったとき)
    func reset(forget: Bool) {
        for cell in cells.values where cell.isRevealed {
            cell.isRevealed = false
        }
        if forget { cells.removeAll() }
    }
}

/// 行 1 つ分の「見せた」の印
@MainActor
@Observable
final class RevealCell {
    fileprivate(set) var isRevealed = false
}

/// 書き取りの欄の中身。打つたびに変わるので、欄 (DictationBar) だけが見る
@MainActor
@Observable
final class DictationState {
    /// 打っている文。打ち直すと、答え合わせの結果は消える
    var typed = "" {
        didSet {
            if typed != oldValue, result != nil { result = nil }
        }
    }
    /// 答え合わせの結果 (まだ比べていなければ nil)
    private(set) var result: DictationCheck.Result?

    func setResult(_ result: DictationCheck.Result) {
        self.result = result
    }

    /// 欄を空にする (いまの行が変わったとき・次の行へ進むとき)
    func clear() {
        if result != nil { result = nil }
        if !typed.isEmpty { typed = "" }
    }
}
