// 結果の一覧を支える部品: 「末尾へ」のボタン、追いかけるか (ListFollow)、行の色 (RowHighlight)、
// 再生の様子を見る見えない部品 (CurrentLineTracker)、練習に一覧の行を知らせる部品 (PracticeRowsFeeder)。
// よく変わる状態 (再生位置・練習・追いかけるか) は、一覧の body でなく、ここの部品が見る。

import AppKit
import KikimimiCore
import SwiftUI

/// 一覧の右下の「末尾へ」。文字起こし中に、一覧の終わりを追いかけていないときだけ出す。
/// ListFollow.isOn を見るのは、この部品だけ (一覧の body では見ない)
struct FollowButton: View {
    let follow: ListFollow
    let running: Bool
    let lastID: UUID?
    let proxy: ScrollViewProxy

    var body: some View {
        if running && !follow.isOn {
            Button {
                follow.isOn = true
                if let lastID { proxy.scrollTo(lastID, anchor: .bottom) }
            } label: {
                Label(L("To the end"), systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(L("Go to the end of the list and follow the transcription as it continues"))
            .padding(12)
        }
    }
}

/// 文字起こし中に、一覧の終わりを追いかけるか (TranscriptListView)。
/// 一覧の上でホイール・トラックパッドを上へ動かしたとき、一覧の中を押したとき (行もスクロールバーも、押した瞬間に)、
/// キーボードで上へ動かしたとき (Page Up・Home・上矢印) に、追いかけるのをやめる
/// (macOS 14 の SwiftUI にはスクロールの操作を知る手段が無いので、アプリに届くイベントを見る。イベントは止めない)。
/// 一覧ごとに 1 つ (一覧はジョブごとに作り直すので、ジョブを選ぶたびに新しくなり、始めは追いかける)。
/// イベントの見張りは、それぞれが自分の分 (monitor) だけを持ち、remove はそれだけを外す: ジョブを選んで、古い一覧の
/// remove が新しい一覧の install よりあとに来ても、新しい一覧の見張りは外れない
@MainActor
@Observable
final class ListFollow {
    var isOn = true
    /// 一覧の位置 (SwiftUI の global: ウインドウの中、左上から下へ)。まだわからなければ空
    @ObservationIgnored var frame: CGRect = .zero
    @ObservationIgnored private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown],
                                                   handler: Self.handler(follow: self))
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// 一覧が現れたときに呼ぶ (TranscriptListView の onAppear)。確認の最中だけ、確認から一覧を動かす口を入れる。
    /// 追いかけるか (isOn) を読み書きする文は、ここに置く (一覧のファイルには置かない)
    func registerSelfTestHooks(proxy: ScrollViewProxy) {
        // 画面の重さの確認 (--selftest-ui-load --screenshots) が、絵を撮る前に一覧を動かす口。
        // ジョブを選ぶと一覧が作り直され、新しい一覧の onAppear と古い一覧の onDisappear は、どちらが先にも来る:
        // 入れるときは、いつも新しい一覧のものに入れ替え、外すときは、自分が入れたものが残っているときだけ外す
        if UILoadHooks.isActive {
            UILoadHooks.register(owner: ObjectIdentifier(self), scrollList: { id, edge in
                proxy.scrollTo(id, anchor: edge == .top ? .top : .bottom)
            }, setFollowing: { on in
                if self.isOn != on { self.isOn = on }
            }, isFollowing: { self.isOn })
        }
    }

    /// 一覧が消えたときに呼ぶ (TranscriptListView の onDisappear)。上で入れた口を外す
    func unregisterSelfTestHooks() {
        if UILoadHooks.isActive { UILoadHooks.unregister(owner: ObjectIdentifier(self)) }
    }

    /// 一覧の終わりの印 (TranscriptRows の見えない行) が見えたときに呼ぶ: また追いかける。
    func followAgainOnNextTurn() {
        // LazyVStack の onAppear は、一覧を並べている最中に呼ばれることがあり、見える少し前
        // (先に作る範囲に入ったとき) にも呼ばれる。並べている最中に状態を変えると、その場でまた並べ直すことに
        // なるので、次の回に変える。同じ値でも書くと見ている部品が描き直されるので、変わるときだけ書く
        Task { @MainActor in
            if !isOn { isOn = true }
        }
    }

    /// 見張りは、この ListFollow を弱く持つ (外し損ねても、消えた一覧の ListFollow を残さない。消えたあとのイベントでは何もしない)
    nonisolated private static func handler(follow: ListFollow) -> (NSEvent) -> NSEvent? {
        return { [weak follow] event in
            MainActor.assumeIsolated { follow?.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard isOn, let window = event.window, MainWindow.all().contains(where: { $0 === window }) else { return }
        switch event.type {
        case .scrollWheel:
            // 一覧の横の範囲の外 (左のジョブの一覧など) の操作は見ない (位置がわからないうちは、どこでも一覧の操作とみなす)
            let x = event.locationInWindow.x
            if frame.width > 0, x < frame.minX || x > frame.maxX { return }
            // 上へ (前の行のほうへ) 動かした
            if event.scrollingDeltaY > 0 { isOn = false }
        case .leftMouseDown:
            // 一覧の中を押した (行・スクロールバー): 離すまでに行が増えても、押したところを動かさないよう、押した瞬間にやめる。
            // 終わりの印の行と「末尾へ」で、また追いかける
            if isInList(event, in: window) { isOn = false }
        case .keyDown:
            // キーボードで上へ動かした。検索欄などで文字を打っているときは見ない
            guard window.isKeyWindow, !isTextInput(window.firstResponder) else { return }
            guard let key = event.specialKey, key == .pageUp || key == .home || key == .upArrow else { return }
            // 左のジョブの一覧などで押したキーは見ない (位置がわからないうちは、どこでも一覧の操作とみなす)
            if frame.width > 0, let view = window.firstResponder as? NSView {
                let rect = view.convert(view.bounds, to: nil)
                if rect.midX < frame.minX || rect.midX > frame.maxX { return }
            }
            isOn = false
        default:
            break
        }
    }

    /// 押したところが一覧の中か (位置がわからないうちは、一覧の中とみなす)
    private func isInList(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return true }
        guard let content = window.contentView else { return true }
        // ウインドウの座標 (左下から上へ) を、SwiftUI の global (内容の左上から下へ) にそろえる
        let local = content.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
        return frame.contains(point)
    }

    /// 文字を打つところ (テキストの欄、文字の部品。編集中の欄の NSTextView も NSText) か
    private func isTextInput(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextField
    }
}

/// 一覧の行の色: 1 行だけ再生している行と、ふつうの再生でいまの位置にある行。
/// 行は自分の RowTintCell (行の id ごと) だけを見る。色が変わるときは、色が変わる行の Cell だけを書き換えるので、
/// 描き直されるのは、その行だけ (Observation では、読んだ部品だけが描き直される。画面の外の行は LazyVStack が作っていないので、
/// Cell はあっても描き直すものが無い)。一覧の body はこれを見ない。
/// 一覧ごとに 1 つ (一覧はジョブごとに作り直すので、別のジョブを選ぶと、Cell の無い新しいものになる。
/// いまの様子は、CurrentLineTracker が現れたときに渡す)
@MainActor
@Observable
final class RowHighlight {
    /// CurrentLineTracker が見つけた、いまの様子
    struct Snapshot: Equatable {
        var playing: UUID?
        var current: UUID?
    }

    /// 1 行だけを再生している行 (練習で続けて流している行 PracticeController.activeLineID の写し。間を待っているあいだも入る)。
    /// 次の currentID とともに、見張らない (行の Cell を作るときに読むので、見張ると、Cell を作った行の body がすべて
    /// これを見ることになり、変わるたびに、それらの行がみな描き直される。行は自分の RowTintCell だけを見る)
    @ObservationIgnored private(set) var playingID: UUID?
    /// ふつうの再生で、いまの位置にある行
    @ObservationIgnored private(set) var currentID: UUID?
    /// 行の id ごとの Cell。行が初めて作られたときに足す (数は、この一覧で画面に出したことのある行の数まで)
    @ObservationIgnored private var cells: [UUID: RowTintCell] = [:]
    /// update を呼んだ回数 (CurrentLineTracker が、遅れて渡す様子が古くないかを見る)
    @ObservationIgnored private(set) var updates = 0

    /// 行の Cell (無ければ、いまの様子の色で作る)。行の body から呼ぶ (足しても、何も描き直さない)
    func cell(for id: UUID) -> RowTintCell {
        if let cell = cells[id] { return cell }
        let cell = RowTintCell(tint: tint(of: id))
        cells[id] = cell
        return cell
    }

    /// 様子が変わった: 前とあとで色が変わる行 (多くて 4 つ) の Cell だけを書き換える
    func update(_ state: Snapshot) {
        updates += 1
        guard state.playing != playingID || state.current != currentID else { return }
        let touched = [playingID, currentID, state.playing, state.current].compactMap { $0 }
        playingID = state.playing
        currentID = state.current
        for id in Set(touched) {
            guard let cell = cells[id] else { continue }
            let tint = tint(of: id)
            if cell.tint != tint { cell.tint = tint }
        }
    }

    private func tint(of id: UUID) -> RowTint {
        if id == playingID { return .playing }
        // 1 行だけを再生しているあいだは、その行だけを色付けする (再生位置の色と重ねない)
        if playingID == nil, id == currentID { return .current }
        return .plain
    }
}

/// 行の色
enum RowTint: Equatable {
    /// 色を付けない (マウスを載せたときの色だけ)
    case plain
    /// ふつうの再生で、いまの位置がこの行にある
    case current
    /// この行だけを再生している
    case playing
}

/// 行 1 つ分の色 (RowHighlight が持つ)。行の body はこれだけを見る
@MainActor
@Observable
final class RowTintCell {
    fileprivate(set) var tint: RowTint

    init(tint: RowTint) {
        self.tint = tint
    }
}

/// 再生の様子 (再生位置は 0.2 秒ごとに変わる) を見るのは、一覧の外の、この見えない部品だけ。
/// - いまの位置にある行を、行の始まりの時刻で二分探索して探し、1 行だけ再生している行とともに RowHighlight に渡す
///   (色が変わる行だけが描き直される。一覧の body は動かない)。
/// - ふつうの再生で、いまの行が変わったら、その行が見えるように動かす (1 行だけの再生では動かさない)。
/// - 文字起こし中に、行を押して 1 行だけ再生したら、一覧の終わりを追いかけるのをやめる。
/// - 文字起こし中に行が増えたら、追いかけていて、再生していなければ、一覧の終わりへ動かす。
/// - 一覧が現れたとき (一覧はジョブごとに作り直すので、ジョブを選んだとき): 文字起こし中のジョブなら、一覧の終わりへ動かす
///   (追いかけるのは、新しい一覧の ListFollow が始めから isOn なので、そのまま続く)。再生していれば、動かさない
///   (そのときは、ふつうの再生でいまの行がこのジョブにあれば、その行が見えるように動かす)。
/// 一覧を動かす (scrollTo) のは、どれも次の回にする: 一覧を並べている最中に動かすと、
/// その場でまた並べ直すことになる
struct CurrentLineTracker: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let items: [TranscriptListItem]
    let highlight: RowHighlight
    let follow: ListFollow
    let proxy: ScrollViewProxy

    var body: some View {
        let player = model.player
        let practice = model.practice
        // 「再生中」の行は、練習の続きの行 (間を待っているあいだも)。練習を通さない 1 行だけの再生 (確認用) なら、その行
        let state = RowHighlight.Snapshot(playing: practice.activeLineID ?? player.playingLineID, current: currentLine())
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                // 一覧と同時に現れる (一覧が行を作っている最中かもしれない): 行の色は次の回に変える。
                // それまでに様子が変わって (onChange で) 渡し直していれば、古い様子では上書きしない
                let updates = highlight.updates
                // 文字起こし中のジョブを選んだ: 一覧の終わりから追いかける (一覧が使い回されていたころは、
                // .onChange(of: job.id) が追いかけるのを戻し、行の数が変わったのを見て終わりへ動かしていた。
                // いまは一覧がジョブごとに新しく、始めは一覧の始めにいるので、ここで終わりへ動かす)
                let last = job.status == .running ? items.last?.id : nil
                // ふつうの再生で、いまの行がこのジョブにある (同じ音声のジョブ): その行が見えるように動かす
                let current = player.isPlaying && player.playingLineID == nil ? state.current : nil
                Task { @MainActor in
                    if highlight.updates == updates { highlight.update(state) }
                    if let last, follow.isOn, !player.isPlaying {
                        proxy.scrollTo(last, anchor: .bottom)
                    } else if let current, player.isPlaying, player.playingLineID == nil {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
            .onChange(of: state) { _, new in
                highlight.update(new)
            }
            .onChange(of: state.playing) { _, id in
                // 行を押して 1 行だけ再生した: 押した行のあたりを見ているので、追いかけるのをやめる
                if id != nil, job.status == .running, follow.isOn { follow.isOn = false }
            }
            .onChange(of: state.current) { _, id in
                // 1 行だけの再生では、押した行が見えているので動かさない
                guard let id, player.isPlaying, player.playingLineID == nil else { return }
                Task { @MainActor in
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .onChange(of: practice.scrollRequest) { _, request in
                // キー (上下・左の矢印) や「自動で次へ」で始めた行が見えるように、少しだけ動かす (見えていれば動かさない)。
                // 行を押して始めた行は見えているので、頼まれない
                guard let request else { return }
                Task { @MainActor in
                    proxy.scrollTo(request.id)
                }
            }
            .onChange(of: items.count) { _, _ in
                guard job.status == .running, follow.isOn, !player.isPlaying, let last = items.last else { return }
                let id = last.id
                Task { @MainActor in
                    guard follow.isOn, !player.isPlaying else { return }
                    // 確認の最中だけ、呼び出しが戻るまでの時間を測る (ふだんの起動では時刻を取らない)
                    let started = UILoadHooks.timingStart()
                    proxy.scrollTo(id, anchor: .bottom)
                    UILoadHooks.scrollToEnded(started)
                }
            }
    }

    private func currentLine() -> UUID? {
        let player = model.player
        guard player.url != nil, player.url == job.url else { return nil }
        let t = player.currentTime
        // 行は始まりの時刻の順に並んでいる: t までに始まった最後の行
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].start <= t { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let item = items[low - 1]
        return t < max(item.end, item.start + 0.3) ? item.id : nil
    }
}

/// 一覧の行が変わったら、練習 (PracticeController) に知らせる見えない部品。練習は、次に要るときに行を作り直す。
/// 練習の様子は見ないので、この body は、一覧の body が動いたときだけ動く
struct PracticeRowsFeeder: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let items: [TranscriptListItem]
    let bilingual: Bool
    /// 訳す先の言語 (練習は、この言語の行を隠さない)
    let target: String

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                model.practice.rowsChanged(job: job, bilingual: bilingual, target: target)
            }
            .onChange(of: items) { _, _ in
                model.practice.rowsChanged(job: job, bilingual: bilingual, target: target)
            }
            .onChange(of: bilingual) { _, on in
                model.practice.rowsChanged(job: job, bilingual: on, target: target)
            }
            .onChange(of: target) { _, code in
                model.practice.rowsChanged(job: job, bilingual: bilingual, target: code)
            }
    }
}
