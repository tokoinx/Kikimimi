#!/usr/bin/env bash
# swift build → Kikimimi.app を組み立てる (Xcode プロジェクト不要)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/Kikimimi.app"

echo "▸ swift build -c $CONFIG (初回は whisper.cpp / llama.cpp の取得と依存のビルドで数分かかります)"
swift build -c "$CONFIG" --product Kikimimi
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Kikimimi" "$APP/Contents/MacOS/Kikimimi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# whisper.framework (音声認識) と llama.framework (監査・翻訳の LLM) を同梱する
# (ビルド先にコピーされていればそれを、無ければ展開済みの XCFramework から)
for NAME in whisper llama; do
  FW="$BIN_DIR/$NAME.framework"
  if [ ! -d "$FW" ]; then
    FW="$(find .build/artifacts -type d -path "*$NAME.xcframework/macos-*/$NAME.framework" -print -quit 2>/dev/null || true)"
  fi
  if [ -z "$FW" ] || [ ! -d "$FW" ]; then
    echo "✗ $NAME.framework が見つかりません。'swift package reset' のあと、もう一度 make run を試してください。" >&2
    exit 1
  fi
  ditto "$FW" "$APP/Contents/Frameworks/$NAME.framework"
done

# 実行ファイルが Contents/Frameworks を探せるようにする (通常は Package.swift の設定で入っている)
LOAD_COMMANDS="$(otool -l "$APP/Contents/MacOS/Kikimimi")"
case "$LOAD_COMMANDS" in
  *"@executable_path/../Frameworks"*) ;;
  *)
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Kikimimi" 2>/dev/null \
      || { echo "✗ 実行ファイルに rpath を追加できませんでした" >&2; exit 1; }
    ;;
esac

if [ -d Resources/AppIcon.iconset ] && command -v iconutil >/dev/null; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

# ad-hoc 署名 (中のフレームワーク → アプリ本体の順)。マイク許可を macOS に覚えてもらうために必要。
codesign --force --sign - "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign - "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign - "$APP"
echo "✓ $APP"
