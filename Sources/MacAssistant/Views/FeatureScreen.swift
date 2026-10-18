import SwiftUI

/// Повторно используемый каркас раздела для загрузки, ошибок и пустого состояния.
/// Конкретные ViewModel будут менять это состояние только после появления сервисов.
struct FeatureScreen<Content: View>: View {
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
                    ProgressView()
                    Text("Загрузка…")
                        .foregroundStyle(.secondary)
                }
            case let .error(message):
                ContentUnavailableView(
                    "Не удалось загрузить данные",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .navigationTitle(title)
    }
}
