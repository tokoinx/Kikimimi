import KikimimiCore
import SwiftUI

struct TranscriptDetailView: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
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

            if job.transcript != nil {
                controls
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                Divider()
                segmentList
            } else {
                Spacer()
            }
        }
        .navigationTitle(job.name)
        .navigationSubtitle(subtitle)
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

    private var subtitle: String {
        guard let t = job.transcript else { return "" }
        var parts: [String] = []
        if let l = t.language { parts.append(Languages.name(for: l)) }
        if let m = t.model, let spec = ModelCatalog.spec(id: m) { parts.append(spec.displayName) }
        return parts.joined(separator: " · ")
    }

    // MARK: 操作列
    private var controls: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            TextField("結果を検索", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Toggle("時刻", isOn: $model.showTimestamps)
                .toggleStyle(.checkbox)
            Spacer()
            Button {
                model.copySelectedText()
            } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.displayName) { model.export(as: format) }
                }
            } label: {
                Label("書き出す", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(job.status != .done)
        }
    }

    // MARK: 本文
    private var filteredSegments: [TranscriptSegment] {
        let segs = job.transcript?.segments ?? []
        let q = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return segs }
        return segs.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private var segmentList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(filteredSegments) { seg in
                    SegmentRow(
                        segment: seg,
                        showTimestamp: model.showTimestamps,
                        highlight: model.searchText,
                        isCurrent: isCurrent(seg)
                    )
                    .id(seg.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if job.url != nil {
                            model.player.seek(to: seg.start, andPlay: true)
                        }
                    }
                }
                if filteredSegments.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .onChange(of: model.player.currentTime) { _, _ in
                if model.player.isPlaying, let cur = filteredSegments.first(where: isCurrent) {
                    withAnimation { proxy.scrollTo(cur.id, anchor: .center) }
                }
            }
            .onChange(of: job.transcript?.segments.count ?? 0) { _, _ in
                if job.status == .running, let last = filteredSegments.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
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

    private func isCurrent(_ seg: TranscriptSegment) -> Bool {
        guard model.player.url != nil, model.player.url == job.url else { return false }
        let t = model.player.currentTime
        return t >= seg.start && t < max(seg.end, seg.start + 0.3)
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let showTimestamp: Bool
    let highlight: String
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if showTimestamp {
                Text(TimeFormat.short(segment.start))
                    .monospacedDigit()
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 52, alignment: .trailing)
            }
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private var attributed: AttributedString {
        var s = AttributedString(segment.text)
        let q = highlight.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return s }
        var searchStart = s.startIndex
        while searchStart < s.endIndex,
              let r = s[searchStart...].range(of: q, options: [.caseInsensitive]) {
            s[r].backgroundColor = Color.yellow.opacity(0.5)
            searchStart = r.upperBound
        }
        return s
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
            .help("再生 / 一時停止")
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
