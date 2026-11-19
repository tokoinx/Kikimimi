import Foundation

/// 翻訳の手本 (LLM に見せる、依頼と答えの例)。訳す先の言語ごとに 1 組。
/// LLM への指示の材料なので、画面の言語では訳さない。
///
/// 小さなモデル (Qwen3.5 4B など) は指示だけだと訳文がほかの言語に流れることがあり、
/// 訳す先の言語の手本を 1 回見せると、その言語で答える (あいさつの行は特に流れやすいので、手本にも入れておく)。
/// 日本語のほかは、同じ英語の 3 行を訳したもの。英語へ訳す時だけ、日本語の 3 行を英語に訳した物にする
enum TranslationExamples {
    /// 手本の原文 (英語の 3 行)
    static let englishLines = [
        "Hi everyone, thanks for joining us today.",
        "Let's take a look at the results.",
        "It costs about 20 dollars.",
    ]

    /// 英語の 3 行の訳 (訳す先の言語ごと)。英語へ訳す時は、日本語の行 (ja) を原文にする
    static let translations: [String: [String]] = [
        "ja": [
            "みなさん、今日はお集まりいただきありがとうございます。",
            "では、結果を見てみましょう。",
            "費用は約 20 ドルです。",
        ],
        "zh": [
            "大家好，感谢大家今天的参与。",
            "我们来看看结果吧。",
            "费用大约是 20 美元。",
        ],
        "ko": [
            "여러분 안녕하세요, 오늘 함께해 주셔서 감사합니다.",
            "그럼 결과를 살펴보겠습니다.",
            "비용은 약 20달러입니다.",
        ],
        "es": [
            "Hola a todos, gracias por acompañarnos hoy.",
            "Veamos los resultados.",
            "Cuesta unos 20 dólares.",
        ],
        "fr": [
            "Bonjour à tous, merci d'être avec nous aujourd'hui.",
            "Jetons un œil aux résultats.",
            "Ça coûte environ 20 dollars.",
        ],
        "de": [
            "Hallo zusammen, danke, dass ihr heute dabei seid.",
            "Schauen wir uns die Ergebnisse an.",
            "Es kostet etwa 20 Dollar.",
        ],
        "it": [
            "Ciao a tutti, grazie per essere qui con noi oggi.",
            "Diamo un'occhiata ai risultati.",
            "Costa circa 20 dollari.",
        ],
        "pt": [
            "Oi, pessoal, obrigado por estarem com a gente hoje.",
            "Vamos dar uma olhada nos resultados.",
            "Custa cerca de 20 dólares.",
        ],
        "ru": [
            "Всем привет, спасибо, что присоединились к нам сегодня.",
            "Давайте посмотрим на результаты.",
            "Это стоит около 20 долларов.",
        ],
        "vi": [
            "Xin chào mọi người, cảm ơn các bạn đã tham gia cùng chúng tôi hôm nay.",
            "Chúng ta hãy cùng xem kết quả.",
            "Nó có giá khoảng 20 đô la.",
        ],
        "th": [
            "สวัสดีทุกคน ขอบคุณที่มาร่วมกับเราในวันนี้",
            "มาดูผลลัพธ์กันเลย",
            "ราคาประมาณ 20 ดอลลาร์",
        ],
        "id": [
            "Halo semuanya, terima kasih sudah bergabung bersama kami hari ini.",
            "Mari kita lihat hasilnya.",
            "Harganya sekitar 20 dolar.",
        ],
    ]

    /// 原文の行と訳の行を、依頼と答えの形にする (答えは、行ごとに改行で終わる)
    static func example(source: [String], translation: [String]) -> LLMExample {
        LLMExample(
            user: "Lines to translate:\n" + source.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n"),
            assistant: translation.enumerated().map { "[\($0.offset + 1)] \($0.element)\n" }.joined()
        )
    }

    /// 訳す先の言語の手本 (13 言語に無いコードは日本語の手本)
    static func examples(for target: String) -> [LLMExample] {
        let code = TranslationTarget.normalized(target)
        if code == "en" {
            return [example(source: translations["ja"] ?? [], translation: englishLines)]
        }
        return [example(source: englishLines, translation: translations[code] ?? translations["ja"] ?? [])]
    }
}
