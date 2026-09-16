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
        XCTAssertEqual(Set(ModelCatalog.transcription.map(\.id)), [
            "whisper-tiny-en",
            "whisper-base-en",
            "whisper-base-multilingual",
            "whisper-small-en",
            "whisper-medium-en-q5",
            "whisper-large-v3-turbo-q5",
        ])
        XCTAssertEqual(Set(ModelCatalog.generation.map(\.id)), [
            "qwen2.5-1.5b-instruct-q4km",
            "granite-3.3-2b-instruct-q4km",
            "qwen3-4b-instruct-2507-q8",
            "granite-3.3-8b-instruct-q4km",
        ])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (ModelCatalog.transcription + ModelCatalog.generation).map { ($0.id, $0.bytes) }), [
            "whisper-tiny-en": 77_704_715,
            "whisper-base-en": 147_964_211,
            "whisper-base-multilingual": 147_951_465,
            "whisper-small-en": 487_614_201,
            "whisper-medium-en-q5": 539_225_533,
            "whisper-large-v3-turbo-q5": 574_041_195,
            "qwen2.5-1.5b-instruct-q4km": 1_117_320_736,
            "granite-3.3-2b-instruct-q4km": 1_545_303_328,
            "qwen3-4b-instruct-2507-q8": 4_280_403_520,
            "granite-3.3-8b-instruct-q4km": 4_942_873_344,
        ])
        XCTAssertTrue((ModelCatalog.transcription + ModelCatalog.generation).allSatisfy {
            $0.sourceURL.scheme == "https" &&
            $0.sourceURL.host == "huggingface.co" &&
            $0.sourceURL.path.contains("/resolve/") &&
            $0.sourceURL.lastPathComponent == $0.filename &&
            $0.sourceURL.query == nil &&
            $0.bytes > 0 &&
            !$0.guidance.isEmpty &&
            ($0.sourceName.contains("MIT") || $0.sourceName.contains("Apache 2.0"))
        })
        XCTAssertTrue(ModelCatalog.transcription.allSatisfy { $0.kind == .transcription })
        XCTAssertTrue(ModelCatalog.generation.allSatisfy { $0.kind == .generation })
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
