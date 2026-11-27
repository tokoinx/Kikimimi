// 画面の重さの確認から、結果の一覧を動かすための口。

import Foundation

/// 画面の重さの確認から、結果の一覧を動かすための口。確認のあいだだけ、一覧 (TranscriptListView) が現れたときに入れる
/// (ScrollViewProxy と ListFollow は一覧の中にしか無い)。ふだんの起動では、どれも nil のまま。
/// 一覧はジョブごとに作り直すので、ジョブを選ぶと、新しい一覧の register と古い一覧の unregister が、どちらが先にも来る:
/// register はいつも入れ替え (あとから現れた一覧のものになる)、unregister は、入れた一覧のものが残っているときだけ外す
@MainActor
enum UILoadHooks {
    /// 行のどちらの端に合わせて動かすか
    enum Edge {
        case top
        case bottom
    }

    /// 確認の最中か (一覧は、このときだけ下の口を入れる)
    static var isActive = false
    /// 一覧を、その行 (行の id) が上の端か下の端に来るように動かす
    static var scrollList: (@MainActor (UUID, Edge) -> Void)?
    /// 一覧の終わりを追いかけるか (ListFollow.isOn) を変える
    static var setFollowing: (@MainActor (Bool) -> Void)?
    /// 一覧の終わりを追いかけているか
    static var isFollowing: (@MainActor () -> Bool)?
    /// 一覧が作った行の数 (PlayableRow を作った回数。確認の最中だけ数える)。一覧が終わりへ飛ぶと、
    /// LazyVStack はすべての行を作る (1 つ 0.1 ms ほど) ので、数千にもなる。重さは次の rowBodies で見る
    static var rowsBuilt = 0
    /// 一覧が body を動かした行の数 (PlayableRow.body の回数。確認の最中だけ数える)。本当に並べた行で、手間はこちら
    static var rowBodies = 0
    /// マウスが一覧の行に載った・行から出た回数 (PlayableRow.onHover の回数。確認の最中だけ数える)。
    /// 行は、マウスが載ると色を変え、body がまた動く。本物のマウスが一覧の上に在ると、一覧が動くたびに増える
    static var rowHoverChanges = 0
    /// CurrentLineTracker が、行が増えた時に一覧の終わりへ動かした (proxy.scrollTo) 回数と、呼び出しが戻るまでの
    /// 時間の合計・いちばん長い 1 回 (uptime のナノ秒。確認の最中だけ数える)
    static var scrollToCalls = 0
    static var scrollToNanos: UInt64 = 0
    static var scrollToLongestNanos: UInt64 = 0
    /// AppModel.applyLive (まとめた区間を足して job.transcript に書き戻す) の回数と、時間の合計・最後の 1 回
    /// (uptime のナノ秒。確認の最中だけ数える)
    static var applyCalls = 0
    static var applyNanos: UInt64 = 0
    static var lastApplyNanos: UInt64 = 0
    /// CurrentLineTracker が、行が増えた時に一覧の終わりへ動かす前に待つミリ秒 (確認の参考の段だけで変える。
    /// ふだんの起動と、測る段階では 0: 待たない)
    static var followScrollDelayMs = 0
    /// いまの口を入れた一覧 (その一覧の ListFollow)
    private static var owner: ObjectIdentifier?

    /// 現れた一覧が、口を入れる (前の一覧のものは入れ替える)
    static func register(owner: ObjectIdentifier,
                         scrollList: @escaping @MainActor (UUID, Edge) -> Void,
                         setFollowing: @escaping @MainActor (Bool) -> Void,
                         isFollowing: @escaping @MainActor () -> Bool) {
        self.owner = owner
        self.scrollList = scrollList
        self.setFollowing = setFollowing
        self.isFollowing = isFollowing
    }

    /// 測る口の始め: 確認の最中なら、いまの時刻 (uptime のナノ秒)。ふだんの起動では 0 (時刻を取らない)
    static func timingStart() -> UInt64 {
        isActive ? DispatchTime.now().uptimeNanoseconds : 0
    }

    /// CurrentLineTracker の scrollTo が戻った。started は timingStart() の値 (0 なら何もしない)
    static func scrollToEnded(_ started: UInt64) {
        guard started > 0 else { return }
        let took = DispatchTime.now().uptimeNanoseconds &- started
        scrollToCalls += 1
        scrollToNanos &+= took
        scrollToLongestNanos = max(scrollToLongestNanos, took)
    }

    /// AppModel.applyLive が、足して書き戻し終えた。started は timingStart() の値 (0 なら何もしない)
    static func applyEnded(_ started: UInt64) {
        guard started > 0 else { return }
        let took = DispatchTime.now().uptimeNanoseconds &- started
        applyCalls += 1
        applyNanos &+= took
        lastApplyNanos = took
    }

    /// 消えた一覧が、口を外す。ほかの一覧 (あとから現れた、新しいジョブの一覧) が入れたものは外さない
    static func unregister(owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        self.owner = nil
        scrollList = nil
        setFollowing = nil
        isFollowing = nil
    }
}
