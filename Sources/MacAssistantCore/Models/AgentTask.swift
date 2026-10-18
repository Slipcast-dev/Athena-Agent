import Foundation

public struct AgentTask: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let command: String
    public let startedAt: Date
    public var status: AgentTaskStatus

    public init(id: UUID = UUID(), command: String, startedAt: Date = .now, status: AgentTaskStatus) {
        self.id = id
        self.command = command
        self.startedAt = startedAt
        self.status = status
    }
}

public enum AgentTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case completed
    case cancelled
    case failed
    case cancelling, interrupted, recoveryRequired, partial
}
