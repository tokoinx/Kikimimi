#!/usr/bin/env python3
"""モデルの一覧の JSON から、アプリに埋め込む Swift のファイルを作る。

元:   Sources/KikimimiCore/Catalog/models.json (一覧のただ 1 つの元。直すのはこちら)
作る: Sources/KikimimiCore/Catalog/ModelCatalogGenerated.swift (JSON の文を、そのまま文字列として持つだけ)

JSON を直したら、これを走らせて、2 つのファイルを一緒に commit する。
走らせ方: /usr/bin/python3 Scripts/generate-model-catalog.py
ずれていると、swift test の ModelCatalogDataTests が落ちる (直し方の命令を出す)。
python3 の標準ライブラリだけで動く。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/KikimimiCore/Catalog/models.json"
OUTPUT = ROOT / "Sources/KikimimiCore/Catalog/ModelCatalogGenerated.swift"


def render(text: str) -> str:
    """JSON の文を、Swift の生の文字列 (#\"\"\"…\"\"\"#) に入れた、ファイルの中身を作る"""
    # 文の中に閉じの印が現れないだけの数の # を付ける
    hashes = "#"
    while ('"""' + hashes) in text or ("\\" + hashes) in text:
        hashes += "#"
    body = text if text.endswith("\n") else text + "\n"
    return (
        "// このファイルは作られた物。手で直さない。\n"
        "// 元は Catalog/models.json。JSON を直したら、次で作り直す:\n"
        "//   /usr/bin/python3 Scripts/generate-model-catalog.py\n"
        "\n"
        "extension ModelCatalogData {\n"
        "    /// 埋め込んだ models.json の文 (ModelCatalogDataTests が、ファイルと同じ事を見る)\n"
        f"    static let embeddedJSON = {hashes}\"\"\"\n"
        f"{body}"
        f"\"\"\"{hashes}\n"
        "}\n"
    )


def main() -> int:
    text = SOURCE.read_text(encoding="utf-8")
    # 読めない JSON は、作る前に止める
    try:
        json.loads(text)
    except ValueError as e:
        print(f"error: {SOURCE.relative_to(ROOT)} is not valid JSON: {e}", file=sys.stderr)
        return 1
    content = render(text)
    old = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else None
    if old == content:
        print(f"{OUTPUT.relative_to(ROOT)} is up to date")
        return 0
    OUTPUT.write_text(content, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
