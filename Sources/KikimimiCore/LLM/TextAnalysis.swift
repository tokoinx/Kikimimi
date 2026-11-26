import Foundation

/// 2 つの文がどれくらい似ているか。
public enum TextSimilarity {
    /// 比較用のキー (互換文字をそろえ、小文字にし、句読点・記号・空白を除く)
    public static func key(_ text: String) -> String {
        RepetitionFilter.key(text)
    }

    /// 編集距離 (文字単位のレーベンシュタイン距離)
    public static func distance(_ a: String, _ b: String) -> Int {
        distance(Array(a), Array(b))
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 0...1 の似ている度合い (1 = 同じ)。比較用キーどうしで測る
    public static func ratio(_ a: String, _ b: String) -> Double {
        let ka = Array(key(a)), kb = Array(key(b))
        let longest = max(ka.count, kb.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(distance(ka, kb)) / Double(longest)
    }

    /// ほぼ同じ文か。数字 (一・二… を含む) が違えば別の文とみなす (「手順 1」「手順 2」のような列挙を消さない)
    public static func isNearDuplicate(_ a: String, _ b: String, minimumRatio: Double) -> Bool {
        let ka = key(a), kb = key(b)
        guard ka.filter(\.isNumber) == kb.filter(\.isNumber) else { return false }
        return ratio(ka, kb) >= minimumRatio
    }
}

/// 文がどの言語の文字で書かれているか (翻訳が要るかの判定用)。
public enum Script {
    /// CharacterSet.letters は呼ぶたびに作り直されて遅いので、1 回だけ作る
    private static let letters = CharacterSet.letters

    /// 中国語の仲間の言語コード (Whisper は広東語を "yue" と返す)
    static func isChineseFamily(_ code: String?) -> Bool {
        guard let code = code?.lowercased() else { return false }
        return code.hasPrefix("zh") || code.hasPrefix("yue")
    }

    private static func isKana(_ v: UInt32) -> Bool {
        (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF66...0xFF9F).contains(v)
    }

    private static func isHan(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
            || v == 0x3005 // 々
    }

    /// 日本語の文か。かなを含むか、漢字だけで書かれていて (英字なし) 文字起こしの言語が中国語でなければ日本語とみなす。
    public static func isJapanese(_ text: String, transcriptLanguage: String? = nil) -> Bool {
        var han = 0, otherLetters = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if isKana(v) {
                return true
            } else if isHan(v) {
                han += 1
            } else if letters.contains(scalar) {
                otherLetters += 1
            }
        }
        if han > 0 && otherLetters == 0 {
            return !isChineseFamily(transcriptLanguage)
        }
        return false
    }

    /// 日本語の文には出てこない文字を含むか: cp932 に無い漢字 (们・这・欢 など簡体字の多く) と、中国語の読点「，」
    public static func containsNonJapaneseHan(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0xFF0C { return true }
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v), !JapaneseKanji.set.contains(scalar) {
                return true
            }
        }
        return false
    }

    /// 文字 (数字・記号以外) を含むか
    public static func hasLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { letters.contains($0) }
    }

    /// 漢字を含むか
    static func hasHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { isHan($0.value) }
    }

    /// 語を空白で区切らない文字か (漢字・かな・日本語や中国語の句読点・全角の文字)
    public static func isUnspacedCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return isHan(v) || isKana(v) || (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    /// 語の間に空白を書かない、東南アジアの文字か (タイ・ラオ・ビルマ・クメール。字につく印も含む)。
    /// これらの文字の語の切れ目は、字の続きでは分からないので、OS の語の分け方で見る (`Auditor.applyFix`)
    public static func isUnspacedSoutheastAsian(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x0E00...0x0EFF).contains(v)       // タイ・ラオ
            || (0x1000...0x109F).contains(v)       // ビルマ
            || (0xA9E0...0xA9FF).contains(v) || (0xAA60...0xAA7F).contains(v) // ビルマの足りない字
            || (0x1780...0x17FF).contains(v) || (0x19E0...0x19FF).contains(v) // クメール
    }

    /// 日本語に訳す必要があるか (日本語ではなく、文字を含む)
    public static func needsTranslation(_ text: String, transcriptLanguage: String? = nil) -> Bool {
        hasLetters(text) && !isJapanese(text, transcriptLanguage: transcriptLanguage)
    }

    /// 訳す必要がある区間か (訳す先 target の言語でなく、文字を含む)。翻訳の区間の決め方は、すべてここを通る。
    /// - target が日本語: これまでの決め方そのまま。区間の言語が日本語 (「日本語＋英語」で日本語とわかっている区間) なら、
    ///   かなが無くても (「Ruth先生」など) 訳さない。ほかは文字の種類で見る (`needsTranslation(_:transcriptLanguage:)`)。
    /// - ほかの target: 文字が無ければ訳さない。言語 (区間の言語、無ければ文字起こし全体の言語) が分かれば、
    ///   それが target と同じ時だけ訳さない。言語が分からなければ訳す (指示文に「もうその言語の行は、そのまま写す」と書いてある)
    public static func needsTranslation(_ text: String, segmentLanguage: String?, transcriptLanguage: String?,
                                        target: String) -> Bool {
        if target == "ja" {
            return segmentLanguage != "ja"
                && needsTranslation(text, transcriptLanguage: segmentLanguage ?? transcriptLanguage)
        }
        guard hasLetters(text) else { return false }
        guard let language = segmentLanguage ?? transcriptLanguage else { return true }
        return language.lowercased() != target.lowercased()
    }

    /// かなを含むか
    public static func hasKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { isKana($0.value) }
    }

    /// かなの範囲に在るが、かなの文字ではない記号 (中黒「・」と長音「ー」、その半角)
    private static let kanaMarks: Set<UInt32> = [0x30FB, 0x30FC, 0xFF65, 0xFF70]

    /// かなの文字を含むか (中黒「・」と長音「ー」は数えない。中国語の訳でも、名前の区切りとして原文から写される事がある)
    public static func hasKanaLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { isKana($0.value) && !kanaMarks.contains($0.value) }
    }

    /// その言語の文字を含むか (ko: ハングル、ru: キリル文字、th: タイ文字。ほかの言語は、いつも false)。訳の検査に使う
    static func hasLetters(_ text: String, of language: String) -> Bool {
        let ranges: [ClosedRange<UInt32>]
        switch language {
        case "ko": ranges = [0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F]
        case "ru": ranges = [0x0400...0x052F]
        case "th": ranges = [0x0E00...0x0E7F]
        default: return false
        }
        return text.unicodeScalars.contains { s in ranges.contains { $0.contains(s.value) } }
    }

    private static func isBasicLatin(_ v: UInt32) -> Bool {
        (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }

    /// 文の文字から、candidates のうちどの言語で話されたものかを決める (「日本語＋英語」の区間の言語)。
    /// かなを含めば日本語、漢字だけ (英字なし) なら日本語、英字だけ (かな・漢字なし) なら英語。
    /// 文字が無い・英字と漢字が混ざるなど、文字から決められなければ fallback (文字にしたときに指定した言語)。
    /// large-v3 系は、英語の音声を日本語の指定で文字にしても英語の文を返すことがあるので、指定した言語より文字を信じる
    public static func spokenLanguage(of text: String, among candidates: [String], fallback: String) -> String {
        var han = 0, latin = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if isKana(v) {
                return candidates.contains("ja") ? "ja" : fallback
            } else if isHan(v) {
                han += 1
            } else if isBasicLatin(v) {
                latin += 1
            }
        }
        if han > 0 && latin == 0 { return candidates.contains("ja") ? "ja" : fallback }
        if latin > 0 && han == 0 { return candidates.contains("en") ? "en" : fallback }
        return fallback
    }

    /// プロンプトに書く、いくつかの言語の名前 (英語)。例: ["en", "ja"] → "English and Japanese"
    public static func englishNames(_ codes: [String]) -> String {
        let names = codes.map { $0.lowercased() == "ja" ? "Japanese" : englishName(for: $0) }
        switch names.count {
        case 0: return englishName(for: nil)
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    /// プロンプトに書く言語名 (英語)。ja は「the original language」のまま (監査の指示文が、前と同じ文になるように。
    /// 翻訳の指示文で原文の言語の名前が要る時は、`Translator.sourceLanguageName(for:)` が ja を "Japanese" にする)
    public static func englishName(for code: String?) -> String {
        switch code?.lowercased() {
        case "en": return "English"
        case "zh": return "Chinese"
        case "yue": return "Cantonese"
        case "ko": return "Korean"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "ru": return "Russian"
        case "vi": return "Vietnamese"
        case "th": return "Thai"
        case "id": return "Indonesian"
        default: return "the original language"
        }
    }
}
