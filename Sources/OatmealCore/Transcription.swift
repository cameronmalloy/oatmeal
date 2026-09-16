import Darwin
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

    public func discard() {
        pending.removeAll(keepingCapacity: true)
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
    private let activityThreshold: Float
    public private(set) var status: TranscriptionStatus = .ready

    public init(engine: any TranscriptionEngine, store: MeetingStore, activityThreshold: Float = 0.01) {
        self.engine = engine
        self.store = store
        self.activityThreshold = max(0, activityThreshold)
    }

    public func validateModel() async throws {
        try await engine.validateModel()
    }

    @discardableResult
    public func transcribe(
        _ chunk: CapturedAudioChunk,
        meetingID: UUID,
        partial: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TranscriptSegment? {
        guard hasActivity(chunk) else { return nil }
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

    public nonisolated func hasActivity(_ chunk: CapturedAudioChunk) -> Bool {
        let frameSamples = max(1, Int((chunk.sampleRate * 0.02).rounded()) * max(1, chunk.channels))
        return stride(from: 0, to: chunk.samples.count, by: frameSamples).contains { start in
            let frame = chunk.samples[start..<min(start + frameSamples, chunk.samples.count)]
            let energy = frame.reduce(Float.zero) { $0 + $1 * $1 } / Float(frame.count)
            return sqrt(energy) > activityThreshold
        }
    }
}

/// A running local `whisper-server` process dedicated to one audio source.
public protocol WhisperRuntimeProcess: Sendable {
    var isRunning: Bool { get }
    func waitUntilReady(timeout: TimeInterval) async throws
    func infer(wav: Data) async throws -> String
    func terminate()
}

/// Keeps one warm `whisper-server` process per audio source so the selected model
/// loads once instead of reloading for every five-second window.
public final class WhisperServerEngine: TranscriptionEngine, @unchecked Sendable {
    public enum RuntimeError: LocalizedError {
        case missingExecutable
        case missingRuntime
        case startupTimedOut
        case startupFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingExecutable: "The local whisper.cpp server runtime is missing."
            case .missingRuntime: "The local transcription runtime is not ready."
            case .startupTimedOut: "The local transcription runtime did not become ready in time."
            case let .startupFailed(message): "Local transcription runtime failed to start: \(message)"
            }
        }
    }

    public let modelURL: URL
    private let startupTimeout: TimeInterval
    private let launch: @Sendable (AudioSource, URL) throws -> any WhisperRuntimeProcess
    private let lock = NSLock()
    private var runtimes: [AudioSource: any WhisperRuntimeProcess] = [:]
    private var preparations: [AudioSource: Task<Void, Error>] = [:]

    public init(
        modelURL: URL,
        startupTimeout: TimeInterval = 10,
        launch: @escaping @Sendable (AudioSource, URL) throws -> any WhisperRuntimeProcess
    ) {
        self.modelURL = modelURL
        self.startupTimeout = startupTimeout
        self.launch = launch
    }

    public func validateModel() async throws {
        try ModelValidator.validate(url: modelURL, kind: .transcription, minimumBytes: 1_000_000)
        // ponytail: concurrent whisper-server launches race on the shared Metal shader
        // cache and can stall 15s+; starting one fully before the next avoids it.
        let microphoneResult = await Task { try await self.prepare(.microphone) }.result
        let systemResult = await Task { try await self.prepare(.system) }.result
        try microphoneResult.get()
        try systemResult.get()
    }

    public func transcribe(_ chunk: CapturedAudioChunk, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await prepare(chunk.source)
        guard let runtime = lock.withLock({ runtimes[chunk.source] }) else { throw RuntimeError.missingRuntime }
        let wav = try WAVEncoder.encode(chunk)
        do {
            return try await runtime.infer(wav: wav)
        } catch {
            if !runtime.isRunning { lock.withLock { runtimes[chunk.source] = nil } }
            throw error
        }
    }

    public func shutdown() {
        lock.withLock {
            for runtime in runtimes.values where runtime.isRunning { runtime.terminate() }
            runtimes.removeAll()
            preparations.removeAll()
        }
    }

    deinit { shutdown() }

    private func prepare(_ source: AudioSource) async throws {
        if let existing = lock.withLock({ runtimes[source] }), existing.isRunning { return }
        let task: Task<Void, Error> = lock.withLock {
            if let existing = preparations[source] { return existing }
            let task = Task { try await self.startRuntime(source) }
            preparations[source] = task
            return task
        }
        do {
            try await task.value
            lock.withLock { preparations[source] = nil }
        } catch {
            lock.withLock { preparations[source] = nil }
            throw error
        }
    }

    private func startRuntime(_ source: AudioSource) async throws {
        let runtime: any WhisperRuntimeProcess
        do { runtime = try launch(source, modelURL) }
        catch { throw RuntimeError.startupFailed(String(describing: error)) }
        do { try await runtime.waitUntilReady(timeout: startupTimeout) }
        catch {
            runtime.terminate()
            throw error
        }
        lock.withLock { runtimes[source] = runtime }
    }

    public static func bundled(modelURL: URL, bundle: Bundle = .main) throws -> WhisperServerEngine {
        guard let executable = RuntimeLocator.executable(named: "whisper-server", bundle: bundle) else {
            throw RuntimeError.missingExecutable
        }
        return WhisperServerEngine(modelURL: modelURL) { _, modelURL in
            try ProcessWhisperRuntime(executableURL: executable, modelURL: modelURL)
        }
    }
}

/// Launches and talks to one real `whisper-server` process over the loopback interface.
final class ProcessWhisperRuntime: WhisperRuntimeProcess, @unchecked Sendable {
    private let process: Process
    private let port: Int
    private let session: URLSession
    private let errorLog = BoundedErrorLog()

    static func serverArguments(modelPath: String, port: Int) -> [String] {
        ["--no-gpu", "-m", modelPath, "--host", "127.0.0.1", "--port", "\(port)"]
    }

    init(executableURL: URL, modelURL: URL) throws {
        port = try Self.availablePort()
        process = Process()
        process.executableURL = executableURL
        process.arguments = Self.serverArguments(modelPath: modelURL.path, port: port)
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let errorLog = self.errorLog
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errorLog.append(data)
        }
        session = URLSession(configuration: .ephemeral)
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func waitUntilReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let readyURL = URL(string: "http://127.0.0.1:\(port)/")!
        while Date() < deadline {
            guard process.isRunning else { throw WhisperServerEngine.RuntimeError.startupFailed(errorLog.text) }
            if let (_, response) = try? await session.data(from: readyURL), (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw WhisperServerEngine.RuntimeError.startupTimedOut
    }

    func infer(wav: Data) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(wav: wav, boundary: boundary)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WhisperServerEngine.RuntimeError.startupFailed(errorLog.text)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func terminate() {
        session.invalidateAndCancel()
        if process.isRunning { process.terminate() }
    }

    private static func multipartBody(wav: Data, boundary: String) -> Data {
        var body = Data()
        func appendField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        appendField(name: "response_format", value: "text")
        appendField(name: "no_timestamps", value: "true")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WhisperServerEngine.RuntimeError.startupFailed("Could not allocate a local port.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { throw WhisperServerEngine.RuntimeError.startupFailed("Could not allocate a local port.") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard nameResult == 0 else { throw WhisperServerEngine.RuntimeError.startupFailed("Could not allocate a local port.") }
        return Int(UInt16(bigEndian: actual.sin_port))
    }
}

/// Bounds captured stderr so a noisy or wedged runtime cannot grow memory unboundedly.
final class BoundedErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int = 4_096) { self.limit = limit }

    func append(_ bytes: Data) {
        lock.withLock {
            data.append(bytes)
            if data.count > limit { data.removeFirst(data.count - limit) }
        }
    }

    var text: String {
        let trimmed = lock.withLock { String(data: data, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "no runtime output" : trimmed
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
