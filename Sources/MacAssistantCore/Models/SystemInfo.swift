import Foundation

/// Неизменяемый снимок сведений о компьютере, безопасный для показа в интерфейсе.
/// Серийный номер намеренно отсутствует: он не нужен для диагностики и является
/// персональным идентификатором устройства.
public struct SystemInfo: Codable, Equatable, Sendable {
    public let modelName: String
    public let operatingSystemVersion: String
    public let architecture: String
    public let physicalCPUCoreCount: Int
    public let logicalCPUCoreCount: Int

    public init(
        modelName: String,
        operatingSystemVersion: String,
        architecture: String,
        physicalCPUCoreCount: Int,
        logicalCPUCoreCount: Int
    ) {
        self.modelName = modelName
        self.operatingSystemVersion = operatingSystemVersion
        self.architecture = architecture
        self.physicalCPUCoreCount = physicalCPUCoreCount
        self.logicalCPUCoreCount = logicalCPUCoreCount
    }
}
