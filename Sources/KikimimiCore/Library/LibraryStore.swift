import Foundation

/// 結果を保存しておく所 (ライブラリ)。
///
/// 既定は `~/Library/Application Support/Kikimimi/Library` (モデルの Models フォルダのとなり)。
/// 環境変数 `KIKIMIMI_LIBRARY_DIR` で変更できる。結果 1 件ごとに、ID の名前のフォルダを 1 つ作る:
///
///     <ID>/document.json            結果の情報・文字起こし・版の一覧 (メモは入れない)
///     <ID>/notes.md                 メモ (ふつうの文字。ファイルが無ければメモは空)
///     <ID>/versions/<版の ID>.json   版 1 つ (その時点の文字起こし・訳とメモ)
///
/// ファイルの読み書きは、呼んだスレッドでそのまま行う。中に変わる値を持たないので、
/// アプリは裏の 1 本の列 (シリアルキュー) から呼べばよい。
public struct LibraryStore: Sendable {
    public let root: URL

    public static let documentFileName = "document.json"
    public static let notesFileName = "notes.md"
    public static let versionsFolderName = "versions"

    public init(root: URL) {
        self.root = root
    }

    /// 既定の場所 (環境変数 `KIKIMIMI_LIBRARY_DIR` があれば、そこ)
    public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let env = environment["KIKIMIMI_LIBRARY_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Kikimimi/Library", isDirectory: true)
    }

    // MARK: 場所

    public func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func documentURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(Self.documentFileName)
    }

    public func notesURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(Self.notesFileName)
    }

    public func versionURL(documentID: UUID, versionID: UUID) -> URL {
        folder(for: documentID).appendingPathComponent(Self.versionsFolderName, isDirectory: true)
            .appendingPathComponent(versionID.uuidString + ".json")
    }

    // MARK: 読む

    /// 全部の結果を読む (作った日時の新しい順)。document.json が読めないフォルダは、そのファイルを
    /// `document.unreadable-<日時>.json` に名前を変えてとっておき、setAside に入れて飛ばす。
    /// document.json の無いフォルダは見ない。版のファイルが無い版は、一覧から外す
    public func loadAll(date: Date = Date()) -> (documents: [SavedDocument], setAside: [URL]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return ([], []) }
        var documents: [SavedDocument] = []
        var setAside: [URL] = []
        for name in names.sorted() {
            // ID の名前でないフォルダは、この保存先のものではない
            guard let folderID = UUID(uuidString: name) else { continue }
            let url = documentURL(for: folderID)
            guard fm.fileExists(atPath: url.path) else { continue }
            if let data = try? Data(contentsOf: url),
               var document = try? Self.decoder().decode(SavedDocument.self, from: data) {
                // フォルダの名前のほうを正とする (フォルダごと写したときも、同じ所に保存し直せるように)
                document.id = folderID
                document.notes = readNotes(id: folderID)
                document.versions = document.versions.filter {
                    fm.fileExists(atPath: versionURL(documentID: folderID, versionID: $0.id).path)
                }
                documents.append(document)
            } else if let aside = setAsideUnreadable(url, date: date) {
                setAside.append(aside)
            }
        }
        documents.sort { $0.createdAt > $1.createdAt }
        return (documents, setAside)
    }

    /// 結果 1 件を読む (無い・読めなければ nil。読めないファイルの名前は変えない)
    public func load(id: UUID) -> SavedDocument? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: documentURL(for: id)),
              var document = try? Self.decoder().decode(SavedDocument.self, from: data) else { return nil }
        document.id = id
        document.notes = readNotes(id: id)
        document.versions = document.versions.filter {
            fm.fileExists(atPath: versionURL(documentID: id, versionID: $0.id).path)
        }
        return document
    }

    private func readNotes(id: UUID) -> String {
        guard let data = try? Data(contentsOf: notesURL(for: id)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func setAsideUnreadable(_ url: URL, date: Date) -> URL? {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = "document.unreadable-\(stamp.string(from: date))"
        let dir = url.deletingLastPathComponent()
        var aside = dir.appendingPathComponent(base + ".json")
        var n = 2
        while FileManager.default.fileExists(atPath: aside.path) {
            aside = dir.appendingPathComponent("\(base)-\(n).json")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            return aside
        } catch {
            // 動かせなければ、そのまま (このフォルダは読まずに飛ばす)
            return nil
        }
    }

    // MARK: 書く

    /// document.json と notes.md を書く (フォルダが無ければ作る)。updatedAt は呼ぶ側で入れる
    public func save(_ document: SavedDocument) throws {
        try FileManager.default.createDirectory(at: folder(for: document.id), withIntermediateDirectories: true)
        try writeDocumentJSON(document)
        try Data(document.notes.utf8).write(to: notesURL(for: document.id), options: .atomic)
    }

    /// notes.md だけを書く。フォルダが無いとき (消した結果) は何もしない (消した結果をよみがえらせない)
    public func saveNotes(id: UUID, text: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder(for: id).path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        try Data(text.utf8).write(to: notesURL(for: id), options: .atomic)
    }

    /// いまの文字起こし・訳とメモを版として書き、版の一覧の先頭に入れて document.json を書き直す
    public func addVersion(to document: SavedDocument, label: String, origin: VersionInfo.Origin,
                           date: Date = Date()) throws -> SavedDocument {
        let info = VersionInfo(savedAt: date, label: label, origin: origin,
                               segmentCount: document.transcript.segments.count,
                               noteLength: document.notes.count)
        try writeVersion(DocumentVersion(info: info, transcript: document.transcript, notes: document.notes),
                         documentID: document.id)
        var updated = document
        updated.versions.insert(info, at: 0)
        try save(updated)
        return updated
    }

    /// いちばん新しい、自分で残した版 (自動で残した版は飛ばす) を、いまの中身で書きかえる。
    /// 版の ID はそのままで、名前と日時を新しくして一覧の先頭に動かす。自分で残した版が無ければ、新しい版を作る
    public func overwriteLatestVersion(of document: SavedDocument, label: String,
                                       date: Date = Date()) throws -> SavedDocument {
        guard let index = document.versions.firstIndex(where: { $0.origin == .manual }) else {
            return try addVersion(to: document, label: label, origin: .manual, date: date)
        }
        var info = document.versions[index]
        info.savedAt = date
        info.label = label
        info.segmentCount = document.transcript.segments.count
        info.noteLength = document.notes.count
        try writeVersion(DocumentVersion(info: info, transcript: document.transcript, notes: document.notes),
                         documentID: document.id)
        var updated = document
        updated.versions.remove(at: index)
        updated.versions.insert(info, at: 0)
        try save(updated)
        return updated
    }

    /// 版 1 つの中身を読む
    public func loadVersion(documentID: UUID, versionID: UUID) throws -> DocumentVersion {
        let data = try Data(contentsOf: versionURL(documentID: documentID, versionID: versionID))
        return try Self.decoder().decode(DocumentVersion.self, from: data)
    }

    /// 版を 1 つ消す (ファイルと一覧から)。ファイルがもう無くても、一覧からは外す
    public func deleteVersion(of document: SavedDocument, versionID: UUID) throws -> SavedDocument {
        let url = versionURL(documentID: document.id, versionID: versionID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var updated = document
        updated.versions.removeAll { $0.id == versionID }
        try save(updated)
        return updated
    }

    /// 結果のフォルダを消す (無ければ何もしない)。アプリは、できればゴミ箱に入れるほうを使う
    public func delete(id: UUID) throws {
        let url = folder(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func writeDocumentJSON(_ document: SavedDocument) throws {
        try Self.encoder().encode(document).write(to: documentURL(for: document.id), options: .atomic)
    }

    private func writeVersion(_ version: DocumentVersion, documentID: UUID) throws {
        let url = versionURL(documentID: documentID, versionID: version.info.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder().encode(version).write(to: url, options: .atomic)
    }

    // MARK: JSON

    /// 日時は ISO 8601。秒より細かい所も、読み戻して同じ値になるように書く
    /// (監査の日時などを含めて、保存の前とあとで中身が同じになるように)
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(LibraryDate.string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = LibraryDate.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }
}

/// ライブラリの日時の書き方。`2026-11-12T10:20:30Z` に、秒より細かい所があれば `.123456` のように足す。
/// 秒より細かい所は、読み戻すと元とまったく同じ値になる桁数で書く
enum LibraryDate {
    static func string(from date: Date) -> String {
        let t = date.timeIntervalSinceReferenceDate
        let whole = t.rounded(.down)
        // whole は整数なので、この引き算は誤差なしで、whole + frac はもとの t にもどる
        let frac = t - whole
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let base = formatter.string(from: Date(timeIntervalSinceReferenceDate: whole))
        guard frac > 0, base.hasSuffix("Z") else { return base }
        return String(base.dropLast()) + "." + fractionDigits(frac) + "Z"
    }

    static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // 秒より細かい所を分けて読む
        guard let t = text.firstIndex(of: "T"), let dot = text[t...].firstIndex(of: ".") else {
            return formatter.date(from: text)
        }
        let afterDot = text.index(after: dot)
        let end = text[afterDot...].firstIndex { !$0.isASCII || !$0.isNumber } ?? text.endIndex
        let digits = text[afterDot..<end]
        guard !digits.isEmpty, let frac = Double("0." + digits),
              let base = formatter.date(from: String(text[..<dot]) + String(text[end...])) else { return nil }
        return Date(timeIntervalSinceReferenceDate: base.timeIntervalSinceReferenceDate + frac)
    }

    /// 0 < frac < 1 を、小数点の後ろの数字だけにする (Double に読み戻すと同じ値になる、いちばん短い書き方)
    static func fractionDigits(_ frac: Double) -> String {
        let text = "\(frac)"
        guard let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            // "0.123" の形
            return String(text.drop { $0 != "." }.dropFirst())
        }
        // "1.25e-05" の形を "0000125" にする
        let mantissa = text[..<e].replacingOccurrences(of: ".", with: "")
        let exponent = Int(text[text.index(after: e)...]) ?? 0
        return String(repeating: "0", count: max(0, -exponent - 1)) + mantissa
    }
}
