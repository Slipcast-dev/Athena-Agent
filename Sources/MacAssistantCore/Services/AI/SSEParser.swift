import Foundation

/// Буферизованный SSE-разборщик: сетевые чанки могут закончиться в середине строки,
/// поэтому событие выдаётся только после пустой строки-разделителя.
public struct SSEParser: Sendable {
    private var buffer = ""
    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        buffer += String(decoding: data, as: UTF8.self)
        var events: [String] = []
        while let range = buffer.range(of: "\n\n") {
            let frame = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            for line in frame.split(separator: "\n") where line.hasPrefix("data:") {
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if value != "[DONE]" { events.append(value) }
            }
        }
        return events
    }
}
