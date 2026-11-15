import Foundation

/// 保存した結果 1 件 (ライブラリの 1 フォルダ)。
///
/// `document.json` に書く。メモ (`notes`) だけは `notes.md` に別に書くので、JSON には入れない。
public struct SavedDocument: Codable, Hashable, Identifiable, Sendable {
    /// いまの書き方の番号
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: UUID
    public var title: String
    /// 音声ファイルの場所 (ファイルが動いても、消えても、覚えておく)
    public var sourcePath: String?
    /// マイクで録音したものか
    public var isRecording: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// 文字起こしのときに選んだ言語 (自動なら nil)
    public var languageCode: String?
    /// 「日本語＋英語」に自動で切り替えたとき、もとの言語
    public var autoMixedFrom: String?
    public var transcript: Transcript
    /// 版の一覧 (新しい順)
    public var versions: [VersionInfo]
    /// メモ。`notes.md` に書く (JSON には入れない)
    public var notes: String

    public init(formatVersion: Int = SavedDocument.currentFormatVersion, id: UUID = UUID(), title: String,
                sourcePath: String? = nil, isRecording: Bool = false, createdAt: Date = Date(),
                updatedAt: Date? = nil, languageCode: String? = nil, autoMixedFrom: String? = nil,
                transcript: Transcript, versions: [VersionInfo] = [], notes: String = "") {
        self.formatVersion = formatVersion
        self.id = id
        self.title = title
        self.sourcePath = sourcePath
        self.isRecording = isRecording
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.languageCode = languageCode
        self.autoMixedFrom = autoMixedFrom
        self.transcript = transcript
        self.versions = versions
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, title, sourcePath, isRecording, createdAt, updatedAt
        case languageCode, autoMixedFrom, transcript, versions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 無い項目は、ふつうの値にする (古い・新しい版のアプリが書いたファイルも読めるように)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? SavedDocument.currentFormatVersion
        id = try c.decode(UUID.self, forKey: .id)
        transcript = try c.decode(Transcript.self, forKey: .transcript)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? transcript.sourceName
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        isRecording = try c.decodeIfPresent(Bool.self, forKey: .isRecording) ?? false
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        let updated = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        createdAt = created ?? updated ?? Date(timeIntervalSince1970: 0)
        updatedAt = updated ?? createdAt
        languageCode = try c.decodeIfPresent(String.self, forKey: .languageCode)
        autoMixedFrom = try c.decodeIfPresent(String.self, forKey: .autoMixedFrom)
        versions = try c.decodeIfPresent([VersionInfo].self, forKey: .versions) ?? []
        notes = ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(sourcePath, forKey: .sourcePath)
        try c.encode(isRecording, forKey: .isRecording)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(languageCode, forKey: .languageCode)
        try c.encodeIfPresent(autoMixedFrom, forKey: .autoMixedFrom)
        try c.encode(transcript, forKey: .transcript)
        try c.encode(versions, forKey: .versions)
    }

    /// いちばん新しい、自分で残した版 (「いちばん新しい版に上書き」で上書きするもの)
    public var latestManualVersion: VersionInfo? {
        versions.first { $0.origin == .manual }
    }

    /// 版の中身で置きかえたもの。transcript なら文字起こしと訳、notes ならメモを置きかえる。
    /// 版の一覧や日付は変えない
    public func restoring(_ version: DocumentVersion, transcript: Bool, notes: Bool) -> SavedDocument {
        var copy = self
        if transcript { copy.transcript = version.transcript }
        if notes { copy.notes = version.notes }
        return copy
    }
}

/// 版 1 つの見出し (document.json の版の一覧に入る)。
public struct VersionInfo: Codable, Hashable, Identifiable, Sendable {
    /// 版をどうやって残したか
    public enum Origin: String, Codable, Sendable {
        /// 利用者が「保存」で残した
        case manual
        /// 前の版に戻す前に、自動で残した
        case beforeRestore

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // 知らない値 (新しい版のアプリが書いたもの) は、自分で残した版とみなす
            self = Origin(rawValue: raw) ?? .manual
        }
    }

    public var id: UUID
    public var savedAt: Date
    /// 版の名前 (なくてもよい)
    public var label: String
    public var origin: Origin
    /// 区間の数
    public var segmentCount: Int
    /// メモの文字数
    public var noteLength: Int

    public init(id: UUID = UUID(), savedAt: Date, label: String = "", origin: Origin = .manual,
                segmentCount: Int, noteLength: Int) {
        self.id = id
        self.savedAt = savedAt
        self.label = label
        self.origin = origin
        self.segmentCount = segmentCount
        self.noteLength = noteLength
    }

    private enum CodingKeys: String, CodingKey {
        case id, savedAt, label, origin, segmentCount, noteLength
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date(timeIntervalSince1970: 0)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .manual
        segmentCount = try c.decodeIfPresent(Int.self, forKey: .segmentCount) ?? 0
        noteLength = try c.decodeIfPresent(Int.self, forKey: .noteLength) ?? 0
    }
}

/// 版 1 つの中身 (versions/<版の ID>.json)。その時点の文字起こし・訳とメモの写し。
public struct DocumentVersion: Codable, Hashable, Sendable {
    public var info: VersionInfo
    public var transcript: Transcript
    public var notes: String

    public init(info: VersionInfo, transcript: Transcript, notes: String) {
        self.info = info
        self.transcript = transcript
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case info, transcript, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = try c.decode(VersionInfo.self, forKey: .info)
        transcript = try c.decode(Transcript.self, forKey: .transcript)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}
