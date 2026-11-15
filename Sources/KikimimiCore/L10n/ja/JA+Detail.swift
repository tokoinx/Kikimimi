// 日本語の表: 結果の画面 (TranscriptDetailView)。
// 鍵 = 英語、値 = 日本語。値は、英語の画面にする前の文と一字も変えない。
// JA+Core・JA+App にもう在る鍵 (Error・Canceled・Export・Transcribe again・Translating…・Original・Japanese translation) は足さない
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
        "Show the original and the Japanese translation side by side": "原文と日本語訳を左右に並べる",
        "Notes": "メモ",
        "Show a notes pane on the right (for what you understood, phrases to remember, and so on. What you write is saved automatically)": "右にメモの欄を出す (理解したこと・覚えたい表現などを書ける。書いたものは自動で保存される)",
        "Translate the rest": "残りを翻訳",
        "Translate": "翻訳",
        "Translate non-Japanese segments into Japanese with the LLM on your Mac": "日本語以外の区間を、Mac の中の LLM で日本語に訳す",
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
        "Translate only this sentence into Japanese": "この文だけ日本語に訳す",
        "%1$@. %2$@": "%1$@。%2$@",
        "Click to stop": "クリックで停止",
        "Click to play only this line": "クリックで、この行だけを再生",
        "Translating this sentence (or waiting to)": "この文を訳しています (順番待ちを含む)",
        "Translate line": "訳",
        // 対訳
        "Original (%@)": "原文（%@）",
        "Not translated": "未翻訳",
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
        // やり直す
        "Transcribe this audio again. The original result is kept": "この音声を、もう一度文字起こしします。元の結果は残ります",
        "Transcribe again with the same settings": "同じ設定でやり直す",
        "Transcribe again without skipping silence (for singing and music)": "無音を飛ばさずにやり直す (歌・音楽向け)",
        "Transcribe again in another language": "言語を変えてやり直す",
        "Try transcribing again": "もう一度文字起こしする",
        "Transcribe this audio again with the same settings. The original result is kept": "この音声を、同じ設定でもう一度文字起こしします。元の結果は残ります",
        // LLM の案内
        "The Japanese translation and the mishearing audit use an LLM that runs on your Mac": "日本語訳と聞き取りミスの監査には、Mac の中で動く LLM を使います",
        "The mishearing audit uses an LLM that runs on your Mac (for now, only repetitions are checked)": "聞き取りミスの監査には、Mac の中で動く LLM を使います (いまは繰り返しだけを見直しています)",
        "%1$@ (about %2$@) is downloaded only once. Your transcriptions never leave your Mac.": "%1$@ (約 %2$@) を一度だけダウンロードします。文字起こしの内容は Mac の外に出ません。",
        "Close (you can download it at any time in the “Audit & translation” tab of Settings)": "閉じる (設定の「監査・翻訳」タブから、いつでも取得できます)",
        "Download": "ダウンロード",
        "Choose in Settings…": "設定で選ぶ…",
        "Opens the “Audit & translation” tab of Settings. You can also choose the light 2B or the accurate 9B": "設定の「監査・翻訳」タブを開きます。軽い 2B や高精度の 9B も選べます",
    ]
}
