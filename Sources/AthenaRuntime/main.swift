import AppKit
import Darwin
import Foundation
import MacAssistantCore
import EcosystemRuntimeSupport
import EcosystemLocalIPC

@main struct AthenaRuntime {
    static func main() {
        do {
            if try LocalRuntimeCLI.clientIfRequested(domain: "athena") { return }
            umask(0o077)
            let file = try LocalRuntimeCLI.configurationFile()
            let config = try LocalRuntimeConfiguration.load(file, domain: "athena")
            let state = file.deletingLastPathComponent().appendingPathComponent("athena-state", isDirectory: true)
            let queue = try DurableTaskQueue(directory: state.appendingPathComponent("queue"), agentID: .athena, fault: try LocalRuntimeCLI.faultForSyntheticProfile(file))
            let grants = try AthenaLocalGrants(directory: state)
            let system = SystemInformationService()
            let policy = try LocalAccessPolicy(directory: state, domain: "athena")
            let work = try AthenaQueuedWork(queue: queue, grants: grants, system: system,
                diagnostics: SystemDiagnosticsService(systemInformation: system), storage: StorageAnalysisService(), monitors: MonitorStore(directory: state), monitorSystem: SystemInformationService(), policy: policy)
            let automation = try LocalAutomationService(directory: state, domain: "athena")
            let history = try LocalMCPHistory(directory: state, domain: "athena", queue: queue, policy: policy,
                inbox: automation.inbox, authorizeTask: { id, client in
                    try await work.task(id, role: .mcp, clientID: client, includeResult: false)
                })
            let service = AthenaRuntimeService(work: work, grants: grants, automation: automation, login: LocalLoginRegistration(profile: file.deletingLastPathComponent(), domain: "athena"), history: history)
            let server = try LocalRPCServer(configuration: config, identifiedHandler: { role, client, request in try await service.handle(role: role, clientID: client, request: request) })
            let termination = LocalRuntimeTermination.install { await work.shutdown() }
            if Bundle.main.bundleURL.pathExtension == "app" { NSApplication.shared.setActivationPolicy(.accessory) }
            let workspace = LocalWakeObserver { Task { await service.tick() } }
            withExtendedLifetime((workspace, termination, queue, grants, work, service, server)) {
                server.resume()
                Task {
                    try? await work.resume()
                    while !Task.isCancelled {
                        // Один таймер на владельца домена; пропущенные интервалы
                        // не догоняются пачкой. Store проверяет due по каждой настройке.
                        await service.tick()
                        do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    }
                }
                RunLoop.main.run()
            }
        } catch QueueFailure.ownerBusy { fputs("LOCAL_RUNTIME_OWNER_BUSY\n", stderr); exit(73) }
        catch { fputs("LOCAL_RUNTIME_START_FAILED\n", stderr); exit(64) }
    }
}
