# Эксплуатация / Operations

Откройте агент, настройте доступ к данным и клиенту внутри приложения.
Подключайте Codex или Harness через GUI-план, проверьте запрошенные изменения.
Отмена сеанса модели не равна отмене устойчивой задачи: проверяйте task status.
Нельзя автоматически повторять изменение после неопределённого transport result.

Open the app and grant data/client access explicitly. Review generated client
configuration before applying it. Cancel durable tasks separately from model
sessions; inspect status before retrying an uncertain operation.

## Восстановление мониторинга / Monitor replay0.29.0

Афина восстанавливает все сохранённые события мониторов (до1000), включая записи за первой страницей; устойчивые ID исключают повторы, ошибка импорта даёт retry5s. Часовое окно баннеров сохранено.

Athena replays the complete retained monitor history (up to1000 events), including events beyond the first page; stable IDs prevent duplicates and failed imports retry after5s. The one-hour notification window is unchanged.

UI/MCP pages remain100 entries. Replay does not reset the opt-in cutoff, TTL, consent or cooldown. Already evicted history cannot be recovered.
