import SwiftUI
import MacAssistantCore
import EcosystemLocalIPC

struct DiagnosticsView: View {
    @StateObject private var viewModel: DiagnosticsViewModel
    private let local: Result<LocalRPCClient, Error>?
    @State private var tab = 0

    init(container: AppContainer) {
        local = container.services.localRuntimeClient
        _viewModel = StateObject(wrappedValue: DiagnosticsViewModel(diagnostics: container.services.diagnostics))
    }

    var body: some View {
        FeatureScreen(title: "Диагностика", state: viewModel.state) {
            VStack {
                if local != nil {
                    Picker("Раздел диагностики", selection: $tab) { Text("Отчёт").tag(0); Text("Мониторинг").tag(1) }.pickerStyle(.segmented)
                }
                if tab == 1 { MonitorPanel(client: local) }
                else { Group {
                if let report = viewModel.report {
                    List {
                        Text(report.status == .partial ? "Часть измерений недоступна или подготавливается" : "Измерения собраны").foregroundStyle(.secondary)
                        ForEach(report.findings) { finding in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(finding.title, systemImage: symbol(for: finding.severity))
                                .foregroundStyle(color(for: finding.severity))
                            Text(finding.explanation)
                            Text(finding.recommendation).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        }
                    }
                    .accessibilityLabel("Результаты диагностики")
                } else {
                    ContentUnavailableView(
                        "Диагностика ещё не запускалась",
                        systemImage: "stethoscope",
                        description: Text("Собираются только локальные системные показатели без прав администратора.")
                    )
                }
                } }
            }
        }
        .toolbar {
            Button("Запустить диагностику", systemImage: "play.fill") {
                Task { await viewModel.run() }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help("Запустить локальную системную диагностику")
            Button("Отменить диагностику") { viewModel.cancel() }.disabled(!viewModel.isRunning)
        }
    }

    private func symbol(for severity: DiagnosticSeverity) -> String {
        switch severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .critical: "xmark.octagon"
        }
    }

    private func color(for severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .info: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }
}
