import Foundation

/// 結果をゴミ箱に入れる時に、ディスクの何が消え、何が残るか。
/// 確認の画面に出す物と、実際に消す物は、どちらもこの計画から取る (決め方を 1 つにする)
public struct DeletionPlan: Equatable, Sendable {
    /// 音声ファイルを残す理由
    /// (`@frozen`: このパッケージはいつも全体を一緒に作り直すので、case を足した時は、使う側の switch がコンパイルで止まるほうがよい)
    @frozen public enum KeptAudioReason: Hashable, Sendable {
        /// 「開く」で読み込んだ元のファイル (アプリは消さない)
        case original
        /// マイクの録音だが、ほかの結果も同じ録音を使っている
        case sharedRecording
        /// マイクの録音だが、アプリの録音フォルダの外に在る
        case recordingOutsideAppFolder
        /// マイクの録音だが、結果をまだ保存していない (録音もゴミ箱に入れない)
        case notSaved
    }

    /// ゴミ箱に入れる保存のフォルダ (保存していなければ nil)
    public var libraryFolder: URL?
    /// ゴミ箱に入れるマイクの録音 (無ければ nil)
    public var recording: URL?
    /// 残る音声ファイル (元のファイル、または残す録音。音声の場所が無ければ nil)
    public var keptAudio: URL?
    /// 音声ファイルを残す理由 (keptAudio が nil なら nil)
    public var keptAudioReason: KeptAudioReason?
    /// 文字起こし・監査・翻訳の途中なので、止めてから消す
    public var stopsWork: Bool

    public init(libraryFolder: URL?, recording: URL?, keptAudio: URL?, keptAudioReason: KeptAudioReason?, stopsWork: Bool) {
        self.libraryFolder = libraryFolder
        self.recording = recording
        self.keptAudio = keptAudio
        self.keptAudioReason = keptAudioReason
        self.stopsWork = stopsWork
    }

    /// ディスクから何も消えない (一覧から外すだけ)
    public var isEmpty: Bool { libraryFolder == nil && recording == nil }

    /// 計画を作る。
    /// - isSaved: 保存した結果か (保存していなければ、フォルダも録音もゴミ箱に入れない)
    /// - libraryFolder: この結果の保存のフォルダ (`<ライブラリ>/<UUID>`。ライブラリが無ければ nil)
    /// - isRecording: マイクの録音から作った結果か (false でも、音声がアプリの録音フォルダの中に在れば録音として扱う。
    ///   録音を「やり直す」と印を失っていた古い結果でも、録音がゴミ箱へ移るように)
    /// - sourcePath: 音声ファイルの場所
    /// - recordingsDirectory: アプリの録音フォルダ
    /// - audioUsedByOtherJobs: ほかの結果も同じ音声ファイルを使っている
    /// - isWorking: 文字起こし・監査・翻訳の途中
    public static func make(isSaved: Bool, libraryFolder: URL?, isRecording: Bool, sourcePath: String?,
                            recordingsDirectory: URL, audioUsedByOtherJobs: Bool, isWorking: Bool) -> DeletionPlan {
        // 保存のフォルダが分からなければ、保存していない時と同じに扱う
        let folder = isSaved ? libraryFolder : nil
        let isSaved = folder != nil
        let audio = sourcePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let isRecording = isRecording || recordingInAppFolder(sourcePath, recordingsDirectory: recordingsDirectory) != nil
        var recording: URL?
        var reason: KeptAudioReason?
        if audio != nil {
            if !isRecording {
                reason = .original
            } else if !isSaved {
                reason = .notSaved
            } else if audioUsedByOtherJobs {
                reason = .sharedRecording
            } else if let inside = recordingInAppFolder(sourcePath, recordingsDirectory: recordingsDirectory) {
                recording = inside
            } else {
                reason = .recordingOutsideAppFolder
            }
        }
        return DeletionPlan(libraryFolder: folder,
                            recording: recording,
                            keptAudio: recording == nil ? audio : nil,
                            keptAudioReason: recording == nil ? reason : nil,
                            stopsWork: isWorking)
    }

    /// アプリの録音フォルダの中のファイルなら、その場所 (ほかの所のファイルは消さない)。
    /// 標準化したパスが「録音フォルダ + "/"」で始まる時だけ (名前の始めが同じだけの別のフォルダは、中と見なさない)
    public static func recordingInAppFolder(_ path: String?, recordingsDirectory: URL) -> URL? {
        guard let path else { return nil }
        let folder = recordingsDirectory.standardizedFileURL.path + "/"
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.path.hasPrefix(folder) ? url : nil
    }
}
