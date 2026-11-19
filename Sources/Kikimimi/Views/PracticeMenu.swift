import KikimimiCore
import SwiftUI

/// 再生の列の右の、速さのボタン (いまの速さを出す。押すと速さを選べる)。
/// 速さを変えると、鳴っている途中でもすぐ変わる (声の高さは変わらない)
struct SpeedMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let practice = model.practice
        Menu {
            Picker(L("Playback speed"), selection: Binding(
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
        .help(L("Playback speed (the pitch of the voice stays the same)"))
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
            Section(L("Repeat")) {
                Picker(L("Repeat"), selection: $practice.settings.repeatCount) {
                    ForEach(PracticeSettings.repeatCounts, id: \.self) { count in
                        Text(LPlural(count, one: "%d time", other: "%d times")).tag(count)
                    }
                    Text(L("Until stopped")).tag(PracticeSettings.untilStopped)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section(L("Pause after the line")) {
                Picker(L("Pause after the line"), selection: $practice.settings.gap) {
                    Text(L("No pause")).tag(PracticeSettings.Gap.off)
                    Text(L("As long as the line")).tag(PracticeSettings.Gap.lineLength)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Toggle(L("Go on to the next line automatically"), isOn: $practice.settings.autoAdvance)
            Section(L("Hide")) {
                Picker(L("Hide"), selection: $practice.settings.hide) {
                    Text(L("Hide nothing")).tag(PracticeSettings.Hide.nothing)
                    Text(L("Hide the original")).tag(PracticeSettings.Hide.source)
                    Text(L("Hide the original and the translation")).tag(PracticeSettings.Hide.sourceAndTranslation)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Toggle(L("Show the dictation box"), isOn: $practice.showsDictation)
        } label: {
            Label(L("Practice"), systemImage: "repeat")
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
        .help(customized ? L("Practice settings (changed from the defaults)") : L("Practice settings: repeat, pause after the line, go on to the next line, hide, dictation"))
    }
}

/// 練習で、行のあとの間を待っているあいだだけ出す知らせ
struct PracticeGapNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.practice.isWaiting {
            Text(L("Pause: try saying it aloud"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
