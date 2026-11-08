import KikimimiCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("文字起こし") {
                Picker("言語", selection: $model.languageCode) {
                    ForEach(Languages.all) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Picker("モデル", selection: $model.modelID) {
                    ForEach(ModelCatalog.all) { spec in
                        Text(spec.displayName + (spec.recommended ? " (おすすめ)" : "")).tag(spec.id)
                    }
                }
                Toggle("精度を優先する (ビームサーチ)", isOn: $model.preferAccuracy)
                Toggle("無音を飛ばす (VAD)", isOn: $model.useVAD)
                Toggle("定番の誤認識と、同じ文の繰り返しを取り除く", isOn: $model.filterHallucinations)
                Toggle("録音中にプレビューを出す", isOn: $model.livePreview)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("語彙のヒント", text: $model.initialPrompt, prompt: Text("例: ロブロックス, Roblox Studio, ききみみ"))
                    Text("固有名詞や専門用語を書いておくと、その表記で出やすくなります。空欄でも構いません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("モデル") {
                ForEach(ModelCatalog.all) { spec in
                    ModelRow(spec: spec)
                }
                HStack {
                    Button("手元のファイルを追加…") { model.importModelFile() }
                    Button("モデルのフォルダを開く") { model.revealModelsFolder() }
                }
            }

            Section {
                Text("音声認識は whisper.cpp (OpenAI Whisper の C/C++ 実装) を使い、Mac の GPU (Metal) で動きます。音声は Mac の外に送られません。インターネットを使うのは、モデルを初めて取得するときだけです。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
    }
}

struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let spec: WhisperModelSpec

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.displayName + (spec.recommended ? " (おすすめ)" : ""))
                Text("\(spec.summary) 約 \(spec.approxMB) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.availability(of: spec) {
            case .installed:
                Label("取得済み", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                Button("削除") { model.deleteModel(spec) }
            case .notInstalled:
                Button("ダウンロード") { model.download(spec) }
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 90)
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
