// 学習した直し・訳を直す・訳の記憶・関門が利用者の判定から学ぶ所。

import Foundation
import KikimimiCore

extension AppModel {
    // MARK: 学習した直し

    /// 保存先 (モデルのフォルダのとなり: ~/Library/Application Support/Kikimimi/learned-corrections.json)
    var ledgerURL: URL {
        store.directory.deletingLastPathComponent().appendingPathComponent("learned-corrections.json")
    }

    /// 台帳を保存する。保存先が無い (確認用の起動) 時は、保存しない
    func saveLedger() {
        guard let url = ledgerFileURL else { return }
        do {
            try ledger.save(to: url)
        } catch {
            errorMessage = L("Could not save the learned corrections: %@", error.localizedDescription)
        }
    }

    /// 設定の画面で、利用者が自分で書いた直し (いつも当てる)
    @discardableResult
    func teachCorrection(wrong: String, right: String) -> Bool {
        guard ledger.teach(wrong: wrong, right: right) else { return false }
        saveLedger()
        return true
    }

    func removeCorrection(_ id: UUID) {
        ledger.remove(id)
        saveLedger()
    }

    // MARK: 訳を直す・訳の記憶

    private func saveTranslationMemory() {
        guard let url = translationMemoryURL else { return }
        do {
            try translationMemory.save(to: url)
        } catch {
            errorMessage = L("Could not save the translation memory: %@", error.localizedDescription)
        }
    }

    /// 設定の「覚えた訳」の一覧で、1 件を消す。消すのは記憶だけ (結果に残っている直した訳は、そのまま)
    func removeRememberedTranslation(_ id: UUID) {
        translationMemory.remove(id)
        saveTranslationMemory()
    }

    /// 設定の「覚えた訳」の訳語の一覧・訳を直す画面で、訳語の対を足す (同じ原語・訳す先の物は書き換える)。
    /// 足したら true (原語か訳語が空なら false)。足した後、ほかの行を訳し直す事はしない (次の翻訳から効く)
    @discardableResult
    func addTerm(source: String, translation: String, target: String) -> Bool {
        guard translationMemory.setTerm(source: source, translation: translation, target: target) != nil else { return false }
        saveTranslationMemory()
        return true
    }

    /// 設定の「覚えた訳」の訳語の一覧で、1 件を消す
    func removeTerm(_ id: UUID) {
        translationMemory.removeTerm(id)
        saveTranslationMemory()
    }

    /// 対訳の行の「訳を直す…」・「直した」の印: 訳を直す画面を開く (文字起こしが終わった結果だけ)
    func requestTranslationEdit(_ id: UUID, in job: Job) {
        guard job.status == .done, job.transcript != nil else { return }
        translationEdit = TranslationEditRequest(jobID: job.id, segmentID: id)
    }

    /// 利用者の訳を置く (訳を直す画面の「保存」)。id は、その行のどの区間でもよい (その区間を含む訳のまとまりに置く)。
    /// 結果に残し (後から来る機械の訳は、この訳を上書きしない: `Transcript.apply`)、訳の記憶に入れる。
    /// 機械の訳と同じに書き直した時は、機械の訳に戻す (記憶からも外す)。何か変えたら true
    @discardableResult
    func setTranslation(_ text: String, head id: UUID, in job: Job) -> Bool {
        guard job.status == .done, var transcript = job.transcript,
              let head = Translator.translationGroupIDs(of: id, in: transcript.segments).first,
              let segment = transcript.segments.first(where: { $0.id == head }) else { return false }
        // 訳す先は、訳を置く前に決める (訳が 1 つも無い結果は、置くと「日本語に訳した結果」に見えてしまうので、言語も残す)
        let target = translationTarget(for: transcript)
        let before = transcript.translationNote(for: head)
        let source = transcript.translationSource(ofHead: head) ?? segment.text
        let sourceLanguage = transcript.language(of: segment)
        let model = transcript.translationModel
        guard let note = transcript.setUserTranslation(text, for: head) else {
            // 機械の訳と同じに書き直した: 機械の訳に戻した (印の付いた機械の訳なら、"llm" の覚えが戻っている)
            guard let before, before.isEdited, transcript.translationNote(for: head)?.isEdited != true else { return false }
            job.transcript = transcript
            let forgot = translationMemory.forget(source: source, target: target)
            let uncounted = withdrawGateVote(of: before, target: target)
            if forgot || uncounted { saveTranslationMemory() }
            return true
        }
        if transcript.translationLanguage == nil { transcript.translationLanguage = target }
        job.transcript = transcript
        let translation = transcript.segments.first { $0.id == head }?.translation ?? text
        translationMemory.remember(source: source, sourceLanguage: sourceLanguage, target: target, translation: translation,
                                   machine: note.machine, model: note.machine == nil ? nil : model)
        // 印の付いた機械の訳を、初めて直した: 検査が当たった数を足す (もう数えてある訳には足さない)
        if note.vote == TranslationNote.edited, before?.vote != TranslationNote.edited {
            countGateVote(flags: note.flags, target: target, edited: 1)
        }
        saveTranslationMemory()
        return true
    }

    // MARK: 関門が、利用者の判定から学ぶ

    /// 印の付いた訳への判定を、訳の記憶の検査ごとの数に足す (負の数で引く)。保存は呼ぶ側
    /// (確認用の起動も、これを呼んで「止める → 元に戻す」を確かめる)
    @discardableResult
    func countGateVote(flags: [String], target: String, confirmed: Int = 0, edited: Int = 0) -> Bool {
        translationMemory.countGate(flags: flags, target: target, confirmed: confirmed, edited: edited)
    }

    /// 直して足した判定 (覚えの vote が "edited") を引く (「機械の訳に戻す」の時)。引いたら true。保存は呼ぶ側
    private func withdrawGateVote(of note: TranslationNote, target: String) -> Bool {
        guard note.vote == TranslationNote.edited else { return false }
        return countGateVote(flags: note.flags, target: target, edited: -1)
    }

    /// 設定の「印を出さなくなった検査」の [元に戻す]: その検査 × 訳す先の数を 0 に戻す (また印を出す)
    func resetGateCheck(_ check: String, target: String) {
        guard translationMemory.resetGate(check: check, target: target) else { return }
        saveTranslationMemory()
    }

    /// 利用者が直した訳を、機械の訳に戻す (訳を直す画面の「機械の訳に戻す」)。訳の記憶からも、その 1 件を消す
    func revertTranslation(head id: UUID, in job: Job) {
        guard var transcript = job.transcript,
              let head = Translator.translationGroupIDs(of: id, in: transcript.segments).first else { return }
        let target = translationTarget(for: transcript)
        let source = transcript.translationSource(ofHead: head)
        guard let removed = transcript.revertUserTranslation(of: head) else { return }
        job.transcript = transcript
        let forgot = source.map { translationMemory.forget(source: $0, target: target) } ?? false
        let uncounted = withdrawGateVote(of: removed, target: target)
        if forgot || uncounted { saveTranslationMemory() }
    }

    /// 印の付いた訳を「この訳でよい」とする (訳を直す画面のボタン)。印は消え、覚えの出どころは "confirmed" になる。
    /// 訳の記憶の文には入れない (入れるのは、利用者が直した訳だけ)。まだ数えていない訳なら、
    /// その印の検査ごとに「検査の誤り」の数を足す (`TranslationMemory.countGate`)。変えたら true
    @discardableResult
    func confirmTranslation(head id: UUID, in job: Job) -> Bool {
        guard job.status == .done, var transcript = job.transcript,
              let head = Translator.translationGroupIDs(of: id, in: transcript.segments).first else { return false }
        let before = transcript.translationNote(for: head)
        guard let note = transcript.confirmTranslation(of: id) else { return false }
        job.transcript = transcript
        if before?.vote == nil, note.vote == TranslationNote.confirmed,
           countGateVote(flags: note.flags, target: translationTarget(for: transcript), confirmed: 1) {
            saveTranslationMemory()
        }
        return true
    }
}
