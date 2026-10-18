import Foundation

/// Элемент результатов сканирования. URL остаётся локальным и не должен
/// автоматически включаться в отчёт, отправляемый внешнему ИИ.
public struct StorageItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let sizeBytes: UInt64
    public let modifiedAt: Date?
    public let isDirectory: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        sizeBytes: UInt64,
        modifiedAt: Date?,
        isDirectory: Bool
    ) {
        self.id = id
        self.url = url
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
    }
}

public struct StorageOverview: Codable, Equatable, Sendable {
    public let capturedAt: Date?
    public let totalBytes: UInt64
    public let availableBytes: UInt64

    public init(totalBytes: UInt64, availableBytes: UInt64, capturedAt: Date = Date()) {
        self.capturedAt = capturedAt
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}
