# Changes / Изменения

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
