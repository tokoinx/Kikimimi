# -*- coding: utf-8 -*-
# 変な保存ファイルを並べた、試し用のライブラリを作る (ゲリラ的に試す時の入力)。
# 使い方: /usr/bin/python3 -I make_hostile_library.py <作る先のフォルダ> [入れる場面の名前 ...]
#   場面の名前を渡さなければ、全部を入れる。1 つずつ試す時は、名前を 1 つ渡す。
# 出力: 場面の名前と、そのフォルダの ID を 1 行ずつ。
import io
import json
import os
import sys
import uuid

root = sys.argv[1]
only = set(sys.argv[2:])
os.makedirs(root, exist_ok=True)


def seg(start, end, text, **more):
    d = {"id": str(uuid.uuid4()).upper(), "start": start, "end": end, "text": text}
    d.update(more)
    return d


def doc(title, segments, **more):
    d = {
        "formatVersion": 1,
        "id": str(uuid.uuid4()).upper(),
        "title": title,
        "isRecording": False,
        "createdAt": "2026-11-28T10:20:30Z",
        "updatedAt": "2026-11-28T10:20:30Z",
        "languageCode": "en",
        "vadSkippedAutomatically": False,
        "versions": [],
        "transcript": {
            "sourceName": "monkey.wav",
            "segments": segments,
            "language": "en",
            "duration": 12.5,
            "elapsed": 1.0,
        },
    }
    for key, value in more.items():
        if key.startswith("t_"):
            d["transcript"][key[2:]] = value
        else:
            d[key] = value
    return d


base = [seg(0, 2.5, "So the first thing I want to talk about."),
        seg(2.5, 5, "Right, and that is exactly the point."),
        seg(5, 8, "Let me show you an example.")]

same_id = str(uuid.uuid4()).upper()
ring_a, ring_b = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()

scenes = {
    # 比べる元 (ふつうの結果)
    "baseline": doc("baseline", base),
    # とても大きい時刻 (時刻を文字にする所)
    "huge-time": doc("huge time", [seg(1e300, 1e300, "A time far beyond any recording."), seg(0, 1, "next")]),
    "huge-duration": doc("huge duration", base, t_duration=1e300, t_elapsed=1e-300),
    # 終わりが始まりより前・負の時刻
    "backwards": doc("backwards", [seg(5, 1, "end before start"), seg(-3, -1, "negative"), seg(2, 2, "zero length")]),
    # 同じ ID の区間が 2 つ
    "same-id": doc("same id", [dict(seg(0, 1, "first"), id=same_id), dict(seg(1, 2, "second"), id=same_id)]),
    # 区間が無い
    "empty": doc("empty", []),
    # 1 つの区間に、とても長い文 (1 MB)
    "long-line": doc("long line", [seg(0, 1, "word " * 200000)]),
    # 区間がとても多い (5 万)
    "many": doc("many", [seg(i * 0.5, i * 0.5 + 0.5, "line %d" % i) for i in range(50000)]),
    # 題名に、改行・向きを変える印・斜線・長い文
    "odd-title": doc("line1\nline2 ‮/../../etc/passwd " + "T" * 3000, base),
    "empty-title": doc("", base),
    # 元の音声の場所が、変な所
    "source-dev-zero": doc("source dev zero", base, sourcePath="/dev/zero"),
    "source-directory": doc("source directory", base, sourcePath="/System"),
    "source-missing": doc("source missing", base, sourcePath="/nonexistent/‮/a.wav"),
    "source-not-audio": doc("source not audio", base, sourcePath="/etc/hosts"),
    # 新しすぎる版の番号
    "future-format": doc("future format", base, formatVersion=999, somethingNew={"a": [1, 2, 3]}),
    # 知らない言語のコード
    "odd-language": doc("odd language", [seg(0, 1, "x", language="zz"), seg(1, 2, "y", language="")],
                        languageCode="xx-" + "y" * 500, t_language="??", t_translationLanguage="‮"),
    # 訳のまとまりが、無い区間・自分・輪を指す
    "covers-ring": doc("covers ring", [
        dict(seg(0, 1, "a", translation="A", translationCovers=[ring_b, ring_a]), id=ring_a),
        dict(seg(1, 2, "b", translation="B", translationCovers=[ring_a, str(uuid.uuid4()).upper()]), id=ring_b)],
        t_translationLanguage="ja"),
    # 日時が変
    "odd-dates": doc("odd dates", base, createdAt="0001-01-01T00:00:00Z", updatedAt="9999-12-31T23:59:59.999999999999Z"),
    # 版の一覧が、壊れた版のファイルを指す
    "broken-version": doc("broken version", base),
}

for name, d in scenes.items():
    if only and name not in only:
        continue
    folder = os.path.join(root, d["id"])
    os.makedirs(folder, exist_ok=True)
    if name == "broken-version":
        vid = str(uuid.uuid4()).upper()
        d["versions"] = [{"id": vid, "savedAt": "2026-11-28T10:20:30Z", "label": "v", "origin": "manual",
                          "segmentCount": 3, "noteLength": 0}]
        os.makedirs(os.path.join(folder, "versions"), exist_ok=True)
        io.open(os.path.join(folder, "versions", vid + ".json"), "w", encoding="utf-8").write(u"{ not json")
    io.open(os.path.join(folder, "document.json"), "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False))
    print(name, d["id"])

# 読めないファイルたち (名前を変えて、とっておかれるはず)
extra = {
    "truncated": b'{"formatVersion":1,"id":"',
    "empty-file": b"",
    "not-utf8": b"\xff\xfe\x00\x00{",
    "array": b"[1,2,3]",
    "deep": b"[" * 100000,
    # 名前 (鍵) の文字列が壊れている (macOS 14 の JSONDecoder は、投げずに落ちていた。2026-11-28)
    "key-control": b'{"formatVersion":1,"\x01":0}',
    "key-not-utf8": b'{"formatVersion":1,"\xff":0}',
    "key-bad-escape": b'{"formatVersion":1,"\\q":0}',
    "key-lone-surrogate": b'{"formatVersion":1,"\\uD800":0}',
}
for name, data in extra.items():
    if only and name not in only:
        continue
    fid = str(uuid.uuid4()).upper()
    folder = os.path.join(root, fid)
    os.makedirs(folder, exist_ok=True)
    io.open(os.path.join(folder, "document.json"), "wb").write(data)
    print(name, fid)

# メモが、文字として読めない・とても大きい
if not only or "odd-notes" in only:
    d = doc("odd notes", base)
    folder = os.path.join(root, d["id"])
    os.makedirs(folder, exist_ok=True)
    io.open(os.path.join(folder, "document.json"), "w", encoding="utf-8").write(json.dumps(d))
    io.open(os.path.join(folder, "notes.md"), "wb").write(b"\xff\xfe note \x00 " + b"n" * 5000000)
    print("odd-notes", d["id"])
