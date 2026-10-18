import Foundation

public actor ChatHistoryStore {
    private let defaults: UserDefaults
    private let key = "chatConversations"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> [ChatConversation] { (try? defaults.data(forKey: key).map { try JSONDecoder().decode([ChatConversation].self, from: $0) }) ?? [] }
    public func save(_ conversations: [ChatConversation]) throws { defaults.set(try JSONEncoder().encode(conversations), forKey: key) }

    /// Actor делает обновление по ID атомарным относительно других сохранений.
    public func upsert(_ conversation: ChatConversation) throws {
        // Повреждённую историю нельзя трактовать как пустую при записи:
        // ошибка декодирования должна остановить сохранение, сохранив оригинал.
        var conversations: [ChatConversation] = []
        if let data = defaults.data(forKey: key) {
            conversations = try JSONDecoder().decode([ChatConversation].self, from: data)
        }
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
        try save(conversations.sorted { $0.updatedAt > $1.updatedAt })
    }
}
