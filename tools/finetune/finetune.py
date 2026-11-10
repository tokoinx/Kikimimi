#!/usr/bin/env python3
"""ききみみの監査役 (ローカル LLM) を、この Mac の中で追加学習 (LoRA) する。

    python3 tools/finetune/finetune.py --data ~/Desktop/kikimimi-training.jsonl --model qwen3.5-2b

流れ:
  1. 学習データ (ききみみの設定「学習用のデータを書き出す…」か `Kikimimi --export-training` で作った .jsonl) を、学習用と確認用に分ける
  2. MLX (mlx-lm) で LoRA を学習する。対象は各層の MLP だけ (GGUF にそのまま変えられる重み)
  3. 学習した差分を、ききみみ (llama.cpp) が読める GGUF に変える
  4. 評価ハーネス (`Kikimimi --eval-llm`) で、差分なし / 差分ありを同じ場面で比べる
  5. 悪くなっていなければ、ききみみの差分の置き場所に入れる (`--install`)

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


def split_data(data, work, seed):
    """学習用と確認用に分ける (確認用は 1 割、最低 2 件)"""
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
    n_valid = max(2, len(rows) // 10)
    out = Path(work) / "data"
    out.mkdir(parents=True, exist_ok=True)
    (out / "valid.jsonl").write_text("\n".join(rows[:n_valid]) + "\n", encoding="utf-8")
    (out / "train.jsonl").write_text("\n".join(rows[n_valid:]) + "\n", encoding="utf-8")
    print(f"▸ 学習データ {len(rows) - n_valid} 件、確認用 {n_valid} 件")
    return out, json.loads(rows[0])["messages"]


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
steps_per_report: 10
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
    if args.cpu:
        import mlx.core as mx
        mx.set_default_device(mx.cpu)
        print("▸ CPU で学習します (--cpu)")
    from mlx_lm import lora as mlx_lora

    saved = sys.argv
    sys.argv = ["mlx_lm.lora", "--config", str(config)]
    try:
        mlx_lora.main()
    finally:
        sys.argv = saved
    if not (Path(adapters) / "adapters.safetensors").exists():
        fail("学習が終わりましたが、差分 (adapters.safetensors) ができていません。上の出力を確かめてください。")


def evaluate(app, gguf, adapter, eval_sets, work, cpu):
    """評価ハーネスで、差分なし / 差分ありを比べる。悪くなっていなければ True"""
    binary = Path(app) / "Contents/MacOS/Kikimimi"
    if not binary.exists():
        print(f"⚠ {app} が無いので、評価は飛ばします (先に make app で組み立ててください)")
        return None
    sets = [x for s in eval_sets for x in ("--set", str(s))]
    extra = ["--cpu"] if cpu else []
    base_report, new_report = Path(work) / "eval-base.json", Path(work) / "eval-adapter.json"
    print("▸ 評価 (差分なし)")
    first = subprocess.run([str(binary), "--eval-llm", str(gguf), *sets, "--report", str(base_report), *extra])
    if first.returncode != 0:
        fail("差分なしの評価が失敗しました。")
    print("▸ 評価 (差分あり)")
    second = subprocess.run([str(binary), "--eval-llm", str(gguf), "--adapter", str(adapter), *sets,
                             "--report", str(new_report), "--baseline", str(base_report), *extra])
    if second.returncode not in (0, 3):
        fail("差分ありの評価が失敗しました。")
    return second.returncode == 0


def main():
    parser = argparse.ArgumentParser(description="ききみみの監査役を、この Mac の中で追加学習 (LoRA) する")
    parser.add_argument("--data", required=True, help="学習データ (.jsonl)")
    parser.add_argument("--model", default="qwen3.5-2b", choices=sorted(MLX_MODELS), help="ききみみで使っている LLM")
    parser.add_argument("--mlx-model", help="学習に使う MLX 形式のモデル (既定は --model に合うもの)")
    parser.add_argument("--gguf", help="ききみみの LLM のファイル (既定は、ききみみの保存先の <model>.gguf)")
    parser.add_argument("--out", default="build/finetune", help="作業用のフォルダ")
    parser.add_argument("--iters", type=int, default=150, help="学習の回数")
    parser.add_argument("--learning-rate", type=float, default=1e-4)
    parser.add_argument("--rank", type=int, default=8)
    parser.add_argument("--scale", type=float, default=4.0)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--cpu", action="store_true", help="GPU を使わない (遅い。GPU でうまく動かないとき)")
    parser.add_argument("--app", default=str(REPO / "build/Kikimimi.app"), help="評価に使う、組み立てたききみみ")
    parser.add_argument("--eval-set", action="append", default=None, help="評価の場面 (.json)。何度でも指定できる")
    parser.add_argument("--no-eval", action="store_true", help="評価を飛ばす")
    parser.add_argument("--install", action="store_true", help="悪くなっていなければ、ききみみの差分の置き場所に入れる")
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

    work = Path(args.out).expanduser()
    adapters = work / "adapters"
    if adapters.exists():
        shutil.rmtree(adapters)
    work.mkdir(parents=True, exist_ok=True)
    mlx_model = args.mlx_model or MLX_MODELS[args.model]

    data_dir, sample = split_data(args.data, work, args.seed)
    check_template(mlx_model, sample)
    print(f"▸ 学習: {mlx_model}、{args.iters} 回 (rank {args.rank}, scale {args.scale})")
    train(mlx_model, data_dir, adapters, args)

    sys.path.insert(0, str(HERE))
    from mlx_lora_to_gguf import convert

    adapter = work / f"{args.model}.lora.gguf"
    convert(adapters, gguf_path, adapter)

    better = None
    if not args.no_eval:
        sets = args.eval_set or [REPO / "Tests/Fixtures/llm-eval/seed.json"]
        better = evaluate(args.app, gguf_path, adapter, sets, work, args.cpu)
    if better is False:
        print(f"✗ 差分を使うと、評価が悪くなりました。入れません (差分は {adapter} に残しています)。")
        raise SystemExit(3)
    if args.install:
        target = LLM_DIR / "Adapters" / f"{args.model}.lora.gguf"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(adapter, target)
        print(f"✓ 入れました: {target}\n  ききみみの設定「監査・翻訳」の「追加学習の差分」で、使う / 使わないを選べます。")
    else:
        print(f"✓ できました: {adapter}\n  使うには --install を付けるか、ききみみの設定「監査・翻訳」の「差分を追加…」で選んでください。")


if __name__ == "__main__":
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    main()
