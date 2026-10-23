# Разработка Athena0.37.0

Swift5.9+, macOS14+ target. Vendored EcosystemKit0.29.0, Yams6.2.2 pinned.
No sibling repository is required.

```sh
python3 script/verify_ecosystem_dependency.py
swift test
swift test --package-path Packages/EcosystemKit
./script/build_and_run.sh --package
```

Изменения прав, очередей, отмены и восстановления требуют отрицательных регрессий.

[Architecture](ARCHITECTURE.md) · [Contributing](../CONTRIBUTING.md) · [Security](../SECURITY.md).

```sh
python3 script/verify_localization_acceptance.py --athena-dir . --kit-dir Packages/EcosystemKit --require-reviewed-boundaries --output localization-acceptance.json
```
