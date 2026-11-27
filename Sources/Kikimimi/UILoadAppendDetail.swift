// 画面の重さの確認の、文字起こし中の結果に行を足す操作の内わけ (原因を調べるための測り。目安とは比べない):
// 足す操作 1 回ごとの行、一覧の終わりを追いかけていない時との比べ (参考の段)、実行機の 1 行。

import AppKit
import Foundation
import MachO

extension LoadRun {
    /// 内わけを取り始めた時の数 (一覧の行の数と、UILoadHooks の数)
    struct DetailMark {
        var rows: Int
        var inits: Int
        var bodies: Int
        var scrollToCalls: Int
        var scrollToNanos: UInt64
        var applyCalls: Int
        var applyNanos: UInt64
    }

    /// 内わけの行の読み方 (内わけの行の前に 1 回出す)
    static let appendDetailLegend = "append detail: per append in phase 4 (not compared with any limit): apply = time inside"
        + " AppModel.applyLive (append the segments and write job.transcript back); scrollTo = the CurrentLineTracker calls"
        + " to proxy.scrollTo during the action (time until each call returned); idle after = the action's time (from the"
        + " start of applying until the main thread is idle); turns = rounds of the idle wait (longest = the longest round);"
        + " row inits / row bodies = PlayableRow inits and bodies during the action"

    /// いまの数を覚える。applyDone なら、足すのはもう済んでいる (最後の 1 回を、この操作の分とする)。
    /// scrollTo のいちばん長い 1 回は、ここから数え直す
    func detailMark(applyDone: Bool = false) -> DetailMark {
        UILoadHooks.scrollToLongestNanos = 0
        var mark = DetailMark(rows: running.transcript?.segments.count ?? 0,
                              inits: UILoadHooks.rowsBuilt, bodies: UILoadHooks.rowBodies,
                              scrollToCalls: UILoadHooks.scrollToCalls, scrollToNanos: UILoadHooks.scrollToNanos,
                              applyCalls: UILoadHooks.applyCalls, applyNanos: UILoadHooks.applyNanos)
        if applyDone, mark.applyCalls > 0 {
            mark.applyCalls -= 1
            mark.applyNanos &-= UILoadHooks.lastApplyNanos
        }
        return mark
    }

    /// 内わけの 1 行 (mark から今までに増えた分)
    func detailLine(_ name: String, index: Int, of total: Int, rowsBefore: Int, since mark: DetailMark,
                    idle: UILoadSelfTest.IdleDetail) -> String {
        func f(_ seconds: Double) -> String { String(format: "%.1f", UILoadSelfTest.ms(seconds)) }
        func nanos(_ value: UInt64) -> Double { Double(value) / 1_000_000_000 }
        let rowsAfter = running.transcript?.segments.count ?? 0
        let applyCalls = UILoadHooks.applyCalls - mark.applyCalls
        let applySeconds = nanos(UILoadHooks.applyNanos &- mark.applyNanos)
        let batches = applyCalls == 1 ? "" : " in \(applyCalls) batches"
        let scrollCalls = UILoadHooks.scrollToCalls - mark.scrollToCalls
        let scrollSeconds = nanos(UILoadHooks.scrollToNanos &- mark.scrollToNanos)
        let longestScroll = scrollCalls > 0 ? nanos(UILoadHooks.scrollToLongestNanos) : 0
        return "UI LOAD: append detail \"\(name)\" \(index) of \(total): rows \(rowsBefore) -> \(rowsAfter),"
            + " apply \(f(applySeconds)) ms\(batches),"
            + " scrollTo calls \(scrollCalls) (total \(f(scrollSeconds)) ms, longest \(f(longestScroll)) ms),"
            + " idle after \(f(idle.seconds)) ms, turns \(idle.rounds) (longest \(f(idle.longestRound)) ms),"
            + " row inits \(UILoadHooks.rowsBuilt - mark.inits), row bodies \(UILoadHooks.rowBodies - mark.bodies)"
    }

    /// 参考の段: 同じ文字起こし中の結果で、追いかけるのをやめてから (絵 05 と同じ口)、300 行を 3 回足し、
    /// 「末尾へ」と同じ道 (追いかけるのを戻し、終わりの行へ動かす) で、また追いかける。
    /// 測る段階・絵・ほかの確認がすべて終わったあとに呼ぶ (このあとに確認は無い)。目安とは比べず、SLOW にも終了コードにも入れない
    func notFollowingRound() async -> [String] {
        func f(_ seconds: Double) -> String { String(format: "%.1f", UILoadSelfTest.ms(seconds)) }
        var lines = ["append detail (reference, not compared with any limit): the running job again, three bursts of 300"
                     + " after scrolling up and stopping following (as for screenshot 05), then following again as the"
                     + " To the end button does"]
        Self.live("reference: bursts while not following")
        player.stopLine()
        player.selfTestSetTime(0, playing: false)
        model.select(running)
        await settle()
        guard let setFollowing = UILoadHooks.setFollowing, let scrollList = UILoadHooks.scrollList,
              let isFollowing = UILoadHooks.isFollowing else {
            lines.append("UI LOAD: append detail: skipped (the list did not register its hooks)")
            return lines
        }
        let segments = running.transcript?.segments ?? []
        guard segments.count > 15 else {
            lines.append("UI LOAD: append detail: skipped (the running job has \(segments.count) rows)")
            return lines
        }
        // 一覧の終わりから、15 行ほど上へ動かし、追いかけるのをやめる (絵 05 と同じ)
        setFollowing(true)
        scrollList(segments[segments.count - 1].id, .bottom)
        await settle()
        scrollList(segments[segments.count - 15].id, .bottom)
        setFollowing(false)
        await settle()
        if isFollowing() {
            lines.append("UI LOAD: append detail: the list was still following the end before the bursts")
        }
        let first = appendDetails.count
        var notFollowing: [Double] = []
        for index in 1...3 {
            let timed = await timedBurst(300, detail: "burst (not following)", index: index, of: 3)
            notFollowing.append(timed.seconds)
            await UILoadSelfTest.sleep(1.0)
        }
        lines += appendDetails[first...]
        if isFollowing() {
            lines.append("UI LOAD: append detail: the list followed the end again during the bursts")
        }
        // また追いかける (「末尾へ」と同じ: 追いかけるのを戻し、終わりの行へ動かす)
        let added = (running.transcript?.segments.count ?? 0) - segments.count
        let rows = running.transcript?.segments.count ?? 0
        if let last = running.transcript?.segments.last?.id {
            let mark = detailMark()
            let started = UILoadSelfTest.now()
            setFollowing(true)
            let scrollStarted = UILoadSelfTest.now()
            scrollList(last, .bottom)
            let scrollTook = UILoadSelfTest.seconds(from: scrollStarted, to: UILoadSelfTest.now())
            let idle = await UILoadSelfTest.untilIdleDetail(since: started)
            let trackerCalls = UILoadHooks.scrollToCalls - mark.scrollToCalls
            lines.append("UI LOAD: append detail \"follow again after \(added) rows\": rows \(rows),"
                         + " To the end scrollTo \(f(scrollTook)) ms, tracker scrollTo calls \(trackerCalls),"
                         + " idle after \(f(idle.seconds)) ms, turns \(idle.rounds) (longest \(f(idle.longestRound)) ms),"
                         + " row inits \(UILoadHooks.rowsBuilt - mark.inits), row bodies \(UILoadHooks.rowBodies - mark.bodies)")
        }
        // 追いかけている時 (段階 4 の burst) と比べる 1 行
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard let worst = sorted.last else { return "no samples" }
            return "median \(f(UILoadSelfTest.percentile(sorted, 0.5))) ms (max \(f(worst)))"
        }
        lines.append("UI LOAD: burst idle after: following \(summary(measured[Action.burst] ?? [])),"
                     + " not following \(summary(notFollowing))")
        Self.live("reference: done")
        return lines
    }
}

extension UILoadSelfTest {
    /// 実行機の 1 行 (CI と手元を比べるため): macOS の版、コアの数、メモリ、画面の倍率、組み立てた SDK
    @MainActor
    static var environmentDetailLine: String {
        let info = ProcessInfo.processInfo
        let os = info.operatingSystemVersion
        var cores = "\(info.activeProcessorCount) cores"
        if info.processorCount != info.activeProcessorCount { cores += " (\(info.processorCount) in all)" }
        // Apple シリコンの、速いコアと省電力のコア (分からなければ出さない)
        if let fast = sysctlInt("hw.perflevel0.physicalcpu"), let slow = sysctlInt("hw.perflevel1.physicalcpu") {
            cores += " (performance \(fast), efficiency \(slow))"
        }
        let memory = String(format: "%.1f", Double(info.physicalMemory) / 1_073_741_824)
        let scales = NSScreen.screens.map { String(format: "%g", $0.backingScaleFactor) }
        let scale = scales.isEmpty ? "unknown" : scales.joined(separator: ", ")
        let model = sysctlString("hw.model") ?? "unknown"
        return "UI LOAD: environment: macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion),"
            + " \(cores), \(memory) GB, screen scale \(scale), built with SDK \(builtSDK ?? "unknown"),"
            + " model \(model), low power mode \(info.isLowPowerModeEnabled ? "on" : "off"),"
            + " thermal state \(thermal(info.thermalState))"
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    /// このアプリの実行ファイルに書かれた SDK の版 (LC_BUILD_VERSION。見つからなければ nil)
    private static var builtSDK: String? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        let count = Int(header.pointee.ncmds)
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<count {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_BUILD_VERSION) {
                let build = command.load(as: build_version_command.self)
                return version(build.sdk) + " (minimum macOS " + version(build.minos) + ")"
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }

    /// xxxx.yy.zz の形の数を、版の文字に
    private static func version(_ value: UInt32) -> String {
        "\(value >> 16).\((value >> 8) & 0xff).\(value & 0xff)"
    }
}
