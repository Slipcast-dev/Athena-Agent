import Foundation
import EcosystemLocalization
import MacAssistantCore

/// Статические сведения читаются один раз при открытии настроек; секундный
/// sampler остаётся единственным источником динамических показателей.
@MainActor
final class SystemIdentityViewModel: ObservableObject {
    @Published private(set) var info: SystemInfo?
    @Published private(set) var loading = false
    @Published private(set) var error: RuntimeMessage?
    private let source: (any SystemInformationProviding)?
    init(systemInformation: (any SystemInformationProviding)? = nil) { source = systemInformation }

    func load(force: Bool = false) async {
        guard !Task.isCancelled, !loading, (force || info == nil), let source else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let value = try await source.systemInfo()
            try Task.checkCancellation()
            info = value
        } catch is CancellationError { }
        catch { self.error = .capture(error) }
    }
}
