import Foundation

/// Настраиваемые и документированные пороги. Они не изменяют системные данные,
/// а только классифицируют уже собранные показатели для рекомендаций.
public struct DiagnosticThresholds: Equatable, Sendable {
    public let storageWarningPercent: Double
    public let storageCriticalPercent: Double
    public let cpuWarningPercent: Double
    public let cpuCriticalPercent: Double

    public init(
        storageWarningPercent: Double = 80,
        storageCriticalPercent: Double = 90,
        cpuWarningPercent: Double = 80,
        cpuCriticalPercent: Double = 95
    ) {
        self.storageWarningPercent = storageWarningPercent
        self.storageCriticalPercent = storageCriticalPercent
        self.cpuWarningPercent = cpuWarningPercent
        self.cpuCriticalPercent = cpuCriticalPercent
    }
}

/// Правила отчёта не зависят от источника метрик, поэтому тестируются отдельно.
public enum DiagnosticFindingFactory {
    public static func makeFindings(for metrics: SystemMetrics, thresholds: DiagnosticThresholds) -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        if let storageUsage = metrics.storageUsagePercent {
            if storageUsage >= thresholds.storageCriticalPercent {
                findings.append(storageFinding(severity: .critical))
            } else if storageUsage >= thresholds.storageWarningPercent {
                findings.append(storageFinding(severity: .warning))
            }
        }
        if let cpuUsage = metrics.cpuUsagePercent {
            if cpuUsage >= thresholds.cpuCriticalPercent {
                findings.append(cpuFinding(severity: .critical))
            } else if cpuUsage >= thresholds.cpuWarningPercent {
                findings.append(cpuFinding(severity: .warning))
            }
        }
        if metrics.memoryPressure == .warning {
            findings.append(DiagnosticFinding(severity: .warning, title: "Повышенное давление памяти", explanation: "macOS сообщает о давлении памяти.", recommendation: "Проверьте ресурсоёмкие приложения и повторите измерение."))
        }
        if metrics.memoryPressure == .critical {
            findings.append(DiagnosticFinding(severity: .critical, title: "Высокое давление памяти", explanation: "macOS сообщает о критическом давлении памяти.", recommendation: "Закройте ненужные ресурсоёмкие приложения и повторите проверку."))
        }
        if findings.isEmpty {
            findings.append(DiagnosticFinding(severity: .info, title: "Критичных признаков не обнаружено", explanation: "По доступным показателям пороги не превышены; недоступные измерения не подтверждают норму.", recommendation: "Продолжайте периодически проверять состояние Mac."))
        }
        return findings
    }

    private static func storageFinding(severity: DiagnosticSeverity) -> DiagnosticFinding {
        DiagnosticFinding(severity: severity, title: severity == .critical ? "Критически мало места на накопителе" : "Мало места на накопителе", explanation: "Заполнение системного накопителя превысило порог диагностики.", recommendation: "Просмотрите крупные файлы и освободите место без автоматического удаления данных.")
    }

    private static func cpuFinding(severity: DiagnosticSeverity) -> DiagnosticFinding {
        DiagnosticFinding(severity: severity, title: severity == .critical ? "Критически высокая загрузка CPU" : "Высокая загрузка CPU", explanation: "Нагрузка рассчитана по разнице последовательных системных снимков CPU.", recommendation: "Повторите измерение через несколько минут и проверьте активные приложения.")
    }
}

public actor SystemDiagnosticsService: SystemDiagnosing {
    private let systemInformation: any SystemInformationProviding
    private let applicationVersion: String
    private let thresholds: DiagnosticThresholds

    public init(systemInformation: any SystemInformationProviding, applicationVersion: String = "0.1.5", thresholds: DiagnosticThresholds = .init()) {
        self.systemInformation = systemInformation
        self.applicationVersion = applicationVersion
        self.thresholds = thresholds
    }

    public func runDiagnostics() async throws -> DiagnosticReport {
        try Task.checkCancellation()
        let info: SystemInfo?
        do { info = try await systemInformation.systemInfo() } catch is CancellationError { throw CancellationError() } catch { info = nil }
        var metrics = try await systemInformation.systemMetrics()
        // Первый снимок CPU не имеет базовой точки. Короткая асинхронная пауза
        // создаёт второе измерение и не блокирует интерфейс приложения.
        if metrics.cpuUsagePercent == nil {
            try await Task.sleep(for: .milliseconds(250))
            metrics = try await systemInformation.systemMetrics()
        }
        return DiagnosticReport(
            applicationVersion: applicationVersion,
            operatingSystemVersion: info?.operatingSystemVersion ?? "unavailable",
            metrics: metrics,
            findings: DiagnosticFindingFactory.makeFindings(for: metrics, thresholds: thresholds),
            status: info != nil && metrics.quality().complete && !metrics.quality().stale ? .completed : .partial
        )
    }
}
