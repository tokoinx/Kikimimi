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
            // 音声・動画だけを読み込む。録音中は読み込まない
            model.importDropped(urls)
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                // 録音中は、受けない事が分かる印・文・灰色の枠にする
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(model.isRecording ? Color.secondary : Color.accentColor,
                                  style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .overlay {
                        Label(model.isRecording ? L("You can’t add files while recording. Stop recording, then drop them.") : L("Drop here to transcribe"),
                              systemImage: model.isRecording ? "nosign" : "waveform.badge.plus")
                            .font(.title2.weight(.semibold))
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .allowsHitTesting(false)
            }
        }
        .alert(L("Notice"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // 履歴の画面 (操作列の「履歴」、メニューの「版として保存…」「履歴…」)
        .sheet(isPresented: Binding(
            get: { model.historyJobID != nil },
            set: { if !$0 { model.historyJobID = nil } }
        )) {
            if let job = model.jobs.first(where: { $0.id == model.historyJobID }) {
                HistorySheet(job: job)
                    .environment(model)
                    // 画面の言語を変えたら作り直す
                    .id(model.uiLanguage)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label(L("Open"), systemImage: "folder.badge.plus")
            }
            .help(L("Open audio or video files (⌘O). You can also drop files on the window."))
            .disabled(model.isRecording)
        }
        ToolbarItem(placement: .navigation) {
            Button {
                model.requestDelete(model.selectedJob)
            } label: {
                Label(L("Move to Trash"), systemImage: "trash")
            }
            .help(L("Move the selected result to the Trash (or press Delete in the list)"))
            .disabled(model.selectedJob == nil || model.isRecording)
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
    /// 入れていないモデルを、この Picker で選んだ時に、案内 (ポップオーバー) を出す印
    @State private var showDownloadHint = false

    /// モデルの Picker の選択。利用者がここで選んだ時だけ、入れていないモデルなら案内を出す。
    /// (設定の画面で変えた時や、起動した時には出さないため、onChange ではなく、ここで見る)
    private var modelSelection: Binding<String> {
        Binding(
            get: { model.modelID },
            set: { newID in
                model.modelID = newID
                showDownloadHint = model.availability(of: model.currentModel) == .notInstalled
            }
        )
    }

    private var isCurrentModelNotInstalled: Bool {
        model.availability(of: model.currentModel) == .notInstalled
    }

    private var currentModelSize: String {
        TimeFormat.bytes(Int64(model.currentModel.approxMB) * 1_000_000)
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Picker(L("Spoken language"), selection: $model.languageCode) {
                ForEach(Languages.all) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            .help(L("The spoken language. Choosing it, if you know it, makes the result more accurate. For recordings that switch between Japanese and English, choose “Japanese + English”."))

            Picker(L("Model"), selection: modelSelection) {
                ForEach(ModelCatalog.all) { spec in
                    Text(menuLabel(spec)).tag(spec.id)
                }
            }
            .labelsHidden()
            .frame(width: 230)
            .disabled(model.isRecording)

            switch model.availability(of: model.currentModel) {
            case .installed:
                Label(L("Ready"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help(L("The model is downloaded. Audio never leaves your Mac."))
            case .notInstalled:
                Button {
                    model.download(model.currentModel)
                } label: {
                    // ツールバーでは、青い印だけにする (文字は、説明と、下の案内に出す)。
                    // ツールバーの中では、ボタンの形と色の指定 (borderedProminent・tint) が効かず、灰色になる
                    // (実機で見た) ので、印の色をここで付ける
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .contentShape(Circle())
                        .accessibilityLabel(L("Download model"))
                }
                .buttonStyle(.plain)
                .help(L("Download the model (about %@, first time only). It is downloaded from Hugging Face.", currentModelSize))
                .popover(isPresented: $showDownloadHint, arrowEdge: .bottom) {
                    downloadHint
                }
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 80)
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        // 入れていない状態でなくなったら (ダウンロードが始まった・入れてあるモデルに変えた)、印を下ろす。
        // ボタンごと消えるので、印が残ると、次に関係の無い時に案内が出てしまう
        .onChange(of: isCurrentModelNotInstalled) { _, notInstalled in
            if !notInstalled { showDownloadHint = false }
        }
    }

    /// 入れていないモデルを選んだ時の案内
    private var downloadHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Please download the model"))
                .font(.headline)
            Text(L("“%1$@” is not downloaded yet (about %2$@). Once it is downloaded, you can use it for transcription.", model.currentModel.displayName, currentModelSize))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("If you open a file without downloading it, it is downloaded automatically when transcription starts."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Later")) {
                    showDownloadHint = false
                }
                Button {
                    model.download(model.currentModel)
                    showDownloadHint = false
                } label: {
                    Label(L("Download"), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func menuLabel(_ spec: WhisperModelSpec) -> String {
        // チェックの印は、選んでいるモデルにだけ付く (メニューが自分で付ける)。
        // 入れてあるモデルにも「✓」を付けていたが、2 つ選んでいるように見えるので、やめた
        spec.recommended ? L("%@ (recommended)", spec.displayName) : spec.displayName
    }
}

struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            if model.isRecording {
                Label(L("Stop and transcribe"), systemImage: "stop.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
            } else {
                Label(L("Record"), systemImage: "mic.circle")
            }
        }
        .help(model.isRecording ? L("Stop recording and transcribe all of it (⌘R)") : L("Record with the microphone and transcribe (⌘R)"))
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
                Text(L("Recording"))
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
                Text(L("Latest speech (preview)"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 640)

            Button {
                Task { await model.toggleRecording() }
            } label: {
                Label(L("Stop and transcribe"), systemImage: "stop.circle.fill")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            Text(L("When you stop, the whole recording is transcribed again carefully. The recording is saved automatically."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 20)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewText: String {
        if !model.livePreviewText.isEmpty { return model.livePreviewText }
        if !model.livePreview { return L("Preview is off (you can turn it on in Settings)") }
        if model.availability(of: model.currentModel) != .installed {
            return L("The model is not downloaded, so there is no preview. After you stop, the model is downloaded and then the recording is transcribed.")
        }
        return L("When you start speaking, the latest speech appears here every few seconds.")
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
                    Text(L("Kikimimi"))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text(L("Drop audio or video here to transcribe it, entirely on your Mac.\nYou can also record with the microphone and transcribe it."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    // モデルが 1 つも入っていない時 (初めて使う時) だけ出す。
                    // 1 つでも入っていれば、入れていないモデルを選んだ時の案内は、ツールバーの印と、その下の案内に任せる
                    if model.installedModelIDs.isEmpty, model.availability(of: model.currentModel) == .notInstalled {
                        VStack(spacing: 8) {
                            Text(L("Please download the model"))
                                .font(.headline)
                            Text(L("First, download the speech recognition model “%1$@” (about %2$d MB) once.", model.currentModel.displayName, model.currentModel.approxMB))
                                .font(.callout)
                            Button {
                                model.download(model.currentModel)
                            } label: {
                                Label(L("Download model"), systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    } else if case .downloading(let fraction) = model.availability(of: model.currentModel) {
                        VStack(spacing: 6) {
                            ProgressView(value: fraction)
                                .frame(width: 280)
                            Text(L("Downloading the model %d%%", Int(fraction * 100)))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            model.presentOpenPanel()
                        } label: {
                            Label(L("Open a file…"), systemImage: "folder")
                        }
                        Button {
                            Task { await model.toggleRecording() }
                        } label: {
                            Label(L("Record with microphone"), systemImage: "mic")
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
                        Label(L("Audit & translation: %@", model.currentLLM.name), systemImage: "checkmark.circle")
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
        let detail = selection.spec.map {
            L("Both use the LLM “%1$@” (about %2$@), which runs on your Mac, and the translation is shown side by side with the original. You can transcribe without it, so you can download it later. The transcription never leaves your Mac.",
              selection.name, TimeFormat.bytes(Int64($0.approxMB) * 1_000_000))
        } ?? L("Both use the LLM “%@”, which runs on your Mac, and the translation is shown side by side with the original. You can transcribe without it, so you can download it later. The transcription never leaves your Mac.", selection.name)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "character.bubble")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("You can also audit for mishearings and translate from other languages into %@",
                       TranslationTarget.displayName(for: model.translationLanguage)))
                    .font(.callout.weight(.semibold))
                Text(detail)
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
            .help(L("Close (you can download it any time in the “Audit & translation” tab of Settings)"))
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
