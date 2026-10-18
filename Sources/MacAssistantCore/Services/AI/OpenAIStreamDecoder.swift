import Foundation

/// Служебные role/usage-кадры допустимы, но повреждённый JSON и неожиданный
/// EOF должны стать ошибкой, чтобы UI сохранил частичный ответ и кнопку повтора.
struct OpenAIStreamDecoder {
    private(set) var completed = false

    mutating func consume(_ data: String) throws -> String? {
        if data == "[DONE]" {
            completed = true
            return nil
        }
        let frame: Frame
        do { frame = try JSONDecoder().decode(Frame.self, from: Data(data.utf8)) }
        catch { throw AIProviderError.invalidResponse }
        guard !frame.choices.isEmpty || frame.usage != nil else { throw AIProviderError.invalidResponse }
        // finish_reason — альтернативное явное подтверждение конца ответа.
        // Это поддерживает совместимые API, которые завершают поток без [DONE].
        if frame.choices.contains(where: { $0.finish_reason != nil }) { completed = true }
        return frame.choices.first?.delta.content
    }

    func validateCompletion() throws {
        guard completed else { throw AIProviderError.invalidResponse }
    }

    private struct Frame: Decodable {
        let choices: [Choice]
        let usage: Usage?
    }
    private struct Choice: Decodable {
        let delta: Delta
        let finish_reason: String?
    }
    private struct Delta: Decodable { let content: String? }
    private struct Usage: Decodable { }
}
