import Foundation

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

    public init(
        id: UUID = UUID(),
        severity: DiagnosticSeverity,
        title: String,
        explanation: String,
        recommendation: String
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.explanation = explanation
        self.recommendation = recommendation
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
