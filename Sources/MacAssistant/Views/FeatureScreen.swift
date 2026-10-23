import SwiftUI
import EcosystemLocalization
import EcosystemUI

/// Повторно используемый каркас раздела для загрузки, ошибок и пустого состояния.
/// Конкретные ViewModel будут менять это состояние только после появления сервисов.
struct FeatureScreen<Content: View>: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    let title: String
    let state: FeaturePresentationState
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            switch state {
            case .ready:
                content()
            case .loading:
                VStack(spacing: 12) {
                    // Одна нативная подпись связывает состояние с индикатором,
                    // не заставляя VoiceOver читать соседнюю строку второй раз.
                    ProgressView(l10n.text("Загрузка…"))
                }
            case let .error(message):
                ContentUnavailableView(
                    l10n.text("Не удалось загрузить данные"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .navigationTitle(title)
    }
}
