// 日本語の表: 結果の画面 (TranscriptDetailView)。
// 鍵 = 英語、値 = 日本語。値は、英語の画面にする前の文と一字も変えない。
// JA+Core・JA+App にもう在る鍵 (Error・Canceled・Export・Transcribe again・Translating…・Original・%@ translation・Cancel) は足さない
extension JA {
    static let detail: [String: String] = screen.merging(audit) { first, _ in first }
        .merging(notices) { first, _ in first }

    /// 見出し・操作の列・一覧・行・進み具合
    private static let screen: [String: String] = [
        // 見出しの数字
        "Length": "長さ",
        "Processing": "処理",
        "%.1f s": "%.1f 秒",
        "Speed": "速度",
        "%d×": "%d倍速",
        "%.1f×": "%.1f倍速",
        "Segments": "区間",
        // 操作の列
        "Search results": "結果を検索",
        "Timestamps": "時刻",
        "Bilingual": "対訳",
        // %@ (%1$@・%2$@) は、その結果の訳す先の言語の名前
        "Show the original and the %@ translation side by side": "原文と%@訳を左右に並べる",
        "Notes": "メモ",
        "Show a notes pane on the right (for what you understood, phrases to remember, and so on. What you write is saved automatically)": "右にメモの欄を出す (理解したこと・覚えたい表現などを書ける。書いたものは自動で保存される)",
        "Translate the rest": "残りを翻訳",
        "Translate": "翻訳",
        "Translate segments that are not in %1$@ into %2$@ with the LLM on your Mac": "%1$@以外の区間を、Mac の中の LLM で%2$@に訳す",
        "Copy": "コピー",
        // 一覧が空のとき
        "No matching segments": "一致する区間はありません",
        "Sentences appear here as they are recognized…": "認識した文から順にここへ出ます…",
        "No speech was detected. The audio may be silent, or the language setting may not match.": "言葉を検出できませんでした。無音か、言語の設定が合っていない可能性があります。",
        // 進み具合
        "Stop": "中止",
        // 行の印・行・行の右クリックのメニュー
        "A segment spoken in English": "英語で話している区間",
        "A segment spoken in Japanese": "日本語で話している区間",
        "To the end": "末尾へ",
        "Go to the end of the list and follow the transcription as it continues": "一覧の終わりへ移り、文字起こしの続きを追いかける",
        "Hidden line": "隠している行",
        "Stop playing this line": "この行の再生を止める",
        "Play only this line": "この行だけを再生",
        "Play from here": "ここから続けて再生",
        "Copy this line": "この行をコピー",
        "Quote in notes": "メモに引用",
        "Translate this sentence again": "この文を訳し直す",
        // 訳を直す (対訳の行の右クリック・「直した」の印・訳を直す画面)
        "Edit translation…": "訳を直す…",
        "Edit translation": "訳を直す",
        "Edited": "直した",
        "You edited this translation. Click to change it.": "この訳は、自分で直した訳です。押すと、直せます。",
        // 聞き取った文を直す (行の右クリック・原文の「直した」の印・行を直す画面)
        "Edit this line…": "この行を直す…",
        "Edit this line": "この行を直す",
        "Heard text": "聞き取った文",
        "Restore the heard text": "聞き取った文に戻す",
        "Saving removes this line’s translation. You can translate the line again.": "保存すると、この行の訳は消えます。この行は、訳し直せます。",
        "You edited this line. Heard text: %@": "この行は、自分で直しました。聞き取った文: %@",
        // 行を直す画面の「この直しを覚える」(学習した直しの台帳に、1 回分覚えさせる)
        "Remember this fix": "この直しを覚える",
        "From the next audit, the same mishearing gets this fix as a suggestion.": "次の監査から、同じ聞き間違いに、この直しを案として出します。",
        "Fill in both terms.": "2 つの語を、どちらも書いてください。",
        "The two terms are the same.": "2 つの語が同じです。",
        "The heard text does not contain the misheard term.": "聞き間違えた語が、聞き取った文に在りません。",
        "Your text does not contain the right term.": "正しい語が、直した文に在りません。",
        // 訳の記憶から置いた訳の印
        "Remembered": "覚えた訳",
        "This is your earlier translation of the same sentence. Click to change it.": "前に自分で直した、同じ文の訳です。押すと、直せます。",
        "Machine translation": "機械の訳",
        "Your translation": "自分の訳",
        "Restore machine translation": "機械の訳に戻す",
        "Remove your translation": "自分の訳を外す",
        // %@ は、その結果の訳す先の言語の名前
        "Translate only this sentence into %@": "この文だけ%@に訳す",
        "%1$@. %2$@": "%1$@。%2$@",
        "Click to stop": "クリックで停止",
        "Click to play only this line": "クリックで、この行だけを再生",
        "Translating this sentence (or waiting to)": "この文を訳しています (順番待ちを含む)",
        "Translate line": "訳",
        // 対訳
        "Original (%@)": "原文（%@）",
        "Not translated": "未翻訳",
        // 訳の関門の印 (「要確認」の印・訳を直す画面の理由・対訳の見出し)
        "Needs review": "要確認",
        "This translation may have a problem. Click to see why and check it.": "この訳は、気になる所があります。押すと、理由を見て確かめられます。",
        "This translation is fine": "この訳でよい",
        "%d needs review": "要確認 %d",
        "%d need review": "要確認 %d",
        "Go to the next translation that needs review": "次の要確認の訳へ移る",
        "The translation may not be in the target language.": "訳が、訳す先の言語でないようです。",
        "A number from the original is missing: %@": "原文の数が、訳にありません: %@",
        "Your term is not in the translation: %@": "決めた訳語が、訳にありません: %@",
        "The translation is the same as the original.": "訳が、原文と同じです。",
        "The same words repeat many times.": "同じ言葉が、何度も繰り返されています。",
        "The translation is much shorter than the original. Part of it may be missing.": "訳が、原文よりかなり短いです。一部が抜けているかもしれません。",
        "The translation used the wrong kind of letters, so it was not used.": "訳の文字の種類が違ったので、使いませんでした。",
        "The translation was far too long, so it was not used.": "訳が長すぎたので、使いませんでした。",
        "The model returned no translation for this line.": "この行の訳が、返ってきませんでした。",
        // 練習で隠した行
        "Hide this line": "この行を隠す",
        "Show this line": "この行を見る",
        // 書き出し・音声ファイル・再生
        "Notes (.md)": "メモ (.md)",
        "Audio file not found: %@": "音声ファイルが見つかりません: %@",
        "Choose the audio again…": "音声を選び直す…",
        "Play / pause (Space)": "再生 / 一時停止 (スペースキー)",
    ]

    /// 監査の印・監査の内容・監査の結果・監査と翻訳の順番
    private static let audit: [String: String] = [
        "Fixed": "修正済み",
        "Deleted": "削除済み",
        "Suggested fix": "修正の提案",
        "Suggested deletion": "削除の提案",
        "Mishearing fix": "聞き取りミスの修正",
        "Segment deletion": "区間の削除",
        "Found by: local LLM": "見つけた: ローカル LLM",
        "Found by: learned corrections": "見つけた: 学習した直し",
        "Found by: repetition rules": "見つけた: 繰り返しの規則",
        "Undo": "元に戻す",
        "Apply this fix": "この修正を反映",
        "Delete this segment": "この区間を消す",
        "See the audit results (fixes made and suggested fixes)": "監査の結果を見る (直した所・直す提案)",
        "Audit": "監査",
        "Check for repetitions and mishearings with the LLM on your Mac": "繰り返しと聞き取りミスを、Mac の中の LLM で見直す",
        "Check for repetitions (to also check for mishearings, download an LLM in Settings)": "繰り返しを見直す (聞き取りミスも見直すには、設定から LLM を取得)",
        "%d fix": "修正 %d",
        "%d fixes": "修正 %d",
        "%d deletion": "削除 %d",
        "%d deletions": "削除 %d",
        "%d suggestion": "提案 %d",
        "%d suggestions": "提案 %d",
        "Audit: no issues": "監査: 問題なし",
        "Audit: %@": "監査: %@",
        "Audit results": "監査の結果",
        "LLM: %@": "LLM: %@",
        "LLM: %@ (partial)": "LLM: %@ (途中まで)",
        "Rules only": "規則のみ",
        "Rules only (partial)": "規則のみ (途中まで)",
        "Only confident fixes are applied. Check each “suggestion” before you apply it. You can undo any of them at any time.": "自信のある直しだけを反映しています。「提案」は確かめてから反映してください。どれもいつでも元に戻せます。",
        "Fix": "修正",
        "Deletion": "削除",
        "Nothing to fix was found.": "直す所は見つかりませんでした。",
        "Undo all": "すべて元に戻す",
        "Audit again": "監査をやり直す",
        // 監査・翻訳の進み具合と順番
        "%1$@ (next: %2$@)": "%1$@（このあと: %2$@）",
        "Waiting: %@": "順番待ち: %@",
        "Translation": "翻訳",
        "Translation of the selected sentences": "選んだ文の翻訳",
        ", ": "・",
    ]

    /// 案内 (言語・無音・LLM)・やり直すのメニュー
    private static let notices: [String: String] = [
        // 日本語＋英語の案内
        "This recording has a lot of English. If Japanese and English take turns, you can transcribe it again with “Japanese + English”": "英語の多い録音でした。日本語と英語が入れ替わるなら、「日本語＋英語」で文字起こしし直せます",
        "It decides Japanese or English for each part and transcribes it in that language. Lines that broke with a single language may come out right. It takes about 2 to 4 times as long.": "区切りごとに日本語か英語かを判定し、その言語で文字にします。言語を 1 つに決めたときに崩れた行が直ることがあります。時間は 2〜4 倍ほどかかります。",
        "Transcribe again with Japanese + English": "日本語＋英語でやり直す",
        "Close (you can also choose the language in the language menu above or in Settings)": "閉じる (言語は、上の言語のメニューや設定でも選べます)",
        "Japanese and English were mixed, so it was transcribed with “Japanese + English”.": "日本語と英語が混ざっていたので、「日本語＋英語」で文字にしました。",
        "It decides Japanese or English for each part and transcribes it in that language. To stop switching automatically, change it in the “Transcription” tab of Settings.": "区切りごとに日本語か英語かを判定し、その言語で文字にしています。自動で切り替えないようにするには、設定の「文字起こし」で変えられます。",
        "Close": "閉じる",
        "Transcribe again without “Japanese + English”": "「日本語＋英語」を使わずにやり直す",
        "Transcribe again with only “%@”": "「%@」だけでやり直す",
        // 無音を飛ばさなかった案内
        "There was continuous sound but very little text, so it was transcribed without skipping silence (it seems to be singing or music).": "音が続いているのに文字が少なかったので、無音を飛ばさずに文字起こししました (歌や音楽のようです)。",
        "Transcribe again, skipping silence": "無音を飛ばしてやり直す",
        // 設定の訳す先と違う言語に訳してある結果の案内 (%1$@ はこの結果が訳した言語、%2$@ と %@ は設定の訳す先の言語)
        "This result is translated into %1$@. The language set to translate into is %2$@.": "この結果は%1$@に訳してあります。設定の訳す先は%2$@です。",
        "Translate again into %@…": "%@で訳し直す…",
        "Translate again into %@?": "%@で訳し直しますか？",
        "Translate again": "訳し直す",
        "The current %1$@ translation will be removed, and the result will be translated again into %2$@. The current state is kept as a version in the history.": "今の%1$@の訳を外し、%2$@に訳し直します。今の状態は、履歴に版として残ります。",
        // やり直す
        "Transcribe this audio again. The original result is kept": "この音声を、もう一度文字起こしします。元の結果は残ります",
        "Transcribe again with the same settings": "同じ設定でやり直す",
        "Transcribe again without skipping silence (for singing and music)": "無音を飛ばさずにやり直す (歌・音楽向け)",
        "Transcribe again in another language": "言語を変えてやり直す",
        "Try transcribing again": "もう一度文字起こしする",
        "Transcribe this audio again with the same settings. The original result is kept": "この音声を、同じ設定でもう一度文字起こしします。元の結果は残ります",
        // LLM の案内
        "The %@ translation and the mishearing audit use an LLM that runs on your Mac": "%@訳と聞き取りミスの監査には、Mac の中で動く LLM を使います",
        "The mishearing audit uses an LLM that runs on your Mac (for now, only repetitions are checked)": "聞き取りミスの監査には、Mac の中で動く LLM を使います (いまは繰り返しだけを見直しています)",
        "%1$@ (about %2$@) is downloaded only once. Your transcriptions never leave your Mac.": "%1$@ (約 %2$@) を一度だけダウンロードします。文字起こしの内容は Mac の外に出ません。",
        "Close (you can download it at any time in the “Audit & translation” tab of Settings)": "閉じる (設定の「監査・翻訳」タブから、いつでも取得できます)",
        "Download": "ダウンロード",
        "Choose in Settings…": "設定で選ぶ…",
        "Opens the “Audit & translation” tab of Settings. You can also choose the light 2B or the accurate 9B": "設定の「監査・翻訳」タブを開きます。軽い 2B や高精度の 9B も選べます",
    ]
}
