// 書き出しの所: ファイルへの書き出し・コピー・対訳の表示の切り替え。

import AppKit
import Foundation
import KikimimiCore
import UniformTypeIdentifiers

extension AppModel {
    // MARK: 書き出し
    func export(as format: ExportFormat, content: ExportContent = .original) {
        guard let job = selectedJob, let transcript = job.transcript else { return }
        let panel = NSSavePanel()
        let base = (job.name as NSString).deletingPathExtension
        // 訳・対訳は、その結果の訳す先の言語で書き出す (ファイルの名前の印も、その言語のコード)
        let target = translationTarget(for: transcript)
        panel.nameFieldStringValue = "\(base.isEmpty ? "transcript" : base)\(content.fileSuffix(target: target)).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporter.render(transcript, as: format, content: content, target: target)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = L("Could not save: %@", error.localizedDescription)
        }
    }

    /// メモを書き出す (.md。中身はメモの文そのまま)
    func exportNotes() {
        guard let job = selectedJob, !job.notes.isEmpty else { return }
        let panel = NSSavePanel()
        let base = (job.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base.isEmpty ? "notes" : base)-メモ.md" // l10n: keep (保存するファイルの名前)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try job.notes.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = L("Could not save: %@", error.localizedDescription)
        }
    }

    /// 対訳で表示しているか (対訳表示がオンか、そのジョブで行の「訳」を押した。そして、訳す先の言語以外が主な文字起こしか、
    /// 訳が 1 つでもある)。stats は、その結果の訳す先の言語で数えたもの (`translationStats(of:)`)
    func isBilingual(_ stats: Transcript.TranslationStats, in job: Job) -> Bool {
        showsBilingual(job) && (stats.hasTranslation || stats.isMainlyForeign)
    }

    /// 「対訳」のチェック (対訳の設定がオンか、そのジョブで行の「訳」を押した)
    func showsBilingual(_ job: Job) -> Bool {
        showBilingual || job.showsLineTranslations
    }

    /// 「対訳」のチェックを変える。外したときは、行の「訳」で出していたこのジョブの対訳も隠す
    func setShowsBilingual(_ on: Bool, for job: Job) {
        if !on { job.showsLineTranslations = false }
        if showBilingual != on { showBilingual = on }
    }

    /// 結果の行をクリックして再生できるか (その文字起こしの音声をプレイヤーが開いている)
    func canPlayLines(of job: Job) -> Bool {
        job.url != nil && player.url == job.url
    }

    /// 本文をコピーする。対訳表示のときは原文と訳を並べたもの
    func copySelectedText() {
        guard let job = selectedJob, let transcript = job.transcript else { return }
        let text: String
        let target = translationTarget(for: transcript)
        let stats = transcript.translationStats(target: target)
        if isBilingual(stats, in: job) && stats.hasTranslation {
            text = Exporter.txt(transcript, content: .bilingual, target: target)
        } else {
            text = transcript.text(withTimestamps: showTimestamps)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 1 行だけをコピーする (行の右クリックから。行のクリックは再生に使うので、行の文字は選べない)
    func copyLine(_ text: String, japanese: String?) {
        var lines = [text]
        if let japanese, japanese != text { lines.append(japanese) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
