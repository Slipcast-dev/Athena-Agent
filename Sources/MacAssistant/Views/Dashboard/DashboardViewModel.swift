import Foundation
import MacAssistantCore

/// ViewModel владеет только состоянием экрана. Получение данных остаётся в
/// сервисе, поэтому интерфейс можно развивать независимо от Mach API.
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var state: FeaturePresentationState = .loading
    @Published private(set) var systemInfo: SystemInfo?
    @Published private(set) var metrics: SystemMetrics?

    private let systemInformation: any SystemInformationProviding

    init(systemInformation: any SystemInformationProviding) {
        self.systemInformation = systemInformation
    }

    /// View.task отменяется SwiftUI при уходе с экрана. Цикл не создаёт
    /// глобальный таймер, поэтому не продолжает ненужный опрос в фоне.
    func refreshWhileVisible() async {
        await refresh()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            await refresh()
        }
    }

    func refresh() async {
        state = .loading
        do {
            async let info = systemInformation.systemInfo()
            async let currentMetrics = systemInformation.systemMetrics()
            systemInfo = try await info
            metrics = try await currentMetrics
            state = .ready
        } catch is CancellationError {
            return
        } catch {
            // В пользовательский интерфейс передаётся только локализованное,
            // безопасное описание: системные пути и секреты не раскрываются.
            state = .error(message: error.localizedDescription)
        }
    }
}
