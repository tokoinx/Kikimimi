# でたらめな入力で試す道具 (モンキーテスト)

人が思いつく例だけでなく、「ふつうは来ない値」を入れて、落ちる所・止まる所・黙って失敗する所を探すための道具と、その使い方です。
見つけた事は、直すだけで終わらせず、**同じ入力がもう 1 度来ても止まる見張り**にして残します (下の「見つけた後の手順」)。

## 3 つの層

| 層 | 何を試すか | 道具 | 時間 |
|---|---|---|---|
| 1. 関数 | 画面に頼らない関数 (`KikimimiCore`) に、端の値・壊れた文・長い文を入れる | `Tests/KikimimiCoreTests/MonkeyTests.swift` | 数秒 |
| 2. 保存ファイル | 変な保存ファイルを入れた一時のライブラリで、アプリを起こす | `make_hostile_library.py`・`run_scenes.sh` | 5 分 |
| 3. 命令の引数 | 確認用の起動に、変な引数・変なファイルを渡す | `run_cli_cases.sh` | 1〜10 分 |

層 2 と層 3 は、アプリを作ってから (`make app`) 走らせます。`swift test` と CI は、層 1 だけを走らせます。

## 層 1: 関数に入れる (`MonkeyTests.swift`)

試験は、どれも `monkey("名前", make: 入力を作る, check: 決まりを見る)` の形です。形は 3 つ:

- **落ちない**: どんな入力でも、関数が戻ってくる (例: `testTimeFormatTakesAnySeconds`)
- **行って戻る**: 書いて読むと、元と同じ (例: `testLibraryDateRoundTrips`)
- **時間の内に終わる**: 入力が長くても、決めた秒数の内に戻る (例: `testWebPageTextFinishesOnHostilePages`。`finishes(within:)` を使う)

決まり:

- 乱数は、必ず `Monkey` (種を決めた乱数) から取る。`Int.random(in:)` をそのまま使うと、失敗した入力を作り直せない。
- 端の値は `MonkeyPool` から選ぶ。足りない値は、試験の中に書かずに `MonkeyPool` へ足す (ほかの試験も、その値を使うようになる)。
- 作る時に直される値 (例: `TranscriptSegment.init` は、終わりを始まりより前にしない) を試す時は、JSON から読んで作る (保存ファイルからは、直しを通らずに入る)。

走らせ方:

```bash
swift test --filter MonkeyTests
```

```bash
KIKIMIMI_MONKEY_ROUNDS=5000 swift test --filter MonkeyTests
```

失敗の読み方:

- 決まりが破れた時は、失敗の文に、試験の名前・種 (seed)・回の番号・入力が出る。同じ入力は `KIKIMIMI_MONKEY_SEED=<種> swift test --filter MonkeyTests/<試験の名前>` で作り直せる。
- 落ちた時 (`Fatal error`。試験の実行ごと止まり、ほかの試験の結果も出ない) は、最後に試していた入力が `$TMPDIR/kikimimi-monkey-last.txt` に残る。

### 手探りする時の型 (コミットしない)

どこが遅いか・落ちるかを、まだ知らない時は、一時の試験ファイルで、長さを倍々にして時間を印刷します。4 倍ずつ増えたら、長さの 2 乗です。

```swift
for n in [2_000, 4_000, 8_000, 16_000, 32_000] {
    let input = String(repeating: "<", count: n)
    let start = Date()
    let ok = finishes(within: 8) { _ = WebPageText.extract(html: input) }
    print("PROBE n=\(n): \(ok ? "\(Date().timeIntervalSince(start) * 1000) ms" : "TIMEOUT")")
}
```

`swift test --filter <一時の試験の名前> | grep -a PROBE` で読みます (出力に `\0` が混ざると、`grep` は `-a` が要ります)。

## 層 2: 変な保存ファイルで起こす

```bash
tools/monkey/run_scenes.sh "$TMPDIR/kikimimi-monkey"
```

```bash
tools/monkey/run_scenes.sh "$TMPDIR/kikimimi-monkey" huge-duration same-id
```

場面は `make_hostile_library.py` の `scenes` に在ります (とても大きい時刻、終わりが始まりより前、同じ ID の区間、5 万区間、1 MB の 1 行、変な題名、元の音声が `/dev/zero`、新しすぎる版の番号、壊れた版のファイル、読めない JSON、文字として読めないメモ、など)。場面を足す時は、`scenes` に 1 行足し、`run_scenes.sh` の `ALL` に名前を足します。

読み方: `exit 0 | LAUNCH SELFTEST OK` が、ふつう。読めないファイルは `set aside 1` (名前を変えて、とっておかれる)。`exit 133` で報告が空なら、アプリが落ちた。`exit 3` は、メインスレッドが止まった。

分かっている限り: 起動は、結果を選ばない。だから、この層が試すのは「読み込み」と「横の一覧」まで。結果を開いた後の画面 (行・再生・書き出し・履歴) は、試せていない。

## 層 3: 変な引数で起こす

```bash
tools/monkey/run_cli_cases.sh "$TMPDIR/kikimimi-monkey" quick
```

```bash
tools/monkey/run_cli_cases.sh "$TMPDIR/kikimimi-monkey" load
```

読み方: `exit N after S s` が、ふつう (引数が足りない時は、使い方を出して exit 2)。`STILL RUNNING after S s (stopped it)` は、終わらなかったので道具が止めた = 見つけた事。

## 守る事 (層 2・層 3)

- アプリは、`--selftest-` で始まる引数 (か、窓を出さない道具の引数) と、一時のライブラリでだけ起こす。ふつうの起動はしない。利用者の本物のライブラリ・設定・モデルのフォルダに書かない。
- 動いているアプリが在る時は、道具はその場面を飛ばす (アプリを止めない)。
- 道具は、前と後で `defaults read local.kikimimi.app` を比べ、`REAL SETTINGS DIFF: N lines` を出す。0 でない時は、下の後片付けをする。

### 後片付け

アプリが落ちた回・道具が止めた回は、アプリ自身の「戻す」処理まで行かないので、macOS が書いた窓の分け方の鍵 (`NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView`) が、前と違う値で残る事があります。
`diff <作業フォルダ>/defaults-before.txt <作業フォルダ>/defaults-after.txt` で違いを見て、**その鍵だけ**を、前の値に書き戻します (ほかの鍵が違っていたら、書き戻さずに報告する)。

```bash
defaults write local.kikimimi.app "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView" -array "<前の 1 行目>" "<前の 2 行目>"
```

落ちた回は、`~/Library/Logs/DiagnosticReports/` に `Kikimimi-<日時>.ips` が 1 つ残ります (落ちた場所が読める。消さなくてよい)。

## 見つけた後の手順 (直して、見張りにする)

1. **小さくする**: 落ちる・止まる入力を、いちばん小さい形にする (どの値が効いているか。長さは、どこから遅いか)。
2. **層 1 の試験にする**: その入力を `MonkeyPool` に足すか、`MonkeyTests` に試験を 1 つ足す。**直す前に、その試験が落ちる事を見る** (落ちない試験は、見張りにならない)。
3. **入口で直す**: 外から来る値 (保存ファイル・Web ページ・LLM の答え・引数) は、入ってくる所で 1 度だけ直す・断る。使う所ごとに守りを足さない (足し忘れる)。加えて、落ちた関数そのものも、変な値で落ちないようにする (二重の守り)。
4. **層 2・層 3 でも見る**: アプリで起きた事なら、その場面をもう 1 度走らせ、ふつうの結果になった事を見る。
5. **記録**: 何を入れて、何が起きて、どう直したかを `docs/HANDOFF-ARCHIVE.md` に書く。試して何も起きなかった物も、1 行で残す (次の人が、同じ所を試さずに済む)。

### 例 (2026-11-28)

- 入力: 保存ファイルの `"duration": 1e300`。起きた事: 横の一覧が長さを `mm:ss` にする所 (`TimeFormat.short` の `Int(…)`) で落ち、アプリが起動のたびに落ちる。
- 小さくする: `TimeFormat.short(1e300)` の 1 行で落ちる。`9.3e15` 秒から上が落ちる (ミリ秒にして `Int` に入らない)。
- 試験: `MonkeyPool.doubles` に端の値を置き、`testTimeFormatTakesAnySeconds` と `testExportTakesHostileSegments` が、直す前に `Fatal error` で止まる事を見た。
- 直し: 読み込んだ結果の時刻と長さを、入口で 1 度だけ、使える範囲に直す。`TimeFormat` も、範囲の外の値を端の値にしてから整数にする。
- アプリで見る: `tools/monkey/run_scenes.sh <作業フォルダ> huge-duration` が `exit 0 | LAUNCH SELFTEST OK` になる。
