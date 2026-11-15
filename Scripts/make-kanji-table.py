#!/usr/bin/env python3
"""Sources/KikimimiCore/LLM/JapaneseKanji.swift を作る。

日本語の文で使われる漢字 = cp932 (Shift_JIS + NEC/IBM 拡張) で表せる CJK 統合漢字 (拡張 A を含む)。
翻訳役が中国語に流れないよう、これに無い漢字 (簡体字の多く) を出力の候補から外すのに使う。
"""
import pathlib

chars = []
for cp in list(range(0x3400, 0x4DC0)) + list(range(0x4E00, 0xA000)):
    ch = chr(cp)
    try:
        ch.encode("cp932")
        chars.append(ch)
    except UnicodeEncodeError:
        pass

lines = ['        "' + "".join(chars[i:i + 100]) + '",' for i in range(0, len(chars), 100)]
src = """// Scripts/make-kanji-table.py で作った表です (Python の cp932 で表せる漢字)。手で書き換えないでください。
import Foundation

/// 日本語の文で使われる漢字 (Windows / Mac の日本語の文字コード cp932 = Shift_JIS + 拡張 で表せるもの)。
/// これに無い漢字 (们・这・欢 など簡体字の多く) は、日本語の訳文には出てこない。
enum JapaneseKanji {
    static let table: [String] = [
""" + "\n".join(lines) + """
    ]

    static let set: Set<Unicode.Scalar> = Set(table.joined().unicodeScalars)
}
"""
out = pathlib.Path(__file__).resolve().parent.parent / "Sources/KikimimiCore/LLM/JapaneseKanji.swift"
out.write_text(src, encoding="utf-8")
print(f"{len(chars)} kanji -> {out}")
