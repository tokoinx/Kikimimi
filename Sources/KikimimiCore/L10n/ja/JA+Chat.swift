// 日本語の表: LLM とのチャット (KikimimiCore/Chat) の文 (鍵 = 英語、値 = 日本語)
extension JA {
    static let chat: [String: String] = [
        // 札: 変えられない時の理由 (KikimimiCore/Chat/ChatSettings.swift の SettingUnavailableReason)
        "Turn on “%@” first.": "先に「%@」をオンにしてください。",
        "No adapter is added. Add one in Settings first.": "差分が入っていません。先に設定で差分を追加してください。",
        // ChatSettingItem.displayValue (入り切りの値)
        "On": "オン",
        "Off": "オフ",
        // ChatError
        "Your message is too long. Shorten it and send it again.": "発言が長すぎます。短くして、もう一度送ってください。",
        // チャットの窓 (Kikimimi/Views/ChatView.swift)
        "Chat": "チャット",
        "Chat with the LLM": "LLM とチャット",
        "New chat": "新しいチャット",
        "Research (reading web pages) is off. Turn it on only when you need it, at your own risk.": "リサーチ (Web ページを読む事) は、基本的に使えません (切)。必要な時だけ、自己責任で入れてください。",
        "Research is on, at your own risk. You are responsible for any breakage or damage caused by Prompt Injection.": "リサーチが入っています (自己責任)。Prompt Injection による破損や損害は、自己責任でお願いします。",
        "Turn on…": "入れる…",
        "Turn off": "切る",
        "Turn on research at your own risk?": "自己責任で、リサーチを入れますか？",
        "With research on, the chat reads the web pages whose URLs you write. A web page can contain hidden instructions (Prompt Injection) that make the LLM give wrong answers or propose changes you did not ask for. You are responsible for any breakage or damage caused by Prompt Injection.": "リサーチを入れると、あなたが書いた URL の Web ページを読みます。Web ページには、LLM にまちがった答えや、頼んでいない変更の案を出させる、隠れた指示 (Prompt Injection) が入っている事があります。Prompt Injection による破損や損害は、自己責任でお願いします。",
        "Research turns off again every time you open the app.": "リサーチは、アプリを開くたびに切に戻ります。",
        "Turn on at my own risk": "自己責任で入れる",
        "The chat uses an LLM that runs on your Mac": "チャットは、この Mac で動く LLM を使います",
        "Ask about Kikimimi, or ask it to change a setting. Nothing changes until you press “Change”.": "ききみみの事を聞いたり、設定の変更を頼んだりできます。「変える」を押すまで、何も変わりません。",
        "What can I change from here?": "ここから何を変えられますか？",
        "Turn off silence skipping": "無音を飛ばすのを切にして",
        "Translate into Korean from now on": "これからは韓国語に翻訳して",
        "Open “%@” in Settings…": "設定の「%@」を開く…",
        "Open settings…": "設定を開く…",
        "%1$@: %2$@": "%1$@: %2$@",
        "%1$@: %2$@ → %3$@": "%1$@: %2$@ → %3$@",
        "Change": "変える",
        "It is already this value.": "もうこの値です。",
        "Changed": "変えました",
        "Not changed": "変えていません",
        "Reading web pages…": "Web ページを読んでいます…",
        "Waiting for the LLM… (it is loading, or an audit or translation is using it)": "LLM を待っています… (読み込み中か、監査・翻訳が使っています)",
        "Answering…": "答えています…",
        "Message": "メッセージ",
        "Send": "送る",
        "The LLM runs on this Mac. Settings change only after you press “Change”.": "LLM はこの Mac で動きます。設定は「変える」を押した時だけ変わります。",
        // チャットの動き (Kikimimi/ChatController.swift)
        "Research is off, so no web pages were read.": "リサーチが切なので、ページは読んでいません。",
        "Could not read %1$@: %2$@": "%1$@ を読めませんでした: %2$@",
        "Read %@": "%@ を読みました",
        "Read “%1$@” (%2$@)": "「%1$@」(%2$@) を読みました",
        "Stopped.": "止めました。",
        "Web pages were read for this answer, so its setting changes are not offered.": "この答えでは Web ページを読んだので、設定の変更の案は出しません。",
        "%d action in the answer was not used.": "答えの中の %d 個の印は、使っていません。",
        "%d actions in the answer were not used.": "答えの中の %d 個の印は、使っていません。",
        "This model is not downloaded yet. Download it in Settings.": "このモデルは、まだダウンロードしていません。設定でダウンロードしてください。",
        "This setting could not be changed.": "この設定は変えられませんでした。",
        // Web ページを読む (Kikimimi/ChatWebFetcher.swift)
        "Only public https pages can be read.": "読めるのは、公開されている https のページだけです。",
        "The page moved to an address that cannot be read.": "ページの転送先が、読めない場所でした。",
        "The page moved too many times.": "ページの転送が多すぎました。",
        "The server answered with code %d.": "サーバーがコード %d で答えました。",
        "This is not a web page (%@).": "Web ページではありません (%@)。",
        "The page could not be read.": "ページを読めませんでした。",
        // 設定の「追加学習 (LoRA)」の行で、GGUF でないファイルを選んだ時 (KikimimiWhisper/LLMModelStore.swift)
        "This is not a fine-tuning adapter (LoRA) in GGUF format. Choose a .gguf file that runs on llama.cpp.": "GGUF 形式の追加学習の差分 (LoRA アダプタ) ではありません。llama.cpp で動く .gguf ファイルを選んでください。",
    ]
}
