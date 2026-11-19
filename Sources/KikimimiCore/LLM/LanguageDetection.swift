import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// 文の言語を決める係。言語のコード ("en"・"fr"・…。中国語は "zh") を返す。分からなければ nil。
/// 評価ハーネスで「訳が、本当に訳す先の言語か」を見るのに使う (試験では偽の係を渡す)
public typealias LanguageDetector = @Sendable (String) -> String?

#if canImport(NaturalLanguage)
/// Apple の NaturalLanguage (`NLLanguageRecognizer`) で言語を決める、既定の係。
/// `zh-Hans`・`zh-Hant` は "zh" にまとめる。ほかは NaturalLanguage のコードのまま返す
/// (13 言語は、どれも訳す先のコードと同じ。13 に無い言語は、そのコードのまま)
public enum SystemLanguageDetector {
    /// 判定の候補にする言語 (アプリの 13 言語。中国語は簡体字と繁体字)。
    /// 候補をしぼらないと、正しいロシア語の訳をカザフ語と判定するなど、近い言語へ外れる
    static let candidates: [NLLanguage] = [
        .english, .japanese, .simplifiedChinese, .traditionalChinese, .korean, .spanish, .french, .german,
        .italian, .portuguese, .russian, .vietnamese, .thai, .indonesian
    ]

    public static func detect(_ text: String) -> String? {
        // 呼ぶたびに作る (1 つの係を、いくつかのスレッドで使い回さないため)
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let code = language.rawValue
        if code.lowercased().hasPrefix("zh") { return "zh" }
        return code
    }

    public static let detector: LanguageDetector = { detect($0) }
}
#endif
