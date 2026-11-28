// ライブラリの所: 結果の保存・読み込みと、版 (履歴)。

import AppKit
import Foundation
import KikimimiCore
import UniformTypeIdentifiers

// MARK: - ライブラリ (結果の保存)

/// 版の残し方
enum VersionSaveMode: Equatable {
    /// 新しい版として残す
    case new
    /// いちばん新しい、自分で残した版に上書きする
    case overwriteLatest
}

extension AppModel {
    /// 保存した結果を読んだもの (音声ファイルがあるかも、裏で確かめておく)
    struct RestoredDocument: Sendable {
        let document: SavedDocument
        let audioExists: Bool
    }

    /// document.json を書くまでに待つ長さ (この間の変化は、まとめて 1 回で書く)
    private static let documentSaveDelay: UInt64 = 1_000_000_000
    /// notes.md を書くまでに待つ長さ
    private static let notesSaveDelay: UInt64 = 800_000_000
    /// 版に戻す前に、自動で残す版の名前
    /// (保存される名前なので、作った時の画面の言語のまま残る。版を見分ける時は、名前ではなく origin で見る)
    static var beforeRestoreLabel: String { L("Before restoring") }
    /// 訳す先を変えて訳し直す前に、自動で残す版の名前 (保存される名前なので、作った時の画面の言語のまま残る)
    static var beforeRetranslateLabel: String { L("Before changing the translation language") }

    /// 起動したとき: 保存した結果を裏で読み、一覧の後ろに足す (選びはしない)
    func loadLibrary() {
        guard let writer = library else { return }
        let deliver: @MainActor @Sendable ([RestoredDocument], [URL]) -> Void = { [weak self] documents, aside in
            self?.restore(documents, setAside: aside)
        }
        writer.async { store in
            let loaded = store.loadAll()
            let restored = loaded.documents.map { document in
                RestoredDocument(document: document,
                                 audioExists: document.sourcePath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
            }
            let aside = loaded.setAside
            Task { @MainActor in deliver(restored, aside) }
        }
    }

    private func restore(_ documents: [RestoredDocument], setAside: [URL]) {
        for item in documents {
            let document = item.document
            guard !jobs.contains(where: { $0.id == document.id }) else { continue }
            // 音声ファイルが見つからなければ、再生はできない (場所は覚えておき、選び直せる)
            let url = item.audioExists ? document.sourcePath.map { URL(fileURLWithPath: $0) } : nil
            let job = Job(id: document.id, name: document.title, url: url, isRecording: document.isRecording,
                          createdAt: document.createdAt)
            job.sourcePath = document.sourcePath
            job.transcript = document.transcript
            job.languageCode = document.languageCode
            job.autoMixedFrom = document.autoMixedFrom
            job.vadSkippedAutomatically = document.vadSkippedAutomatically
            job.versions = document.versions
            job.notes = document.notes
            job.status = .done
            job.progress = 1
            job.message = L("Done")
            job.mixedSuggestionDismissed = true
            job.autoMixedNoticeDismissed = true
            job.vadSkippedNoticeDismissed = true
            job.inLibrary = true
            job.documentOnDisk = true
            adopt(job, at: jobs.count)
        }
        if !setAside.isEmpty {
            let text = LPlural(setAside.count,
                               one: "%d saved result could not be read, so it is not in the list. The original file is kept in its folder as “document.unreadable-…”.",
                               other: "%d saved results could not be read, so they are not in the list. The original files are kept in their folders as “document.unreadable-…”.")
            errorMessage = errorMessage.map { $0 + "\n\n" + text } ?? text
        }
        libraryLoadFinished = true
    }

    /// ジョブを一覧に入れる (保存の受け口を付ける)。一覧にジョブを足すときは、いつもこれを使う
    func adopt(_ job: Job, at index: Int = 0) {
        job.onChange = { [weak self] job, change in
            self?.jobChanged(job, change)
        }
        jobs.insert(job, at: min(max(0, index), jobs.count))
        // もう終わっているジョブ (確認用に入れたものなど) は、ここではじめて保存する
        startSavingIfFinished(job)
    }

    /// ジョブの中身が変わった (Job.onChange から)。少し待ってから保存する
    private func jobChanged(_ job: Job, _ change: Job.Change) {
        guard library != nil, jobs.contains(where: { $0 === job }) else { return }
        switch change {
        case .status:
            startSavingIfFinished(job)
        case .document:
            if job.inLibrary { scheduleDocumentSave(job) }
        case .notes:
            if job.inLibrary { scheduleNotesSave(job) }
        }
    }

    /// 文字起こしが終わり、文がある: ライブラリに入れて、保存する (中止・失敗したものは保存しない)
    private func startSavingIfFinished(_ job: Job) {
        guard library != nil, !job.inLibrary, job.status == .done,
              let transcript = job.transcript, !transcript.segments.isEmpty else { return }
        job.inLibrary = true
        scheduleDocumentSave(job)
    }

    /// 保存する中身の写し (値なので、メインスレッドでは写すだけ。JSON にするのは裏の列)
    func snapshot(of job: Job) -> SavedDocument? {
        guard let transcript = job.transcript else { return nil }
        return SavedDocument(id: job.id, title: job.name, sourcePath: job.sourcePath, isRecording: job.isRecording,
                             createdAt: job.createdAt, updatedAt: Date(), languageCode: job.languageCode,
                             autoMixedFrom: job.autoMixedFrom,
                             vadSkippedAutomatically: job.vadSkippedAutomatically, transcript: transcript, versions: job.versions,
                             notes: job.notes)
    }

    /// 1 秒ほどあとに document.json を書く。待っているあいだの変化は、その 1 回にまとめる
    /// (翻訳のように続けて変わるときも、1 秒に 1 回まで。書くときに、そのときの中身を写す)
    private func scheduleDocumentSave(_ job: Job) {
        let id = job.id
        guard documentSaveTimers[id] == nil else { return }
        documentSaveTimers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.documentSaveDelay)
            guard !Task.isCancelled else { return }
            self?.documentSaveDue(id)
        }
    }

    private func documentSaveDue(_ id: UUID) {
        documentSaveTimers[id] = nil
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        // 版の作業の最中は、終わるまで待つ (版の一覧を書きかえている最中に、古い一覧で書かない)
        if job.versionBusy {
            scheduleDocumentSave(job)
            return
        }
        writeDocument(job)
    }

    /// いまの中身を写して、裏の列で document.json と notes.md を書く
    private func writeDocument(_ job: Job) {
        guard let writer = library, job.status == .done, let document = snapshot(of: job) else { return }
        // notes.md もいっしょに書くので、待っているメモの保存は要らない
        notesSaveTimers.removeValue(forKey: job.id)?.cancel()
        let report = saveReporter(document: true)
        let id = job.id
        let revision = job.notesRevision
        writer.async { store in
            do {
                try store.save(document)
                Task { @MainActor in report(id, revision, nil) }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in report(id, revision, message) }
            }
        }
    }

    /// 0.8 秒ほどあとに notes.md だけを書く (document.json を書く予定があれば、そちらでいっしょに書く)
    private func scheduleNotesSave(_ job: Job) {
        let id = job.id
        guard notesSaveTimers[id] == nil, documentSaveTimers[id] == nil else { return }
        notesSaveTimers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.notesSaveDelay)
            guard !Task.isCancelled else { return }
            self?.notesSaveDue(id)
        }
    }

    private func notesSaveDue(_ id: UUID) {
        notesSaveTimers[id] = nil
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        writeNotesOrDocument(job)
    }

    /// メモを書く。document.json をまだ書けていなければ (はじめの保存の失敗など)、全体を書く
    /// (notes.md だけでは、フォルダが無いので何も書かれない)
    private func writeNotesOrDocument(_ job: Job) {
        if job.documentOnDisk {
            writeNotes(job)
        } else {
            writeDocument(job)
        }
    }

    private func writeNotes(_ job: Job) {
        guard let writer = library else { return }
        let id = job.id
        let text = job.notes
        let revision = job.notesRevision
        let report = saveReporter(document: false)
        writer.async { store in
            do {
                try store.saveNotes(id: id, text: text)
                Task { @MainActor in report(id, revision, nil) }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in report(id, revision, message) }
            }
        }
    }

    /// 裏の列から、書き終えたことを受け取る口 (メインスレッドで動く)
    private func saveReporter(document: Bool) -> @MainActor @Sendable (UUID, Int, String?) -> Void {
        { [weak self] id, revision, failure in
            self?.saveFinished(id, document: document, notesRevision: revision, failure: failure)
        }
    }

    private func saveFinished(_ id: UUID, document: Bool, notesRevision: Int, failure: String?) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if let failure {
            // 知らせるのは 1 回だけ (書き直すたびには出さない)。結果は一覧に残す
            if !job.saveErrorReported {
                job.saveErrorReported = true
                errorMessage = L("Could not save “%1$@” (it stays in the list): %2$@", job.name, failure)
            }
            return
        }
        job.saveErrorReported = false
        if document { job.documentOnDisk = true }
        // 書いたあとでメモが変わっていなければ、「保存しました」
        if job.notesRevision == notesRevision, !job.notesSaved { job.notesSaved = true }
    }

    /// 待っている保存を、いま列に積む
    private func dispatchPendingSaves(for id: UUID) {
        if let timer = documentSaveTimers.removeValue(forKey: id) {
            timer.cancel()
            if let job = jobs.first(where: { $0.id == id }) { writeDocument(job) }
        }
        if let timer = notesSaveTimers.removeValue(forKey: id) {
            timer.cancel()
            if let job = jobs.first(where: { $0.id == id }) { writeNotesOrDocument(job) }
        }
    }

    /// 待っている保存をすべて積み、書き終わるまで待つ (終了の前と、確認用)
    func flushLibrary() {
        guard let writer = library else { return }
        for id in Set(documentSaveTimers.keys).union(notesSaveTimers.keys) {
            dispatchPendingSaves(for: id)
        }
        writer.flush()
    }

    /// 保存したフォルダを Finder で表示する
    func revealInLibrary(_ job: Job) {
        guard let writer = library, job.inLibrary else { return }
        dispatchPendingSaves(for: job.id)
        writer.flush()
        NSWorkspace.shared.activateFileViewerSelecting([writer.store.folder(for: job.id)])
    }

    /// 音声ファイルを選び直す (動かした・名前を変えたとき)
    func relocateAudio(of job: Job) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.message = L("Choose the audio or video file for “%@”", job.name)
        panel.prompt = L("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        job.url = url
        // 場所が変わったので保存する (Job.sourcePath の変化から)
        job.sourcePath = url.path
        if selectedJobID == job.id { player.load(url: url) }
    }

    /// 行の文をメモに引用する (行の右クリックの「メモに引用」)。メモの欄も出す
    func quoteToNotes(text: String, time: TimeInterval, in job: Job) {
        job.notes = NoteQuote.appending(NoteQuote.line(time: time, text: text), to: job.notes)
        if !showNotes { showNotes = true }
    }

    // MARK: 版 (履歴)

    /// 版を残す・戻す・消すことができるか (保存した、終わった結果で、監査・翻訳の最中でない)
    func canEditVersions(_ job: Job) -> Bool {
        library != nil && job.inLibrary && job.status == .done && !job.isPostActive && !job.versionBusy
    }

    /// 版の作業ができないときの説明 (できるときは nil)
    func versionBlockedReason(_ job: Job) -> String? {
        if library == nil || !job.inLibrary || job.status != .done { return L("Versions can be saved only for finished, saved transcription results.") }
        if job.isPostActive { return L("You cannot save or restore versions during audit or translation. Wait until it finishes.") }
        if job.versionBusy { return L("Saving the version…") }
        return nil
    }

    /// いまの状態を版として残す。origin は、新しい版のときの残し方 (自分で残した版か、自動で残した版か)
    @discardableResult
    func saveVersion(_ job: Job, label: String, mode: VersionSaveMode,
                     origin: VersionInfo.Origin = .manual) async -> Bool {
        guard canEditVersions(job), let writer = library else { return false }
        // 待っている保存を先に積む (列の順に書くので、版はそのあとの状態になる)
        dispatchPendingSaves(for: job.id)
        guard let document = snapshot(of: job) else { return false }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let overwrite = mode == .overwriteLatest
        job.versionBusy = true
        defer { job.versionBusy = false }
        let result = await writer.run { (store: LibraryStore) throws -> SavedDocument in
            if overwrite { return try store.overwriteLatestVersion(of: document, label: name) }
            return try store.addVersion(to: document, label: name, origin: origin)
        }
        switch result {
        case .success(let updated):
            guard jobs.contains(where: { $0 === job }) else { return false }
            job.versions = updated.versions
            return true
        case .failure(let error):
            errorMessage = L("Could not save the version: %@", error.localizedDescription)
            return false
        }
    }

    /// 版に戻す。先に、いまの状態を版 (自動・「戻す前の状態」) として残してから、選んだ所 (文字起こしと訳・メモ) を置きかえる
    @discardableResult
    func restoreVersion(_ job: Job, versionID: UUID, transcript: Bool, notes: Bool) async -> Bool {
        guard transcript || notes, canEditVersions(job), let writer = library else { return false }
        dispatchPendingSaves(for: job.id)
        guard let document = snapshot(of: job) else { return false }
        job.versionBusy = true
        defer { job.versionBusy = false }
        let label = AppModel.beforeRestoreLabel
        let result = await writer.run { (store: LibraryStore) throws -> SavedDocument in
            // 版を先に読む (読めなければ、何も変えない)
            let version = try store.loadVersion(documentID: document.id, versionID: versionID)
            var restored = try store.addVersion(to: document, label: label, origin: .beforeRestore)
            restored = restored.restoring(version, transcript: transcript, notes: notes)
            restored.updatedAt = Date()
            try store.save(restored)
            return restored
        }
        switch result {
        case .success(let restored):
            guard jobs.contains(where: { $0 === job }) else { return false }
            job.versions = restored.versions
            if transcript { job.transcript = restored.transcript }
            if notes { job.notes = restored.notes }
            return true
        case .failure(let error):
            errorMessage = L("Could not restore the version: %@", error.localizedDescription)
            return false
        }
    }

    /// 版を 1 つ消す
    @discardableResult
    func deleteVersion(_ job: Job, versionID: UUID) async -> Bool {
        guard canEditVersions(job), let writer = library else { return false }
        dispatchPendingSaves(for: job.id)
        guard let document = snapshot(of: job) else { return false }
        job.versionBusy = true
        defer { job.versionBusy = false }
        let result = await writer.run { (store: LibraryStore) throws -> SavedDocument in
            try store.deleteVersion(of: document, versionID: versionID)
        }
        switch result {
        case .success(let updated):
            guard jobs.contains(where: { $0 === job }) else { return false }
            job.versions = updated.versions
            return true
        case .failure(let error):
            errorMessage = L("Could not delete the version: %@", error.localizedDescription)
            return false
        }
    }
}
