// 聞き取った文を、利用者が手で直す所 (行の右クリックの「この行を直す…」・原文の「直した」の印)。
// 中身の決まりは KikimimiCore の LineEdit.swift (Transcript.setLineText・revertLineEdit)。

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
    /// 保存は、結果に入れれば自動 (`Job.transcript` の didSet)。翻訳は自動では走らせない
    /// (監査の直しを反映した時と同じ: 行に「訳」が出る)。学習した直しの台帳にも書かない
    @discardableResult
    func setLineTexts(_ texts: [UUID: String], in job: Job) -> Bool {
        guard job.status == .done, var transcript = job.transcript else { return false }
        let date = Date()
        var changed = false
        for (id, text) in texts where transcript.setLineText(text, forSegment: id, date: date) {
            changed = true
        }
        guard changed else { return false }
        job.transcript = transcript
        return true
    }

    /// 1 つの区間の文を直す (`setLineTexts` の 1 区間の形)
    @discardableResult
    func setLineText(_ text: String, segment id: UUID, in job: Job) -> Bool {
        setLineTexts([id: text], in: job)
    }

    /// 区間 ids の直しを元に戻す (行を直す画面の「聞き取った文に戻す」)。結果への代入は 1 回だけ。戻したら true
    @discardableResult
    func revertLineEdits(_ ids: [UUID], in job: Job) -> Bool {
        guard job.status == .done, var transcript = job.transcript else { return false }
        var changed = false
        for id in ids where transcript.revertLineEdit(forSegment: id) {
            changed = true
        }
        guard changed else { return false }
        job.transcript = transcript
        return true
    }

    /// 1 つの区間の直しを元に戻す (`revertLineEdits` の 1 区間の形)
    @discardableResult
    func revertLineEdit(_ id: UUID, in job: Job) -> Bool {
        revertLineEdits([id], in: job)
    }
}
