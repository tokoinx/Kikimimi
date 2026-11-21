// 画面の重さの確認の、ウインドウの絵 (--screenshots) を残す所。

import AppKit
import Foundation
import KikimimiCore

extension LoadRun {
    // MARK: ウインドウの絵 (--screenshots)

    /// 決まった場面を順に出し、それぞれ、メインスレッドが空いて絵が落ち着いてから、ウインドウの絵を PNG で残す。
    /// 測り終えたあとに呼ぶ (測る操作の中では撮らない)。出力の行を返す
    func takeScreenshots(into directory: URL) async -> [String] {
        var lines: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return ["UI LOAD: screenshot failed (all): could not create \(directory.path): \(error.localizedDescription)"]
        }
        guard let window = MainWindow.all().first(where: { $0.isVisible }) else {
            return ["UI LOAD: screenshot failed (all): no visible main window"]
        }
        // 絵の大きさ (左上の位置はそのまま)
        var frame = window.frame
        frame.origin.y += frame.height - 800
        frame.size = CGSize(width: 1200, height: 800)
        window.setFrame(frame, display: true)
        lines.append("screenshots: into \(directory.path), window \(Int(window.frame.width))x\(Int(window.frame.height)) pt")
        player.stopLine()
        player.selfTestSetTime(0, playing: false)

        // 1. 終わったジョブ (対訳)、一覧の始め
        Self.live("scene 01: select the finished bilingual job")
        model.select(doneBilingual)
        await settle()
        lines += await scroll(to: doneBilingual.transcript?.segments.first?.id, .top, for: "01")
        lines.append(shot("01-finished-bilingual", in: window, to: directory))

        // 2. 同じジョブで、見えている 4 行目を 1 行だけ再生しているところ (再生の色と止める印)。
        // 音声が無くても、playLine は行の印を付ける (音は出ない)
        if let segments = doneBilingual.transcript?.segments, segments.count > 3 {
            let segment = segments[3]
            Self.live("scene 02: one-line playback of row 4")
            player.playLine(id: segment.id, start: segment.start, end: segment.end)
            await settle()
            let playing = player.playingLineID == segment.id
            lines.append(shot("02-line-playing", in: window, to: directory))
            if !playing || player.playingLineID != segment.id {
                lines.append("UI LOAD: screenshot 02-line-playing.png: the row was not in one-line playback for the whole"
                             + " picture (it may show no playing tint)")
            }
            player.stopLine()
        } else {
            lines.append("UI LOAD: screenshot failed 02-line-playing.png: the job has fewer than 4 rows")
        }
        player.selfTestSetTime(0, playing: false)

        // 3. 終わったジョブ (日本語だけ)
        Self.live("scene 03: select the finished plain job")
        model.select(donePlain)
        await settle()
        lines += await scroll(to: donePlain.transcript?.segments.first?.id, .top, for: "03")
        lines.append(shot("03-finished-plain", in: window, to: directory))

        // 4. 文字起こし中のジョブ、一覧の終わり (進み具合と、出てきた行)
        Self.live("scene 04: select the running job")
        model.select(running)
        await settle()
        UILoadHooks.setFollowing?(true)
        lines += await scroll(to: running.transcript?.segments.last?.id, .bottom, for: "04")
        lines.append(shot("04-running-job", in: window, to: directory))

        // 5. 同じジョブで、追いかけるのをやめ、15 行ほど上へ動かしたところ (右下の「末尾へ」)
        let segments = running.transcript?.segments ?? []
        Self.live("scene 05: scroll up and stop following")
        lines += await scroll(to: segments.isEmpty ? nil : segments[max(0, segments.count - 15)].id, .bottom, for: "05")
        UILoadHooks.setFollowing?(false)
        await settle()
        if UILoadHooks.isFollowing?() ?? true {
            lines.append("UI LOAD: screenshot 05-running-scrolled-up.png: the list was still following the end"
                         + " (the 末尾へ button may be missing)")
        }
        lines.append(shot("05-running-scrolled-up", in: window, to: directory))
        UILoadHooks.setFollowing?(true)

        // 6. 日本語と英語が混ざっていたので、自動で「日本語＋英語」にした終わったジョブ (案内と「…だけでやり直す」)。
        // AppModel.run が、言語を確かめて混ざっていたときに入れるものと同じものを入れる。訳の無い英語の行には「訳」が出る
        let mixed = Job(name: "日本語と英語が混ざった録音 (確認用)", url: doneBilingual.url)
        let mixedRows = 60
        mixed.transcript = Transcript(sourceName: mixed.name, segments: UILoadSelfTest.makeSegments(0..<mixedRows),
                                      language: "ja", duration: Double(mixedRows) * UILoadSelfTest.rowSpacing, elapsed: 1)
        mixed.status = .done
        mixed.progress = 1
        mixed.message = "完了"
        mixed.autoMixedFrom = "ja"
        mixed.languageCode = Languages.japaneseEnglish.code
        Self.live("scene 06: select the automatically switched job")
        model.adopt(mixed)
        model.select(mixed)
        await settle()
        lines += await scroll(to: mixed.transcript?.segments.first?.id, .top, for: "06")
        lines.append(shot("06-auto-mixed-notice", in: window, to: directory))
        return lines
    }

    /// メインスレッドが空くのを待ち、0.4 秒おいて (絵が落ち着くまで)、また空くのを待つ
    func settle() async {
        _ = await UILoadSelfTest.untilIdle(since: UILoadSelfTest.now())
        await UILoadSelfTest.sleep(0.4)
        _ = await UILoadSelfTest.untilIdle(since: UILoadSelfTest.now())
    }

    /// 一覧を、その行が端に来るように動かし、落ち着くまで待つ。動かせなければ、そのことを出力の行で返す
    func scroll(to id: UUID?, _ edge: UILoadHooks.Edge, for name: String) async -> [String] {
        guard let id else { return ["UI LOAD: screenshot \(name): could not scroll the list (no rows)"] }
        guard let scrollList = UILoadHooks.scrollList else {
            return ["UI LOAD: screenshot \(name): could not scroll the list (the list did not register its scroll hook)"]
        }
        Self.live("  scroll for \(name)")
        scrollList(id, edge)
        await settle()
        Self.live("  scrolled for \(name)")
        return []
    }

    /// ウインドウの絵を PNG で残し、出力の行を返す。タイトルバーとツールバーも入るよう、内容の外側 (枠の view) から撮り、
    /// 撮れなければ内容の view から撮る
    func shot(_ name: String, in window: NSWindow, to directory: URL) -> String {
        let file = name + ".png"
        Self.live("  draw \(file)")
        defer { Self.live("  drew \(file)") }
        var picture: (data: Data, width: Int, height: Int)?
        var what = ""
        if let frameView = window.contentView?.superview, let p = Self.png(of: frameView) {
            picture = p
            what = "window frame"
        } else if let content = window.contentView, let p = Self.png(of: content) {
            picture = p
            what = "content view"
        }
        guard let picture else {
            return "UI LOAD: screenshot failed \(file): the view could not be drawn into a PNG"
        }
        do {
            try picture.data.write(to: directory.appendingPathComponent(file))
        } catch {
            return "UI LOAD: screenshot failed \(file): \(error.localizedDescription)"
        }
        return "UI LOAD: screenshot \(file) \(picture.width)x\(picture.height) (\(what))"
    }

    /// いま何をしているかを、その場で標準エラーへ書く (結果の行は終わりにまとめて出るので、途中で止まったときに
    /// どこで止まったかが分かるように)
    static func live(_ text: String) {
        FileHandle.standardError.write(Data(("UI LOAD (live): " + text + "\n").utf8))
    }

    /// view を描いた PNG と、その画素の幅と高さ (描けなければ nil)
    private static func png(of view: NSView) -> (data: Data, width: Int, height: Int)? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, rep.pixelsWide, rep.pixelsHigh)
    }
}
