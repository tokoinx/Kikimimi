#!/usr/bin/env python3
"""ききみみの翻訳を、訳す先 13 言語の問題で測り、訳す先ごとの表にまとめる。

    python3 tools/translation-eval/evaluate.py --model ~/Library/Application\\ Support/Kikimimi/Models/LLM/qwen3.5-4b.gguf

問題 (`fetch_wmt24pp.py` で作った sets/*.json) ごとに、組み立てたアプリの評価ハーネス
(`Kikimimi --eval-llm <GGUF> --set <問題> --report <結果>`) を走らせ、終わったら summary.md と summary.json に
まとめる。`--baseline <前の結果のフォルダ>` を付けると、同じ名前の結果と比べる (悪くなった問題は、表に印を付ける)。
途中で 1 つ失敗しても、ほかは続け、終わりに失敗を並べる。Python の標準の部品だけを使う。
"""
import argparse
import datetime
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent


def fail(message):
    raise SystemExit("✗ " + message)


def set_target(path):
    """問題のファイルの訳す先 (最初の問題の target。無ければ日本語)"""
    data = json.loads(path.read_text(encoding="utf-8"))
    cases = data.get("translation") or []
    return (cases[0].get("target") or "ja") if cases else None, data


def fmt_chrf(value):
    return "-" if value is None else f"{value:.2f}"


def main():
    parser = argparse.ArgumentParser(description="翻訳を 13 言語の問題で測る")
    parser.add_argument("--model", required=True, help="測る LLM (GGUF)")
    parser.add_argument("--app", default=str(REPO / "build/Kikimimi.app/Contents/MacOS/Kikimimi"),
                        help="ききみみのアプリの本体 (既定 build/Kikimimi.app/Contents/MacOS/Kikimimi)")
    parser.add_argument("--sets", default=str(REPO / "build/translation-eval/sets"), help="問題のフォルダ")
    parser.add_argument("--targets", help="測る訳す先 (例: fr,th,en。既定は全部)")
    parser.add_argument("--out", help="結果のフォルダ (既定 build/translation-eval/results/<モデルの名前>-<日時>)")
    parser.add_argument("--baseline", help="前の結果のフォルダ (同じ名前の結果と比べる)")
    parser.add_argument("--adapter", help="アプリにそのまま渡す: 追加学習の差分 (.lora.gguf)")
    parser.add_argument("--ledger", help="アプリにそのまま渡す: 学習した直しの台帳 (.json)")
    parser.add_argument("--cpu", action="store_true", help="アプリにそのまま渡す: GPU を使わない")
    args = parser.parse_args()

    model = Path(args.model).expanduser()
    app = Path(args.app).expanduser()
    sets_dir = Path(args.sets).expanduser()
    if not model.exists():
        fail(f"{model} がありません (--model)。")
    if not app.exists():
        fail(f"{app} がありません。先に make app でアプリを組み立ててください (--app)。")
    files = sorted(p for p in sets_dir.glob("*.json") if p.name != "selection.json")
    if not files:
        fail(f"{sets_dir} に問題がありません。先に fetch_wmt24pp.py を走らせてください (--sets)。")
    wanted = {t.strip() for t in args.targets.split(",") if t.strip()} if args.targets else None
    baseline = Path(args.baseline).expanduser() if args.baseline else None
    if baseline and not baseline.is_dir():
        fail(f"{baseline} がありません (--baseline)。")
    started = datetime.datetime.now()
    out = Path(args.out).expanduser() if args.out else \
        REPO / "build/translation-eval/results" / f"{model.stem}-{started.strftime('%Y%m%d-%H%M%S')}"
    out.mkdir(parents=True, exist_ok=True)

    chosen = []
    for path in files:
        target, data = set_target(path)
        if target is None or (wanted is not None and target not in wanted):
            continue
        chosen.append((path, target, data))
    if not chosen:
        fail("測る問題がありません (--targets を確かめてください)。")

    print(f"▸ {model.name} で {len(chosen)} 個の問題を測ります → {out}")
    rows, failures, about = [], [], None
    for number, (path, target, data) in enumerate(chosen, 1):
        about = about or data.get("about")
        report = out / f"{path.stem}.json"
        log = out / f"{path.stem}.log"
        command = [str(app), "--eval-llm", str(model), "--set", str(path), "--report", str(report)]
        before = baseline / f"{path.stem}.json" if baseline else None
        if before is not None and before.exists():
            command += ["--baseline", str(before)]
        if args.adapter:
            command += ["--adapter", str(Path(args.adapter).expanduser())]
        if args.ledger:
            command += ["--ledger", str(Path(args.ledger).expanduser())]
        if args.cpu:
            command.append("--cpu")
        print(f"  [{number}/{len(chosen)}] {path.name} (→ {target})", flush=True)
        try:
            with open(log, "w", encoding="utf-8") as f:
                done = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT)
        except OSError as error:
            failures.append(f"{path.name}: アプリを起動できませんでした ({error})")
            continue
        compared = before is not None and before.exists()
        if done.returncode not in ((0, 3) if compared else (0,)) or not report.exists():
            failures.append(f"{path.name}: 終了コード {done.returncode} (出力は {log})")
            continue
        result = json.loads(report.read_text(encoding="utf-8"))
        old = json.loads(before.read_text(encoding="utf-8")) if compared else None
        by_target = result.get("translationByTarget") or {}
        for code, score in sorted(by_target.items()):
            previous = ((old or {}).get("translationByTarget") or {}).get(code) if old else None
            rows.append({
                "set": path.stem, "target": code, "lines": score.get("lines", 0),
                "translated": score.get("translated", 0), "inTarget": score.get("inTarget", 0),
                "numbersKept": score.get("numbersKept", 0), "numbersChecked": score.get("numbersChecked", 0),
                "termsKept": score.get("termsKept", 0), "termsChecked": score.get("termsChecked", 0),
                "copied": score.get("copied", 0), "repeated": score.get("repeated", 0), "chrF": score.get("chrF"),
                "secondsPerLine": score.get("seconds", 0) / score["lines"] if score.get("lines") else 0,
                "baselineChrF": previous.get("chrF") if previous else None,
                "worse": (done.returncode == 3) if compared else None,
            })
        points = ", ".join(c + " " + fmt_chrf(s.get("chrF")) for c, s in sorted(by_target.items())) or "-"
        print("      chrF " + points + ("  ← 前より悪い" if compared and done.returncode == 3 else ""), flush=True)

    finished = datetime.datetime.now()
    summary = {
        "model": model.name, "adapter": Path(args.adapter).name if args.adapter else None,
        "ledger": bool(args.ledger), "started": started.isoformat(timespec="seconds"),
        "finished": finished.isoformat(timespec="seconds"), "sets": len(chosen), "data": about,
        "baseline": str(baseline) if baseline else None, "rows": rows, "failures": failures,
    }
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

    lines = [f"# 翻訳の評価: {model.name}", ""]
    lines.append(f"- 日付: {started.strftime('%Y-%m-%d %H:%M')} (かかった時間 {int((finished - started).total_seconds() // 60)} 分)")
    if args.adapter:
        lines.append(f"- 追加学習の差分: {Path(args.adapter).name}")
    if args.ledger:
        lines.append("- 学習した直しの台帳: 使った")
    lines.append(f"- 問題の数: {len(chosen)}")
    if about:
        lines.append(f"- データ: WMT24++ ({about.get('dataset')}, {about.get('license')})、領域 {', '.join(about.get('domains', []))}、"
                     f"1 言語 {about.get('lines')} 行 (領域ごとに {about.get('perDomain')} 行、種 {about.get('seed')})")
    if baseline:
        lines.append(f"- 比べた前の結果: {baseline}")
    lines += ["", "chrF はコーパスの点 (0〜100、高いほど人の訳に近い)。ja-en は日本語が訳された文なので、参考の値。", ""]
    header = ["問題", "訳す先", "行", "訳せた", "その言語", "数", "語", "写し", "繰り返し", "chrF", "秒/行"]
    if baseline:
        header += ["前の chrF", "前より"]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "---|" * len(header))
    for r in rows:
        cells = [r["set"], r["target"], str(r["lines"]), str(r["translated"]), str(r["inTarget"]),
                 f"{r['numbersKept']}/{r['numbersChecked']}", f"{r['termsKept']}/{r['termsChecked']}",
                 str(r["copied"]), str(r["repeated"]), fmt_chrf(r["chrF"]), f"{r['secondsPerLine']:.2f}"]
        if baseline:
            cells += [fmt_chrf(r["baselineChrF"]),
                      "-" if r["worse"] is None else ("悪い" if r["worse"] else "悪くない")]
        lines.append("| " + " | ".join(cells) + " |")
    if failures:
        lines += ["", "## 失敗した問題", ""] + [f"- {f}" for f in failures]
    (out / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"▸ まとめ: {out / 'summary.md'}")
    if failures:
        print("✗ 失敗した問題:")
        for f in failures:
            print("  " + f)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
