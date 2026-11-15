import XCTest
@testable import KikimimiCore

/// 結果の保存 (ライブラリ)・メモ・版
final class LibraryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kikimimi-library-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var store: LibraryStore { LibraryStore(root: root) }

    /// 訳・文の続き・区間の言語・監査 (秒より細かい日時つき) の入った文字起こし
    private func richTranscript() -> Transcript {
        let a = TranscriptSegment(start: 0, end: 2.5, text: "Have you ever", translation: "これまでに、オーケストラで",
                                  translationCovers: nil, language: "en")
        let b = TranscriptSegment(start: 2.5, end: 4, text: "played in an orchestra?", language: "en")
        var head = a
        head.translationCovers = [b.id]
        let c = TranscriptSegment(start: 4, end: 6.25, text: "はい、あります。", language: "ja")
        let change = AuditChange(kind: .fix, origin: .llm, original: c, replacement: "はい、あります!", reason: "テスト",
                                 isConfident: false)
        let audit = AuditReport(changes: [change], model: "test-llm", reviewedCount: 3,
                                date: Date(timeIntervalSinceReferenceDate: 815_000_000.123_456_7),
                                userDecisions: ["k": true], isPartial: nil)
        return Transcript(sourceName: "talk.m4a", segments: [head, b, c], language: "en", model: "small",
                          duration: 6.25, elapsed: 1.5, audit: audit, translationModel: "test-llm")
    }

    private func document(title: String = "talk.m4a", createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
                          notes: String = "") -> SavedDocument {
        SavedDocument(title: title, sourcePath: "/Users/me/Music/talk.m4a", isRecording: false,
                      createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(10), languageCode: "en",
                      autoMixedFrom: "ja", transcript: richTranscript(), notes: notes)
    }

    // MARK: 保存と読み込み

    func testSaveThenLoadAllRoundTrip() throws {
        let notes = "理解したこと:\n- orchestra = オーケストラ\n\n"
        let doc = document(notes: notes)
        try store.save(doc)
        let loaded = store.loadAll()
        XCTAssertTrue(loaded.setAside.isEmpty)
        XCTAssertEqual(loaded.documents.count, 1)
        let back = try XCTUnwrap(loaded.documents.first)
        XCTAssertEqual(back, doc)
        XCTAssertEqual(back.transcript, doc.transcript, "dates with fractions of a second come back exactly")
        XCTAssertEqual(back.notes, notes)
        XCTAssertEqual(back.transcript.segments[0].translationCovers, [doc.transcript.segments[1].id])
        XCTAssertEqual(back.transcript.segments[2].language, "ja")
        XCTAssertEqual(back.transcript.audit?.date, doc.transcript.audit?.date)
        XCTAssertEqual(store.load(id: doc.id), doc)
    }

    func testNotesLiveOnlyInNotesFile() throws {
        let notes = "メモの本文 > [00:01] quote\n"
        let doc = document(notes: notes)
        try store.save(doc)
        let json = try String(contentsOf: store.documentURL(for: doc.id), encoding: .utf8)
        XCTAssertFalse(json.contains("メモの本文"))
        XCTAssertFalse(json.contains("\"notes\""))
        XCTAssertTrue(json.contains("/Users/me/Music/talk.m4a"), "slashes are not escaped")
        let data = try Data(contentsOf: store.notesURL(for: doc.id))
        XCTAssertEqual(data, Data(notes.utf8))
        XCTAssertEqual(store.notesURL(for: doc.id).lastPathComponent, "notes.md")
        XCTAssertEqual(store.folder(for: doc.id).lastPathComponent, doc.id.uuidString)

        try store.saveNotes(id: doc.id, text: "書きかえた")
        XCTAssertEqual(try String(contentsOf: store.notesURL(for: doc.id), encoding: .utf8), "書きかえた")
        XCTAssertEqual(store.loadAll().documents.first?.notes, "書きかえた")
    }

    func testMissingNotesFileMeansEmptyNotes() throws {
        let doc = document(notes: "x")
        try store.save(doc)
        try FileManager.default.removeItem(at: store.notesURL(for: doc.id))
        XCTAssertEqual(store.loadAll().documents.first?.notes, "")
    }

    func testSaveNotesOnMissingFolderCreatesNothing() throws {
        let id = UUID()
        try store.saveNotes(id: id, text: "hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testLoadAllSortsNewestFirst() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let old = document(title: "old", createdAt: base)
        let new = document(title: "new", createdAt: base.addingTimeInterval(3600))
        let middle = document(title: "middle", createdAt: base.addingTimeInterval(60))
        for d in [old, new, middle] { try store.save(d) }
        XCTAssertEqual(store.loadAll().documents.map(\.title), ["new", "middle", "old"])
    }

    func testEmptyOrMissingRootLoadsNothing() {
        let loaded = store.loadAll()
        XCTAssertTrue(loaded.documents.isEmpty)
        XCTAssertTrue(loaded.setAside.isEmpty)
    }

    func testUnreadableDocumentIsSetAsideAndOthersLoad() throws {
        let good = document(title: "good")
        let bad = document(title: "bad")
        try store.save(good)
        try store.save(bad)
        try Data("{ not json".utf8).write(to: store.documentURL(for: bad.id))
        // ID の名前でないフォルダや、document.json の無いフォルダは見ない
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-an-id"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.folder(for: UUID()), withIntermediateDirectories: true)

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let loaded = store.loadAll(date: date)
        XCTAssertEqual(loaded.documents.map(\.title), ["good"])
        XCTAssertEqual(loaded.setAside.count, 1)
        let aside = try XCTUnwrap(loaded.setAside.first)
        XCTAssertEqual(aside.deletingLastPathComponent().lastPathComponent, bad.id.uuidString)
        XCTAssertTrue(aside.lastPathComponent.hasPrefix("document.unreadable-"))
        XCTAssertTrue(aside.lastPathComponent.hasSuffix(".json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.documentURL(for: bad.id).path))
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ not json")
        // 2 回目は、もう飛ばすだけ
        let again = store.loadAll(date: date)
        XCTAssertEqual(again.documents.map(\.title), ["good"])
        XCTAssertTrue(again.setAside.isEmpty)
    }

    func testUnknownKeysAndMissingOptionalKeysLoad() throws {
        let id = UUID()
        let segID = UUID()
        let json = """
        {
          "id" : "\(id.uuidString)",
          "createdAt" : "2026-11-12T10:20:30Z",
          "futureField" : { "anything" : [1, 2, 3] },
          "transcript" : {
            "sourceName" : "rec.wav",
            "segments" : [ { "id" : "\(segID.uuidString)", "start" : 0, "end" : 1, "text" : "Hello" } ],
            "duration" : 1,
            "elapsed" : 0.5
          },
          "versions" : [ { "id" : "\(UUID().uuidString)", "origin" : "somethingNew", "savedAt" : "2026-11-12T10:20:31.5Z" } ]
        }
        """
        try FileManager.default.createDirectory(at: store.folder(for: id), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.documentURL(for: id))
        let loaded = store.loadAll()
        XCTAssertTrue(loaded.setAside.isEmpty)
        let doc = try XCTUnwrap(loaded.documents.first)
        XCTAssertEqual(doc.id, id)
        XCTAssertEqual(doc.formatVersion, 1)
        XCTAssertEqual(doc.title, "rec.wav")
        XCTAssertNil(doc.sourcePath)
        XCTAssertFalse(doc.isRecording)
        XCTAssertNil(doc.languageCode)
        XCTAssertNil(doc.autoMixedFrom)
        XCTAssertEqual(doc.updatedAt, doc.createdAt)
        XCTAssertEqual(doc.transcript.segments.map(\.text), ["Hello"])
        XCTAssertEqual(doc.notes, "")
        XCTAssertTrue(doc.versions.isEmpty, "the version file is missing")

        // 版の見出しの知らない origin は manual、無い項目はふつうの値
        let info = try LibraryStore.decoder().decode(VersionInfo.self, from: Data("""
        { "id" : "\(UUID().uuidString)", "origin" : "somethingNew", "savedAt" : "2026-11-12T10:20:31.5Z", "extra" : 1 }
        """.utf8))
        XCTAssertEqual(info.origin, .manual)
        XCTAssertEqual(info.label, "")
        XCTAssertEqual(info.segmentCount, 0)
        XCTAssertEqual(info.savedAt.timeIntervalSince1970, 1_794_478_831.5, accuracy: 0.000_1)
    }

    func testTwoSavesWriteIdenticalBytes() throws {
        var doc = document(notes: "メモ\n")
        doc = try store.addVersion(to: doc, label: "A", origin: .manual, date: Date(timeIntervalSince1970: 1_800_000_100.25))
        let first = try Data(contentsOf: store.documentURL(for: doc.id))
        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        let other = LibraryStore(root: otherRoot)
        try other.save(doc)
        try store.save(doc)
        XCTAssertEqual(try Data(contentsOf: store.documentURL(for: doc.id)), first)
        XCTAssertEqual(try Data(contentsOf: other.documentURL(for: doc.id)), first)
        // キーは名前の順
        let text = String(decoding: first, as: UTF8.self)
        let keys = ["\"autoMixedFrom\"", "\"createdAt\"", "\"formatVersion\"", "\"id\"", "\"isRecording\"",
                    "\"languageCode\"", "\"sourcePath\"", "\"title\"", "\"transcript\"", "\"updatedAt\"", "\"versions\""]
        let positions = keys.compactMap { text.range(of: "\n  " + $0)?.lowerBound }
        XCTAssertEqual(positions.count, keys.count)
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.versionURL(documentID: doc.id, versionID: doc.versions[0].id).path))
        XCTAssertEqual(store.versionURL(documentID: doc.id, versionID: doc.versions[0].id).lastPathComponent,
                       doc.versions[0].id.uuidString + ".json")
    }

    func testDatesRoundTripExactly() throws {
        let samples: [Double] = [0, 815_000_000, 815_000_000.5, 815_000_000.123_456_789, 815_000_000.000_012_5,
                                 -1.75, 1e-7, 815_000_000.999_999_9, Date().timeIntervalSinceReferenceDate]
        for t in samples {
            let date = Date(timeIntervalSinceReferenceDate: t)
            let text = LibraryDate.string(from: date)
            XCTAssertTrue(text.hasSuffix("Z"), text)
            XCTAssertEqual(LibraryDate.date(from: text), date, text)
        }
        XCTAssertEqual(LibraryDate.string(from: Date(timeIntervalSince1970: 1_794_478_830)), "2026-11-12T10:20:30Z")
        // ほかの書き方 (時差つき) も読める
        XCTAssertEqual(LibraryDate.date(from: "2026-11-12T19:20:30.5+09:00"), Date(timeIntervalSince1970: 1_794_478_830.5))
        XCTAssertNil(LibraryDate.date(from: "yesterday"))
    }

    // MARK: 版

    func testAddAndLoadVersion() throws {
        var doc = document(notes: "最初のメモ")
        try store.save(doc)
        let date = Date(timeIntervalSince1970: 1_800_000_500)
        doc = try store.addVersion(to: doc, label: "A", origin: .manual, date: date)
        XCTAssertEqual(doc.versions.count, 1)
        let info = doc.versions[0]
        XCTAssertEqual(info.label, "A")
        XCTAssertEqual(info.origin, .manual)
        XCTAssertEqual(info.savedAt, date)
        XCTAssertEqual(info.segmentCount, 3)
        XCTAssertEqual(info.noteLength, 5)
        let version = try store.loadVersion(documentID: doc.id, versionID: info.id)
        XCTAssertEqual(version.info, info)
        XCTAssertEqual(version.transcript, doc.transcript)
        XCTAssertEqual(version.notes, "最初のメモ")
        // 一覧は document.json にも入る
        XCTAssertEqual(store.loadAll().documents.first?.versions, [info])

        doc.notes = "次のメモ"
        doc = try store.addVersion(to: doc, label: "", origin: .manual, date: date.addingTimeInterval(1))
        XCTAssertEqual(doc.versions.map(\.label), ["", "A"])
        XCTAssertEqual(store.loadAll().documents.first?.versions, doc.versions)
        XCTAssertThrowsError(try store.loadVersion(documentID: doc.id, versionID: UUID()))
    }

    func testOverwriteWithNoVersionAddsOne() throws {
        var doc = document(notes: "n")
        doc = try store.overwriteLatestVersion(of: doc, label: "X", date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(doc.versions.count, 1)
        XCTAssertEqual(doc.versions[0].origin, .manual)
        XCTAssertEqual(doc.versions[0].label, "X")
        XCTAssertEqual(try store.loadVersion(documentID: doc.id, versionID: doc.versions[0].id).notes, "n")
    }

    func testOverwriteWithOnlyAutomaticVersionAddsManualOne() throws {
        var doc = document(notes: "n")
        doc = try store.addVersion(to: doc, label: "戻す前の状態", origin: .beforeRestore, date: Date(timeIntervalSince1970: 1_800_000_000))
        let auto = doc.versions[0]
        doc.notes = "m"
        doc = try store.overwriteLatestVersion(of: doc, label: "X", date: Date(timeIntervalSince1970: 1_800_000_010))
        XCTAssertEqual(doc.versions.count, 2)
        XCTAssertEqual(doc.versions.map(\.origin), [.manual, .beforeRestore])
        XCTAssertEqual(doc.versions[1], auto)
        XCTAssertEqual(try store.loadVersion(documentID: doc.id, versionID: auto.id).notes, "n")
    }

    func testOverwriteReplacesManualVersionUnderNewerAutomaticOne() throws {
        var doc = document(notes: "a")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        doc = try store.addVersion(to: doc, label: "A", origin: .manual, date: t0)
        let manual = doc.versions[0]
        doc.notes = "auto"
        doc = try store.addVersion(to: doc, label: "戻す前の状態", origin: .beforeRestore, date: t0.addingTimeInterval(1))
        let auto = doc.versions[0]
        doc.notes = "c は長いメモ"
        doc.transcript.segments.removeLast()
        let t2 = t0.addingTimeInterval(2)
        doc = try store.overwriteLatestVersion(of: doc, label: "C", date: t2)
        XCTAssertEqual(doc.versions.count, 2)
        XCTAssertEqual(doc.versions[0].id, manual.id, "keeps the id")
        XCTAssertEqual(doc.versions[0].label, "C")
        XCTAssertEqual(doc.versions[0].savedAt, t2)
        XCTAssertEqual(doc.versions[0].segmentCount, 2)
        XCTAssertEqual(doc.versions[0].noteLength, 7)
        XCTAssertEqual(doc.versions[1], auto)
        let content = try store.loadVersion(documentID: doc.id, versionID: manual.id)
        XCTAssertEqual(content.notes, "c は長いメモ")
        XCTAssertEqual(content.transcript.segments.count, 2)
        XCTAssertEqual(content.info, doc.versions[0])
        XCTAssertEqual(try store.loadVersion(documentID: doc.id, versionID: auto.id).notes, "auto")
        XCTAssertEqual(store.loadAll().documents.first?.versions, doc.versions)
        XCTAssertEqual(doc.latestManualVersion?.id, manual.id)
    }

    func testDeleteVersion() throws {
        var doc = document()
        doc = try store.addVersion(to: doc, label: "A", origin: .manual, date: Date(timeIntervalSince1970: 1_800_000_000))
        doc = try store.addVersion(to: doc, label: "B", origin: .manual, date: Date(timeIntervalSince1970: 1_800_000_001))
        let a = doc.versions[1]
        doc = try store.deleteVersion(of: doc, versionID: a.id)
        XCTAssertEqual(doc.versions.map(\.label), ["B"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.versionURL(documentID: doc.id, versionID: a.id).path))
        XCTAssertEqual(store.loadAll().documents.first?.versions.map(\.label), ["B"])
        // もう無い版を消しても失敗しない
        doc = try store.deleteVersion(of: doc, versionID: a.id)
        XCTAssertEqual(doc.versions.count, 1)
    }

    func testIndexEntryWithMissingFileIsDroppedAtLoad() throws {
        var doc = document()
        doc = try store.addVersion(to: doc, label: "A", origin: .manual, date: Date(timeIntervalSince1970: 1_800_000_000))
        doc = try store.addVersion(to: doc, label: "B", origin: .manual, date: Date(timeIntervalSince1970: 1_800_000_001))
        try FileManager.default.removeItem(at: store.versionURL(documentID: doc.id, versionID: doc.versions[0].id))
        XCTAssertEqual(store.loadAll().documents.first?.versions.map(\.label), ["A"])
    }

    func testRestoringEachCombination() {
        let doc = document(notes: "いまのメモ")
        var old = doc.transcript
        old.segments = [TranscriptSegment(start: 0, end: 1, text: "old")]
        let version = DocumentVersion(info: VersionInfo(savedAt: Date(), segmentCount: 1, noteLength: 6),
                                      transcript: old, notes: "古いメモ")
        let both = doc.restoring(version, transcript: true, notes: true)
        XCTAssertEqual(both.transcript, old)
        XCTAssertEqual(both.notes, "古いメモ")
        let onlyTranscript = doc.restoring(version, transcript: true, notes: false)
        XCTAssertEqual(onlyTranscript.transcript, old)
        XCTAssertEqual(onlyTranscript.notes, "いまのメモ")
        let onlyNotes = doc.restoring(version, transcript: false, notes: true)
        XCTAssertEqual(onlyNotes.transcript, doc.transcript)
        XCTAssertEqual(onlyNotes.notes, "古いメモ")
        XCTAssertEqual(doc.restoring(version, transcript: false, notes: false), doc)
        for d in [both, onlyTranscript, onlyNotes] {
            XCTAssertEqual(d.id, doc.id)
            XCTAssertEqual(d.versions, doc.versions)
            XCTAssertEqual(d.updatedAt, doc.updatedAt)
        }
    }

    func testCopiedFolderLoadsUnderItsOwnName() throws {
        let doc = document(notes: "写したメモ")
        try store.save(doc)
        let copyID = UUID()
        try FileManager.default.copyItem(at: store.folder(for: doc.id), to: store.folder(for: copyID))
        let loaded = store.loadAll().documents
        XCTAssertEqual(Set(loaded.map(\.id)), [doc.id, copyID])
        let copy = try XCTUnwrap(loaded.first { $0.id == copyID })
        XCTAssertEqual(copy.notes, "写したメモ")
        // 保存し直しても、元のフォルダは変わらない
        var changed = copy
        changed.title = "copy"
        try store.save(changed)
        XCTAssertEqual(store.load(id: doc.id)?.title, doc.title)
        XCTAssertEqual(store.load(id: copyID)?.title, "copy")
    }

    func testDeleteRemovesFolderAndSaveNotesDoesNotBringItBack() throws {
        var doc = document(notes: "x")
        doc = try store.addVersion(to: doc, label: "A", origin: .manual, date: Date(timeIntervalSince1970: 1_800_000_000))
        try store.delete(id: doc.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: doc.id).path))
        try store.saveNotes(id: doc.id, text: "後から")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: doc.id).path))
        XCTAssertTrue(store.loadAll().documents.isEmpty)
        // 無いものを消しても失敗しない
        XCTAssertNoThrow(try store.delete(id: doc.id))
    }

    func testDefaultRoot() {
        XCTAssertEqual(LibraryStore.defaultRoot(environment: ["KIKIMIMI_LIBRARY_DIR": "/tmp/lib"]).path, "/tmp/lib")
        let standard = LibraryStore.defaultRoot(environment: [:])
        XCTAssertEqual(standard.lastPathComponent, "Library")
        XCTAssertEqual(standard.deletingLastPathComponent().lastPathComponent, "Kikimimi")
    }

    // MARK: メモに引用

    func testNoteQuoteLine() {
        XCTAssertEqual(NoteQuote.line(time: 142.7, text: "Have you ever played?"), "> [02:22] Have you ever played?\n")
        XCTAssertEqual(NoteQuote.line(time: 5, text: " Hi "), "> [00:05] Hi\n")
        XCTAssertEqual(NoteQuote.line(time: 3723, text: "Long talk"), "> [1:02:03] Long talk\n")
        XCTAssertEqual(NoteQuote.line(time: 61, text: "one\ntwo\r\nthree"), "> [01:01] one two three\n")
    }

    func testNoteQuoteAppending() {
        let quote = "> [00:05] Hi\n"
        XCTAssertEqual(NoteQuote.appending(quote, to: ""), quote)
        XCTAssertEqual(NoteQuote.appending(quote, to: "メモ"), "メモ\n\n" + quote)
        XCTAssertEqual(NoteQuote.appending(quote, to: "メモ\n"), "メモ\n\n" + quote)
        XCTAssertEqual(NoteQuote.appending(quote, to: "メモ\n\n"), "メモ\n\n" + quote)
        // 続けて引用しても、引用の間に空の行が 1 つ
        let twice = NoteQuote.appending("> [00:09] Bye\n", to: NoteQuote.appending(quote, to: ""))
        XCTAssertEqual(twice, quote + "\n> [00:09] Bye\n")
    }
}
