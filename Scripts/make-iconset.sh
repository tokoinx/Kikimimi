#!/usr/bin/env bash
# 1024 x 1024 の PNG から、アプリのアイコン一式 (Resources/AppIcon.iconset の 10 枚) を作り直す
# 使い方: Scripts/make-iconset.sh [1024 x 1024 の PNG]
#   省いた時は、今の Resources/AppIcon.iconset/icon_512x512@2x.png を元にする (一式をそろえ直す時に使う)
# 元の絵は、透明な 1024 x 1024 の中に、824 x 824 の本体を真ん中に置いた物にする (macOS のアイコンの決まり)。
# できた一式は、make app (Scripts/build-app.sh) が iconutil で AppIcon.icns にまとめて、アプリに入れる。
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="Resources/AppIcon.iconset"
SOURCE="${1:-$ICONSET/icon_512x512@2x.png}"

if [ ! -f "$SOURCE" ]; then
  echo "✗ 元の絵が見つかりません: $SOURCE" >&2
  exit 1
fi
WIDTH="$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ {print $2}')"
HEIGHT="$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')"
if [ "$WIDTH" != "1024" ] || [ "$HEIGHT" != "1024" ]; then
  echo "✗ 元の絵は 1024 x 1024 にしてください (今は ${WIDTH} x ${HEIGHT}): $SOURCE" >&2
  exit 1
fi

mkdir -p "$ICONSET"
# 元の絵を、作業の場所へ写してから使う (省いた時は、元の絵が一式の 1 枚なので、作る途中で書き換わらないように)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$SOURCE" "$WORK/source.png"

# ファイル名と、その大きさ (px)
for ENTRY in \
  icon_16x16.png:16 \
  icon_16x16@2x.png:32 \
  icon_32x32.png:32 \
  icon_32x32@2x.png:64 \
  icon_128x128.png:128 \
  icon_128x128@2x.png:256 \
  icon_256x256.png:256 \
  icon_256x256@2x.png:512 \
  icon_512x512.png:512 \
  icon_512x512@2x.png:1024
do
  NAME="${ENTRY%%:*}"
  SIZE="${ENTRY##*:}"
  if [ "$SIZE" = "1024" ]; then
    # 1024 は、元の絵そのもの
    cp "$WORK/source.png" "$ICONSET/$NAME"
  else
    # 縮める (色の情報は元の絵のまま。sips は縮める時に、なめらかに混ぜる)
    sips -z "$SIZE" "$SIZE" "$WORK/source.png" --out "$ICONSET/$NAME" >/dev/null
  fi
  echo "▸ $ICONSET/$NAME ($SIZE x $SIZE)"
done

# 一式が icns にまとまるかを確かめる (make app と同じ命令。できた物は捨てる)
iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"
echo "✓ $ICONSET を作り直しました (元の絵: $SOURCE)"
