#!/usr/bin/env python3
r"""ききみみの監査役・翻訳役 (ローカル LLM) を、この Mac の中で追加学習 (LoRA) する。

    python3 tools/finetune/finetune.py --data ~/Desktop/kikimimi-training.jsonl --model qwen3.5-2b

流れ:
  1. 学習データ (ききみみの設定「学習用のデータを書き出す…」か `Kikimimi --export-training` で作った .jsonl) を、学習用と確認用に分ける。
     確認用の例からは、評価の場面も作る (学習に使っていない並びの行)
  2. MLX (mlx-lm) で LoRA を学習する。対象は各層の MLP だけ (GGUF にそのまま変えられる重み)。学習するのは「答え」のところだけ
  3. 学習した差分を、ききみみ (llama.cpp) が読める GGUF に変える
  4. 評価ハーネス (`Kikimimi --eval-llm`) で、差分なし / 差分ありを同じ場面で比べる
     (ききみみに付いている場面と、1 で作った自分の直しの場面)
  5. 直せた行が増え、悪くなったところが無ければ、ききみみの差分の置き場所に入れる (`--install`)。
     誤った直しが出る・正しい行を壊す・直せた行が増えない差分は、入れない

翻訳の追加学習 (`--task translation`。既定は `--task audit` で、上の流れのまま):
  差分は、監査用 (`<model>.lora.gguf`) と翻訳用 (`<model>.translation.lora.gguf`) に分かれている。アプリは、監査には
  監査用、翻訳には翻訳用だけを使う (監査を学習した差分が、訳の固有名詞を崩した例が在ったため)。
  1. 学習データ: 訳の記憶の、取り分け (heldOut) でない文から作る (LLM は使わない)
         build/Kikimimi.app/Contents/MacOS/Kikimimi --export-translation-training build/finetune-tr/train.jsonl \
             --memory ~/Library/Application\ Support/Kikimimi/translation-memory.json --memory <見立ての記憶.json>
     (見立ての記憶は tools/translation-eval/make_memory.py で WMT24++ から作れる)
  2. 評価の問題: 取り分けの問題 (`Kikimimi --export-translation-eval <出力.json> --memory <記憶>`) と、
     見張りの問題 (WMT24++ の en-ja など。tools/translation-eval/fetch_wmt24pp.py で作った sets/*.json)。
     確認用の例からは評価の場面を作らないので、`--eval-set` を 1 つ以上渡す (必須)
  3. 学習・途中の差分・GGUF への変換は、監査と同じ道。途中の差分の数 (`--checkpoints`) の既定は 3
     (翻訳の評価は長い。4B で 1 行あたり約 11 秒 × 問題の行 × (候補 + 差分なし))
  4. 評価: 問題 1 つずつ、差分なしと候補ごとに `Kikimimi --eval-llm … --set <問題> [--adapter <候補> --baseline <差分なし>]`
     を走らせ、訳す先ごとに比べる。判定の決まりは tools/translation-eval/evaluate.py の `row_verdict`・`judge` を
     そのまま読み込んで使う (行が 30 未満は参考、アプリが悪くなったとした問題は悪くなった、chrF が 1.0 より大きく
     上がれば良くなった)。「悪くなった」が 1 つも無く、「良くなった」が 1 つ以上の候補だけが採れる。採れる候補が
     複数なら、良くなった訳す先の chrF の上がり幅の合計が大きい物、同じなら回数の少ない物
  5. `--install` で、翻訳用の置き場 (Adapters/<model>.translation.lora.gguf) に入れる

         .venv-finetune/bin/python tools/finetune/finetune.py --task translation --model qwen3.5-4b \
             --data build/finetune-tr/train.jsonl --out build/finetune-tr \
             --eval-set build/finetune-tr/heldout.json --eval-set build/translation-eval/sets/en-ja.json --install

  `--base-report <フォルダ>` を付けると、差分なしの評価は、そのフォルダの `<問題の名前>.json`
  (無ければ `eval-base-<問題の名前>.json`。前の実行の作業用のフォルダ) を使う。

必要なもの (Apple シリコンの Mac):
    python3 -m venv .venv-finetune
    .venv-finetune/bin/pip install "mlx-lm[train]" gguf numpy
    .venv-finetune/bin/python tools/finetune/finetune.py …

音声・文字起こし・学習データは Mac の外に出ない。インターネットを使うのは、学習用のモデル (MLX 形式) を
Hugging Face から初めて取るときだけ。
"""
import argparse
import json
import os
import platform
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

# ききみみの LLM の ID → 学習に使う MLX 形式のモデル (同じ Qwen3.5 を 4 bit にしたもの)
MLX_MODELS = {
    "qwen3.5-0.8b": "mlx-community/Qwen3.5-0.8B-4bit",
    "qwen3.5-2b": "mlx-community/Qwen3.5-2B-4bit",
    "qwen3.5-4b": "mlx-community/Qwen3.5-4B-4bit",
    "qwen3.5-9b": "mlx-community/Qwen3.5-9B-4bit",
}
# 学習に必要なメモリの目安 (GB)。足りないと、とても遅くなるか止まる
MEMORY_NEEDED = {"qwen3.5-0.8b": 4, "qwen3.5-2b": 8, "qwen3.5-4b": 16, "qwen3.5-9b": 32}
LLM_DIR = Path.home() / "Library/Application Support/Kikimimi/Models/LLM"
EMPTY_THINK = "<think>\n\n</think>\n\n"
# 学習の 1 例の長さの上限 (トークン)。mlx-lm は、これより長い例の終わり (= 答え) を切り捨てる
MAX_SEQ_LENGTH = 1024


def fail(message):
    raise SystemExit("✗ " + message)


def memory_gb():
    try:
        return int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) // 2**30
    except (ValueError, OSError):
        return 0


def eval_case(messages, case_id):
    """確認用の学習例 (監査役への問いと答え) を、評価ハーネスの場面 (行と、直した後の行) にする。評価役への問いは None"""
    user, answer = messages[-2]["content"], messages[-1]["content"]
    if "Lines to check:\n" not in user:
        return None
    lines = [re.sub(r"^\[\d+\] ", "", line) for line in user.split("Lines to check:\n", 1)[1].split("\n") if line.strip()]
    expected = list(lines)
    for match in re.finditer(r"^\[(\d+)\] FIX (.+?) => (.+)$", answer, flags=re.MULTILINE):
        k = int(match.group(1)) - 1
        if 0 <= k < len(expected):
            expected[k] = expected[k].replace(match.group(2), match.group(3), 1)
    system = messages[0]["content"] if messages[0]["role"] == "system" else ""
    language = "ja" if "mostly in Japanese" in system else ("en" if "mostly in English" in system else None)
    if language is None:
        language = "ja" if re.search("[\u3040-\u30ff\u4e00-\u9fff]", "".join(lines)) else "en"
    return {"id": case_id, "language": language, "lines": lines, "expected": expected}


def split_data(data, work, seed):
    """学習用と確認用に分ける (確認用は 15%、最低 4 件)。確認用の例からは、評価の場面も作る
    (学習に使っていない並びの行で、自分の直しを覚えたか・直す必要のない行を直していないかを測る)"""
    rows = [line for line in Path(data).read_text(encoding="utf-8").splitlines() if line.strip()]
    for n, row in enumerate(rows, 1):
        try:
            messages = json.loads(row)["messages"]
            assert [m["role"] for m in messages][-2:] == ["user", "assistant"]
        except (ValueError, KeyError, AssertionError, TypeError):
            fail(f"{data} の {n} 行目が、学習データの形 (messages: system / user / assistant) ではありません。")
    if len(rows) < 12:
        fail(f"学習データが {len(rows)} 件しかありません。少なすぎると丸暗記になるだけなので、12 件以上になってから試してください "
             "(数件の直しは、追加学習をしなくても「学習した直し」がそのまま当てます)。")
    random.Random(seed).shuffle(rows)
    n_valid = max(4, len(rows) * 15 // 100)
    out = Path(work) / "data"
    out.mkdir(parents=True, exist_ok=True)
    (out / "valid.jsonl").write_text("\n".join(rows[:n_valid]) + "\n", encoding="utf-8")
    (out / "train.jsonl").write_text("\n".join(rows[n_valid:]) + "\n", encoding="utf-8")
    cases = [c for c in (eval_case(json.loads(row)["messages"], f"own-{n}") for n, row in enumerate(rows[:n_valid])) if c]
    own = Path(work) / "eval-own.json"
    own.write_text(json.dumps({"name": "own", "audit": cases, "translation": []}, ensure_ascii=False, indent=1), encoding="utf-8")
    fixes = sum(1 for c in cases if c["lines"] != c["expected"])
    print(f"▸ 学習データ {len(rows) - n_valid} 件、確認用 {n_valid} 件 (うち評価の場面 {len(cases)}: 直す行のある場面 {fixes})")
    return out, json.loads(rows[0])["messages"], len(rows) - n_valid, (own if cases else None)


def check_template(mlx_model, sample):
    """学習のときの文の組み立てが、ききみみが LLM に渡す形 (答えの前に空の <think>) と同じかを確かめる"""
    from mlx_lm import load

    _, tokenizer = load(mlx_model)
    text = tokenizer.apply_chat_template(sample, tokenize=False)
    answer = sample[-1]["content"]
    if EMPTY_THINK + answer not in text:
        print("⚠ このモデルの会話の型は、ききみみの渡し方 (答えの前に空の <think>…</think>) と違います。"
              "学習はできますが、効き目が弱くなることがあります。")
        print("  組み立てた文の終わり: " + repr(text[-160:]))
    else:
        print("▸ 会話の型は、ききみみの渡し方と同じです")
    if app_chat_tokens(tokenizer, sample) is not None:
        print(f"▸ 手本のやりとり {(len(sample) - 3) // 2} 組つきの例は、ききみみが送るのと同じ ChatML の文に組み立てます")
    # 学習の対象が、答えだけになっているか
    from mlx_lm.tuner.datasets import ChatDataset

    mask_only_the_answer()
    tokens, offset = ChatDataset([{"messages": sample}], tokenizer, mask_prompt=True).process({"messages": sample})
    trained = tokenizer.decode(list(tokens[offset:]))
    if trained.startswith(answer.strip()):
        print("▸ 学習の対象は、答えだけです: " + repr(trained))
    else:
        print("⚠ 学習の対象が、答えだけになっていません (効き目が弱くなります): " + repr(trained[:120]))
    return tokenizer


def answer_offset(tokenizer, messages, tokens, fallback):
    """学習の対象にする「答え」が、トークンの列の何番目から始まるか。

    mlx-lm は「答えの前まで」を、答えの無い会話を組み立てて数える。Qwen3.5 の会話の型では、それが
    「…assistant\n<think>\n」で終わる (考える前提) ので、答えのある会話の「<think>\n\n</think>\n\n答え」と食い違い、
    「</think>」から後ろが学習の対象になる。ききみみは、空の <think>…</think> までを問いとして渡し、答えだけを
    書かせるので、学習も答えだけにする (そうしないと、「考えずに閉じる」ことを覚えるのに学習を使い切る。
    GitHub の Mac での確認では、検証の損失が 2.9 → 0.3 に下がっても、答えは何も変わらなかった)
    """
    answer = messages[-1]["content"].strip()  # 会話の型は、答えの前後の空白と改行を落とす
    text = tokenizer.apply_chat_template(messages, tokenize=False)
    cut = text.rfind(answer) if answer else -1
    if cut <= 0:
        return fallback
    head = tokenizer.encode(text[:cut], add_special_tokens=False)
    return len(head) if list(tokens[:len(head)]) == list(head) else fallback


def app_chat_tokens(tokenizer, messages):
    """手本のやりとりつきの例 (system・(user・assistant) × 手本・user・assistant) を、ききみみが LLM に送るのと同じ
    ChatML の文にして、(トークン, 答えの始まる位置) を返す。使えない時は None (mlx-lm のふつうの組み立てに任せる)。

    会話の型 (Qwen3.5 の chat_template) は、前の会話の答えの前後の改行を落とす。ききみみ (LlamaEngine の ChatML) は
    手本の答えを「[3] …\n<|im_end|>」とそのまま送るので、型に任せると、学習の時と使う時で手本の文が 1 字ずつ違う。
    そこで、ききみみと同じ並べ方で組み立てる: 手本の答えには <think> を付けず、最後の答えの前にだけ空の <think> を置く。
    最後の答えの後ろは、会話の型と同じく「<|im_end|>\n」(答えの前後の空白は落とす)。
    会話が 3 つ (system・user・assistant) の例 (監査) は、ここを通らない (今までどおり)"""
    if len(messages) <= 3 or "<|im_start|>" not in (getattr(tokenizer, "chat_template", None) or ""):
        return None
    if messages[0]["role"] != "system" or [m["role"] for m in messages[1:]] != ["user", "assistant"] * ((len(messages) - 1) // 2):
        return None
    prompt = "<|im_start|>system\n" + messages[0]["content"] + "<|im_end|>\n"
    for user, assistant in zip(messages[1:-2:2], messages[2:-2:2]):
        prompt += ("<|im_start|>user\n" + user["content"] + "<|im_end|>\n<|im_start|>assistant\n"
                   + assistant["content"] + "<|im_end|>\n")
    prompt += "<|im_start|>user\n" + messages[-2]["content"] + "<|im_end|>\n<|im_start|>assistant\n" + EMPTY_THINK
    head = tokenizer.encode(prompt, add_special_tokens=False)
    tokens = tokenizer.encode(prompt + messages[-1]["content"].strip() + "<|im_end|>\n", add_special_tokens=False)
    if list(tokens[:len(head)]) != list(head):
        return None
    return tokens, len(head)


def drop_long_examples(tokenizer, data_dir, limit=MAX_SEQ_LENGTH):
    """train.jsonl・valid.jsonl から、limit トークンより長い例を外す (翻訳だけで使う)。
    mlx-lm は長い例の終わりを切り捨てるので、そのままだと答えの無い (途中で切れた) 例を学習してしまう。
    返すのは (学習用の残りの数, 外した数)"""
    from mlx_lm.tuner.datasets import ChatDataset

    mask_only_the_answer()
    kept_train, dropped, longest = 0, 0, 0
    for name in ("train.jsonl", "valid.jsonl"):
        path = Path(data_dir) / name
        rows = [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        kept = []
        for row in rows:
            messages = json.loads(row)["messages"]
            tokens, _ = ChatDataset([{"messages": messages}], tokenizer, mask_prompt=True).process({"messages": messages})
            longest = max(longest, len(tokens))
            if len(tokens) > limit:
                dropped += 1
            else:
                kept.append(row)
        if not kept:
            fail(f"{name} の例が、どれも {limit} トークンより長くなりました。短い文の記憶で作り直してください。")
        path.write_text("\n".join(kept) + "\n", encoding="utf-8")
        if name == "train.jsonl":
            kept_train = len(kept)
    print(f"▸ {limit} トークンより長い例 {dropped} 件を外しました (長さの最大 {longest})" if dropped
          else f"▸ 例は、どれも {limit} トークンに収まります (長さの最大 {longest})")
    return kept_train, dropped


def mask_only_the_answer():
    """mlx-lm の学習データの読み方を、答えだけを学習の対象にするものに差し替える"""
    import mlx_lm.tuner.datasets as datasets

    original = datasets.ChatDataset.process
    if getattr(original, "kikimimi", False):
        return

    def process(self, d):
        # 手本のやりとりつきの例 (翻訳) は、ききみみが送るのと同じ文に組み立てる (app_chat_tokens)
        own = app_chat_tokens(self.tokenizer, d[self.chat_key])
        if own is not None:
            tokens, offset = own
            return tokens, (offset if self.mask_prompt else 0)
        tokens, offset = original(self, d)
        if self.mask_prompt:
            offset = answer_offset(self.tokenizer, d[self.chat_key], tokens, offset)
        return tokens, offset

    process.kikimimi = True
    datasets.ChatDataset.process = process


def answer_only_loss(model, batch, lengths):
    """mlx-lm の損失と同じ。ただし、学習例の終わりの次 (詰め物) は数えない。

    mlx-lm は「答えの始まり ≦ 位置 ≦ 例の長さ」を対象にするので、例の終わりの次の 1 つ (詰め物のトークン 0) を
    当てることまで学習する。数千トークンを学習するふつうの使い方では誤差だが、答えだけ (3〜12 トークン) を学習する
    ここでは、その 1 つが損失の大半になる (学習前の検証の損失が、PyTorch の 0.36 に対して 3.9 だった)"""
    import mlx.core as mx
    import mlx.nn as nn

    inputs = batch[:, :-1]
    targets = batch[:, 1:]
    logits = model(inputs)
    steps = mx.arange(1, targets.shape[1] + 1)
    mask = mx.logical_and(steps >= lengths[:, 0:1], steps < lengths[:, 1:])
    ce = nn.losses.cross_entropy(logits, targets) * mask
    ntoks = mask.sum()
    ce = ce.astype(mx.float32).sum() / ntoks
    return ce, ntoks


def use_answer_only_loss():
    """mlx-lm の学習と検証が使う損失を、answer_only_loss に差し替える。差し替えた数を返す"""
    import mlx_lm.tuner.trainer as trainer

    original = trainer.default_loss
    if original is answer_only_loss:
        return 1
    replaced = 0
    for function in (trainer.train, trainer.evaluate):
        defaults = function.__defaults__ or ()
        if any(d is original for d in defaults):
            function.__defaults__ = tuple(answer_only_loss if d is original else d for d in defaults)
            replaced += 1
        keywords = function.__kwdefaults__ or {}
        for name, value in list(keywords.items()):
            if value is original:
                keywords[name] = answer_only_loss
                replaced += 1
    trainer.default_loss = answer_only_loss
    return replaced


def save_every(args):
    """学習の途中の差分を保存する間隔 (--checkpoints 個の候補ができる)"""
    return max(10, args.iters // max(1, args.checkpoints))


def train(mlx_model, data_dir, adapters, args):
    """mlx-lm の LoRA の学習を、このプロセスの中で動かす。

    Adam は、偏りの補正 (bias_correction) を有効にする。MLX の既定は補正なしで、そのままだと最初の数百回は、
    補正ありの約 3 倍の大きさで重みが動く (学習率 2e-4 では不安定になり、検証の損失が 0.80 → 2.80 と上がった)。
    学習率の既定 (2e-4) は、補正ありで確かめた値"""
    config = Path(adapters).parent / "lora-config.yaml"
    config.write_text(f"""model: "{mlx_model}"
train: true
data: "{data_dir}"
adapter_path: "{adapters}"
fine_tune_type: lora
num_layers: -1
batch_size: 1
iters: {args.iters}
learning_rate: {args.learning_rate}
max_seq_length: {MAX_SEQ_LENGTH}
mask_prompt: true
grad_checkpoint: true
steps_per_report: 5
steps_per_eval: {max(10, args.iters // 4)}
val_batches: -1
save_every: {save_every(args)}
seed: {args.seed}
lr_schedule:
  name: cosine_decay
  arguments: [{args.learning_rate}, {args.iters}]
optimizer: adam
optimizer_config:
  adam:
    bias_correction: true
lora_parameters:
  keys: ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj"]
  rank: {args.rank}
  scale: {args.scale}
  dropout: 0.0
""", encoding="utf-8")
    from mlx_lm import lora as mlx_lora

    mask_only_the_answer()
    if use_answer_only_loss() < 2:
        print("⚠ mlx-lm の損失の計算を差し替えられませんでした (mlx-lm の版が変わった可能性)。"
              "学習はできますが、効き目が弱くなることがあります。")
    saved = sys.argv
    sys.argv = ["mlx_lm.lora", "--config", str(config)]
    try:
        mlx_lora.main()
    finally:
        sys.argv = saved
    if not (Path(adapters) / "adapters.safetensors").exists():
        fail("学習が終わりましたが、差分 (adapters.safetensors) ができていません。上の出力を確かめてください。")


def found(report):
    return report["audit"]["fixedAutomatically"] + report["audit"]["fixedBySuggestion"]


def run_eval(binary, gguf, sets, cpu, report, adapter=None, baseline=None):
    """評価ハーネスを 1 回動かして、結果 (report の中身) と終了コードを返す"""
    command = [str(binary), "--eval-llm", str(gguf), *[x for s in sets for x in ("--set", str(s))], "--report", str(report)]
    if adapter:
        command += ["--adapter", str(adapter)]
    if baseline:
        command += ["--baseline", str(baseline)]
    if cpu:
        command.append("--cpu")
    done = subprocess.run(command, capture_output=True, text=True)
    if done.returncode not in ((0, 3) if baseline else (0,)):
        print(done.stdout[-2000:] + done.stderr[-2000:])
        fail("評価が失敗しました。")
    return json.loads(Path(report).read_text(encoding="utf-8")), done.returncode


def choose(base, candidates):
    """候補 (名前, 結果, 悪くなっていないか) から、いちばん良いものを選ぶ。
    悪くなっていない (誤った直し・正しい行を壊す・直せた行が減る、が無い) ものの中で、点がいちばん高いもの。
    点は、自動で直せた行を 2、提案どまりで見つけた行を 1 と数える (確かめずに済む直しのほうが役に立つ)。
    同じなら、不要な提案が少ないもの、それも同じなら学習の回数が少ないもの (候補は回数の順に並んでいる)。
    差分なしより直せた行が増えたものが無ければ None"""
    best = None
    for index, (name, report, not_worse) in enumerate(candidates):
        if not not_worse or found(report) <= found(base):
            continue
        key = (found(report) + report["audit"]["fixedAutomatically"], -report["audit"]["falseSuggestions"], -index)
        if best is None or key > best[0]:
            best = (key, name)
    return best[1] if best else None


def translation_rules():
    """翻訳の判定の決まり (tools/translation-eval/evaluate.py)。同じ決まりを 2 か所に書かないよう、そのファイルを読み込む
    (標準の部品だけで書かれている)"""
    import importlib.util

    name = "kikimimi_translation_evaluate"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, REPO / "tools/translation-eval/evaluate.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def translation_gain(verdict):
    """「良くなった」訳す先の、chrF の上がり幅の合計 (小数の誤差で同点が崩れないよう、6 桁で丸める)"""
    rules = translation_rules()
    return round(sum(t["chrF"] - t["baselineChrF"] for t in verdict["targets"]
                     if t["verdict"] == rules.VERDICT_BETTER and t["chrF"] is not None and t["baselineChrF"] is not None), 6)


def choose_translation(candidates):
    """候補 (名前, 判定) から、翻訳用の差分を選ぶ。判定は evaluate.py の judge の結果 (差分なしと比べた物)。
    採れるのは、全体が「採る」(「悪くなった」が 1 つも無く、「良くなった」が 1 つ以上) の候補だけ。
    採れる候補が複数なら、良くなった訳す先の chrF の上がり幅の合計が大きい物、同じなら学習の回数が少ない物
    (候補は回数の順に並んでいる)。採れる候補が無ければ None"""
    rules = translation_rules()
    best = None
    for index, (name, verdict) in enumerate(candidates):
        if verdict["overall"] != rules.OVERALL_ADOPT:
            continue
        key = (translation_gain(verdict), -index)
        if best is None or key > best[0]:
            best = (key, name)
    return best[1] if best else None


def translation_base_reports(eval_sets, base_dir):
    """問題ごとの、差分なしの評価の結果の場所 (base_dir の <名前>.json か eval-base-<名前>.json)。無い問題が在れば止める。
    評価の結果の形 (translationByTarget が在る) の物だけを使う (問題のファイルそのものを、結果と取り違えないように)"""
    def is_report(path):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return False
        return isinstance(data, dict) and "translationByTarget" in data

    found_reports = {}
    for path in eval_sets:
        stem = Path(path).stem
        for name in (f"{stem}.json", f"eval-base-{stem}.json"):
            if is_report(Path(base_dir) / name):
                found_reports[stem] = Path(base_dir) / name
                break
        else:
            fail(f"{base_dir} に、{stem} の差分なしの結果 ({stem}.json か eval-base-{stem}.json) がありません (--base-report)。")
    return found_reports


def evaluate_translation(app, gguf, candidates, eval_sets, work, cpu, base_dir=None):
    """翻訳の評価: 問題 1 つずつ、差分なしと候補 (名前 → GGUF の差分) を走らせ、訳す先ごとに比べる。
    返すのは (選んだ候補の名前か None, 悪くなっていない候補があったか)。評価できなければ None。
    base_dir があれば、差分なしの評価は、そのフォルダの結果を使う"""
    binary = Path(app) / "Contents/MacOS/Kikimimi"
    if not binary.exists():
        print(f"⚠ {app} が無いので、評価は飛ばします (先に make app で組み立ててください)")
        return None
    rules = translation_rules()
    given = translation_base_reports(eval_sets, base_dir) if base_dir else {}
    bases = []
    for path in eval_sets:
        stem = Path(path).stem
        base_path = Path(work) / f"eval-base-{stem}.json"
        if stem in given:
            print(f"▸ 評価 (差分なし、{stem}): {given[stem]} を使います")
            if Path(given[stem]).resolve() != base_path.resolve():
                shutil.copyfile(given[stem], base_path)
            base = json.loads(base_path.read_text(encoding="utf-8"))
        else:
            print(f"▸ 評価 (差分なし、{stem})")
            base, _ = run_eval(binary, gguf, [path], cpu, base_path)
        bases.append((path, stem, base, base_path))

    results = []
    for name, adapter in candidates:
        rows = []
        for path, stem, base, base_path in bases:
            report, code = run_eval(binary, gguf, [path], cpu, Path(work) / f"eval-{name}-{stem}.json",
                                    adapter=adapter, baseline=base_path)
            rows += rules.collect_rows(stem, report, base, code, True, None)
        verdict = rules.judge(rows)
        results.append((name, verdict))
        print(f"  {name}:")
        for text in rules.verdict_lines(verdict)[2:]:
            print("    " + text)
    (Path(work) / "eval-translation-verdicts.json").write_text(
        json.dumps({name: verdict for name, verdict in results}, ensure_ascii=False, indent=1), encoding="utf-8")
    chosen = choose_translation(results)
    return chosen, any(v["overall"] != rules.OVERALL_REJECT for _, v in results)


def evaluate(app, gguf, candidates, eval_sets, work, cpu, base_report=None):
    """評価ハーネスで、差分なしと、候補 (名前 → GGUF の差分) を同じ場面で比べる。
    返すのは (選んだ候補の名前か None, 悪くなっていない候補があったか)。評価できなければ None。
    base_report があれば、差分なしの評価はそれを使う (同じ LLM・同じ場面で前に測ったもの)"""
    binary = Path(app) / "Contents/MacOS/Kikimimi"
    if not binary.exists():
        print(f"⚠ {app} が無いので、評価は飛ばします (先に make app で組み立ててください)")
        return None
    base_path = Path(work) / "eval-base.json"
    if base_report:
        print(f"▸ 評価 (差分なし): {base_report} を使います")
        # 前の実行が作業用のフォルダに書いたものを、そのまま指定したときは写さない
        if Path(base_report).resolve() != base_path.resolve():
            shutil.copyfile(base_report, base_path)
        base = json.loads(base_path.read_text(encoding="utf-8"))
    else:
        print("▸ 評価 (差分なし)")
        base, _ = run_eval(binary, gguf, eval_sets, cpu, base_path)

    def line(name, r, note=""):
        a, tr = r["audit"], r.get("translation", {})
        text = (f"  {name:>10}: 直せた行 {found(r)}/{a['errorLines']} (うち自動 {a['fixedAutomatically']})、"
                f"誤った直し {a['wrongFixes']}、正しい行を壊した数 {a['harmed']}、不要な提案 {a['falseSuggestions']}")
        if tr.get("lines"):
            # 監査の学習が、翻訳を変えてしまうことがある (固有名詞の訳が崩れるなど)。翻訳の場面も同じように比べる
            # その言語だった行 (古い結果は japanese。日本語だけを採点していた)
            in_target = tr.get("inTarget", tr.get("japanese", 0))
            text += (f"、訳: その言語 {in_target}/{tr.get('translated', 0)}・"
                     f"数 {tr.get('numbersKept', 0)}/{tr.get('numbersChecked', 0)}・語 {tr.get('termsKept', 0)}/{tr.get('termsChecked', 0)}")
        print(text + note)

    line("差分なし", base)
    results = []
    for name, adapter in candidates:
        report, code = run_eval(binary, gguf, eval_sets, cpu, Path(work) / f"eval-{name}.json", adapter=adapter, baseline=base_path)
        results.append((name, report, code == 0))
        line(name, report, "" if code == 0 else "  ← 悪くなっている")
    chosen = choose(base, results)
    if chosen:
        shutil.copyfile(Path(work) / f"eval-{chosen}.json", Path(work) / "eval-adapter.json")
    return chosen, any(ok for _, _, ok in results)


def main():
    parser = argparse.ArgumentParser(description="ききみみの監査役・翻訳役を、この Mac の中で追加学習 (LoRA) する")
    parser.add_argument("--task", default="audit", choices=["audit", "translation"],
                        help="学習するもの。audit は監査 (既定。学習データは --export-training)、translation は翻訳 "
                             "(学習データは --export-translation-training。評価は --eval-set の問題で、訳す先ごとに比べる。"
                             "入れる先は <model>.translation.lora.gguf)")
    parser.add_argument("--data", required=True, help="学習データ (.jsonl)")
    parser.add_argument("--model", default="qwen3.5-2b", choices=sorted(MLX_MODELS), help="ききみみで使っている LLM")
    parser.add_argument("--mlx-model", help="学習に使う MLX 形式のモデル (既定は --model に合うもの)")
    parser.add_argument("--gguf", help="ききみみの LLM のファイル (既定は、ききみみの保存先の <model>.gguf)")
    parser.add_argument("--out", default="build/finetune", help="作業用のフォルダ")
    parser.add_argument("--iters", type=int, default=0,
                        help="学習の回数 (既定は、学習データを 5 周する回数。300〜1000 の範囲)")
    parser.add_argument("--checkpoints", type=int, default=None,
                        help="学習の途中の差分を、いくつ候補として残すか (評価して、いちばん良いものを選ぶ。"
                             "既定は 5、--task translation では 3。翻訳の評価は長いため)")
    parser.add_argument("--learning-rate", type=float, default=2e-4)
    parser.add_argument("--rank", type=int, default=8)
    parser.add_argument("--scale", type=float, default=4.0, help="差分の強さ")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--cpu", action="store_true", help="評価を CPU で動かす (学習は、いつも GPU)")
    parser.add_argument("--app", default=str(REPO / "build/Kikimimi.app"), help="評価に使う、組み立てたききみみ")
    parser.add_argument("--eval-set", action="append", default=None,
                        help="評価の場面 (.json)。何度でも指定できる (既定は、ききみみに付いている場面。"
                             "学習データの確認用の例から作った場面は、いつも足す)。--task translation では必須: "
                             "取り分けの問題 (--export-translation-eval) と、見張りの問題 (WMT24++ など)")
    parser.add_argument("--no-eval", action="store_true", help="評価を飛ばす")
    parser.add_argument("--base-report", help="差分なしの評価の結果 (--eval-llm --report で作った .json)。あれば、測り直さずに使う。"
                                              "--task translation では、問題ごとの結果 (<問題の名前>.json) を入れたフォルダ")
    parser.add_argument("--install", action="store_true",
                        help="評価で良くなっていれば (直せた行が増え、悪くなっていなければ)、ききみみの差分の置き場所に入れる "
                             "(--task translation では、翻訳用の置き場 Adapters/<model>.translation.lora.gguf に)")
    parser.add_argument("--force", action="store_true", help="メモリの目安に足りなくても学習する")
    args = parser.parse_args()
    translation = args.task == "translation"
    if args.checkpoints is None:
        args.checkpoints = 3 if translation else 5
    if translation and not args.no_eval and not args.eval_set:
        fail("--task translation では、評価の問題 (--eval-set) を 1 つ以上渡してください "
             "(取り分けの問題 --export-translation-eval の出力と、見張りの問題 WMT24++ など)。")

    if platform.system() != "Darwin" or platform.machine() != "arm64":
        fail("追加学習には Apple シリコンの Mac が必要です (MLX を使います)。")
    try:
        import gguf  # noqa: F401
        import mlx_lm  # noqa: F401
        import numpy  # noqa: F401
    except ImportError as error:
        fail(f"{error.name} がありません。次を実行してください:\n"
             '    python3 -m venv .venv-finetune && .venv-finetune/bin/pip install "mlx-lm[train]" gguf numpy\n'
             "    .venv-finetune/bin/python tools/finetune/finetune.py …")

    gguf_path = Path(args.gguf).expanduser() if args.gguf else LLM_DIR / f"{args.model}.gguf"
    if not gguf_path.exists():
        fail(f"{gguf_path} がありません。ききみみの設定で LLM を取得するか、--gguf で場所を指定してください。")
    have, need = memory_gb(), MEMORY_NEEDED[args.model]
    if have and have < need and not args.force:
        fail(f"この Mac のメモリは {have} GB で、{args.model} の追加学習の目安 ({need} GB) に足りません。"
             "軽いモデル (--model qwen3.5-2b など) を使うか、ほかのアプリを閉じて --force を付けてください。")

    # 評価に使うファイルは、学習の前に確かめる (学習が終わってから「ありません」で止まらないように)
    base = Path(args.base_report).expanduser() if args.base_report else None
    if base and not base.exists():
        fail(f"{base} がありません (--base-report)。")
    for path in args.eval_set or []:
        if not Path(path).expanduser().exists():
            fail(f"{path} がありません (--eval-set)。")
    if translation:
        stems = [Path(p).stem for p in args.eval_set or []]
        if len(set(stems)) != len(stems):
            fail("--eval-set の問題のファイルの名前 (拡張子なし) が重なっています。結果を名前で分けるので、名前を変えてください。")
        if base and not base.is_dir():
            fail(f"--task translation の --base-report は、問題ごとの結果を入れたフォルダです ({base} はフォルダではありません)。")
        if base:
            translation_base_reports([Path(p).expanduser() for p in args.eval_set or []], base)

    work = Path(args.out).expanduser()
    adapters = work / "adapters"
    if adapters.exists():
        shutil.rmtree(adapters)
    work.mkdir(parents=True, exist_ok=True)
    mlx_model = args.mlx_model or MLX_MODELS[args.model]

    data_dir, sample, n_train, own_eval = split_data(args.data, work, args.seed)
    auto_iters = args.iters <= 0
    if args.iters <= 0:
        # 1 回に 1 件ずつ学習する。5 周が目安。何回がよいかは、決め打ちできない: 同じ学習 (0.8B、90 件) を PyTorch で
        # 確かめたとき、1〜2 周では学習した例にも「直しなし」と答え、3〜4 周で直せるようになり (10 行中 7 行)、5 周を
        # 超えると、種によっては逆にほとんど直さなくなった。そこで、途中の差分を残して、評価でいちばん良いものを選ぶ
        args.iters = max(300, min(1000, 5 * n_train))
    tokenizer = check_template(mlx_model, sample)
    if translation:
        # 翻訳の例は、手本のやりとりつきで長い。上限を超える例は、答えが切れるので外す
        n_train, dropped = drop_long_examples(tokenizer, data_dir)
        if dropped and auto_iters:
            args.iters = max(300, min(1000, 5 * n_train))
    print(f"▸ 学習: {mlx_model}、{args.iters} 回 (rank {args.rank}, scale {args.scale})")
    train(mlx_model, data_dir, adapters, args)

    sys.path.insert(0, str(HERE))
    from mlx_lora_to_gguf import convert

    # 候補: 学習の途中で保存された差分と、最後の差分 (回数の順)
    candidates = []
    for saved in sorted(adapters.glob("*_adapters.safetensors")):
        step = int(saved.name.split("_")[0])
        if step < args.iters:
            candidates.append((f"{step}回", saved))
    candidates.append((f"{args.iters}回", adapters / "adapters.safetensors"))
    converted = []
    for name, weights in candidates:
        out = work / f"candidate-{name}.lora.gguf"
        convert(adapters, gguf_path, out, weights=weights)
        converted.append((name, out))

    suffix = ".translation.lora.gguf" if translation else ".lora.gguf"
    adapter = work / f"{args.model}{suffix}"
    result = None
    if not args.no_eval and translation:
        # 翻訳: 確認用の例からは評価の場面を作らない (渡された問題だけで、訳す先ごとに比べる)
        sets = [Path(p).expanduser() for p in args.eval_set]
        print(f"▸ 評価 (翻訳): 候補 {len(converted)} 個を、問題 {len(sets)} つで比べます")
        result = evaluate_translation(args.app, gguf_path, converted, sets, work, args.cpu, base)
    elif not args.no_eval:
        sets = list(args.eval_set or [REPO / "Tests/Fixtures/llm-eval/seed.json"])
        if own_eval:
            sets.append(own_eval)
        print(f"▸ 評価: 候補 {len(converted)} 個を、同じ場面で比べます")
        result = evaluate(args.app, gguf_path, converted, sets, work, args.cpu, base)
    if result is None:
        # 評価していない: 最後の差分をそのまま使う
        shutil.copyfile(converted[-1][1], adapter)
    else:
        chosen, any_not_worse = result
        if chosen is None and translation:
            if any_not_worse:
                print("△ 悪くはなっていない候補はありますが、chrF が良くなった訳す先のある候補がありません (効き目を確かめられませんでした)。入れません。")
            else:
                print("✗ どの候補も、差分なしより悪くなった訳す先があります (訳せた行・その言語の行・数・語が減る、写し・繰り返しが増える、chrF が下がる)。入れません。")
            print(f"  候補は {work} に残しています (candidate-….lora.gguf。判定は eval-translation-verdicts.json)。"
                  "記憶をもっとためるか、--iters や --seed を変えて、もう一度試してください。")
            raise SystemExit(4 if any_not_worse else 3)
        if chosen is None:
            if any_not_worse:
                print("△ 悪くはなっていない候補はありますが、直せた行が増えた候補がありません (効き目を確かめられませんでした)。入れません。")
            else:
                print("✗ どの候補も、差分なしより悪くなりました (誤った直し・正しい行を壊す・直せた行が減る)。入れません。")
            print(f"  候補は {work} に残しています (candidate-….lora.gguf)。直しをもっとためるか、--iters や --seed を変えて、もう一度試してください。")
            raise SystemExit(4 if any_not_worse else 3)
        shutil.copyfile(dict(converted)[chosen], adapter)
        print(f"▸ いちばん良かった候補: {chosen}")
    if args.install:
        target = LLM_DIR / "Adapters" / f"{args.model}{suffix}"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(adapter, target)
        print(f"✓ 入れました: {target}\n  ききみみの設定「監査・翻訳」の「追加学習 (LoRA)」で、使う / 使わないを選べます。")
    elif translation:
        print(f"✓ できました: {adapter}\n  使うには --install を付けるか、ききみみの設定「監査・翻訳」の、翻訳の差分の「差分を追加…」で選んでください。")
    else:
        print(f"✓ できました: {adapter}\n  使うには --install を付けるか、ききみみの設定「監査・翻訳」の「差分を追加…」で選んでください。")

if __name__ == "__main__":
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    main()
