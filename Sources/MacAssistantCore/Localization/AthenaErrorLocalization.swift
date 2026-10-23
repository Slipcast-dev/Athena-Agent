import Foundation
import EcosystemLocalization

// Сопоставление только конечных typed cases. Свободные детали остаются literal
// аргументами: их не ищем в каталоге и не сериализуем обратно в историю.
extension ServiceError: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .unavailableFeature(let feature):
            RuntimeMessage("athena.error.service.unavailable", messages: [RuntimeMessage("athena.service.feature." + feature.rawValue)])
        case .invalidOperation(let reason):
            RuntimeMessage("athena.error.service.invalidInput", messages: [RuntimeMessage("athena.service.reason." + reason.rawValue)])
        case .unavailable(let feature): RuntimeMessage("athena.error.service.unavailable", args: [feature])
        case .invalidInput(let reason): RuntimeMessage("athena.error.service.invalidInput", args: [reason])
        }
    }
}
extension SystemServiceError: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .sysctlFailed(let name, _): RuntimeMessage("athena.error.system.sysctlFailed", args: [name])
        case .machCallFailed: RuntimeMessage("athena.error.system.machCallFailed")
        case .missingSystemValue(let value):
            RuntimeMessage("athena.error.system.missingValue", messages: [RuntimeMessage("athena.system.value." + value.rawValue)])
        case .missingValue(let name): RuntimeMessage("athena.error.system.missingValue", args: [name])
        }
    }
}
extension StorageAnalysisError: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .invalidDirectory: RuntimeMessage("athena.error.storage.invalidDirectory")
        case .cannotEnumerateDirectory: RuntimeMessage("athena.error.storage.cannotEnumerateDirectory")
        case .volumeInformationUnavailable: RuntimeMessage("athena.error.storage.volumeInformationUnavailable")
        }
    }
}
extension MCPConnectionError: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .codexRegistrationFailed:
            // stderr внешнего CLI может содержать личные пути или секреты.
            return RuntimeMessage("athena.error.mcp.codexRegistrationFailed")
        }
    }
}
extension AIProviderError: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .invalidEndpoint: RuntimeMessage("athena.error.ai.invalidEndpoint")
        case .insecureEndpoint: RuntimeMessage("athena.error.ai.insecureEndpoint")
        case .insecureLocalEndpoint: RuntimeMessage("athena.error.ai.insecureLocalEndpoint")
        case .secretStorageFailed: RuntimeMessage("athena.error.ai.secretStorageFailed")
        case .missingAPIKey: RuntimeMessage("athena.error.ai.missingAPIKey")
        case .unauthorized: RuntimeMessage("athena.error.ai.unauthorized")
        case .rateLimited: RuntimeMessage("athena.error.ai.rateLimited")
        case .server: RuntimeMessage("athena.error.ai.server")
        case .invalidResponse: RuntimeMessage("athena.error.ai.invalidResponse")
        case .network: RuntimeMessage("athena.error.ai.network")
        }
    }
}
