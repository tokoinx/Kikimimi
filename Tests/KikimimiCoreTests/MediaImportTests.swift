import XCTest
@testable import KikimimiCore

/// 落としたファイルを読み込むかどうかの決め方
final class MediaImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kikimimi-media-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAudioAndVideoExtensionsAreImportable() {
        for ext in ["mp3", "wav", "m4a", "aiff", "mp4", "mov", "MP3"] {
            XCTAssertTrue(MediaImport.isImportable(fileExtension: ext), ext)
        }
    }

    func testOtherExtensionsAreNotImportable() {
        for ext in ["txt", "pdf", "png", "zip", ""] {
            XCTAssertFalse(MediaImport.isImportable(fileExtension: ext), ext)
        }
    }

    func testSplitKeepsOrderAndRejectsFoldersAndWebURLs() throws {
        let wav = root.appendingPathComponent("a.wav")
        let text = root.appendingPathComponent("b.txt")
        let movie = root.appendingPathComponent("c.MOV")
        let folder = root.appendingPathComponent("sub", isDirectory: true)
        let web = try XCTUnwrap(URL(string: "https://example.com/d.mp3"))
        for file in [wav, text, movie] {
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let result = MediaImport.split([wav, text, movie, folder, web])

        XCTAssertEqual(result.accepted, [wav, movie])
        XCTAssertEqual(result.rejected, [text, folder, web])
    }
}
