import KikimimiCore
import SwiftUI

/// 一覧の下の、書き取りの欄の置き場所。出すかどうか (「書き取りの欄を出す」) を見るのは、この部品だけ
/// (結果の画面が見ると、切り替えるたびに一覧の body まで動く)
struct DictationSlot: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        if model.practice.showsDictation {
            Divider()
            DictationBar(job: job)
        }
    }
}

/// 書き取りの欄: いまの行を聞いて、聞こえたとおりに打ち、Return で答え合わせをする。
/// もう一度 Return を押すと (打ち直していなければ)、次の行へ進む。
/// 打っている文と結果を見るのは、この部品だけ (一覧は描き直さない)。高さは中身の分だけ (一覧の場所を、要る分しか取らない)
struct DictationBar: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        let practice = model.practice
        @Bindable var dictation = practice.dictation
        let canPlay = model.canPlayLines(of: job)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("書き取り")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let start = practice.currentLineStart {
                    Text(TimeFormat.short(start))
                        .monospacedDigit()
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("行を再生すると、その行をここで書き取れます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if practice.hideMode == .nothing {
                    Button("原文を隠す") {
                        practice.settings.hide = .source
                    }
                    .controlSize(.small)
                    .help("日本語でない行の原文を隠す (行の目のボタンで、1 行ずつ見られます)")
                }
                Button("もう一度聞く") {
                    practice.replay()
                }
                .keyboardShortcut("l")
                .help("いまの行をもう一度流す (⌘L)")
                .disabled(!canPlay)
                Button("前の行") {
                    practice.previous()
                }
                .disabled(!canPlay)
                Button("次の行") {
                    practice.next()
                }
                .disabled(!canPlay)
            }
            TextField("聞こえたとおりに打つ", text: $dictation.typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    practice.submitDictation()
                }
                .disabled(practice.currentLineID == nil)
            if let result = dictation.result {
                DictationResultView(result: result)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 答え合わせの結果: 合っている語はふつうの色、違う語は打った語を赤の取り消し線で出し、そのあとに正しい語を緑で、
/// 打っていない語はオレンジで [ ] に入れ、余計に打った語は赤の取り消し線。右に合っている数
struct DictationResultView: View {
    let result: DictationCheck.Result

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.marked(result))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(DictationDisplay.summary(result))
                .font(.callout.weight(.semibold))
                .foregroundStyle(result.isPerfect ? Color.green : Color.secondary)
                .monospacedDigit()
        }
    }

    static func marked(_ result: DictationCheck.Result) -> AttributedString {
        var text = AttributedString()
        for span in DictationDisplay.spans(result) {
            var part = AttributedString(span.text)
            switch span.style {
            case .correct:
                break
            case .typedWrong:
                part.foregroundColor = Color.red
                part.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Color.red)
            case .expected:
                part.foregroundColor = Color.green
            case .missing:
                part.foregroundColor = Color.orange
            }
            text.append(part)
        }
        return text
    }
}
