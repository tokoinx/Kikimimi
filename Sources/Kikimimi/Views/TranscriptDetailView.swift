import AppKit
import KikimimiCore
import SwiftUI

struct TranscriptDetailView: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var cache = TranscriptRowCache()
    /// メモの欄と一覧を並べている欄の幅 (NotesSidebar だけが見る。この body では中を見ない)
    @State private var notesSpace = NotesSpace()

    var body: some View {
        // 翻訳の状況・言語の名前・一覧の行は、文字起こしが変わったときだけ作り直す (長い録音では区間が数千あるため。
        // 画面は、進み具合や検索欄の入力でも描き直される)。文字起こし中に区間が末尾に増えたときは、増えた分だけを足す
        let summary = job.transcript.map { cache.summary(of: $0, job: job.id, done: job.status == .done) }
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

            if job.status == .running || job.status == .queued {
                JobProgressBar(job: job)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            if job.status == .failed {
                Label(job.error ?? "エラー", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            if job.status == .cancelled {
                Label("中止しました", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            if job.url != nil {
                PlayerBar()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            } else if job.status == .done, let path = job.sourcePath {
                MissingAudioNotice(job: job, path: path)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            PostProcessBar(job: job)

            if let transcript = job.transcript, let summary {
                let stats = summary.stats
                let bilingual = model.isBilingual(stats, in: job)
                if job.status == .done, let from = job.autoMixedFrom, !job.autoMixedNoticeDismissed {
                    AutoMixedLanguageNotice(job: job, from: from)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                if job.status == .done, job.languageCode == "ja", job.url != nil, !job.mixedSuggestionDismissed,
                   job.allowsAutoMixed, summary.spokenLanguages.isEmpty, stats.isMainlyForeign {
                    MixedLanguageSuggestion(job: job)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                if job.status == .done, !transcript.segments.isEmpty, !model.isLLMInstalled, !model.llmBannerDismissed,
                   (model.autoTranslate && stats.isMainlyForeign) || model.autoAudit {
                    LLMNeededBanner(wantsTranslation: stats.isMainlyForeign)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                controls(transcript, stats)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                Divider()
                let items = cache.items(of: transcript, job: job.id, done: job.status == .done,
                                        bilingual: bilingual, query: model.searchText)
                // 右にメモの欄 (「メモ」を入れたときだけ)。メモの中身を見るのは NotesPane だけ (打つたびに一覧を作り直さない)。
                // メモの欄の幅を見るのも NotesSidebar だけ (区切りを動かしても、この body は動かない)。
                // 一覧は、メモを出しても消しても同じ場所に置く (置き場所を変えると一覧が作り直され、読んでいた位置が始めに戻る)。
                // HSplitView は使わない: 下の NSSplitView が、中の部品に望みの大きさを尋ね、尋ねられた ScrollView は
                // 中身をすべて測るので、LazyVStack が 3000 行をすべて作った (GitHub の Mac で、終わったジョブを 2 回目に選ぶと
                // 5〜21 秒。HSplitView の前は 0.13〜1.0 秒)
                let space = notesSpace
                HStack(spacing: 0) {
                    transcriptColumn(items: items, bilingual: bilingual, languageLabel: summary.languageLabel)
                        .frame(minWidth: CGFloat(NotesSidebar.listMinWidth), maxWidth: .infinity, maxHeight: .infinity)
                    if model.showNotes {
                        NotesSidebar(job: job, space: space)
                    }
                }
                .background(
                    GeometryReader { geometry in
                        // 並べている欄の幅 (メモの欄を広げても、一覧に 360 pt を残すため)。見るのは NotesSidebar だけ
                        Color.clear
                            .onAppear { space.width = Double(geometry.size.width) }
                            .onChange(of: geometry.size.width) { _, width in space.width = Double(width) }
                    }
                )
            } else {
                Spacer()
            }
        }
        .navigationTitle(job.name)
        .navigationSubtitle(subtitle(summary))
    }

    /// 対訳の見出しと一覧
    @ViewBuilder
    private func transcriptColumn(items: [TranscriptListItem], bilingual: Bool, languageLabel: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if bilingual {
                BilingualHeader(label: languageLabel, showTimestamp: model.showTimestamps,
                                showPlayMark: model.canPlayLines(of: job))
                Divider()
            }
            // 一覧はジョブごとに作り直す (.id): 別のジョブを選んだら、新しい ScrollView が一覧の始めから出て、
            // 一覧の状態 (追いかけるか・行の色) も新しくなる。この結果の画面は、別のジョブを選んでも作り直されず使い回されるので、
            // .id が無いと ScrollView が前のジョブで動かした位置 (ずっと下) を残したまま中身だけが入れ替わり、LazyVStack が
            // その位置まで数千行を本当に並べた (GitHub の Mac で 3000 行のとき、文字起こし中のジョブを終わりまで出したあとに
            // 終わったジョブを選ぶ 1 回が 16.8 秒。ふだんは 0.2〜1.1 秒)
            TranscriptListView(job: job, items: items, bilingual: bilingual, emptyMessage: emptyMessage)
                .id(job.id)
            // 一覧の下の書き取りの欄 (「書き取りの欄を出す」のときだけ)。出すかどうかと中身を見るのは、この部品だけ
            // (この body が見ると、打つたびや設定を変えるたびに、一覧まで作り直すことになる)
            DictationSlot(job: job)
        }
    }

    // MARK: ヘッダ
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(job.name)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let t = job.transcript, job.status == .done {
                stat("長さ", TimeFormat.short(t.duration))
                stat("処理", String(format: "%.1f 秒", t.elapsed))
                if let rtf = t.realTimeFactor, rtf > 0 {
                    let speed = 1 / rtf
                    stat("速度", speed >= 10 ? "\(Int(speed))倍速" : String(format: "%.1f倍速", speed))
                }
                stat("区間", "\(t.segments.count)")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    private func subtitle(_ summary: TranscriptRowCache.Summary?) -> String {
        guard let t = job.transcript, let summary else { return "" }
        var parts: [String] = []
        if let l = summary.languageLabel { parts.append(l) }
        if let m = t.model, let spec = ModelCatalog.spec(id: m) { parts.append(spec.displayName) }
        return parts.joined(separator: " · ")
    }

    // MARK: 操作列
    private func controls(_ transcript: Transcript, _ stats: Transcript.TranslationStats) -> some View {
        @Bindable var model = model
        let canPost = job.status == .done && !transcript.segments.isEmpty
        return HStack(spacing: 12) {
            TextField("結果を検索", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Toggle("時刻", isOn: $model.showTimestamps)
                .toggleStyle(.checkbox)
            if stats.hasTranslation || stats.isMainlyForeign {
                // 行の「訳」で対訳を出しているジョブでは、設定がオフでもチェックを付けて見せる
                Toggle("対訳", isOn: Binding(
                    get: { model.showsBilingual(job) },
                    set: { model.setShowsBilingual($0, for: job) }
                ))
                    .toggleStyle(.checkbox)
                    .help("原文と日本語訳を左右に並べる")
            }
            Toggle("メモ", isOn: $model.showNotes)
                .toggleStyle(.checkbox)
                .help("右にメモの欄を出す (理解したこと・覚えたい表現などを書ける。書いたものは自動で保存される)")
            Spacer()
            HistoryButton(job: job)
            AuditButton(job: job, transcript: transcript)
                .disabled(!canPost)
            if stats.translatable > 0 {
                Button {
                    model.translate(job)
                } label: {
                    Label(stats.untranslated > 0 && stats.hasTranslation ? "残りを翻訳" : "翻訳",
                          systemImage: "character.bubble")
                }
                .help("日本語以外の区間を、Mac の中の LLM で日本語に訳す")
                .disabled(!canPost || job.isPostActive || stats.untranslated == 0)
            }
            Button {
                model.copySelectedText()
            } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
            ExportMenu(hasTranslation: stats.hasTranslation, job: job)
                .disabled(job.status != .done)
        }
    }

    private var emptyMessage: String {
        if !model.searchText.isEmpty { return "一致する区間はありません" }
        switch job.status {
        case .running, .queued: return "認識した文から順にここへ出ます…"
        case .done: return "言葉を検出できませんでした。無音か、言語の設定が合っていない可能性があります。"
        default: return ""
        }
    }
}

/// 文字起こし中の進み具合と知らせ、「中止」。進み具合 (1 秒に何度も変わる) を見るのはこの部品だけにする
/// (結果の画面全体で見ると、進み具合が変わるたびに、数千行の一覧の部品まで作り直すことになる)
struct JobProgressBar: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if job.status == .running && job.progress > 0 {
                    ProgressView(value: job.progress)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(job.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("中止") { model.cancel(job) }
        }
    }
}

/// 行の頭の言語の印 (英・日)
struct LanguageTagLabel: View {
    let tag: String?

    var body: some View {
        if let tag {
            Text(tag)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(tag == "英" ? "英語で話している区間" : "日本語で話している区間")
        }
    }
}

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
    let emptyMessage: String
    /// 行の色 (1 行だけ再生している行・いまの位置の行)。行と CurrentLineTracker が使い、この body では中を見ない
    @State private var highlight = RowHighlight()
    /// 文字起こし中に、一覧の終わりを追いかけるか。この body では中を見ない (見ると、一覧の中を押すたびに body が動く)。
    /// 一覧ごとに 1 つ (始めは追いかける)。イベントの見張りも、この一覧の ListFollow が自分の分だけを入れ、自分の分だけを外す
    @State private var follow = ListFollow()

    var body: some View {
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
                    TranscriptRows(job: job, items: items, bilingual: bilingual, emptyMessage: emptyMessage,
                                   canPlay: canPlay, translating: translating, showTimestamps: showTimestamps,
                                   highlightText: highlightText, running: running, highlight: highlight, follow: follow)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(Color(nsColor: .controlBackgroundColor))
                .background(CurrentLineTracker(job: job, items: items, highlight: highlight, follow: follow, proxy: proxy))
                // 練習の行を、一覧の行に合わせる (一覧が変わったときだけ知らせる)
                .background(PracticeRowsFeeder(job: job, items: items, bilingual: bilingual))
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
                    // 画面の重さの確認 (--selftest-ui-load --screenshots) が、絵を撮る前に一覧を動かす口。
                    // ジョブを選ぶと一覧が作り直され、新しい一覧の onAppear と古い一覧の onDisappear は、どちらが先にも来る:
                    // 入れるときは、いつも新しい一覧のものに入れ替え、外すときは、自分が入れたものが残っているときだけ外す
                    if UILoadHooks.isActive {
                        UILoadHooks.register(owner: ObjectIdentifier(follow), scrollList: { id, edge in
                            proxy.scrollTo(id, anchor: edge == .top ? .top : .bottom)
                        }, setFollowing: { on in
                            if follow.isOn != on { follow.isOn = on }
                        }, isFollowing: { follow.isOn })
                    }
                }
                .onDisappear {
                    follow.remove()
                    if UILoadHooks.isActive { UILoadHooks.unregister(owner: ObjectIdentifier(follow)) }
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
                PlayableRow(item: item, job: job, canPlay: canPlay, highlight: highlight) {
                    if bilingual {
                        BilingualRow(item: item, isTranslating: translating, showTimestamp: showTimestamps,
                                     highlight: highlightText, job: job)
                    } else {
                        SegmentRow(item: item, showTimestamp: showTimestamps,
                                   highlight: highlightText, job: job)
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
            // LazyVStack の onAppear は、一覧を並べている最中に呼ばれることがあり、見える少し前
            // (先に作る範囲に入ったとき) にも呼ばれる。並べている最中に状態を変えると、その場でまた並べ直すことに
            // なるので、次の回に変える。同じ値でも書くと見ている部品が描き直されるので、変わるときだけ書く
            Color.clear
                .frame(height: 1)
                .accessibilityHidden(true)
                .onAppear {
                    Task { @MainActor in
                        if !follow.isOn { follow.isOn = true }
                    }
                }
        }
    }
}

/// 一覧の右下の「末尾へ」。文字起こし中に、一覧の終わりを追いかけていないときだけ出す。
/// ListFollow.isOn を見るのは、この部品だけ (一覧の body では見ない)
private struct FollowButton: View {
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
                Label("末尾へ", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("一覧の終わりへ移り、文字起こしの続きを追いかける")
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
private struct CurrentLineTracker: View {
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
                    proxy.scrollTo(id, anchor: .bottom)
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
private struct PracticeRowsFeeder: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let items: [TranscriptListItem]
    let bilingual: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                model.practice.rowsChanged(job: job, bilingual: bilingual)
            }
            .onChange(of: items) { _, _ in
                model.practice.rowsChanged(job: job, bilingual: bilingual)
            }
            .onChange(of: bilingual) { _, on in
                model.practice.rowsChanged(job: job, bilingual: on)
            }
    }
}

/// 検索語に色を付ける
func highlighted(_ text: String, _ query: String) -> AttributedString {
    var s = AttributedString(text)
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return s }
    var searchStart = s.startIndex
    while searchStart < s.endIndex,
          let r = s[searchStart...].range(of: q, options: [.caseInsensitive]) {
        s[r].backgroundColor = Color.yellow.opacity(0.5)
        searchStart = r.upperBound
    }
    return s
}

/// 行そのものを再生のボタンにする。クリックでその行だけを再生し、再生中の行をもう一度クリックすると止める
/// (再生は練習 (PracticeController) を通すので、繰り返し・間・自動で次へ の設定が効く。間を待っているあいだも「再生中」)。
/// 行の文字はクリックを再生に使うため選べない (コピーは右クリックの「この行をコピー」か、上の「コピー」)
struct PlayableRow<Content: View>: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptListItem
    let job: Job
    /// 音声を再生できる (できないときは、クリックしても何もせず、再生の印も出さない)
    let canPlay: Bool
    /// 行の色 (この行だけを再生している・ふつうの再生でいまの位置がこの行にある)。この行の Cell だけを見る
    let highlight: RowHighlight
    let content: Content
    @State private var hovering = false

    @MainActor
    init(item: TranscriptListItem, job: Job, canPlay: Bool, highlight: RowHighlight,
         @ViewBuilder content: () -> Content) {
        self.item = item
        self.job = job
        self.canPlay = canPlay
        self.highlight = highlight
        self.content = content()
        // 画面の重さの確認が、一覧が作った行の数を数える (ふだんは Bool を 1 つ見るだけ)。一覧が終わりへ飛ぶと、
        // LazyVStack はすべての行を作るが (1 つ 0.1 ms ほど)、並べるのは見える分だけなので、重さは body の数 (下) で見る
        if UILoadHooks.isActive { UILoadHooks.rowsBuilt += 1 }
    }

    var body: some View {
        // 画面の重さの確認が、body を動かした行の数も数える (一覧が本当に並べた行。init の数は、一覧が終わりへ飛ぶと
        // 数千になるが、それは軽い。重いのは、こちら)
        if UILoadHooks.isActive { UILoadHooks.rowBodies += 1 }
        let tint = highlight.cell(for: item.id).tint
        let isPlaying = tint == .playing
        // 原文を隠している行は、読み上げにも文を出さない
        let hidden = model.practice.concealment(of: item).hidesSource
        let spoken = hidden ? "隠している行" : item.text
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            if canPlay {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
            }
            content
        }
        // 行の余白を付け、幅いっぱいに広げる (押せる所・背景の色が行の幅いっぱいになる)
        .padding(.horizontal, RowMetrics.horizontal)
        .padding(.vertical, RowMetrics.vertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if canPlay { toggle() }
        }
        .onHover { inside in
            hovering = inside
        }
        .help(canPlay ? hint(isPlaying) : "")
        .contextMenu {
            if canPlay {
                Button(isPlaying ? "この行の再生を止める" : "この行だけを再生") { toggle() }
                Button("ここから続けて再生") {
                    model.player.seek(to: item.start, andPlay: true)
                }
                Divider()
            }
            Button("この行をコピー") {
                model.copyLine(item.text, japanese: item.japanese)
            }
            Button("メモに引用") {
                model.quoteToNotes(text: item.text, time: item.start, in: job)
            }
            // 行の「訳」と同じ (VoiceOver では行が 1 つの要素になるので、ここからも訳せるように)
            if item.canTranslate || item.isTranslated {
                Divider()
                Button(item.isTranslated ? "この文を訳し直す" : "この文だけ日本語に訳す") {
                    model.translateLine(item.id, in: job, redo: item.isTranslated)
                }
                .disabled(job.lineQueue.contains(item.id) || job.postState.task == .translate
                          || job.postQueue.contains(.translate))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(canPlay ? spoken + "。" + hint(isPlaying) : spoken))
        .accessibilityAddTraits(canPlay ? .isButton : [])
        .accessibilityAction {
            if canPlay { toggle() }
        }
        // 行の背景の色 (マウスを載せた・いまの位置・再生している)
        .background(background(tint))
    }

    private func hint(_ isPlaying: Bool) -> String {
        isPlaying ? "クリックで停止" : "クリックで、この行だけを再生"
    }

    private func background(_ tint: RowTint) -> Color {
        switch tint {
        case .playing: return Color.accentColor.opacity(0.24)
        case .current: return Color.accentColor.opacity(0.12)
        case .plain: return hovering && canPlay ? Color.primary.opacity(0.06) : Color.clear
        }
    }

    /// 練習を通して流す (繰り返し・間・自動で次へ が効く)。続けて流している行なら止める
    private func toggle() {
        // 左の結果の一覧を触ったあとなら、一覧から手を離す (このあと、矢印のキーで行を移れるように)。
        // メモや書き取りを打っている最中なら、そのままにする
        if let window = NSApp.keyWindow, window.firstResponder is NSTableView {
            window.makeFirstResponder(nil)
        }
        model.practice.toggleLine(item.id)
    }
}

/// 一覧の行の余白 (macOS の List の行に合わせた値)
private enum RowMetrics {
    static let horizontal: CGFloat = 10
    static let vertical: CGFloat = 4
}

struct SegmentRow: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptListItem
    let showTimestamp: Bool
    let highlight: String
    let job: Job

    var body: some View {
        // 練習で隠すか (隠し方と、隠す行ならその行の「見せた」だけを見る)
        let conceal = model.practice.concealment(of: item)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if showTimestamp {
                TimestampLabel(time: item.start)
            }
            LanguageTagLabel(tag: item.languageTag)
            Text(highlighted(item.text, highlight))
                // 隠すときは、同じ場所に灰色の帯を出す (行の高さは変わらない)
                .redacted(reason: conceal.hidesSource ? .placeholder : [])
                .frame(maxWidth: .infinity, alignment: .leading)
            if conceal.canHide {
                RevealLineButton(id: item.id, revealed: conceal.revealed)
            }
            ForEach(item.changes) { change in
                AuditBadge(change: change, job: job)
            }
            TranslateLineButton(item: item, job: job)
        }
        .padding(.vertical, 3)
    }
}

/// 行の「訳」: その行を含む 1 文だけを日本語に訳す (まとめて訳すより軽い)。行の再生とは別のボタンで、押しても再生しない。
/// 文が訳されるのを待っているあいだ・訳しているあいだは、くるくるに変わる
struct TranslateLineButton: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptListItem
    let job: Job

    var body: some View {
        if job.lineQueue.contains(item.id) {
            ProgressView()
                .controlSize(.small)
                .help("この文を訳しています (順番待ちを含む)")
        } else if item.canTranslate && job.postState.task != .translate && !job.postQueue.contains(.translate) {
            // まとめての「翻訳」を待っている・動いているあいだは出さない (その「翻訳」がこの行も訳す)
            Button {
                model.translateLine(item.id, in: job)
            } label: {
                Text("訳")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("この文だけ日本語に訳す")
        }
    }
}

struct TimestampLabel: View {
    let time: TimeInterval

    var body: some View {
        Text(TimeFormat.short(time))
            .monospacedDigit()
            .font(.callout)
            .foregroundStyle(Color.accentColor)
            .frame(width: 52, alignment: .trailing)
    }
}

/// 対訳表示の見出し (左: 原文 / 右: 日本語訳)
struct BilingualHeader: View {
    /// 原文の言語の名前 (「英語」「英語＋日本語」など)
    let label: String?
    let showTimestamp: Bool
    /// 行の頭に再生の印がある (その幅だけ空ける)
    var showPlayMark = false

    var body: some View {
        HStack(spacing: 12) {
            if showPlayMark {
                Color.clear.frame(width: 16, height: 1)
            }
            if showTimestamp {
                Color.clear.frame(width: 52, height: 1)
            }
            Label("原文" + (label.map { "（\($0)）" } ?? ""), systemImage: "text.quote")
                .frame(maxWidth: .infinity, alignment: .leading)
            Label("日本語訳", systemImage: "character.bubble")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28)
        .padding(.vertical, 6)
    }
}

/// 対訳表示の 1 行 (左: 原文 / 右: 日本語訳)。文がいくつかの区間にまたがるときは、まとめて 1 行
struct BilingualRow: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptListItem
    let isTranslating: Bool
    let showTimestamp: Bool
    let highlight: String
    let job: Job

    var body: some View {
        // 練習で隠すか (隠し方と、隠す行ならその行の「見せた」だけを見る)
        let conceal = model.practice.concealment(of: item)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if showTimestamp {
                TimestampLabel(time: item.start)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                LanguageTagLabel(tag: item.languageTag)
                Text(highlighted(item.text, highlight))
                    .redacted(reason: conceal.hidesSource ? .placeholder : [])
                    .frame(maxWidth: .infinity, alignment: .leading)
                if conceal.canHide {
                    RevealLineButton(id: item.id, revealed: conceal.revealed)
                }
                ForEach(item.changes) { change in
                    AuditBadge(change: change, job: job)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 訳の列。まだ訳がない行は、訳が入る所に「訳」を出す
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    if let japanese = item.japanese {
                        Text(highlighted(japanese, highlight))
                            .foregroundStyle(item.isOriginalJapanese ? Color.secondary : Color.primary)
                            .redacted(reason: conceal.hidesTranslation ? .placeholder : [])
                    } else {
                        Text(isTranslating || job.lineQueue.contains(item.id) ? "翻訳中…" : "未翻訳")
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TranslateLineButton(item: item, job: job)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}

/// 練習で隠している行の、目のボタン。押すと、その行だけを見せる / また隠す
struct RevealLineButton: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let revealed: Bool

    var body: some View {
        Button {
            model.practice.reveal.toggle(id)
        } label: {
            Image(systemName: revealed ? "eye.slash" : "eye")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(revealed ? "この行を隠す" : "この行を見る")
        .accessibilityLabel(Text(revealed ? "この行を隠す" : "この行を見る"))
    }
}

/// 監査で直した / 直す提案がある区間の印。押すと内容を見て、反映・取り消しができる
struct AuditBadge: View {
    let change: AuditChange
    let job: Job
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help(change.reason)
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            AuditChangeDetail(change: change, job: job)
                .padding(14)
                .frame(width: 360)
        }
    }

    private var title: String {
        if change.isApplied { return change.kind == .fix ? "修正済み" : "削除済み" }
        return change.kind == .fix ? "修正の提案" : "削除の提案"
    }

    private var color: Color {
        change.isApplied ? .green : .orange
    }
}

/// 監査の 1 か所の内容
struct AuditChangeDetail: View {
    @Environment(AppModel.self) private var model
    let change: AuditChange
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(change.kind == .fix ? "聞き取りミスの修正" : "区間の削除",
                      systemImage: change.kind == .fix ? "pencil" : "trash")
                    .font(.headline)
                Spacer()
                Text(TimeFormat.short(change.original.start))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(change.reason)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(change.original.text)
                .strikethrough(change.kind == .delete || change.isApplied)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let replacement = change.replacement {
                Label {
                    Text(replacement).textSelection(.enabled)
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                }
            }
            HStack {
                Text(change.origin == .llm ? "見つけた: ローカル LLM"
                     : (change.origin == .ledger ? "見つけた: 学習した直し" : "見つけた: 繰り返しの規則"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if change.isApplied {
                    Button("元に戻す") { model.setAuditChange(change, applied: false, in: job) }
                } else {
                    Button(change.kind == .fix ? "この修正を反映" : "この区間を消す") {
                        model.setAuditChange(change, applied: true, in: job)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 4)
        }
    }
}

/// 監査の実行と、結果の一覧
struct AuditButton: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let transcript: Transcript
    @State private var showing = false

    var body: some View {
        if let audit = transcript.audit {
            Button {
                showing = true
            } label: {
                Label(summary(audit), systemImage: "checkmark.seal")
            }
            .help("監査の結果を見る (直した所・直す提案)")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AuditPanel(job: job, transcript: transcript)
                    .frame(width: 460, height: 420)
            }
        } else {
            Button {
                model.audit(job)
            } label: {
                Label("監査", systemImage: "checkmark.seal")
            }
            .help(model.isLLMInstalled
                  ? "繰り返しと聞き取りミスを、Mac の中の LLM で見直す"
                  : "繰り返しを見直す (聞き取りミスも見直すには、設定から LLM を取得)")
            .disabled(job.isPostActive)
        }
    }

    private func summary(_ audit: AuditReport) -> String {
        var parts: [String] = []
        if audit.appliedFixes > 0 { parts.append("修正 \(audit.appliedFixes)") }
        if audit.appliedDeletes > 0 { parts.append("削除 \(audit.appliedDeletes)") }
        if audit.pendingSuggestions > 0 { parts.append("提案 \(audit.pendingSuggestions)") }
        return parts.isEmpty ? "監査: 問題なし" : "監査: " + parts.joined(separator: " · ")
    }
}

struct AuditPanel: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let transcript: Transcript

    var body: some View {
        let audit = transcript.audit
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("監査の結果").font(.headline)
                Spacer()
                if let audit {
                    Text((audit.model.map { "LLM: \($0)" } ?? "規則のみ") + (audit.isPartial == true ? " (途中まで)" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("自信のある直しだけを反映しています。「提案」は確かめてから反映してください。どれもいつでも元に戻せます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let audit, !audit.changes.isEmpty {
                List(audit.changes) { change in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { change.isApplied },
                            set: { model.setAuditChange(change, applied: $0, in: job) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(TimeFormat.short(change.original.start))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.accentColor)
                                Text(change.kind == .fix ? "修正" : "削除")
                                    .font(.caption.weight(.semibold))
                                Text(change.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(change.original.text)
                                .strikethrough(change.isApplied)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if let replacement = change.replacement {
                                Text("→ " + replacement)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                Spacer()
                Text("直す所は見つかりませんでした。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            HStack {
                Button("すべて元に戻す") { model.revertAudit(of: job) }
                    .disabled((audit?.appliedFixes ?? 0) + (audit?.appliedDeletes ?? 0) == 0)
                Spacer()
                Button("監査をやり直す") { model.audit(job) }
                    .disabled(job.isPostActive)
            }
        }
        .padding(14)
    }
}

/// 監査・翻訳の進み具合
struct PostProcessBar: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .running(let task, let message, let progress) = job.postState {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: task == .audit ? "checkmark.seal" : "character.bubble")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        if let progress {
                            ProgressView(value: progress)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Text(message + (job.postQueue.isEmpty ? "" : "（このあと: " + queued + "）"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("中止") { model.cancelPost(job) }
                }
            } else if !job.postQueue.isEmpty {
                Label("順番待ち: " + queued, systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let note = job.postNote {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, job.isPostActive || job.postNote != nil ? 10 : 0)
    }

    private var queued: String {
        job.postQueue.map { task in
            switch task {
            case .audit: return "監査"
            case .translate: return "翻訳"
            case .translateLines: return "選んだ文の翻訳"
            }
        }.joined(separator: "・")
    }
}

/// 「日本語」で文字にしたら、英語が多かった: 「日本語＋英語」でやり直すよう案内する
/// (英語の講師と日本語の通訳のように言語が入れ替わる録音は、1 つの言語に決めて文字にすると、英語の部分が崩れやすい)
struct MixedLanguageSuggestion: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("英語の多い録音でした。日本語と英語が入れ替わるなら、「日本語＋英語」で文字起こしし直せます")
                    .font(.callout.weight(.semibold))
                Text("区切りごとに日本語か英語かを判定し、その言語で文字にします。言語を 1 つに決めたときに崩れた行が直ることがあります。時間は 2〜4 倍ほどかかります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("日本語＋英語でやり直す") {
                model.retranscribe(job, languageCode: Languages.japaneseEnglish.code)
            }
            .buttonStyle(.borderedProminent)
            Button {
                job.mixedSuggestionDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("閉じる (言語は、上の言語のメニューや設定でも選べます)")
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 日本語と英語が混ざっていたので、自動で「日本語＋英語」で文字にしたことを知らせる。
/// 設定の言語だけでやり直すこともできる (やり直しでは、自動で切り替えない)
struct AutoMixedLanguageNotice: View {
    @Environment(AppModel.self) private var model
    let job: Job
    /// 切り替える前の言語 (設定の言語)
    let from: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("日本語と英語が混ざっていたので、「日本語＋英語」で文字にしました。")
                    .font(.callout.weight(.semibold))
                Text("区切りごとに日本語か英語かを判定し、その言語で文字にしています。自動で切り替えないようにするには、設定の「文字起こし」で変えられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if job.url != nil {
                Button(retryTitle) {
                    model.retranscribe(job, languageCode: from, autoMixed: false)
                }
            }
            Button {
                job.autoMixedNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("閉じる")
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var retryTitle: String {
        from == Languages.auto.code ? "「日本語＋英語」を使わずにやり直す" : "「\(Languages.name(for: from))」だけでやり直す"
    }
}

/// 翻訳・監査に LLM が必要なことを知らせる
struct LLMNeededBanner: View {
    @Environment(AppModel.self) private var model
    /// 日本語以外が主な文字起こし (翻訳も案内する)
    let wantsTranslation: Bool

    var body: some View {
        let selection = model.currentLLM
        HStack(spacing: 12) {
            Image(systemName: wantsTranslation ? "character.bubble" : "checkmark.seal")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(wantsTranslation
                     ? "日本語訳と聞き取りミスの監査には、Mac の中で動く LLM を使います"
                     : "聞き取りミスの監査には、Mac の中で動く LLM を使います (いまは繰り返しだけを見直しています)")
                    .font(.callout.weight(.semibold))
                Text("\(selection.name) (約 \(selection.spec.map { TimeFormat.bytes(Int64($0.approxMB) * 1_000_000) } ?? "—")) を一度だけダウンロードします。文字起こしの内容は Mac の外に出ません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // ボタンを並べた残りの幅を文に使う (Spacer と分け合うと、狭いウインドウでボタンの文字が欠ける)
            .frame(maxWidth: .infinity, alignment: .leading)
            LLMDownloadControls()
            Button {
                model.llmBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("閉じる (設定の「監査・翻訳」タブから、いつでも取得できます)")
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// LLM のダウンロード (進み具合・中止) と「設定で選ぶ…」。結果の画面の案内と、始めの画面で使う
struct LLMDownloadControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    /// 「ダウンロード」を目立たせる (始めの画面では、音声認識モデルの取得を主にするので控えめにする)
    var prominent = true

    var body: some View {
        if let spec = model.currentLLM.spec {
            switch model.llmAvailability(of: spec) {
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 90)
                Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Button("中止") { model.cancelLLMDownload(spec) }
            case .notInstalled:
                if prominent {
                    Button("ダウンロード") { model.downloadLLM(spec) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("ダウンロード") { model.downloadLLM(spec) }
                        .buttonStyle(.bordered)
                }
            case .installed:
                EmptyView()
            }
        }
        // 設定の「監査・翻訳」タブを開く (メモリ 8 GB の Mac で軽い 2B を選ぶときなど)
        Button("設定で選ぶ…") {
            model.settingsTab = .llm
            openSettings()
        }
        .help("設定の「監査・翻訳」タブを開きます。軽い 2B や高精度の 9B も選べます")
    }
}

/// 書き出し (原文 / 日本語訳 / 対訳 × 形式)
struct ExportMenu: View {
    let hasTranslation: Bool
    /// メモが空かどうかは、この部品の中で見る (結果の画面が見ると、メモを書き始めたときに一覧まで描き直す)
    let job: Job

    var body: some View {
        Menu {
            ExportMenuItems(hasTranslation: hasTranslation, hasNotes: job.hasNotes)
        } label: {
            Label("書き出す", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .fixedSize()
    }
}

struct ExportMenuItems: View {
    @Environment(AppModel.self) private var model
    let hasTranslation: Bool
    /// メモが空でない (「メモ (.md)」も出す)
    let hasNotes: Bool

    var body: some View {
        formats
        if hasNotes {
            Divider()
            Button("メモ (.md)") { model.exportNotes() }
        }
    }

    @ViewBuilder
    private var formats: some View {
        if hasTranslation {
            ForEach(ExportContent.allCases) { content in
                Section(content.displayName) {
                    ForEach(ExportFormat.allCases.filter { ExportContent.available(for: $0).contains(content) }) { format in
                        Button(format.displayName) { model.export(as: format, content: content) }
                    }
                }
            }
        } else {
            ForEach(ExportFormat.allCases) { format in
                Button(format.displayName) { model.export(as: format) }
            }
        }
    }
}

/// 音声ファイルが見つからない (保存した結果の音声を動かした・消した)。選び直せる
struct MissingAudioNotice: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .foregroundStyle(.secondary)
            Text("音声ファイルが見つかりません: " + path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("音声を選び直す…") { model.relocateAudio(of: job) }
                .controlSize(.small)
        }
    }
}

/// 再生・シーク
struct PlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.player
        // 練習で間を待っているあいだも「止める」の形にする (押すと、続けて流すのが止まる)
        let playing = p.isPlaying || model.practice.isWaiting
        HStack(spacing: 12) {
            Button {
                // 練習で続けて流している最中なら、それも終わりにする
                model.practice.togglePlay()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.bordered)
            .help("再生 / 一時停止 (スペースキー)")
            Text(TimeFormat.short(p.currentTime))
                .monospacedDigit()
                .font(.callout)
                .frame(width: 56, alignment: .trailing)
            Slider(
                value: Binding(get: { p.currentTime }, set: { p.seek(to: $0) }),
                in: 0...max(p.duration, 0.01)
            )
            Text(TimeFormat.short(p.duration))
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            // 練習: 間の知らせ・速さ・繰り返しなど (再生位置は見ない部品に分けてある)
            PracticeGapNote()
            SpeedMenu()
            PracticeMenu()
        }
    }
}
