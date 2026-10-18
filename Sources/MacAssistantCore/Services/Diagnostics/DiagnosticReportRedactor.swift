import Foundation

/// Подготавливает только необходимые показатели для внешнего ИИ и исключает
/// идентификаторы устройства, серийные номера и пользовательские пути.
public enum DiagnosticReportRedactor {
    public static func text(for report: DiagnosticReport) -> String {
        let cpu = report.metrics.cpuUsagePercent.map { String(format: "%.1f%%", $0) } ?? "нет данных"
        let storage = report.metrics.storageUsagePercent.map { String(format: "%.1f%%", $0) } ?? "нет данных"
        let findings = report.findings.map { "- [\($0.severity.rawValue)] \($0.title): \($0.recommendation)" }.joined(separator: "\n")
        return "Диагностический отчёт Athena\nmacOS: \(report.operatingSystemVersion)\nCPU: \(cpu)\nНакопитель: \(storage)\nПредупреждения:\n\(findings)"
    }
}
