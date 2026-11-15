"""変換の確認用: mlx_lm.lora が作るのと同じ形のフォルダ (adapters.safetensors + adapter_config.json) を、MLX なしで作る。
lora_b を 0 にした差分は、重ねても出力を変えない (既定)。2 番目の引数を random にすると、出力が変わる差分になる。
形は mlx-community/Qwen3.5-0.8B-4bit のもの。

    python3 make_zero_adapter.py <出力フォルダ> [zero|random]
"""
import json, struct, sys, numpy as np
from pathlib import Path
out, mode = Path(sys.argv[1]), (sys.argv[2] if len(sys.argv) > 2 else "zero")
out.mkdir(parents=True, exist_ok=True)
rank, hidden, inner, layers = 8, 1024, 3584, 24
rng = np.random.default_rng(3)
tensors = {}
for n in range(layers):
    for module, (n_in, n_out) in {"gate_proj": (hidden, inner), "up_proj": (hidden, inner), "down_proj": (inner, hidden)}.items():
        base = f"language_model.model.layers.{n}.mlp.{module}"
        tensors[base + ".lora_a"] = (rng.standard_normal((n_in, rank)) / np.sqrt(n_in)).astype(np.float32)
        tensors[base + ".lora_b"] = (np.zeros((rank, n_out)) if mode == "zero" else rng.standard_normal((rank, n_out)) * 0.02).astype(np.float32)
header, blob, offset = {"__metadata__": {"format": "mlx"}}, b"", 0
for name, array in tensors.items():
    raw = array.tobytes()
    header[name] = {"dtype": "F32", "shape": list(array.shape), "data_offsets": [offset, offset + len(raw)]}
    blob += raw; offset += len(raw)
h = json.dumps(header).encode()
(out / "adapters.safetensors").write_bytes(struct.pack("<Q", len(h)) + h + blob)
(out / "adapter_config.json").write_text(json.dumps({"fine_tune_type": "lora", "num_layers": -1,
    "lora_parameters": {"rank": rank, "scale": 2.0, "dropout": 0.0, "keys": ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj"]}}))
print(out, len(tensors))
