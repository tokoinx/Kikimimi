# 翻訳の評価 (13 言語)

ききみみの翻訳 (Mac の中で動く小さな LLM) の質を、訳す先 13 言語で、同じ物差しで測るための道具です。
モデル・指示文・追加学習の差分を変えた時に、どの言語で良くなり、どの言語で悪くなったかを数で確かめます。

## 手順

1. **問題を取ってくる** (初回だけ。インターネットを使うのはここだけ):

   ```bash
   python3 tools/translation-eval/fetch_wmt24pp.py
   ```

   `build/translation-eval/cache/` に元のファイル (12 個、合わせて 14 MB ほど) を取り、`build/translation-eval/sets/` に問題を作ります。
   - `en-<訳す先>.json` (12 個): 英語 → ja・zh・ko・es・fr・de・it・pt・ru・vi・th・id
   - `ja-en.json`: 日本語 → 英語
   - `selection.json`: 選んだ行の一覧 (どの言語でも同じ行)

   既定では、領域 speech と social から 15 行ずつ、1 言語 30 行です。`--per-domain 30`・`--domains speech,social,news` で変えられます。
   同じ引数なら、毎回同じ行を選びます (`--seed`)。もう取ってあるファイルは、取り直しません。

2. **アプリを組み立てる**: `make app` (`build/Kikimimi.app` ができます)。

3. **回す**:

   ```bash
   python3 tools/translation-eval/evaluate.py --model ~/Library/Application\ Support/Kikimimi/Models/LLM/qwen3.5-4b.gguf
   ```

   問題ごとにアプリの評価ハーネス (`--eval-llm`) を走らせ、結果を `build/translation-eval/results/<モデルの名前>-<日時>/` に置きます。
   - `<問題>.json`: 評価ハーネスの結果 (`--report`)。`<問題>.log`: その出力
   - `summary.md`・`summary.json`: 訳す先ごとの表

   一部だけ測るなら `--targets fr,th,en`。追加学習の差分は `--adapter`、学習した直しは `--ledger`、GPU を使わないなら `--cpu` (アプリにそのまま渡します)。
   1 つの問題が失敗しても、ほかは続けます。失敗は終わりに並べます。

4. **比べる**: 前の結果のフォルダを `--baseline` に渡すと、同じ名前の問題の結果と比べます。

   ```bash
   python3 tools/translation-eval/evaluate.py --model <新しいモデル.gguf> --baseline build/translation-eval/results/<前の結果>
   ```

   訳す先ごとに、訳せた行・その言語だった行・残った数字・残った語が減った、写し・繰り返しが増えた、chrF が 1 点より大きく下がった、
   のどれかで「悪い」と表に出ます (アプリは終了コード 3)。
   問題の数か行の数が前の結果と違う問題 (問題を作り直した後など) は比べず、表に「比べられない」と書きます。

5. **採点し直す** (LLM を回さない): 結果には、問題ごとの LLM の訳そのもの (`translationOutputs`) が残ります。
   採点の決まりを直した後は、測り直さずに、前の結果のフォルダを今の決まりで採点し直せます。
   新しいフォルダ (既定は `<元のフォルダ>-rescored`、`--out` で変えられます) に結果と `summary.md`・`summary.json` を作り、元のフォルダは変えません。
   `--baseline` とも一緒に使えます。訳が残っていない古い結果は、失敗として並べます (測り直してください)。

   ```bash
   python3 tools/translation-eval/evaluate.py --rescore build/translation-eval/results/<前の結果>
   ```

6. **訳の関門を測る** (LLM を回さない): 訳に「要確認」の印を付ける関門 (`TranslationGate`) を、フォルダの中のファイルの全部に掛けます。

   ```bash
   python3 tools/translation-eval/evaluate.py --gate build/translation-eval/sets --out build/translation-eval/results/gate-sets
   python3 tools/translation-eval/evaluate.py --gate build/translation-eval/results/<結果> --out build/translation-eval/results/<結果>-gate
   ```

   問題のフォルダなら、人の訳に誤って付いた印の数と、人の訳を機械的に壊した訳 (数を消す・原文を写す・別の言語・繰り返し・空・短く切る) を拾った数を、
   結果のフォルダなら、LLM の訳に付いた印の数と、印の有る・無いまとまりの chrF を出します。
   `--out` (既定は、そのフォルダ) に `gate.md`・`gate.json` (印の付いたまとまりの原文・訳・符号) を作ります。

## 自己改善の輪 (利用者の直しで、前より良いかを測る)

追加学習なしで回す輪です。LLM を回すのは 3 だけです。

1. **直しをためる**: アプリの対訳の行で、訳を直す・「この訳でよい」を押す。直した訳は訳の記憶 (`translation-memory.json`) に入り、
   5 件に 1 件は評価用に取り分けられます (`heldOut`)。「この訳でよい」が多い検査は、その言語で印を出さなくなります
   (設定の「覚えた訳」の「印を出さなくなった検査」。[元に戻す] で戻せます)。
2. **取り分けた直しを、問題にする** (LLM なし):

   ```bash
   build/Kikimimi.app/Contents/MacOS/Kikimimi --export-translation-eval build/translation-eval/sets-memory/memory.json \
     [--memory <translation-memory.json>]
   ```

   取り分けた直しだけを、1 件 = 1 場面 (原文 1 行、人の訳 = 直した訳) の問題にします。訳す先ごとの件数を出します。
   `--memory` が無ければ、アプリの今の記憶 (`~/Library/Application Support/Kikimimi/translation-memory.json`) を読みます。0 件でも、空の問題を作って終了コード 0 です。
3. **記憶を渡して測る**: `evaluate.py --model <GGUF> --memory <translation-memory.json> --baseline <前の結果>`
   (アプリの `--eval-llm … --memory` にそのまま渡します)。翻訳に、記憶の文・訳語の対・止めた検査を渡します。
   ただし問題の行と同じ文は、記憶から抜いて測ります (答えを見て訳す事になるため)。記憶に当たった行の数は、結果の `reused` に残ります。
4. **判定を見る**: `--baseline` と比べると、summary.md の末尾・標準出力・summary.json の `verdict` に判定が出ます。
   - 訳す先ごと: 30 行に満たない → 「参考 (行が少ない)」。悪くなった (下の「比べる」の決まり) → 「悪くなった」。
     chrF が前より 1.0 より大きく上がった → 「良くなった」。ほか → 「変わらない」。前の結果と比べていない → 「比べられない」。
   - 全体: 「悪くなった」が在る → 「採らない」。無く、「良くなった」が 1 つ以上 → 「採る」。どちらでもない → 「変わらない (採る理由が無い)」。
   - 秒/行が前の 1.10 倍を超えた訳す先は「遅くなった」と知らせます (判定には入れません。秒は、同時に走る作業で揺れるため)。
   - `evaluate.py` の終了コードは、判定では変わりません (失敗した問題が在る時だけ 1)。
5. **基準を残す**: 採った結果を、リポジトリの `tools/translation-eval/baselines/<名前>/` に写します (`build/` は git に入らないため)。

   ```bash
   python3 tools/translation-eval/evaluate.py --save-baseline <名前> --from build/translation-eval/results/<結果>
   ```

   測り・採点し直しと一緒に `--save-baseline <名前>` を付けると、その結果を写します。もう在る名前には上書きしません。
   次からは `--baseline tools/translation-eval/baselines/<名前>` で比べます。

## 表の読み方

| 列 | 意味 |
|---|---|
| 行 | 問題の行の数 |
| 訳せた | 訳が付いた行 |
| その言語 | 訳が、訳す先の言語だった行。日本語は文字の種類で見ます。ほかの言語は macOS の言語の判定 (NaturalLanguage) で見ます。8 字に満たない訳は判定しません (合っていると数えます) |
| 数・語 | 原文の 2 桁以上の数字・残すべき語が、訳に残った数 / 確かめた数 |
| 写し | 訳が、原文をそのまま写しただけだった行 |
| 繰り返し | 同じ語句の繰り返しが異常に多い訳 (空白を除いて、3 字以上の同じ並びが 5 回以上続く) |
| chrF | 人の訳との近さ (0〜100。高いほど近い) |
| 秒/行 | 1 行あたりの時間 (モデルの読み込みは含みません) |

- **chrF は、コーパスの点です**: 文ごとの数え (文字の 1〜6 字の並びの一致) を全部足してから 1 回計算します。sacreBLEU の `CHRF()` の既定と同じ値です。
  1 文ごとの点は揺れが大きいので、当てにしません。30 行の点でも、1〜2 点の差は揺れの内です。
- 言語どうしで chrF を比べるのは、目安だけにしてください (言語によって、点の出やすさが違います)。同じ言語で、モデルや差分の前後を比べるのに使います。
- **ja-en は参考の値です**: WMT24++ の日本語は、英語から人が訳した文です。日本語で話された文とは違うので、日本語 → 英語の本当の力とは、ずれがあります。
- 訳は、アプリと同じく、文の途中で切れた行をまとめて 1 つの文として訳します。まとめて訳した行は、その行ぶんの人の訳をつないだ物と比べます。

## 訳語の対の問題 (`Tests/Fixtures/llm-eval/translation-terms.json`)

訳語の対 (`terms`、設定の「訳語」) つきの小さな問題です (英語 → 8 言語の 8 場面と、日本語 → 英語の 2 場面)。
測るのは「指示した訳語を LLM が使うか」だけで、訳語そのものの良し悪しを決める物ではありません
(対は、わざと LLM が黙っていると選ばなさそうな訳語にしてあります。人の訳 `references` は無く、chrF は出ません)。
対を渡した時と渡さない時の `termsKept` を比べます: `--eval-llm <model.gguf> --set Tests/Fixtures/llm-eval/translation-terms.json` と、
同じ物に `--no-terms` を付けた物 (`evaluate.py` にも `--no-terms` が在り、アプリにそのまま渡します)。

## かかる時間の目安

既定の問題は 13 個 × 30 行 = 390 行です。1 行に数秒かかるとして、合わせて 15〜40 分ほど (モデルの大きさと Mac による) に、
問題ごとのモデルの読み込みが加わります。まず `--targets` で 1〜2 言語だけ回して、1 行あたりの秒を確かめてください。

## データの出典とライセンス

- WMT24++ (Deutsch ほか, 2025, "WMT24++: Expanding the Language Coverage of WMT24 to 55 Languages & Dialects")。
  Hugging Face の [google/wmt24pp](https://huggingface.co/datasets/google/wmt24pp)。ライセンスは Apache-2.0。
- 使うのは、`is_bad_source` が付いた行と `canary` を除いた行の、原文 (`source`) と、人が直した訳 (`target`) です。
- 取ってきたファイルと問題は `build/` の中に置き、リポジトリには入れません。
