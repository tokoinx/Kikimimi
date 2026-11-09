// swift-tools-version: 6.0
import PackageDescription

// whisper.framework と llama.framework は、版の違う ggml.h をそれぞれ持っている。
// 両方の C モジュールが 1 つのコンパイルに入ると型の定義がぶつかるため、
// ラッパーは `internal import` で C モジュールを内側に閉じ込め、library evolution で
// アプリ本体のコンパイルにそれらを持ち込まないようにする
// (ラッパーが使う KikimimiCore も library evolution にしておくと、余計な警告が出ない)。
let libraryEvolution: SwiftSetting = .unsafeFlags(["-enable-library-evolution"])
let wrapperSettings: [SwiftSetting] = [.swiftLanguageMode(.v5), libraryEvolution]

let package = Package(
    name: "Kikimimi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kikimimi", targets: ["Kikimimi"]),
    ],
    targets: [
        // プラットフォーム非依存のコア (書き出し・モデル一覧・WAV・誤認識フィルタ)
        .target(
            name: "KikimimiCore",
            swiftSettings: [.swiftLanguageMode(.v6), libraryEvolution]
        ),
        // whisper.cpp の C API を Swift から使うための薄いラッパーと、モデルの取得・保存
        .target(
            name: "KikimimiWhisper",
            dependencies: ["KikimimiCore", "WhisperFramework"],
            swiftSettings: wrapperSettings
        ),
        // llama.cpp の C API で、監査役・翻訳役のローカル LLM (GGUF) を動かす
        .target(
            name: "KikimimiLLM",
            dependencies: ["KikimimiCore", "LlamaFramework"],
            swiftSettings: wrapperSettings
        ),
        // macOS アプリ本体 (SwiftUI + AVFoundation)
        .executableTarget(
            name: "Kikimimi",
            dependencies: ["KikimimiCore", "KikimimiWhisper", "KikimimiLLM"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // .app に同梱する whisper.framework / llama.framework (Contents/Frameworks) を見つけられるようにする
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // whisper.cpp 公式のビルド済み XCFramework (Metal 対応, macOS 13.3 以降)
        .binaryTarget(
            name: "WhisperFramework",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),
        // llama.cpp 公式のビルド済み XCFramework (Metal 対応, macOS 13.3 以降)
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12211/llama-b12211-xcframework.zip",
            checksum: "1f701c47b0e2f9410e1441960105e7d7ad1757f8a49e4063c6e792df31348a7a"
        ),
        .testTarget(
            name: "KikimimiCoreTests",
            dependencies: ["KikimimiCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
