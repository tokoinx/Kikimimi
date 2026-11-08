# ききみみ (Kikimimi) for Mac

[![build](https://github.com/tokoinx/Kikimimi/actions/workflows/build.yml/badge.svg)](https://github.com/tokoinx/Kikimimi/actions/workflows/build.yml)

**Mac の中だけで完結する音声文字起こしアプリ。** 会議・インタビュー・動画の音声を、時刻付きの文字にします。

[English README](README.en.md)

Swift / SwiftUI で書いたネイティブ Mac アプリです。音声認識には **whisper.cpp** (OpenAI Whisper の C/C++ 実装) を使い、Apple Silicon の GPU (Metal) で動きます。
音声は Mac の外に出ません。インターネットを使うのは、最初に音声認識モデルを取得するときだけです。

- 音声・動画ファイル (mp3 / m4a / wav / aiff / caf / mp4 / mov …) をドロップ → 時刻付きで文字起こし
- Finder の「このアプリケーションで開く」や Dock アイコンへのドロップでも追加できます
- 認識できた文から順に画面へ表示。途中で中止もできます
- マイク録音 (録音中は数秒ごとに直近の内容をプレビュー、止めると全体をていねいに認識)
- 行をクリックして該当箇所から再生、検索ハイライト
- 書き出し: txt / srt / vtt / Markdown / csv / json
- 言語: 日本語・英語・中国語・韓国語など (自動判定も可)

## 必要なもの

- macOS 14 (Sonoma) 以降。Apple Silicon 推奨 (Intel Mac でも CPU で動きますが遅くなります)
- Xcode 16 以降、または Command Line Tools (`xcode-select --install`)
- 空きディスク 1 GB 程度 (おすすめモデルが約 574 MB)

## ビルドと起動

```bash
git clone https://github.com/tokoinx/Kikimimi.git
cd Kikimimi
make run
```

`make run` は次をまとめて行います。

1. `swift build -c release` (初回は whisper.cpp のビルド済みフレームワーク約 54 MB を GitHub から取得)
2. `build/Kikimimi.app` の組み立てと whisper.framework の同梱
3. ad-hoc 署名
4. 起動 (ききみみが起動中なら、いったん終了させてから新しいものを開きます)

`/Applications` に入れるなら:

```bash
make install
```

### 初回の使い方

1. 起動すると「モデルをダウンロード」ボタンが出ます。おすすめの **Large v3 Turbo (軽量版)** は約 574 MB で、一度取れば以後はオフラインで動きます。
2. 音声ファイルをウィンドウに落とすか ⌘O で開きます。
3. 認識できた文から順に右側へ出ます。終わったら「書き出す」で保存します。

録音 (⌘R) を使うと、初回だけマイク許可のダイアログが出ます。

## モデルの選び方

| モデル | 向いている用途 | サイズ |
|---|---|---|
| Large v3 Turbo (軽量版) | 日本語の会議・インタビュー。迷ったらこれ | 約 574 MB |
| Large v3 Turbo | 軽量版より少しだけ高精度 | 約 1.6 GB |
| Large v3 (軽量版) | 最高精度クラス。Turbo の数倍遅い | 約 1.1 GB |
| Medium / Small / Base / Tiny | 速さ優先・動作確認 | 60〜540 MB |

モデルは `~/Library/Application Support/Kikimimi/Models` に保存されます。設定 (⌘,) から取得・削除・フォルダを開けます。

## 設定 (⌘,)

- **精度を優先する**: ビームサーチで認識します。オフにすると速くなります。
- **無音を飛ばす (VAD)**: 無音部分を飛ばして処理を速くし、無音での誤認識を減らします (VAD モデル約 0.9 MB を自動取得)。
- **定番の誤認識と、同じ文の繰り返しを取り除く**: 無音や BGM のところで Whisper が出しがちな「ご視聴ありがとうございました」などを、発話が無さそうなときだけ取り除きます。間を空けずに同じ文が 4 回以上 (2〜3 文の組なら 3 周以上) 続いたときは最初の 1 回だけ残し、1 文の中で同じ語句が 6 回以上続くときも 1 回にまとめます。数分おきに同じことを言う場面や、「No, no, no, no, no.」のような強調、金額・番号は残します。
- **語彙のヒント**: 固有名詞や専門用語 (例: Roblox Studio, ロブロックス) を書いておくと、その表記で出やすくなります。

## うまくいかないとき

- **モデルのダウンロードが失敗する**: Hugging Face (huggingface.co) に接続できる必要があります。会社のネットワーク等で繋がらない場合は、別の環境で次のファイルを入手し、設定の「手元のファイルを追加…」で取り込めます。
  - 音声認識モデル: `ggml-large-v3-turbo-q5_0.bin` (huggingface.co/ggerganov/whisper.cpp)
  - 無音検出 (VAD) モデル: `ggml-silero-v6.2.0.bin` (huggingface.co/ggml-org/whisper-vad)。無くても動きます。取れなかったときは 10 分おきに取り直します。
- **`make run` で whisper.framework が見つからないと言われる**: 次を実行してから、もう一度 `make run` してください。

  ```bash
  swift package reset
  ```

- **マイク許可のダイアログが出ない / 拒否してしまった**: システム設定 › プライバシーとセキュリティ › マイク で「ききみみ」をオンにします。作り直して署名が変わった場合は、次を実行してから起動し直してください。

  ```bash
  tccutil reset Microphone local.kikimimi.app
  ```

- **録音中に AirPods をつないだ / 入力を切り替えた**: 新しい入力で録音を続けます。続けられなかったときは、そこまでの録音を文字起こしします。
- **同じ文が延々と繰り返される (1.0.0 の不具合)**: 1.0.0 では、30 秒ごとの区間で認識した文章を次の区間の手がかりとして渡していたため、音楽や雑音で一度誤認識すると、その文が後ろの区間すべてに連鎖しました。1.0.1 で直しています。1.0.0 で文字起こししたファイルは、失われた部分を取り戻すために、もう一度文字起こししてください。
- **webm / mkv / ogg が読めない**: AVFoundation が対応していない形式です。QuickTime Player か ffmpeg で m4a / mp4 に変換してから使ってください。
- **起動時に「開発元を確認できない」と出る**: 自分でビルドしたアプリは通常出ませんが、出た場合は Finder でアプリを右クリック › 開く を選んでください。

## 検証状況

| 項目 | 状況 |
|---|---|
| 実機 (Apple Silicon、macOS 14.8.3) でビルドし、文字起こしに使用 | 確認済み |
| macOS 15 + Xcode 16.2 (Swift 6.0) / Xcode 26.3 でのビルドとテスト | GitHub Actions で毎回確認 |
| 録音中の入力デバイス切り替え (AirPods の接続など) | 未確認 (実装のみ) |
| Finder の「このアプリケーションで開く」/ Dock へのドロップ | 未確認 (実装のみ) |
| Intel Mac | 未確認 |
| 長い録音で同じ文が延々と続く不具合の修正 (1.0.1) | 再現実験で確認 (tiny モデル、音楽をはさんだ 5 分の音声)。実際の講演録音での再確認待ち |

## テスト

書き出し・モデル一覧・WAV・誤認識フィルタなど UI に依存しない部分は `KikimimiCore` に分けてあり、テストできます。

```bash
swift test
```

## 構成

```
Package.swift            依存: whisper.cpp v1.9.2 の公式 XCFramework (チェックサム固定)
Sources/
  KikimimiCore/          プラットフォーム非依存のコア
    Transcript.swift     区間・結果のモデル、時刻フォーマット
    Exporter.swift       txt / srt / vtt / md / csv / json
    ModelCatalog.swift   モデル一覧と配布元 URL、モデルファイルの検証
    HallucinationFilter.swift  定番の誤認識の除去
    WAV.swift            録音の保存 (16-bit PCM)
  KikimimiWhisper/       whisper.cpp の C API を包む層
    WhisperContext.swift 推論・進捗・区間ごとの通知・中止
    ModelStore.swift     モデルの保存場所・取り込み・削除
    ModelDownloader.swift 進捗つきダウンロード (検証してから配置)
  Kikimimi/              macOS アプリ (SwiftUI + AVFoundation)
    AppModel.swift       状態・ジョブの順番待ち・設定
    TranscriptionService.swift  推論専用スレッド、モデルの使い回し
    AudioDecoder.swift   音声/動画 → 16 kHz モノラル
    LiveRecorder.swift   マイク録音
    PlayerController.swift  再生・シーク
    Views/               画面
Resources/               Info.plist、アイコン
Scripts/build-app.sh     .app の組み立て
```

## 設計メモ

- **whisper.cpp を選んだ理由**: macOS 14 で動き、Metal で速く、ビルド済みの公式 XCFramework があるので C/C++ のビルドが不要です。日本語の精度は OpenAI Whisper と同じモデルなので同等です。
- **macOS 26 の SpeechAnalyzer** は将来の選択肢です。macOS 26 に上げた場合は、エンジンを差し替えられる構成にしてあります。
- **長い音声と繰り返しの暴走**: Whisper は 30 秒ずつ処理します。whisper.cpp の既定では、直前の区間で認識した文章を次の区間の手がかりとして渡します。`no_context` はこれを止めません (前回の呼び出しの文脈を捨てるだけです)。そこで `n_max_text_ctx = 0` にして区間どうしの引き継ぎを止め、OpenAI 版の `condition_on_previous_text=False` と同じ動きにしています。語彙のヒントは `carry_initial_prompt` で毎区間に付け、`n_max_text_ctx` を「ヒントのトークン数 + 1」に絞って、前の区間の文章が入らないようにしています。区間内で繰り返しになったときの言い直しは、ビームサーチでも 5 候補から選びます (`greedy.best_of = 5`、whisper-cli と同じ。既定のままだと 1 候補だけの抽選になります)。繰り返しとみなす基準 (`entropy_thold`) は既定の 2.4 のままです。上げると普通の発話でも言い直しが増えて遅くなり、音楽部分のでたらめな文もかえって片付けにくくなることを、再現実験で確かめました。それでも残った分は後始末で片付けます。
- **署名**: ad-hoc 署名です。人に配る場合は Developer ID での署名と公証に差し替えてください。

## 既知の制限

- 話者分離はありません。
- 録音中のプレビューは直近 12 秒ぶんだけです (止めると全体を認識し直します)。

## ライセンス

MIT License ([LICENSE](LICENSE))。

ビルド時・実行時に取得するもの (このリポジトリには含みません):

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) v1.9.2 の XCFramework (MIT): ビルド時に GitHub から取得
- Whisper のモデル (MIT, OpenAI) を whisper.cpp 形式にしたもの: 初回に [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp) から取得
- [Silero VAD](https://github.com/snakers4/silero-vad) (MIT) を whisper.cpp 形式にしたもの: 同上 ([ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad))
