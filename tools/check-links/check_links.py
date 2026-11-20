#!/usr/bin/env python3
"""リンク切れと、古くなった依存に、早く気づくための検査。

調べる物:
  (a) アプリが実行時に使う URL (モデルの一覧 Sources/KikimimiCore/Catalog/models.json から作る)
  (b) 文書・CI・道具のファイルの中に書いてある https:// の URL
  (参考) Package.swift の binaryTarget の版と、GitHub の最新の版の違い

python3 の標準ライブラリだけで動く。走らせ方と結果の読み方は、同じ場所の README.md に在る。
画面や記録に出す文は英語にしてある (CI の記録に出るので)。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
# モデルの一覧 (アプリが埋め込むのと同じ JSON)。実行時の URL は、ここのテンプレートから作る
CATALOG = ROOT / "Sources/KikimimiCore/Catalog/models.json"
IGNORE_LIST = HERE / "ignore.txt"

USER_AGENT = "Kikimimi-link-check"
TIMEOUT = 20          # 1 回の問い合わせを待つ秒数
RETRIES = 2           # 失敗した時に、やり直す回数
RETRY_WAIT = 3        # やり直すまでの秒数
HOST_GAP = 0.2        # 同じホストへ続けて当てる時に、あける秒数
MAX_REDIRECTS = 10

# (b) で見るファイル (ROOT からの glob)
DOC_GLOBS = [
    "README.md",
    "README.en.md",
    "docs/**/*.md",
    "Package.swift",
    ".github/workflows/*.yml",
    "tools/**/*.py",
    "tools/**/*.md",
    ".claude/skills/**/*.md",
]
SKIP_DIRS = {"build", ".build", ".git", "__pycache__"}

# URL として拾う文字。空白・引用符・括弧・非 ASCII などで止める
URL_RE = re.compile(r"https://[^\s\"'`\\()\[\]{}<>|\x80-\U0010ffff]+")
# 拾った URL のすぐ後ろにこれが在れば、組み立て途中の URL (${…}・{…}・<…>・$(…)・\(…)・…) なので飛ばす
TEMPLATE_NEXT = ("$", "{", "<", "\\", "…")
TRAILING = ".,;:!?*"

STATUS_ORDER = ["BROKEN", "UNSURE", "MOVED", "OK"]


# ---------------------------------------------------------------- URL を集める

def read_list(path: Path) -> list[tuple[str, int]]:
    """1 行に 1 つの一覧を読む。# の行と空の行は飛ばす。(内容, 行番号) を返す"""
    items = []
    if not path.exists():
        return items
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        s = line.strip()
        if s and not s.startswith("#"):
            items.append((s, n))
    return items


def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def collect_list(path: Path) -> dict[str, list[tuple[str, int]]]:
    found: dict[str, list[tuple[str, int]]] = {}
    for url, n in read_list(path):
        found.setdefault(url, []).append((rel(path), n))
    return found


def fill(template: str, values: dict[str, str]) -> str:
    """テンプレートの {名前} を、そのまま置き換える (アプリの ModelCatalogData.fill と同じやり方)"""
    for name, value in values.items():
        template = template.replace("{" + name + "}", value)
    return template


def catalog_urls(path: Path = CATALOG) -> list[tuple[str, int]]:
    """モデルの一覧から、アプリが実行時に使う URL を作る。(URL, JSON の中の行番号) を返す。
    並び: Whisper (一覧の順) → VAD → LLM の tree API (モデルの順 × リポジトリの順)。
    LLM は、アプリがファイルの一覧を読む tree API の URL を載せる (取るファイルは、その一覧から選ぶため)"""
    text = path.read_text(encoding="utf-8")
    data = json.loads(text)
    lines = text.splitlines()

    def line_of(needle: str) -> int:
        # 注釈に出す行 (見つからなければ 1 行目)
        return next((n for n, line in enumerate(lines, start=1) if needle in line), 1)

    whisper, vad, llm = data["whisper"], data["vad"], data["llm"]
    items = []
    for model in whisper["models"]:
        file_name = fill(whisper["fileNameTemplate"], {"id": model["id"]})
        url = fill(whisper["downloadURLTemplate"], {"fileName": file_name})
        items.append((url, line_of(json.dumps(model["id"]))))
    items.append((vad["url"], line_of(vad["url"])))
    for model in llm["models"]:
        for repository in model["repositories"]:
            items.append((fill(llm["treeURLTemplate"], {"repository": repository}), line_of(json.dumps(repository))))
    return items


def collect_catalog(path: Path = CATALOG) -> dict[str, list[tuple[str, int]]]:
    found: dict[str, list[tuple[str, int]]] = {}
    for url, n in catalog_urls(path):
        found.setdefault(url, []).append((rel(path), n))
    return found


def doc_files() -> list[Path]:
    seen = set()
    files = []
    for pattern in DOC_GLOBS:
        for p in sorted(ROOT.glob(pattern)):
            if not p.is_file() or p.resolve() == Path(__file__).resolve():
                continue
            parts = p.relative_to(ROOT).parts
            if any(part in SKIP_DIRS for part in parts):
                continue
            if p not in seen:
                seen.add(p)
                files.append(p)
    return files


def urls_in_line(line: str) -> list[str]:
    urls = []
    for m in URL_RE.finditer(line):
        url = m.group(0)
        rest = line[m.end():]
        if rest.startswith(TEMPLATE_NEXT) or "$" in url or "…" in url:
            continue
        # 文字列をつないで作る URL ("https://…/" + name) も、組み立て途中として飛ばす
        if re.match(r"[\"']\s*\+", rest):
            continue
        url = url.rstrip(TRAILING)
        if url.count("/") < 2 or url == "https://":
            continue
        urls.append(url)
    return urls


def collect_docs() -> dict[str, list[tuple[str, int]]]:
    found: dict[str, list[tuple[str, int]]] = {}
    for path in doc_files():
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for n, line in enumerate(text.splitlines(), start=1):
            for url in urls_in_line(line):
                found.setdefault(url, []).append((rel(path), n))
    return found


# ---------------------------------------------------------------- 調べる

class NoRedirect(urllib.request.HTTPRedirectHandler):
    """転送を自分で追うため (始めの応答が 301 / 308 かを見たいので)、urllib には追わせない"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)
_last_hit: dict[str, float] = {}


def wait_for_host(host: str) -> None:
    last = _last_hit.get(host)
    if last is not None:
        gap = time.monotonic() - last
        if gap < HOST_GAP:
            time.sleep(HOST_GAP - gap)
    _last_hit[host] = time.monotonic()


def one_request(url: str, method: str) -> tuple[int | None, str | None, str | None]:
    """1 回だけ問い合わせる。(状態コード, 転送先, つながらなかった理由) を返す"""
    host = urllib.parse.urlsplit(url).hostname or ""
    wait_for_host(host)
    headers = {"User-Agent": USER_AGENT, "Accept": "*/*"}
    if method == "GET":
        headers["Range"] = "bytes=0-0"
    token = os.environ.get("GITHUB_TOKEN")
    if token and host == "api.github.com":
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, method=method, headers=headers)
    try:
        with OPENER.open(req, timeout=TIMEOUT) as resp:
            if method == "GET":
                resp.read(1)
            return resp.status, None, None
    except urllib.error.HTTPError as e:
        location = e.headers.get("Location") if e.headers else None
        if location:
            location = urllib.parse.urljoin(url, location)
        return e.code, location, None
    except TimeoutError:
        return None, None, "timeout"
    except urllib.error.URLError as e:
        reason = e.reason
        if isinstance(reason, TimeoutError) or "timed out" in str(reason):
            return None, None, "timeout"
        return None, None, f"unreachable ({reason})"
    except OSError as e:
        return None, None, f"unreachable ({e})"


def with_retries(url: str, method: str) -> tuple[int | None, str | None, str | None]:
    """つながらない時と、429 / 5xx の時は、間をあけてやり直す"""
    result = one_request(url, method)
    for _ in range(RETRIES):
        code, _, err = result
        # 証明書を確かめられない時は、やり直しても同じなので、やり直さない
        if err is not None and "CERTIFICATE_VERIFY_FAILED" in err:
            break
        temporary = err is not None or code == 429 or (code is not None and code >= 500 and code != 501)
        if not temporary:
            break
        time.sleep(RETRY_WAIT)
        result = one_request(url, method)
    return result


def follow(url: str, method: str) -> dict:
    """転送を追いながら問い合わせる"""
    first_code = None
    first_location = None
    current = url
    hops = 0
    while True:
        code, location, err = with_retries(current, method)
        if first_code is None:
            first_code, first_location = code, location
        if err is not None:
            return {"code": None, "error": err, "final": current,
                    "first_code": first_code, "first_location": first_location}
        if code in (301, 302, 303, 307, 308) and location:
            hops += 1
            if hops > MAX_REDIRECTS:
                return {"code": code, "error": "too many redirects", "final": current,
                        "first_code": first_code, "first_location": first_location}
            current = location
            continue
        return {"code": code, "error": None, "final": current,
                "first_code": first_code, "first_location": first_location}


def check_url(url: str) -> dict:
    r = follow(url, "HEAD")
    # HEAD を受け付けない所 (GitHub の Releases の zip など) は、1 バイトだけの GET で見る
    if r["code"] in (403, 405, 501):
        r = follow(url, "GET")
        r["method"] = "GET (Range)"
    else:
        r["method"] = "HEAD"

    code, err = r["code"], r["error"]
    if err == "timeout":
        status, detail = "UNSURE", "timeout"
    elif err is not None:
        status, detail = "BROKEN", err
    elif code == 429 or (code >= 500 and code != 501):
        status, detail = "UNSURE", f"HTTP {code}"
    elif code >= 400:
        status, detail = "BROKEN", f"HTTP {code}"
    elif r["first_code"] in (301, 308) and r["first_location"] and r["first_location"] != url:
        status, detail = "MOVED", f"-> {r['first_location']}"
    else:
        status, detail = "OK", f"HTTP {code}"
    return {"url": url, "status": status, "detail": detail, "code": code,
            "final_url": r["final"], "method": r["method"]}


# ---------------------------------------------------------------- 依存の新しさ

BINARY_RE = re.compile(
    r"https://github\.com/(?P<owner>[^/\s\"]+)/(?P<repo>[^/\s\"]+)/releases/download/"
    r"(?P<tag>[^/\s\"]+)/(?P<asset>[^/\s\"]+\.zip)")


def github_json(url: str) -> tuple[int | None, object]:
    host = urllib.parse.urlsplit(url).hostname or ""
    wait_for_host(host)
    headers = {"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token and host == "api.github.com":
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, None
    except (urllib.error.URLError, OSError, ValueError):
        return None, None


def tag_shape(tag: str) -> str:
    """版の名前の形 (数字を N にした物)。v1.9.2 -> vN.N.N、b12211 -> bN"""
    return re.sub(r"\d+", "N", tag)


def check_dependencies() -> list[dict]:
    """Package.swift の binaryTarget の版と、GitHub の release を比べる (参考。失敗にはしない)。

    llama.cpp の bNNNN の release は prerelease の印が付き、releases/latest は zip の無い release を指す事がある。
    whisper.cpp は、zip が vX.Y.Z でなく bNNNN の release に付く形に変わった。
    そこで「最新」は、今の zip と同じ形の名前 (版の所だけ違う) の zip が付いた、いちばん新しい release とする。
    GitHub が latest と印を付けた release も、別に出す。
    """
    package = ROOT / "Package.swift"
    if not package.exists():
        return []
    deps = []
    for n, line in enumerate(package.read_text(encoding="utf-8").splitlines(), start=1):
        m = BINARY_RE.search(line)
        if not m:
            continue
        owner, repo, tag, asset = m["owner"], m["repo"], m["tag"], m["asset"]
        dep = {"name": repo, "current": tag, "asset": asset, "file": "Package.swift", "line": n,
               "latest": None, "latest_asset": None, "latest_prerelease": None, "outdated": None,
               "tag_form_changed": None, "github_latest": None, "github_latest_has_zip": None, "note": None}
        api = f"https://api.github.com/repos/{owner}/{repo}"
        code_list, releases = github_json(f"{api}/releases?per_page=30")
        code_latest, latest_release = github_json(f"{api}/releases/latest")
        if code_list in (403, 429) or code_latest in (403, 429):
            dep["note"] = "unknown (rate limited)"
            deps.append(dep)
            continue
        if code_list != 200 or not isinstance(releases, list):
            dep["note"] = f"unknown (HTTP {code_list})" if code_list else "unknown (unreachable)"
            deps.append(dep)
            continue
        if code_latest == 200 and isinstance(latest_release, dict):
            dep["github_latest"] = latest_release.get("tag_name")
            dep["github_latest_has_zip"] = any(
                "xcframework" in a.get("name", "") for a in latest_release.get("assets", []))
        # 今の zip の名前の、版の所だけを何でもよいとした形
        if tag in asset:
            head, _, tail = asset.partition(tag)
            pattern = re.compile(re.escape(head) + r"(?P<tag>[^/]+)" + re.escape(tail) + "$")
        else:
            pattern = re.compile(re.escape(asset) + "$")
        for rel_ in releases:  # 新しい順に並んでいる
            if rel_.get("draft"):
                continue
            hit = next((a.get("name") for a in rel_.get("assets", []) if pattern.match(a.get("name", ""))), None)
            if hit:
                dep["latest"] = rel_.get("tag_name")
                dep["latest_asset"] = hit
                dep["latest_prerelease"] = bool(rel_.get("prerelease"))
                break
        if dep["latest"]:
            dep["outdated"] = dep["latest"] != tag
            dep["tag_form_changed"] = tag_shape(dep["latest"]) != tag_shape(tag)
        else:
            dep["note"] = (f"unknown (no zip named like {asset.replace(tag, '<tag>')} in the last {len(releases)}"
                           " releases; the asset name pattern may have changed)")
        deps.append(dep)
    return deps


def dependency_line(dep: dict) -> str:
    gh = ""
    if dep["github_latest"]:
        gh = f"GitHub's latest release is {dep['github_latest']}"
        if not dep["github_latest_has_zip"]:
            gh += " (no xcframework zip there)"
    if dep["note"]:
        text = f"DEPENDENCY: {dep['name']} {dep['current']} -> latest {dep['note']}"
        return text + (f"; {gh}" if gh else "")
    if not dep["outdated"]:
        text = f"DEPENDENCY: {dep['name']} {dep['current']} is the latest"
    else:
        text = f"DEPENDENCY: {dep['name']} {dep['current']} -> latest {dep['latest']}"
    extra = [dep["latest_asset"]]
    if dep["latest_prerelease"]:
        extra.append("marked prerelease")
    if dep["tag_form_changed"]:
        extra.append(f"tag form changed: {dep['current']} -> {dep['latest']}")
    if gh and dep["github_latest"] != dep["latest"]:
        extra.append(gh)
    return text + " (" + "; ".join(extra) + ")"


# ---------------------------------------------------------------- 出力

def gh_escape(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def annotate(kind: str, where: tuple[str, int] | None, message: str) -> None:
    if not os.environ.get("GITHUB_ACTIONS"):
        return
    loc = f" file={where[0]},line={where[1]}" if where else ""
    print(f"::{kind}{loc}::{gh_escape(message)}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Check links used by the app and written in the docs.")
    group = ap.add_mutually_exclusive_group()
    group.add_argument("--runtime-only", action="store_true",
                       help="check only the runtime URLs (built from Sources/KikimimiCore/Catalog/models.json)")
    group.add_argument("--docs-only", action="store_true", help="check only URLs found in the repository files")
    group.add_argument("--urls-file", type=Path, help="check only the URLs in this file (one per line)")
    group.add_argument("--list-runtime", action="store_true",
                       help="print the runtime URLs built from models.json (one per line) and exit; no network")
    ap.add_argument("--no-deps", action="store_true", help="skip the dependency freshness check")
    ap.add_argument("--report", type=Path, help="write a JSON report to this file")
    args = ap.parse_args()

    if args.list_runtime:
        for url, _ in catalog_urls():
            print(url)
        return 0

    ignore = [p for p, _ in read_list(IGNORE_LIST)]

    # URL ごとに、どこに在ったか (ファイル, 行) と、実行時の URL かを覚える
    sources: dict[str, list[tuple[str, int]]] = {}
    runtime: set[str] = set()

    def add(found: dict[str, list[tuple[str, int]]], is_runtime: bool) -> None:
        for url, where in found.items():
            sources.setdefault(url, []).extend(where)
            if is_runtime:
                runtime.add(url)

    if args.urls_file:
        add(collect_list(args.urls_file), True)
    else:
        if not args.docs_only:
            add(collect_catalog(), True)
        if not args.runtime_only:
            add(collect_docs(), False)

    ignored = sorted(u for u in sources if any(u.startswith(p) for p in ignore))
    urls = [u for u in sources if u not in ignored]

    results = []
    for url in urls:
        r = check_url(url)
        r["runtime"] = url in runtime
        r["sources"] = [{"file": f, "line": n} for f, n in sources[url]]
        results.append(r)

    deps = []
    if not args.no_deps and not args.urls_file:
        deps = check_dependencies()

    # 表 (人が読む物)
    results.sort(key=lambda r: (STATUS_ORDER.index(r["status"]), not r["runtime"], r["url"]))
    print(f"{'STATUS':<7} {'KIND':<8} URL")
    for r in results:
        kind = "runtime" if r["runtime"] else "docs"
        print(f"{r['status']:<7} {kind:<8} {r['url']}")
        if r["status"] != "OK":
            print(f"{'':<16} {r['detail']}  [{r['method']}]")
            for s in r["sources"]:
                print(f"{'':<16} at {s['file']}:{s['line']}")
    if ignored:
        print(f"\nIgnored by ignore.txt: {len(ignored)}")
        for u in ignored:
            print(f"  {u}")

    # GitHub の注釈
    for r in results:
        where = (r["sources"][0]["file"], r["sources"][0]["line"]) if r["sources"] else None
        if r["status"] == "BROKEN":
            annotate("error", where, f"Broken link: {r['url']} ({r['detail']})")
        elif r["status"] == "MOVED":
            annotate("warning", where, f"Moved link: {r['url']} {r['detail']}")
        elif r["status"] == "UNSURE":
            label = "runtime URL" if r["runtime"] else "link"
            annotate("warning", where, f"Could not confirm {label}: {r['url']} ({r['detail']}); may be temporary")

    if deps:
        print()
        for dep in deps:
            line = dependency_line(dep)
            print(line)
            if dep["note"] or dep["outdated"]:
                annotate("warning", (dep["file"], dep["line"]), line)

    counts = {s: sum(1 for r in results if r["status"] == s) for s in STATUS_ORDER}
    print(f"\nOK {counts['OK']}  MOVED {counts['MOVED']}  UNSURE {counts['UNSURE']}  BROKEN {counts['BROKEN']}"
          f"  (runtime {sum(1 for r in results if r['runtime'])}, docs {sum(1 for r in results if not r['runtime'])},"
          f" ignored {len(ignored)})")

    if args.report:
        report = {"counts": counts, "ignored": ignored, "results": results, "dependencies": deps}
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if any("CERTIFICATE_VERIFY_FAILED" in (r["detail"] or "") for r in results):
        print("NOTE: certificate verification failed. If this happens for every URL, this Python has no CA"
              " certificates (python.org builds on macOS need 'Install Certificates.command'; /usr/bin/python3 works).")

    if counts["BROKEN"]:
        print(f"LINK CHECK FAILED: {counts['BROKEN']} broken")
        return 1
    print(f"LINK CHECK OK ({len(results)} urls)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
