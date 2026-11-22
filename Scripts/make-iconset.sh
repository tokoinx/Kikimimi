#!/usr/bin/env bash
# 1024 x 1024 の PNG から、アプリのアイコン一式 (Resources/AppIcon.iconset の 10 枚) を作り直す
# 使い方: Scripts/make-iconset.sh [1024 x 1024 の PNG] [16 ポイント用の 1024 x 1024 の PNG]
#   1 つ目を省いた時は、今の Resources/AppIcon.iconset/icon_512x512@2x.png を元にする (一式をそろえ直す時に使う)
#   2 つ目を省いた時は、Resources/AppIcon-16pt-master.png が在れば、それを使う
# 元の絵は、透明な 1024 x 1024 の中に、824 x 824 の本体を真ん中に置いた物にする (macOS のアイコンの決まり)。
# 16 ポイントの 2 枚 (icon_16x16.png・icon_16x16@2x.png) は、2 つ目の絵 (顔と耳に寄った絵) から作る:
# 全身の絵を縮めただけだと、16 px では、うさぎと読めないため。2 つ目の絵が無ければ、1 つ目から作る。
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

# 16 ポイント用の絵 (名前を渡した時は、無ければ止まる。省いた時は、決まりの場所に在る時だけ使う)
SMALL_DEFAULT="Resources/AppIcon-16pt-master.png"
SMALL_SOURCE="${2:-$SMALL_DEFAULT}"
if [ ! -f "$SMALL_SOURCE" ]; then
  if [ -n "${2:-}" ]; then
    echo "✗ 16 ポイント用の絵が見つかりません: $SMALL_SOURCE" >&2
    exit 1
  fi
  SMALL_SOURCE=""
fi
if [ -n "$SMALL_SOURCE" ]; then
  SMALL_WIDTH="$(sips -g pixelWidth "$SMALL_SOURCE" | awk '/pixelWidth/ {print $2}')"
  SMALL_HEIGHT="$(sips -g pixelHeight "$SMALL_SOURCE" | awk '/pixelHeight/ {print $2}')"
  if [ "$SMALL_WIDTH" != "1024" ] || [ "$SMALL_HEIGHT" != "1024" ]; then
    echo "✗ 16 ポイント用の絵は 1024 x 1024 にしてください (今は ${SMALL_WIDTH} x ${SMALL_HEIGHT}): $SMALL_SOURCE" >&2
    exit 1
  fi
fi

mkdir -p "$ICONSET"
# 元の絵を、作業の場所へ写してから使う (省いた時は、元の絵が一式の 1 枚なので、作る途中で書き換わらないように)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$SOURCE" "$WORK/source.png"
if [ -n "$SMALL_SOURCE" ]; then
  cp "$SMALL_SOURCE" "$WORK/small.png"
fi

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
  # 16 ポイントの 2 枚 (@1x と @2x。同じポイントは同じ絵にそろえる) は、寄った絵から作る
  FROM="$WORK/source.png"
  NOTE=""
  case "$NAME" in
    icon_16x16.png|icon_16x16@2x.png)
      if [ -n "$SMALL_SOURCE" ]; then
        FROM="$WORK/small.png"
        NOTE="、16 ポイント用の絵から"
      fi
      ;;
  esac
  if [ "$SIZE" = "1024" ]; then
    # 1024 は、元の絵そのもの
    cp "$WORK/source.png" "$ICONSET/$NAME"
  else
    # 縮める (色の情報は元の絵のまま。sips は縮める時に、なめらかに混ぜる)
    sips -z "$SIZE" "$SIZE" "$FROM" --out "$ICONSET/$NAME" >/dev/null
  fi
  echo "▸ $ICONSET/$NAME ($SIZE x $SIZE$NOTE)"
done

# 一式が icns にまとまるかを確かめる (make app と同じ命令。できた物は捨てる)
iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"
echo "✓ $ICONSET を作り直しました (元の絵: $SOURCE)"
