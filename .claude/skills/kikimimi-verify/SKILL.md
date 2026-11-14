---
name: kikimimi-verify
description: ききみみの変更を確かめる手順 (ビルド → 試験 → アプリを作る → アプリの確認 → 出力・終了コード・絵の読み方)。Swift のコードや画面を変えた後、完了と報告する前に使う。指示ファイル・Skill・門の設定だけの変更には使わない。
---

# ききみみの変更を確かめる

決まり (Swift 6.0・末尾のカンマ・macOS 14・一覧の 4 つの決まり・push・命令の書き方・「完了」の条件) は `CLAUDE.md` に在る。ここには手順と読み方だけを書く。

## 1. どこまで行うか

- `Sources/KikimimiCore` や `Tests` だけを変えた → 2 の 1〜2 (ビルドと試験) まで。
- 画面 (`Sources/Kikimimi`) を変えた → 2 の 1〜4 (アプリの確認) まで。
- 結果の一覧 (`Sources/Kikimimi/Views/TranscriptDetailView.swift`) に触った → 必ず 3000 行のアプリの確認まで行い、4 の「重い」の読み方を見る。

## 2. 命令 (作業フォルダはプロジェクトの根。1 行に 1 命令)

1. `swift build` (門: 通る)
2. `swift test` (門: 通る。Bash の timeout は 600000 にしておく)
3. `make app` (門: 確認が出る。`build/Kikimimi.app` ができる)
4. `build/Kikimimi.app/Contents/MacOS/Kikimimi --selftest-ui-load 3000 --audio Tests/Fixtures/mixed-en-ja.wav --screenshots build/ui-shots` (門: 確認が出る。ウインドウが開き、音が鳴る。数分かかるので run_in_background で走らせる)

- 4 は CI (`.github/workflows/build.yml` の「UI load self-test (3000 lines, …)」の段) と同じ確認。音声は相対パスで読める (プロジェクトの根から走らせた時)。`$PWD` は門で止まるので書かない。
- 結果の行は標準エラーへ、終わりにまとめて出る。途中では `UI LOAD (live): …` の行だけが出る。ファイルにも残したい時は `--report build/ui-load-3000.txt` を足す。
- `--selftest-…` の時は、ふだんのライブラリに保存しない (確認は一時フォルダで行い、終わりに消す)。
- `make app` が `PCH was compiled with module cache path '…'` で失敗した時は、フォルダの名前が変わる前の release の成果物が残っている。`.build/arm64-apple-macosx/release` を、まだ無い別の名前へ `mv` でよけて (門: 確認が出る。`rm -r` は拒まれる) から、もう一度 `make app`。よけた物を消すのは利用者に頼む。

## 3. 出力の読み方

`swift test`:
- 出力は長い (Bash の結果がファイルへ逃がされたら、その終わりの数行を Read で開く。`tail` やパイプは門の確認で止まる)。終わりの `Test Suite 'All tests' passed at …` (失敗があれば `failed at`) と、その次の `Executed N tests, with M failures (0 unexpected) in …` を見る。件数 N と失敗 M をここから写す。
- そのさらに後に出る `✔ Test run with 0 tests passed …` は Swift Testing の分で、ここの試験は XCTest なので 0 件と出る。件数として写さない。

アプリの確認: `LIBRARY CHECK OK` (保存)・`PRACTICE CHECK OK` (練習。`--audio` の時だけ)・`UI LOAD OK` (終了コード 0 の時だけ、最後の行) の 3 つが出て、終了コードが 0 である事を見る。

| 終了コード | 意味 | 出力に出る文 |
|---|---|---|
| 0 | 成功 | `UI LOAD OK` |
| 1 | メインのウインドウが出ない | `UI LOAD FAILED: no main window after 20 s` |
| 3 | 終わらない (メインスレッドが止まった) | `UI LOAD FAILED: the self-test did not finish in … s` |
| 5 | 重い | `UI LOAD: SLOW (…)` |
| 6 | 1 行だけの再生が行の終わりで止まらない・続きから再生しない | `UI LOAD: LINE DID NOT STOP …`・`LINE STOPPED TOO EARLY …`・`LINE STOPPED AWAY FROM …`・`PLAY AFTER THE ROW DID NOT CONTINUE …` |
| 7 | 保存の確認に失敗 | `LIBRARY CHECK FAILED: …` |
| 8 | 練習の確認に失敗 | `PRACTICE CHECK FAILED: …` |

- 複数が失敗しても、返る終了コードは 1 つだけ (5 > 6 > 7 > 8 の順)。終了コードが 5 でも、7 や 8 の失敗が隠れている事がある。`FAILED` の行を全部探す。
- 音を出せない Mac (ふつうの再生で位置が進まない・音声を開けない) では、`UI LOAD: no audio playback here (…)` と `PRACTICE: skipped (no audio playback here)` が出て、1 行の再生と練習の確認は飛ばされる。この時 `PRACTICE CHECK OK` は出ないが、終了コードは 0 になりうる。「練習の確認は走らなかった」と報告する。
- 絵を残せなくても終了コードは変わらない。`UI LOAD: screenshot failed …` の行で分かる。

## 4. 「重い」(SLOW) の読み方

- 目安を超えた物は 1 つにつき 1 行、`UI LOAD: SLOW ("<操作の名前>" p95 … ms >= … ms)` や `max … ms >= … ms` の形で出る。どの値がどの目安を超えたかは、この行の中に在る。目安の値は `Sources/Kikimimi/UILoadSelfTest.swift` の `Limits`、比べ方は `limitFailures()`。
- 操作ごとの値は `UI LOAD: action "<名前>": n …, median …, p95 …, max …` の行。`n < 20: p95 not checked` と付いた操作は最大だけを比べている。
- 一覧に関わる値: ジョブを選ぶ操作 (`select finished job …`・`select running job`) と再生位置を遠くへ動かす操作 (`jump …`) には `UI LOAD: rows built "<名前>": inits …; bodies …` の行が出る。比べるのは bodies (行の body が動いた数) で、目安は `Limits.selectRowsBuiltMax`。inits は一覧が終わりへ飛ぶと数千になってよく、比べない。bodies が数千なら、一覧が見える分だけを並べていない (CLAUDE.md の一覧の決まりを破った時の形)。
- `UI LOAD: rows built during the measured part: inits …, bodies …` は測った間すべての合計で、目安 (1 回あたり) と比べない。合計が目安の数を超えていても `SLOW` にはならない。
- `UI LOAD: samples "<名前>": …` は測った順の値。初めの 1 回だけが遅いのか、毎回遅いのかを見分ける。
- `UI LOAD: stall 1..5` は長かった待ちと、その直前の操作。どの操作が重いかの手がかり。

## 5. 絵の見方 (`build/ui-shots`)

各絵は 1200 x 800 pt のウインドウ (タイトルバーつき。Retina の Mac では 2400x1600 画素)。08 だけはシートそのものを撮るので小さく、ウインドウは写らない。出力の `UI LOAD: screenshot <名前>.png <幅>x<高さ> (…)` の行で、できたかが分かる。

| 絵 | 写っているべき物 |
|---|---|
| `01-finished-bilingual.png` | 終わったジョブ (英語と日本語の対訳)、一覧の始め |
| `02-line-playing.png` | 同じジョブで、4 行目を 1 行だけ再生している色と止める印 |
| `03-finished-plain.png` | 終わったジョブ (日本語だけ)、一覧の始め |
| `04-running-job.png` | 文字起こし中のジョブ、一覧の終わりと進み具合 |
| `05-running-scrolled-up.png` | 同じジョブを 15 行ほど上へ動かし、右下に「末尾へ」が出ている |
| `06-auto-mixed-notice.png` | 自動で「日本語＋英語」にしたジョブの案内と「…だけでやり直す」、英語の行の「訳」 |
| `07-notes-pane.png` | メモの欄 (引用した行を 1 つ含むメモ) |
| `08-history-sheet.png` | 履歴の画面 (版が 3 つ以上、1 つは自動で残したもの) |
| `09-practice-hidden.png` | 英語の原文が灰色の帯で隠れ、目のボタンで 1 行だけ見えている。「練習」のボタンに色 |
| `10-dictation.png` | 下に書き取りの欄。答え合わせで 1 語が赤の取り消し線、1 語が抜け (`[…]`)、右に「n / m 語」 |

- 変えた画面に関わる絵を Read で開いて見る。絵の場面ごとの注意 (`… may show no playing tint` など) が出力に在れば、その絵は特に見る。

## 6. 手元では見ない事 (CI だけが見る)

- 起動の確認 (`--selftest-launch` の 7 通り: シェルから・open で・reopen で・メニューで・何度か強制終了した後・ウインドウの復元 (参考)・ウインドウの無い写しが動いている時の open。ほかに「確認用の実行中の起動」の段)。
- `--selftest-llm`、`--selftest-whisper`。
- 8000 行のアプリの確認 (参考。失敗にしない)。
- Xcode 16.2 と 26.3 の両方でのビルド (手元の Xcode は 1 つ)。
- macOS 14 の実機での動作は、利用者の Mac でだけ見られる (CI にも無い)。

## 7. 報告に入れる物

- 走らせた命令 (全文)。
- `swift test` の件数と失敗の数 (`Executed … tests, with … failures` の行から写す)。
- アプリの確認で 3 つの文が出たか、それぞれ。終了コード。`SLOW`・`FAILED`・`skipped` の行があれば、その行。
- 開いた絵の名前と、写っていた物。
- 走らせなかった確認 (6 の CI だけの物、飛ばされた練習の確認など) と、その理由。
