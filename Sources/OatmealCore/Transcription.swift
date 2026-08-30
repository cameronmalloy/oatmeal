import Foundation

public enum WAVEncoder {
    public enum EncodingError: LocalizedError {
        case unsupportedFormat
        public var errorDescription: String? { "Audio must be normalized mono PCM before transcription." }
    }

    public static func encode(_ chunk: CapturedAudioChunk) throws -> Data {
        guard chunk.channels == 1, chunk.sampleRate > 0 else { throw EncodingError.unsupportedFormat }
        let pcm: [Int16] = chunk.samples.map { sample in
            Int16(max(-1, min(1, sample)) * Float(Int16.max))
        }
        let dataSize = UInt32(pcm.count * MemoryLayout<Int16>.size)
        let sampleRate = UInt32(chunk.sampleRate.rounded())
        var data = Data()
        data.append(Data("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(Data("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(Data("data".utf8))
        data.appendLittleEndian(dataSize)
        for sample in pcm { data.appendLittleEndian(sample) }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

public actor AudioWindowAssembler {
    private struct Pending {
        var startMS: Int64
        var samples: [Float]
    }

    private let windowSamples: Int
    private let maximumSamplesPerSource: Int
    private var pending: [AudioSource: Pending] = [:]
    public private(set) var droppedSampleCount = 0

    public init(windowSamples: Int = 80_000, maximumSamplesPerSource: Int = 960_000) {
        self.windowSamples = max(1, windowSamples)
        self.maximumSamplesPerSource = max(1, maximumSamplesPerSource)
    }

    public var pendingSampleCount: Int { pending.values.reduce(0) { $0 + $1.samples.count } }

    public func append(_ chunk: CapturedAudioChunk) -> [CapturedAudioChunk] {
        var value = pending[chunk.source] ?? Pending(startMS: chunk.startMS, samples: [])
        value.samples.append(contentsOf: chunk.samples)
        if value.samples.count > maximumSamplesPerSource {
            let overflow = value.samples.count - maximumSamplesPerSource
            value.samples.removeFirst(overflow)
            value.startMS += Int64(Double(overflow) / chunk.sampleRate * 1_000)
            droppedSampleCount += overflow
        }
        var windows: [CapturedAudioChunk] = []
        while value.samples.count >= windowSamples {
            let samples = Array(value.samples.prefix(windowSamples))
            value.samples.removeFirst(windowSamples)
            let window = CapturedAudioChunk(source: chunk.source, startMS: value.startMS, sampleRate: chunk.sampleRate, channels: 1, samples: samples)
            windows.append(window)
            value.startMS += window.durationMS
        }
        pending[chunk.source] = value
        return windows
    }

    public func flush() -> [CapturedAudioChunk] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending.compactMap { source, value in
            guard !value.samples.isEmpty else { return nil }
            return CapturedAudioChunk(source: source, startMS: value.startMS, sampleRate: 16_000, channels: 1, samples: value.samples)
        }
    }
}

public protocol TranscriptionEngine: Sendable {
    func validateModel() async throws
    func transcribe(_ chunk: CapturedAudioChunk, partial: @escaping @Sendable (String) -> Void) async throws -> String
}

public extension TranscriptionEngine {
    func transcribe(_ chunk: CapturedAudioChunk) async throws -> String {
        try await transcribe(chunk, partial: { _ in })
    }
}

public enum TranscriptionStatus: Equatable, Sendable {
    case ready
    case transcribing
    case degraded(String)
}

public actor TranscriptionCoordinator {
    public enum TranscriptionError: LocalizedError {
        case emptyResult
        public var errorDescription: String? { "Local transcription returned no text." }
    }

    private let engine: any TranscriptionEngine
    private let store: MeetingStore
    public private(set) var status: TranscriptionStatus = .ready

    public init(engine: any TranscriptionEngine, store: MeetingStore) {
        self.engine = engine
        self.store = store
    }

    public func validateModel() async throws {
        try await engine.validateModel()
    }

    @discardableResult
    public func transcribe(
        _ chunk: CapturedAudioChunk,
        meetingID: UUID,
        partial: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TranscriptSegment {
        status = .transcribing
        do {
            let text = try await engine.transcribe(chunk, partial: partial).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.emptyResult }
            let segment = TranscriptSegment(
                meetingID: meetingID,
                source: TranscriptSource(chunk.source),
                startMS: chunk.startMS,
                endMS: chunk.startMS + chunk.durationMS,
                text: text
            )
            try store.saveSegment(segment)
            status = .ready
            return segment
        } catch {
            status = .degraded(error.localizedDescription)
            throw error
        }
    }
}

public struct WhisperProcessEngine: TranscriptionEngine {
    public enum RuntimeError: LocalizedError {
        case missingExecutable
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .missingExecutable: "The local whisper.cpp runtime is missing."
            case let .failed(message): "Local transcription failed: \(message)"
            }
        }
    }

    public let executableURL: URL
    public let modelURL: URL
    public let temporaryDirectory: URL

    public init(executableURL: URL, modelURL: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.temporaryDirectory = temporaryDirectory
    }

    public func validateModel() async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw RuntimeError.missingExecutable }
        try ModelValidator.validate(url: modelURL, kind: .transcription, minimumBytes: 1_000_000)
    }

    public func transcribe(_ chunk: CapturedAudioChunk, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await validateModel()
        let wavURL = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        try WAVEncoder.encode(chunk).write(to: wavURL, options: .atomic)

        let process = Process()
        process.executableURL = executableURL
        // ponytail: Homebrew's Metal backend can crash during allocation; CPU remains faster than realtime for the curated models.
        process.arguments = ["--no-gpu", "-m", modelURL.path, "-f", wavURL.path, "-nt", "-np"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let captured = LockedData()
        let capturedErrors = LockedData()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            captured.append(data)
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                partial(text)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { capturedErrors.append(data) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    captured.append(output.fileHandleForReading.readDataToEndOfFile())
                    capturedErrors.append(errors.fileHandleForReading.readDataToEndOfFile())
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: String(data: captured.value, encoding: .utf8) ?? "")
                    } else {
                        let message = String(data: capturedErrors.value, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                        continuation.resume(throwing: RuntimeError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
                do { try process.run() }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    public static func bundled(modelURL: URL, bundle: Bundle = .main) throws -> WhisperProcessEngine {
        guard let executable = RuntimeLocator.executable(named: "whisper-cli", bundle: bundle) else { throw RuntimeError.missingExecutable }
        return .init(executableURL: executable, modelURL: modelURL)
    }
}

enum RuntimeLocator {
    static func executable(named name: String, bundle: Bundle = .main) -> URL? {
        let candidates = [
            bundle.resourceURL?.appendingPathComponent("Runtimes/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) { lock.withLock { data.append(bytes) } }
    var value: Data { lock.withLock { data } }
}
