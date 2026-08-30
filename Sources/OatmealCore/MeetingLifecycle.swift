import Foundation

public struct MeetingLifecycle: Equatable, Sendable {
    public enum LifecycleError: LocalizedError, Equatable, Sendable {
        case invalidTransition(from: MeetingStatus, to: MeetingStatus)

        public var errorDescription: String? {
            switch self {
            case let .invalidTransition(from, to):
                "Cannot move a meeting from \(from.rawValue) to \(to.rawValue)."
            }
        }
    }

    public private(set) var status: MeetingStatus

    public init(status: MeetingStatus = .idle) {
        self.status = status
    }

    public mutating func transition(to next: MeetingStatus) throws {
        guard Self.allowed[status, default: []].contains(next) else {
            throw LifecycleError.invalidTransition(from: status, to: next)
        }
        status = next
    }

    private static let allowed: [MeetingStatus: Set<MeetingStatus>] = [
        .idle: [.starting],
        .starting: [.capturing, .failed, .idle],
        .capturing: [.degraded, .stopping, .failed],
        .degraded: [.capturing, .stopping, .failed],
        .stopping: [.finalizing, .degraded, .failed],
        .finalizing: [.completed, .degraded, .failed],
        .completed: [],
        .failed: [.stopping, .completed, .idle],
    ]
}
