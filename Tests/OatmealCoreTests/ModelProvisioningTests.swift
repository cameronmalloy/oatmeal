import XCTest
@testable import OatmealCore

final class ModelProvisioningTests: XCTestCase {
    func testValidatorRejectsMissingUndersizedAndWrongFormatModels() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try ModelValidator.validate(url: missing, kind: .transcription, minimumBytes: 16))

        let tiny = try temporaryFile(Data("lmgg".utf8))
        XCTAssertThrowsError(try ModelValidator.validate(url: tiny, kind: .transcription, minimumBytes: 16))

        let wrongFormat = try temporaryFile(Data(repeating: 1, count: 16))
        XCTAssertThrowsError(try ModelValidator.validate(url: wrongFormat, kind: .generation, minimumBytes: 16))
    }

    func testValidatorAcceptsExpectedLocalModelMagic() throws {
        let whisper = try temporaryFile(Data("lmgg".utf8) + Data(repeating: 0, count: 12))
        let gguf = try temporaryFile(Data("GGUF".utf8) + Data(repeating: 0, count: 12))

        XCTAssertNoThrow(try ModelValidator.validate(url: whisper, kind: .transcription, minimumBytes: 16))
        XCTAssertNoThrow(try ModelValidator.validate(url: gguf, kind: .generation, minimumBytes: 16))
    }

    func testCatalogDisclosesHTTPSModelSourcesAndUsefulChoices() {
        XCTAssertGreaterThanOrEqual(ModelCatalog.transcription.count, 2)
        XCTAssertGreaterThanOrEqual(ModelCatalog.generation.count, 2)
        XCTAssertTrue((ModelCatalog.transcription + ModelCatalog.generation).allSatisfy {
            $0.sourceURL.scheme == "https" &&
            $0.sourceURL.query == nil &&
            $0.bytes > 0 &&
            !$0.guidance.isEmpty
        })
    }

    func testCapacityPreflightIncludesSafetyMargin() {
        XCTAssertEqual(ModelDownloader.requiredCapacity(for: 1_000_000_000), 1_100_000_000)
        XCTAssertThrowsError(try ModelDownloader.checkCapacity(1_099_999_999, for: 1_000_000_000))
        XCTAssertNoThrow(try ModelDownloader.checkCapacity(1_100_000_000, for: 1_000_000_000))
    }

    func testDownloadedFileIsInstalledAtomicallyInModelDirectory() throws {
        let source = try temporaryFile(Data("GGUF".utf8) + Data(repeating: 0, count: 12))
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("model.gguf")

        try ModelDownloader.installDownloadedFile(from: source, to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("model")
        try data.write(to: url)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
