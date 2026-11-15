#!/usr/bin/env python3
"""公開の対訳データ WMT24++ から、ききみみの評価ハーネス (`Kikimimi --eval-llm`) の翻訳の問題を作る。

    python3 tools/translation-eval/fetch_wmt24pp.py [--per-domain 15] [--domains speech,social] [--out build/translation-eval]

WMT24++ (Hugging Face の google/wmt24pp、Apache-2.0、ログイン不要) は、英語の文と、人が直した 55 言語の訳。
ここでは、訳す先 12 言語 (en-ja_JP など) のファイルを取り、どの言語でも同じ行 (同じ document_id と segment_id) を選んで、
訳す先ごとの問題 `sets/en-<訳す先>.json` を作る。加えて、日本語を原文・英語を参照にした `sets/ja-en.json` も作る
(この日本語は訳された文なので、参考の値)。

選び方: is_bad_source の行と canary を除き、領域 (既定 speech と social) ごとに、原文が 20〜400 字の行から N 行を、
決まった種 (seed) で選ぶ (毎回同じ行になる)。原文か訳に改行の在る行と、どれかの言語に無い行も除く。

ダウンロードは 1 つずつ行い、失敗したら止まる。もう cache/ に在るファイルは取り直さない。
Python の標準の部品だけを使う。
"""
import argparse
import json
import random
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

BASE_URL = "https://huggingface.co/datasets/google/wmt24pp/resolve/main/"
# WMT24++ のファイルの言語 → ききみみの訳す先のコード
FILES = {
    "ja_JP": "ja", "zh_CN": "zh", "ko_KR": "ko", "es_MX": "es", "fr_FR": "fr", "de_DE": "de",
    "it_IT": "it", "pt_BR": "pt", "ru_RU": "ru", "vi_VN": "vi", "th_TH": "th", "id_ID": "id",
}
DATASET = "google/wmt24pp"
LICENSE = "Apache-2.0"


def fail(message):
    raise SystemExit("✗ " + message)


def download(name, cache):
    """1 つのファイルを取る (もう在れば取り直さない)。途中で切れたファイルを残さないよう、別の名前に書いてから置き換える"""
    path = cache / name
    if path.exists() and path.stat().st_size > 0:
        print(f"  {name}: cache に在ります")
        return path
    url = BASE_URL + name
    print(f"  {name}: 取っています ({url})")
    partial = cache / (name + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "translation-eval-fetch/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response, open(partial, "wb") as out:
            while True:
                block = response.read(1 << 16)
                if not block:
                    break
                out.write(block)
    except (urllib.error.URLError, OSError) as error:
        # python.org の Python は、証明書を入れる手順 (Install Certificates.command) を済ませていないと、
        # 証明書を確かめられない。その時は、macOS の証明書を使う curl で取る
        if "CERTIFICATE_VERIFY_FAILED" not in str(error) or not shutil.which("curl"):
            fail(f"{url} を取れませんでした: {error}。ネットワークを確かめて、もう一度走らせてください (取れたファイルは取り直しません)。")
        print("    (Python が証明書を確かめられないので、curl で取ります)")
        done = subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2",
                               "--output", str(partial), url])
        if done.returncode != 0:
            fail(f"{url} を取れませんでした (curl の終了コード {done.returncode})。ネットワークを確かめて、もう一度走らせてください。")
    partial.replace(path)
    return path


def read_rows(path):
    rows = {}
    with open(path, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                fail(f"{path} の {number} 行目が読めません ({error})。cache/ のこのファイルを消して、取り直してください。")
            rows[(str(row["document_id"]), int(row["segment_id"]))] = row
    return rows


def usable(row, domains, min_chars, max_chars):
    source, target = row.get("source") or "", row.get("target") or ""
    return (not row.get("is_bad_source") and row.get("domain") in domains and row.get("domain") != "canary"
            and min_chars <= len(source) <= max_chars and target.strip()
            and "\n" not in source and "\n" not in target)


def cases_for(keys, rows, language, target, domains_of):
    """選んだ行を、文書ごとに 1 つの問題にする (行は segment_id の順)"""
    by_document = {}
    for key in sorted(keys):
        by_document.setdefault(key[0], []).append(key)
    cases = []
    for document, members in sorted(by_document.items()):
        members.sort(key=lambda k: k[1])
        if language == "en":
            lines = [rows[k]["source"] for k in members]
            references = [rows[k]["target"] for k in members]
        else:  # 日本語を原文に、英語を参照に
            lines = [rows[k]["target"] for k in members]
            references = [rows[k]["source"] for k in members]
        cases.append({
            "id": f"wmt24pp-{language}-{target}-{document}",
            "language": language,
            "target": target,
            "domain": domains_of[members[0]],
            "lines": lines,
            "references": references,
        })
    return cases


def main():
    parser = argparse.ArgumentParser(description="WMT24++ から、翻訳の評価の問題を作る")
    parser.add_argument("--out", default=str(REPO / "build/translation-eval"), help="出す場所 (既定 build/translation-eval)")
    parser.add_argument("--per-domain", type=int, default=15, help="領域ごとの行の数 (既定 15)")
    parser.add_argument("--domains", default="speech,social", help="使う領域 (既定 speech,social。ほかに news,literary)")
    parser.add_argument("--seed", type=int, default=20241, help="選ぶ順を決める種 (既定 20241)")
    parser.add_argument("--min-chars", type=int, default=20, help="原文の字数の下限 (既定 20)")
    parser.add_argument("--max-chars", type=int, default=400, help="原文の字数の上限 (既定 400)")
    args = parser.parse_args()

    domains = [d.strip() for d in args.domains.split(",") if d.strip()]
    if not domains or "canary" in domains:
        fail("--domains には speech・social・news・literary から選んでください (canary は使いません)。")
    if args.per_domain < 1:
        fail("--per-domain は 1 以上にしてください。")
    out = Path(args.out).expanduser()
    cache, sets = out / "cache", out / "sets"
    cache.mkdir(parents=True, exist_ok=True)
    sets.mkdir(parents=True, exist_ok=True)

    print(f"▸ WMT24++ ({DATASET}, {LICENSE}) を取ります: {len(FILES)} ファイル")
    tables = {}
    for wmt, code in FILES.items():
        tables[code] = read_rows(download(f"en-{wmt}.jsonl", cache))

    # どの言語にも在り、どの言語でも使える行 (原文の英語も同じ行) だけを候補にする
    first = tables["ja"]
    candidates = []
    for key, row in first.items():
        if all(key in t and usable(t[key], domains, args.min_chars, args.max_chars) and t[key]["source"] == row["source"]
               for t in tables.values()):
            candidates.append(key)
    rng = random.Random(args.seed)
    chosen = []
    domains_of = {}
    for domain in domains:
        pool = sorted(k for k in candidates if first[k]["domain"] == domain)
        if len(pool) < args.per_domain:
            fail(f"領域 {domain} の使える行は {len(pool)} 行しかありません (--per-domain {args.per_domain})。")
        picked = rng.sample(pool, args.per_domain)
        chosen += picked
        for k in picked:
            domains_of[k] = domain
        print(f"  {domain}: 使える行 {len(pool)} 行から {len(picked)} 行")

    about = {"dataset": DATASET, "license": LICENSE, "url": "https://huggingface.co/datasets/" + DATASET,
             "domains": domains, "perDomain": args.per_domain, "seed": args.seed, "lines": len(chosen),
             "minChars": args.min_chars, "maxChars": args.max_chars}
    written = []
    for code in FILES.values():
        cases = cases_for(chosen, tables[code], "en", code, domains_of)
        data = {"name": f"WMT24++ en-{code} ({', '.join(domains)}; {len(chosen)} lines)", "about": about,
                "audit": [], "translation": cases}
        path = sets / f"en-{code}.json"
        path.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        written.append((path, len(cases), sum(len(c["lines"]) for c in cases)))
    cases = cases_for(chosen, tables["ja"], "ja", "en", domains_of)
    data = {"name": f"WMT24++ ja-en ({', '.join(domains)}; {len(chosen)} lines; reference only: "
                    "the Japanese source is itself a translation from English)",
            "about": dict(about, note="ja-en: the Japanese source is a human translation of the English; use as a reference value"),
            "audit": [], "translation": cases}
    path = sets / "ja-en.json"
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    written.append((path, len(cases), sum(len(c["lines"]) for c in cases)))
    # 選んだ行 (どの言語でも同じ)。言語どうしを比べる時の確かめに使う
    selection = {"about": about, "rows": [{"document_id": k[0], "segment_id": k[1], "domain": domains_of[k]}
                                          for k in sorted(chosen)]}
    (sets / "selection.json").write_text(json.dumps(selection, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

    print(f"▸ 問題を書きました ({sets}):")
    for path, n_cases, n_lines in written:
        print(f"  {path.name}: 問題 {n_cases}・行 {n_lines}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
