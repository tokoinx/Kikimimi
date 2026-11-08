// swift-tools-version: 6.0
import PackageDescription

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
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // whisper.cpp の C API を Swift から使うための薄いラッパーと、モデルの取得・保存
        .target(
            name: "KikimimiWhisper",
            dependencies: ["KikimimiCore", "WhisperFramework"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // macOS アプリ本体 (SwiftUI + AVFoundation)
        .executableTarget(
            name: "Kikimimi",
            dependencies: ["KikimimiCore", "KikimimiWhisper"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // .app に同梱する whisper.framework (Contents/Frameworks) を見つけられるようにする
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // whisper.cpp 公式のビルド済み XCFramework (Metal 対応, macOS 13.3 以降)
        .binaryTarget(
            name: "WhisperFramework",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),
        .testTarget(
            name: "KikimimiCoreTests",
            dependencies: ["KikimimiCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
