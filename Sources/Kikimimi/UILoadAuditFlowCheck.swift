// 監査の流れの確認 (AUDIT FLOW CHECK): アプリの監査の呼び方そのもの (AppModel.audit → runPost(.audit)) を、
// LLM の代わり (決まった答えを返す生成器) で、最後まで通す。

import Foundation
import KikimimiCore

extension LoadRun {
    /// ふだんと同じ AppModel の関数で、行を直して組を覚える (1 回) → 監査 → 別の行に提案 → 反映 (2 回) →
    /// 別の結果の監査、を通す。別の結果では、規則だけの段の後に自動で直り、LLM の代わりの監査が終わった後も直ったままか、
    /// LLM の代わりが覚えた字を書き換える直しを出しても、行が覚えた字のままかを見る。
    /// 本物の設定・台帳・ライブラリには書かない: 台帳は一時のファイル (終わりに消し、始める前の状態に戻す)、
    /// 結果は確認用のライブラリ (一時のフォルダ) に入れ、終わりに消す。LLM の代わりも、終わりに外す。
    /// 出力の行と、失敗したかを返す
    func auditFlowCheck(root: URL) async -> (lines: [String], failed: Bool) {
        Self.live("audit flow check")
        var lines: [String] = []
        var failure: String?
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            lines.append("AUDIT FLOW: \(name): \(ok ? "ok" : "FAILED") (\(detail))")
            if !ok, failure == nil { failure = name }
        }
        let realLedger = model.ledgerURL
        let realLedgerBefore = Self.fileStamp(realLedger)
        let wasUsingFile = model.ledgerFileURL
        step("learned corrections are on and have no file before the check", wasUsingFile == nil && model.useLedger,
             "ledger file \(wasUsingFile?.path ?? "none") (expected none), use learned corrections \(model.useLedger)")
        let ledgerURL = root.deletingLastPathComponent()
            .appendingPathComponent("kikimimi-ui-load-audit-ledger-\(UUID().uuidString).json")
        model.useLedgerFile(at: ledgerURL)
        let standIn = AuditFlowStandIn()
        model.llm.selfTestGenerator = standIn
        var made: [Job] = []
        defer {
            // 結果と台帳と LLM の代わりを、始める前と同じに戻す
            model.llm.selfTestGenerator = nil
            for job in made { model.delete(job) }
            model.flushLibrary()
            model.useLedgerFile(at: wasUsingFile)
            try? FileManager.default.removeItem(at: ledgerURL)
        }
        let wrong = "Roblocks", right = "Roblox"
        func accepted() -> (memory: Int, saved: Int) {
            let find = { (ledger: CorrectionLedger) in
                ledger.corrections.first { $0.wrong == wrong && $0.right == right }?.accepted ?? 0
            }
            return (find(model.ledger), find(CorrectionLedger.load(from: ledgerURL)))
        }

        // 1. 結果 A の 1 行を手で直し、組を 1 回覚えさせる
        let first = makeJob("監査の流れの確認 A (確認用)", lines: [
            "Open Roblocks Studio first.",
            "Our team uses Roblocks every day.",
            "We will make a small game today.",
            "Thanks for joining the session.",
        ])
        made.append(first)
        guard let a = first.transcript?.segments, a.count == 4 else {
            step("make result A", false, "no segments")
            return finish(lines, failure: failure ?? "make result A")
        }
        let edited = "Open Roblox Studio first."
        let pair = LineEdit.suggestedPair(heard: a[0].text, edited: edited)
        let saved = model.setLineText(edited, segment: a[0].id, learning: pair, in: first)
        step("edit a line and remember the pair once",
             saved && pair == AuditChange.Pair(wrong: wrong, right: right) && accepted() == (1, 1),
             "saved \(saved), pair \(pair.map { "\($0.wrong) → \($0.right)" } ?? "none"), "
                + "applied \(accepted().memory) (saved \(accepted().saved)) (expected Roblocks → Roblox, 1, 1)")

        // 2. 結果 A を監査する (LLM の代わりは何も見つけない): 別の行に、学習した直しの提案が出る
        standIn.configure(fixes: [])
        let auditedA = await audit(first)
        let proposal = first.transcript?.audit?.change(forSegment: a[1].id)
        step("audit result A through the model", auditedA && first.transcript?.audit?.model != nil && standIn.calls > 0,
             "finished \(auditedA), model \(first.transcript?.audit?.model ?? "none"), stand-in calls \(standIn.calls)")
        step("the learned pair is proposed on another line",
             proposal?.origin == .ledger && proposal?.isApplied == false
                && proposal?.replacement == "Our team uses Roblox every day."
                && first.transcript?.segments[1].text == a[1].text,
             "origin \(proposal.map { "\($0.origin)" } ?? "none"), applied \(proposal?.isApplied ?? false), "
                + "replacement \(proposal?.replacement ?? "none") (expected ledger, false, the fixed line)")

        // 3. 提案を反映する: 2 回目を覚え、組が自動になる
        if let proposal {
            model.setAuditChange(proposal, applied: true, in: first)
        }
        let twice = accepted()
        let automatic = model.ledger.corrections.first { $0.wrong == wrong && $0.right == right }?.isAutomatic ?? false
        step("apply the proposal and remember the pair twice",
             twice == (2, 2) && automatic && first.transcript?.segments[1].text == "Our team uses Roblox every day.",
             "applied \(twice.memory) (saved \(twice.saved)), automatic \(automatic), "
                + "line \(first.transcript?.segments[1].text ?? "none") (expected 2, 2, true)")

        // 4. 別の結果 B を監査する。LLM の代わりは、覚えた字 (Roblox) を書き換える直しと、別の行の直しを出す。
        // 規則だけの段を反映した所で LLM の代わりを止めて (始めの答えの手前で待たせて)、行を見る
        let second = makeJob("監査の流れの確認 B (確認用)", lines: [
            "Open Roblocks Studio first.",
            "We will bild a small game today.",
            "First we add a part to the place.",
            "Then we press the play button.",
            "It takes about ten minutes.",
            "Thanks for joining the session.",
        ])
        made.append(second)
        guard let b = second.transcript?.segments, b.count == 6 else {
            step("make result B", false, "no segments")
            return finish(lines, failure: failure ?? "make result B")
        }
        standIn.configure(fixes: [(line: "Studio first", wrong: right, right: "Roblux"),
                                  (line: "small game", wrong: "bild", right: "build")],
                          hold: true)
        let callsBefore = standIn.calls
        model.audit(second)
        var rulesSeen = false
        for _ in 0..<200 {
            if let report = second.transcript?.audit, report.model == nil, report.change(forSegment: b[0].id) != nil {
                rulesSeen = true
                break
            }
            if second.postQueue.isEmpty && second.postState == .idle { break }
            await UILoadSelfTest.sleep(0.05)
        }
        let afterRules = second.transcript
        let rulesChange = afterRules?.audit?.change(forSegment: b[0].id)
        step("the rules-only step fixes the line automatically",
             rulesSeen && afterRules?.segments[0].text == "Open Roblox Studio first."
                && rulesChange?.origin == .ledger && rulesChange?.isApplied == true,
             "seen \(rulesSeen), line \(afterRules?.segments[0].text ?? "none"), "
                + "origin \(rulesChange.map { "\($0.origin)" } ?? "none"), applied \(rulesChange?.isApplied ?? false)")
        standIn.release()
        let auditedB = await waitUntilIdle(second)
        let report = second.transcript?.audit
        let kept = report?.change(forSegment: b[0].id)
        let other = report?.change(forSegment: b[1].id)
        step("audit result B through the model with the stand-in",
             auditedB && report?.model != nil && standIn.calls > callsBefore,
             "finished \(auditedB), model \(report?.model ?? "none"), stand-in calls \(standIn.calls - callsBefore)")
        step("the automatic fix stays after the LLM step",
             second.transcript?.segments[0].text == "Open Roblox Studio first."
                && kept?.origin == .ledger && kept?.isApplied == true
                && kept?.decisionPairs == [AuditChange.Pair(wrong: wrong, right: right)],
             "line \(second.transcript?.segments[0].text ?? "none"), origin \(kept.map { "\($0.origin)" } ?? "none"), "
                + "applied \(kept?.isApplied ?? false) (expected the learned word, ledger, true)")
        step("the LLM step fixes another line",
             second.transcript?.segments[1].text == "We will build a small game today."
                && other?.origin == .llm && other?.isApplied == true,
             "line \(second.transcript?.segments[1].text ?? "none"), origin \(other.map { "\($0.origin)" } ?? "none")")

        // 5. LLM が途中で失敗した時 (llama.cpp の失敗 -1 を、LLM の代わりが投げる)
        await llmFailureSteps(standIn: standIn, previous: second, step: step, made: &made)

        // 6. 終わり: 本物の台帳は変わっていない (戻すのは defer。ここでは本物のファイルだけを見る)
        step("the check does not touch the real learned corrections", Self.fileStamp(realLedger) == realLedgerBefore,
             "real file \(realLedgerBefore) → \(Self.fileStamp(realLedger))")
        return finish(lines, failure: failure)
    }

    /// LLM が途中で失敗した時の監査の受け止め方を見る: (a) はじめの監査で、始めの依頼から失敗 → 規則だけを反映した知らせ、
    /// (b) はじめの監査で、1 つ目のまとまりの後に失敗 → 見終えた所までを反映した知らせ、
    /// (c) 前に LLM で監査した結果 previous で失敗 → 前の監査の結果のまま。
    /// どれも、仕事が終わった状態 (待ち・動いている仕事が無い) に戻る事も見る。作った結果は made に足す (終わりに消す)
    private func llmFailureSteps(standIn: AuditFlowStandIn, previous: Job,
                                 step: (String, Bool, String) -> Void, made: inout [Job]) async {
        let error = LLMError.decodeFailed(-1).localizedDescription
        func idle(_ job: Job) -> Bool { job.postQueue.isEmpty && job.postState == .idle && !job.isPostActive }

        // (a) はじめの監査で、始めの依頼から失敗する
        let atOnce = makeJob("Audit flow check C (self-test)", lines: [
            "Please water the plants on Friday.",
            "Seven people joined the call from Osaka.",
            "The bridge downtown closes at midnight.",
            "Lunch will be served in the north hall.",
        ])
        made.append(atOnce)
        let rowsBefore = atOnce.transcript?.segments.map(\.text)
        let failuresBefore = standIn.failures
        standIn.configure(fixes: [], failAfter: 0)
        let finishedAtOnce = await audit(atOnce)
        let noteAtOnce = atOnce.postNote ?? ""
        step("LLM fails at once: only the repetition check is applied",
             finishedAtOnce && idle(atOnce) && standIn.failures > failuresBefore
                && noteAtOnce == L("The LLM could not audit, so only the repetition check was applied: %@", error)
                && noteAtOnce.contains("-1")
                && atOnce.transcript?.audit?.model == nil
                && atOnce.transcript?.segments.map(\.text) == rowsBefore,
             "finished \(finishedAtOnce), idle \(idle(atOnce)), failures \(standIn.failures - failuresBefore), "
                + "model \(atOnce.transcript?.audit?.model ?? "none") (expected none), "
                + "rows unchanged \(atOnce.transcript?.segments.map(\.text) == rowsBefore), note \"\(noteAtOnce)\"")

        // (b) はじめの監査で、1 つ目のまとまり (20 行) の後に失敗する。
        // 1 つ目のまとまりの答え (1 回) と、その直しの評価役 (2 回) には答え、2 つ目のまとまりの依頼で失敗する
        // 互いに似ていない文 (規則の「繰り返し」に当たらない)。2 行目だけを、LLM の代わりが直す
        let texts = [
            "Open the editor before the meeting starts.", "We will bild a small game today.",
            "Our designer prefers warm colors for menus.", "Yesterday the file server crashed twice.",
            "Remember to back up your laptop weekly.", "A cat slept on the keyboard all morning.",
            "We should test the parser with long inputs.", "Her violin lesson moved to Thursday.",
            "Snow is expected in the mountains tonight.", "The printer on floor three is jammed again.",
            "Bring an umbrella if you walk to the station.", "My brother collects old maps of harbors.",
            "This recipe needs fresh basil and lemon.", "Traffic was light on the highway today.",
            "Ask the librarian about the rare books.", "The orchestra rehearses every Tuesday.",
            "Please sign the visitor log at the desk.", "Most tickets sold out within an hour.",
            "He fixed the squeaky door with some oil.", "Our garden produced too many tomatoes.",
            "The museum opens a new dinosaur exhibit.", "Charge the drone batteries overnight.",
            "Spring cleaning starts with the garage.", "We finished the agenda early.",
        ]
        let partway = makeJob("Audit flow check D (self-test)", lines: texts)
        made.append(partway)
        let partwayBefore = partway.transcript?.segments.map(\.text) ?? []
        standIn.configure(fixes: [(line: "small game", wrong: "bild", right: "build")], failAfter: 3)
        let failuresBeforePartway = standIn.failures
        let finishedPartway = await audit(partway)
        let notePartway = partway.postNote ?? ""
        let report = partway.transcript?.audit
        let fixed = report?.change(forSegment: partway.transcript?.segments[1].id ?? UUID())
        let rowsAfter = partway.transcript?.segments.map(\.text) ?? []
        let othersUnchanged = rowsAfter.count == partwayBefore.count
            && zip(rowsAfter, partwayBefore).enumerated().allSatisfy { $0.offset == 1 || $0.element.0 == $0.element.1 }
        step("LLM fails partway: results up to that point are applied",
             finishedPartway && idle(partway) && standIn.failures > failuresBeforePartway
                && notePartway == L("The LLM audit stopped partway. Results up to the point it reached are applied: %@", error)
                && report?.model != nil && report?.isPartial == true
                && rowsAfter.count > 1 && rowsAfter[1] == "We will build a small game today."
                && fixed?.origin == .llm && fixed?.isApplied == true && othersUnchanged,
             "finished \(finishedPartway), idle \(idle(partway)), failures \(standIn.failures - failuresBeforePartway), "
                + "model \(report?.model ?? "none"), partial \(report?.isPartial ?? false), "
                + "line \(rowsAfter.count > 1 ? rowsAfter[1] : "none"), other rows unchanged \(othersUnchanged), "
                + "note \"\(notePartway)\"")

        // (c) 前に LLM で監査した結果で、始めの依頼から失敗する: 前の監査の結果のまま
        let previousBefore = previous.transcript
        standIn.configure(fixes: [], failAfter: 0)
        let failuresBeforeKept = standIn.failures
        let finishedKept = await audit(previous)
        let noteKept = previous.postNote ?? ""
        step("LLM fails with a previous LLM audit: the previous result is kept",
             finishedKept && idle(previous) && standIn.failures > failuresBeforeKept
                && noteKept == L("The LLM could not audit, so the previous audit result is kept: %@", error)
                && previousBefore?.audit?.model != nil && previous.transcript == previousBefore,
             "finished \(finishedKept), idle \(idle(previous)), failures \(standIn.failures - failuresBeforeKept), "
                + "previous model \(previousBefore?.audit?.model ?? "none"), "
                + "result unchanged \(previous.transcript == previousBefore), note \"\(noteKept)\"")

        // (d) 見直しの答えが「END」の手前で切れる (答えの長さの上限など): 監査はふつうに終わり、
        // 書き切った行の直しは使い、読めなかった所の数を知らせる。24 行 = 2 つのまとまりの、どちらの答えも切れる
        let cut = makeJob("Audit flow check E (self-test)", lines: texts)
        made.append(cut)
        standIn.configure(fixes: [(line: "small game", wrong: "bild", right: "build")], cutOff: true)
        let finishedCut = await audit(cut)
        let noteCut = cut.postNote ?? ""
        let expectedCut = LPlural(2, one: "The LLM’s answer could not be read in %d place, so problems there may have been missed.",
                                  other: "The LLM’s answer could not be read in %d places, so problems there may have been missed.")
        let cutReport = cut.transcript?.audit
        let cutRows = cut.transcript?.segments.map(\.text) ?? []
        step("the LLM answer is cut off: the audit finishes and tells how many places could not be read",
             finishedCut && idle(cut) && cutReport?.model != nil && cutReport?.isPartial == nil
                && noteCut == expectedCut
                && cutRows.count > 1 && cutRows[1] == "We will build a small game today.",
             "finished \(finishedCut), idle \(idle(cut)), model \(cutReport?.model ?? "none"), "
                + "partial \(cutReport?.isPartial ?? false), line \(cutRows.count > 1 ? cutRows[1] : "none"), "
                + "note \"\(noteCut)\"")
        standIn.configure(fixes: [])
    }

    private func finish(_ lines: [String], failure: String?) -> (lines: [String], failed: Bool) {
        (lines + [failure.map { "AUDIT FLOW CHECK FAILED: \($0)" } ?? "AUDIT FLOW CHECK OK"], failure != nil)
    }

    /// 確認用の、終わった結果を作って、モデルに入れる (確認用のライブラリに保存される)
    private func makeJob(_ name: String, lines texts: [String]) -> Job {
        let job = Job(name: name, url: nil)
        let segments = texts.enumerated().map {
            TranscriptSegment(start: Double($0.offset) * 3, end: Double($0.offset) * 3 + 3, text: $0.element)
        }
        job.transcript = Transcript(sourceName: name, segments: segments, language: "en",
                                    duration: Double(texts.count) * 3, elapsed: 1)
        job.status = .done
        job.progress = 1
        job.message = "完了"
        model.adopt(job, at: model.jobs.count)
        return job
    }

    /// 監査を頼み、終わるまで待つ。終わったら true
    private func audit(_ job: Job) async -> Bool {
        model.audit(job)
        return await waitUntilIdle(job)
    }

    /// 監査・翻訳の仕事が終わるまで待つ (20 秒まで)
    private func waitUntilIdle(_ job: Job) async -> Bool {
        for _ in 0..<400 {
            if job.postQueue.isEmpty && job.postState == .idle { return true }
            await UILoadSelfTest.sleep(0.05)
        }
        return false
    }
}

/// 監査の流れの確認の、LLM の代わり。「Lines to check」の行のうち、決めた字を含む行に「FIX 字 => 字」と答える。
/// 評価役 (1: … / 2: …) には、直した後の字を含む方を選ぶ (KikimimiCore の試験 AuditLedgerAfterLLMTests の偽物と同じ答え方)。
/// hold の時は、始めの答えの手前で、release() まで待つ (規則だけの段の後の行を見るため。10 秒で待つのをやめる)。
/// failAfter を渡すと、configure の後にその回数だけ答え、その次から llama.cpp の失敗 (`LLMError.decodeFailed(-1)`) を投げる
/// (0 なら始めの依頼から。LLM が途中で失敗した時のアプリの受け止め方を見るため)。
/// cutOff の時は、見直しの答えを「END」の手前で切る (書き切っていない答えの、アプリの知らせを見るため)
final class AuditFlowStandIn: TextGenerating, @unchecked Sendable {
    typealias Fix = (line: String, wrong: String, right: String)
    private let lock = NSLock()
    private var fixes: [Fix] = []
    private var gate: DispatchSemaphore?
    private var count = 0
    private var failAfter: Int?
    private var sinceConfigure = 0
    private var failedCount = 0
    private var cutOff = false

    /// これまでに答えた回数 (失敗を投げた回は数えない)
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// これまでに失敗を投げた回数
    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failedCount
    }

    func configure(fixes: [Fix], hold: Bool = false, failAfter: Int? = nil, cutOff: Bool = false) {
        lock.lock()
        self.fixes = fixes
        self.cutOff = cutOff
        gate = hold ? DispatchSemaphore(value: 0) : nil
        self.failAfter = failAfter
        sinceConfigure = 0
        lock.unlock()
    }

    func release() {
        lock.lock()
        let waiting = gate
        gate = nil
        lock.unlock()
        waiting?.signal()
    }

    var contextLength: Int { 8192 }

    func tokenCount(_ text: String) -> Int { text.utf8.count / 3 + 1 }

    func generate(_ prompt: LLMPrompt, shouldCancel: () -> Bool) throws -> String {
        lock.lock()
        let waiting = gate
        lock.unlock()
        if let waiting { _ = waiting.wait(timeout: .now() + 10) }
        lock.lock()
        if let failAfter, sinceConfigure >= failAfter {
            failedCount += 1
            lock.unlock()
            throw LLMError.decodeFailed(-1)
        }
        sinceConfigure += 1
        count += 1
        let fixes = self.fixes
        let cutOff = self.cutOff
        lock.unlock()
        if let range = prompt.user.range(of: "Lines to check:\n") {
            var answer: [String] = []
            for line in prompt.user[range.upperBound...].split(separator: "\n") {
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
                let number = line[line.index(after: line.startIndex)..<close]
                for fix in fixes where line.contains(fix.line) && line.contains(fix.wrong) {
                    answer.append("[\(number)] FIX \(fix.wrong) => \(fix.right)")
                }
            }
            // 切る時は、書き切った行の後ろに、行の途中で切れた指摘を置く (END は書かない)
            if cutOff { return (answer + ["[1] FIX wor"]).joined(separator: "\n") }
            return (answer + ["END"]).joined(separator: "\n")
        }
        for line in prompt.user.split(separator: "\n") where line.hasPrefix("1: ") || line.hasPrefix("2: ") {
            if fixes.contains(where: { line.contains($0.right) }) { return String(line.prefix(1)) }
        }
        return "1"
    }
}
