// swift-tools-version: 5.9
// Минимальная конфигурация Swift Package: она делает архитектурное ядро
// воспроизводимо собираемым и тестируемым; Yams разбирает YAML без эвристик строк.
import PackageDescription

let package = Package(
    name: "MacAssistant",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacAssistantCore", targets: ["MacAssistantCore"]),
        .executable(name: "MacAssistant", targets: ["MacAssistant"]),
        // Отдельный процесс нужен Harness для безопасного протокола stdio:
        // графическое приложение не должно делить с внешним агентом свой UI-процесс.
        .executable(name: "MacAssistantMCP", targets: ["MacAssistantMCP"]),
        .executable(name: "AthenaRuntime", targets: ["AthenaRuntime"]),
        .executable(name: "CodexAgentTool", targets: ["CodexAgentTool"]),
        .executable(name: "HarnessAgentTool", targets: ["HarnessAgentTool"])
    ],
    dependencies: [
        // Относительный путь сохраняет воспроизводимость в общей папке/архиве.
        .package(path: "Packages/EcosystemKit"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
    ],
    targets: [
        .target(name: "MacAssistantCore", dependencies: [
            .product(name: "EcosystemContracts", package: "EcosystemKit"),
            .product(name: "EcosystemLocalIPC", package: "EcosystemKit"),
            .product(name: "EcosystemClientAdapters", package: "EcosystemKit"),
            .product(name: "EcosystemRuntimeSupport", package: "EcosystemKit"),
            .product(name: "Yams", package: "Yams")
        ]),
        .executableTarget(
            name: "MacAssistant",
            dependencies: ["MacAssistantCore", .product(name: "EcosystemUI", package: "EcosystemKit")],
            // PNG Афины доступен как локальный ресурс и резервная иконка Dock,
            // без зависимости от внешнего пути на машине разработчика.
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "AthenaRuntime", dependencies: ["MacAssistantCore"]),
        .executableTarget(name: "HarnessAgentTool", dependencies: [.product(name: "EcosystemClientAdapters", package: "EcosystemKit")]),
        .executableTarget(name: "CodexAgentTool", dependencies: [.product(name: "EcosystemClientAdapters", package: "EcosystemKit")]),
        .executableTarget(
            name: "MacAssistantMCP",
            dependencies: ["MacAssistantCore"]
        ),
        .testTarget(
            name: "MacAssistantCoreTests",
            dependencies: ["MacAssistantCore", "MacAssistant"]
        )
    ]
)
