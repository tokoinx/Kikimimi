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
            // モデルの一覧のデータ (Whisper・VAD・LLM)。アプリには、台本が作った ModelCatalogGenerated.swift
            // (中身は同じ JSON の文) として入るので、JSON のファイルそのものはビルドに使わない
            exclude: ["Catalog/models.json"],
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
        // v1.9.3 からは、zip が vN.N.N の release でなく bNNNN の release に付く。b5454 は v1.9.5 と同じコミット
        .binaryTarget(
            name: "WhisperFramework",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        // llama.cpp 公式のビルド済み XCFramework (Metal 対応, macOS 13.3 以降)
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12556/llama-b12556-xcframework.zip",
            checksum: "354dfa19491eb6e154559879020f652d31c9c8330c40b14877d9451d70162590"
        ),
        .testTarget(
            name: "KikimimiCoreTests",
            dependencies: ["KikimimiCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
