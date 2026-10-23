import SwiftUI
import EcosystemLocalization
import EcosystemUI
import MacAssistantCore

struct DashboardView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    @Environment(\.scenePhase) private var scenePhase
    @State private var windowVisible = false
    @StateObject private var viewModel: DashboardViewModel

    init(container: AppContainer) {
        _viewModel = StateObject(
            wrappedValue: DashboardViewModel(systemInformation: container.services.systemInformation)
        )
    }

    var body: some View {
        FeatureScreen(title: l10n.text("Обзор"), state: viewModel.presentedState(language: language)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let info = viewModel.systemInfo, let metrics = viewModel.metrics {
                        SystemIdentityCard(info: info)
                        MetricsGrid(metrics: metrics)
                    } else {
                        ContentUnavailableView(
                            l10n.text("Системные показатели недоступны"),
                            systemImage: "gauge.with.dots.needle.33percent",
                            description: Text(l10n.text("Повторите попытку обновления."))
                        )
                    }
                }
                .padding()
            }
        }
        .toolbar {
            Button(l10n.text("Обновить"), systemImage: "arrow.clockwise") {
                Task { await viewModel.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(l10n.text("Обновить системные показатели"))
        }
        .background(DashboardWindowVisibility { windowVisible = $0 })
        .task(id: scenePhase == .active && windowVisible) {
            guard scenePhase == .active && windowVisible else { return }
            await viewModel.refreshWhileVisible()
        }
    }
}

struct SystemIdentityCard: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    let info: SystemInfo

    var body: some View {
        GroupBox(l10n.text("Этот Mac")) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                MetricRow(title: l10n.text("Модель"), value: info.modelName)
                MetricRow(title: "macOS", value: info.operatingSystemVersion)
                MetricRow(title: l10n.text("Архитектура"), value: info.architecture)
                MetricRow(title: l10n.text("Ядра CPU"), value: l10n.format("%@ физических / %@ логических", info.physicalCPUCoreCount.formatted(), info.logicalCPUCoreCount.formatted()))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MetricsGrid: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    let metrics: SystemMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
            MetricCard(title: l10n.text("Загрузка CPU"), value: AthenaMetricPresentation.cpu(metrics, using: l10n), symbol: "cpu")
            MetricCard(title: l10n.text("Использование RAM"), value: memoryValue, symbol: "memorychip")
            MetricCard(title: l10n.text("Доступно RAM"), value: metrics.availableMemoryBytes.map(bytes) ?? l10n.text("Нет данных"), symbol: "memorychip.fill")
            MetricCard(title: l10n.text("Накопитель"), value: storageValue, symbol: "internaldrive")
        }
        // Используем тот же persisted snapshot/quality, а не новый timer или
        // самостоятельную эвристику «нормы» при отсутствующем измерении.
        Text(AthenaMetricPresentation.freshness(metrics, now: Date(), using: l10n))
            .font(.caption).foregroundStyle(metrics.quality().stale ? Color.orange : Color.secondary)
        }
    }

    private var memoryValue: String {
        guard metrics.quality().memory == .available else { return l10n.text("Измерение недоступно") }
        return l10n.format("%@ из %@", bytes(metrics.usedMemoryBytes), bytes(metrics.totalMemoryBytes))
    }
    private var storageValue: String {
        guard metrics.quality().storage == .available else { return l10n.text("Измерение недоступно") }
        return l10n.format("%@ · свободно %@", metrics.storageUsagePercent.map(percent) ?? l10n.text("Нет данных"), bytes(metrics.availableStorageBytes))
    }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
    private func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) + " %" }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).foregroundStyle(.secondary)
                Text(value).font(.title3).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String

    var body: some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
