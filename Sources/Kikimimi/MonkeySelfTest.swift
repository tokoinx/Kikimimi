// 画面をでたらめな順に触る確認 (--selftest-monkey) の入口と、操作の表。
// 使い方と読み方は tools/monkey/README.md の「層 4: 開いた後の画面を触る」。

import AppKit
import Foundation
import KikimimiCore

/// `KIKIMIMI_LIBRARY_DIR=<一時のライブラリ> Kikimimi --selftest-monkey [--seed <種>] [--steps <回数>] [--report <ファイル>]`
///
/// 一時のライブラリ (環境変数) だけを開き、窓を出して、読み終えるのを待ち、`--steps` 回 (既定 300)、
/// 下の表の操作を 1 つずつ行う。行う前に、何をするかを 1 行で出す (標準出力と `--report` のファイル。1 行ごとに書き出す)。
/// 落ちた時は、その最後の行が、落ちた操作。1 つ行うたびに、画面が描き終わるのを待ち、いつも成り立つ事を見る。
///
/// 終了コード: 0 = 終わりまで行った (`MONKEY OK`)、2 = 引数か環境変数が使えない (始めない)、
/// 3 = メインスレッドが 20 秒進まない・1 つの操作が 60 秒終わらない (`MONKEY FAILED: stuck …`)、
/// 10 = いつも成り立つ事が破れた (`MONKEY FAILED: <訳> at step N: …`)。
///
/// 行わない事: 結果を消す (macOS のゴミ箱に入る)・文字起こし・監査・翻訳・チャット (LLM を呼ばない)・ネットワーク・
/// ファイルを選ぶ画面と、利用者の答えを待つ窓。知らせの窓 (errorMessage) が出たら、文を足あとに書いてから消して進む。
/// 確認用の起動なので、設定は書かない (SettingsWriter が書かない。macOS が書いた物は、終わりに元に戻す)
@MainActor
enum MonkeyRun {
    /// 操作 1 つ。prepare は、今の状態で行えなければ nil を返す
    struct Action {
        let name: String
        /// 選ばれやすさ (表の中での重み)
        var weight: Int = 1
        /// 何をするかを決める (乱数は、ここでだけ使う。状態は変えない)。足あとに書く文と、行う中身を返す
        let prepare: @MainActor (AppModel, inout SeededRandom) -> (trail: String, perform: @MainActor () async -> Void)?
    }

    /// 書き出しの文を書く、一時のフォルダ (終わりに消す)
    nonisolated static let exportFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("kikimimi-monkey-export-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    static let actions: [Action] = [
        // 1. 結果を選ぶ・選ぶのをやめる (横の一覧の選択が呼ぶ AppModel.select)
        Action(name: "select", weight: 4) { model, rng in
            let jobs = ordered(model.jobs)
            guard !jobs.isEmpty else { return nil }
            let job = rng.pick(jobs)
            return ("select \(show(job.name))", { model.select(job) })
        },
        Action(name: "deselect") { model, _ in
            guard model.selectedJob != nil else { return nil }
            return ("deselect", { model.select(nil) })
        },
        // 2. 表示を切り替える (結果の画面の「対訳」「時刻」、メモの欄、検索の欄)
        Action(name: "bilingual") { model, _ in
            guard let job = model.selectedJob else { return nil }
            let on = !model.showsBilingual(job)
            return ("bilingual \(on ? "on" : "off")", { model.setShowsBilingual(on, for: job) })
        },
        Action(name: "timestamps") { model, _ in
            let on = !model.showTimestamps
            return ("timestamps \(on ? "on" : "off")", { model.showTimestamps = on })
        },
        Action(name: "notes pane") { model, _ in
            let on = !model.showNotes
            return ("notes pane \(on ? "on" : "off")", { model.showNotes = on })
        },
        Action(name: "search") { model, rng in
            guard model.selectedJob != nil else { return nil }
            let text = rng.text(from: HostileValues.textFragments, pieces: 1...3)
            return ("search \(show(text))", { model.searchText = text })
        },
        Action(name: "clear search") { model, _ in
            guard !model.searchText.isEmpty else { return nil }
            return ("clear search", { model.searchText = "" })
        },
        // 3. 履歴のシート (メニューの「履歴…」と同じ決まりで出す)。版を残す・版を読む (「戻す」。壊れた版のファイルも在る)
        Action(name: "open history", weight: 2) { model, _ in
            guard model.historyJobID == nil, let job = model.selectedJob, job.inLibrary, job.status == .done else { return nil }
            return ("open history of \(show(job.name))", { model.historyJobID = job.id })
        },
        Action(name: "close history") { model, _ in
            guard model.historyJobID != nil else { return nil }
            return ("close history", { model.historyJobID = nil })
        },
        Action(name: "save version") { model, rng in
            guard let job = historyJob(model), model.canEditVersions(job) else { return nil }
            let label = rng.text(from: HostileValues.textFragments, pieces: 0...2)
            let mode: VersionSaveMode = job.versions.contains { $0.origin == .manual } && rng.int(0...1) == 0 ? .overwriteLatest : .new
            return ("save version \(show(label)) \(mode == .new ? "new" : "overwrite")", {
                await model.saveVersion(job, label: label, mode: mode)
            })
        },
        Action(name: "restore version", weight: 2) { model, rng in
            guard let job = historyJob(model), model.canEditVersions(job), !job.versions.isEmpty else { return nil }
            let version = rng.pick(job.versions)
            let part = rng.int(0...2)
            let transcript = part != 1, notes = part != 0
            return ("restore version \(show(version.label)) transcript \(transcript) notes \(notes)", {
                await model.restoreVersion(job, versionID: version.id, transcript: transcript, notes: notes)
            })
        },
        // 4. 行を直すシート (行の右クリックの「この行を直す…」)。変な文で保存する・やめる。直しを戻す
        Action(name: "open line edit", weight: 2) { model, rng in
            guard model.lineEdit == nil, let job = model.selectedJob, job.status == .done,
                  let segments = job.transcript?.segments, !segments.isEmpty else { return nil }
            let first = rng.int(0...(segments.count - 1))
            let ids = segments[first...min(first + rng.int(0...1), segments.count - 1)].map(\.id)
            return ("open line edit of row \(first) (\(ids.count) segment(s))", { model.requestLineEdit(ids, in: job) })
        },
        Action(name: "save line edit") { model, rng in
            guard let request = model.lineEdit, let job = model.jobs.first(where: { $0.id == request.jobID }) else { return nil }
            var texts: [UUID: String] = [:]
            for id in request.segmentIDs { texts[id] = rng.text(from: HostileValues.textFragments, pieces: 0...3) }
            // 画面の「保存」と同じ決まり: 空の入力欄が在る時は、保存しない (シートは出たまま)
            let empty = texts.values.contains { LineEdit.normalized($0).isEmpty }
            let shown = request.segmentIDs.map { show(texts[$0] ?? "") }.joined(separator: ", ")
            return ("save line edit \(shown)\(empty ? " (not saved: an empty field)" : "")", {
                guard !empty else { return }
                model.setLineTexts(texts, in: job)
                model.lineEdit = nil
            })
        },
        Action(name: "cancel line edit") { model, _ in
            guard model.lineEdit != nil else { return nil }
            return ("cancel line edit", { model.lineEdit = nil })
        },
        Action(name: "revert line edits") { model, rng in
            guard let job = model.selectedJob, job.status == .done, let edits = job.transcript?.lineEdits, !edits.isEmpty else { return nil }
            let edit = rng.pick(edits)
            return ("revert line edit of segment \(edit.segmentID.uuidString.prefix(8))", {
                model.revertLineEdits([edit.segmentID], in: job)
            })
        },
        // 5. 行をメモに引用する (行の右クリックの「メモに引用」)。メモに変な文を入れる
        Action(name: "quote to notes") { model, rng in
            guard let job = model.selectedJob, let segments = job.transcript?.segments, !segments.isEmpty else { return nil }
            let i = rng.int(0...(segments.count - 1))
            let segment = segments[i]
            return ("quote row \(i) to notes", { model.quoteToNotes(text: segment.text, time: segment.start, in: job) })
        },
        Action(name: "type notes") { model, rng in
            guard let job = model.selectedJob, job.transcript != nil else { return nil }
            let text = rng.text(from: HostileValues.textFragments, pieces: 0...4)
            let append = rng.int(0...1) == 0
            return ("\(append ? "append" : "replace") notes \(show(text))", {
                job.notes = append ? job.notes + text : text
            })
        },
        // 6. 書き出し: 文を作り、一時のフォルダへ書くだけ (ファイルを選ぶ画面は出さない)
        Action(name: "export") { model, rng in
            guard let job = model.selectedJob, job.status == .done, let transcript = job.transcript else { return nil }
            let format = rng.pick(ExportFormat.allCases)
            let content = rng.pick(ExportContent.available(for: format))
            return ("export \(format.rawValue) \(content.rawValue)", {
                let text = Exporter.render(transcript, as: format, content: content, target: model.translationTarget(for: transcript))
                try? text.write(to: exportFolder.appendingPathComponent("monkey.\(format.fileExtension)"),
                                atomically: true, encoding: .utf8)
            })
        },
        // 7. 再生 (下の再生ボタン・つまみ・行のクリック)。元の音声が /dev/zero・フォルダ・音声でない・無い結果も在る
        Action(name: "play or pause", weight: 2) { model, _ in
            guard model.player.url != nil else { return nil }
            return ("play or pause", { model.practice.togglePlay() })
        },
        Action(name: "seek") { model, rng in
            guard model.player.url != nil else { return nil }
            let seconds = rng.int(0...1) == 0 ? rng.pick(HostileValues.doubles)
                : Double(rng.int(0...1000)) / 1000 * max(model.player.duration, 1)
            return ("seek to \(seconds)", { model.player.seek(to: seconds) })
        },
        Action(name: "play line", weight: 2) { model, rng in
            guard let job = model.selectedJob, model.canPlayLines(of: job),
                  let segments = job.transcript?.segments, !segments.isEmpty else { return nil }
            let i = rng.int(0...(segments.count - 1))
            let id = segments[i].id
            return ("play line of row \(i)", { model.practice.toggleLine(id) })
        },
        Action(name: "stop") { model, _ in
            guard model.player.url != nil else { return nil }
            return ("stop", { model.practice.stop() })
        },
        // 8. 練習: 原文を隠す・書き取りの欄・前へ・次へ・もう一度 (メニューの「再生」と同じ決まり)
        Action(name: "hide") { model, rng in
            guard model.selectedJob != nil else { return nil }
            let hide = rng.pick(PracticeSettings.Hide.allCases)
            return ("hide \(hide.rawValue)", { model.practice.settings.hide = hide })
        },
        Action(name: "dictation pane") { model, _ in
            let on = !model.practice.showsDictation
            return ("dictation pane \(on ? "on" : "off")", { model.practice.showsDictation = on })
        },
        Action(name: "dictation") { model, rng in
            guard model.practice.showsDictation, model.selectedJob != nil else { return nil }
            let text = rng.text(from: HostileValues.textFragments, pieces: 0...3)
            return ("dictation \(show(text))", {
                model.practice.dictation.typed = text
                if model.practice.currentLineID != nil { model.practice.submitDictation() }
            })
        },
        Action(name: "next or previous line", weight: 2) { model, rng in
            guard let job = model.selectedJob, model.canPlayLines(of: job) else { return nil }
            let which = rng.int(0...2)
            return (["next line", "previous line", "replay line"][which], {
                switch which {
                case 0: model.practice.next()
                case 1: model.practice.previous()
                default: model.practice.replay()
                }
            })
        },
        // 9. 訳を直すシート (対訳の行の「訳を直す…」。訳の在る行だけ)
        Action(name: "open translation edit") { model, rng in
            guard model.translationEdit == nil, let job = model.selectedJob, job.status == .done,
                  let translated = job.transcript?.segments.filter({ $0.translation != nil }), !translated.isEmpty else { return nil }
            let segment = rng.pick(translated)
            return ("open translation edit of segment \(segment.id.uuidString.prefix(8))", {
                model.requestTranslationEdit(segment.id, in: job)
            })
        },
        Action(name: "save translation edit") { model, rng in
            guard let request = model.translationEdit, let job = model.jobs.first(where: { $0.id == request.jobID }) else { return nil }
            let text = rng.text(from: HostileValues.textFragments, pieces: 0...3)
            return ("save translation edit \(show(text))", {
                // 画面の「保存」と同じ: 空白だけの時は、置かずに閉じる
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.setTranslation(text, head: request.segmentID, in: job)
                }
                model.translationEdit = nil
            })
        },
        Action(name: "close translation edit") { model, _ in
            guard model.translationEdit != nil else { return nil }
            return ("close translation edit", { model.translationEdit = nil })
        },
        // 10. 画面の言語を、別の言語に替える (確認用の起動は、設定を書かない)
        Action(name: "ui language") { model, rng in
            let language = rng.pick(UILanguage.allCases.filter { $0 != model.uiLanguage })
            return ("ui language \(language.rawValue)", { model.uiLanguage = language })
        }
        // 操作を足す時は、ここに 1 つ足すだけ
    ]

    // MARK: 選ぶ時の決まった並び

    /// 結果を選ぶ時の並び: 題名の順 (同じ題名は、区間の数・作った日時の順)。読み込みの順や UUID に頼らない
    static func ordered(_ jobs: [Job]) -> [Job] {
        jobs.sorted { a, b in
            if a.name != b.name { return a.name < b.name }
            let ac = a.transcript?.segments.count ?? 0, bc = b.transcript?.segments.count ?? 0
            if ac != bc { return ac < bc }
            return a.createdAt < b.createdAt
        }
    }

    /// 履歴のシートを出している結果 (選んでいる結果と同じ時だけ。シートの中のボタンは、その結果に効く)
    static func historyJob(_ model: AppModel) -> Job? {
        guard let id = model.historyJobID, let job = model.jobs.first(where: { $0.id == id }) else { return nil }
        return job
    }

    /// 足あとに書く文: 40 文字までにし、改行・制御文字・向きを変える印などは `\u{…}` にする (足あとの 1 行を壊さない)
    static func show(_ text: String) -> String {
        let cut = text.count > 40 ? String(text.prefix(40)) : text
        var out = "\""
        for scalar in cut.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse:
                out += "\\u{\(String(scalar.value, radix: 16))}"
            default:
                if scalar == "\"" || scalar == "\\" { out += "\\" }
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return text.count > 40 ? out + "…(\(text.count) characters)" : out
    }

    // MARK: 起動

    /// 起動の前に呼ぶ。引数か環境変数が使えなければ、訳を出して終了コード 2 で終わる。使えれば、確認を予約して戻る
    nonisolated static func arm(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        func refuse(_ reason: String) -> Never {
            FileHandle.standardError.write(Data("MONKEY: not started: \(reason)\n".utf8))
            exit(2)
        }
        guard LaunchMode.handCheckLibraryPath(arguments: arguments) != nil else {
            refuse("set KIKIMIMI_LIBRARY_DIR to a temporary library folder (not the real library), and give no other --selftest- argument")
        }
        var seed: UInt64 = 1
        if let text = value(after: "--seed") {
            guard let parsed = UInt64(text) else { refuse("--seed needs a whole number from 0, not \"\(text)\"") }
            seed = parsed
        }
        var steps = 300
        if let text = value(after: "--steps") {
            guard let parsed = Int(text), parsed > 0, parsed <= 100_000 else { refuse("--steps needs a whole number from 1 to 100000, not \"\(text)\"") }
            steps = parsed
        }
        let log = MonkeyLog(reportPath: value(after: "--report"))
        let watch = MonkeyWatch()
        watch.start(log: log)
        Task { @MainActor in
            await run(seed: seed, steps: steps, log: log, watch: watch)
        }
    }

    private static func run(seed: UInt64, steps: Int, log: MonkeyLog, watch: MonkeyWatch) async {
        log.line("MONKEY: \(LaunchLog.versionLine), seed \(seed), steps \(steps)")
        watch.beginStep(0, "wait for the window and the library")
        // 1. メインの窓と、その中のモデルと、ライブラリの読み込みを待つ (60 秒まで)
        var found: AppModel?
        for _ in 0..<240 {
            if let model = AppDelegate.shared?.model, MainWindow.all().contains(where: { $0.isVisible }), model.libraryLoadFinished {
                found = model
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let model = found else {
            finish(log, "MONKEY FAILED: no main window or the library did not load in 60 s at step 0: wait", code: 10)
        }
        AppDelegate.shared?.keepRunningWithoutWindows = true
        try? FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        await MainRunLoopTurn.afterRedraw()
        noteNotice(model, log: log, step: 0)
        let count = model.jobs.count
        log.line("MONKEY: library loaded: \(count) result(s)")

        // 2. 操作を 1 つずつ。行う前に足あとを書き、行ったら描き終わるのを待って、いつも成り立つ事を見る
        var rng = SeededRandom(seed: seed)
        var done: [String: Int] = [:]
        let totalWeight = actions.reduce(0) { $0 + $1.weight }
        for step in 1...steps {
            var chosen: (action: Action, trail: String, perform: @MainActor () async -> Void)?
            for _ in 0..<60 {
                var pick = rng.int(0...(totalWeight - 1))
                var action = actions[0]
                for candidate in actions {
                    if pick < candidate.weight { action = candidate; break }
                    pick -= candidate.weight
                }
                if let prepared = action.prepare(model, &rng) {
                    chosen = (action, prepared.trail, prepared.perform)
                    break
                }
            }
            // 「時刻」の切り替えは、いつでも行える (60 回とも行えない操作を引いた時の代わり)
            let item = chosen ?? (actions[3], "timestamps \(model.showTimestamps ? "off" : "on")", { model.showTimestamps.toggle() })
            let trail = "step \(step) (seed \(seed)): \(item.trail)"
            log.line("MONKEY: " + trail)
            watch.beginStep(step, item.trail)
            await item.perform()
            await MainRunLoopTurn.afterRedraw()
            watch.endStep()
            done[item.action.name, default: 0] += 1
            noteNotice(model, log: log, step: step)
            if let broken = invariantProblem(model, count: count) {
                finish(log, "MONKEY FAILED: \(broken) at \(trail)", code: 10)
            }
        }
        let counts = actions.compactMap { action in done[action.name].map { "\(action.name) \($0)" } }.joined(separator: ", ")
        model.flushLibrary()
        finish(log, "MONKEY OK (seed \(seed), steps \(steps), \(counts))", code: 0)
    }

    /// 知らせの窓が出ていたら、文を足あとに書いてから消す (閉じる人が居ないので)
    private static func noteNotice(_ model: AppModel, log: MonkeyLog, step: Int) {
        guard let message = model.errorMessage else { return }
        log.line("MONKEY: step \(step) notice: \(show(message))")
        model.errorMessage = nil
    }

    /// いつも成り立つ事 (破れていれば、その訳)
    static func invariantProblem(_ model: AppModel, count: Int) -> String? {
        if !MainWindow.all().contains(where: { $0.isVisible }) { return "no visible main window" }
        if let id = model.selectedJobID, !model.jobs.contains(where: { $0.id == id }) {
            return "the selected result is not in the list"
        }
        if model.jobs.count != count { return "the list has \(model.jobs.count) results, not \(count)" }
        if Set(model.jobs.map(\.id)).count != model.jobs.count { return "the list has the same result twice" }
        // 選んだ結果の音声を、再生の係が開いている (選んでいなければ、何も開いていない)
        if model.player.url != model.selectedJob?.url {
            return "the player has \(model.player.url?.path ?? "nothing") open, not the selected result's audio"
        }
        if !(model.player.currentTime.isFinite && model.player.currentTime >= 0) {
            return "the playback position is \(model.player.currentTime)"
        }
        // 文字起こし・監査・翻訳・チャットは行わないので、作業中にならない
        if model.isBusy { return "the app is busy although no work was started" }
        // シートの相手は、一覧に在る結果
        for (name, id) in [("history", model.historyJobID), ("line edit", model.lineEdit?.jobID),
                           ("translation edit", model.translationEdit?.jobID)] {
            if let id, !model.jobs.contains(where: { $0.id == id }) { return "the \(name) sheet is for a result not in the list" }
        }
        // どの結果の時刻も、使える範囲の中で、終わりは始まりより前にならない (読み込む所で直し、直した後も崩れない)
        for job in model.jobs {
            guard let t = job.transcript else { continue }
            func bad(_ x: Double) -> Bool { !(x >= 0 && x <= TimeRange.maxSeconds) }
            if bad(t.duration) || bad(t.elapsed) { return "\(show(job.name)) has duration \(t.duration), elapsed \(t.elapsed)" }
            if let s = t.segments.first(where: { bad($0.start) || bad($0.end) || $0.end < $0.start }) {
                return "\(show(job.name)) has a segment \(s.start)-\(s.end)"
            }
        }
        return nil
    }

    /// 結果を書いて終わる (メインスレッドでも、見張りのスレッドからも呼ぶ)
    nonisolated static func finish(_ log: MonkeyLog, _ last: String, code: Int32) -> Never {
        // macOS が確認のあいだに本物の設定へ書いた物を元に戻す (合否・終了コードは変えない)。
        // 戻した鍵の行を先に書き、結果の行を最後にする (道具は、最後の MONKEY の行を読む)
        if let restored = SettingsWriter.putBackAfterSelfTest() {
            for line in SettingsSnapshot.reportLines(restored: restored) { log.line(line) }
        }
        log.line(last)
        try? FileManager.default.removeItem(at: exportFolder)
        LaunchLog.note("monkey self-test finished with code \(code)")
        exit(code)
    }
}

/// 足あとの書き手: 標準出力と、`--report` のファイルに、1 行ごとに書き出す (落ちても、そこまでの行が残る)。
/// メインスレッドと見張りのスレッドの両方から書くので、ロックで守る
final class MonkeyLog: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle?

    init(reportPath: String?) {
        if let reportPath {
            let path = (reportPath as NSString).expandingTildeInPath
            FileManager.default.createFile(atPath: path, contents: nil)
            file = FileHandle(forWritingAtPath: path)
        } else {
            file = nil
        }
    }

    func line(_ text: String) {
        let data = Data((text + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(data)
        file?.write(data)
        try? file?.synchronize()
    }
}

/// 止まった時の見張り: メインのキューで 0.25 秒ごとに時刻を置き、別のスレッドが 1 秒ごとに見る。
/// メインスレッドが 20 秒進まない、または 1 つの操作が 60 秒終わらない時は、別のスレッドから知らせて終わる (終了コード 3)
final class MonkeyWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBeat = DispatchTime.now().uptimeNanoseconds
    private var stepStarted: UInt64?
    private var step = 0
    private var trail = ""
    private var beat: DispatchSourceTimer?
    private var check: DispatchSourceTimer?

    static let mainLimit: UInt64 = 20_000_000_000
    static let stepLimit: UInt64 = 60_000_000_000

    func start(log: MonkeyLog) {
        let beat = DispatchSource.makeTimerSource(queue: .main)
        beat.schedule(deadline: .now(), repeating: 0.25)
        beat.setEventHandler { [weak self] in self?.touch() }
        beat.resume()
        self.beat = beat
        let check = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        check.schedule(deadline: .now() + 1, repeating: 1)
        check.setEventHandler { [weak self] in self?.look(log: log) }
        check.resume()
        self.check = check
    }

    private func touch() {
        lock.lock(); defer { lock.unlock() }
        lastBeat = DispatchTime.now().uptimeNanoseconds
    }

    func beginStep(_ number: Int, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        step = number
        trail = text
        stepStarted = DispatchTime.now().uptimeNanoseconds
    }

    func endStep() {
        lock.lock(); defer { lock.unlock() }
        stepStarted = nil
    }

    private func look(log: MonkeyLog) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let mainQuiet = now > lastBeat ? now - lastBeat : 0
        let stepTime = stepStarted.map { now > $0 ? now - $0 : 0 } ?? 0
        let where_ = "step \(step): \(trail)"
        lock.unlock()
        if mainQuiet > Self.mainLimit {
            MonkeyRun.finish(log, "MONKEY FAILED: stuck at \(where_) (the main thread did not move for \(mainQuiet / 1_000_000_000) s)", code: 3)
        }
        if stepTime > Self.stepLimit {
            MonkeyRun.finish(log, "MONKEY FAILED: stuck at \(where_) (the step did not finish in \(stepTime / 1_000_000_000) s)", code: 3)
        }
    }
}
