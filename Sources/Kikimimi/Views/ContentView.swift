import KikimimiCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            JobListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if model.isRecording {
                RecordingView()
            } else if let job = model.selectedJob {
                TranscriptDetailView(job: job)
            } else {
                EmptyStateView()
            }
        }
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL }
            guard !files.isEmpty else { return false }
            model.enqueue(files)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .overlay {
                        Label("ここに落として文字起こし", systemImage: "waveform.badge.plus")
                            .font(.title2.weight(.semibold))
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .allowsHitTesting(false)
            }
        }
        .alert("お知らせ", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label("開く", systemImage: "folder.badge.plus")
            }
            .help("音声・動画ファイルを開く (⌘O)")
            .disabled(model.isRecording)
        }
        ToolbarItem(placement: .principal) {
            ModelBar()
        }
        ToolbarItem(placement: .primaryAction) {
            RecordButton()
        }
    }
}

/// 言語とモデルの選択、モデルの状態
struct ModelBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Picker("言語", selection: $model.languageCode) {
                ForEach(Languages.all) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            .help("話されている言語。分かっているなら指定すると精度が上がります。日本語と英語が入れ替わる録音は「日本語＋英語」")

            Picker("モデル", selection: $model.modelID) {
                ForEach(ModelCatalog.all) { spec in
                    Text(menuLabel(spec)).tag(spec.id)
                }
            }
            .labelsHidden()
            .frame(width: 230)
            .disabled(model.isRecording)

            switch model.availability(of: model.currentModel) {
            case .installed:
                Label("準備完了", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("モデルは取得済みです。音声は Mac の外に出ません")
            case .notInstalled:
                Button {
                    model.download(model.currentModel)
                } label: {
                    Label("取得 (\(TimeFormat.bytes(Int64(model.currentModel.approxMB) * 1_000_000)))", systemImage: "arrow.down.circle")
                }
                .help("Hugging Face からモデルをダウンロードします (初回のみ)")
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 80)
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func menuLabel(_ spec: WhisperModelSpec) -> String {
        let mark = model.installedModelIDs.contains(spec.id) ? "✓ " : ""
        let rec = spec.recommended ? " (おすすめ)" : ""
        return "\(mark)\(spec.displayName)\(rec)"
    }
}

struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            if model.isRecording {
                Label("停止して文字起こし", systemImage: "stop.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
            } else {
                Label("録音", systemImage: "mic.circle")
            }
        }
        .help(model.isRecording ? "録音を止めて、全体を文字起こし (⌘R)" : "マイクで録音して文字起こし (⌘R)")
    }
}

/// 録音中の画面
struct RecordingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                Text("録音中")
                    .font(.title3.weight(.semibold))
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = model.recordingStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
                Text(TimeFormat.short(elapsed))
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            LevelMeter(level: model.recordingLevel)
                .frame(width: 300, height: 8)

            GroupBox {
                ScrollView {
                    Text(previewText)
                        .font(.title3)
                        .foregroundStyle(model.livePreviewText.isEmpty ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                }
                .frame(height: 120)
            } label: {
                Text("直近の内容 (プレビュー)")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 640)

            Button {
                Task { await model.toggleRecording() }
            } label: {
                Label("停止して文字起こし", systemImage: "stop.circle.fill")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            Text("止めると、録音全体をもう一度ていねいに文字起こしします。録音は自動で保存されます。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 20)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewText: String {
        if !model.livePreviewText.isEmpty { return model.livePreviewText }
        if !model.livePreview { return "プレビューはオフです (設定で切り替えられます)" }
        if model.availability(of: model.currentModel) != .installed {
            return "モデルが未取得のため、プレビューは出ません。停止後にモデルを取得してから文字起こしします。"
        }
        return "話し始めると、数秒ごとにここへ直近の内容が出ます。"
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(level > 0.3 ? Color.orange : Color.green)
                    .frame(width: geo.size.width * CGFloat(min(1, Double(level) * 5)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 狭いウインドウでは、文を切らずにスクロールできるようにする (収まるときは、これまでどおり真ん中に置く)
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 60, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("ききみみ")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("音声や動画をここに落とすと、Mac の中だけで文字に起こします。\nマイクで録音して起こすこともできます。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    if model.availability(of: model.currentModel) == .notInstalled {
                        VStack(spacing: 8) {
                            Text("最初に音声認識モデル「\(model.currentModel.displayName)」(約 \(model.currentModel.approxMB) MB) を一度だけダウンロードします。")
                                .font(.callout)
                            Button {
                                model.download(model.currentModel)
                            } label: {
                                Label("モデルをダウンロード", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    } else if case .downloading(let fraction) = model.availability(of: model.currentModel) {
                        VStack(spacing: 6) {
                            ProgressView(value: fraction)
                                .frame(width: 280)
                            Text("モデルをダウンロード中 \(Int(fraction * 100))%")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            model.presentOpenPanel()
                        } label: {
                            Label("ファイルを開く", systemImage: "folder")
                        }
                        Button {
                            Task { await model.toggleRecording() }
                        } label: {
                            Label("マイクで録音", systemImage: "mic")
                        }
                    }
                    .controlSize(.large)
                    .padding(.top, 4)

                    // 監査・翻訳の LLM (任意)。結果の画面を待たずに、ここでも取得できるようにする。
                    // 任意なので、文字起こしの操作より後に置く (収まらないときにスクロールの先に回るのは、こちら)
                    if !model.isLLMInstalled && (model.autoAudit || model.autoTranslate)
                        && !model.llmSetupCardDismissed && !model.llmBannerDismissed {
                        LLMSetupCard()
                    } else if model.isLLMInstalled {
                        Label("監査・翻訳: \(model.currentLLM.name)", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// 始めの画面の、監査・翻訳の LLM の案内 (取得は任意なので、音声認識モデルの取得より控えめに出す)
struct LLMSetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = model.currentLLM
        let size = selection.spec.map { "(約 \(TimeFormat.bytes(Int64($0.approxMB) * 1_000_000))) " } ?? ""
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "character.bubble")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text("聞き取りミスの監査と、英語から日本語への翻訳もできます")
                    .font(.callout.weight(.semibold))
                Text("どちらも Mac の中で動く LLM「\(selection.name)」\(size)を使い、訳は原文と左右に並べて表示します。なくても文字起こしはできるので、ダウンロードはあとからでも構いません。文字起こしの内容は Mac の外に出ません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    LLMDownloadControls(prominent: false)
                }
                .padding(.top, 2)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                // 閉じるのは始めの画面の案内だけ (「あとから」の案内として、結果の画面の案内は出す)
                model.llmSetupCardDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("閉じる (設定の「監査・翻訳」タブから、いつでも取得できます)")
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
