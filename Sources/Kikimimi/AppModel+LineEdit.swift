// 聞き取った文を、利用者が手で直す所 (行の右クリックの「この行を直す…」・原文の「直した」の印)。
// 中身の決まりは KikimimiCore の LineEdit.swift (Transcript.setLineText・revertLineEdit・LineEdit.ledgerUpdate)。

import Foundation
import KikimimiCore

extension AppModel {
    /// 行を直す画面を開く (文字起こしが終わった結果だけ。訳を直す画面と同じ守り)。
    /// ids は行が持つ区間の全部 (対訳の行は、訳のまとまりの区間の全部。画面は区間ごとに入力欄を出す)
    func requestLineEdit(_ ids: [UUID], in job: Job) {
        guard job.status == .done, job.transcript != nil, !ids.isEmpty else { return }
        lineEdit = LineEditRequest(jobID: job.id, segmentIDs: ids)
    }

    /// 区間ごとの文を、利用者の文に直す (行を直す画面の「保存」)。何か変えたら true。
    /// 結果への代入は 1 回だけ (保存と一覧の作り直しが 1 回で済むように)。
    /// learning は、区間ごとの「学習した直しの台帳に覚えさせる組」。texts に在って learning に無い区間は、覚えない
    /// (前に覚えさせていれば取り消す)。学習した直しを使わない設定 (useLedger が切) の時は、台帳にも組にも触らない。
    /// 文は変わらず、組だけが変わった区間も、組を置き換える。
    /// 保存は、結果に入れれば自動 (`Job.transcript` の didSet)。翻訳は自動では走らせない
    /// (監査の直しを反映した時と同じ: 行に「訳」が出る)
    @discardableResult
    func setLineTexts(_ texts: [UUID: String], learning: [UUID: AuditChange.Pair] = [:], in job: Job) -> Bool {
        guard job.status == .done, var transcript = job.transcript else { return false }
        let date = Date()
        var changed = false
        var ledgerChanged = false
        for (id, text) in texts {
            guard useLedger else {
                if transcript.setLineText(text, forSegment: id, date: date) { changed = true }
                continue
            }
            let old = transcript.lineEdit(forSegment: id)?.learned
            let wanted = learning[id]
            let done = transcript.setLineText(text, forSegment: id, learned: wanted, date: date)
                || transcript.setLineLearned(wanted, forSegment: id)
            guard done else { continue }
            changed = true
            // 直しを聞き取った文に戻した時は、記録が無くなるので、覚えた組も無い (取り消す)
            let edit = transcript.lineEdit(forSegment: id)
            let update = LineEdit.ledgerUpdate(old: old, new: edit?.learned)
            if apply(update, segment: id, heard: edit?.heard, in: transcript) { ledgerChanged = true }
        }
        guard changed else { return false }
        job.transcript = transcript
        if ledgerChanged { saveLedger() }
        return true
    }

    /// 1 つの区間の文を直す (`setLineTexts` の 1 区間の形)
    @discardableResult
    func setLineText(_ text: String, segment id: UUID, learning pair: AuditChange.Pair? = nil, in job: Job) -> Bool {
        setLineTexts([id: text], learning: pair.map { [id: $0] } ?? [:], in: job)
    }

    /// 区間 ids の直しを元に戻す (行を直す画面の「聞き取った文に戻す」)。結果への代入は 1 回だけ。戻したら true。
    /// 学習した直しの台帳に覚えさせていた組は、取り消す (useLedger が切の時は、台帳に触らない)
    @discardableResult
    func revertLineEdits(_ ids: [UUID], in job: Job) -> Bool {
        guard job.status == .done, var transcript = job.transcript else { return false }
        var changed = false
        var ledgerChanged = false
        for id in ids {
            let old = transcript.lineEdit(forSegment: id)?.learned
            guard transcript.revertLineEdit(forSegment: id) else { continue }
            changed = true
            if useLedger, apply(LineEdit.ledgerUpdate(old: old, new: nil), segment: id, heard: nil, in: transcript) {
                ledgerChanged = true
            }
        }
        guard changed else { return false }
        job.transcript = transcript
        if ledgerChanged { saveLedger() }
        return true
    }

    /// 1 つの区間の直しを元に戻す (`revertLineEdits` の 1 区間の形)
    @discardableResult
    func revertLineEdit(_ id: UUID, in job: Job) -> Bool {
        revertLineEdits([id], in: job)
    }

    /// 台帳に、取り消す組と覚える組を当てる (監査の一覧で決めた時と同じ形: 言語はその行の言語、例は聞き取った文)。
    /// 台帳を変えたら true (保存は呼ぶ側)
    private func apply(_ update: LineEdit.LedgerUpdate, segment id: UUID, heard: String?, in transcript: Transcript) -> Bool {
        guard !update.isEmpty else { return false }
        if let old = update.retract {
            ledger.retract(wrong: old.wrong, right: old.right)
        }
        if let new = update.record {
            let language = transcript.segments.first { $0.id == id }.flatMap { transcript.language(of: $0) }
            ledger.record(wrong: new.wrong, right: new.right, language: language, example: heard, accepted: true)
        }
        return true
    }
}
