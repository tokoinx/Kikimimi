# 翻訳の評価の基準 (baselines)

`evaluate.py` の結果のうち、「この結果を、次の比べの元にする」と決めた物を置きます。
結果のフォルダ (`build/translation-eval/results/…`) は `build/` の中なので git に入りません。基準は、ここに写して残します。

## 置く物

`<名前>/` のフォルダ 1 つが、基準 1 つです。中身は、結果のフォルダから写した物だけです。

- `summary.json`・`summary.md`: 訳す先ごとの表 (と、比べた時の判定)
- `<問題>.json`: 問題ごとの、アプリの評価ハーネスの結果 (`--report`)。LLM の訳そのもの (`translationOutputs`) を含むので、
  採点の決まりを直した後も `--rescore` で採点し直せます
- 出力の記録 (`.log`) と、関門の測り (`gate.json`) は写しません

名前は、何を測ったかが分かる物にします (例: `qwen3.5-4b-2026-11-16`)。英数字と `.` `_` `-` だけです。

## 今ある基準

- `qwen3.5-4b-20261116-before-split-retry/`: Qwen3.5 4B、1 言語 30 行、文に分けて訳し直す仕組み (U4) を入れる前。
- `qwen3.5-4b-20261116/`: Qwen3.5 4B、1 言語 30 行、U4 を入れた後 (30 行の今の基準)。
- `qwen3.5-4b-100-20261116/`: Qwen3.5 4B、1 言語 100 行 (領域ごとに 50 行、種 20241)、U4 を入れた後 (100 行の今の基準)。
  比べ方: `--sets build/translation-eval-100/sets --baseline tools/translation-eval/baselines/qwen3.5-4b-100-20261116`。
  30 行の問題は 100 行の問題の一部ではないので、30 行の基準とは比べません。

## 写し方

```bash
python3 tools/translation-eval/evaluate.py --save-baseline <名前> --from build/translation-eval/results/<結果>
```

測り (`--model`)・採点し直し (`--rescore`) と一緒に `--save-baseline <名前>` を付けると、その結果を写します。
もう在る名前には上書きしません (前の基準を残すため。新しい名前を付けてください)。

## 比べ方

```bash
python3 tools/translation-eval/evaluate.py --model <GGUF> --baseline tools/translation-eval/baselines/<名前>
```

同じ名前の問題の結果と比べ、summary.md の末尾に判定 (採る・採らない) を出します。決まりは `../README.md` の「自己改善の輪」に在ります。
問題の数か行の数が違う問題 (問題を作り直した後など) は、比べずに「比べられない」と出します。
chrF は、同じモデル・同じ問題の前後を比べるのにだけ使います。
