import SwiftUI
import MacAssistantCore
import EcosystemLocalIPC
import EcosystemLocalization

struct DiagnosticsView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    private var runtimeL10n: AgentLocalization { AgentLocalization(language: language) }
    private var presentationState: FeaturePresentationState {
        if let error = viewModel.runtimeError { return .error(message: runtimeL10n.runtimeMessage(error)) }
        return viewModel.state
    }
    @StateObject private var viewModel: DiagnosticsViewModel
    private let local: Result<LocalRPCClient, Error>?
    @State private var tab = 0

    init(container: AppContainer) {
        local = container.services.localRuntimeClient
        _viewModel = StateObject(wrappedValue: DiagnosticsViewModel(diagnostics: container.services.diagnostics))
    }

    /// Тесты передают изолированную модель без bootstrap личного runtime.
    init(viewModel: DiagnosticsViewModel, local: Result<LocalRPCClient, Error>? = nil) {
        self.local = local
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        FeatureScreen(title: l10n.text("Диагностика"), state: presentationState) {
            VStack {
                if local != nil {
                    Picker(l10n.text("Раздел диагностики"), selection: $tab) { Text(l10n.text("Отчёт")).tag(0); Text(l10n.text("Мониторинг")).tag(1) }.pickerStyle(.segmented)
                }
                if tab == 1 { MonitorPanel(client: local) }
                else { Group {
                if let report = viewModel.report {
                    List {
                        Text(l10n.text(report.status == .partial ? "Часть измерений недоступна или подготавливается" : "Измерения собраны")).foregroundStyle(.secondary)
                        // Legacy/неизвестные коды не угадываем по сохранённому тексту.
                        if report.findings.contains(where: { $0.recognizedPresentationCode == nil }) {
                            Text(l10n.text("Текст сохранённого отчёта показан на исходном языке.")).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(report.findings) { original in
                        let finding = original.localized(using: runtimeL10n)
                        VStack(alignment: .leading, spacing: 6) {
                            Label(finding.title, systemImage: symbol(for: finding.severity))
                                .foregroundStyle(color(for: finding.severity))
                            Text(finding.explanation)
                            Text(finding.recommendation).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        }
                    }
                    .accessibilityLabel(l10n.text("Результаты диагностики"))
                } else {
                    ContentUnavailableView(
                        l10n.text("Диагностика ещё не запускалась"),
                        systemImage: "stethoscope",
                        description: Text(l10n.text("Собираются только локальные системные показатели без прав администратора."))
                    )
                }
                } }
            }
        }
        .toolbar {
            Button(l10n.text("Запустить диагностику"), systemImage: "play.fill") {
                Task { await viewModel.run() }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help(l10n.text("Запустить локальную системную диагностику"))
            Button(l10n.text("Отменить диагностику")) { viewModel.cancel() }.disabled(!viewModel.isRunning)
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
