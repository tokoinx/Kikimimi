import KikimimiCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettingsForm()
                .tabItem { Label(L("General"), systemImage: "gearshape") }
                .tag(SettingsTab.general)
            TranscriptionSettingsForm()
                .tabItem { Label(L("Transcription"), systemImage: "waveform") }
                .tag(SettingsTab.transcription)
            LLMSettingsForm()
                .tabItem { Label(L("Audit & translation"), systemImage: "character.bubble") }
                .tag(SettingsTab.llm)
        }
        // 「監査・翻訳」のタブが、スクロールせずに収まる大きさ
        .frame(width: 600, height: 680)
        // 画面の言語を変えた時の、開き直しの案内 (新しく選んだ言語の文で出す。
        // 設定の画面は言語を変えると作り直すので、出すかどうかは AppModel が持つ)
        .alert(L("The display language was changed"), isPresented: $model.showsLanguageChangedAlert) {
            if model.isBusy {
                Button(L("OK")) {}
            } else {
                Button(L("Reopen now")) { AppDelegate.shared?.reopenApp() }
                Button(L("Later"), role: .cancel) {}
            }
        } message: {
            Text(model.isBusy ? L("The text on screen has already changed. Standard menu bar items (Edit, Window, and so on) change when you reopen Kikimimi. Reopen Kikimimi after the current work finishes.")
                 : L("The text on screen has already changed. Standard menu bar items (Edit, Window, and so on) change when you reopen Kikimimi."))
        }
    }
}

/// 設定の「一般」タブ (画面の言語)
struct GeneralSettingsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(L("Display language"), selection: $model.uiLanguage) {
                    ForEach(UILanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                if model.needsReopenForLanguage {
                    // 言語を変えてから、まだ開き直していない (元の言語に戻すと消える)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("The text on screen has already changed. Standard menu bar items (Edit, Window, and so on) change when you reopen Kikimimi."))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("Reopen now")) { AppDelegate.shared?.reopenApp() }
                            .disabled(model.isBusy)
                        if model.isBusy {
                            Text(L("Work is in progress (transcription, audit, translation, recording, or download). You can reopen after it finishes."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(L("Standard menu bar items (Edit, Window, and so on) change after you reopen the app."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(L("The spoken language for transcription is chosen in the “Transcription” tab."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 設定の「文字起こし」タブ
struct TranscriptionSettingsForm: View {
    @Environment(AppModel.self) private var model
    /// 語彙のヒントの欄の例 (固有の語なので、どの言語の画面でも同じ)
    static let hintExample = "ロブロックス, Roblox Studio, ききみみ" // l10n: keep (固有の語の例)

    var body: some View {
        @Bindable var model = model
        Form {
            Section(L("Transcription")) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(L("Spoken language"), selection: $model.languageCode) {
                        ForEach(Languages.all) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    if model.languageCode == Languages.japaneseEnglish.code {
                        Text(L("For recordings that switch between Japanese and English. Each stretch of speech is checked to see whether it is Japanese or English, and is transcribed in that language. Because of the check, it takes about 2–4 times as long as the “Japanese” setting (longer when the language changes often or there are many short remarks in the other language). For a recording in only one of the two, choose that language."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Picker(L("Model"), selection: $model.modelID) {
                    ForEach(ModelCatalog.all) { spec in
                        Text(spec.recommended ? L("%@ (recommended)", spec.displayName) : spec.displayName).tag(spec.id)
                    }
                }
                Toggle(L("Prefer accuracy (beam search)"), isOn: $model.preferAccuracy)
                Toggle(L("Skip silence (VAD)"), isOn: $model.useVAD)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L("When there is continuous sound but very little text, transcribe again without skipping silence"), isOn: $model.autoVADOff)
                    Text(L("With songs and music, skipping silence may not treat singing as speech, so the lyrics may be missing. When that happens, the audio is transcribed again automatically without skipping silence (this takes longer)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!model.useVAD)
                Toggle(L("Remove common misrecognitions and repeated sentences"), isOn: $model.filterHallucinations)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L("Automatically transcribe recordings that mix Japanese and English as “Japanese + English”"), isOn: $model.autoMixedLanguage)
                    Text(L("With “Japanese”, “English”, or “Auto-detect”, the language is checked at several points in the recording before transcribing (a few seconds to a few tens of seconds). When the recording is mixed and the setting is switched, it takes about 2–4 times as long as “Japanese”. A recording in only one language takes no longer, apart from the check. “Skip silence (VAD)” must be on."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(L("Show a preview while recording"), isOn: $model.livePreview)
                VStack(alignment: .leading, spacing: 4) {
                    TextField(L("Vocabulary hints"), text: $model.initialPrompt, prompt: Text(L("Example: %@", Self.hintExample)))
                    Text(L("Write proper nouns and technical terms here, and they are more likely to come out with that spelling. You can leave this empty."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L("Models")) {
                ForEach(ModelCatalog.all) { spec in
                    ModelRow(spec: spec)
                }
                HStack {
                    Button(L("Add a local file…")) { model.importModelFile() }
                    Button(L("Open the models folder")) { model.revealModelsFolder() }
                }
            }

            Section {
                Text(L("Speech recognition uses whisper.cpp (a C/C++ implementation of OpenAI Whisper), which is free and open source, and runs on the Mac’s GPU (Metal). Neither the audio nor the transcription leaves your Mac. The internet is used only to download a model the first time."))
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
            Section(L("Audit & translation (local LLM)")) {
                Toggle(L("Audit after transcription (check for repetitions and mishearings)"), isOn: $model.autoAudit)
                // 訳す先の言語 (13 言語)。もう訳してある結果は、その結果の言語のまま (結果の画面で訳し直せる)
                Picker(L("Translate into"), selection: $model.translationLanguage) {
                    ForEach(TranslationTarget.all, id: \.self) { code in
                        Text(TranslationTarget.displayName(for: code)).tag(code)
                    }
                }
                Text(L("Results that are already translated keep their language. To use another language, translate again on the result screen."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("Translate segments that are not in %1$@ into %2$@",
                         TranslationTarget.displayName(for: model.translationLanguage),
                         TranslationTarget.displayName(for: model.translationLanguage)), isOn: $model.autoTranslate)
                Text(L("Even when this is off, you can translate only the sentences you want to read, one at a time, with “Translate” on a result line (lighter than translating everything)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("LLM", selection: $model.llmModelID) {
                    ForEach(LLMCatalog.all) { spec in
                        Text(spec.recommended ? L("%@ (recommended)", spec.displayName) : spec.displayName).tag(spec.id)
                    }
                    ForEach(model.customLLMFiles, id: \.self) { name in
                        Text(L("Your file: %@", name)).tag("file:" + name)
                    }
                }
                ForEach(LLMCatalog.all) { spec in
                    LLMModelRow(spec: spec)
                }
                ForEach(model.customLLMFiles, id: \.self) { name in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                            Text(L("Added GGUF")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Delete")) { model.deleteLLMFile(name) }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button(L("Add a local GGUF…")) { model.importLLMFile() }
                            .disabled(model.importingLLM)
                        Button(L("Open the LLM folder")) { model.revealLLMFolder() }
                        if model.importingLLM {
                            ProgressView().controlSize(.small)
                            Text(L("Adding…")).foregroundStyle(.secondary)
                        }
                    }
                    Text(L("Location: %@", model.llmFolderPath))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(MemoryBudget.isTight
                     ? L("The auditor finds repeated sentences and mishearings that are clear from the context. Only fixes it is sure of are applied; the rest are kept as “suggestions”, so you can check them before applying. Every fix can be undone. This Mac has %d GB of memory (on the low side, so transcription and the LLM are loaded in turn).", MemoryBudget.physicalGB)
                     : L("The auditor finds repeated sentences and mishearings that are clear from the context. Only fixes it is sure of are applied; the rest are kept as “suggestions”, so you can check them before applying. Every fix can be undone. This Mac has %d GB of memory.", MemoryBudget.physicalGB))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LearnedCorrectionsSection()

            AdapterSection()

            Section {
                Text(L("Audit and translation use llama.cpp and Qwen3.5, which are free and open source, and run on the Mac’s GPU (Metal). The transcription does not leave your Mac. The internet is used only to download an LLM the first time."))
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
                Text(spec.recommended ? L("%@ (recommended)", spec.displayName) : spec.displayName)
                Text(L("%1$@ About %2$@ · %3$@", spec.summary, TimeFormat.bytes(Int64(spec.approxMB) * 1_000_000), spec.license))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if spec.recommendedMemoryGB > MemoryBudget.physicalGB {
                    Text(L("May be too heavy for this Mac (%d GB of memory)", MemoryBudget.physicalGB))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            switch model.llmAvailability(of: spec) {
            case .installed:
                Label(L("Downloaded"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                Button(L("Delete")) { model.deleteLLM(spec) }
            case .notInstalled:
                Button(L("Download")) {
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
                Button(L("Cancel download")) { model.cancelLLMDownload(spec) }
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
                Text(spec.recommended ? L("%@ (recommended)", spec.displayName) : spec.displayName)
                Text(L("%1$@ About %2$d MB", spec.summary, spec.approxMB))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.availability(of: spec) {
            case .installed:
                Label(L("Downloaded"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                Button(L("Delete")) { model.deleteModel(spec) }
            case .notInstalled:
                Button(L("Download")) { model.download(spec) }
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
        Section(L("Fine-tuning (LoRA)")) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Adapter for %@", model.currentLLM.name))
                    Text(model.hasAdapter ? L("Added") : L("Not added"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.importingAdapter {
                    ProgressView().controlSize(.small)
                }
                if model.hasAdapter {
                    Button(L("Remove")) { model.removeAdapter() }
                }
                Button(model.hasAdapter ? L("Replace…") : L("Add adapter…")) { model.importAdapter() }
                    .disabled(model.importingAdapter)
            }
            Toggle(L("Use this adapter for audit and translation"), isOn: $model.useAdapter)
                .disabled(!model.hasAdapter)
            HStack {
                Button(L("Export training data…")) { model.exportTrainingData() }
                Text(LPlural(model.ledger.corrections.count, one: "%d learned correction", other: "%d learned corrections"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L("When learned corrections build up, you can teach them to the LLM itself (fine-tuning). Export the training data and run tools/finetune/finetune.py in Terminal: it trains on this Mac and makes an “adapter” (….lora.gguf). An adapter is a small file used on top of the original LLM without changing it, and you can remove it at any time. Compare before and after training on the same cases, and add only an adapter that fixes more lines and makes nothing worse. The steps are in “Fine-tuning” in the README. For just a few corrections, “Learned corrections” above applies them as they are, without fine-tuning."))
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
        Section(L("Learned corrections")) {
            Toggle(L("Remember the fixes decided in the audit list and use them from next time"), isOn: $model.useLedger)
            let corrections = model.ledger.corrections.sorted { $0.updated > $1.updated }
            if corrections.isEmpty {
                Text(L("None yet. When you check or uncheck fixes in the audit list, they are remembered here."))
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
                    Button(L("Delete")) { model.removeCorrection(correction.id) }
                }
            }
            HStack {
                TextField(L("Misheard term"), text: $newWrong, prompt: Text(L("Misheard term (e.g. Roblocks)")))
                    .labelsHidden()
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField(L("Right term"), text: $newRight, prompt: Text(L("Right term (e.g. Roblox)")))
                    .labelsHidden()
                Button(L("Add")) {
                    if model.teachCorrection(wrong: newWrong, right: newRight) {
                        newWrong = ""
                        newRight = ""
                    }
                }
                .disabled(newWrong.trimmingCharacters(in: .whitespaces).isEmpty
                          || newRight.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(L("Applied fixes are used from the next audit, before the LLM is asked. A fix applied once is shown as a suggestion; after it is applied twice, it is fixed automatically (fixes that change a number or a negation, or turn kana into kanji, are always suggestions). They are shown as “Learned corrections” in the list, so you can always undo them. A fix you undid is not used, even if the LLM suggests it again. The right term is also added to the vocabulary hints. Fixes you add here are always applied automatically. They are saved only on this Mac."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func status(of correction: LearnedCorrection) -> String {
        if correction.taught { return L("Always fix (added by you)") }
        if correction.isAutomatic { return L("Fix automatically from now on (applied: %1$d, undone: %2$d)", correction.accepted, correction.rejected) }
        if correction.isActive { return L("Suggest next time (applied: %1$d, undone: %2$d. Apply it once more to fix it automatically)", correction.accepted, correction.rejected) }
        if correction.isBlocked { return L("No longer suggested (undone: %1$d, applied: %2$d)", correction.rejected, correction.accepted) }
        return L("On hold (applied: %1$d, undone: %2$d)", correction.accepted, correction.rejected)
    }
}
