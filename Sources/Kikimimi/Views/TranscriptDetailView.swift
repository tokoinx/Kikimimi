import KikimimiCore
import SwiftUI

struct TranscriptDetailView: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var cache = TranscriptViewCache()

    var body: some View {
        // 翻訳の状況・言語の名前は、文字起こしが変わったときだけ数え直す (長い録音では区間が数千あるため。
        // 画面は、進み具合や検索欄の入力でも描き直される)
        let summary = job.transcript.map { cache.summary(of: $0, job: job) }
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

            if job.status == .running || job.status == .queued {
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
                if bilingual {
                    BilingualHeader(label: summary.languageLabel, showTimestamp: model.showTimestamps,
                                    showPlayMark: model.canPlayLines(of: job))
                    Divider()
                }
                TranscriptListView(job: job, items: cache.items(of: transcript, job: job, bilingual: bilingual,
                                                                query: model.searchText, make: listItems),
                                   bilingual: bilingual, emptyMessage: emptyMessage)
            } else {
                Spacer()
            }
        }
        .navigationTitle(job.name)
        .navigationSubtitle(subtitle(summary))
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

    private func subtitle(_ summary: TranscriptViewCache.Summary?) -> String {
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
            Spacer()
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
            ExportMenu(hasTranslation: stats.hasTranslation)
                .disabled(job.status != .done)
        }
    }

    // MARK: 本文
    /// 一覧に出す行 (対訳表示なら訳ごと、そうでなければ区間ごと)。検索語で絞る (作り直すのは TranscriptViewCache が決める)
    private func listItems(_ transcript: Transcript, bilingual: Bool, query: String) -> [TranscriptListItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let changes = Dictionary((transcript.audit?.changes ?? []).map { ($0.original.id, $0) },
                                 uniquingKeysWith: { a, _ in a })
        // 「日本語＋英語」で 2 つの言語が混ざるときだけ、行に言語の印 (英・日) を付ける
        let tags = transcript.spokenLanguages.count >= 2
        // 行の「訳」は、文字起こしが終わってから (訳がある文 = ほかの区間の訳に含まれる区間も、訳がある行として扱う)
        let done = job.status == .done
        let covered = done ? transcript.coveredIDs : Set<UUID>()
        let items: [TranscriptListItem]
        if bilingual {
            items = transcript.bilingualUnits().map { unit in
                let translated = unit.segments[0].translation != nil
                return TranscriptListItem(id: unit.id, start: unit.start, end: unit.end, text: unit.text,
                                          japanese: unit.japanese, isOriginalJapanese: unit.isOriginalJapanese,
                                          changes: unit.segments.compactMap { changes[$0.id] },
                                          languageTag: tags ? LanguageTag.short(unit.language) : nil,
                                          canTranslate: done && unit.japanese == nil && !covered.contains(unit.id),
                                          isTranslated: done && translated)
            }
        } else {
            items = transcript.segments.map { seg in
                let translated = seg.translation != nil || covered.contains(seg.id)
                return TranscriptListItem(id: seg.id, start: seg.start, end: seg.end, text: seg.text,
                                          japanese: nil, isOriginalJapanese: false, changes: changes[seg.id].map { [$0] } ?? [],
                                          languageTag: tags ? LanguageTag.short(seg.language) : nil,
                                          canTranslate: done && !translated && transcript.needsTranslation(seg),
                                          isTranslated: done && translated)
            }
        }
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.text.localizedCaseInsensitiveContains(q) || ($0.japanese?.localizedCaseInsensitiveContains(q) ?? false)
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

/// 結果の画面で、区間の数だけ手間がかかるもの (翻訳の状況・言語の名前・一覧の行) を覚えておく。
/// 文字起こし・ジョブの状態・表示の条件が同じなら、前に作ったものを返す。
/// (文字起こしの比べは、区間の数が違えばすぐ終わり、同じ配列ならその場で同じとわかる)
@MainActor
final class TranscriptViewCache {
    struct Summary {
        var stats = Transcript.TranslationStats()
        var spokenLanguages: [String] = []
        var languageLabel: String?
    }

    private struct SummaryKey: Equatable {
        let job: UUID
        let transcript: Transcript
        let done: Bool
    }

    private struct ItemsKey: Equatable {
        let summary: SummaryKey
        let bilingual: Bool
        let query: String
    }

    private var summaryKey: SummaryKey?
    private var summaryValue = Summary()
    private var itemsKey: ItemsKey?
    private var itemsValue: [TranscriptListItem] = []

    func summary(of transcript: Transcript, job: Job) -> Summary {
        let key = SummaryKey(job: job.id, transcript: transcript, done: job.status == .done)
        if key != summaryKey {
            // 翻訳の状況は、文字起こしが終わってから数える (最中は区間が増えるたびに数え直すことになるため)
            let stats = key.done ? transcript.translationStats : Transcript.TranslationStats()
            summaryValue = Summary(stats: stats, spokenLanguages: transcript.spokenLanguages,
                                   languageLabel: transcript.languageLabel)
            summaryKey = key
        }
        return summaryValue
    }

    func items(of transcript: Transcript, job: Job, bilingual: Bool, query: String,
               make: (Transcript, Bool, String) -> [TranscriptListItem]) -> [TranscriptListItem] {
        let key = ItemsKey(summary: SummaryKey(job: job.id, transcript: transcript, done: job.status == .done),
                           bilingual: bilingual, query: query)
        if key != itemsKey {
            itemsValue = make(transcript, bilingual, query)
            itemsKey = key
        }
        return itemsValue
    }
}

/// 一覧の 1 行 (区間 1 つ、または訳 1 つ分の区間)
struct TranscriptListItem: Identifiable, Hashable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let japanese: String?
    let isOriginalJapanese: Bool
    /// この行に当たる監査の直し
    let changes: [AuditChange]
    /// 原文の言語の印 (英・日)。2 つの言語が混ざる文字起こしのときだけ
    var languageTag: String? = nil
    /// 行の「訳」を出す (日本語以外で、まだ訳がない)
    var canTranslate = false
    /// 訳がある文の行 (右クリックで訳し直せる)
    var isTranslated = false
}

/// 行の言語の印
enum LanguageTag {
    static func short(_ code: String?) -> String? {
        switch code {
        case "ja": return "日"
        case "en": return "英"
        default: return nil
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

/// 本文の一覧。再生位置 (0.2 秒ごとに変わる) はここでは見ない (見ると、0.2 秒ごとに数千の行を並べ直すことになる)。
/// いまの位置にある行は CurrentLineTracker が探して、行が変わったときだけ知らせる
struct TranscriptListView: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let items: [TranscriptListItem]
    let bilingual: Bool
    let emptyMessage: String
    /// ふつうの再生で、いまの位置にある行
    @State private var currentID: UUID?

    var body: some View {
        let translating = job.postState.task == .translate || job.postQueue.contains(.translate)
        let canPlay = model.canPlayLines(of: job)
        let playingID = model.player.playingLineID
        let showTimestamps = model.showTimestamps
        let highlight = model.searchText
        ScrollViewReader { proxy in
            // 行に .id() を付けない (付けると List がすべての行を一度に作るようになる。scrollTo は ForEach の id で動く)
            List {
                ForEach(items) { item in
                    // 1 行だけを再生しているあいだは、その行だけを色付けする (再生位置の色と重ねない)
                    PlayableRow(item: item, job: job, canPlay: canPlay, isPlaying: playingID == item.id,
                                isCurrent: playingID == nil && currentID == item.id) {
                        if bilingual {
                            BilingualRow(item: item, isTranslating: translating, showTimestamp: showTimestamps,
                                         highlight: highlight, job: job)
                        } else {
                            SegmentRow(item: item, showTimestamp: showTimestamps,
                                       highlight: highlight, job: job)
                        }
                    }
                }
                if items.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .background(CurrentLineTracker(job: job, items: items, currentID: $currentID))
            .onChange(of: currentID) { _, id in
                // 1 行だけの再生では、押した行が見えているので追いかけない
                if let id, model.player.isPlaying, model.player.playingLineID == nil {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .onChange(of: items.count) { _, _ in
                if job.status == .running, let last = items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

/// 再生位置 (0.2 秒ごとに変わる) を見るのは、この見えない部品だけ。
/// いまの位置にある行を、行の始まりの時刻で二分探索して探し、行が変わったときだけ一覧に知らせる
private struct CurrentLineTracker: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let items: [TranscriptListItem]
    @Binding var currentID: UUID?

    var body: some View {
        let id = currentLine()
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                if currentID != id { currentID = id }
            }
            .onChange(of: id) { _, new in
                currentID = new
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

/// 行そのものを再生のボタンにする。クリックでその行だけを再生し、再生中の行をもう一度クリックすると止める。
/// 行の文字はクリックを再生に使うため選べない (コピーは右クリックの「この行をコピー」か、上の「コピー」)
struct PlayableRow<Content: View>: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptListItem
    let job: Job
    /// 音声を再生できる (できないときは、クリックしても何もせず、再生の印も出さない)
    let canPlay: Bool
    /// この行だけを再生している
    let isPlaying: Bool
    /// ふつうの再生で、いまの位置がこの行にある
    let isCurrent: Bool
    let content: Content
    @State private var hovering = false

    init(item: TranscriptListItem, job: Job, canPlay: Bool, isPlaying: Bool, isCurrent: Bool,
         @ViewBuilder content: () -> Content) {
        self.item = item
        self.job = job
        self.canPlay = canPlay
        self.isPlaying = isPlaying
        self.isCurrent = isCurrent
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if canPlay {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
            }
            content
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if canPlay { toggle() }
        }
        .onHover { inside in
            hovering = inside
        }
        .help(canPlay ? hint : "")
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
        .accessibilityLabel(Text(canPlay ? item.text + "。" + hint : item.text))
        .accessibilityAddTraits(canPlay ? .isButton : [])
        .accessibilityAction {
            if canPlay { toggle() }
        }
        .listRowBackground(background)
    }

    private var hint: String {
        isPlaying ? "クリックで停止" : "クリックで、この行だけを再生"
    }

    private var background: Color {
        if isPlaying { return Color.accentColor.opacity(0.24) }
        if isCurrent { return Color.accentColor.opacity(0.12) }
        if hovering && canPlay { return Color.primary.opacity(0.06) }
        return Color.clear
    }

    private func toggle() {
        model.player.toggleLine(id: item.id, start: item.start, end: item.end)
    }
}

struct SegmentRow: View {
    let item: TranscriptListItem
    let showTimestamp: Bool
    let highlight: String
    let job: Job

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if showTimestamp {
                TimestampLabel(time: item.start)
            }
            LanguageTagLabel(tag: item.languageTag)
            Text(highlighted(item.text, highlight))
                .frame(maxWidth: .infinity, alignment: .leading)
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
    let item: TranscriptListItem
    let isTranslating: Bool
    let showTimestamp: Bool
    let highlight: String
    let job: Job

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if showTimestamp {
                TimestampLabel(time: item.start)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                LanguageTagLabel(tag: item.languageTag)
                Text(highlighted(item.text, highlight))
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        Menu {
            ExportMenuItems(hasTranslation: hasTranslation)
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

    var body: some View {
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

/// 再生・シーク
struct PlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.player
        HStack(spacing: 12) {
            Button {
                p.togglePlay()
            } label: {
                Image(systemName: p.isPlaying ? "pause.fill" : "play.fill")
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
        }
    }
}
