import SwiftUI
import MacAssistantCore

struct DashboardView: View {
    @StateObject private var viewModel: DashboardViewModel

    init(container: AppContainer) {
        _viewModel = StateObject(
            wrappedValue: DashboardViewModel(systemInformation: container.services.systemInformation)
        )
    }

    var body: some View {
        FeatureScreen(title: "Обзор", state: viewModel.state) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let info = viewModel.systemInfo, let metrics = viewModel.metrics {
                        SystemIdentityCard(info: info)
                        MetricsGrid(metrics: metrics)
                    } else {
                        ContentUnavailableView(
                            "Системные показатели недоступны",
                            systemImage: "gauge.with.dots.needle.33percent",
                            description: Text("Повторите попытку обновления.")
                        )
                    }
                }
                .padding()
            }
        }
        .toolbar {
            Button("Обновить", systemImage: "arrow.clockwise") {
                Task { await viewModel.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Обновить системные показатели")
        }
        .task { await viewModel.refreshWhileVisible() }
    }
}

private struct SystemIdentityCard: View {
    let info: SystemInfo

    var body: some View {
        GroupBox("Этот Mac") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                MetricRow(title: "Модель", value: info.modelName)
                MetricRow(title: "macOS", value: info.operatingSystemVersion)
                MetricRow(title: "Архитектура", value: info.architecture)
                MetricRow(title: "Ядра CPU", value: "\(info.physicalCPUCoreCount) физических / \(info.logicalCPUCoreCount) логических")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MetricsGrid: View {
    let metrics: SystemMetrics

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
            MetricCard(title: "Загрузка CPU", value: metrics.cpuUsagePercent.map(percent) ?? "Измерение…", symbol: "cpu")
            MetricCard(title: "Использование RAM", value: memoryValue, symbol: "memorychip")
            MetricCard(title: "Доступно RAM", value: metrics.availableMemoryBytes.map(bytes) ?? "Нет данных", symbol: "memorychip.fill")
            MetricCard(title: "Накопитель", value: storageValue, symbol: "internaldrive")
        }
    }

    private var memoryValue: String { "\(bytes(metrics.usedMemoryBytes)) из \(bytes(metrics.totalMemoryBytes))" }
    private var storageValue: String {
        "\(metrics.storageUsagePercent.map(percent) ?? "Нет данных") · свободно \(bytes(metrics.availableStorageBytes))"
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
