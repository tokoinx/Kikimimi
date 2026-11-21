// モデルの所: 音声認識のモデルと VAD の取得・有無、監査・翻訳の LLM、追加学習の差分 (LoRA)。

import AppKit
import Foundation
import KikimimiCore
import KikimimiWhisper
import UniformTypeIdentifiers

extension AppModel {
    // MARK: モデル
    func refreshInstalled() {
        installedModelIDs = Set(ModelCatalog.all.filter { store.isInstalled($0) }.map(\.id))
    }

    func availability(of spec: WhisperModelSpec) -> ModelAvailability {
        if let fraction = downloads[spec.id] { return .downloading(fraction) }
        return installedModelIDs.contains(spec.id) ? .installed : .notInstalled
    }

    /// 同じモデルの取得は 1 本にまとめる。待っているジョブが中止されても、取得は最後まで続ける。
    private func startDownload(_ spec: WhisperModelSpec) -> Task<Void, Error> {
        if let running = downloadTasks[spec.id] { return running }
        let task = Task { try await self.performDownload(spec) }
        downloadTasks[spec.id] = task
        Task {
            _ = try? await task.value
            if downloadTasks[spec.id] == task { downloadTasks[spec.id] = nil }
        }
        return task
    }

    /// モデルが無ければダウンロードして、ファイルの場所を返す。
    /// cancelFlag を渡すと、取得の途中でも中止にすぐ反応する (取得そのものは裏で続く)。
    @discardableResult
    func ensureModel(_ spec: WhisperModelSpec, cancelFlag: CancelFlag? = nil) async throws -> URL {
        let url = store.url(for: spec)
        if store.isInstalled(spec) {
            if !installedModelIDs.contains(spec.id) { refreshInstalled() }
            return url
        }
        let task = startDownload(spec)
        if let cancelFlag {
            while downloadTasks[spec.id] == task {
                if cancelFlag.isSet { throw WhisperError.cancelled }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        try await task.value // 取得に失敗していればここで投げる
        return url
    }

    func download(_ spec: WhisperModelSpec) {
        Task {
            do {
                try await ensureModel(spec)
            } catch is CancellationError {
            } catch {
                errorMessage = L("Could not download %1$@: %2$@\n\nIf you cannot connect to Hugging Face (huggingface.co), you can add a .bin file with “Add a local file…” in Settings.", spec.displayName, error.localizedDescription)
            }
        }
    }

    private func performDownload(_ spec: WhisperModelSpec) async throws {
        downloads[spec.id] = 0
        defer { downloads[spec.id] = nil }
        try store.ensureDirectory()
        try await ModelDownloader.download(
            from: spec.downloadURL,
            to: store.url(for: spec),
            onProgress: { [weak self] fraction, _, _ in
                Task { @MainActor in
                    guard let self, self.downloads[spec.id] != nil else { return }
                    self.downloads[spec.id] = fraction
                }
            }
        )
        // 待っていたジョブが全部中止されていても「取得済み」に切り替える
        refreshInstalled()
        // オンラインのうちに、無音検出 (VAD) モデル (約 0.9 MB) も取っておく
        if useVAD {
            Task { _ = await self.vadModelPath() }
        }
    }

    func deleteModel(_ spec: WhisperModelSpec) {
        do {
            try store.delete(spec)
        } catch {
            errorMessage = L("Could not delete: %@", error.localizedDescription)
        }
        refreshInstalled()
    }

    func importModelFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.message = L("Choose a whisper.cpp model (such as ggml-large-v3-turbo-q5_0.bin)")
        panel.prompt = L("Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch try store.importFile(from: url) {
            case .model(let spec):
                refreshInstalled()
                modelID = spec.id
            case .vad:
                vadRetryAfter = nil
                errorMessage = L("Added the silence detection (VAD) model.")
            @unknown default:
                // KikimimiWhisper は library evolution でビルドしているため、将来の値にも備える
                refreshInstalled()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealModelsFolder() {
        try? store.ensureDirectory()
        NSWorkspace.shared.open(store.directory)
    }

    /// 無音スキップ用の VAD モデル (約 0.9 MB) の場所。無ければ取得する。
    /// 取れなければ VAD なしで続け、失敗したら 10 分は取り直さない (繋がらないネットワークで毎回待たせない)。
    /// - Parameter enabled: VAD を使うか (nil なら設定に従う。ジョブだけの指定は Job.vadOverride)
    func vadModelPath(enabled: Bool? = nil) async -> String? {
        guard enabled ?? useVAD else { return nil }
        if store.isVADInstalled { return store.vadURL.path }
        if let retry = vadRetryAfter, Date() < retry { return nil }
        if let running = vadTask { return await running.value }

        let destination = store.vadURL
        let directory = store
        let task = Task<String?, Never> {
            do {
                try directory.ensureDirectory()
                // 0.9 MB なので 20 秒で見切る (子タスクを止めるとダウンロードも止まる)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await ModelDownloader.download(
                            from: ModelCatalog.vadURL,
                            to: destination,
                            validate: { ModelFile.isValidModel(at: $0, minimumBytes: 100_000) }
                        )
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(20))
                        throw URLError(.timedOut)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
                return destination.path
            } catch {
                return nil
            }
        }
        vadTask = task
        let path = await task.value
        vadTask = nil
        vadRetryAfter = path == nil ? Date().addingTimeInterval(10 * 60) : nil
        return path
    }

    // MARK: 監査・翻訳のモデル (ローカル LLM)
    struct LLMSelection: Equatable {
        let id: String
        let name: String
        let url: URL
        let spec: LLMModelSpec?
    }

    /// 選んでいる LLM
    var currentLLM: LLMSelection {
        if llmModelID.hasPrefix("file:") {
            let name = String(llmModelID.dropFirst(5))
            return LLMSelection(id: llmModelID, name: (name as NSString).deletingPathExtension,
                                url: llmStore.url(forFile: name), spec: nil)
        }
        let spec = LLMCatalog.spec(id: llmModelID) ?? LLMCatalog.all[0]
        return LLMSelection(id: spec.id, name: spec.displayName, url: llmStore.url(for: spec), spec: spec)
    }

    var isLLMInstalled: Bool {
        let current = currentLLM
        if let spec = current.spec { return installedLLMIDs.contains(spec.id) }
        return customLLMFiles.contains(current.url.lastPathComponent)
    }

    func refreshLLMInstalled() {
        installedLLMIDs = Set(LLMCatalog.all.filter { llmStore.isInstalled($0) }.map(\.id))
        customLLMFiles = llmStore.customFiles()
        // 選んでいた取り込みのモデルが消えていたら、一覧のおすすめに戻す
        if llmModelID.hasPrefix("file:"), !customLLMFiles.contains(String(llmModelID.dropFirst(5))) {
            llmModelID = LLMCatalog.defaultModelID
        }
        // 一覧に無い ID (前の版の設定など) も、おすすめに戻す (設定の選択肢に当てはまるものが無くなる)
        if !llmModelID.hasPrefix("file:"), LLMCatalog.spec(id: llmModelID) == nil {
            llmModelID = LLMCatalog.defaultModelID
        }
        refreshAdapters()
    }

    // MARK: 追加学習の差分 (LoRA)

    /// 監査用・翻訳用の差分が入っているかを、置き場から読み直す
    func refreshAdapters() {
        hasAdapter = llmStore.hasAdapter(forModelKey: adapterKey, kind: .audit)
        hasTranslationAdapter = llmStore.hasAdapter(forModelKey: adapterKey, kind: .translation)
    }

    /// 選んでいる LLM の、差分の名前 (一覧のモデルは ID、取り込んだ GGUF はファイル名から拡張子を除いたもの)。
    /// `tools/finetune/finetune.py --install` が置く名前と同じ
    var adapterKey: String {
        let current = currentLLM
        return current.spec?.id ?? current.url.deletingPathExtension().lastPathComponent
    }

    /// 仕事に渡す差分 (使う設定で、選んでいる LLM 用のその種類の差分が入っているときだけ)。
    /// 監査には監査用、翻訳には翻訳用だけを渡す。翻訳用が無い時、翻訳は差分なしで動く
    /// (前は、監査用の差分を翻訳にも渡していた。監査を学習した差分が、訳の固有名詞を崩した例が在ったので、やめた)
    func activeAdapterPath(for kind: AdapterKind) -> String? {
        var installed = Set<AdapterKind>()
        if hasAdapter { installed.insert(.audit) }
        if hasTranslationAdapter { installed.insert(.translation) }
        let store = llmStore
        let key = adapterKey
        return AdapterFiles.activePath(for: kind, enabled: useAdapter, installed: installed) {
            store.adapterURL(forModelKey: key, kind: $0)
        }
    }

    /// 差分を取り込む (kind は、監査用か翻訳用か)
    func importAdapter(kind: AdapterKind) {
        guard isLLMInstalled else {
            errorMessage = L("Download an LLM first (the adapter is checked against the selected LLM).")
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.message = L("Choose a fine-tuning adapter (….lora.gguf). It will be added for the selected LLM (%@)", currentLLM.name)
        panel.prompt = L("Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = llmStore
        let key = adapterKey
        let modelURL = currentLLM.url
        importingAdapter = true
        Task {
            defer { importingAdapter = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try store.importAdapter(from: url, forModelKey: key, kind: kind, modelURL: modelURL)
                }.value
                llm.adapterChanged()
                refreshLLMInstalled()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// その種類の差分だけを外す
    func removeAdapter(kind: AdapterKind) {
        do {
            try llmStore.deleteAdapter(forModelKey: adapterKey, kind: kind)
        } catch {
            errorMessage = L("Could not delete: %@", error.localizedDescription)
        }
        llm.adapterChanged()
        refreshLLMInstalled()
    }

    /// 学習用のデータに入れる「直す必要のなかった行」: 監査を終えた文字起こしの中で、監査が何も指摘しなかった行。
    /// 多すぎると書き出しが大きくなるだけなので、まんべんなく limit 行まで
    func cleanLinesForTraining(limit: Int = 600) -> [FineTuneData.CleanLine] {
        var lines: [FineTuneData.CleanLine] = []
        var seen = Set<String>()
        for job in jobs {
            guard let transcript = job.transcript, let audit = transcript.audit else { continue }
            let touched = Set(audit.changes.map(\.original.id))
            for segment in transcript.segments where !touched.contains(segment.id) {
                let text = segment.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard text.count >= 4, seen.insert(text).inserted else { continue }
                lines.append(FineTuneData.CleanLine(text: text, language: segment.language ?? transcript.language))
            }
        }
        guard lines.count > limit else { return lines }
        return (0..<limit).map { lines[$0 * lines.count / limit] }
    }

    /// 学習した直しから、追加学習 (LoRA) 用のデータを書き出す (`tools/finetune/finetune.py --data` に渡す)
    func exportTrainingData() {
        let clean = cleanLinesForTraining()
        let records = FineTuneData.records(ledger: ledger, cleanLines: clean)
        guard !records.isEmpty else {
            errorMessage = L("There is no training data to export yet. Learned corrections build up when you apply or undo corrections in the audit list.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kikimimi-training.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText]
        panel.canCreateDirectories = true
        panel.message = LPlural(records.count, one: "Exports %d training record (used only on this Mac)", other: "Exports %d training records (used only on this Mac)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FineTuneData.jsonl(records).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = L("Could not save: %@", error.localizedDescription)
        }
    }

    func llmAvailability(of spec: LLMModelSpec) -> ModelAvailability {
        if let fraction = llmDownloads[spec.id] { return .downloading(fraction) }
        return installedLLMIDs.contains(spec.id) ? .installed : .notInstalled
    }

    func downloadLLM(_ spec: LLMModelSpec) {
        guard llmDownloadTasks[spec.id] == nil else { return }
        llmDownloads[spec.id] = 0
        llmDownloadTasks[spec.id] = Task {
            defer {
                llmDownloads[spec.id] = nil
                llmDownloadTasks[spec.id] = nil
                // どう終わっても置き場所を見直す (中止がちょうど置き終えた直後に届いても、取得済みと表示できるように)
                refreshLLMInstalled()
            }
            do {
                try llmStore.ensureDirectory()
                let resolved = try await HuggingFaceResolver.resolve(spec)
                try Task.checkCancellation()
                let size = resolved.expectedSize
                let sha = resolved.sha256
                try await ModelDownloader.download(
                    from: resolved.url,
                    to: llmStore.url(for: spec),
                    validate: { FileHash.validateDownload(at: $0, expectedSize: size, sha256: sha) },
                    onProgress: { [weak self] fraction, _, _ in
                        Task { @MainActor in
                            guard let self, self.llmDownloads[spec.id] != nil else { return }
                            self.llmDownloads[spec.id] = fraction
                        }
                    }
                )
                refreshLLMInstalled()
                // 中止されていたら、見直し・翻訳は始めない
                try Task.checkCancellation()
                // 取得のきっかけになった結果 (いま開いているもの) を、そのまま LLM で見直し・翻訳する
                if currentLLM.spec?.id == spec.id, let job = selectedJob, job.status == .done, let t = job.transcript {
                    var tasks: [PostTask] = []
                    if autoAudit, t.audit?.model == nil { tasks.append(.audit) }
                    let stats = translationStats(of: t)
                    if autoTranslate, stats.isMainlyForeign, stats.untranslated > 0 { tasks.append(.translate) }
                    if !tasks.isEmpty { schedulePostTasks(for: job, automatic: false, tasks: tasks) }
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorMessage = L("Could not download %1$@: %2$@\n\nIf you cannot connect to Hugging Face (huggingface.co), you can add it with “Add a local GGUF…” in the “Audit & translation” tab of Settings.", spec.displayName, error.localizedDescription)
            }
        }
    }

    func cancelLLMDownload(_ spec: LLMModelSpec) {
        llmDownloadTasks[spec.id]?.cancel()
    }

    func deleteLLM(_ spec: LLMModelSpec) {
        deleteLLMFile(spec.fileName)
    }

    func deleteLLMFile(_ name: String) {
        llm.unload()
        do {
            try llmStore.delete(fileNamed: name)
        } catch {
            errorMessage = L("Could not delete: %@", error.localizedDescription)
        }
        refreshLLMInstalled()
    }

    func importLLMFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.message = L("Choose an LLM (.gguf) that runs on llama.cpp")
        panel.prompt = L("Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = llmStore
        importingLLM = true
        Task {
            defer { importingLLM = false }
            do {
                // 数 GB を写すので、画面を止めないよう裏で行う
                let name = try await Task.detached(priority: .userInitiated) { try store.importFile(from: url) }.value
                refreshLLMInstalled()
                if let spec = LLMCatalog.all.first(where: { $0.fileName == name }) {
                    llmModelID = spec.id
                } else {
                    llmModelID = "file:" + name
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func revealLLMFolder() {
        try? llmStore.ensureDirectory()
        NSWorkspace.shared.open(llmStore.directory)
    }

    /// LLM の置き場所 (画面に出す用。ホームは ~ で表す)
    var llmFolderPath: String {
        (llmStore.directory.path as NSString).abbreviatingWithTildeInPath
    }
}
