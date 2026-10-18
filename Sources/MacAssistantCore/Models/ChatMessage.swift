import Foundation

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let role: ChatMessageRole
    public let content: String
    public let createdAt: Date

    public init(id: UUID = UUID(), role: ChatMessageRole, content: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public enum ChatMessageRole: String, Codable, CaseIterable, Sendable {
    case system
    case user
    case assistant
}
