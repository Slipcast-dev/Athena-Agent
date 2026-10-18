import Foundation

/// Сетевой адаптер поддерживает подтверждённый контракт OpenAI-compatible APIs
/// (OpenAI, OpenRouter, DeepSeek и совместимые серверы) и отдельный локальный Ollama.
public struct NetworkAIProvider: AIStreamingProviding {
    private let manager: AIProviderManager
    private let session: URLSession

    public init(manager: AIProviderManager, session: URLSession = .shared) {
        self.manager = manager
        self.session = session
    }

    public func availableModels(for profile: AIProviderProfile) async throws -> [AIModel] {
        try AIEndpointValidator.validate(profile)
        var request = try await request(for: profile, path: profile.kind == .ollama ? "tags" : "models")
        request.httpMethod = "GET"
        let (data, _) = try await perform(request)
        if profile.kind == .ollama {
            let decoded = try JSONDecoder().decode(OllamaModelsResponse.self, from: data)
            return decoded.models.map { AIModel(id: $0.name, displayName: $0.name, supportsStreaming: true) }
        }
        return try JSONDecoder().decode(OpenAIModelsResponse.self, from: data).data.map { AIModel(id: $0.id, displayName: $0.id, supportsStreaming: true) }
    }

    public func send(messages: [ChatMessage], using profile: AIProviderProfile, modelID: String) async throws -> ChatMessage {
        try AIEndpointValidator.validate(profile)
        if profile.kind == .ollama { return try await sendOllama(messages: messages, profile: profile, modelID: modelID) }
        var request = try await request(for: profile, path: "chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OpenAIChatRequest(model: modelID, messages: messages.map(OpenAIChatMessage.init)))
        let (data, _) = try await perform(request)
        guard let content = try JSONDecoder().decode(OpenAIChatResponse.self, from: data).choices.first?.message.content else { throw AIProviderError.invalidResponse }
        return ChatMessage(role: .assistant, content: content)
    }

    public func stream(messages: [ChatMessage], using profile: AIProviderProfile, modelID: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Проверяем endpoint до чтения ключа, в том числе для
                    // профилей, восстановленных из старого хранилища.
                    try AIEndpointValidator.validate(profile)
                    guard profile.kind != .ollama else { throw AIProviderError.invalidResponse }
                    var request = try await request(for: profile, path: "chat/completions")
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(OpenAIStreamingRequest(model: modelID, messages: messages.map(OpenAIChatMessage.init), stream: true))
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw AIProviderError.invalidResponse }
                    var decoder = OpenAIStreamDecoder()
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let delta = try decoder.consume(value), !delta.isEmpty { continuation.yield(delta) }
                        if value == "[DONE]" { break }
                    }
                    try Task.checkCancellation()
                    try decoder.validateCompletion()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func sendOllama(messages: [ChatMessage], profile: AIProviderProfile, modelID: String) async throws -> ChatMessage {
        var request = try await request(for: profile, path: "chat")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaChatRequest(model: modelID, messages: messages.map(OpenAIChatMessage.init), stream: false))
        let (data, _) = try await perform(request)
        return ChatMessage(role: .assistant, content: try JSONDecoder().decode(OllamaChatResponse.self, from: data).message.content)
    }

    private func request(for profile: AIProviderProfile, path: String) async throws -> URLRequest {
        var url = profile.baseURL
        url.appendPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: 45)
        if profile.kind != .ollama {
            guard let key = try await manager.apiKey(for: profile), !key.isEmpty else { throw AIProviderError.missingAPIKey }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
            switch http.statusCode {
            case 200 ... 299: return (data, http)
            case 401, 403: throw AIProviderError.unauthorized
            case 429: throw AIProviderError.rateLimited
            case 500 ... 599: throw AIProviderError.server(status: http.statusCode)
            default: throw AIProviderError.invalidResponse
            }
        } catch let error as AIProviderError { throw error }
        catch { throw AIProviderError.network }
    }
}

private struct OpenAIModelsResponse: Decodable { let data: [OpenAIModel] }
private struct OpenAIModel: Decodable { let id: String }
private struct OllamaModelsResponse: Decodable { let models: [OllamaModel] }
private struct OllamaModel: Decodable { let name: String }
private struct OpenAIChatRequest: Encodable { let model: String; let messages: [OpenAIChatMessage] }
private struct OpenAIStreamingRequest: Encodable { let model: String; let messages: [OpenAIChatMessage]; let stream: Bool }
private struct OllamaChatRequest: Encodable { let model: String; let messages: [OpenAIChatMessage]; let stream: Bool }
private struct OpenAIChatResponse: Decodable { let choices: [OpenAIChoice] }
private struct OpenAIChoice: Decodable { let message: OpenAIChatMessage }
private struct OllamaChatResponse: Decodable { let message: OpenAIChatMessage }
private struct OpenAIChatMessage: Codable {
    let role: ChatMessageRole
    let content: String
    init(_ message: ChatMessage) { role = message.role; content = message.content }
}
