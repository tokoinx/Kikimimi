import Foundation

/// 「日本語＋英語」(区切りごとに言語を判定して文字にする) の決まりごと。
///
/// 数値は、英語と日本語の朗読 (FLEURS) を交互に並べた 3.5 分の録音・切り替わりに間の無い録音・日本語の講演 3.5 分を、
/// large-v3-turbo (q5_0) と Silero VAD v6.2.0 で測って決めた (2026-11 の試作)。
/// 1 回目の試作で、1 区間 1 言語 (今の「日本語」) の誤り 25.2% が、区切りごとの判定で 12.0% になった。
public enum MixedLanguageRules {
    /// whisper.cpp の入力のサンプリング周波数
    public static let sampleRate = 16_000

    // MARK: 区切り (言語を判定する単位)

    /// 区切りの長さの上限 (whisper の言語判定は先頭の 30 秒だけを聞くので、それに収める)
    public static let maxChunkSeconds = 28.0
    /// 長すぎる区切りを分けるとき、両側に最低これだけ残す
    public static let minSideSeconds = 3.0
    /// 話者の切り替わりなどで切るとき、発話の端からこれ以上離れていなければ切らない (端の切れ端を作らない)
    public static let forcedCutMarginSeconds = 0.3
    /// VAD が無いときの区切りの長さ。区切りは前後 `fixedChunkSearchSeconds` の中でいちばん静かなところへずらす
    public static let fixedChunkSeconds = 25.0
    public static let fixedChunkSearchSeconds = 2.0

    // MARK: 判定を信じる条件

    /// これより短い発話は判定しない (0.5 秒の日本語は 13% が英語と判定された)
    public static let minDetectSpeechSeconds = 1.0
    /// 2 秒以上の発話は、確からしさ 0.90 以上で信じる (1.5〜28 秒の区切り 34 個は、すべて 0.99 以上で正しかった)
    public static let trustedSpeechSeconds = 2.0
    public static let trustedConfidence = 0.90
    /// 1〜2 秒の発話は 0.95 以上で信じる (1 秒の切り抜きでは、正しくても 0.79 まで下がった)
    public static let shortTrustedConfidence = 0.95
    /// 信じられない区切りは、前の区切りとの間がこれ未満なら前の言語に、そうでなければ次の言語に合わせる
    public static let borrowPreviousBelowPauseSeconds = 1.0
    /// これだけ話している区切りは、確からしさが低くても前後の言語を借りずに、判定のとおりにする
    /// (低いのは言語が混ざっているからで、多い側は聞き取れている。前の言語を借りると、9 割が英語の 26 秒を日本語で文字にした)
    public static let longChunkOwnGuessSeconds = 8.0
    /// 混ざっていて分けて判定し直した部分は、確からしさが低くても、発話がこれ以上あれば判定のとおりにする
    /// (低いのは言語が混ざっているからで、多い側の言語は聞き取れている。前後の言語を借りると、多い側をまるごと取り違える)
    public static let majorityMinSpeechSeconds = 2.0

    // MARK: 言語が混ざっていそうな区切り

    /// 発話がこれ以上あり、確からしさが `refineBelow` 未満の区切りは、分けて判定し直す
    /// (英語と日本語が半分ずつの区切りでも 0.954 と出た。1 つの言語の区切りは、本物の日本語の講演で 0.977 以上、
    /// 英語の朗読と JFK で 0.998 以上なので、0.97 未満なら混ざっているとみなす)
    public static let refineMinSpeechSeconds = 4.0
    public static let refineBelow = 0.97
    /// 区切りの中の長い間 (最大 2 か所) で分けるとき、それぞれの長さの下限
    public static let pieceMinSeconds = 2.0
    /// これ以上長く、確からしさが `bisectBelow` 未満の部分は、間の無い切り替わりを二分探索で探す。
    /// `bisectLongSeconds` 以上の部分は 4 秒の窓、それより短い部分は 2 秒の窓で探す
    /// (4.9 秒の部分を探さなかったため、英語の終わりの 1 秒を日本語で文字にして失った)
    public static let bisectMinSeconds = 4.0
    public static let bisectLongSeconds = 6.0
    public static let bisectBelow = 0.97
    /// 二分探索で聞く長さ・探索をやめる幅・回数の上限
    public static let bisectWindowSeconds = 4.0
    /// 両端の言語が同じとき、端に寄った切り替わりを探すために聞く、端の長さ (tiny でも 2 秒あれば {ja, en} は 100% 正しかった)
    public static let edgeWindowSeconds = 2.0
    public static let bisectStopSeconds = 1.5
    public static let bisectMaxSteps = 5
    /// 切り替わりの位置は、探索の幅の前後これだけの中で、VAD の発話らしさがいちばん低いところ
    public static let cutSearchMarginSeconds = 0.25
    /// 二分探索の窓の判定がこの確からしさ未満なら、その窓に両方の言語が入っている (切り替わりは窓の中)。
    /// 9 割が日本語の窓が英語 0.565 と出て、切り替わりを幅の外へ追い出し、日本語の 2 秒を失った
    public static let uncertainProbe = 0.8
    /// 分けて判定し直す回数の上限: (それまでの区切りの数 × 0.35 + 5) 回。超えても、確からしさが `trustedConfidence`
    /// 未満の区切り (そのままでは前後の言語を借りる区切り) は分けて判定し直す
    public static let refineBudgetPerChunk = 0.35
    public static let refineBudgetBase = 5.0
    public static let overBudgetRefineBelow = 0.90

    // MARK: 区切りの中ほどに挟まった、別の言語の短い発話 (島)

    /// 島を探す区切りの言語。英語の講義に挟まる日本語の一言は、英語で文字にすると訳されずに消えるので探す。
    /// 日本語の中の英語の語は、日本語のまま文字にしても残るので探さない (日本語だけの講演の時間と結果を変えない)
    public static let islandHosts: Set<String> = ["en"]
    /// 別の言語の確率が、そのファイルの (島を探す言語の) 区切りの中央値の 5 倍以上、かつ 0.002 以上の区切りで探す。
    /// 中央値が分かるまで (区切り 5 つ) は 0.005 以上。英語だけの区切りは 0.0000〜0.0014 (雑音入りでも)、
    /// 1〜3 秒の日本語の差し込みを含む 25 秒前後の区切りは 0.0036〜0.036 だった
    public static let islandMinimumOther = 0.002
    public static let islandMedianFactor = 5.0
    public static let islandDefaultOther = 0.005
    public static let islandMedianMinSamples = 5
    /// 半分にしていき、これ以下の長さになったら判定のとおりにする
    public static let islandMaxSeconds = 4.0
    /// 半分を詳しく見るのは、別の言語の確率がこれ以上のときだけ (区切りで探し始めるときは、そのファイルのしきい値も下回らないこと。
    /// 雑音の多い英語で、英語だけの半分を延々と調べないように)
    public static let islandFloor = 0.005
    /// 4 秒以下で、別の言語の確率がこれ以上なのに信じられない部分は、もう一度だけ分ける (両端にこれだけ残す)。
    /// 1.5 秒の相づちを含む 3.7 秒の部分は、日本語 0.14 だった (英語だけの部分は 0.001 以下)
    public static let islandTrimOther = 0.1
    public static let islandTrimEdgeSeconds = 0.5
    /// 島を探す判定の回数の上限: (それまでの区切りの数 × 16 + 10) 回。1 つの島を見つけるのに 8〜14 回かかるので、
    /// どの区切りにも相づちが挟まる録音でも探し続けられる。英語だけの区切りは、半分にした 2 回で止まる
    public static let islandBudgetPerChunk = 16.0
    public static let islandBudgetBase = 10.0
    /// 雑音と島を見分ける比: 島なら、別の言語は一部に集まっている。
    /// - 二分探索の後: 両端の窓のどちらかの別の言語の確率が、部分全体のこの倍未満のときだけ島を探す
    ///   (雑音で全体に広がっているなら、両端も全体と同じくらい。英語だけの雑音の多い 25 秒の区切りで、判定 45 回が 13 回になった)
    /// - 分けて判定し直す回数の上限を超えた区切り: 最初に半分にした 2 つが、この比より近い確率なら、それ以上探さない
    public static let islandContrast = 0.5

    // MARK: 文字にする単位

    /// 同じ言語の区切りをつないで 1 回で文字にする長さの上限 (whisper が使うメモリを抑える)
    public static let maxRunSeconds = 600.0

    // MARK: 文字にした結果の点検

    /// 4 文字の並びの重なりがこれ以上なら、繰り返し (正しい文は 0.08 以下、暴走は 0.28〜0.73)
    public static let repetitionThreshold = 0.20
    /// 1 区間の中の繰り返しをまとめて、これ以上縮んだら繰り返し (「彼は、」×55 は 32 分の 1)
    public static let shrinkThreshold = 2.0
    /// 平均の対数確率がこれ未満で、しかもファイル全体の中央値より `logProbBelowMedian` 以上低ければ、自信なし
    /// (正しい文は −0.18 以上、本物の日本語の講演は中央値 −0.155・最低 −0.382。訳のような別の言語の文や崩れた文は −0.44〜−1.63)
    public static let lowLogProb = -0.35
    public static let logProbBelowMedian = 0.25
    /// 自信の点検に使う区間のトークン数の下限
    public static let minTokensForLogProb = 6
    /// 文字の密度 (発話 1 秒あたりの文字数) を点検する区間の発話の長さの下限
    public static let densityMinSpeechSeconds = 4.0
    /// 中央値を数えるのに使う区間の発話の長さの下限と、中央値を使い始める区間の数
    public static let densityMedianMinSpeechSeconds = 3.0
    public static let densityMedianMinSamples = 10
    /// 日本語の文: 密度が中央値の 0.5 倍未満なら、話した分が抜けている (中央値が分かるまでは 6.0 文字/秒)
    public static let sparseRatio = 0.5
    public static let defaultJapaneseDensity = 6.0
    /// 英語の文: 中央値の 0.4 倍未満か 1.6 倍より多ければおかしい (中央値が分かるまでは 12 文字/秒)
    public static let lowLatinRatio = 0.4
    public static let highLatinRatio = 1.6
    public static let defaultLatinDensity = 12.0
    /// これだけの発話に、文字にした区間が 1 つも重ならなければ、抜けている (前後 `coverSlackSeconds` まで重なるとみなす)
    public static let uncoveredMinSpeechSeconds = 3.0
    public static let coverSlackSeconds = 0.3

    // MARK: 直し

    /// 点検で引っかかった区間どうしの間がこれ未満なら、まとめて直す
    public static let repairMergeGapSeconds = 1.0
    /// 直す範囲は、引っかかった区間の前後にこれだけ広げる
    public static let repairPadSeconds = 0.2
    /// 別の言語だと、この確からしさ以上で判定されたときだけ、その言語で文字にし直す
    /// (切り替わりも島も見つからない部分。二分探索の両端がそろっていれば、両端の判定も使う)
    public static let repairConfidence = 0.9
    /// 文字にし直した部分から何も出ず、元の文がその部分にこれ以上の発話の長さで重なっていたら、入れ替えない (文を消さない)
    public static let repairKeepOverlapSeconds = 0.5
    /// 文字にし直すのは、ファイルの発話の 1 割まで (時間がかかりすぎないように)。短いファイルでも 30 秒までは直せる。
    /// 判定し直しただけ (同じ言語だった) のところは数えない
    public static let repairSpeechShare = 0.10
    public static let repairMinimumSeconds = 30.0
    /// 直しで行う判定の回数の上限: (区切りの数 × 1 + 30) 回
    public static let repairDetectionsPerChunk = 1.0
    public static let repairDetectionsBase = 30.0

    // MARK: 進み具合

    /// VAD が終わった時点の進み具合
    public static let progressAfterVAD = 0.03
    /// 判定と文字にする作業の重み (残りは直し)
    public static let progressDetectShare = 0.4
    public static let progressDecodeShare = 0.6
    public static let progressRepairShare = 0.05

    static func samples(_ seconds: Double) -> Int { Int((seconds * Double(sampleRate)).rounded()) }
    static func seconds(_ samples: Int) -> Double { Double(samples) / Double(sampleRate) }
}
