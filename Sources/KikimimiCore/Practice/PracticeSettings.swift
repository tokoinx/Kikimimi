import Foundation

/// 英語の聞き取り練習の設定 (速さ・繰り返し・言ってみる間・自動で次へ・文字を隠す)。
///
/// 値は決めた候補の中から選ぶ。候補にない値は `normalized()` で近い候補に直す (作るときと読み込むときにも直す)。
/// 読み込みでは、ない項目や知らない値はその項目の決まりの値にする (古い版や壊れた保存でも開ける)。
/// 画面に出す名前はアプリの側で決める。
public struct PracticeSettings: Codable, Hashable, Sendable {
    /// 選べる速さ (1.0 がふつう)
    public static let rates: [Double] = [0.5, 0.6, 0.75, 0.85, 1.0, 1.25]
    /// 選べる繰り返しの回数。ほかに「止めるまで」(`untilStopped`) がある
    public static let repeatCounts: [Int] = [1, 2, 3, 5]
    /// 繰り返しの回数のうち「止めるまで」を表す値
    public static let untilStopped = 0
    /// 「行の長さだけ」の間のいちばん短い長さ (秒)
    public static let minGap: TimeInterval = 1.0
    /// 「行の長さだけ」の間のいちばん長い長さ (秒)
    public static let maxGap: TimeInterval = 15.0

    /// 1 回流すごとに入れる、声に出して言ってみるための間
    public enum Gap: String, Codable, CaseIterable, Hashable, Sendable {
        /// 間を入れない
        case off
        /// 行を流すのにかかった長さだけ (いまの速さで。1〜15 秒)
        case lineLength
    }

    /// 隠す文字
    public enum Hide: String, Codable, CaseIterable, Hashable, Sendable {
        /// 何も隠さない
        case nothing
        /// 原文を隠す
        case source
        /// 原文と訳を隠す
        case sourceAndTranslation
    }

    /// 流す速さ (`rates` のどれか)
    public var rate: Double
    /// 1 行を続けて流す回数 (`repeatCounts` のどれか。0 は止めるまで)
    public var repeatCount: Int
    /// 1 回流すごとの間
    public var gap: Gap
    /// 1 行の繰り返しと間が終わったら、次の行へ進む
    public var autoAdvance: Bool
    /// 隠す文字
    public var hide: Hide

    public init(rate: Double = 1.0, repeatCount: Int = 1, gap: Gap = .off, autoAdvance: Bool = false,
                hide: Hide = .nothing) {
        self.rate = Self.nearestRate(rate)
        self.repeatCount = Self.nearestRepeatCount(repeatCount)
        self.gap = gap
        self.autoAdvance = autoAdvance
        self.hide = hide
    }

    /// 速さと回数を、いちばん近い候補に直したもの
    public func normalized() -> PracticeSettings {
        var s = self
        s.rate = Self.nearestRate(rate)
        s.repeatCount = Self.nearestRepeatCount(repeatCount)
        return s
    }

    /// 止めるまで繰り返す
    public var repeatsUntilStopped: Bool { repeatCount == Self.untilStopped }

    /// いちばん近い速さの候補。真ん中のときは遅いほう。数でない値は 1.0
    public static func nearestRate(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        var best = rates[0]
        for r in rates where abs(r - value) < abs(best - value) - 1e-9 {
            best = r
        }
        return best
    }

    /// いちばん近い回数の候補。0 は止めるまでのまま。0 より小さいときは 1。真ん中のときは少ないほう
    public static func nearestRepeatCount(_ value: Int) -> Int {
        if value == untilStopped { return untilStopped }
        guard value > 0 else { return 1 }
        var best = repeatCounts[0]
        for c in repeatCounts where abs(c - value) < abs(best - value) {
            best = c
        }
        return best
    }

    /// 1 回流したあとの間 (秒)。lineDuration は行の長さ (ふつうの速さで)。間を入れないときは 0
    public func gapSeconds(lineDuration: TimeInterval) -> TimeInterval {
        switch gap {
        case .off: return 0
        case .lineLength: return Self.lineLengthGap(duration: lineDuration, rate: rate)
        }
    }

    /// 「行の長さだけ」の間 (秒): 行の長さを速さで割ったもの (遅くすると長くなる)。1〜15 秒に収める。
    /// 長さや速さが数でない・0 以下のときは、長さは 0、速さは 1.0 とみなす
    public static func lineLengthGap(duration: TimeInterval, rate: Double) -> TimeInterval {
        let d = duration.isFinite && duration > 0 ? duration : 0
        let r = rate.isFinite && rate > 0 ? rate : 1.0
        return min(maxGap, max(minGap, d / r))
    }

    // MARK: 保存と読み込み

    private enum CodingKeys: String, CodingKey {
        case rate
        case repeatCount
        case gap
        case autoAdvance
        case hide
    }

    /// ない項目・型の違う項目・知らない値は、その項目の決まりの値にする
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = PracticeSettings()
        let rate = (try? c.decodeIfPresent(Double.self, forKey: .rate)) ?? nil
        let count = (try? c.decodeIfPresent(Int.self, forKey: .repeatCount)) ?? nil
        let gap = (try? c.decodeIfPresent(String.self, forKey: .gap)) ?? nil
        let advance = (try? c.decodeIfPresent(Bool.self, forKey: .autoAdvance)) ?? nil
        let hide = (try? c.decodeIfPresent(String.self, forKey: .hide)) ?? nil
        self.init(rate: rate ?? base.rate, repeatCount: count ?? base.repeatCount,
                  gap: gap.flatMap(Gap.init(rawValue:)) ?? base.gap, autoAdvance: advance ?? base.autoAdvance,
                  hide: hide.flatMap(Hide.init(rawValue:)) ?? base.hide)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rate, forKey: .rate)
        try c.encode(repeatCount, forKey: .repeatCount)
        try c.encode(gap, forKey: .gap)
        try c.encode(autoAdvance, forKey: .autoAdvance)
        try c.encode(hide, forKey: .hide)
    }

    /// JSON の文字列にする (UserDefaults に入れる用)。項目は名前の順に並ぶ
    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// JSON の文字列から読む。nil や読めない文字列なら決まりの設定
    public static func load(jsonString: String?) -> PracticeSettings {
        guard let jsonString, let data = jsonString.data(using: .utf8),
              let settings = try? JSONDecoder().decode(PracticeSettings.self, from: data) else {
            return PracticeSettings()
        }
        return settings
    }
}
