import Foundation

public enum ModelKind: String, Codable, Sendable, Identifiable {
    case transcription
    case generation
    public var id: String { rawValue }
}

public struct ModelDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: ModelKind
    public let filename: String
    public let bytes: Int64
    public let guidance: String
    public let sourceName: String
    public let sourceURL: URL

    public init(
        id: String,
        name: String,
        kind: ModelKind,
        filename: String,
        bytes: Int64,
        guidance: String,
        sourceName: String,
        sourceURL: URL
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.filename = filename
        self.bytes = bytes
        self.guidance = guidance
        self.sourceName = sourceName
        self.sourceURL = sourceURL
    }
}

public enum ModelCatalog {
    public static let transcription: [ModelDescriptor] = [
        .init(
            id: "whisper-base-en",
            name: "Whisper Base English",
            kind: .transcription,
            filename: "ggml-base.en.bin",
            bytes: 148_897_792,
            guidance: "Fastest recommended option for English meetings.",
            sourceName: "whisper.cpp on Hugging Face",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!
        ),
        .init(
            id: "whisper-small-en",
            name: "Whisper Small English",
            kind: .transcription,
            filename: "ggml-small.en.bin",
            bytes: 488_000_000,
            guidance: "Better accuracy with higher memory use and latency.",
            sourceName: "whisper.cpp on Hugging Face",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!
        ),
    ]

    public static let generation: [ModelDescriptor] = [
        .init(
            id: "qwen2.5-1.5b-instruct-q4km",
            name: "Qwen 2.5 1.5B Instruct",
            kind: .generation,
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            bytes: 1_120_000_000,
            guidance: "Fast and compact; suitable for Macs with 8 GB memory.",
            sourceName: "Qwen on Hugging Face",
            sourceURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!
        ),
        .init(
            id: "qwen2.5-3b-instruct-q4km",
            name: "Qwen 2.5 3B Instruct",
            kind: .generation,
            filename: "qwen2.5-3b-instruct-q4_k_m.gguf",
            bytes: 2_100_000_000,
            guidance: "Higher-quality notes; recommended for Macs with 16 GB memory.",
            sourceName: "Qwen on Hugging Face",
            sourceURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!
        ),
    ]
}

public enum ModelValidator {
    public enum ValidationError: LocalizedError, Equatable {
        case missing
        case undersized(actual: Int64, minimum: Int64)
        case incompatible

        public var errorDescription: String? {
            switch self {
            case .missing: "The selected model file is missing."
            case let .undersized(actual, minimum): "The model is incomplete (\(actual) of at least \(minimum) bytes)."
            case .incompatible: "The selected file is not a compatible local model."
            }
        }
    }

    public static func validate(url: URL, kind: ModelKind, minimumBytes: Int64) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ValidationError.missing }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        guard size >= minimumBytes else { throw ValidationError.undersized(actual: size, minimum: minimumBytes) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        let expected = kind == .transcription ? Data("lmgg".utf8) : Data("GGUF".utf8)
        guard magic == expected else { throw ValidationError.incompatible }
    }
}

public enum ModelStorage {
    public static func directory(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Oatmeal/Models", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    public static func url(for descriptor: ModelDescriptor, fileManager: FileManager = .default) throws -> URL {
        try directory(fileManager: fileManager).appendingPathComponent(descriptor.filename)
    }
}

public struct ModelDownloader: Sendable {
    public enum DownloadError: LocalizedError, Equatable {
        case insufficientSpace(required: Int64, available: Int64)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case let .insufficientSpace(required, available):
                "The model needs \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)); only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
            case .invalidResponse: "The model server returned an unsuccessful response."
            }
        }
    }

    public init() {}

    public func download(
        _ descriptor: ModelDescriptor,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let values = try destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        try Self.checkCapacity(values.volumeAvailableCapacityForImportantUsage ?? 0, for: descriptor.bytes)
        let delegate = DownloadProgressDelegate(progress: progress)
        let (temporaryURL, response) = try await URLSession.shared.download(from: descriptor.sourceURL, delegate: delegate)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw DownloadError.invalidResponse
        }
        try ModelValidator.validate(url: temporaryURL, kind: descriptor.kind, minimumBytes: descriptor.bytes * 9 / 10)
        try Self.installDownloadedFile(from: temporaryURL, to: destination)
        return destination
    }

    public static func requiredCapacity(for bytes: Int64) -> Int64 {
        bytes + max(bytes / 10, 100_000_000)
    }

    public static func checkCapacity(_ available: Int64, for bytes: Int64) throws {
        let required = requiredCapacity(for: bytes)
        guard available >= required else { throw DownloadError.insufficientSpace(required: required, available: available) }
    }

    public static func installDownloadedFile(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
