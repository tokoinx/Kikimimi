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
   今の基準は 2 つです。どちらも Qwen3.5 4B で、文に分けて訳し直す仕組みを入れた後の物です。
   - 1 言語 30 行 (既定の問題 `build/translation-eval/sets`): `baselines/qwen3.5-4b-20261116/` (入れる前は `baselines/qwen3.5-4b-20261116-before-split-retry/`)。
     比べ方: `--baseline tools/translation-eval/baselines/qwen3.5-4b-20261116`。
   - 1 言語 100 行 (下の「100 行で測る」の問題): `baselines/qwen3.5-4b-100-20261116/`。
     比べ方: `--sets build/translation-eval-100/sets --baseline tools/translation-eval/baselines/qwen3.5-4b-100-20261116`。

## 100 行で測る (採る・採らないを決める時)

30 行では 1〜2 点は揺れるので、採る・採らないは 1 言語 100 行で決めます。100 行の問題は、30 行の問題と別のフォルダに作ります。

```bash
python3 tools/translation-eval/fetch_wmt24pp.py --per-domain 50 --out build/translation-eval-100
python3 tools/translation-eval/evaluate.py --model <GGUF> --sets build/translation-eval-100/sets \
  --baseline tools/translation-eval/baselines/qwen3.5-4b-100-20261116
```

- 領域 speech・social から 50 行ずつ、種は既定の 20241 です。
- **30 行の問題は、100 行の問題の一部ではありません** (行の選び方が違います)。30 行と 100 行の値を、じかに比べないでください。
  比べるのは、同じ問題のフォルダで測った結果どうしだけです。
- 13 個 × 100 行は、Qwen3.5 4B・M1 で 257 分かかりました (2026-11-16。ほかの作業が同時に走り、数分止めた時間も含むので、秒/行は当てにしていません)。
- 2026-11-16 の値 (chrF): de 57.17・es 65.72・fr 61.69・id 57.99・it 62.69・ja 29.06・ko 28.73・pt 63.32・ru 52.28・th 42.76・vi 53.61・zh 35.52・ja→en 47.46 (参考)。
  文に分けた訳し直しを切 (`--no-split-retry`) にした 5 言語の値は、de 55.07・ja 26.71・ko 27.34・th 40.44・zh 34.67 (道具の判定は、入れた後を「採る」)。ほかの 8 言語は、100 行では切を測っていません。

## 似た文を手本にする実験 (既定は切)

記憶の中の、送る行に似た文 (原文どうしの chrF が 30 以上。取り分けた文・問題と同じ文・200 字を超える文は使わない) を、
多くて N 件、手本として指示文に足します。アプリの翻訳は切のままです (`TranslationOptions.memoryExamples` = 0)。
2026-11-16 に測りました (Qwen3.5 4B、日本語・韓国語・中国語・タイ語 × 100 行、手本は多くて 2 件、見立ての記憶は訳す先ごとに 300 文、65 分)。
chrF (手本なし → 手本あり) は、ja 29.06 → 29.25、ko 28.73 → 28.61、th 42.76 → 42.80、zh 35.52 → 35.27。道具の判定は、4 言語とも「変わらない」、全体は「変わらない (採る理由が無い)」でした。
ただし、手本が付いた呼び出しは、どの言語も、まとまり 72 個のうち 5 個 (各 1 件) だけでした (見立ての記憶に、似た文が少なかったため)。「似た文が在る時に、手本が効くか」は、この測りでは分かりません。
アプリでは切のままにします。

1. **見立ての記憶を作る** (評価の問題に入っていない WMT24++ の行。`--same-documents` で、問題と同じ文書の行を先に選ぶ):
   `python3 tools/translation-eval/make_memory.py --cache build/translation-eval-100/cache --sets build/translation-eval-100/sets --same-documents --out <記憶.json>`
2. **手本を入にして測る**: `evaluate.py --model <GGUF> --sets build/translation-eval-100/sets --memory <記憶.json> --examples 2 --baseline <比べる結果>`
   (アプリの `--eval-llm … --memory … --examples 2` にそのまま渡します。`--examples` には `--memory` が要ります)。
   手本を足した呼び出しの数は、結果の `examplesUsed` に残ります。
3. **比べる**: 記憶の文に同じ文が在る行は再利用 (`reused`) にも効くので、手本だけの効き目は、同じ記憶で `--examples` を付けない測りを
   `--baseline` にして比べます。

この記憶は見立て (WMT24++ の人の訳) で、利用者が本当に直した訳ではありません。

## ほかのモデルを測った記録

- **Hy-MT2 7B** (`Hy-MT2-7B-Q4_K_M.gguf`、4.62 GB。2026-11-16、M1): アプリの今の指示文のまま `--model` に渡して測ると、ほとんど訳せませんでした。
  en-de は 30 行のうち訳せた行 4・chrF 3.06 (Qwen3.5 4B の基準は 57.58)・920.7 秒 (30.69 秒/行)、en-es は訳せた行 4・chrF 4.07。
  2 言語が終わった所で止めました (残りの 11 言語は測っていません)。先に 9 行だけ試した時は、9 行のうち 7 行が訳せ、数は 1/3、111.3 秒でした。
  - Hy-MT2 の元の指示文は、1 つの文を渡して訳させる形で、アプリの指示文 (番号つきの行をまとめて渡す形) と違います。
    この測りでは、モデルの訳の質そのものは分かりません。Hy-MT2 の指示文で訳す口は、作っていません (作るなら、コードの変更が要ります)。
  - 結果は手元の `build/translation-eval/results/hymt2-7b-20261116/` (2 言語分。git に入りません)。モデルは Qwen3.5 4B のままです。
- Hy-MT2 1.8B・TranslateGemma は、取っていないし、測っていません。

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
