import EcosystemContracts
import EcosystemLocalIPC

/// Общая версия отделена от старых DB AgentTask моделей; их миграция — E3–E5.
public enum AthenaEcosystem {
    public static let descriptor = EcosystemDescriptor(agentID: .athena)
    public static var experimentalCapability: [String: Any] {
        var value = descriptor.experimentalCapability
        let configured = (try? LocalRuntimeConfiguration.environment(domain: "athena")) != nil
        value["runtimeIntegrated"] = configured
        if configured { value["runtimeMode"] = "local-ad-hoc" }
        return value
    }
}
