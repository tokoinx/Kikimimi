// 結果の一覧 (数千行) の入れ物 TranscriptListView と、その中身 TranscriptRows。
// 一覧が固まらないための 4 つの決まり (CLAUDE.md の「結果の一覧」) を、TranscriptListRulesTests が
// このファイルの書き方で見る。よく変わる状態を見る部品は、TranscriptListSupport.swift に置く。

import AppKit
import KikimimiCore
import SwiftUI

/// 本文の一覧。ジョブごとに作り直す (呼ぶ側で .id(job.id) を付ける。理由は TranscriptDetailView.transcriptColumn)。
/// 下の @State (行の色・追いかけるか) も、ジョブを選ぶたびに新しくなる。
/// この body は、行が変わる (区間が増えた・検索・表示の切り替え) ときだけ動かす:
/// 数千行の一覧では、body が動くたびに ForEach が数千の id を比べ直し、一覧を更新する (GitHub の実行機で、3000 行に 10 行を足す 1 回が 110〜180 ms)。
/// そのため、ここでは再生の様子 (1 行だけ再生している行・再生位置・再生中か) と、追いかけるか (ListFollow.isOn) を見ない:
/// - 行の色 (1 行だけ再生している行・いまの位置の行) は、行ごとに RowHighlight の RowTintCell を見る。
///   色が変わったときに描き直すのは、色が変わる、画面に出ている行だけ (画面の外の行は、LazyVStack が作っていない)。
/// - 再生位置を見て、いまの行を探し、行の色を変え、いまの行や一覧の終わりへ動かすのは、一覧の外の見えない部品
///   (CurrentLineTracker)。「末尾へ」のボタンも、一覧の外の部品 (FollowButton) が ListFollow.isOn を見る。
/// - 練習の様子 (続けて流している行・隠し方・見せた行・書き取り) も見ない。行が自分で、練習の小さな入れ物
///   (PracticeController.hideMode・RowReveal の RevealCell) を見る。一覧の行を練習に知らせるのは、見えない部品
///   (PracticeRowsFeeder) で、一覧の行が変わったときだけ動く。
///
/// 文字起こし中は、一覧の終わりを追いかける (新しい行が出たら、いちばん下へ動かす)。ただし:
/// - 使う人が一覧の上でホイールやトラックパッドで上へ動かす、一覧の中を押す (行もスクロールバーも、押した瞬間に)、
///   キーボードで上へ動かす (Page Up・Home・上矢印)、行を押して 1 行だけ再生する
///   と、追いかけるのをやめる (上の行を読んでいる・押そうとしているのに、下へ飛ばさない)。
/// - 一覧の終わり (見えない印の行) が見えたら、また追いかける。右下の「末尾へ」でも戻せる。
/// - 再生しているあいだ (1 行だけでも、ふつうの再生でも) は、追いかけていても動かさない。
/// macOS 14 の SwiftUI の ScrollView には、いまどこまで動かしたかを知る手段が無いので、この決まりにしている
///
/// 入れ物は ScrollView の中の LazyVStack。SwiftUI の List は数千行で重かった: GitHub の Mac で 3000 行のとき、
/// 文字起こし中にメインスレッドが 28〜30% ふさがり、新しい行の 1 回分に 0.33〜0.40 秒かかった
/// (LazyVStack では 4.5〜12.4%、0.11〜0.18 秒)。
/// 行の背景・区切りの線・行の余白・一覧の背景の色は、行の側 (PlayableRow) と rows で付ける
struct TranscriptListView: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let items: [TranscriptListItem]
    let bilingual: Bool
    /// その結果の訳す先の言語 (めったに変わらない値。行の説明の文と、練習の「隠す」に使う)
    let target: String
    let emptyMessage: String
    /// 行の色 (1 行だけ再生している行・いまの位置の行)。行と CurrentLineTracker が使い、この body では中を見ない
    @State private var highlight = RowHighlight()
    /// 文字起こし中に、一覧の終わりを追いかけるか。この body では中を見ない (見ると、一覧の中を押すたびに body が動く)。
    /// 一覧ごとに 1 つ (始めは追いかける)。イベントの見張りも、この一覧の ListFollow が自分の分だけを入れ、自分の分だけを外す
    @State private var follow = ListFollow()

    var body: some View {
        // アプリの確認だけが使う: この body が動いた回数を数える (ふだんは Bool を 1 つ見るだけ)
        let _ = UILoadHooks.listBodyRan()
        let translating = job.postState.task == .translate || job.postQueue.contains(.translate)
        let canPlay = model.canPlayLines(of: job)
        let showTimestamps = model.showTimestamps
        let highlightText = model.searchText
        let running = job.status == .running
        // 中を見ずに、入れ物そのものを渡す (行・見えない部品・ボタンが、それぞれ要るものだけを見る)
        let highlight = self.highlight
        let follow = self.follow
        // 一覧の大きさは、外から与えられた大きさに決める (GeometryReader は、与えられた大きさをそのまま取り、
        // 中の部品に望みの大きさを尋ねない)。親の部品が ScrollView に望みの大きさを尋ねると、ScrollView は中身を
        // すべて測るので、LazyVStack が行をすべて作る: GitHub の Mac で 3000 行のとき、終わったジョブを選ぶ 1 回が
        // 0.13〜1.0 秒から 5〜21 秒になった (結果の画面を HSplitView に入れたとき)。
        // 前に 1 度だけ、選んだ 1 回が 17.9 秒になったのは別の理由で、一覧がジョブをまたいで使い回され、
        // 前のジョブで下まで動かした位置のまま並べたためと見ている (いまはジョブごとに作り直す: transcriptColumn)。
        // 大きさが変わると (ウインドウやメモの欄の幅を変えると) この中が動くが、行の中身は TranscriptRows に分けてあり、
        // 渡すものが変わらないので、行を作り直さない
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    TranscriptRows(job: job, items: items, bilingual: bilingual,
                                   targetName: TranslationTarget.displayName(for: target), emptyMessage: emptyMessage,
                                   canPlay: canPlay, translating: translating, showTimestamps: showTimestamps,
                                   highlightText: highlightText, running: running, highlight: highlight, follow: follow)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(Color(nsColor: .controlBackgroundColor))
                .background(CurrentLineTracker(job: job, items: items, highlight: highlight, follow: follow, proxy: proxy))
                // 練習の行を、一覧の行に合わせる (一覧が変わったときだけ知らせる)
                .background(PracticeRowsFeeder(job: job, items: items, bilingual: bilingual, target: target))
                .background(
                    GeometryReader { geometry in
                        // ホイールの操作が、この一覧の上かを見分けるための、一覧の位置 (ウインドウの中の横の範囲)
                        Color.clear
                            .onAppear { follow.frame = geometry.frame(in: .global) }
                            .onChange(of: geometry.frame(in: .global)) { _, frame in follow.frame = frame }
                    }
                )
                .overlay(alignment: .bottomTrailing) {
                    FollowButton(follow: follow, running: running, lastID: items.last?.id, proxy: proxy)
                }
                .onAppear {
                    follow.install()
                    follow.registerSelfTestHooks(proxy: proxy)
                }
                .onDisappear {
                    follow.remove()
                    follow.unregisterSelfTestHooks()
                }
            }
        }
    }
}

/// 一覧の中身: 行、行が無いときの知らせ、一覧の終わりの印 (TranscriptListView の ScrollView の中)。
/// 一覧の大きさが変わっても、渡すものは変わらないので、この body は動かない (動くと、ForEach が数千の id を比べ直す)。
/// 行に .id() は付けない (scrollTo は ForEach の id で動くので、要らない)
private struct TranscriptRows: View {
    let job: Job
    let items: [TranscriptListItem]
    let bilingual: Bool
    /// 訳す先の言語の名前 (行の「訳」と右クリックの説明の文に使う)
    let targetName: String
    let emptyMessage: String
    let canPlay: Bool
    let translating: Bool
    let showTimestamps: Bool
    let highlightText: String
    let running: Bool
    let highlight: RowHighlight
    let follow: ListFollow

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            rows
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var rows: some View {
        let lastID = items.last?.id
        ForEach(items) { item in
            // 行と、その下の区切りの線 (行の背景の外に、行の余白と同じだけ内側へ寄せて引く。最後の行の下には引かない)
            VStack(alignment: .leading, spacing: 0) {
                PlayableRow(item: item, job: job, canPlay: canPlay, highlight: highlight, targetName: targetName,
                            bilingual: bilingual) {
                    if bilingual {
                        BilingualRow(item: item, isTranslating: translating, showTimestamp: showTimestamps,
                                     highlight: highlightText, job: job, targetName: targetName)
                    } else {
                        SegmentRow(item: item, showTimestamp: showTimestamps,
                                   highlight: highlightText, job: job, targetName: targetName)
                    }
                }
                if item.id != lastID {
                    Divider()
                        .padding(.horizontal, RowMetrics.horizontal)
                }
            }
        }
        if items.isEmpty {
            Text(emptyMessage)
                .foregroundStyle(.secondary)
                .padding(.horizontal, RowMetrics.horizontal)
                .padding(.vertical, RowMetrics.vertical)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if running {
            // 一覧の終わりの印 (見えない行)。これが見えたら、使う人は一覧の終わりにいる: また追いかける。
            // (追いかけるかを書くのは ListFollow.followAgainOnNextTurn。一覧の側では読まない)
            Color.clear
                .frame(height: 1)
                .accessibilityHidden(true)
                .onAppear { follow.followAgainOnNextTurn() }
        }
    }
}
