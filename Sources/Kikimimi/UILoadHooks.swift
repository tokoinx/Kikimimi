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

    /// 消えた一覧が、口を外す。ほかの一覧 (あとから現れた、新しいジョブの一覧) が入れたものは外さない
    static func unregister(owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        self.owner = nil
        scrollList = nil
        setFollowing = nil
        isFollowing = nil
    }
}
