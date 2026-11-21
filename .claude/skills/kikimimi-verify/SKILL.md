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

1. `swift build`
2. `swift test` (Bash の timeout は 600000 にしておく)
3. `make app` (`build/Kikimimi.app` ができる)
4. `make check-ui` (ウインドウが開き、音が鳴る。数分かかるので run_in_background で走らせる)

- 4 が走らせる命令は `Makefile` の `check-ui` に在る。CI (`.github/workflows/build.yml` の「UI load self-test (3000 lines, …)」の段) と同じ確認。アプリは作らないので、先に 3 を行う。違いは 1 つ: CI は、「重い」(終了コード 5) の時だけ、もう 1 回だけ測り直し、2 回続けて「重い」の時に失敗にする (実行機が一時止まった時の跳ねのため。1 回目の SLOW の行は、警告として残る)。手元の `make check-ui` は測り直さない。
- `make` を通すので、アプリの終了コード N は `make: *** [check-ui] Error N` の行に出る (`make` 自身は 2 を返す)。この行が無く `make` が 0 で終われば、アプリの終了コードは 0。
- 結果の行は標準エラーへ、終わりにまとめて出る。途中では `UI LOAD (live): …` の行だけが出る。
- `--selftest-…` の時は、ふだんのライブラリに保存しない (確認は一時フォルダで行い、終わりに消す)。
- `--selftest-…` の時の画面の言語は、引数 `--ui-language <コード>` で決まる (無ければ日本語。設定は読まず・書かない)。下の「絵の見方」は日本語の画面の文で書いてある。ほかの言語の見た目 (字が切れていないか) を見る時は、`build/Kikimimi.app/Contents/MacOS/Kikimimi --selftest-ui-load 300 --audio Tests/Fixtures/mixed-en-ja.wav --ui-language de --screenshots <置き場>` のように、言語と絵の置き場を変えて走らせる (ドイツ語は語が長いので、切れを見つけやすい)。
- `make app` が `PCH was compiled with module cache path '…'` で失敗した時は、フォルダの名前が変わる前の release の成果物が残っている。`.build/arm64-apple-macosx/release` を、まだ無い別の名前へ `mv` でよけて (`rm -r` は門で拒まれる) から、もう一度 `make app`。よけた物を消すのは利用者に頼む。

## 3. 出力の読み方

`swift test`:
- 出力は長いので、終わりの 2 行だけを抜き出すとよい: `swift test 2>&1 | rg -A 1 "Test Suite 'All tests' (passed|failed)"`。終わりの `Test Suite 'All tests' passed at …` (失敗があれば `failed at`) と、その次の `Executed N tests, with M failures (0 unexpected) in …` を見る。件数 N と失敗 M をここから写す。
- そのさらに後に出る `✔ Test run with 0 tests passed …` は Swift Testing の分で、ここの試験は XCTest なので 0 件と出る。件数として写さない。

アプリの確認: `LIBRARY CHECK OK` (保存)・`PRACTICE CHECK OK` (練習。`--audio` の時だけ)・`CHAT CHECK OK` (チャットの窓。LLM もネットワークも使わない)・`UI LOAD OK` (終了コード 0 の時だけ、最後の行) の 4 つが出て、終了コードが 0 である事を見る。`ADAPTER MESSAGE CHECK OK` (設定の「追加学習」の、GGUF でない差分のお知らせ) も出る。

| 終了コード | 意味 | 出力に出る文 |
|---|---|---|
| 0 | 成功 | `UI LOAD OK` |
| 1 | メインのウインドウが出ない | `UI LOAD FAILED: no main window after 20 s` |
| 3 | 終わらない (メインスレッドが止まった) | `UI LOAD FAILED: the self-test did not finish in … s` |
| 5 | 重い | `UI LOAD: SLOW (…)` |
| 6 | 1 行だけの再生が行の終わりで止まらない・続きから再生しない | `UI LOAD: LINE DID NOT STOP …`・`LINE STOPPED TOO EARLY …`・`LINE STOPPED AWAY FROM …`・`PLAY AFTER THE ROW DID NOT CONTINUE …` |
| 7 | 保存の確認に失敗 | `LIBRARY CHECK FAILED: …` |
| 8 | 練習の確認に失敗 | `PRACTICE CHECK FAILED: …` |
| 9 | チャットの確認に失敗 | `CHAT CHECK FAILED: <段の名前>` (段ごとに `CHAT CHECK: <段> ok` / `NG (…)` の行も出る) |

- 終了コードの数と順の元は `Sources/KikimimiCore/UILoadExit.swift`。この表や下の「5 > 6 > … の順」と合わない時は、`swift test` の `UILoadExitTests` が落ちる。
- 保存の確認 (LIBRARY CHECK) の各段は `LIBRARY: <段の名前>: ok (…)` か `FAILED (…)` の 1 行で出る。訳に関わる段 (2026-11-16 に足した):
  - `rows with edited and flagged translations`: 対訳のジョブに、直した行と要確認の行が両方在る (3000 行なら、それぞれ 125)。
  - `count rows that need review`: 「要確認 N」の数 (行を作る時に数えた物) と、結果の覚えの数が同じ。
  - `confirm a flagged translation through the model`: 「この訳でよい」で印が消え、覚えの出どころが `confirmed` になる (符号は残る)。
  - `the self-test does not use the real translation memory`: 確認用の起動は、利用者の本物の訳の記憶 (`translation-memory.json`) を読まず・書かない。
  - `edit a translation through the model` → `reuse a remembered translation without the LLM` → `restore the machine translation through the model`: 一時の記憶で、訳を直すと記憶が 1 件、記憶に在る文が LLM なしで入る (覚えが `memory`)、機械の訳に戻すと記憶が 0 件。
  - `count “this translation is fine” for the check` (256f8de で足した): 「この訳でよい」で、その印の検査 (数の抜け) の「この訳でよい」の数が 1 以上になり、覚えの判定が `confirmed` になる。
  - `a check stops after five “this translation is fine”` (同): 一時の記憶で「この訳でよい」を 5 回数えると、その検査が、その訳す先で止まる (止めた検査の一覧に 1 つ)。
  - `undo a stopped check` (同): [元に戻す] で、止めた検査が無くなり、保存した記憶の数も消える。
- 複数が失敗しても、返る終了コードは 1 つだけ (5 > 6 > 7 > 8 > 9 の順。`ADAPTER MESSAGE CHECK FAILED` は 7 に入る)。終了コードが 5 でも、7 や 8 の失敗が隠れている事がある。`FAILED` の行を全部探す。
- 音を出せない Mac (ふつうの再生で位置が進まない・音声を開けない) では、`UI LOAD: no audio playback here (…)` と `PRACTICE: skipped (no audio playback here)` が出て、1 行の再生と練習の確認は飛ばされる。この時 `PRACTICE CHECK OK` は出ないが、終了コードは 0 になりうる。「練習の確認は走らなかった」と報告する。
- 絵を残せなくても終了コードは変わらない。`UI LOAD: screenshot failed …` の行で分かる。

## 4. 「重い」(SLOW) の読み方

- 目安を超えた物は 1 つにつき 1 行、`UI LOAD: SLOW ("<操作の名前>" p95 … ms >= … ms)` や `max … ms >= … ms` の形で出る。どの値がどの目安を超えたかは、この行の中に在る。目安の値は `Sources/Kikimimi/UILoadLimits.swift` の `Limits`、比べ方は `Sources/Kikimimi/UILoadRun+Measure.swift` の `limitFailures()`。
- 操作ごとの値は `UI LOAD: action "<名前>": n …, median …, p95 …, max …` の行。`n < 20: p95 not checked` と付いた操作は最大だけを比べている。
- 一覧に関わる値: ジョブを選ぶ操作 (`select finished job …`・`select running job`) と再生位置を遠くへ動かす操作 (`jump …`) には `UI LOAD: rows built "<名前>": inits …; bodies …` の行が出る。比べるのは bodies (行の body が動いた数) で、目安は `Limits.selectRowsBuiltMax`。inits は一覧が終わりへ飛ぶと数千になってよく、比べない。bodies が数千なら、一覧が見える分だけを並べていない (CLAUDE.md の一覧の決まりを破った時の形)。
- `UI LOAD: rows built during the measured part: inits …, bodies …` は測った間すべての合計で、目安 (1 回あたり) と比べない。合計が目安の数を超えていても `SLOW` にはならない。
- `UI LOAD: samples "<名前>": …` は測った順の値。初めの 1 回だけが遅いのか、毎回遅いのかを見分ける。
- `UI LOAD: stall 1..5` は長かった待ちと、その直前の操作。どの操作が重いかの手がかり。

## 5. 絵の見方 (`build/ui-shots`)

各絵は 1200 x 800 pt のウインドウ (タイトルバーつき。Retina の Mac では 2400x1600 画素)。08・11・12・13 はシートそのものを撮るので小さく、ウインドウは写らない。出力の `UI LOAD: screenshot <名前>.png <幅>x<高さ> (…)` の行で、できたかが分かる。

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
| `11-delete-confirm.png` | ゴミ箱に入れるかの確認の画面 (07・08 の後に撮る)。「ゴミ箱に入れるもの」に保存のフォルダのパス、「残るもの」に元の音声ファイルのパス、「キャンセル」と「ゴミ箱に入れる」 |
| `12-translation-edit.png` | 訳を直す画面 (直した訳の行を開いたところ。08 の後、11 の前に撮る)。機械の訳と「機械の訳に戻す」 |
| `13-translation-check.png` | 要確認の行を開いた、訳を直す画面。上に理由の行と「この訳でよい」 |

| `14-chat-empty.png` | チャットの窓 (480 x 640 pt)。上に灰色の「リサーチ … 切」の帯と「入れる…」、空の案内と例のボタン 3 つ、下に入力の欄と小さな 1 行 |
| `15-chat-research-confirm.png` | リサーチの確認のシート (シートそのもの)。題「自己責任で、リサーチを入れますか？」、Prompt Injection の説明、「キャンセル」(既定) と「自己責任で入れる」 |
| `16-chat-research-on.png` | チャットの窓の上の帯が橙色の「リサーチが入っています (自己責任)…」と「切る」 |
| `17-chat-proposal.png` | 答えの下の札「無音を飛ばす (VAD): オン → オフ」と「変える」「キャンセル」 |

- 12・13 のシートには、23f94f8 (U5) から、下に訳語の 1 行「語を、いつもこう訳す (任意)」が在る (シートのコードでは、いつも出す)。

- 変えた画面に関わる絵を Read で開いて見る。絵の場面ごとの注意 (`… may show no playing tint` など) が出力に在れば、その絵は特に見る。

## 6. 手元では見ない事 (CI だけが見る)

- 起動の確認 (`--selftest-launch` の 7 通り: シェルから・open で・reopen で・メニューで・何度か強制終了した後・ウインドウの復元 (参考)・ウインドウの無い写しが動いている時の open。ほかに「確認用の実行中の起動」の段)。
- `--selftest-llm`、`--selftest-whisper`。
- `--selftest-chat` (本物の LLM でチャットの答えを測る。手元で走らせるなら `make check-chat LLM=<モデル.gguf>`。`CHAT STREAM OK` (出している途中の文が 2 回以上届き、最後の文が答えと同じ) で終了コード 0。`CHAT EVAL: <id> ok|NG | <期待> | <答えの始め>` の 16 行と `CHAT EVAL: N/16` は参考で、点では落とさない。`--report <ファイル>` で同じ行をファイルにも書く)。
- `--selftest-llm-queue` (本物の `LLMService` を通して、監査・翻訳の最中にチャットが割り込めるかを見る。手元で走らせるなら `make check-llm-queue LLM=<モデル.gguf>`。割り込みあり・なしで訳と監査の結果が同じ、最中に通った割り込みが 1 つ以上、中止した割り込みが監査・翻訳を止めない、で `LLM QUEUE OK`・終了コード 0。通らない時は `LLM QUEUE FAILED: 理由`・終了コード 1)。LLM の順番待ち (`LLMService.swift`・`LLMInterrupts.swift`) を変えた時は、手元でも走らせる。
- 8000 行のアプリの確認 (参考。失敗にしない)。
- Xcode 16.2 と 26.3 の両方でのビルド (手元の Xcode は 1 つ)。
- macOS 14 の実機での動作は、利用者の Mac でだけ見られる (CI にも無い)。

## 7. 報告に入れる物

- 走らせた命令 (全文)。
- `swift test` の件数と失敗の数 (`Executed … tests, with … failures` の行から写す)。
- アプリの確認で 3 つの文が出たか、それぞれ。終了コード。`SLOW`・`FAILED`・`skipped` の行があれば、その行。
- 開いた絵の名前と、写っていた物。
- 走らせなかった確認 (6 の CI だけの物、飛ばされた練習の確認など) と、その理由。
