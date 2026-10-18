import Foundation

/// Состояние, единообразно отображаемое во всех разделах. Оно не хранит
/// технические ошибки целиком, чтобы случайно не показать пользователю секреты.
enum FeaturePresentationState: Equatable {
    case ready
    case loading
    case error(message: String)
}
