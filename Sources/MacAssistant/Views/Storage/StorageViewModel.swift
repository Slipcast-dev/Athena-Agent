import AppKit
import Foundation
import EcosystemLocalization
import MacAssistantCore

@MainActor
final class StorageViewModel: ObservableObject {
    @Published private(set) var state: FeaturePresentationState = .ready
    @Published private(set) var runtimeError: RuntimeMessage?
    @Published private(set) var items: [StorageItem] = []
    @Published private(set) var selectedDirectory: URL?
    func presentedState(language: AgentLanguage) -> FeaturePresentationState {
        guard let runtimeError else { return state }
        return .error(message: AgentLocalization(language: language).runtimeMessage(runtimeError))
    }

    private let storage: any StorageAnalyzing
    private var scanID = UUID()
    private var scanTask: Task<Void, Never>?

    init(storage: any StorageAnalyzing) { self.storage = storage }
    deinit { scanTask?.cancel() }

    func chooseAndScanDirectory(language: AgentLanguage) {
        let l10n = AthenaLocalization(language: language)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = l10n.text("Анализировать")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startScan(directory: url)
    }

    func startScan(directory: URL) {
        scanTask?.cancel()
        let id = UUID(); scanID = id
        selectedDirectory = directory
        runtimeError = nil
        state = .loading
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await storage.scanDirectory(at: directory, minimumSizeBytes: 100 * 1_024 * 1_024)
                guard !Task.isCancelled, scanID == id else { return }
                items = results
                state = .ready
            } catch is CancellationError {
                guard scanID == id else { return }
                state = .ready
            } catch {
                guard scanID == id else { return }
                runtimeError = .capture(error)
                state = .error(message: error.localizedDescription)
            }
        }
    }

    func cancel() { scanTask?.cancel() }
}
