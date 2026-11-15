#!/usr/bin/env python3
"""ききみみの翻訳を、訳す先 13 言語の問題で測り、訳す先ごとの表にまとめる。

    python3 tools/translation-eval/evaluate.py --model ~/Library/Application\\ Support/Kikimimi/Models/LLM/qwen3.5-4b.gguf

問題 (`fetch_wmt24pp.py` で作った sets/*.json) ごとに、組み立てたアプリの評価ハーネス
(`Kikimimi --eval-llm <GGUF> --set <問題> --report <結果>`) を走らせ、終わったら summary.md と summary.json に
まとめる。`--baseline <前の結果のフォルダ>` を付けると、同じ名前の結果と比べる (悪くなった問題は、表に印を付ける)。
問題の数か行の数が前の結果と違う問題は、比べずに「比べられない」と書く。
途中で 1 つ失敗しても、ほかは続け、終わりに失敗を並べる。Python の標準の部品だけを使う。

    python3 tools/translation-eval/evaluate.py --rescore build/translation-eval/results/<前の結果>

`--rescore <結果のフォルダ>` は、LLM を回さずに、そのフォルダの結果に残した訳 (translationOutputs) を、
今の採点の決まりで採点し直す (`Kikimimi --eval-llm none --rescore <結果> --report <新しい結果>`)。
新しいフォルダ (`--out`。既定は <元のフォルダ>-rescored) に、問題ごとの結果と summary.md・summary.json を作る。
元のフォルダは変えない。

    python3 tools/translation-eval/evaluate.py --gate build/translation-eval/sets --out <出力のフォルダ>

`--gate <フォルダ>` は、LLM を回さずに、フォルダの中の問題か結果 (summary.json・gate.json は除く) の全部を
1 回のアプリ (`Kikimimi --eval-llm none --gate <ファイル> … --report gate.json`) に渡し、訳の関門を掛ける。
`--out` (既定は、そのフォルダ) に gate.md・gate.json・gate.log を作る。

`--baseline` と比べた時は、訳す先ごとと全体の「判定」(採る・採らない) を summary.md の末尾・標準出力・
summary.json の `verdict` に出す (決まりは `judge`)。終了コードは判定で変えない (失敗した問題が在る時だけ 1)。

    python3 tools/translation-eval/evaluate.py --save-baseline <名前> --from build/translation-eval/results/<結果>

`--save-baseline <名前>` は、結果のフォルダ (`--from`。測りと一緒に付けた時は、その測りの結果) の summary.json・summary.md と、
問題ごとの結果の JSON を、`tools/translation-eval/baselines/<名前>/` に写す (もう在る名前には上書きしない)。
"""
import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
BASELINES = HERE / "baselines"

# 判定の決まり (`judge`)
# 行がこれより少ない訳す先は「参考」: 30 行の chrF は 1〜2 点揺れるので、採る・採らないに使わない
VERDICT_MIN_LINES = 30
# chrF がこれより大きく上がった訳す先を「良くなった」とする (下がる側の決まり chrFTolerance と同じ 1 点)
VERDICT_CHRF_GAIN = 1.0
# 秒/行が前のこの倍を超えた訳す先を「遅くなった」と知らせる (判定には入れない。秒は、同時に走る作業で揺れるため)
VERDICT_SLOWER_RATIO = 1.10

VERDICT_REFERENCE = "参考 (行が少ない)"
VERDICT_WORSE = "悪くなった"
VERDICT_BETTER = "良くなった"
VERDICT_SAME = "変わらない"
VERDICT_NOT_COMPARED = "比べられない"
OVERALL_ADOPT = "採る"
OVERALL_REJECT = "採らない"
OVERALL_SAME = "変わらない (採る理由が無い)"


def fail(message):
    raise SystemExit("✗ " + message)


def set_target(path):
    """問題のファイルの訳す先 (最初の問題の target。無ければ日本語)"""
    data = json.loads(path.read_text(encoding="utf-8"))
    cases = data.get("translation") or []
    return (cases[0].get("target") or "ja") if cases else None, data


def set_size(data):
    """問題のファイルの、翻訳の問題の数と行の数"""
    cases = data.get("translation") or []
    return len(cases), sum(len(c.get("lines") or []) for c in cases)


def report_size(report):
    """結果の、翻訳の問題の数と行の数"""
    score = report.get("translation") or {}
    return score.get("cases", 0), score.get("lines", 0)


def fmt_chrf(value):
    return "-" if value is None else f"{value:.2f}"


def same_folder(a, b):
    return a is not None and b is not None and a.resolve() == b.resolve()


def run_app(command, log):
    """アプリを走らせ、出力を log に書く。起動できなければ None"""
    try:
        with open(log, "w", encoding="utf-8") as f:
            return subprocess.run(command, stdout=f, stderr=subprocess.STDOUT)
    except OSError:
        return None


def comparable_baseline(baseline, stem, size):
    """同じ名前の前の結果 (問題の数と行の数が同じ時だけ)。(前の結果の場所 or None, 比べられない理由 or None)"""
    if baseline is None:
        return None, None
    before = baseline / f"{stem}.json"
    if not before.exists():
        return None, None
    try:
        old_size = report_size(json.loads(before.read_text(encoding="utf-8")))
    except (OSError, ValueError) as error:
        return None, f"前の結果を読めません ({error})"
    if old_size != size:
        return None, f"問題の数・行の数が違います (前 {old_size[0]} 問 {old_size[1]} 行、今 {size[0]} 問 {size[1]} 行)"
    return before, None


def collect_rows(stem, result, old, returncode, compared, not_comparable):
    rows = []
    by_target = result.get("translationByTarget") or {}
    for code, score in sorted(by_target.items()):
        previous = ((old or {}).get("translationByTarget") or {}).get(code) if old else None
        rows.append({
            "set": stem, "target": code, "lines": score.get("lines", 0),
            "translated": score.get("translated", 0), "inTarget": score.get("inTarget", 0),
            "numbersKept": score.get("numbersKept", 0), "numbersChecked": score.get("numbersChecked", 0),
            "termsKept": score.get("termsKept", 0), "termsChecked": score.get("termsChecked", 0),
            "copied": score.get("copied", 0), "repeated": score.get("repeated", 0), "chrF": score.get("chrF"),
            "retried": score.get("retried", 0), "retryFixed": score.get("retryFixed", 0),
            "secondsPerLine": score.get("seconds", 0) / score["lines"] if score.get("lines") else 0,
            "reused": score.get("reused", 0),
            "baselineChrF": previous.get("chrF") if previous else None,
            "baselineSecondsPerLine": (previous.get("seconds", 0) / previous["lines"]
                                       if previous and previous.get("lines") else None),
            "worse": (returncode == 3) if compared else None,
            "notComparable": not_comparable,
        })
    return rows


def row_verdict(r):
    """問題 1 つ × 訳す先 1 つの判定 (決まりは judge の説明)"""
    if r.get("notComparable") or r.get("worse") is None:
        return VERDICT_NOT_COMPARED
    if (r.get("lines") or 0) < VERDICT_MIN_LINES:
        return VERDICT_REFERENCE
    if r["worse"]:
        return VERDICT_WORSE
    now, before = r.get("chrF"), r.get("baselineChrF")
    if now is not None and before is not None and now - before > VERDICT_CHRF_GAIN:
        return VERDICT_BETTER
    return VERDICT_SAME


def judge(rows):
    """前の結果と比べた行 (collect_rows の行) から、採る・採らないを決める。

    訳す先ごと (行の順に):
    - 前の結果と比べていない (前の結果が無い・問題の数か行の数が違う) → 「比べられない」
    - 行の数が VERDICT_MIN_LINES (30) に満たない → 「参考 (行が少ない)」
    - アプリが「悪くなった」とした (translationRegressions に当たった。終了コード 3) → 「悪くなった」
    - chrF が前より VERDICT_CHRF_GAIN (1.0) より大きく上がった → 「良くなった」
    - ほか → 「変わらない」
    全体: 「悪くなった」が在る → 「採らない」。無く、「良くなった」が 1 つ以上 → 「採る」。どちらでもない → 「変わらない (採る理由が無い)」。
    時間: 秒/行が前の VERDICT_SLOWER_RATIO (1.10) 倍を超えた訳す先を slower に並べる (判定には入れない)
    """
    targets, slower = [], []
    for r in rows:
        verdict = row_verdict(r)
        targets.append({"set": r.get("set"), "target": r.get("target"), "lines": r.get("lines"),
                        "chrF": r.get("chrF"), "baselineChrF": r.get("baselineChrF"), "verdict": verdict})
        before, now = r.get("baselineSecondsPerLine"), r.get("secondsPerLine")
        if verdict != VERDICT_NOT_COMPARED and before and now is not None and now > before * VERDICT_SLOWER_RATIO:
            slower.append({"set": r.get("set"), "target": r.get("target"),
                           "secondsPerLine": now, "baselineSecondsPerLine": before})
    verdicts = [t["verdict"] for t in targets]
    if VERDICT_WORSE in verdicts:
        overall = OVERALL_REJECT
    elif VERDICT_BETTER in verdicts:
        overall = OVERALL_ADOPT
    else:
        overall = OVERALL_SAME
    return {"overall": overall, "targets": targets, "slower": slower,
            "rules": {"minLines": VERDICT_MIN_LINES, "chrFGain": VERDICT_CHRF_GAIN, "slowerRatio": VERDICT_SLOWER_RATIO}}


def verdict_lines(verdict):
    """判定を、summary.md と標準出力に出す行にする"""
    lines = ["## 判定", "", f"- 全体: **{verdict['overall']}**"]
    for t in verdict["targets"]:
        lines.append(f"- {t['set']} ({t['target']}): {t['verdict']} (chrF {fmt_chrf(t['baselineChrF'])} → {fmt_chrf(t['chrF'])}、"
                     f"{t['lines']} 行)")
    if verdict["slower"]:
        lines.append("- 遅くなった (判定には入れない。秒は、同時に走っていた作業で揺れる): "
                     + "、".join(f"{s['set']} ({s['target']}) {s['baselineSecondsPerLine']:.2f} → {s['secondsPerLine']:.2f} 秒/行"
                                for s in verdict["slower"]))
    lines.append(f"- 決まり: {VERDICT_MIN_LINES} 行に満たない訳す先は参考。chrF が {VERDICT_CHRF_GAIN} より大きく上がれば良くなった。"
                 f"悪くなった訳す先が 1 つでも在れば採らない。秒/行が {VERDICT_SLOWER_RATIO} 倍を超えたら遅くなったと知らせる")
    return lines


def write_summary(out, title, info_lines, summary, rows, failures, baseline):
    judgement = judge(rows) if baseline else None
    if judgement:
        summary["verdict"] = judgement
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    lines = [f"# {title}", ""] + info_lines
    lines += ["", "chrF はコーパスの点 (0〜100、高いほど人の訳に近い)。ja-en は日本語が訳された文なので、参考の値。",
              "訳し直しは、訳の後ろが抜けて文に分けて訳し直したまとまりのうち、入れ替えた数 / 訳し直した数。", ""]
    header = ["問題", "訳す先", "行", "訳せた", "その言語", "数", "語", "写し", "繰り返し", "chrF", "秒/行", "訳し直し"]
    if baseline:
        header += ["前の chrF", "前より"]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "---|" * len(header))
    for r in rows:
        cells = [r["set"], r["target"], str(r["lines"]), str(r["translated"]), str(r["inTarget"]),
                 f"{r['numbersKept']}/{r['numbersChecked']}", f"{r['termsKept']}/{r['termsChecked']}",
                 str(r["copied"]), str(r["repeated"]), fmt_chrf(r["chrF"]), f"{r['secondsPerLine']:.2f}",
                 f"{r.get('retryFixed', 0)}/{r.get('retried', 0)}"]
        if baseline:
            if r.get("notComparable"):
                verdict = "比べられない"
            elif r["worse"] is None:
                verdict = "-"
            else:
                verdict = "悪い" if r["worse"] else "悪くない"
            cells += [fmt_chrf(r["baselineChrF"]), verdict]
        lines.append("| " + " | ".join(cells) + " |")
    if failures:
        lines += ["", "## 失敗した問題", ""] + [f"- {f}" for f in failures]
    if judgement:
        lines += [""] + verdict_lines(judgement)
    (out / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"▸ まとめ: {out / 'summary.md'}")
    if judgement:
        for line in verdict_lines(judgement)[2:]:
            print("  " + line.replace("**", ""))
    if failures:
        print("✗ 失敗した問題:")
        for f in failures:
            print("  " + f)
        return 1
    return 0


def rescore(args, app, baseline):
    """--rescore: 前の結果のフォルダの訳を、今の採点の決まりで採点し直す (LLM は使わない)"""
    # 「.」のような相対の道でも、元のフォルダの隣に -rescored を作れるよう、先に絶対の道にする
    source = Path(args.rescore).expanduser().resolve()
    if not source.is_dir():
        fail(f"{source} がありません (--rescore)。")
    out = Path(args.out).expanduser() if args.out else source.parent / f"{source.name}-rescored"
    if same_folder(out, source):
        fail("--out が --rescore と同じフォルダです。元の結果を残すため、別のフォルダを指定してください。")
    if same_folder(out, baseline):
        fail("--out が --baseline と同じフォルダです。前の結果を残すため、別のフォルダを指定してください。")
    files = sorted(p for p in source.glob("*.json") if p.name != "summary.json")
    if not files:
        fail(f"{source} に結果がありません (--rescore)。")
    out.mkdir(parents=True, exist_ok=True)
    started = datetime.datetime.now()
    print(f"▸ {source} の {len(files)} 個の結果を採点し直します → {out}")
    rows, failures, model = [], [], None
    for number, path in enumerate(files, 1):
        try:
            original = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            failures.append(f"{path.name}: 読めません ({error})")
            continue
        model = model or original.get("model")
        report = out / path.name
        log = out / f"{path.stem}.log"
        command = [str(app), "--eval-llm", "none", "--rescore", str(path), "--report", str(report)]
        before, not_comparable = comparable_baseline(baseline, path.stem, report_size(original))
        if before is not None:
            command += ["--baseline", str(before)]
        print(f"  [{number}/{len(files)}] {path.name}", flush=True)
        done = run_app(command, log)
        if done is None:
            failures.append(f"{path.name}: アプリを起動できませんでした")
            continue
        if done.returncode == 2:
            failures.append(f"{path.name}: 訳が残っていない結果です (この版の --eval-llm で測り直してください。出力は {log})")
            continue
        compared = before is not None
        if done.returncode not in ((0, 3) if compared else (0,)) or not report.exists():
            failures.append(f"{path.name}: 終了コード {done.returncode} (出力は {log})")
            continue
        result = json.loads(report.read_text(encoding="utf-8"))
        old = json.loads(before.read_text(encoding="utf-8")) if compared else None
        rows += collect_rows(path.stem, result, old, done.returncode, compared, not_comparable)
    finished = datetime.datetime.now()
    summary = {
        "model": model, "rescoredFrom": str(source), "started": started.isoformat(timespec="seconds"),
        "finished": finished.isoformat(timespec="seconds"), "sets": len(files),
        "baseline": str(baseline) if baseline else None, "rows": rows, "failures": failures,
    }
    info = [f"- 採点し直した元の結果: {source} (LLM は回していない。秒/行は元の結果の値)",
            f"- 日付: {started.strftime('%Y-%m-%d %H:%M')}", f"- 結果の数: {len(files)}"]
    if baseline:
        info.append(f"- 比べた前の結果: {baseline}")
    return write_summary(out, f"翻訳の評価 (採点し直し): {model or '-'}", info, summary, rows, failures, baseline)


def fmt_ratio(count):
    return "-" if count is None else f"{count.get('caught', 0)}/{count.get('tried', 0)}"


def gate(args, app):
    """--gate: フォルダの中の問題か結果の全部に、訳の関門を掛ける (LLM は使わない)"""
    source = Path(args.gate).expanduser().resolve()
    if not source.is_dir():
        fail(f"{source} がありません (--gate)。")
    out = Path(args.out).expanduser() if args.out else source
    # 前に作った gate.json と、まとめの summary.json は、問題でも結果でもないので外す
    files = sorted(p for p in source.glob("*.json") if p.name not in ("summary.json", "gate.json"))
    if not files:
        fail(f"{source} に問題も結果もありません (--gate)。")
    out.mkdir(parents=True, exist_ok=True)
    report = out / "gate.json"
    log = out / "gate.log"
    command = [str(app), "--eval-llm", "none"]
    for path in files:
        command += ["--gate", str(path)]
    command += ["--report", str(report)]
    print(f"▸ {source} の {len(files)} 個のファイルに関門を掛けます → {out}")
    done = run_app(command, log)
    if done is None:
        fail("アプリを起動できませんでした。")
    if done.returncode != 0 or not report.exists():
        fail(f"終了コード {done.returncode} (出力は {log})")
    result = json.loads(report.read_text(encoding="utf-8"))
    flags = ["failed", "script", "long", "repeated", "copied", "language", "number", "term", "short"]
    lines = [f"# 訳の関門の測り: {source.name}", "",
             f"- 日付: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}",
             f"- 読んだファイル: {', '.join(result.get('files') or [])}",
             f"- short の比: {result.get('shortRatio')} (原文の重さ {result.get('shortMinimumSourceWeight')} 以上の時だけ見る)",
             f"- 重い印 (訳し直す物): {', '.join(result.get('severe') or [])}",
             f"- 細かい所 (原文・訳・符号): {report}"]
    references = result.get("references") or {}
    if references:
        mutations = sorted({m for s in references.values() for m in (s.get("mutations") or {})})
        lines += ["", "## 人の訳に掛けた結果", "",
                  "印の列は、人の訳に誤って印が付いた数。「壊し」の列は、壊した訳を拾った数 / 壊した数。", ""]
        header = ["訳す先", "まとまり", "印あり"] + flags + [f"壊し {m}" for m in mutations]
        lines += ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
        for code, s in sorted(references.items()):
            cells = [code, str(s.get("units", 0)), str(s.get("flaggedUnits", 0))]
            cells += [str((s.get("flags") or {}).get(f, 0)) for f in flags]
            cells += [fmt_ratio((s.get("mutations") or {}).get(m)) for m in mutations]
            lines.append("| " + " | ".join(cells) + " |")
    outputs = result.get("outputs") or {}
    if outputs:
        lines += ["", "## LLM の訳に掛けた結果", "",
                  "chrF は、人の訳の在るまとまりだけのコーパスの点 (かっこの中は、まとまりの数)。", ""]
        header = ["訳す先", "まとまり", "印あり", "重い印"] + flags + ["chrF 印あり", "chrF 印なし"]
        lines += ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
        for code, s in sorted(outputs.items()):
            cells = [code, str(s.get("units", 0)), str(s.get("flaggedUnits", 0)), str(s.get("severeUnits", 0))]
            cells += [str((s.get("flags") or {}).get(f, 0)) for f in flags]
            cells += [f"{fmt_chrf(s.get('flaggedChrF'))} ({s.get('flaggedWithReference', 0)})",
                      f"{fmt_chrf(s.get('unflaggedChrF'))} ({s.get('unflaggedWithReference', 0)})"]
            lines.append("| " + " | ".join(cells) + " |")
    (out / "gate.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"▸ まとめ: {out / 'gate.md'}")
    return 0


def save_baseline(name, source):
    """結果のフォルダ source の summary.json・summary.md と、問題ごとの結果の JSON を、baselines/<name>/ に写す。
    もう在る名前には上書きしない。写したファイルの数を返す"""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name or ""):
        fail(f"--save-baseline の名前 {name!r} は、英数字と . _ - だけにしてください (先頭は英数字)。")
    source = Path(source).expanduser().resolve()
    if not source.is_dir():
        fail(f"{source} がありません (--save-baseline の元)。")
    if not (source / "summary.json").exists():
        fail(f"{source} に summary.json がありません (結果のフォルダを指定してください)。")
    target = BASELINES / name
    if target.exists():
        fail(f"{target} はもう在ります。上書きしないので、別の名前にしてください。")
    files = [source / "summary.json"] + ([source / "summary.md"] if (source / "summary.md").exists() else [])
    files += sorted(p for p in source.glob("*.json") if p.name not in ("summary.json", "gate.json"))
    target.mkdir(parents=True)
    for path in files:
        shutil.copy2(path, target / path.name)
    print(f"▸ 基準を残しました: {target} ({len(files)} 個のファイル)")
    return len(files)


def main():
    parser = argparse.ArgumentParser(description="翻訳を 13 言語の問題で測る")
    parser.add_argument("--model", help="測る LLM (GGUF)。--rescore の時は要らない")
    parser.add_argument("--app", default=str(REPO / "build/Kikimimi.app/Contents/MacOS/Kikimimi"),
                        help="ききみみのアプリの本体 (既定 build/Kikimimi.app/Contents/MacOS/Kikimimi)")
    parser.add_argument("--sets", default=str(REPO / "build/translation-eval/sets"), help="問題のフォルダ")
    parser.add_argument("--targets", help="測る訳す先 (例: fr,th,en。既定は全部)")
    parser.add_argument("--out", help="結果のフォルダ (既定 build/translation-eval/results/<モデルの名前>-<日時>。"
                                      "--rescore の時は <元のフォルダ>-rescored)")
    parser.add_argument("--baseline", help="前の結果のフォルダ (同じ名前の結果と比べる)")
    parser.add_argument("--rescore", help="前の結果のフォルダ: LLM を回さず、残した訳を今の採点の決まりで採点し直す")
    parser.add_argument("--gate", help="問題か結果のフォルダ: LLM を回さず、訳の関門を掛けて gate.md・gate.json を作る")
    parser.add_argument("--adapter", help="アプリにそのまま渡す: 追加学習の差分 (.lora.gguf)")
    parser.add_argument("--ledger", help="アプリにそのまま渡す: 学習した直しの台帳 (.json)")
    parser.add_argument("--cpu", action="store_true", help="アプリにそのまま渡す: GPU を使わない")
    parser.add_argument("--no-split-retry", action="store_true",
                        help="アプリにそのまま渡す: 訳の後ろが抜けた時の、文に分けた訳し直しを切る")
    parser.add_argument("--no-terms", action="store_true",
                        help="アプリにそのまま渡す: 問題の訳語の対を翻訳に渡さない (採点は対で行う)")
    parser.add_argument("--memory", help="アプリにそのまま渡す: 訳の記憶 (translation-memory.json)。"
                                         "問題の行と同じ文は、記憶から抜いて測る")
    parser.add_argument("--save-baseline", metavar="NAME",
                        help="結果を tools/translation-eval/baselines/<NAME>/ に写す (--from のフォルダ、"
                             "無ければこの測り・採点し直しの結果)。もう在る名前には上書きしない")
    parser.add_argument("--from", dest="from_folder", help="--save-baseline で写す結果のフォルダ")
    args = parser.parse_args()

    # 基準を写すだけ (アプリは使わない)
    if args.save_baseline and args.from_folder:
        save_baseline(args.save_baseline, args.from_folder)
        return 0
    if args.save_baseline and not (args.model or args.rescore):
        fail("--save-baseline には、写す結果のフォルダを --from で指定してください。")
    if args.save_baseline and (BASELINES / args.save_baseline).exists():
        fail(f"{BASELINES / args.save_baseline} はもう在ります。上書きしないので、別の名前にしてください。")

    app = Path(args.app).expanduser()
    baseline = Path(args.baseline).expanduser() if args.baseline else None
    if baseline and not baseline.is_dir():
        fail(f"{baseline} がありません (--baseline)。")
    if args.out and same_folder(Path(args.out).expanduser(), baseline):
        fail("--out と --baseline が同じフォルダです。前の結果を上書きしてしまうので、別のフォルダを指定してください。")
    if not app.exists():
        fail(f"{app} がありません。先に make app でアプリを組み立ててください (--app)。")
    if args.gate:
        return gate(args, app)
    if args.rescore:
        code = rescore(args, app, baseline)
        if args.save_baseline and code == 0:
            source = Path(args.rescore).expanduser().resolve()
            save_baseline(args.save_baseline, Path(args.out).expanduser() if args.out
                          else source.parent / f"{source.name}-rescored")
        return code

    if not args.model:
        fail("--model を指定してください (採点し直すだけなら --rescore)。")
    model = Path(args.model).expanduser()
    sets_dir = Path(args.sets).expanduser()
    if not model.exists():
        fail(f"{model} がありません (--model)。")
    files = sorted(p for p in sets_dir.glob("*.json") if p.name != "selection.json")
    if not files:
        fail(f"{sets_dir} に問題がありません。先に fetch_wmt24pp.py を走らせてください (--sets)。")
    wanted = {t.strip() for t in args.targets.split(",") if t.strip()} if args.targets else None
    started = datetime.datetime.now()
    out = Path(args.out).expanduser() if args.out else \
        REPO / "build/translation-eval/results" / f"{model.stem}-{started.strftime('%Y%m%d-%H%M%S')}"
    if same_folder(out, baseline):
        fail("--out と --baseline が同じフォルダです。前の結果を上書きしてしまうので、別のフォルダを指定してください。")
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
        # 問題の数・行の数が違う前の結果 (問題を作り直した後など) とは比べない
        before, not_comparable = comparable_baseline(baseline, path.stem, set_size(data))
        if before is not None:
            command += ["--baseline", str(before)]
        if args.adapter:
            command += ["--adapter", str(Path(args.adapter).expanduser())]
        if args.ledger:
            command += ["--ledger", str(Path(args.ledger).expanduser())]
        if args.cpu:
            command.append("--cpu")
        if args.no_split_retry:
            command.append("--no-split-retry")
        if args.no_terms:
            command.append("--no-terms")
        if args.memory:
            command += ["--memory", str(Path(args.memory).expanduser())]
        print(f"  [{number}/{len(chosen)}] {path.name} (→ {target})", flush=True)
        if not_comparable:
            print(f"      前の結果と比べません: {not_comparable}", flush=True)
        done = run_app(command, log)
        if done is None:
            failures.append(f"{path.name}: アプリを起動できませんでした")
            continue
        compared = before is not None
        if done.returncode not in ((0, 3) if compared else (0,)) or not report.exists():
            failures.append(f"{path.name}: 終了コード {done.returncode} (出力は {log})")
            continue
        result = json.loads(report.read_text(encoding="utf-8"))
        old = json.loads(before.read_text(encoding="utf-8")) if compared else None
        rows += collect_rows(path.stem, result, old, done.returncode, compared, not_comparable)
        by_target = result.get("translationByTarget") or {}
        points = ", ".join(c + " " + fmt_chrf(s.get("chrF")) for c, s in sorted(by_target.items())) or "-"
        print("      chrF " + points + ("  ← 前より悪い" if compared and done.returncode == 3 else ""), flush=True)

    finished = datetime.datetime.now()
    summary = {
        "model": model.name, "adapter": Path(args.adapter).name if args.adapter else None,
        "ledger": bool(args.ledger), "splitRetry": not args.no_split_retry, "terms": not args.no_terms,
        "memory": bool(args.memory), "started": started.isoformat(timespec="seconds"),
        "finished": finished.isoformat(timespec="seconds"), "sets": len(chosen), "data": about,
        "baseline": str(baseline) if baseline else None, "rows": rows, "failures": failures,
    }
    info = [f"- 日付: {started.strftime('%Y-%m-%d %H:%M')} (かかった時間 {int((finished - started).total_seconds() // 60)} 分)"]
    if args.adapter:
        info.append(f"- 追加学習の差分: {Path(args.adapter).name}")
    if args.ledger:
        info.append("- 学習した直しの台帳: 使った")
    if args.no_split_retry:
        info.append("- 文に分けた訳し直し: 切 (--no-split-retry)")
    if args.no_terms:
        info.append("- 訳語の対: 翻訳に渡さない (--no-terms)")
    if args.memory:
        reused = sum(r.get("reused", 0) for r in rows)
        info.append(f"- 訳の記憶: 使った (問題の行と同じ文は抜いた。記憶に当たった行 {reused})")
    info.append(f"- 問題の数: {len(chosen)}")
    if about:
        info.append(f"- データ: WMT24++ ({about.get('dataset')}, {about.get('license')})、領域 {', '.join(about.get('domains', []))}、"
                    f"1 言語 {about.get('lines')} 行 (領域ごとに {about.get('perDomain')} 行、種 {about.get('seed')})")
    if baseline:
        info.append(f"- 比べた前の結果: {baseline}")
    code = write_summary(out, f"翻訳の評価: {model.name}", info, summary, rows, failures, baseline)
    if args.save_baseline and code == 0:
        save_baseline(args.save_baseline, out)
    return code


if __name__ == "__main__":
    sys.exit(main())
