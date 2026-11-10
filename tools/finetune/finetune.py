#!/usr/bin/env python3
"""ききみみの監査役 (ローカル LLM) を、この Mac の中で追加学習 (LoRA) する。

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
    # 学習の対象が、答えだけになっているか
    from mlx_lm.tuner.datasets import ChatDataset

    mask_only_the_answer()
    tokens, offset = ChatDataset([{"messages": sample}], tokenizer, mask_prompt=True).process({"messages": sample})
    trained = tokenizer.decode(list(tokens[offset:]))
    if trained.startswith(answer.strip()):
        print("▸ 学習の対象は、答えだけです: " + repr(trained))
    else:
        print("⚠ 学習の対象が、答えだけになっていません (効き目が弱くなります): " + repr(trained[:120]))


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


def mask_only_the_answer():
    """mlx-lm の学習データの読み方を、答えだけを学習の対象にするものに差し替える"""
    import mlx_lm.tuner.datasets as datasets

    original = datasets.ChatDataset.process
    if getattr(original, "kikimimi", False):
        return

    def process(self, d):
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


def train(mlx_model, data_dir, adapters, args):
    """mlx-lm の LoRA の学習を、このプロセスの中で動かす"""
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
max_seq_length: 1024
mask_prompt: true
grad_checkpoint: true
steps_per_report: 5
steps_per_eval: {max(10, args.iters // 4)}
val_batches: -1
save_every: {max(10, args.iters // 2)}
seed: {args.seed}
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


def evaluate(app, gguf, adapter, eval_sets, work, cpu, base_report=None):
    """評価ハーネスで、差分なし / 差分ありを比べる。
    返すのは (悪くなっていないか, 直せた行が増えたか)。評価できなければ None。
    base_report があれば、差分なしの評価はそれを使う (同じ LLM・同じ場面で前に測ったもの)"""
    binary = Path(app) / "Contents/MacOS/Kikimimi"
    if not binary.exists():
        print(f"⚠ {app} が無いので、評価は飛ばします (先に make app で組み立ててください)")
        return None
    sets = [x for s in eval_sets for x in ("--set", str(s))]
    extra = ["--cpu"] if cpu else []
    base_path, new_path = Path(work) / "eval-base.json", Path(work) / "eval-adapter.json"
    if base_report:
        print(f"▸ 評価 (差分なし): {base_report} を使います")
        # 前の実行が作業用のフォルダに書いたものを、そのまま指定したときは写さない
        if Path(base_report).resolve() != base_path.resolve():
            shutil.copyfile(base_report, base_path)
    else:
        print("▸ 評価 (差分なし)")
        first = subprocess.run([str(binary), "--eval-llm", str(gguf), *sets, "--report", str(base_path), *extra])
        if first.returncode != 0:
            fail("差分なしの評価が失敗しました。")
    print("▸ 評価 (差分あり)")
    second = subprocess.run([str(binary), "--eval-llm", str(gguf), "--adapter", str(adapter), *sets,
                             "--report", str(new_path), "--baseline", str(base_path), *extra])
    if second.returncode not in (0, 3):
        fail("差分ありの評価が失敗しました。")
    base, new = json.loads(base_path.read_text(encoding="utf-8")), json.loads(new_path.read_text(encoding="utf-8"))
    lines = new["audit"]["errorLines"]
    print(f"▸ 直せた行 (提案を含む): {found(base)} → {found(new)} / {lines}、"
          f"正しい行を壊した数: {base['audit']['harmed']} → {new['audit']['harmed']}、"
          f"誤った直し: {base['audit']['wrongFixes']} → {new['audit']['wrongFixes']}")
    return second.returncode == 0, found(new) > found(base)


def main():
    parser = argparse.ArgumentParser(description="ききみみの監査役を、この Mac の中で追加学習 (LoRA) する")
    parser.add_argument("--data", required=True, help="学習データ (.jsonl)")
    parser.add_argument("--model", default="qwen3.5-2b", choices=sorted(MLX_MODELS), help="ききみみで使っている LLM")
    parser.add_argument("--mlx-model", help="学習に使う MLX 形式のモデル (既定は --model に合うもの)")
    parser.add_argument("--gguf", help="ききみみの LLM のファイル (既定は、ききみみの保存先の <model>.gguf)")
    parser.add_argument("--out", default="build/finetune", help="作業用のフォルダ")
    parser.add_argument("--iters", type=int, default=0,
                        help="学習の回数 (既定は、学習データを 3 周半する回数。200〜800 の範囲)")
    parser.add_argument("--learning-rate", type=float, default=2e-4)
    parser.add_argument("--rank", type=int, default=8)
    parser.add_argument("--scale", type=float, default=4.0, help="差分の強さ")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--cpu", action="store_true", help="評価を CPU で動かす (学習は、いつも GPU)")
    parser.add_argument("--app", default=str(REPO / "build/Kikimimi.app"), help="評価に使う、組み立てたききみみ")
    parser.add_argument("--eval-set", action="append", default=None,
                        help="評価の場面 (.json)。何度でも指定できる (既定は、ききみみに付いている場面。"
                             "学習データの確認用の例から作った場面は、いつも足す)")
    parser.add_argument("--no-eval", action="store_true", help="評価を飛ばす")
    parser.add_argument("--base-report", help="差分なしの評価の結果 (--eval-llm --report で作った .json)。あれば、測り直さずに使う")
    parser.add_argument("--install", action="store_true",
                        help="評価で良くなっていれば (直せた行が増え、悪くなっていなければ)、ききみみの差分の置き場所に入れる")
    parser.add_argument("--force", action="store_true", help="メモリの目安に足りなくても学習する")
    args = parser.parse_args()

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

    work = Path(args.out).expanduser()
    adapters = work / "adapters"
    if adapters.exists():
        shutil.rmtree(adapters)
    work.mkdir(parents=True, exist_ok=True)
    mlx_model = args.mlx_model or MLX_MODELS[args.model]

    data_dir, sample, n_train, own_eval = split_data(args.data, work, args.seed)
    if args.iters <= 0:
        # 1 回に 1 件ずつ学習する。3 周半が目安: 同じ学習 (0.8B、90 件) を確かめたとき、1 周 (100 回) では学習した例にも
        # 「直しなし」と答え、3 周 (300 回) で、学習に使っていない文の 10 行のうち 7 行を直せるようになった
        args.iters = max(200, min(800, round(3.5 * n_train)))
    check_template(mlx_model, sample)
    print(f"▸ 学習: {mlx_model}、{args.iters} 回 (rank {args.rank}, scale {args.scale})")
    train(mlx_model, data_dir, adapters, args)

    sys.path.insert(0, str(HERE))
    from mlx_lora_to_gguf import convert

    adapter = work / f"{args.model}.lora.gguf"
    convert(adapters, gguf_path, adapter)

    result = None
    if not args.no_eval:
        sets = list(args.eval_set or [REPO / "Tests/Fixtures/llm-eval/seed.json"])
        if own_eval:
            sets.append(own_eval)
        result = evaluate(args.app, gguf_path, adapter, sets, work, args.cpu, base)
    if result is not None and not result[0]:
        print(f"✗ 差分を使うと、評価が悪くなりました (誤った直し・正しい行を壊す・直せた行が減る)。入れません。\n"
              f"  差分は {adapter} に残しています。直しをもっとためるか、--iters を変えて、もう一度試してください。")
        raise SystemExit(3)
    if result is not None and not result[1]:
        print(f"△ 悪くはなっていませんが、直せた行は増えていません (効き目を確かめられませんでした)。入れません。\n"
              f"  差分は {adapter} に残しています。直しをもっとためるか、--iters を増やして、もう一度試してください。")
        raise SystemExit(4)
    if args.install:
        target = LLM_DIR / "Adapters" / f"{args.model}.lora.gguf"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(adapter, target)
        print(f"✓ 入れました: {target}\n  ききみみの設定「監査・翻訳」の「追加学習 (LoRA)」で、使う / 使わないを選べます。")
    else:
        print(f"✓ できました: {adapter}\n  使うには --install を付けるか、ききみみの設定「監査・翻訳」の「差分を追加…」で選んでください。")

if __name__ == "__main__":
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    main()
