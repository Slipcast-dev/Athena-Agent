# Development Athena0.29.0

Swift5.9+, macOS14+ target. Vendored EcosystemKit0.23.0, Yams6.2.2 pinned.
No sibling repository is required.

```sh
python3 script/verify_ecosystem_dependency.py
swift test
swift test --package-path Packages/EcosystemKit
./script/build_and_run.sh --package
```

Permission, queue, cancellation and recovery changes require negative regression checks.

[Architecture](ARCHITECTURE.md) · [Contributing](../CONTRIBUTING.md) · [Security](../SECURITY.md).
