// 訳し直しの確認 (RETRANSLATE CHECK): 結果の画面の「〇〇語で訳し直す」の道 (AppModel.retranslate) を、
// LLM の代わり (決まった訳を返す生成器) で、最後まで通す。

import Foundation
import KikimimiCore

extension LoadRun {
    /// ふだんと同じ AppModel の関数で、訳の付いた結果を「別の言語で訳し直す」。
    /// LLM が無い時は何も変えずに知らせを出す事、LLM が在る時は、訳し直す前の状態が自動の版として 1 つだけ残り
    /// (メモリの上とディスクの上の両方)、訳が新しい言語の訳に置きかわる事、「いちばん新しい版に上書き」の相手が
    /// 自分で残した版のままである事を見る。
    /// 本物の設定・ライブラリには書かない: 結果は確認用のライブラリ (一時のフォルダ) に入れ、終わりに消す。
    /// LLM が在る事にするのも、LLM の代わりを入れるのも、この確認の間だけ (終わりに元に戻す)。
    /// 出力の行と、失敗したかを返す
    func retranslateCheck(root: URL) async -> (lines: [String], failed: Bool) {
        Self.live("retranslate check")
        var lines: [String] = []
        var failure: String?
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            lines.append("RETRANSLATE: \(name): \(ok ? "ok" : "FAILED") (\(detail))")
            if !ok, failure == nil { failure = name }
        }
        // 確認の間だけ変える物の、始める前の値
        let installedBefore = model.installedLLMIDs
        let customBefore = model.customLLMFiles
        let errorBefore = model.errorMessage
        let selectedBefore = model.selectedJob
        let standIn = RetranslateStandIn()
        var made: Job?
        defer {
            // 変えた物を、始める前と同じに戻す (途中で失敗して戻った時も)
            model.llm.selfTestGenerator = nil
            model.installedLLMIDs = installedBefore
            model.customLLMFiles = customBefore
            model.errorMessage = errorBefore
            model.select(selectedBefore)
            if let made { model.delete(made) }
            model.flushLibrary()
        }

        // 1. 訳 (英語) の付いた、終わった結果を作り、保存されるのを待って、自分で残した版を 1 つ残す
        let sources = [
            "今日は確認用の短い録音です。",
            "訳し直す前の訳を、版に残します。",
            "新しい言語で、もう一度訳します。",
            "最後に、元に戻して片付けます。",
        ]
        let before = [
            "This is a short recording for the check.",
            "The translation before translating again is kept as a version.",
            "It is translated again into a new language.",
            "At the end, everything is put back and cleaned up.",
        ]
        let oldLanguage = "en", newLanguage = "fr"
        let job = makeTranslatedJob("Retranslate check (self-test)", sources: sources, translations: before,
                                    language: "ja", translationLanguage: oldLanguage)
        made = job
        model.select(job)
        model.flushLibrary()
        let store = LibraryStore(root: root)
        let savedNormally = FileManager.default.fileExists(atPath: store.documentURL(for: job.id).path)
        step("the translated result is saved", savedNormally && model.canEditVersions(job),
             "document.json \(savedNormally), versions allowed \(model.versionBlockedReason(job) ?? "yes")")
        let manualSaved = await model.saveVersion(job, label: "Manual version (self-test)", mode: .new)
        let manualID = job.versions.first?.id
        step("save a manual version", manualSaved && job.versions.count == 1 && job.versions.first?.origin == .manual,
             "saved \(manualSaved), versions \(job.versions.map { "\($0.origin)" }) (expected [manual])")
        guard let manualID else { return finishRetranslate(lines, failure: failure ?? "save a manual version") }
        let transcriptBefore = job.transcript

        // 2. LLM が無い時: 訳し直しを頼んでも、版は増えず、訳も変わらず、知らせが出る
        model.installedLLMIDs = []
        model.customLLMFiles = []
        model.errorMessage = nil
        let installedWithout = model.isLLMInstalled
        model.retranslate(job, into: newLanguage)
        // 版を残す仕事は Task の中なので、少し待ってから見る (LLM が無ければ、Task は始まらないはず)
        await UILoadSelfTest.sleep(0.5)
        let message = model.errorMessage
        step("without the LLM nothing changes and a message is shown",
             !installedWithout && job.versions.count == 1 && job.transcript == transcriptBefore
                && !(message ?? "").isEmpty && job.postQueue.isEmpty && job.postState == .idle,
             "LLM installed \(installedWithout), versions \(job.versions.count) (expected 1), "
                + "transcript unchanged \(job.transcript == transcriptBefore), message \(message.map { "\"\($0)\"" } ?? "none")")
        model.errorMessage = nil

        // 3. LLM が在る事にして (今の LLM の ID を、確認の間だけ入れる)、LLM の代わりで、別の言語へ訳し直す
        let current = model.currentLLM
        if let spec = current.spec {
            model.installedLLMIDs = installedBefore.union([spec.id])
        } else {
            model.customLLMFiles = customBefore + [current.url.lastPathComponent]
        }
        let answers = Dictionary(uniqueKeysWithValues: sources.enumerated().map {
            ($0.element, "Phrase retraduite pour le controle, ligne \(["un", "deux", "trois", "quatre"][$0.offset]).")
        })
        standIn.configure(answers: answers)
        model.llm.selfTestGenerator = standIn
        step("the LLM counts as installed for the check", model.isLLMInstalled,
             "current LLM \(current.name), installed \(model.isLLMInstalled)")
        model.retranslate(job, into: newLanguage)

        // 4. 自動の版が残り、翻訳の仕事が終わるまで待つ (20 秒まで)
        var versionSeen = false
        for _ in 0..<400 {
            if job.versions.contains(where: { $0.origin != .manual }) {
                versionSeen = true
                break
            }
            await UILoadSelfTest.sleep(0.05)
        }
        var finished = false
        if versionSeen {
            for _ in 0..<400 {
                if job.postQueue.isEmpty && job.postState == .idle && !job.versionBusy
                    && job.transcript?.translationLanguage == newLanguage && job.transcript?.hasTranslation == true {
                    finished = true
                    break
                }
                await UILoadSelfTest.sleep(0.05)
            }
        }
        step("retranslate through the model with the stand-in", versionSeen && finished && standIn.calls > 0,
             "automatic version seen \(versionSeen), translation finished \(finished), stand-in calls \(standIn.calls)")

        // (a) 訳し直す前の版が、メモリの上とディスクの上に 1 つだけ在る
        model.flushLibrary()
        let auto = job.versions.filter { $0.origin == .beforeRetranslation }
        let loaded = store.load(id: job.id)
        let autoOnDisk = loaded?.versions.filter { $0.origin == .beforeRetranslation } ?? []
        let versionFile = auto.first.map { store.versionURL(documentID: job.id, versionID: $0.id) }
        let fileExists = versionFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        step("one version before translating again, in memory and on disk",
             auto.count == 1 && autoOnDisk.count == 1 && autoOnDisk.first?.id == auto.first?.id && fileExists
                && job.versions.count == 2,
             "in memory \(auto.count), on disk \(autoOnDisk.count) (expected 1, 1), version file \(fileExists), "
                + "origins \(job.versions.map { "\($0.origin)" }) (expected [beforeRetranslation, manual])")

        // (b) その版の中身は、訳し直す前の訳と、前の訳した言語
        var versionTranslations: [String?] = []
        var versionLanguage: String?
        if let id = auto.first?.id, let version = try? store.loadVersion(documentID: job.id, versionID: id) {
            versionTranslations = version.transcript.segments.map(\.translation)
            versionLanguage = version.transcript.translationLanguage
        }
        step("the version keeps the translation before translating again",
             versionTranslations == before.map { Optional($0) } && versionLanguage == oldLanguage,
             "language \(versionLanguage ?? "none") (expected \(oldLanguage)), "
                + "translations \(versionTranslations == before.map { Optional($0) } ? "the same" : "\(versionTranslations)")")

        // (c) 翻訳の後: 訳した言語は新しい言語で、行の訳は LLM の代わりの答え (前の訳は残っていない)
        let after = job.transcript?.segments ?? []
        let expected = after.map { answers[$0.text] }
        let leftovers = after.filter { segment in before.contains { $0 == segment.translation } }.count
        step("the result is translated into the new language",
             job.transcript?.translationLanguage == newLanguage && after.count == sources.count
                && after.map(\.translation) == expected && !expected.contains(nil) && leftovers == 0,
             "language \(job.transcript?.translationLanguage ?? "none") (expected \(newLanguage)), "
                + "rows with the stand-in's translation \(zip(after.map(\.translation), expected).filter { $0.0 == $0.1 && $0.1 != nil }.count)"
                + " of \(sources.count), rows with the old translation \(leftovers)")

        // (d) 「いちばん新しい版に上書き」の相手は、自分で残した版のまま (自動の版ではない)
        let latestInMemory = model.snapshot(of: job)?.latestManualVersion?.id
        let latestOnDisk = loaded?.latestManualVersion?.id
        step("overwrite the newest version still means the manual version",
             latestInMemory == manualID && latestOnDisk == manualID,
             "in memory \(latestInMemory == manualID ? "the manual version" : latestInMemory?.uuidString ?? "none"), "
                + "on disk \(latestOnDisk == manualID ? "the manual version" : latestOnDisk?.uuidString ?? "none")")

        // (e) 履歴の画面の、自動の版の印
        let badge = HistorySheet.automaticBadge(for: .beforeRetranslation)
        let manualBadge = HistorySheet.automaticBadge(for: .manual)
        step("the history sheet marks the version as automatic",
             badge == L("Automatic (before translating again)") && manualBadge == nil,
             "badge \(badge ?? "none"), manual \(manualBadge ?? "none")")
        return finishRetranslate(lines, failure: failure)
    }

    private func finishRetranslate(_ lines: [String], failure: String?) -> (lines: [String], failed: Bool) {
        (lines + [failure.map { "RETRANSLATE CHECK FAILED: \($0)" } ?? "RETRANSLATE CHECK OK"], failure != nil)
    }

    /// 確認用の、訳の付いた終わった結果を作って、モデルに入れる (確認用のライブラリに保存される)
    private func makeTranslatedJob(_ name: String, sources: [String], translations: [String], language: String,
                                   translationLanguage: String) -> Job {
        let job = Job(name: name, url: nil)
        let segments = sources.enumerated().map {
            TranscriptSegment(start: Double($0.offset) * 3, end: Double($0.offset) * 3 + 3, text: $0.element,
                              translation: translations[$0.offset])
        }
        job.transcript = Transcript(sourceName: name, segments: segments, language: language,
                                    duration: Double(sources.count) * 3, elapsed: 1,
                                    translationModel: "self-test", translationLanguage: translationLanguage)
        job.status = .done
        job.progress = 1
        job.message = L("Done")
        model.adopt(job, at: model.jobs.count)
        return job
    }
}

/// 訳し直しの確認の、LLM の代わり。「Lines to translate」の行 ([番号] 原文) に、決めた訳 (原文ごと) で答える。
/// 決めていない原文には、決まった印の文で答える (照らし合わせで落ちるように)
final class RetranslateStandIn: TextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String] = [:]
    private var count = 0

    /// これまでに答えた回数
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func configure(answers: [String: String]) {
        lock.lock()
        self.answers = answers
        lock.unlock()
    }

    var contextLength: Int { 8192 }

    func tokenCount(_ text: String) -> Int { text.utf8.count / 3 + 1 }

    func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool) throws -> String {
        lock.lock()
        count += 1
        let answers = self.answers
        lock.unlock()
        guard let range = prompt.user.range(of: "Lines to translate:\n") else { return "" }
        var out: [String] = []
        for line in prompt.user[range.upperBound...].split(separator: "\n") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let number = line[line.index(after: line.startIndex)..<close]
            let source = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            out.append("[\(number)] \(answers[source] ?? "Unexpected line for the stand-in.")")
        }
        // 最後の行も改行で終える (答えを読む所は、改行で終わっていない最後の行を、書きかけとして捨てる)
        return out.map { $0 + "\n" }.joined()
    }
}
