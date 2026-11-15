import XCTest
@testable import KikimimiCore

/// 結果をゴミ箱に入れる時に、何が消えて何が残るか (確認の画面と、実際に消す物の決め方)
final class DeletionPlanTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Users/me/Library/Application Support/Kikimimi/Library/1234", isDirectory: true)
    private let recordings = URL(fileURLWithPath: "/Users/me/Library/Application Support/Kikimimi/Recordings", isDirectory: true)
    private let recordingPath = "/Users/me/Library/Application Support/Kikimimi/Recordings/録音-1.wav"
    private let importedPath = "/Users/me/Music/talk.m4a"

    private func plan(saved: Bool = true, recording: Bool = false, path: String?, shared: Bool = false,
                      working: Bool = false) -> DeletionPlan {
        DeletionPlan.make(isSaved: saved, libraryFolder: folder, isRecording: recording, sourcePath: path,
                          recordingsDirectory: recordings, audioUsedByOtherJobs: shared, isWorking: working)
    }

    func testSavedImportedFileTrashesOnlyTheFolder() {
        let p = plan(path: importedPath)
        XCTAssertEqual(p.libraryFolder, folder)
        XCTAssertNil(p.recording)
        XCTAssertEqual(p.keptAudio?.path, importedPath)
        XCTAssertEqual(p.keptAudioReason, .original)
        XCTAssertFalse(p.isEmpty)
        XCTAssertFalse(p.stopsWork)
    }

    func testSavedRecordingTrashesFolderAndRecording() {
        let p = plan(recording: true, path: recordingPath)
        XCTAssertEqual(p.libraryFolder, folder)
        XCTAssertEqual(p.recording?.path, recordingPath)
        XCTAssertNil(p.keptAudio)
        XCTAssertNil(p.keptAudioReason)
    }

    func testRecordingUsedByAnotherJobIsKept() {
        let p = plan(recording: true, path: recordingPath, shared: true)
        XCTAssertEqual(p.libraryFolder, folder)
        XCTAssertNil(p.recording)
        XCTAssertEqual(p.keptAudio?.path, recordingPath)
        XCTAssertEqual(p.keptAudioReason, .sharedRecording)
    }

    func testRecordingOutsideTheAppFolderIsKept() {
        let path = "/Users/me/Desktop/録音-1.wav"
        let p = plan(recording: true, path: path)
        XCTAssertNil(p.recording)
        XCTAssertEqual(p.keptAudio?.path, path)
        XCTAssertEqual(p.keptAudioReason, .recordingOutsideAppFolder)
    }

    func testFolderThatOnlySharesThePrefixIsOutside() {
        let path = "/Users/me/Library/Application Support/Kikimimi/Recordings2/録音-1.wav"
        let p = plan(recording: true, path: path)
        XCTAssertNil(p.recording)
        XCTAssertEqual(p.keptAudioReason, .recordingOutsideAppFolder)
        // 録音フォルダそのもの (末尾の / の無いパス) も、中のファイルではない
        XCTAssertNil(DeletionPlan.recordingInAppFolder(recordings.path, recordingsDirectory: recordings))
    }

    func testPathIsStandardizedBeforeTheCheck() {
        // 「..」で録音フォルダの外へ出るパスは、外と見なす。中へ戻るパスは、中と見なす
        let escaping = recordings.path + "/../Library/1234/document.json"
        XCTAssertNil(DeletionPlan.recordingInAppFolder(escaping, recordingsDirectory: recordings))
        let inside = recordings.path + "/sub/../録音-1.wav"
        XCTAssertEqual(DeletionPlan.recordingInAppFolder(inside, recordingsDirectory: recordings)?.path, recordingPath)
    }

    func testUnsavedResultTrashesNothing() {
        let imported = plan(saved: false, path: importedPath, working: true)
        XCTAssertTrue(imported.isEmpty)
        XCTAssertNil(imported.libraryFolder)
        XCTAssertEqual(imported.keptAudioReason, .original)
        XCTAssertTrue(imported.stopsWork)

        let recorded = plan(saved: false, recording: true, path: recordingPath)
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertNil(recorded.recording)
        XCTAssertEqual(recorded.keptAudio?.path, recordingPath)
        XCTAssertEqual(recorded.keptAudioReason, .notSaved)
    }

    func testNoLibraryFolderMeansNotSaved() {
        let p = DeletionPlan.make(isSaved: true, libraryFolder: nil, isRecording: true, sourcePath: recordingPath,
                                  recordingsDirectory: recordings, audioUsedByOtherJobs: false, isWorking: false)
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.keptAudioReason, .notSaved)
    }

    func testNoSourcePath() {
        let saved = plan(recording: true, path: nil)
        XCTAssertEqual(saved.libraryFolder, folder)
        XCTAssertNil(saved.recording)
        XCTAssertNil(saved.keptAudio)
        XCTAssertNil(saved.keptAudioReason)
        XCTAssertFalse(saved.isEmpty)

        let unsaved = plan(saved: false, path: nil)
        XCTAssertTrue(unsaved.isEmpty)
        XCTAssertNil(unsaved.keptAudio)
    }
}
