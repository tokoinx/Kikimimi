import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case formatUnsupported

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "マイクの使用が許可されていません。システム設定 › プライバシーとセキュリティ › マイク で「ききみみ」をオンにしてください。"
        case .noInputDevice: return "入力デバイス (マイク) が見つかりません。"
        case .formatUnsupported: return "マイクの音声形式に対応できませんでした。"
        }
    }
}

/// オーディオスレッドから書き込み、メインスレッドから読む録音バッファ
final class SampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ pointer: UnsafePointer<Float>, count: Int) {
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
        lock.unlock()
    }

    func all() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func tail(_ count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return Array(samples.suffix(count))
    }
}

/// マイク入力を 16 kHz モノラルで録る。
///
/// 録音中に入力デバイスが変わる (AirPods の接続など) と AVAudioEngine は自分で止まるので、
/// 新しいエンジンを作って同じバッファに録り続ける。
@MainActor
final class LiveRecorder {
    static let sampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?
    /// 入力デバイスの変更後に録音を続けられなかったとき (メインスレッドで呼ばれる)
    var onInterrupted: ((Error) -> Void)?

    private var engine = AVAudioEngine()
    private let store = SampleStore()
    private var isRunning = false
    private var configObserver: NSObjectProtocol?

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecorderError.microphoneDenied
        }
        try startEngine()
        isRunning = true
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.formatUnsupported
        }
        converter.downmix = true

        let level: @Sendable (Float) -> Void = { [weak self] value in
            Task { @MainActor in self?.onLevel?(value) }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat,
                         block: Self.makeTapBlock(converter: converter, target: target,
                                                  inputFormat: inputFormat, store: store, level: level))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        // queue: nil にして、エンジン内部のスレッドがメインスレッドを待たないようにする
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
    }

    private func removeConfigObserver() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

    /// デバイス・サンプルレート・チャンネル数が変わるとエンジンは止まる。新しいエンジンで録音を続ける。
    private func handleConfigurationChange() {
        guard isRunning, !engine.isRunning else { return } // 重複や古い通知は無視
        removeConfigObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        do {
            try startEngine()
        } catch {
            isRunning = false
            onInterrupted?(error)
        }
    }

    /// 録音を止めて、全体の音声を返す
    func stop() -> [Float] {
        removeConfigObserver()
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        return store.all()
    }

    func recentSamples(seconds: Double) -> [Float] {
        store.tail(Int(seconds * Self.sampleRate))
    }

    /// オーディオスレッドで実行されるタップ処理。MainActor に隔離されないよう nonisolated で作る。
    nonisolated private static func makeTapBlock(converter: AVAudioConverter,
                                                 target: AVAudioFormat,
                                                 inputFormat: AVAudioFormat,
                                                 store: SampleStore,
                                                 level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        let ratio = target.sampleRate / inputFormat.sampleRate
        return { buffer, _ in
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, converted.frameLength > 0, let channels = converted.floatChannelData else { return }
            let count = Int(converted.frameLength)
            let samples = channels[0]
            store.append(samples, count: count)
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            level((sum / Float(count)).squareRoot())
        }
    }
}
