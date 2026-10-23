# Changes / Изменения

## 0.38.0 — 2026-10-23, pre-release

- CPU and per-core live load, memory charts and per-process memory.
- Network rates and interface configuration; disk capacity and application inventory.
- Battery data exposed by macOS, with explicit unavailable/unsupported states.
- Seven sections: CPU, Network, Disk, Memory, Battery, Diagnostics, Settings.
- Folder analysis moved to Disk; Mac information moved to Settings.
- GUI-only monitoring subscriptions, bounded in-memory history and stale-sample handling.
- Fixed standalone MCP localization resources during profile creation and cold upgrade.
- Added regression coverage for legacy upgrade, resource transfer and rollback.
- Refreshed release downloads, installation instructions and current validation details.
- arm64, local ad-hoc signatures; Developer ID/notarization and external acceptance remain open.

## Previous releases / Предыдущие выпуски

## 0.37.0 — RU/EN prerelease / предварительный выпуск

- Independent System/Russian/English preference per agent.
- RU/EN UI, typed errors, new diagnostic presentation and bilingual MCP metadata.
- Localized GUI/background bundle names and unsigned PKG welcome/readme pages.
- Existing histories, permissions, machine schemas and replay protection retained.
- Full manual accessibility, macOS14/Intel and installed-client acceptance remain open.
- Preliminary release; full production acceptance remains open.

Локализация: независимый выбор System/RU/EN, перевод интерфейса и встроенных
ошибок, локализованные имена GUI/фоновой службы и страницы установщика.
Существующие данные, разрешения и защита от повторных операций сохраняются.

## 0.29.0

Афина восстанавливает все сохранённые события мониторов (до1000), включая записи за первой страницей; устойчивые ID исключают повторы, ошибка импорта даёт retry5s. Часовое окно баннеров сохранено.

Athena replays the complete retained monitor history (up to1000 events), including events beyond the first page; stable IDs prevent duplicates and failed imports retry after5s. The one-hour notification window is unchanged.

Developer ID unsigned / not notarized.

## После 0.28.0 / After 0.28.0

Source compatibility: SwiftPM resource layouts across Xcode versions; explicit MCP entry filename for older Swift. Released 0.28.0 installer assets remain unchanged.

Совместимость исходников: расположение SwiftPM-ресурсов и точка входа MCP при разных версиях Swift. Установщики релиза 0.28.0 сохранены без замены.

## 0.28.0

- Adaptive monitor waiting and bounded storage selection retained.
- Conservative heavy-task concurrency on battery/Low Power/thermal constraints.
- Measured synthetic idle-runtime CPU, memory and kernel wakeups.
- Previous adaptive queues, bounded storage selection and snapshot views retained.
- Standalone source export; Developer ID/notarization remain unavailable.
