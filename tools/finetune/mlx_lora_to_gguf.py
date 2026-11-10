#!/usr/bin/env python3
"""MLX (mlx-lm) で学習した LoRA の差分を、ききみみ (llama.cpp) が読める GGUF の差分に変える。

    python3 mlx_lora_to_gguf.py <adapters のフォルダ> <元の GGUF> <出力.gguf>

- adapters のフォルダ: mlx_lm.lora が作る adapters.safetensors と adapter_config.json
- 元の GGUF: ききみみで使っている LLM (例: ~/Library/Application Support/Kikimimi/Models/LLM/qwen3.5-2b.gguf)。
  形 (行列の大きさ) を照らし合わせて、別のモデルの差分を取り違えないようにする

変えるのは MLP (gate_proj / up_proj / down_proj) の差分だけ。この 3 つは、Hugging Face の重みの名前と GGUF の名前が
1 対 1 で対応する。注意機構 (q/k/v) の重みは、GGUF では並べ替えやまとめ直しがあるので扱わない
(学習するときも MLP だけを対象にする: finetune.py がそう設定する)。

mlx-lm の LoRA:  y = W x + scale * ((x @ lora_a) @ lora_b)      lora_a: (入力, r)   lora_b: (r, 出力)
llama.cpp の LoRA: y = W x + (alpha / r) * B (A x)               A: (r, 入力)        B: (出力, r)
なので A = lora_a の転置、B = lora_b の転置、alpha = scale * r。
"""
import json
import re
import struct
import sys
from pathlib import Path

import numpy as np

MLP = {"gate_proj": "ffn_gate", "up_proj": "ffn_up", "down_proj": "ffn_down"}
KEY = re.compile(r"(?:^|\.)layers\.(\d+)\.mlp\.(gate_proj|up_proj|down_proj)\.lora_([ab])$")
DTYPES = {"F32": np.float32, "F16": np.float16, "F64": np.float64}


def read_safetensors(path):
    """safetensors を numpy で読む (追加のライブラリなし)。BF16 は float32 に直す"""
    data = Path(path).read_bytes()
    (n,) = struct.unpack("<Q", data[:8])
    header = json.loads(data[8:8 + n])
    out = {}
    for name, info in header.items():
        if name == "__metadata__":
            continue
        start, end = info["data_offsets"]
        raw = data[8 + n + start:8 + n + end]
        if info["dtype"] == "BF16":
            array = (np.frombuffer(raw, dtype=np.uint16).astype(np.uint32) << 16).view(np.float32)
        elif info["dtype"] in DTYPES:
            array = np.frombuffer(raw, dtype=DTYPES[info["dtype"]]).astype(np.float32)
        else:
            raise SystemExit(f"✗ {name}: 対応していない型 {info['dtype']} です")
        out[name] = array.reshape(info["shape"])
    return out


def convert(adapter_dir, base_gguf, output):
    import gguf

    adapter_dir = Path(adapter_dir)
    config = json.loads((adapter_dir / "adapter_config.json").read_text())
    params = config.get("lora_parameters", {})
    scale = float(params.get("scale", 20.0))
    tensors = read_safetensors(adapter_dir / "adapters.safetensors")

    base = gguf.GGUFReader(str(base_gguf))
    field = base.fields["general.architecture"]
    architecture = bytes(field.parts[field.data[0]]).decode()
    shapes = {t.name: [int(x) for x in t.shape] for t in base.tensors}

    pairs = {}
    skipped = []
    for name, array in tensors.items():
        match = KEY.search(name)
        if not match:
            skipped.append(name)
            continue
        layer, module, side = int(match.group(1)), match.group(2), match.group(3)
        pairs.setdefault(f"blk.{layer}.{MLP[module]}.weight", {})[side] = array
    if skipped:
        raise SystemExit("✗ MLP 以外の差分が入っています (GGUF に変えられません): " + ", ".join(sorted(skipped)[:4])
                         + f" … 全 {len(skipped)} 個。finetune.py で学習し直してください (MLP だけを対象にします)。")
    if not pairs:
        raise SystemExit("✗ 差分の中に MLP (gate_proj / up_proj / down_proj) の重みがありません。")

    writer = gguf.GGUFWriter(str(output), architecture)
    writer.add_string("general.type", "adapter")
    writer.add_string("adapter.type", "lora")
    writer.add_string("general.name", f"kikimimi LoRA for {Path(base_gguf).name}")
    rank = None
    for target in sorted(pairs, key=lambda k: (int(k.split(".")[1]), k)):
        sides = pairs[target]
        if set(sides) != {"a", "b"}:
            raise SystemExit(f"✗ {target}: lora_a と lora_b がそろっていません")
        a, b = sides["a"].T, sides["b"].T                      # A: (r, 入力)  B: (出力, r)
        if target not in shapes:
            raise SystemExit(f"✗ 元の GGUF に {target} がありません。別のモデルの差分ではありませんか。")
        n_in, n_out = shapes[target]                           # GGUF の次元は逆順: [入力, 出力]
        if a.shape[1] != n_in or b.shape[0] != n_out or a.shape[0] != b.shape[1]:
            raise SystemExit(f"✗ {target}: 形が合いません (差分 A{a.shape} B{b.shape}、元のモデル 入力 {n_in}・出力 {n_out})。"
                             "学習に使ったモデルと、ききみみで選んでいるモデルが同じ大きさかを確かめてください。")
        if rank is None:
            rank = a.shape[0]
        elif rank != a.shape[0]:
            raise SystemExit(f"✗ {target}: rank がそろっていません ({a.shape[0]} と {rank})")
        if not (np.isfinite(a).all() and np.isfinite(b).all()):
            raise SystemExit(f"✗ {target}: 数値が壊れています (NaN / inf)。学習がうまくいっていません。")
        writer.add_tensor(target + ".lora_a", np.ascontiguousarray(a, dtype=np.float32))
        writer.add_tensor(target + ".lora_b", np.ascontiguousarray(b, dtype=np.float32))
    writer.add_float32("adapter.lora.alpha", scale * rank)
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()
    print(f"✓ {output}: {len(pairs)} 個の重みの差分 (rank {rank}, scale {scale}, {architecture})")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    convert(sys.argv[1], sys.argv[2], sys.argv[3])
