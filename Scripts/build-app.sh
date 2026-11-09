#!/usr/bin/env bash
# swift build → Kikimimi.app を組み立てる (Xcode プロジェクト不要)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
FINAL="build/Kikimimi.app"
# 途中で失敗しても前のアプリを壊さないよう、別の名前で組み立てて、最後に入れ替える
APP="build/Kikimimi.app.new"

echo "▸ swift build -c $CONFIG (初回は whisper.cpp / llama.cpp の取得と依存のビルドで数分かかります)"
swift build -c "$CONFIG" --product Kikimimi
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Kikimimi" "$APP/Contents/MacOS/Kikimimi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# どのコミットから組み立てたかを残す (古いアプリを開いていないかを確かめられるように)
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || true)"
if [ -n "$COMMIT" ]; then
  [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] || COMMIT="$COMMIT+"
  /usr/libexec/PlistBuddy -c "Add :KikimimiCommit string $COMMIT" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

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
codesign --force --sign - "$APP" \
  || { echo "✗ 署名できませんでした。iCloud や Dropbox で同期しているフォルダの中では失敗することがあります (xattr -cr build を試すか、フォルダを移してください)。" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

# この Mac で読み込めるかを、入れ替える前に確かめる (同梱したフレームワークを読み込めないと、ここで止まる)
if ! VERSION="$("$APP/Contents/MacOS/Kikimimi" --version 2>&1)"; then
  echo "$VERSION" >&2
  echo "✗ 組み立てたアプリを、この Mac で読み込めません。上のメッセージを報告してください (前のアプリはそのままです)。" >&2
  exit 1
fi

rm -rf "$FINAL"
mv "$APP" "$FINAL"
echo "✓ $FINAL — $(printf '%s\n' "$VERSION" | head -1)"
