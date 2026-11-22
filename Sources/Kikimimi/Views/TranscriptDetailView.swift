import AppKit
import KikimimiCore
import SwiftUI

struct TranscriptDetailView: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var cache = TranscriptRowCache()
    /// 日本語で数えた翻訳の状況 (「日本語＋英語でやり直す」の案内が使う。訳す先が日本語でない時だけ使う)
    @State private var japaneseCache = TranscriptRowCache()
    /// メモの欄と一覧を並べている欄の幅 (NotesSidebar だけが見る。この body では中を見ない)
    @State private var notesSpace = NotesSpace()

    var body: some View {
        // 翻訳の状況・言語の名前・一覧の行は、文字起こしが変わったときだけ作り直す (長い録音では区間が数千あるため。
        // 画面は、進み具合や検索欄の入力でも描き直される)。文字起こし中に区間が末尾に増えたときは、増えた分だけを足す
        // 訳す先の言語 (その結果の言語。訳が無ければ設定の言語。めったに変わらない)。文字起こしの最中は訳せないので、
        // 結果を見ずに設定の言語にする (区間が増えるたびに、全部の区間から訳の有無を探さないように)
        let target = job.status == .done
            ? job.transcript.map { model.translationTarget(for: $0) } ?? model.translationLanguage
            : model.translationLanguage
        let summary = job.transcript.map { cache.summary(of: $0, job: job.id, done: job.status == .done, target: target) }
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
                HStack(spacing: 12) {
                    Label(job.error ?? L("Error"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    RedoAgainButton(job: job)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if job.status == .cancelled {
                HStack(spacing: 12) {
                    Label(L("Canceled"), systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                    RedoAgainButton(job: job)
                }
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
                if job.status == .done, job.vadSkippedAutomatically, !job.vadSkippedNoticeDismissed {
                    VADSkippedNotice(job: job)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                if job.status == .done, job.languageCode == "ja", job.url != nil, !job.mixedSuggestionDismissed,
                   job.allowsAutoMixed, summary.spokenLanguages.isEmpty,
                   isMainlyNotJapanese(transcript, stats: stats, target: target) {
                    MixedLanguageSuggestion(job: job)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                if job.status == .done, !transcript.segments.isEmpty, !model.isLLMInstalled, !model.llmBannerDismissed,
                   (model.autoTranslate && stats.isMainlyForeign) || model.autoAudit {
                    LLMNeededBanner(wantsTranslation: stats.isMainlyForeign, target: target)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                // 設定の訳す先と違う言語に訳してある結果: 訳し直せることを知らせる (訳が在り、LLM が在る時だけ)。
                // 訳がまだ無くても、訳す先の記録が残っている結果 (訳し直しの途中で終了した、など) にも出す (ほかに直す道が無い)
                if job.status == .done, stats.hasTranslation || transcript.translationLanguage != nil,
                   target != model.translationLanguage, model.isLLMInstalled,
                   !job.translationLanguageNoticeDismissed {
                    TranslationLanguageNotice(job: job, current: target, setting: model.translationLanguage)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                TranscriptControls(job: job, transcript: transcript, stats: stats, target: target)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                Divider()
                let items = cache.items(of: transcript, job: job.id, done: job.status == .done,
                                        bilingual: bilingual, query: model.searchText, target: target)
                // 右にメモの欄 (「メモ」を入れたときだけ)。メモの中身を見るのは NotesPane だけ (打つたびに一覧を作り直さない)。
                // メモの欄の幅を見るのも NotesSidebar だけ (区切りを動かしても、この body は動かない)。
                // 一覧は、メモを出しても消しても同じ場所に置く (置き場所を変えると一覧が作り直され、読んでいた位置が始めに戻る)。
                // HSplitView は使わない: 下の NSSplitView が、中の部品に望みの大きさを尋ね、尋ねられた ScrollView は
                // 中身をすべて測るので、LazyVStack が 3000 行をすべて作った (GitHub の Mac で、終わったジョブを 2 回目に選ぶと
                // 5〜21 秒。HSplitView の前は 0.13〜1.0 秒)
                let space = notesSpace
                HStack(spacing: 0) {
                    // 「要確認」の行 (行を作る時に 1 度だけ数えた物。ここでは数えない)
                let flaggedIDs = cache.flaggedItemIDs
                transcriptColumn(items: items, bilingual: bilingual, languageLabel: summary.languageLabel, target: target,
                                 flaggedIDs: flaggedIDs)
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

    /// 日本語以外が主な文字起こしか (「日本語＋英語でやり直す」の案内。文字起こしの言語の話なので、訳す先によらず日本語で数える)。
    /// 訳す先が日本語なら、一覧と同じ数え方 (stats) をそのまま使う
    private func isMainlyNotJapanese(_ transcript: Transcript, stats: Transcript.TranslationStats, target: String) -> Bool {
        if target == "ja" { return stats.isMainlyForeign }
        return japaneseCache.summary(of: transcript, job: job.id, done: job.status == .done, target: "ja").stats.isMainlyForeign
    }

    /// 対訳の見出しと一覧
    @ViewBuilder
    private func transcriptColumn(items: [TranscriptListItem], bilingual: Bool, languageLabel: String?,
                                  target: String, flaggedIDs: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if bilingual {
                BilingualHeader(label: languageLabel, target: target, showTimestamp: model.showTimestamps,
                                showPlayMark: model.canPlayLines(of: job), flaggedIDs: flaggedIDs)
                Divider()
            }
            // 一覧はジョブごとに作り直す (.id): 別のジョブを選んだら、新しい ScrollView が一覧の始めから出て、
            // 一覧の状態 (追いかけるか・行の色) も新しくなる。この結果の画面は、別のジョブを選んでも作り直されず使い回されるので、
            // .id が無いと ScrollView が前のジョブで動かした位置 (ずっと下) を残したまま中身だけが入れ替わり、LazyVStack が
            // その位置まで数千行を本当に並べた (GitHub の Mac で 3000 行のとき、文字起こし中のジョブを終わりまで出したあとに
            // 終わったジョブを選ぶ 1 回が 16.8 秒。ふだんは 0.2〜1.1 秒)
            // 訳す先 (target) は、行の説明の文 (「この文だけ〇〇語に訳す」) と練習の「隠す」に使う。めったに変わらない値
            TranscriptListView(job: job, items: items, bilingual: bilingual, target: target, emptyMessage: emptyMessage)
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
                stat(L("Length"), TimeFormat.short(t.duration))
                stat(L("Processing"), L("%.1f s", t.elapsed))
                if let rtf = t.realTimeFactor, rtf > 0 {
                    let speed = 1 / rtf
                    stat(L("Speed"), speed >= 10 ? L("%d×", Int(speed)) : L("%.1f×", speed))
                }
                stat(L("Segments"), "\(t.segments.count)")
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

    private var emptyMessage: String {
        if !model.searchText.isEmpty { return L("No matching segments") }
        switch job.status {
        case .running, .queued: return L("Sentences appear here as they are recognized…")
        case .done: return L("No speech was detected. The audio may be silent, or the language setting may not match.")
        default: return ""
        }
    }
}

/// 結果の画面の操作の列 (検索・チェック・ボタン)。ここは一覧の外。
/// 画面の言語によって字の長さが違うので、並べ方を 3 つから選ぶ: 1 行 → 2 行 (下の行に字つきのボタン) → 2 行 (印だけ)。
/// ViewThatFits は使わない: 文字起こし中は行が増えるたびにレイアウトが走り、そのたびに候補を測り直して重くなった
/// (タイ語で、メインスレッドがふさがる割合が 6.9% から 26.0% に)。代わりに、使える幅 (幅が変わったときだけ変わる) と、
/// 字の幅の見積もり (言語ごとに 1 度だけ測る) から 1 つを決め、それだけを描く。
/// 使える幅を、結果の画面 (一覧を含む) の状態にしない: 幅を変えるたびに一覧まで描き直すことになる
struct TranscriptControls: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let transcript: Transcript
    let stats: Transcript.TranslationStats
    /// その結果の訳す先の言語 (説明の文と書き出しの名前に使う。ボタンの字には入れないので、並べ方の見積もりは変わらない)
    let target: String
    /// 操作の列に使える幅 (幅が変わったときだけ入れる。文字起こし中に行が増えても変わらない)
    @State private var width: CGFloat?
    @State private var textWidths = ControlsTextWidths()

    var body: some View {
        Group {
            switch arrangement(for: width) {
            case .oneLine:
                HStack(spacing: ControlsMetrics.spacing) {
                    // 1 行の形は、前と同じ見た目にする (検索の欄は 220 pt まで)
                    searchField(maxWidth: 220)
                    toggles
                    Spacer()
                    actions(iconOnly: false)
                }
            case .twoLines:
                twoLines(iconOnly: false)
            case .twoLinesIconOnly:
                twoLines(iconOnly: true)
            }
        }
        // minWidth: 0 = この列は、中身の幅を外へ求めない (与えられた幅をそのまま使う)。
        // これが無いと、始めの 1 回の「1 行の形」が使える幅より広い言語 (英語など) で、その広さが結果の画面を
        // ウインドウの外へ押し広げ、下で測る幅も押し広げた後の幅になるので、1 行の形のまま抜けられない
        // (2026-11-19、英語の画面で、右端の「Export」と印の列・左のサイドバーが切れた)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
    }

    /// 2 行の形: 上に検索とチェック、下に右寄せのボタン
    private func twoLines(iconOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: ControlsMetrics.spacing) {
                searchField(maxWidth: .infinity)
                toggles
            }
            HStack(spacing: ControlsMetrics.spacing) {
                Spacer()
                actions(iconOnly: iconOnly)
            }
        }
    }

    /// 検索の欄。残りの幅を使うが、140 pt より細くしない
    private func searchField(maxWidth: CGFloat) -> some View {
        @Bindable var model = model
        return TextField(L("Search results"), text: $model.searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 140, maxWidth: maxWidth)
    }

    /// 「時刻」「対訳」「メモ」のチェック。字は 1 行のまま、縮めない
    @ViewBuilder
    private var toggles: some View {
        @Bindable var model = model
        Toggle(L("Timestamps"), isOn: $model.showTimestamps)
            .toggleStyle(.checkbox)
            .lineLimit(1)
            .fixedSize()
        if showsBilingualToggle {
            // 行の「訳」で対訳を出しているジョブでは、設定がオフでもチェックを付けて見せる
            Toggle(L("Bilingual"), isOn: Binding(
                get: { model.showsBilingual(job) },
                set: { model.setShowsBilingual($0, for: job) }
            ))
                .toggleStyle(.checkbox)
                .lineLimit(1)
                .fixedSize()
                .help(L("Show the original and the %@ translation side by side", TranslationTarget.displayName(for: target)))
        }
        Toggle(L("Notes"), isOn: $model.showNotes)
            .toggleStyle(.checkbox)
            .lineLimit(1)
            .fixedSize()
            .help(L("Show a notes pane on the right (for what you understood, phrases to remember, and so on. What you write is saved automatically)"))
    }

    /// 操作の列のボタンとメニュー。iconOnly のときは印だけにする (字は読み上げと .help に出す)。字は 1 行のまま、縮めない
    @ViewBuilder
    private func actions(iconOnly: Bool) -> some View {
        let canPost = job.status == .done && !transcript.segments.isEmpty
        RedoMenu(job: job, iconOnly: iconOnly)
        // 履歴のボタンは別のファイルの部品なので、印だけにするのは外から掛ける (中にポップオーバーは無い)
        HistoryButton(job: job)
            .actionLabelStyle(iconOnly: iconOnly)
            .accessibilityLabel(Text(L("History")))
            .lineLimit(1)
            .fixedSize()
        AuditButton(job: job, transcript: transcript, iconOnly: iconOnly)
            .lineLimit(1)
            .fixedSize()
            .disabled(!canPost)
        if stats.translatable > 0 {
            let title = translateTitle
            Button {
                model.translate(job)
            } label: {
                Label(title, systemImage: "character.bubble")
                    .actionLabelStyle(iconOnly: iconOnly)
                    .accessibilityLabel(Text(title))
            }
            .lineLimit(1)
            .fixedSize()
            .help(L("Translate segments that are not in %1$@ into %2$@ with the LLM on your Mac",
                    TranslationTarget.displayName(for: target), TranslationTarget.displayName(for: target)))
            .disabled(!canPost || job.isPostActive || stats.untranslated == 0)
        }
        Button {
            model.copySelectedText()
        } label: {
            Label(L("Copy"), systemImage: "doc.on.doc")
                .actionLabelStyle(iconOnly: iconOnly)
                .accessibilityLabel(Text(L("Copy")))
        }
        .lineLimit(1)
        .fixedSize()
        .iconOnlyHelp(iconOnly, L("Copy"))
        ExportMenu(hasTranslation: stats.hasTranslation, target: target, job: job, iconOnly: iconOnly)
            .disabled(job.status != .done)
    }

    /// 翻訳のボタンの字 (並べ方の見積もりと、ボタンの両方で使う)
    private var translateTitle: String {
        stats.untranslated > 0 && stats.hasTranslation ? L("Translate the rest") : L("Translate")
    }

    /// 「対訳」のチェックを出す
    private var showsBilingualToggle: Bool {
        stats.hasTranslation || stats.isMainlyForeign
    }

    /// 使える幅に収まる並べ方を、見積もりで選ぶ。字の幅は ControlsTextWidths が覚えているので、ここでは足し算だけ
    private func arrangement(for width: CGFloat?) -> ControlsArrangement {
        // 幅をまだ測っていない始めの 1 回は、1 行にしておく (日本語の画面のふだんの形)
        guard let width else { return .oneLine }
        let m = ControlsMetrics.self
        var toggleTitles = [L("Timestamps")]
        if showsBilingualToggle { toggleTitles.append(L("Bilingual")) }
        toggleTitles.append(L("Notes"))
        let toggles = toggleTitles.map { textWidths.width(of: $0) + m.checkbox }

        var buttons: [CGFloat] = []
        if job.url != nil { buttons.append(textWidths.width(of: L("Transcribe again")) + m.button + m.menuIndicator) }
        buttons.append(textWidths.width(of: L("History")) + m.button)
        buttons.append(textWidths.width(of: transcript.audit.map { AuditButton.title(of: $0) } ?? L("Audit")) + m.button)
        if stats.translatable > 0 { buttons.append(textWidths.width(of: translateTitle) + m.button) }
        buttons.append(textWidths.width(of: L("Copy")) + m.button)
        buttons.append(textWidths.width(of: L("Export")) + m.button + m.menuIndicator)

        let buttonsWidth = buttons.reduce(0, +) + m.spacing * CGFloat(buttons.count - 1)
        // 1 行: 検索・チェック・Spacer・ボタン。間隔は (チェックの数 + ボタンの数 + 1) 個
        let oneLine = m.searchMin + toggles.reduce(0, +) + m.spacerMin + buttonsWidth
            + m.spacing * CGFloat(toggles.count + 2) + m.safety
        if oneLine <= width { return .oneLine }
        // 2 行の下の行: Spacer・ボタン
        let bottomLine = m.spacerMin + m.spacing + buttonsWidth + m.safety
        if bottomLine <= width { return .twoLines }
        return .twoLinesIconOnly
    }
}

/// 操作の列の並べ方
enum ControlsArrangement {
    /// 1 行 (検索・チェック・ボタンが、字つきで並ぶ)
    case oneLine
    /// 2 行 (上に検索とチェック、下に字つきのボタン)
    case twoLines
    /// 2 行 (下のボタンは印だけ)
    case twoLinesIconOnly
}

/// 操作の列の並べ方を見積もるための、字以外の幅 (pt)。足りないと字が切れるので、少し多めにしてある
enum ControlsMetrics {
    /// 部品の間隔 (HStack の spacing)
    static let spacing: CGFloat = 12
    /// 検索の欄の最小の幅
    static let searchMin: CGFloat = 140
    /// Spacer の最小の幅 (macOS)
    static let spacerMin: CGFloat = 8
    /// チェックの箱と、箱と字の間
    static let checkbox: CGFloat = 20
    /// ボタンの縁の内側の余白 (左右)・印・印と字の間
    static let button: CGFloat = 34
    /// メニューの矢印と、その前の間 (「やり直す」「書き出す」)
    static let menuIndicator: CGFloat = 14
    /// 見積もりの余り (迷う幅のときは、次の並べ方に落とす)
    static let safety: CGFloat = 12
}

/// 操作の列の字の幅。AppKit で、操作の列が使う字 (システムの 13 pt) で測り、同じ字は 1 度だけ測る。
/// 画面の言語を変えると、ウインドウの中身が .id(model.uiLanguage) で作り直されるので、ここも作り直される
final class ControlsTextWidths {
    private var widths: [String: CGFloat] = [:]
    private let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    func width(of text: String) -> CGFloat {
        if let width = widths[text] { return width }
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        widths[text] = width
        return width
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
            Button(L("Stop")) { model.cancel(job) }
        }
    }
}

/// 行の頭の言語の印 (英・日)
struct LanguageTagLabel: View {
    let tag: String?

    var body: some View {
        // tag は言語のコード (en・ja)。出す印は、今の画面の言語で作る
        if let tag, let label = LanguageTag.short(tag) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(tag == "en" ? L("A segment spoken in English") : L("A segment spoken in Japanese"))
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
    /// 訳す先の言語の名前 (右クリックの「この文だけ〇〇語に訳す」)
    let targetName: String
    /// 対訳の行 (右クリックに「訳を直す…」を出す)
    let bilingual: Bool
    let content: Content
    @State private var hovering = false

    @MainActor
    init(item: TranscriptListItem, job: Job, canPlay: Bool, highlight: RowHighlight, targetName: String,
         bilingual: Bool = false, @ViewBuilder content: () -> Content) {
        self.item = item
        self.job = job
        self.canPlay = canPlay
        self.highlight = highlight
        self.targetName = targetName
        self.bilingual = bilingual
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
        let spoken = hidden ? L("Hidden line") : item.text
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
            // 画面の重さの確認が、マウスが行に載った・行から出た回数を数える (色が変わり、body がまた動く。ふだんは Bool を 1 つ見るだけ)
            if UILoadHooks.isActive { UILoadHooks.rowHoverChanges += 1 }
            hovering = inside
        }
        .help(canPlay ? hint(isPlaying) : "")
        .contextMenu {
            if canPlay {
                Button(isPlaying ? L("Stop playing this line") : L("Play only this line")) { toggle() }
                Button(L("Play from here")) {
                    model.player.seek(to: item.start, andPlay: true)
                }
                Divider()
            }
            Button(L("Copy this line")) {
                model.copyLine(item.text, japanese: item.translation)
            }
            Button(L("Quote in notes")) {
                model.quoteToNotes(text: item.text, time: item.start, in: job)
            }
            // 聞き取った文を、利用者が直す (文字起こしが終わった結果だけ)。直す画面は一覧の外のシート。
            // 対訳の行では、次の「訳を直す…」と並ぶ (原文を直す・訳を直す、の順)
            if job.status == .done {
                Button(L("Edit this line…")) {
                    model.requestLineEdit(item.editSegmentIDs, in: job)
                }
            }
            // 行の「訳」と同じ (VoiceOver では行が 1 つの要素になるので、ここからも訳せるように)
            if item.canTranslate || item.isTranslated {
                Divider()
                Button(item.isTranslated ? L("Translate this sentence again") : L("Translate only this sentence into %@", targetName)) {
                    model.translateLine(item.id, in: job, redo: item.isTranslated)
                }
                .disabled(job.lineQueue.contains(item.id) || job.postState.task == .translate
                          || job.postQueue.contains(.translate))
            }
            // 対訳の行の訳を、利用者が直す (訳がまだ無い行でも、自分で書ける)。直す画面は一覧の外のシート
            // (翻訳の途中は行が作り直されるので、行の中の入力欄では下書きが消える)。もともと訳す先の言語の行には出さない
            if bilingual && !item.isOriginalInTarget && job.status == .done {
                if !(item.canTranslate || item.isTranslated) { Divider() }
                Button(L("Edit translation…")) {
                    model.requestTranslationEdit(item.id, in: job)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(canPlay ? L("%1$@. %2$@", spoken, hint(isPlaying)) : spoken))
        .accessibilityAddTraits(canPlay ? .isButton : [])
        .accessibilityAction {
            if canPlay { toggle() }
        }
        // 行の背景の色 (マウスを載せた・いまの位置・再生している)
        .background(background(tint))
    }

    private func hint(_ isPlaying: Bool) -> String {
        isPlaying ? L("Click to stop") : L("Click to play only this line")
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
enum RowMetrics {
    static let horizontal: CGFloat = 10
    static let vertical: CGFloat = 4
}

struct SegmentRow: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptListItem
    let showTimestamp: Bool
    let highlight: String
    let job: Job
    /// 訳す先の言語の名前 (行の「訳」の説明の文)
    let targetName: String

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
            // 手で直した行の印 (行の値を出すだけ。原文を隠している時は出さない: 説明に聞き取った文が出るため)
            if let heard = item.heard, !conceal.hidesSource {
                EditedLineBadge(ids: item.editSegmentIDs, heard: heard, job: job)
            }
            if conceal.canHide {
                RevealLineButton(id: item.id, revealed: conceal.revealed)
            }
            ForEach(item.changes) { change in
                AuditBadge(change: change, job: job)
            }
            TranslateLineButton(item: item, job: job, targetName: targetName)
        }
        .padding(.vertical, 3)
    }
}

/// 行の「訳」: その行を含む 1 文だけを、その結果の訳す先の言語に訳す (まとめて訳すより軽い)。
/// 行の再生とは別のボタンで、押しても再生しない。文が訳されるのを待っているあいだ・訳しているあいだは、くるくるに変わる
struct TranslateLineButton: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptListItem
    let job: Job
    /// 訳す先の言語の名前 (説明の文)
    let targetName: String

    var body: some View {
        if job.lineQueue.contains(item.id) {
            ProgressView()
                .controlSize(.small)
                .help(L("Translating this sentence (or waiting to)"))
        } else if item.canTranslate && job.postState.task != .translate && !job.postQueue.contains(.translate) {
            // まとめての「翻訳」を待っている・動いているあいだは出さない (その「翻訳」がこの行も訳す)
            Button {
                model.translateLine(item.id, in: job)
            } label: {
                Text(L("Translate line"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(L("Translate only this sentence into %@", targetName))
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

/// 対訳表示の見出し (左: 原文 / 右: 訳。「日本語訳」など、その結果の訳す先の言語の名前で出す)
struct BilingualHeader: View {
    /// 原文の言語の名前 (「英語」「英語＋日本語」など)
    let label: String?
    /// 訳す先の言語のコード
    let target: String
    let showTimestamp: Bool
    /// 行の頭に再生の印がある (その幅だけ空ける)
    var showPlayMark = false
    /// 「要確認」の行の id (一覧の順。空なら「要確認 N」を出さない)
    var flaggedIDs: [UUID] = []

    var body: some View {
        HStack(spacing: 12) {
            if showPlayMark {
                Color.clear.frame(width: 16, height: 1)
            }
            if showTimestamp {
                Color.clear.frame(width: 52, height: 1)
            }
            Label(label.map { L("Original (%@)", $0) } ?? L("Original"), systemImage: "text.quote")
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Label(L("%@ translation", TranslationTarget.displayName(for: target)), systemImage: "character.bubble")
                if !flaggedIDs.isEmpty {
                    ReviewJumpButton(ids: flaggedIDs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28)
        .padding(.vertical, 6)
    }
}

/// 対訳の見出しの「要確認 N」。押すたびに、次の「要確認」の行へ一覧を動かす (最後の次は初めに戻る)。
/// 一覧の外に在るので、一覧を動かすのは練習の口 (`PracticeController.requestListScroll`) を通す。
/// どこまで跳んだかは、この部品の @State に持つ (一覧の body は見ない)
struct ReviewJumpButton: View {
    @Environment(AppModel.self) private var model
    let ids: [UUID]
    @State private var last: UUID?

    var body: some View {
        Button {
            guard !ids.isEmpty else { return }
            let next = last.flatMap { ids.firstIndex(of: $0) }.map { ($0 + 1) % ids.count } ?? 0
            last = ids[next]
            model.practice.requestListScroll(to: ids[next])
        } label: {
            Text(LPlural(ids.count, one: "%d needs review", other: "%d need review"))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .help(L("Go to the next translation that needs review"))
    }
}

/// 対訳表示の 1 行 (左: 原文 / 右: 訳)。文がいくつかの区間にまたがるときは、まとめて 1 行
struct BilingualRow: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptListItem
    let isTranslating: Bool
    let showTimestamp: Bool
    let highlight: String
    let job: Job
    /// 訳す先の言語の名前 (行の「訳」の説明の文)
    let targetName: String

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
                // 手で直した行の印は、原文の列に出す (訳の列の「直した」の印と、場所で見分けられるように)
                if let heard = item.heard, !conceal.hidesSource {
                    EditedLineBadge(ids: item.editSegmentIDs, heard: heard, job: job)
                }
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
                    if let japanese = item.translation {
                        Text(highlighted(japanese, highlight))
                            .foregroundStyle(item.isOriginalInTarget ? Color.secondary : Color.primary)
                            .redacted(reason: conceal.hidesTranslation ? .placeholder : [])
                    } else if !isTranslating, !job.lineQueue.contains(item.id), item.hasUntranslatedReason {
                        // 訳せなかった理由の覚えが在る行: 理由を、マウスを載せると出る文で添える (行の値を出すだけ)
                        Text(L("Not translated"))
                            .foregroundStyle(.tertiary)
                            .italic()
                            .help(item.review?.reasonTexts.joined(separator: "\n") ?? "")
                    } else {
                        Text(isTranslating || job.lineQueue.contains(item.id) ? L("Translating…") : L("Not translated"))
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 利用者が直した訳の印 (行の値を出すだけ。押すと、訳を直す画面を開く)
                if item.isEditedTranslation {
                    EditedTranslationBadge(id: item.id, job: job)
                } else if item.needsTranslationReview {
                    // 訳の関門の印が付いた機械の訳 (同じ部品。橙色。押すと、理由を見て直す・「この訳でよい」を選べる)
                    EditedTranslationBadge(id: item.id, job: job, title: L("Needs review"),
                                           help: L("This translation may have a problem. Click to see why and check it."),
                                           tint: .orange)
                } else if item.isRememberedTranslation {
                    // 訳の記憶から置いた訳の印 (同じ部品。文と説明だけ違う)
                    EditedTranslationBadge(id: item.id, job: job, title: L("Remembered"),
                                           help: L("This is your earlier translation of the same sentence. Click to change it."))
                }
                TranslateLineButton(item: item, job: job, targetName: targetName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}

/// 利用者が直した訳の行の、灰色の小さな印「直した」。押すと、訳を直す画面 (一覧の外のシート) を開く。
/// 訳の記憶から置いた訳の行の印「覚えた訳」、関門の印が付いた訳の橙色の印「要確認」にも使う (title・help・tint を渡す)
struct EditedTranslationBadge: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let job: Job
    /// 印の文と説明 (nil なら「直した」の物)
    var title: String? = nil
    var help: String? = nil
    /// 印の色 (nil なら灰色。「要確認」は橙色)
    var tint: Color? = nil

    var body: some View {
        Button {
            model.requestTranslationEdit(id, in: job)
        } label: {
            Text(title ?? L("Edited"))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((tint ?? Color.secondary).opacity(0.15), in: Capsule())
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(help ?? L("You edited this translation. Click to change it."))
    }
}

/// 利用者が手で直した行の、灰色の小さな印「直した」(原文の側に出す)。押すと、行を直す画面 (一覧の外のシート) を開く。
/// 見た目は、訳の「直した」の印 (`EditedTranslationBadge`) と同じ
struct EditedLineBadge: View {
    @Environment(AppModel.self) private var model
    /// 行が持つ区間の全部 (直す画面は、区間ごとに入力欄を出す)
    let ids: [UUID]
    /// 聞き取った文 (説明に出す)
    let heard: String
    let job: Job

    var body: some View {
        Button {
            model.requestLineEdit(ids, in: job)
        } label: {
            Text(L("Edited"))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("You edited this line. Heard text: %@", heard))
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
        .help(revealed ? L("Hide this line") : L("Show this line"))
        .accessibilityLabel(Text(revealed ? L("Hide this line") : L("Show this line")))
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
        if change.isApplied { return change.kind == .fix ? L("Fixed") : L("Deleted") }
        return change.kind == .fix ? L("Suggested fix") : L("Suggested deletion")
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
                Label(change.kind == .fix ? L("Mishearing fix") : L("Segment deletion"),
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
                Text(change.origin == .llm ? L("Found by: local LLM")
                     : (change.origin == .ledger ? L("Found by: learned corrections") : L("Found by: repetition rules")))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if change.isApplied {
                    Button(L("Undo")) { model.setAuditChange(change, applied: false, in: job) }
                } else {
                    Button(change.kind == .fix ? L("Apply this fix") : L("Delete this segment")) {
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
    /// 印だけにする (操作の列が狭いとき)。字は読み上げに出す
    var iconOnly = false
    @State private var showing = false

    var body: some View {
        if let audit = transcript.audit {
            Button {
                showing = true
            } label: {
                // 印だけの形は、ボタンの字にだけ掛ける (ポップオーバーの中の字まで消さないため)
                Label(Self.title(of: audit), systemImage: "checkmark.seal")
                    .actionLabelStyle(iconOnly: iconOnly)
                    .accessibilityLabel(Text(Self.title(of: audit)))
            }
            .help(L("See the audit results (fixes made and suggested fixes)"))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AuditPanel(job: job, transcript: transcript)
                    .frame(width: 460, height: 420)
            }
        } else {
            Button {
                model.audit(job)
            } label: {
                Label(L("Audit"), systemImage: "checkmark.seal")
                    .actionLabelStyle(iconOnly: iconOnly)
                    .accessibilityLabel(Text(L("Audit")))
            }
            .help(model.isLLMInstalled
                  ? L("Check for repetitions and mishearings with the LLM on your Mac")
                  : L("Check for repetitions (to also check for mishearings, download an LLM in Settings)"))
            .disabled(job.isPostActive)
        }
    }

    /// ボタンの字 (操作の列の並べ方の見積もりでも使う)
    static func title(of audit: AuditReport) -> String {
        var parts: [String] = []
        if audit.appliedFixes > 0 { parts.append(LPlural(audit.appliedFixes, one: "%d fix", other: "%d fixes")) }
        if audit.appliedDeletes > 0 {
            parts.append(LPlural(audit.appliedDeletes, one: "%d deletion", other: "%d deletions"))
        }
        if audit.pendingSuggestions > 0 {
            parts.append(LPlural(audit.pendingSuggestions, one: "%d suggestion", other: "%d suggestions"))
        }
        return parts.isEmpty ? L("Audit: no issues") : L("Audit: %@", parts.joined(separator: " · "))
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
                Text(L("Audit results")).font(.headline)
                Spacer()
                if let audit {
                    let partial = audit.isPartial == true
                    Text(audit.model.map { partial ? L("LLM: %@ (partial)", $0) : L("LLM: %@", $0) }
                         ?? (partial ? L("Rules only (partial)") : L("Rules only")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(L("Only confident fixes are applied. Check each “suggestion” before you apply it. You can undo any of them at any time."))
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
                                Text(change.kind == .fix ? L("Fix") : L("Deletion"))
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
                Text(L("Nothing to fix was found."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            HStack {
                Button(L("Undo all")) { model.revertAudit(of: job) }
                    .disabled((audit?.appliedFixes ?? 0) + (audit?.appliedDeletes ?? 0) == 0)
                Spacer()
                Button(L("Audit again")) { model.audit(job) }
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
                        Text(job.postQueue.isEmpty ? message : L("%1$@ (next: %2$@)", message, queued))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button(L("Stop")) { model.cancelPost(job) }
                }
            } else if !job.postQueue.isEmpty {
                Label(L("Waiting: %@", queued), systemImage: "clock")
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
            case .audit: return L("Audit")
            case .translate: return L("Translation")
            case .translateLines: return L("Translation of the selected sentences")
            }
        }.joined(separator: L(", "))
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
                Text(L("This recording has a lot of English. If Japanese and English take turns, you can transcribe it again with “Japanese + English”"))
                    .font(.callout.weight(.semibold))
                Text(L("It decides Japanese or English for each part and transcribes it in that language. Lines that broke with a single language may come out right. It takes about 2 to 4 times as long."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Transcribe again with Japanese + English")) {
                model.retranscribe(job, languageCode: Languages.japaneseEnglish.code)
            }
            .buttonStyle(.borderedProminent)
            Button {
                job.mixedSuggestionDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L("Close (you can also choose the language in the language menu above or in Settings)"))
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
                Text(L("Japanese and English were mixed, so it was transcribed with “Japanese + English”."))
                    .font(.callout.weight(.semibold))
                Text(L("It decides Japanese or English for each part and transcribes it in that language. To stop switching automatically, change it in the “Transcription” tab of Settings."))
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
            .help(L("Close"))
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var retryTitle: String {
        from == Languages.auto.code
            ? L("Transcribe again without “Japanese + English”")
            : L("Transcribe again with only “%@”", Languages.name(for: from))
    }
}

/// 音が続いているのに文字が少なかったので、自動で無音を飛ばさずに (VAD なしで) 文字起こししたことを知らせる。
/// 無音を飛ばしてやり直すこともできる (やり直しでは、自動で VAD なしにしない)
struct VADSkippedNotice: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text(L("There was continuous sound but very little text, so it was transcribed without skipping silence (it seems to be singing or music)."))
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            if job.url != nil {
                Button(L("Transcribe again, skipping silence")) {
                    model.redo(job, vad: true)
                }
                .disabled(!model.canRedo(job))
            }
            Button {
                job.vadSkippedNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L("Close"))
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 設定の訳す先と違う言語に訳してある結果に出す案内。設定の言語で訳し直せる (確かめてから。今の状態は履歴の版に残る)。
/// 閉じると、この起動のあいだ、この結果では出さない。
/// 監査・翻訳の最中か (版を残せるか) は、この部品の中で見る (結果の画面が見ると、進み具合が変わるたびに一覧まで描き直す)
struct TranslationLanguageNotice: View {
    @Environment(AppModel.self) private var model
    let job: Job
    /// この結果が訳した言語のコード
    let current: String
    /// 設定の訳す先の言語のコード
    let setting: String
    @State private var confirming = false

    var body: some View {
        let currentName = TranslationTarget.displayName(for: current)
        let settingName = TranslationTarget.displayName(for: setting)
        // 版を残せない時 (保存していない結果・監査や翻訳の最中) は、訳し直せない (「戻す」と同じ)
        let blocked = model.versionBlockedReason(job)
        HStack(spacing: 12) {
            Image(systemName: "character.bubble")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text(L("This result is translated into %1$@. The language set to translate into is %2$@.", currentName, settingName))
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Translate again into %@…", settingName)) {
                confirming = true
            }
            .disabled(blocked != nil)
            .help(blocked ?? "")
            Button {
                job.translationLanguageNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L("Close"))
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .alert(L("Translate again into %@?", settingName), isPresented: $confirming) {
            Button(L("Translate again")) {
                model.retranslate(job, into: setting)
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("The current %1$@ translation will be removed, and the result will be translated again into %2$@. The current state is kept as a version in the history.", currentName, settingName))
        }
    }
}

/// 「やり直す」のメニュー (結果の画面の操作の列)。録音中か・音声ファイルが在るかは、この部品の中で見る
/// (結果の画面が見ると、録音を始めた・止めたときに一覧まで描き直す)
struct RedoMenu: View {
    @Environment(AppModel.self) private var model
    let job: Job
    /// 印だけにする (操作の列が狭いとき)。字は読み上げに出す
    var iconOnly = false

    var body: some View {
        if job.url != nil {
            Menu {
                RedoMenuItems(job: job)
            } label: {
                Label(L("Transcribe again"), systemImage: "arrow.clockwise")
                    .actionLabelStyle(iconOnly: iconOnly)
                    .accessibilityLabel(Text(L("Transcribe again")))
            }
            .menuStyle(.button)
            .fixedSize()
            .help(L("Transcribe this audio again. The original result is kept"))
            .disabled(!model.canRedo(job))
        }
    }
}

/// 「やり直す」の中身 (結果の画面とメニューバーの両方で使う)
struct RedoMenuItems: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        Button(L("Transcribe again with the same settings")) { model.redo(job) }
        Button(L("Transcribe again without skipping silence (for singing and music)")) { model.redo(job, vad: false) }
        Button(L("Transcribe again, skipping silence")) { model.redo(job, vad: true) }
        Divider()
        Menu(L("Transcribe again in another language")) {
            ForEach(Languages.all) { language in
                Button(language.name) { model.redo(job, languageCode: language.code) }
            }
        }
    }
}

/// 失敗・中止した結果の「もう一度文字起こしする」(同じ設定でやり直す)。録音中か・音声ファイルが在るかは、この部品の中で見る
struct RedoAgainButton: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        if job.url != nil {
            Button(L("Try transcribing again")) { model.redo(job) }
                .disabled(!model.canRedo(job))
                .help(L("Transcribe this audio again with the same settings. The original result is kept"))
        }
    }
}

/// 翻訳・監査に LLM が必要なことを知らせる
struct LLMNeededBanner: View {
    @Environment(AppModel.self) private var model
    /// 訳す先の言語以外が主な文字起こし (翻訳も案内する)
    let wantsTranslation: Bool
    /// 訳す先の言語のコード
    let target: String

    var body: some View {
        let selection = model.currentLLM
        HStack(spacing: 12) {
            Image(systemName: wantsTranslation ? "character.bubble" : "checkmark.seal")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(wantsTranslation
                     ? L("The %@ translation and the mishearing audit use an LLM that runs on your Mac",
                         TranslationTarget.displayName(for: target))
                     : L("The mishearing audit uses an LLM that runs on your Mac (for now, only repetitions are checked)"))
                    .font(.callout.weight(.semibold))
                Text(L("%1$@ (about %2$@) is downloaded only once. Your transcriptions never leave your Mac.",
                       selection.name,
                       selection.spec.map { TimeFormat.bytes(Int64($0.approxMB) * 1_000_000) } ?? "—"))
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
            .help(L("Close (you can download it at any time in the “Audit & translation” tab of Settings)"))
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
                Button(L("Stop")) { model.cancelLLMDownload(spec) }
            case .notInstalled:
                if prominent {
                    Button(L("Download")) { model.downloadLLM(spec) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(L("Download")) { model.downloadLLM(spec) }
                        .buttonStyle(.bordered)
                }
            case .installed:
                EmptyView()
            }
        }
        // 設定の「監査・翻訳」タブを開く (メモリ 8 GB の Mac で軽い 2B を選ぶときなど)
        Button(L("Choose in Settings…")) {
            model.settingsTab = .llm
            openSettings()
        }
        .help(L("Opens the “Audit & translation” tab of Settings. You can also choose the light 2B or the accurate 9B"))
    }
}

/// 書き出し (原文 / 訳 / 対訳 × 形式)
struct ExportMenu: View {
    let hasTranslation: Bool
    /// その結果の訳す先の言語のコード (訳・対訳の名前に使う)
    let target: String
    /// メモが空かどうかは、この部品の中で見る (結果の画面が見ると、メモを書き始めたときに一覧まで描き直す)
    let job: Job
    /// 印だけにする (操作の列が狭いとき)。字は読み上げと .help に出す
    var iconOnly = false

    var body: some View {
        Menu {
            ExportMenuItems(hasTranslation: hasTranslation, target: target, hasNotes: job.hasNotes)
        } label: {
            Label(L("Export"), systemImage: "square.and.arrow.up")
                .actionLabelStyle(iconOnly: iconOnly)
                .accessibilityLabel(Text(L("Export")))
        }
        .menuStyle(.button)
        .fixedSize()
        .iconOnlyHelp(iconOnly, L("Export"))
    }
}

/// 操作の列の、印だけの形 (狭いとき)
extension View {
    /// iconOnly のときは、ボタンやメニューの字を隠して印だけにする。そうでないときは、今のまま
    @ViewBuilder
    func actionLabelStyle(iconOnly: Bool) -> some View {
        if iconOnly {
            labelStyle(.iconOnly)
        } else {
            self
        }
    }

    /// 印だけのときに、字を .help に出す (ほかに .help が無いボタン用)
    @ViewBuilder
    func iconOnlyHelp(_ iconOnly: Bool, _ text: String) -> some View {
        if iconOnly {
            help(text)
        } else {
            self
        }
    }
}

struct ExportMenuItems: View {
    @Environment(AppModel.self) private var model
    let hasTranslation: Bool
    /// その結果の訳す先の言語のコード (「日本語訳」「対訳 (原文 + 日本語)」の名前に使う)
    let target: String
    /// メモが空でない (「メモ (.md)」も出す)
    let hasNotes: Bool

    var body: some View {
        formats
        if hasNotes {
            Divider()
            Button(L("Notes (.md)")) { model.exportNotes() }
        }
    }

    @ViewBuilder
    private var formats: some View {
        if hasTranslation {
            ForEach(ExportContent.allCases) { content in
                Section(content.displayName(target: target)) {
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
            Text(L("Audio file not found: %@", path))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button(L("Choose the audio again…")) { model.relocateAudio(of: job) }
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
            .help(L("Play / pause (Space)"))
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
