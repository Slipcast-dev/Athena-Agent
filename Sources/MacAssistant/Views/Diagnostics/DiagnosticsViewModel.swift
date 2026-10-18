import Foundation
import MacAssistantCore

/// Состояние запуска диагностики изолировано от представления и от конкретного
/// источника отчёта, поэтому сервис можно заменить тестовой реализацией.
@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published private(set) var state: FeaturePresentationState = .ready
    @Published private(set) var isRunning = false
    private var operation: Task<DiagnosticReport, Error>?
    @Published private(set) var report: DiagnosticReport?
    private let diagnostics: any SystemDiagnosing

    init(diagnostics: any SystemDiagnosing) {
        self.diagnostics = diagnostics
    }

    func cancel() { operation?.cancel() }

    func run() async {
        guard !isRunning else { return }
        state = .loading; isRunning = true
        let task = Task { try await diagnostics.runDiagnostics() }; operation = task
        defer { operation = nil; isRunning = false }
        do {
            report = try await task.value
            state = .ready
        } catch is CancellationError {
            state = .ready
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }
}
