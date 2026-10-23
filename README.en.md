![Athena](docs/assets/banner.svg)

<p align="center"><img src="docs/assets/athena-banner.png" width="620" alt="Athena"></p>

# Athena / Афина

[Русский](README.md) · [English](README.en.md)

[0.37.0 · PKG / DMG](https://github.com/Slipcast-dev/Athena-Agent/releases/tag/v0.37.0) · [Status / Статус](docs/STATUS.md) · [CI](https://github.com/Slipcast-dev/Athena-Agent/actions/workflows/ci.yml)

Athena is an independent local macOS agent. Local Mac diagnostics, storage analysis and monitoring.

Version **0.37.0** · macOS14+ target · current release **Apple Silicon arm64**.
Intel/macOS14 execution remains unverified. This is a source-available project
under the custom non-commercial [LICENSE](LICENSE), not an MIT-licensed project.

## Installation

[PKG](https://github.com/Slipcast-dev/Athena-Agent/releases/download/v0.37.0/Athena-0.37.0-unsigned.pkg) · [DMG](https://github.com/Slipcast-dev/Athena-Agent/releases/download/v0.37.0/Athena-0.37.0-unsigned.dmg) · [SHA256SUMS](https://github.com/Slipcast-dev/Athena-Agent/releases/download/v0.37.0/SHA256SUMS).

Installers are prerelease 0.37.0 attachments, not Git source files. They are **unsigned by
Developer ID and not notarized**. Verify SHA256SUMS before use. Local ad-hoc code
signatures provide integrity; they do not establish trusted developer identity.
Do not disable Gatekeeper globally. No automatic installation is performed.

## Build

Xcode / Command Line Tools with Swift5.9+; macOS14+ SDK. EcosystemKit is vendored:
no sibling repository is required. Yams6.2.2 is pinned in Package.resolved.

```sh
python3 script/verify_ecosystem_dependency.py
swift test
swift build -c release
./script/build_and_run.sh --package
```

Built apps: `dist/Athena.app`. Source executable names are retained for compatibility.

## Control and safety

GUI and background runtime are separate. Access starts denied; grant data access
inside this agent. Codex/Harness connection requires explicit setup in the app.
Hermes is a future extension; live Hermes support is not implemented.
No model keys or user data are bundled. See [security](SECURITY.md),
[operations](docs/OPERATIONS.md), [architecture](docs/ARCHITECTURE.md),
[performance](docs/PERFORMANCE.md), [changes](CHANGELOG.md) and [support](SUPPORT.md).

## Contributing

Read [CONTRIBUTING](CONTRIBUTING.md) and the [code of conduct](CODE_OF_CONDUCT.md).
Security reports should follow SECURITY.md; do not post personal data in issues.


## RU/EN localization / Локализация

**0.37.0 prerelease.** Select System, Русский or English in the agent settings.
Each application keeps its own language. Dates and numbers follow the macOS
region; user names, paths and historical free text retain their original values.
System Settings uses the macOS language.

Full manual VoiceOver/keyboard, macOS 14/Intel execution and installed-client
acceptance remain open. This prerelease has not completed full acceptance.

```sh
python3 script/verify_localization_acceptance.py --athena-dir . --kit-dir Packages/EcosystemKit --require-reviewed-boundaries --output localization-acceptance.json
ECOSYSTEM_SKIP_LSREGISTER=1 ECOSYSTEM_APP_VERSION=0.37.0 ./script/build_and_run.sh --package
python3 script/prepare_local_release.py --run --version 0.37.0 --agent Athena --use-prepared-apps --apps-dir dist --output installers/0.37.0
```

Installer output is unsigned Developer ID and not notarized. These commands
create and verify artifacts; they do not install applications or publish them.
