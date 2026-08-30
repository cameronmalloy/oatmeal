import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

public struct CapturedAudioChunk: Equatable, Sendable {
    public let source: AudioSource
    public let startMS: Int64
    public let sampleRate: Double
    public let channels: Int
    public let samples: [Float]

    public init(source: AudioSource, startMS: Int64, sampleRate: Double, channels: Int, samples: [Float]) {
        self.source = source
        self.startMS = startMS
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = samples
    }

    public var durationMS: Int64 {
        guard sampleRate > 0, channels > 0 else { return 0 }
        return Int64((Double(samples.count / channels) / sampleRate * 1_000).rounded())
    }
}

enum AudioSamples {
    static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0, sourceRate != targetRate else { return samples }
        let count = max(1, Int((Double(samples.count) * targetRate / sourceRate).rounded()))
        // ponytail: linear interpolation is enough for speech; use AVAudioConverter if measured STT quality requires it.
        return (0..<count).map { outputIndex in
            let position = Double(outputIndex) * sourceRate / targetRate
            let lower = min(Int(position), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }
}

public actor BoundedAudioBuffer {
    private let capacity: Int
    private var chunks: [CapturedAudioChunk] = []
    public private(set) var droppedCount = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func append(_ chunk: CapturedAudioChunk) {
        chunks.append(chunk)
        if chunks.count > capacity {
            let overflow = chunks.count - capacity
            chunks.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    public func drain() -> [CapturedAudioChunk] {
        defer { chunks.removeAll(keepingCapacity: true) }
        return chunks
    }
}

public enum CapturePermissionState: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

public struct CapturePermissionStatus: Equatable, Sendable {
    public let microphone: CapturePermissionState
    public let systemAudio: CapturePermissionState
    public var allGranted: Bool { microphone == .granted && systemAudio == .granted }
}

public enum CapturePermissions {
    public static func current() -> CapturePermissionStatus {
        let microphone: CapturePermissionState = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        return .init(microphone: microphone, systemAudio: CGPreflightScreenCaptureAccess() ? .granted : .denied)
    }

    public static func request() async -> CapturePermissionStatus {
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        let systemAudio = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        return .init(microphone: microphone ? .granted : .denied, systemAudio: systemAudio ? .granted : .denied)
    }
}

public protocol AudioCaptureSource: AnyObject, Sendable {
    func start(handler: @escaping @Sendable (CapturedAudioChunk) -> Void) async throws
    func stop() async
}

public final class CaptureClock: @unchecked Sendable {
    private let start = ProcessInfo.processInfo.systemUptime
    public init() {}
    public var nowMS: Int64 { Int64(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded()) }
}

public final class MicrophoneCapture: AudioCaptureSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let clock: CaptureClock
    private var tapInstalled = false

    public init(clock: CaptureClock) { self.clock = clock }

    public func start(handler: @escaping @Sendable (CapturedAudioChunk) -> Void) async throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [clock] buffer, _ in
            guard let samples = Self.monoSamples(from: buffer), !samples.isEmpty else { return }
            handler(.init(
                source: .microphone,
                startMS: clock.nowMS,
                sampleRate: 16_000,
                channels: 1,
                samples: AudioSamples.resample(samples, from: format.sampleRate, to: 16_000)
            ))
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    public func stop() async {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }
        if channelCount == 1 { return Array(UnsafeBufferPointer(start: channels[0], count: frameCount)) }
        return (0..<frameCount).map { frame in
            (0..<channelCount).reduce(0) { $0 + channels[$1][frame] } / Float(channelCount)
        }
    }
}

public final class SystemAudioCapture: NSObject, AudioCaptureSource, SCStreamOutput, @unchecked Sendable {
    public enum CaptureError: LocalizedError {
        case noDisplay
        case unreadableAudio

        public var errorDescription: String? {
            switch self {
            case .noDisplay: "No display is available for system-audio capture."
            case .unreadableAudio: "macOS returned unreadable system audio."
            }
        }
    }

    private let clock: CaptureClock
    private let queue = DispatchQueue(label: "Oatmeal.SystemAudio")
    private var stream: SCStream?
    private var handler: (@Sendable (CapturedAudioChunk) -> Void)?

    public init(clock: CaptureClock) { self.clock = clock }

    public func start(handler: @escaping @Sendable (CapturedAudioChunk) -> Void) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.handler = handler
        self.stream = stream
        try await stream.startCapture()
    }

    public func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .audio)
        self.stream = nil
        handler = nil
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount >= MemoryLayout<Float>.size else { return }
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        handler?(.init(source: .system, startMS: clock.nowMS, sampleRate: 16_000, channels: 1, samples: samples))
    }
}

public actor DualCaptureCoordinator {
    private let microphone: any AudioCaptureSource
    private let system: any AudioCaptureSource

    public init(microphone: any AudioCaptureSource, system: any AudioCaptureSource) {
        self.microphone = microphone
        self.system = system
    }

    public func start(handler: @escaping @Sendable (CapturedAudioChunk) -> Void) async throws {
        try await microphone.start(handler: handler)
        do {
            try await system.start(handler: handler)
        } catch {
            await microphone.stop()
            throw error
        }
    }

    public func stop() async {
        await microphone.stop()
        await system.stop()
    }
}
