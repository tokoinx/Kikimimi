// 日本語の表: KikimimiCore・KikimimiWhisper・KikimimiLLM の文 (鍵 = 英語、値 = 日本語)。
// 値は、英語の画面にする前の文と一字も変えない (日本語を選んだ時の画面が、前と同じになるように)
extension JA {
    static let core: [String: String] = languages.merging(catalog) { first, _ in first }
        .merging(audit) { first, _ in first }
        .merging(errors) { first, _ in first }

    /// 言語の名前・書き出し・書き取り・行の印
    private static let languages: [String: String] = [
        // Languages
        "Auto-detect": "自動判定",
        "Japanese + English": "日本語＋英語",
        "Japanese": "日本語",
        "English": "英語",
        "Chinese": "中国語",
        "Korean": "韓国語",
        "Spanish": "スペイン語",
        "French": "フランス語",
        "German": "ドイツ語",
        "Italian": "イタリア語",
        "Portuguese": "ポルトガル語",
        "Russian": "ロシア語",
        "Vietnamese": "ベトナム語",
        "Thai": "タイ語",
        "Indonesian": "インドネシア語",
        // Transcript.languageLabel (2 つ以上の言語をつなぐ)
        "%1$@ + %2$@": "%1$@＋%2$@",
        // LanguageTag
        "JA": "日",
        "EN": "英",
        // Exporter
        "Text (.txt)": "テキスト (.txt)",
        "Subtitles SRT (.srt)": "字幕 SRT (.srt)",
        "Subtitles WebVTT (.vtt)": "字幕 WebVTT (.vtt)",
        "Original": "原文",
        // %@ は訳した言語の名前 (日本語なら「日本語訳」「対訳 (原文 + 日本語)」で、これまでと同じ文になる)。
        // 「%@ translation」は、結果の画面の対訳の見出し (TranscriptDetailView) にも使う
        "%@ translation": "%@訳",
        "Bilingual (original + %@)": "対訳 (原文 + %@)",
        "Language: %@": "言語: %@",
        "Length: %@": "長さ: %@",
        "Model: %@": "モデル: %@",
        "Translation: %@": "翻訳: %@",
        "| Time | Original | %@ translation |": "| 時刻 | 原文 | %@訳 |",
        // DictationDisplay
        "All correct": "全部合っています",
        "%1$d / %2$d words": "%1$d / %2$d 語",
        "%1$d / %2$d characters": "%1$d / %2$d 字",
    ]

    /// モデルの名前と説明 (ModelCatalog・LLMCatalog)
    private static let catalog: [String: String] = [
        "Large v3 Turbo (light)": "Large v3 Turbo (軽量版)",
        "Best balance of Japanese accuracy and speed. Pick this if unsure.": "日本語の精度と速度のバランスが最も良い。迷ったらこれ。",
        "Slightly more accurate than the light version. For Macs with plenty of memory.": "軽量版より少しだけ高精度。メモリに余裕がある Mac 向け。",
        "Large v3 (light)": "Large v3 (軽量版)",
        "Top accuracy. Several times slower than Turbo.": "最高精度クラス。Turbo の数倍遅い。",
        "Medium (light)": "Medium (軽量版)",
        "Medium accuracy and speed.": "中くらいの精度と速度。",
        "Small (light)": "Small (軽量版)",
        "Fast, but less accurate for Japanese.": "速いが日本語の精度は控えめ。",
        "Base (light)": "Base (軽量版)",
        "Very fast. For testing.": "とても速い。動作確認向け。",
        "Smallest. Low accuracy.": "最小。精度は低い。",
        "Good balance for audit and translation. Pick this if unsure. Runs on Macs with 8 GB of memory.": "監査と翻訳のバランスが良い。迷ったらこれ。メモリ 8 GB の Mac でも動く。",
        "Qwen3.5 2B (light)": "Qwen3.5 2B (軽量)",
        "Fast and light. Less accurate than 4B.": "速くて軽い。精度は 4B より控えめ。",
        "Qwen3.5 9B (accurate)": "Qwen3.5 9B (高精度)",
        "Smartest, but slow. For Macs with 16 GB of memory or more.": "いちばん賢いが遅い。メモリ 16 GB 以上の Mac 向け。",
    ]

    /// 監査の理由 (Auditor・CorrectionLedger)
    private static let audit: [String: String] = [
        "Possibly a common misrecognition that tends to appear in silence or music": "無音や音楽のところで出やすい定番の誤認識の可能性",
        "Repeats the previous sentence (%@)": "直前と同じ文の繰り返し (%@)",
        "Repeats the previous sentence (%@). It may really have been said twice, so needs review": "直前と同じ文の繰り返し (%@)。本当にくり返して話した可能性もあるため要確認",
        "Nearly repeats the previous sentence (%@). It may be a rephrasing, so needs review": "直前とほぼ同じ文の繰り返し (%@)。言い直しの可能性もあるため要確認",
        "Repeats part of the previous sentence (%@). Needs review": "直前の文の一部の繰り返し (%@)。要確認",
        "a correction that changes a number": "数字が変わる直し",
        "a correction that adds or removes a negation": "否定の有無が変わる直し",
        "a correction that only adds or removes words": "語を足す・削るだけの直し",
        "a correction that removes many words": "語を大きく削る直し",
        "a correction that adds new kanji": "漢字が新しく入る直し",
        "Mishearing: “%1$@” → “%2$@”": "聞き取りミス: 「%1$@」→「%2$@」",
        "Mishearing: “%1$@” → “%2$@” (needs review: %3$@)": "聞き取りミス: 「%1$@」→「%2$@」 (%3$@のため要確認)",
        "Mishearing: “%1$@” → “%2$@” (needs review: the reviewers disagreed)": "聞き取りミス: 「%1$@」→「%2$@」 (評価役の判断が割れたため要確認)",
        "Mishearing: “%1$@” → “%2$@” (needs review: a large change)": "聞き取りミス: 「%1$@」→「%2$@」 (直す量が多いため要確認)",
        "Repetition (the same sentence is nearby. Needs review)": "繰り返し (近くに同じ文があります。要確認)",
        "Repetition (weak evidence, so needs review)": "繰り返し (裏付けが弱いため要確認)",
        "Possibly a sentence that was not actually said (the same sentence is nearby. Needs review)": "実際には話していない文の可能性 (近くに同じ文があります。要確認)",
        "Possibly a sentence that was not actually said (weak evidence, so needs review)": "実際には話していない文の可能性 (裏付けが弱いため要確認)",
        "%@ (You undid a correction on this line before. Needs review)": "%@ (この行では、前に直しを元に戻しています。要確認)",
        "“%1$@” → “%2$@”": "「%1$@」→「%2$@」",
        "%1$@, %2$@": "%1$@、%2$@",
        "Learned correction: %@": "学習した直し: %@",
        "Learned correction: %1$@ (needs review: %2$@)": "学習した直し: %1$@ (%2$@。要確認)",
        "Learned correction: %@ (applied once before. Apply it again and it will be fixed automatically from then on)": "学習した直し: %@ (前に 1 回反映した直し。もう一度反映すると、次から自動で直します)",
    ]

    /// エラーの文 (LLMError・WhisperError・DownloadError・ModelStore・LLMModelStore) と LlamaEngine の説明
    private static let errors: [String: String] = [
        "Could not load the LLM model: %@. The file may be damaged, or its format is not yet supported by this app’s llama.cpp. Delete it in Settings and download it again.": "LLM のモデルを読み込めませんでした: %@。ファイルが壊れているか、このアプリの llama.cpp がまだ対応していない形式です。設定から削除して取り直してください。",
        "Could not prepare the LLM’s working memory. There may not be enough memory. Close other apps, or choose a lighter model.": "LLM の作業領域を用意できませんでした。メモリが足りない可能性があります。ほかのアプリを閉じるか、軽いモデルを選んでください。",
        "The text for the LLM is too long (%1$d / %2$d tokens).": "LLM に渡す文が長すぎます (%1$d / %2$d トークン)。",
        "The LLM failed to compute (llama.cpp error %d).": "LLM の計算に失敗しました (llama.cpp エラー %d)。",
        "Could not prepare the LLM’s output format (grammar).": "LLM の出力の形式 (文法) を準備できませんでした。",
        "Canceled.": "中止しました。",
        "Could not load the fine-tuning adapter (LoRA): %@. Check that it was made from the same model as the selected LLM. If you remove the adapter in Settings, the original model is used.": "追加学習の差分 (LoRA) を読み込めませんでした: %@。選んでいる LLM と同じモデルから作った差分かを確かめてください。設定で差分を外すと、元のモデルで動きます。",
        "Could not load the model: %@. The file may be damaged. Delete it in Settings and download it again.": "モデルを読み込めませんでした: %@。ファイルが壊れている可能性があります。設定から削除して取り直してください。",
        "The audio is empty.": "音声が空です。",
        "Transcription failed (whisper.cpp error %d).": "文字起こしに失敗しました (whisper.cpp エラー %d)。",
        "Download failed (HTTP %d).": "ダウンロードに失敗しました (HTTP %d)。",
        "The downloaded file was not a model. Check your network settings (filters or proxies).": "ダウンロードしたファイルがモデルではありませんでした。ネットワークの設定 (フィルタやプロキシ) を確認してください。",
        "This is not a model file in whisper.cpp (ggml) format.": "whisper.cpp 形式 (ggml) のモデルファイルではありません。",
        "“%1$@” is not a name in the list. Choose a model with an official name such as ggml-large-v3-turbo-q5_0.bin, or %2$@ for silence detection.": "「%1$@」は一覧にない名前です。ggml-large-v3-turbo-q5_0.bin のような公式の名前のモデルか、無音検出用の %2$@ を選んでください。",
        "This is not an LLM in GGUF format. Choose a .gguf file that runs on llama.cpp.": "GGUF 形式の LLM ではありません。llama.cpp で動く .gguf ファイルを選んでください。",
        "This is a helper file for reading images (mmproj). Choose the main .gguf file.": "これは画像を読むための補助ファイル (mmproj) です。本体の .gguf を選んでください。",
        "This is not a GGUF fine-tuning adapter (LoRA). Choose the “….lora.gguf” file made by tools/finetune/finetune.py.": "追加学習の差分 (LoRA アダプタ) の GGUF ではありません。tools/finetune/finetune.py が作る「….lora.gguf」を選んでください。",
        "This adapter is for a different kind of model (adapter: %1$@, selected LLM: %2$@). Choose an adapter made from the selected LLM.": "この差分は別の種類のモデル用です (差分: %1$@、選んでいる LLM: %2$@)。選んでいる LLM から作った差分を選んでください。",
        "This is a fine-tuning adapter (LoRA), not an LLM. Choose it with “Add adapter…”.": "これは追加学習の差分 (LoRA アダプタ) です。LLM の本体ではないので、「差分を追加…」から選んでください。",
        "The file for %@ was not found at the source. You can also add it with “Add a local GGUF…” in the “Audit & translation” tab of Settings.": "%@ のファイルが配布元で見つかりませんでした。設定の「監査・翻訳」タブの「手元の GGUF を追加…」から取り込むこともできます。",
        "ChatML (thinking skipped)": "ChatML (思考を省く)",
        "The model’s own template": "モデル付属のテンプレート",
    ]
}
