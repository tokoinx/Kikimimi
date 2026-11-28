---
name: kikimimi-verify
description: ききみみの変更を確かめる手順 (ビルド → 試験 → アプリを作る → アプリの確認 → 出力・終了コード・絵の読み方)。Swift のコードや画面を変えた後、完了と報告する前に使う。指示ファイル・Skill・門の設定だけの変更には使わない。
---

# ききみみの変更を確かめる

決まり (Swift 6.0・末尾のカンマ・macOS 14・一覧の 4 つの決まり・push・命令の書き方・「完了」の条件) は `CLAUDE.md` に在る。ここには手順と読み方だけを書く。

## 1. どこまで行うか

- `Sources/KikimimiCore` や `Tests` だけを変えた → 2 の 1〜2 (ビルドと試験) まで。
- 画面 (`Sources/Kikimimi`) を変えた → 2 の 1〜4 (アプリの確認) まで。
- 結果の一覧 (`Sources/Kikimimi/Views/TranscriptListView.swift`・`TranscriptListSupport.swift` と、呼ぶ側と行の部品の `TranscriptDetailView.swift`) に触った → 必ず 3000 行のアプリの確認まで行い、4 の「重い」の読み方を見る。

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

アプリの確認: `LIBRARY CHECK OK` (保存)・`PRACTICE CHECK OK` (練習。`--audio` の時だけ)・`CHAT CHECK OK` (チャットの窓。LLM もネットワークも使わない)・`UI LOAD OK` (終了コード 0 の時だけ、最後の行) の 4 つが出て、終了コードが 0 である事を見る。`ADAPTER MESSAGE CHECK OK` (設定の「追加学習」の、GGUF でない差分のお知らせ) と、`AUDIT FLOW CHECK OK` (監査の流れ。LLM の代わりを入れて、アプリの監査を、行を直して覚える → 提案 → 反映 → 自動の直し → LLM の段の後も直ったまま、まで通す。2026-11-26 に足した) も出る。`RETRANSLATE CHECK OK` (「〇〇で訳し直す」の道。LLM の代わりを入れて、訳の付いた確認用の結果を別の言語へ訳し直し、LLM が無い時は何も変わらない事・訳し直す前の版 (自動) が 1 つだけ残る事・訳が新しい言語になる事・「いちばん新しい版に上書き」の相手が自分で残した版のままである事を見る。段ごとに `RETRANSLATE: <段の名前>: ok (…)` か `FAILED (…)` の行が出る。2026-11-27 に足した) も出る。

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
- 聞き取った文を直す段 (2026-11-22 に足した。訳の在る 1 行で、終わりに結果を直す前と同じに戻す):
  - `edit a line through the model`: 文が変わり、聞き取った文 (直す前の文) が記録に残る。
  - `editing a line removes its translation`: 直した行の訳が消える。
  - `reload an edited line with a fresh LibraryStore`: 新しい LibraryStore で読み直すと、結果と記録が同じ。
  - `the list row shows the edited line`: 一覧の行 (単言語・対訳) に聞き取った文が入り、行の「訳」が出る。
  - `restore the heard text through the model` → `the job is the same as before the line edit`: 戻すと文が元どおりで記録が無い。確認用に訳を置き直すと、結果が直す前と同じ。
  - `a bilingual row of two segments lists both` → `edit the second segment of a bilingual row through the model` → `restore the second segment and put the job back`: 確認用の結果には、いくつかの区間から成る訳のまとまりが無いので、確かめる間だけ 2 つの区間を 1 つの訳にする。行が 2 つの区間を持ち、2 つ目だけを直すと行の文が変わって印が出て、戻してまとまりを外すと結果が前と同じ。
  - 直した組を、学習した直しの台帳に覚えさせる段 (2026-11-22 に足した。台帳は、確かめる間だけ一時のファイル):
    - `learned corrections are on and have no file before the learning steps`: 学習した直しが入で、台帳の保存先が無い (確認用の起動は、本物の `learned-corrections.json` を読まず・書かない)。
    - `remember an edited pair in the learned corrections` → `saving the same pair again does not count it twice` → `restoring the heard text takes the pair back`: 1 語を「Kikimimi」に直して覚えさせると、台帳に 1 件・反映 1 回 (一時のファイルにも)。同じ組で保存し直しても 1 回のまま。戻すと 0 回。
    - `the job and the ledger are the same as before the learning steps`: 結果と台帳が、始める前と同じ。
  - `the self-test does not use the real learned corrections` (保存の確認の最後): 台帳の保存先が無く、本物の `learned-corrections.json` の有無・大きさ・更新の時刻が、保存の確認の前後で同じ。
- LLM が失敗した時の段 (2026-11-28 に足した。偽の LLM が、失敗 `decodeFailed(-1)` を投げる・答えを途中で切る・空の答えを返す): `AUDIT FLOW: LLM fails at once: …`・`LLM fails partway: …`・`LLM fails with a previous LLM audit: …`・`the LLM answer is cut off: …`、`RETRANSLATE: LLM fails while translating: …`・`the next translation with a working LLM finishes`・`a failed translate-again keeps the edited translation and its Edited mark`、`CHAT CHECK: an empty reply shows a notice`・`an LLM failure shows the error`・`a normal reply works after the failure`。どれも `ok` のはず。`FAILED`・`NG` なら、その確認の `… CHECK FAILED` の行と終了コード (7・9) になる。知らせの文・結果が変わっていない事・仕事が残っていない事を見ている。
- 複数が失敗しても、返る終了コードは 1 つだけ (5 > 6 > 7 > 8 > 9 の順。`ADAPTER MESSAGE CHECK FAILED`・`AUDIT FLOW CHECK FAILED`・`RETRANSLATE CHECK FAILED` は 7 に入る)。終了コードが 5 でも、7 や 8 の失敗が隠れている事がある。`FAILED` の行を全部探す。
- 音を出せない Mac (ふつうの再生で位置が進まない・音声を開けない) では、`UI LOAD: no audio playback here (…)` と `PRACTICE: skipped (no audio playback here)` が出て、1 行の再生と練習の確認は飛ばされる。この時 `PRACTICE CHECK OK` は出ないが、終了コードは 0 になりうる。「練習の確認は走らなかった」と報告する。
- 絵を残せなくても終了コードは変わらない。`UI LOAD: screenshot failed …` の行で分かる。
- 狭い窓の絵 (21・22) を撮る時は、`UI LOAD: narrow window: asked 880, got <実際の横幅> (<絵の名前>)` の行が出る。実際の横幅が 880 より 1 pt を超えて広い時 (中身が窓を押し広げた時) は、`screenshot failed` の行も出る。この時も終了コードは変わらないので、行を見て報告する。
- 測りの行 (2026-11-27 に足した。どれも参考で、目安・「重い」・終了コードには入らない):
  - `UI LOAD: environment: …`: 走らせた Mac の macOS・コアの数・メモリ・画面の倍率。
  - `UI LOAD: append detail "<操作>" k of n: rows A -> B, crosses …, apply … ms, scrollTo calls …, idle after … ms, turns …, row inits …, row bodies …, longest wait before the next append … ms`: 文字起こし中の結果に区間を足す操作ごとの内わけ。`row bodies` が、その操作で作り直した行の数。
  - 3000 行・8000 行の確認の後に、参考の段が走る: `"burst (following, extra)"` 3 回 → 追いかけるのをやめて `"burst (not following)"` 3 回 → `"follow again after 900 rows"`。まとめは `UI LOAD: burst idle after: following median …, following extra median …, not following median …`。
  - `UI LOAD: tail catch-up: on|off (macOS 15 or later: …, KIKIMIMI_TAIL_STEPS: …); bursts caught up in steps k of n; total median … ms, max … ms; longest wait max … ms` (2026-11-28 に足した): 終わりを追いかけている時に 11 行以上がいっぺんに増えると、macOS 15 以降では、末尾へ 10 行ずつ動かして追いつく。`on` の時、追いかけ中の 300 行の回は、内わけの行に `catch-up steps 30, catch-up total … ms` が付き、**目安 (1.5 秒) と比べる値は、合わせた時間ではなく、その間のメインスレッドのいちばん長い待ち** になる。手元 (macOS 14) は `off` で、今までどおり。手元で小刻みの道を通す時は、確認の命令の前に `KIKIMIMI_TAIL_STEPS=1` を付ける (確認の最中だけ効く。`0` は、macOS 15 でも切る)。`UI LOAD: tail catch-up stop check: as expected: …` は、追いつく途中で追いかけをやめると止まる事の確認 (参考。`on` の時だけ走る)。
  - 300 行の回の内わけの行の終わりの `counted X ms (idle|longest wait|longest wait during the catch-up)` (2026-11-28 に足した) は、目安と比べる値と、その元。`idle` = 足してから、メインが空くまでの時間。`longest wait` = その回の始めから、次に足すまでの、メインスレッドのいちばん長い待ち (空いた後に来た重い仕事も、ここに入る)。値は、この 2 つの長いほう。`longest wait during the catch-up` = 小刻みに追いついた回の、いちばん長い待ち。
  - `UI LOAD: note: "burst" k of n at N rows built M row bodies (…)`: 300 行をいっぺんに足した 1 回で、行の body を 100 以上作った時だけ出る。GitHub の Mac (macOS 15) の 8000 行で時々出る (この回が長いと、8000 行の `UI LOAD: SLOW` になる)。手元 (macOS 14) では出ていない。出たら、行の数・body の数・待ちを報告する。調べた事は `docs/HANDOFF-ARCHIVE.md` の 2026-11-27・11-28。
- `REAL SETTINGS:` の行 (`UI LOAD OK`・`LAUNCH SELFTEST OK` の直前): 確認の始めに取った本物の設定の写しと比べ、macOS が確認のあいだに書いた鍵 (ウインドウの位置・大きさ、左の一覧の幅など) を元に戻した結果。`unchanged` は戻す物が無かった事、`put back N keys the system wrote …: <鍵>` は戻した鍵 (どちらも、ふつうの事)。
- `REAL SETTINGS: APP SETTINGS CHANGED DURING THE SELF-TEST (put back): <鍵>` は、アプリの設定 (`SettingKey`) が確認のあいだに書かれた印 (確認用の起動はアプリの設定を書かない決まりが破れている)。元には戻してあり、終了コードは変わらないが、必ず報告し、書いた所を探す。

## 4. 「重い」(SLOW) の読み方

- 目安を超えた物は 1 つにつき 1 行、`UI LOAD: SLOW ("<操作の名前>" p95 … ms >= … ms)` や `max … ms >= … ms` の形で出る。どの値がどの目安を超えたかは、この行の中に在る。目安の値は `Sources/Kikimimi/UILoadLimits.swift` の `Limits`、比べ方は `Sources/Kikimimi/UILoadRun+Measure.swift` の `limitFailures()`。
- 操作ごとの値は `UI LOAD: action "<名前>": n …, median …, p95 …, max …` の行。`n < 20: p95 not checked` と付いた操作は最大だけを比べている。
- 一覧に関わる値: ジョブを選ぶ操作 (`select finished job …`・`select running job`) と再生位置を遠くへ動かす操作 (`jump …`) には `UI LOAD: rows built "<名前>": inits …; bodies …` の行が出る。比べるのは bodies (行の body が動いた数) で、目安は `Limits.selectRowsBuiltMax`。inits は一覧が終わりへ飛ぶと数千になってよく、比べない。bodies が数千なら、一覧が見える分だけを並べていない (CLAUDE.md の一覧の決まりを破った時の形)。
- `UI LOAD: rows built during the measured part: inits …, bodies …` は測った間すべての合計で、目安 (1 回あたり) と比べない。合計が目安の数を超えていても `SLOW` にはならない。
- そのすぐ後の `UI LOAD: row bodies by phase: …`・`row inits by phase: …`・`row bodies by action: …`・`row inits by action: …` は、上の合計の内わけ (段階ごと・操作ごと。終わりの `outside …` は、名前の付いた分を引いた残り)。操作が重なった時は、後から始まった操作に入れている。どの目安とも比べない。
- `UI LOAD: list bodies by action: …` は、一覧そのもの (`TranscriptListView`) の body が動いた回数の、操作ごとの内わけ (2026-11-27 に足した)。
- 一覧の決まり 4 を、回数で見る (2026-11-27 に足した): `time tick`・`current row changes`・`notes edit` (メモを 20 回書き換える)・`practice dictation typing` (練習の書き取りの欄を 20 回書き換える) の 4 つの操作で、一覧の body が 1 回でも動くと `UI LOAD: SLOW ("<操作>" re-ran the list (list bodies N, row inits …, row bodies …; list bodies must be 0): the list body reads …)`、行を作り直すと `UI LOAD: SLOW ("<操作>" rebuilt rows (…))` が出て、終了コード 5 になる。時間ではなく回数なので、測り直しても同じ行が出る。この行が出たら、一覧の body か行が、再生位置・メモ・練習を読んでいる所を探す (別のファイルの関数を通して読む形は、`TranscriptListRulesTests` は見逃すが、ここで止まる)。
- `UI LOAD: row hover changes N (the mouse pointer was inside the main window at k of 9 checks +++…; the app was active at k +++…, the main window was key at k +++…)` は、マウスが行に載った・行から出た回数と、測る部分の始め・各段階の始めと終わり (9 回) で、マウスがウインドウの枠の中に在ったか・アプリが前面 (active) だったか・メインのウインドウがキーだったか (`+` = そうだった、`-` = 違った)。
- **bodies の合計は、「アプリが前面でない」と「マウスが一覧の行の上に在る」の 2 つが重なった時に、高い山になる** (2026-11-22 に手元で確かめた。3000 行・音声つきの 6 回)。前面でなく (`the app was active at 0 ---------`)、`row hover changes` が 113・119 の回は 924・926。前面で、87 の回は 648。前面でなくても、0 の回は 579。差は、どれも `outside the measured actions`・`outside the phases` に出る (測った操作の中の数と、操作ごとの時間は変わらない)。裏の命令から起こした確認用のアプリは、何も触らないと前面にならなかった (この日の 13 回とも)。**合計を前の回と比べる時は、先に、この行の `row hover changes` と `active` を見る** (確認の間、マウスを一覧の上に置かなければ、低い山にそろう)。前面でない時に、マウスが載るたびの描き直しが、なぜ 3 倍ほどになるのかは、調べていない。
- `UI LOAD: samples "<名前>": …` は測った順の値。初めの 1 回だけが遅いのか、毎回遅いのかを見分ける。
- `UI LOAD: stall 1..5` は長かった待ちと、その直前の操作。どの操作が重いかの手がかり。

## 5. 絵の見方 (`build/ui-shots`)

各絵は 1200 x 800 pt のウインドウ (タイトルバーつき。Retina の Mac では 2400x1600 画素)。08・11・12・13・19・20 はシートそのものを撮るので小さく、ウインドウは写らない。21・22 は、窓の横幅をいちばん狭い 880 pt にして撮る (880 x 800 pt。撮った後、窓は元の大きさに戻る)。出力の `UI LOAD: screenshot <名前>.png <幅>x<高さ> (…)` の行で、できたかが分かる。

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
| `19-line-edit.png` | 行を直す画面 (13 の後、11 の前に撮る。直した後に訳し直した形の行を開いたところ)。題「この行を直す」、「聞き取った文」の下に元の文、入力の欄に、初めの 5 字以上の語を「Kikimimi」に置き換えた文、その下に「この直しを覚える」(入) と 2 つの欄 (聞き間違えた語 → Kikimimi)、説明の 1 行、訳が消える注意の 1 行、「聞き取った文に戻す」「キャンセル」「保存」 (保存は押せない形) |
| `20-line-edit-two-segments.png` | 2 つの区間から成る対訳の行の、行を直す画面 (19 の後に撮る。2 つ目の区間を直して訳し直した形)。区間ごとに青い時刻と入力欄、2 つ目の区間だけに「聞き取った文」と元の文、入力欄の末尾が「（確認用に直した）」。訳が消える注意の 1 行と「聞き取った文に戻す」 |
| `21-narrow-bilingual.png` | 横 880 pt の窓 (06 の後に撮る)。終わった対訳のジョブ。2 段目のボタン (やり直す・履歴・監査・残りを翻訳・コピー・書き出す) とチェック (時刻・対訳・メモ) が全部見え、窓の外へ出た物・重なった物が無い。ツールバーの右端は `>>` (入りきらない項目のメニュー) でよい |
| `22-narrow-notes.png` | 横 880 pt の窓で、メモの欄を開いたところ。一覧は 360 pt ほどで、行は縦に長い。訳の列の見出しは、名前 (「日本語訳」) と「要確認 N」が縦に 2 段で、名前が 1 字ずつ折れていない |

| `14-chat-empty.png` | チャットの窓 (480 x 640 pt)。上に灰色の「リサーチ … 切」の帯と「入れる…」、空の案内と例のボタン 3 つ、下に入力の欄と小さな 1 行 |
| `15-chat-research-confirm.png` | リサーチの確認のシート (シートそのもの)。題「自己責任で、リサーチを入れますか？」、Prompt Injection の説明、「キャンセル」(既定) と「自己責任で入れる」 |
| `16-chat-research-on.png` | チャットの窓の上の帯が橙色の「リサーチが入っています (自己責任)…」と「切る」 |
| `17-chat-proposal.png` | 答えの下の札「無音を飛ばす (VAD): オン → オフ」と「変える」「キャンセル」 |
| `18-chat-unavailable.png` | 同じ答えの札 2 枚。1 枚目「無音を飛ばす (VAD): オフ → オン」に「変える」「キャンセル」、2 枚目 (自動でやり直す) は「変える」が無く、理由「先に「無音を飛ばす (VAD)」をオンにしてください。」と「キャンセル」 |

- 12・13 のシートには、23f94f8 (U5) から、下に訳語の 1 行「語を、いつもこう訳す (任意)」が在る (シートのコードでは、いつも出す)。

- 変えた画面に関わる絵を Read で開いて見る。絵の場面ごとの注意 (`… may show no playing tint` など) が出力に在れば、その絵は特に見る。
- 絵に写らない画面 (設定の画面など) を、手で触って確かめる時: ふつうに起動しない (触った設定が、本物の設定に書かれる)。確認用の起動 `build/Kikimimi.app/Contents/MacOS/Kikimimi --selftest-launch 60` を使う (本物の設定に書かない。60 秒で自分で終わる。60 が上限)。値を入れた状態から始めたい時は、`-鍵 値` の引数で渡す (例: `-initialPrompt "…"`。その起動のあいだだけ効く)。入・切の設定は、`-鍵 NO` では切り替わらない (文字列として入り、決まりの値になる)。`-useLedger '<false/>'` のように、真偽の形で渡す (2026-11-24 に、この形で切になる事を画面で見た)。ライブラリとモデルの置き場は、`KIKIMIMI_LIBRARY_DIR`・`KIKIMIMI_MODELS_DIR` で一時フォルダにする。終わったら、`defaults read local.kikimimi.app` の前と後の違いが 0 行である事を見る (2026-11-22、設定の欄の 400 字の上限を、この形で確かめた)。確認用の起動は、macOS が自分で書いた物 (ウインドウの位置・大きさなど) を、終わりに元に戻す。戻した鍵は、出力の `REAL SETTINGS:` の行に出る (`--report <ファイル>` を付けると、ファイルにも残る)。
- 行の画面 (右クリックのメニュー・行の印・直す画面など) を、手で触って確かめる時: 上の確認用の起動は、ライブラリを読まない。**一時フォルダに写した結果を見せたい時は、`KIKIMIMI_LIBRARY_DIR=<一時フォルダ>` を付けて `--selftest-launch 60` で起こす** (ほかの確認用の引数を付けない。その場所を開いて、そこへ保存する。本物の置き場を指している時は、開かない)。順を守る: (1) 確認用の起動を裏で始める → (2) `pgrep -lf "Kikimimi.app/Contents/MacOS/Kikimimi"` で、動いている物が 1 つで、引数に `--selftest-launch` が在る事を見る → (3) それから `open_application` を呼ぶ → (4) 最初の絵で、横の一覧が一時フォルダの結果である事を見てから、触る。**(1) と (3) を同時に送らない**: 起動がまだ動き出していないと、`open_application` が、ききみみをふつうの形で起こし、本物のライブラリが開く (2026-11-22 に、実際に起きた)。引数の無い ききみみ が動いていたら、触らずに、利用者に伝える。終わったら、設定の前後の違いが 0 行である事と、`find "$HOME/Library/Application Support/Kikimimi" -newer <始める前に作ったファイル> -not -type d` が 0 個である事を見る。

## 6. 手元では見ない事 (CI だけが見る)

- 起動の確認 (`--selftest-launch` の 7 通り: シェルから・open で・reopen で・メニューで・何度か強制終了した後・ウインドウの復元 (参考)・ウインドウの無い写しが動いている時の open。ほかに「確認用の実行中の起動」の段)。
- `--selftest-llm`、`--selftest-whisper`。`--selftest-llm` の `audit: N findings, … s, unread M` の `unread` は、LLM の答えを読めなかった所の数 (ふつうは 0。0 でなければ、その行を報告する)。`LLM FAILURE: <名前>: ok|NG (…)` の 6 行 (2026-11-28 に足した) は、本物のエンジンで失敗を起こした確かめ: 途中で切れたモデル・モデルでないファイル・壊れた差分 (と、差分なしでの読み直し)・文脈より長い依頼・途中の中止。どれかが NG なら `SELFTEST FAILED`・終了コード 1。手元で走らせる時は `build/Kikimimi.app/Contents/MacOS/Kikimimi --selftest-llm <モデル.gguf>` (本物のモデルは、読むだけ)。`--selftest-whisper` は、`WHISPER: live segments: n … over … s; most within 0.25 s …, 0.5 s …, 1.0 s …, 3.0 s …; longest gap … s` の行も出す (文字起こしの途中の区間が、その幅の時間の中に、多くていくつ届いたか。参考で、OK・FAILED と終了コードには入らない)。
- `--selftest-chat` (本物の LLM でチャットの答えを測る。手元で走らせるなら `make check-chat LLM=<モデル.gguf>`。`CHAT STREAM OK` (出している途中の文が 2 回以上届き、最後の文が答えと同じ) と、`CHAT FINISH: a tiny limit is reported as cut off: ok`・`CHAT FINISH: a normal answer is reported as complete: ok` (2026-11-28 に足した。答えが長さの上限で切れた事を、エンジンが返すか) の 3 つが揃って、終了コード 0。`CHAT EVAL: <id> ok|NG | <期待> | <答えの始め>` の 16 行と `CHAT EVAL: N/16` は参考で、点では落とさない。`--report <ファイル>` で同じ行をファイルにも書く)。
- `--selftest-llm-queue` (本物の `LLMService` を通して、監査・翻訳の最中にチャットが割り込めるかを見る。手元で走らせるなら `make check-llm-queue LLM=<モデル.gguf>`。割り込みあり・なしで訳と監査の結果が同じ、最中に通った割り込みが 1 つ以上、中止した割り込みが監査・翻訳を止めない、で `LLM QUEUE OK`・終了コード 0。通らない時は `LLM QUEUE FAILED: 理由`・終了コード 1)。LLM の順番待ち (`LLMService.swift`・`LLMInterrupts.swift`) を変えた時は、手元でも走らせる。
- 8000 行のアプリの確認 (参考。失敗にしない)。
- Xcode 16.2 と 26.3 の両方でのビルド (手元の Xcode は 1 つ)。
- macOS 14 の実機での動作は、利用者の Mac でだけ見られる (CI にも無い)。

push の後の build は、`tools/ci-watch/watch-build.sh <run の ID>` で待てる (裏で走らせる。使い方は `tools/ci-watch/README.md`)。列が「取り消し (cancelled) で、ランナーの名前が空」の時は、GitHub の Mac が付かなかっただけで、コードの失敗ではない。この道具は、走らせ直す命令 (`gh run rerun <run の ID> --repo tokoinx/Kikimimi --failed`) を出すだけで、自分では走らせ直さない (2026-11-28 に変えた。確認の出る命令を、台本で包まないため)。出た命令を、そのまま打つ (門の確認が出る)。失敗 (failure) の列の時は、命令を出さないので、ログを読む。

## 7. 報告に入れる物

- 走らせた命令 (全文)。
- `swift test` の件数と失敗の数 (`Executed … tests, with … failures` の行から写す)。
- アプリの確認で 3 つの文が出たか、それぞれ。終了コード。`SLOW`・`FAILED`・`skipped` の行があれば、その行。
- 開いた絵の名前と、写っていた物。
- 走らせなかった確認 (6 の CI だけの物、飛ばされた練習の確認など) と、その理由。
