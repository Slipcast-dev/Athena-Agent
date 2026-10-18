import Foundation

public struct ChatConversation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var updatedAt: Date
    /// Контекст незавершённого запроса позволяет повторить его после перезапуска.
    /// Optional сохраняет совместимость с ранее записанными JSON-диалогами.
    public var retryMessages: [ChatMessage]?
    public init(id: UUID = UUID(), title: String, messages: [ChatMessage] = [], updatedAt: Date = .now) {
        self.id = id; self.title = title; self.messages = messages; self.updatedAt = updatedAt
        self.retryMessages = nil
    }
}
