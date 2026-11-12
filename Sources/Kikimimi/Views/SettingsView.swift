import KikimimiCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            TranscriptionSettingsForm()
                .tabItem { Label("文字起こし", systemImage: "waveform") }
                .tag(SettingsTab.transcription)
            LLMSettingsForm()
                .tabItem { Label("監査・翻訳", systemImage: "character.bubble") }
                .tag(SettingsTab.llm)
        }
        // 「監査・翻訳」のタブが、スクロールせずに収まる大きさ
        .frame(width: 600, height: 680)
    }
}

/// 設定の「文字起こし」タブ
struct TranscriptionSettingsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("文字起こし") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("言語", selection: $model.languageCode) {
                        ForEach(Languages.all) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    if model.languageCode == Languages.japaneseEnglish.code {
                        Text("日本語と英語が入れ替わる録音向けです。区切りごとに、話している言語を日本語か英語かで判定して、その言語で文字にします。判定のぶん、「日本語」の設定の 2〜4 倍ほどの時間がかかります (言語の入れ替わりや短い差し込みが多いほど長くなります)。どちらか一方だけの録音には、その言語を選んでください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Picker("モデル", selection: $model.modelID) {
                    ForEach(ModelCatalog.all) { spec in
                        Text(spec.displayName + (spec.recommended ? " (おすすめ)" : "")).tag(spec.id)
                    }
                }
                Toggle("精度を優先する (ビームサーチ)", isOn: $model.preferAccuracy)
                Toggle("無音を飛ばす (VAD)", isOn: $model.useVAD)
                Toggle("定番の誤認識と、同じ文の繰り返しを取り除く", isOn: $model.filterHallucinations)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("日本語と英語が混ざっている録音は、自動で「日本語＋英語」で文字にする", isOn: $model.autoMixedLanguage)
                    Text("「日本語」「英語」「自動判定」のとき、文字にする前に録音のところどころの言語を確かめます (数秒〜数十秒)。混ざっていて切り替えたときは、「日本語」の 2〜4 倍ほどの時間がかかります。1 つの言語だけの録音は、確かめる時間のほかは変わりません。無音を飛ばす (VAD) が必要です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("録音中にプレビューを出す", isOn: $model.livePreview)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("語彙のヒント", text: $model.initialPrompt, prompt: Text("例: ロブロックス, Roblox Studio, ききみみ"))
                    Text("固有名詞や専門用語を書いておくと、その表記で出やすくなります。空欄でも構いません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("モデル") {
                ForEach(ModelCatalog.all) { spec in
                    ModelRow(spec: spec)
                }
                HStack {
                    Button("手元のファイルを追加…") { model.importModelFile() }
                    Button("モデルのフォルダを開く") { model.revealModelsFolder() }
                }
            }

            Section {
                Text("音声認識には、無料・オープンソースの whisper.cpp (OpenAI Whisper の C/C++ 実装) を使い、Mac の GPU (Metal) で動きます。音声も文字起こしの内容も Mac の外に送られません。インターネットを使うのは、モデルを初めて取得するときだけです。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 設定の「監査・翻訳」タブ
struct LLMSettingsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("監査・翻訳 (ローカル LLM)") {
                Toggle("文字起こしのあとに監査する (繰り返し・聞き取りミスの見直し)", isOn: $model.autoAudit)
                Toggle("日本語以外の区間を、日本語に翻訳する", isOn: $model.autoTranslate)
                Picker("LLM", selection: $model.llmModelID) {
                    ForEach(LLMCatalog.all) { spec in
                        Text(spec.displayName + (spec.recommended ? " (おすすめ)" : "")).tag(spec.id)
                    }
                    ForEach(model.customLLMFiles, id: \.self) { name in
                        Text("手持ち: \(name)").tag("file:" + name)
                    }
                }
                ForEach(LLMCatalog.all) { spec in
                    LLMModelRow(spec: spec)
                }
                ForEach(model.customLLMFiles, id: \.self) { name in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                            Text("取り込んだ GGUF").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("削除") { model.deleteLLMFile(name) }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("手元の GGUF を追加…") { model.importLLMFile() }
                            .disabled(model.importingLLM)
                        Button("LLM のフォルダを開く") { model.revealLLMFolder() }
                        if model.importingLLM {
                            ProgressView().controlSize(.small)
                            Text("取り込み中…").foregroundStyle(.secondary)
                        }
                    }
                    Text("保存先: \(model.llmFolderPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("監査役は、同じ文の繰り返しと、文脈から見て明らかな聞き間違いを見つけます。自信のある直しだけを反映し、それ以外は「提案」として残すので、確かめてから反映できます。どの直しも元に戻せます。この Mac のメモリは \(MemoryBudget.physicalGB) GB です\(MemoryBudget.isTight ? " (少なめなので、文字起こしと LLM を交互に読み込みます)" : "")。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LearnedCorrectionsSection()

            AdapterSection()

            Section {
                Text("監査と翻訳には、無料・オープンソースの llama.cpp と Qwen3.5 を使い、Mac の GPU (Metal) で動きます。文字起こしの内容は Mac の外に送られません。インターネットを使うのは、LLM を初めて取得するときだけです。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LLMModelRow: View {
    @Environment(AppModel.self) private var model
    let spec: LLMModelSpec

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.displayName + (spec.recommended ? " (おすすめ)" : ""))
                Text("\(spec.summary) 約 \(TimeFormat.bytes(Int64(spec.approxMB) * 1_000_000))・\(spec.license)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if spec.recommendedMemoryGB > MemoryBudget.physicalGB {
                    Text("この Mac (メモリ \(MemoryBudget.physicalGB) GB) では重いかもしれません")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            switch model.llmAvailability(of: spec) {
            case .installed:
                Label("取得済み", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                Button("削除") { model.deleteLLM(spec) }
            case .notInstalled:
                Button("ダウンロード") {
                    // 使える LLM をまだ選んでいなければ、取得するものを選ぶ
                    // (始めの画面・結果の画面の案内がこの取得を示し、取得後の監査・翻訳もこれを使う)
                    if !model.isLLMInstalled { model.llmModelID = spec.id }
                    model.downloadLLM(spec)
                }
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 90)
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("中止") { model.cancelLLMDownload(spec) }
            }
        }
    }
}

struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let spec: WhisperModelSpec

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.displayName + (spec.recommended ? " (おすすめ)" : ""))
                Text("\(spec.summary) 約 \(spec.approxMB) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.availability(of: spec) {
            case .installed:
                Label("取得済み", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                Button("削除") { model.deleteModel(spec) }
            case .notInstalled:
                Button("ダウンロード") { model.download(spec) }
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 90)
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 設定の「追加学習 (LoRA)」: 学習用のデータの書き出しと、学習した差分を入れる・外す・使う
struct AdapterSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("追加学習 (LoRA)") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.currentLLM.name) 用の差分")
                    Text(model.hasAdapter ? "入っています" : "入っていません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.importingAdapter {
                    ProgressView().controlSize(.small)
                }
                if model.hasAdapter {
                    Button("外す") { model.removeAdapter() }
                }
                Button(model.hasAdapter ? "入れ替える…" : "差分を追加…") { model.importAdapter() }
                    .disabled(model.importingAdapter)
            }
            Toggle("監査・翻訳で、この差分を使う", isOn: $model.useAdapter)
                .disabled(!model.hasAdapter)
            HStack {
                Button("学習用のデータを書き出す…") { model.exportTrainingData() }
                Text("学習した直し \(model.ledger.corrections.count) 件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("学習した直しがたまったら、LLM そのものに覚えさせることができます (追加学習)。学習用のデータを書き出し、ターミナルで tools/finetune/finetune.py を動かすと、この Mac の中で学習して「差分」(….lora.gguf) を作ります。差分は、元の LLM を書き換えずに重ねて使う小さなファイルで、いつでも外せます。学習の前後は同じ場面で比べ、直せる行が増えて、悪くなったところの無い差分だけを入れます。手順は README の「追加学習」にあります。数件の直しなら、追加学習をしなくても上の「学習した直し」がそのまま当てます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 設定の「学習した直し」: 監査の一覧で利用者が決めた直しの台帳。一覧・削除・自分で追加
struct LearnedCorrectionsSection: View {
    @Environment(AppModel.self) private var model
    @State private var newWrong = ""
    @State private var newRight = ""

    var body: some View {
        @Bindable var model = model
        Section("学習した直し") {
            Toggle("監査の一覧で決めた直しを覚えて、次から使う", isOn: $model.useLedger)
            let corrections = model.ledger.corrections.sorted { $0.updated > $1.updated }
            if corrections.isEmpty {
                Text("まだありません。監査の一覧で直しのチェックを入れたり外したりすると、ここに覚えます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(corrections) { correction in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(correction.wrong) → \(correction.right)")
                            .textSelection(.enabled)
                        Text(Self.status(of: correction))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("削除") { model.removeCorrection(correction.id) }
                }
            }
            HStack {
                TextField("聞き間違えた語", text: $newWrong, prompt: Text("聞き間違えた語 (例: Roblocks)"))
                    .labelsHidden()
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("正しい語", text: $newRight, prompt: Text("正しい語 (例: Roblox)"))
                    .labelsHidden()
                Button("追加") {
                    if model.teachCorrection(wrong: newWrong, right: newRight) {
                        newWrong = ""
                        newRight = ""
                    }
                }
                .disabled(newWrong.trimmingCharacters(in: .whitespaces).isEmpty
                          || newRight.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("反映した直しは、次の監査から LLM に聞く前に当てます。1 回反映しただけの直しは提案として出し、2 回反映すると自動で直します (数字や否定が変わる直し・かなを漢字にする直しは、いつも提案です)。一覧に「学習した直し」と出るので、いつでも元に戻せます。元に戻した直しは、LLM がまた出してきても使いません。正しい語は、語彙のヒントにも足します。ここで追加した直しは、いつも自動で当てます。保存先はこの Mac の中だけです。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func status(of correction: LearnedCorrection) -> String {
        if correction.taught { return "いつも直す (自分で追加)" }
        if correction.isAutomatic { return "次から自動で直す (反映 \(correction.accepted) 回・元に戻す \(correction.rejected) 回)" }
        if correction.isActive { return "次は提案として出す (反映 \(correction.accepted) 回・元に戻す \(correction.rejected) 回。もう一度反映すると、自動で直す)" }
        if correction.isBlocked { return "もう提案しない (元に戻す \(correction.rejected) 回・反映 \(correction.accepted) 回)" }
        return "保留 (反映 \(correction.accepted) 回・元に戻す \(correction.rejected) 回)"
    }
}
