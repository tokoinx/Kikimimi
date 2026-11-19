#!/usr/bin/env python3
"""WMT24++ の手元のデータから、見立ての「訳の記憶」(translation-memory.json の形) を作る。

    python3 tools/translation-eval/make_memory.py --cache build/translation-eval-100/cache \\
        --sets build/translation-eval-100/sets --out /tmp/memory.json [--per-target 300] [--same-documents] [--seed 1]

似た文を手本にする実験 (`Kikimimi --eval-llm … --memory <記憶> --examples N`) のための物。
入れるのは、評価の問題に入っていない行の、人の訳 (WMT24++ の訳) だけ。利用者が本当に直した訳ではない (見立て)。

- 訳す先は、--sets の問題のファイルに在る物 (en-ja.json なら英語 → 日本語、ja-en.json なら日本語 → 英語)。
- 評価の問題の行 (原文と人の訳。--sets の selection.json が在れば、その行の番号も) は、記憶に入れない。
- 訳の参照が空の行・原文が同じ行 (2 つ目から)・canary・is_bad_source・改行を含む行・
  原文か訳が --max-chars を超える行 (アプリは長い手本を使わない) は入れない。
- --same-documents: 評価の問題と同じ文書 (document_id) の、評価に入っていない行を先に選ぶ
  (「利用者が、同じ録音の前のほうの行を直してあった」という場面の見立て)。残りは、ほかの文書から選ぶ。
- 選ぶ順は --seed で決まる (毎回同じ行になる)。

書き出す形は {"version": 1, "sentences": [...], "terms": [], "gate": []}。
1 件は RememberedTranslation の項目 (id・source・sourceLanguage・target・translation・heldOut・updated)。
heldOut はいつも false (手本に使える文)、machine は書かない。
Python の標準の部品だけを使う。
"""
import argparse
import json
import random
import sys
import unicodedata
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from fetch_wmt24pp import FILES  # noqa: E402  (WMT24++ のファイルの言語 → ききみみの訳す先のコード)

CODE_TO_FILE = {code: f"en-{wmt}.jsonl" for wmt, code in FILES.items()}
# 決まった日時 (記憶の updated。同じ引数なら同じファイルになるように)
UPDATED = "2026-01-01T00:00:00Z"


def fail(message):
    raise SystemExit("✗ " + message)


def normalized(text):
    """アプリの TranslationMemory.normalizedSource と同じそろえ方 (NFKC、続く空白を 1 つに、前後の空白を外す)"""
    return " ".join(unicodedata.normalize("NFKC", text or "").split())


def read_rows(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as error:
                fail(f"{path} の {number} 行目が読めません ({error})。")
    return rows


def read_sets(sets_dir):
    """問題のフォルダから、訳す先ごとの (原文の言語, 問題の原文と人の訳の集合) と、問題の行の番号・文書を読む"""
    pairs = {}  # (原文の言語, 訳す先) → 問題の文 (原文・人の訳、そろえた物) の集合
    for path in sorted(sets_dir.glob("*.json")):
        if path.name == "selection.json":
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        for case in data.get("translation", []):
            key = (case.get("language", "en"), case.get("target", "ja"))
            texts = pairs.setdefault(key, set())
            texts.update(normalized(t) for t in case.get("lines", []))
            texts.update(normalized(t) for t in (case.get("references") or []))
    keys, documents = set(), set()
    selection = sets_dir / "selection.json"
    if selection.exists():
        for row in json.loads(selection.read_text(encoding="utf-8")).get("rows", []):
            keys.add((str(row["document_id"]), int(row["segment_id"])))
            documents.add(str(row["document_id"]))
    return pairs, keys, documents


def usable(row, max_chars):
    source, target = row.get("source") or "", row.get("target") or ""
    return (not row.get("is_bad_source") and row.get("domain") != "canary"
            and source.strip() and target.strip() and "\n" not in source and "\n" not in target
            and len(normalized(source)) <= max_chars and len(normalized(target)) <= max_chars)


def main():
    parser = argparse.ArgumentParser(description="WMT24++ の手元のデータから、見立ての訳の記憶を作る")
    parser.add_argument("--cache", required=True, help="fetch_wmt24pp.py の cache/ のフォルダ (en-ja_JP.jsonl など)")
    parser.add_argument("--sets", required=True, help="評価の問題のフォルダ (ここに在る問題の文は、記憶に入れない)")
    parser.add_argument("--out", required=True, help="書き出す記憶のファイル (.json)")
    parser.add_argument("--per-target", type=int, default=300, help="訳す先ごとの文の数 (既定 300)")
    parser.add_argument("--same-documents", action="store_true",
                        help="評価の問題と同じ文書の、評価に入っていない行を先に選ぶ")
    parser.add_argument("--seed", type=int, default=1, help="選ぶ順を決める種 (既定 1)")
    parser.add_argument("--max-chars", type=int, default=200,
                        help="原文・訳の字数の上限 (既定 200。アプリが手本に使う上限と同じ)")
    args = parser.parse_args()

    cache, sets_dir, out = Path(args.cache).expanduser(), Path(args.sets).expanduser(), Path(args.out).expanduser()
    if not cache.is_dir():
        fail(f"{cache} がありません (--cache)。")
    if not sets_dir.is_dir():
        fail(f"{sets_dir} がありません (--sets)。")
    if args.per_target < 1:
        fail("--per-target は 1 以上にしてください。")
    pairs, eval_keys, eval_documents = read_sets(sets_dir)
    if not pairs:
        fail(f"{sets_dir} に翻訳の問題がありません。")

    sentences, report = [], []
    for (language, target) in sorted(pairs):
        # 英語 → 訳す先は en-<訳す先>.jsonl、日本語 → 英語は en-ja_JP.jsonl を逆に使う
        if language == "en" and target in CODE_TO_FILE:
            name, reverse = CODE_TO_FILE[target], False
        elif language == "ja" and target == "en":
            name, reverse = CODE_TO_FILE["ja"], True
        else:
            print(f"  {language}→{target}: WMT24++ のファイルが無いので、飛ばします")
            continue
        path = cache / name
        if not path.exists():
            fail(f"{path} がありません (--cache)。先に fetch_wmt24pp.py を走らせてください。")
        excluded = pairs[(language, target)]
        rows = [r for r in read_rows(path) if usable(r, args.max_chars)]
        # 問題の文書 (selection.json が無い時は、問題の原文に当たった行の文書)
        documents = set(eval_documents)
        candidates, seen = [], set()
        for r in sorted(rows, key=lambda r: (str(r["document_id"]), int(r["segment_id"]))):
            source, translation = (r["target"], r["source"]) if reverse else (r["source"], r["target"])
            s, t = normalized(source), normalized(translation)
            key = (str(r["document_id"]), int(r["segment_id"]))
            if s in excluded or t in excluded:
                documents.add(key[0])
                continue
            if key in eval_keys or s in seen:
                continue
            seen.add(s)
            candidates.append((key, s, t))
        rng = random.Random(f"{args.seed}-{language}-{target}")
        same = [c for c in candidates if c[0][0] in documents]
        other = [c for c in candidates if c[0][0] not in documents]
        rng.shuffle(same)
        rng.shuffle(other)
        chosen = (same + other) if args.same_documents else rng.sample(candidates, len(candidates))
        chosen = chosen[:args.per_target]
        from_same = sum(1 for c in chosen if c[0][0] in documents)
        for key, s, t in sorted(chosen, key=lambda c: c[0]):
            sentences.append({
                "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"wmt24pp/{language}-{target}/{key[0]}/{key[1]}")).upper(),
                "source": s, "sourceLanguage": language, "target": target, "translation": t,
                "heldOut": False, "updated": UPDATED,
            })
        report.append((language, target, len(chosen), from_same, len(same), len(candidates)))

    memory = {"version": 1, "sentences": sentences, "terms": [], "gate": []}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(memory, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"▸ 見立ての訳の記憶を書きました: {out} (文 {len(sentences)})")
    print("  訳す先  文の数  同じ文書から  (同じ文書の候補 / 候補の全部)")
    for language, target, n, from_same, n_same, n_all in report:
        print(f"  {language}→{target:<4} {n:>5}  {from_same:>10}    ({n_same} / {n_all})")
    if not args.same_documents:
        print("  (--same-documents なし: 同じ文書から取れた数は、たまたま入った数)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
