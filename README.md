![Athena](docs/assets/banner.svg)

<p align="center"><img src="docs/assets/athena-banner.png" width="620" alt="Athena"></p>

# Афина / Athena

[Русский](README.md) · [English](README.en.md)

Афина — отдельный локальный агент macOS. Диагностика Mac, анализ хранилища и мониторинг.

Версия **0.38.0**. Целевая macOS14+, текущий выпуск — **Apple Silicon arm64**.
Запуск на Intel и macOS14 отдельно ещё не принят. Проект с доступными исходниками
использует собственную некоммерческую [лицензию](LICENSE), а не MIT/OSI-лицензию.

Актуальные разделы: «Процессор», «Сеть», «Диск», «Память», «Аккумулятор», «Диагностика» и «Настройки». Живые графики показывают нагрузку CPU/ядер и память; диск включает список приложений и занимаемое ими место.

[Релиз 0.38.0](https://github.com/Slipcast-dev/Athena-Agent/releases/tag/v0.38.0) · [PKG](https://github.com/Slipcast-dev/Athena-Agent/releases/download/v0.38.0/Athena-0.38.0-unsigned.pkg) · [DMG](https://github.com/Slipcast-dev/Athena-Agent/releases/download/v0.38.0/Athena-0.38.0-unsigned.dmg) · [SHA-256](https://github.com/Slipcast-dev/Athena-Agent/releases/download/v0.38.0/SHA256SUMS) · [Проверки и ограничения](docs/RELEASE.md)

[Состав метрик и частота обновления](docs/MONITORING.md).

## Установка

PKG/DMG прикладываются к релизу отдельно от исходников. Выпуск **без подписи
Apple Developer ID и без notarization**. Перед использованием сверьте SHA256SUMS.
Локальная ad-hoc подпись защищает целостность, но не подтверждает издателя.
Не отключайте Gatekeeper глобально. Автоматическая установка не выполняется.

## Сборка

Нужны Xcode/Command Line Tools, Swift5.9+ и SDK macOS14+. Общий EcosystemKit
включён в репозиторий: соседние папки не требуются. Yams6.2.2 закреплён lock-файлом.

```sh
python3 script/verify_ecosystem_dependency.py
swift test
swift build -c release
./script/build_and_run.sh --package
```

Приложение появится в `dist/Athena.app`. Технические имена исполняемых файлов
сохранены ради совместимости модулей и клиентских конфигураций.

## Управление и безопасность

Интерфейс и фоновая служба разделены. Доступ к данным по умолчанию запрещён;
разрешения выдаются внутри каждого агента отдельно. Подключение Codex/Harness
выполняется через проверяемый план в интерфейсе. Hermes предусмотрен архитектурой,
но действующее подключение ещё не реализовано. Ключи моделей и личные данные
в комплект не входят.

[Эксплуатация](docs/OPERATIONS.md) · [Архитектура](docs/ARCHITECTURE.md) ·
[Безопасность](SECURITY.md) · [Производительность](docs/PERFORMANCE.md) ·
[Изменения](CHANGELOG.md) · [Поддержка](SUPPORT.md).

## Участие

Прочитайте [CONTRIBUTING](CONTRIBUTING.md), [правила общения](CODE_OF_CONDUCT.md)
и лицензию. Не публикуйте в issue личные файлы, профили и секреты. Сообщения об
уязвимостях направляйте по правилам SECURITY.md.


## RU/EN localization / Локализация

Предварительный выпуск 0.38.0. Полная ручная приёмка VoiceOver/клавиатуры
и аппаратные проверки остаются открытыми.
Select System, Русский or English in this agent's settings. Each agent keeps its
own language. Даты/числа следуют региону macOS. User names, paths and historical
free text retain their original language. System Settings follows macOS language.

```sh
python3 script/verify_localization_acceptance.py --athena-dir . --kit-dir Packages/EcosystemKit --require-reviewed-boundaries --output localization-acceptance.json
ECOSYSTEM_SKIP_LSREGISTER=1 ECOSYSTEM_APP_VERSION=0.38.0 ./script/build_and_run.sh --package
python3 script/prepare_local_release.py --run --version 0.38.0 --agent Athena --use-prepared-apps --apps-dir dist --output installers/0.38.0
```

Installer output is unsigned Developer ID and not notarized. These commands
create and verify artifacts; they do not install applications or publish them.
