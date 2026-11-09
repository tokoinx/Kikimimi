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
    private static func isKana(_ v: UInt32) -> Bool {
        (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF66...0xFF9F).contains(v)
    }

    private static func isHan(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
            || v == 0x3005 // 々
    }

    /// 日本語の文か。かなを含むか、漢字だけで書かれていて (英字なし) 文字起こしの言語が中国語でなければ日本語とみなす。
    public static func isJapanese(_ text: String, transcriptLanguage: String? = nil) -> Bool {
        var kana = 0, han = 0, otherLetters = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if isKana(v) {
                kana += 1
            } else if isHan(v) {
                han += 1
            } else if CharacterSet.letters.contains(scalar) {
                otherLetters += 1
            }
        }
        if kana > 0 { return true }
        if han > 0 && otherLetters == 0 {
            return !(transcriptLanguage?.hasPrefix("zh") ?? false)
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
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// 日本語に訳す必要があるか (日本語ではなく、文字を含む)
    public static func needsTranslation(_ text: String, transcriptLanguage: String? = nil) -> Bool {
        hasLetters(text) && !isJapanese(text, transcriptLanguage: transcriptLanguage)
    }

    /// プロンプトに書く言語名 (英語)
    public static func englishName(for code: String?) -> String {
        switch code?.lowercased() {
        case "en": return "English"
        case "zh": return "Chinese"
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
