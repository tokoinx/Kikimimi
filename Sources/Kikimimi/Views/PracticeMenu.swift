import KikimimiCore
import SwiftUI

/// 再生の列の右の、速さのボタン (いまの速さを出す。押すと速さを選べる)。
/// 速さを変えると、鳴っている途中でもすぐ変わる (声の高さは変わらない)
struct SpeedMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let practice = model.practice
        Menu {
            Picker("速さ", selection: Binding(
                get: { practice.settings.rate },
                set: { practice.setRate($0) }
            )) {
                ForEach(PracticeSettings.rates, id: \.self) { rate in
                    Text(HiddenText.rateLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(HiddenText.rateLabel(practice.settings.rate))
                .monospacedDigit()
        }
        .menuStyle(.button)
        .fixedSize()
        .help("再生の速さ (声の高さは変わりません)")
    }
}

/// 再生の列の右の「練習」のボタン: 繰り返し・行のあとの間・自動で次へ・隠す・書き取りの欄。
/// 決まりの設定から変えているときは、ボタンに色を付ける
struct PracticeMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var practice = model.practice
        let customized = practice.isCustomized
        Menu {
            Section("繰り返し") {
                Picker("繰り返し", selection: $practice.settings.repeatCount) {
                    ForEach(PracticeSettings.repeatCounts, id: \.self) { count in
                        Text("\(count) 回").tag(count)
                    }
                    Text("止めるまで").tag(PracticeSettings.untilStopped)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("行のあとの間") {
                Picker("行のあとの間", selection: $practice.settings.gap) {
                    Text("空けない").tag(PracticeSettings.Gap.off)
                    Text("行と同じ長さだけ空ける").tag(PracticeSettings.Gap.lineLength)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Toggle("自動で次の行へ進む", isOn: $practice.settings.autoAdvance)
            Section("隠す") {
                Picker("隠す", selection: $practice.settings.hide) {
                    Text("隠さない").tag(PracticeSettings.Hide.nothing)
                    Text("原文を隠す").tag(PracticeSettings.Hide.source)
                    Text("原文と訳を隠す").tag(PracticeSettings.Hide.sourceAndTranslation)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Toggle("書き取りの欄を出す", isOn: $practice.showsDictation)
        } label: {
            Label("練習", systemImage: "repeat")
        }
        .menuStyle(.button)
        .fixedSize()
        // 設定を変えているときの色 (ボタンの後ろに敷く。メニューのボタンの文字の色は、macOS では変えられないことがある)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(customized ? Color.accentColor.opacity(0.28) : Color.clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(customized ? Color.accentColor : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .help(customized ? "練習の設定 (決まりの設定から変えています)" : "練習の設定: 繰り返し・行のあとの間・自動で次へ・隠す・書き取り")
    }
}

/// 練習で、行のあとの間を待っているあいだだけ出す知らせ
struct PracticeGapNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.practice.isWaiting {
            Text("間 (声に出してみましょう)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
