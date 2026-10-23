import Foundation
import EcosystemLocalization

public struct DiagnosticReport: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let applicationVersion: String
    public let operatingSystemVersion: String
    public let metrics: SystemMetrics
    public let findings: [DiagnosticFinding]
    public let status: DiagnosticReportStatus

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        applicationVersion: String,
        operatingSystemVersion: String,
        metrics: SystemMetrics,
        findings: [DiagnosticFinding],
        status: DiagnosticReportStatus
    ) {
        self.id = id
        self.createdAt = createdAt
        self.applicationVersion = applicationVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.metrics = metrics
        self.findings = findings
        self.status = status
    }
}

public struct DiagnosticFinding: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let severity: DiagnosticSeverity
    public let title: String
    public let explanation: String
    public let recommendation: String
    /// Необязательные подсказки представления: legacy readers игнорируют поля,
    /// а неизвестный код/версия всегда оставляет три исходные строки без догадок.
    public let presentationCode: String?
    public let presentationVersion: Int?

    public init(
        id: UUID = UUID(),
        severity: DiagnosticSeverity,
        title: String,
        explanation: String,
        recommendation: String,
        presentationCode: String? = nil,
        presentationVersion: Int? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.explanation = explanation
        self.recommendation = recommendation
        self.presentationCode = presentationCode
        self.presentationVersion = presentationVersion
    }
}

public enum DiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case critical
}

public enum DiagnosticReportStatus: String, Codable, CaseIterable, Sendable {
    case completed
    case partial
    case failed
}

/// Код описывает семантику новой записи, не заменяя UUID или сохранённый текст.
/// Пороговые вычисления остаются в фабрике; UI не вычисляет диагноз повторно.
public enum DiagnosticPresentationCode: String, CaseIterable, Sendable {
    case storageWarning, storageCritical, cpuWarning, cpuCritical
    case memoryWarning, memoryCritical, noCriticalSigns

    public var severity: DiagnosticSeverity {
        switch self {
        case .storageWarning, .cpuWarning, .memoryWarning: .warning
        case .storageCritical, .cpuCritical, .memoryCritical: .critical
        case .noCriticalSigns: .info
        }
    }
}

public extension DiagnosticFinding {
    var recognizedPresentationCode: DiagnosticPresentationCode? {
        guard presentationVersion == 1, let presentationCode,
              let code = DiagnosticPresentationCode(rawValue: presentationCode),
              code.severity == severity else { return nil }
        return code
    }

    /// Возвращается только временная копия для явного языка потребителя.
    /// История, UUID, severity и metadata исходной записи не переписываются.
    func localized(using localization: AgentLocalization) -> DiagnosticFinding {
        guard let code = recognizedPresentationCode else { return self }
        let prefix = "athena.finding." + code.rawValue
        return DiagnosticFinding(id: id, severity: severity,
            title: localization.runtimeText(prefix + ".title"),
            explanation: localization.runtimeText(prefix + ".explanation"),
            recommendation: localization.runtimeText(prefix + ".recommendation"),
            presentationCode: presentationCode, presentationVersion: presentationVersion)
    }
}
