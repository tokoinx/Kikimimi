#!/usr/bin/env python3
"""動作確認用の、とても小さな GGUF (乱数の重みの qwen2) を作る。

本物の語彙 (llama.cpp の models/ggml-vocab-qwen2.gguf) を使うので、トークン化・チャットテンプレート・
文法つきの生成など、llama.cpp の呼び出し方をひと通り確かめられる。答えの中身は無意味。
CI で `Kikimimi --selftest-llm` に渡すために使う。

usage: make-tiny-gguf.py <ggml-vocab-qwen2.gguf> <out.gguf> [chatml-think|gemma|none]
requires: pip install gguf numpy
"""
import sys
import numpy as np
import gguf

vocab_path, out_path = sys.argv[1], sys.argv[2]
template_kind = sys.argv[3] if len(sys.argv) > 3 else "chatml-think"

reader = gguf.GGUFReader(vocab_path)

def field(name):
    f = reader.fields.get(name)
    if f is None:
        return None
    return f

def scalar(name):
    f = field(name)
    if f is None:
        return None
    v = f.parts[f.data[0]]
    return v[0] if hasattr(v, "__len__") and len(v) == 1 else v

def str_array(name):
    f = field(name)
    return [bytes(f.parts[i]).decode("utf-8") for i in f.data]

def int_array(name):
    f = field(name)
    return [int(f.parts[i][0]) for i in f.data]

tokens = str_array("tokenizer.ggml.tokens")
types = int_array("tokenizer.ggml.token_type")
merges = str_array("tokenizer.ggml.merges")
pre = bytes(field("tokenizer.ggml.pre").parts[field("tokenizer.ggml.pre").data[0]]).decode()
n_vocab = len(tokens)
print("vocab", n_vocab, "merges", len(merges), "pre", pre)

def tok_id(text):
    return tokens.index(text)

im_end = tok_id("<|im_end|>")
endoftext = tok_id("<|endoftext|>")

templates = {
    "chatml-think": (
        "{% for message in messages %}{{'<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>' + '\\n'}}{% endfor %}"
        "{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n' }}{% if enable_thinking is defined and enable_thinking is false %}{{ '<think>\\n\\n</think>\\n\\n' }}{% endif %}{% endif %}"
    ),
    "gemma": (
        "{{ bos_token }}{% for message in messages %}{{ '<start_of_turn>' + message['role'] + '\\n' + message['content'] | trim + '<end_of_turn>\\n' }}{% endfor %}"
        "{% if add_generation_prompt %}{{'<start_of_turn>model\\n'}}{% endif %}"
    ),
}

n_embd, n_head, n_head_kv, n_ff, n_layer = 64, 4, 2, 128, 2
head_dim = n_embd // n_head
n_embd_kv = head_dim * n_head_kv

w = gguf.GGUFWriter(out_path, "qwen2")
w.add_name("kikimimi-tiny-test")
w.add_context_length(4096)
w.add_embedding_length(n_embd)
w.add_block_count(n_layer)
w.add_feed_forward_length(n_ff)
w.add_head_count(n_head)
w.add_head_count_kv(n_head_kv)
w.add_rope_freq_base(1_000_000.0)
w.add_layer_norm_rms_eps(1e-6)
w.add_file_type(gguf.LlamaFileType.MOSTLY_F16)

w.add_tokenizer_model("gpt2")
w.add_tokenizer_pre(pre)
w.add_token_list(tokens)
w.add_token_types(types)
w.add_token_merges(merges)
w.add_eos_token_id(im_end if template_kind != "gemma" else endoftext)
w.add_bos_token_id(endoftext)
w.add_pad_token_id(endoftext)
w.add_add_bos_token(template_kind == "gemma")
if template_kind in templates:
    w.add_chat_template(templates[template_kind])

rng = np.random.default_rng(1234)
def mat(n_out, n_in):
    return (rng.standard_normal((n_out, n_in)) * 0.05).astype(np.float16)
def vec(n, val=None):
    return (np.full(n, val, dtype=np.float32) if val is not None
            else (rng.standard_normal(n) * 0.02).astype(np.float32))

w.add_tensor("token_embd.weight", mat(n_vocab, n_embd))
w.add_tensor("output_norm.weight", vec(n_embd, 1.0))
for i in range(n_layer):
    p = f"blk.{i}."
    w.add_tensor(p + "attn_norm.weight", vec(n_embd, 1.0))
    w.add_tensor(p + "attn_q.weight", mat(n_embd, n_embd))
    w.add_tensor(p + "attn_q.bias", vec(n_embd))
    w.add_tensor(p + "attn_k.weight", mat(n_embd_kv, n_embd))
    w.add_tensor(p + "attn_k.bias", vec(n_embd_kv))
    w.add_tensor(p + "attn_v.weight", mat(n_embd_kv, n_embd))
    w.add_tensor(p + "attn_v.bias", vec(n_embd_kv))
    w.add_tensor(p + "attn_output.weight", mat(n_embd, n_embd))
    w.add_tensor(p + "ffn_norm.weight", vec(n_embd, 1.0))
    w.add_tensor(p + "ffn_gate.weight", mat(n_ff, n_embd))
    w.add_tensor(p + "ffn_up.weight", mat(n_ff, n_embd))
    w.add_tensor(p + "ffn_down.weight", mat(n_embd, n_ff))

w.write_header_to_file()
w.write_kv_data_to_file()
w.write_tensors_to_file()
w.close()
print("wrote", out_path)
