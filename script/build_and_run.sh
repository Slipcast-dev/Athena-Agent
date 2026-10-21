#!/usr/bin/env bash
# Единая точка запуска SwiftUI-приложения из Swift Package. Скрипт собирает
# воспроизводимый локальный .app-пакет, поэтому macOS запускает приложение как GUI.
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Athena"
# Техническое имя продукта сохраняет совместимость модулей и MCP-настроек.
PRODUCT_NAME="MacAssistant"
BUNDLE_ID="com.macassistant.app"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="${ECOSYSTEM_APP_VERSION:-0.28.0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
INSTALLERS_DIR="$ROOT_DIR/installers"
# Finder не должен наблюдать пустой/недособранный .app: иначе он запоминает
# стандартную иконку до перезапуска. Публикуем только полностью готовый bundle.
STAGING_PARENT="$(mktemp -d)"
APP_BUNDLE="$STAGING_PARENT/$APP_NAME.app"
trap 'rm -rf "$STAGING_PARENT"' EXIT
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$PRODUCT_NAME"
MCP_BINARY="$APP_MACOS/MacAssistantMCP"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Sources/MacAssistant/Resources/AgentAthena.png"
ICON_FILE="$APP_CONTENTS/Resources/$APP_NAME.icns"
INSTALLER_PATH="$INSTALLERS_DIR/Локальные-сборки/$APP_NAME-$APP_VERSION-unsigned.pkg"

BUILD_CONFIGURATION="debug"
if [[ "$MODE" == "--package" || "$MODE" == "package" || "$MODE" == "--installer" || "$MODE" == "installer" ]]; then
  # Релизный бинарник нужен для передачи на ручную подпись; запускать его
  # автоматически не следует, поскольку это операция подготовки артефакта.
  BUILD_CONFIGURATION="release"
fi

if [[ "$MODE" != "--package" && "$MODE" != "package" && "$MODE" != "--installer" && "$MODE" != "installer" ]]; then
  pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
swift build -c "$BUILD_CONFIGURATION"
BUILD_BINARY="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)/$PRODUCT_NAME"
BUILD_MCP_BINARY="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)/MacAssistantMCP"
BUILD_PRODUCTS_DIR="$(dirname "$BUILD_BINARY")"

mkdir -p "$APP_MACOS"
mkdir -p "$APP_CONTENTS/Resources"
cp "$ROOT_DIR/LICENSE" "$APP_CONTENTS/Resources/LICENSE.txt"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_CONTENTS/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT_DIR/docs/MAINTENANCE.md" "$APP_CONTENTS/Resources/ProfileMaintenance.md"
cp "$ROOT_DIR/docs/LIFECYCLE.md" "$APP_CONTENTS/Resources/ProfileLifecycle.md"
cp "$BUILD_PRODUCTS_DIR/AthenaMaintenance" "$APP_MACOS/AthenaMaintenance"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_MCP_BINARY" "$MCP_BINARY"
chmod +x "$APP_BINARY"
chmod +x "$MCP_BINARY"

# SwiftPM обрабатывает ресурсы исполняемого target в отдельный bundle рядом с
# бинарником. `Bundle.module` в SwiftUI ищет именно его: без копирования
# приложение аварийно завершается при первом обращении к ресурсам (например,
# к изображению Афины в боковой панели). Переносим все bundles целиком, чтобы
# упаковщик оставался корректным и после добавления новых локальных ресурсов.
while IFS= read -r -d '' resource_bundle; do
  /usr/bin/ditto --norsrc --noextattr "$resource_bundle" "$APP_CONTENTS/Resources/$(basename "$resource_bundle")"
done < <(/usr/bin/find "$BUILD_PRODUCTS_DIR" -maxdepth 1 -type d -name '*.bundle' -print0)

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Не найден исходный файл иконки: $ICON_SOURCE" >&2
  exit 1
fi

# macOS использует .icns для иконки приложения. Набор размеров создаётся из
# одного квадратного исходника, чтобы Finder и Dock не масштабировали его
# некачественно на Retina-экранах.
ICONSET_PARENT="$(mktemp -d)"
ICONSET_DIR="$ICONSET_PARENT/$APP_NAME.iconset"
mkdir -p "$ICONSET_DIR"
trap 'rm -rf "$ICONSET_PARENT" "$STAGING_PARENT"' EXIT
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  /usr/bin/sips -z "$retina_size" "$retina_size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <!-- ICNS используется напрямую: CFBundleIconName требует Asset Catalog,
       которого в SwiftPM bundle нет. -->
  <key>CFBundleIconFile</key>
  <string>$APP_NAME.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Вложенный runtime доставляется целиком, но не включается автоматически.
# Без этого bundle установщик переносил GUI/MCP, оставляя фон только в .build.
BACKGROUND="$APP_CONTENTS/Library/LoginItems/AthenaBackground.app"
mkdir -p "$BACKGROUND/Contents/MacOS" "$BACKGROUND/Contents/Resources"
cp "$BUILD_PRODUCTS_DIR/AthenaRuntime" "$BACKGROUND/Contents/MacOS/AthenaRuntime"
while IFS= read -r -d '' resource_bundle; do
  /usr/bin/ditto --norsrc --noextattr "$resource_bundle" "$BACKGROUND/Contents/Resources/$(basename "$resource_bundle")"
done < <(/usr/bin/find "$BUILD_PRODUCTS_DIR" -maxdepth 1 -type d -name '*.bundle' -print0)
# Собственный sender bundle обязан нести ICNS до codesign: иконка GUI
# не используется автоматически для уведомлений Athena Background.
cp "$ICON_FILE" "$BACKGROUND/Contents/Resources/Athena.icns"
python3 - "$BACKGROUND/Contents/Info.plist" "$APP_VERSION" <<'BACKGROUND_PLIST'
import plistlib
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundlePackageType': 'APPL', 'CFBundleExecutable': 'AthenaRuntime',
    'CFBundleIdentifier': 'com.macassistant.app.background',
    'CFBundleName': 'Athena Background', 'CFBundleVersion': sys.argv[2],
    'CFBundleShortVersionString': sys.argv[2],
    'CFBundleIconFile': 'Athena.icns',
    'LSMinimumSystemVersion': '14.0', 'LSUIElement': True,
    'NSPrincipalClass': 'NSApplication'}))
BACKGROUND_PLIST
# Вложенный код подписывается до внешнего seal. --deep при подписи скрывал бы
# неполный список helpers; здесь каждый элемент назван явно.
/usr/bin/codesign --force --sign - "$MCP_BINARY"
/usr/bin/codesign --force --sign - "$BACKGROUND"

# Ad-hoc подпись проверяет целостность локального артефакта, но не заменяет
# Developer ID Application и не делает приложение пригодным для распространения.
/usr/bin/codesign --force --sign - "$APP_MACOS/AthenaMaintenance"
/usr/bin/codesign --force --sign - "$APP_BUNDLE"

/usr/bin/plutil -lint "$INFO_PLIST"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
swift "$ROOT_DIR/script/verify_app_bundle.swift" "$APP_BUNDLE" "$ICONSET_PARENT/staged-preview.png"

# Предыдущая сборка живёт во временном каталоге до успешной замены. В случае
# ошибки перемещения восстанавливаем её, не оставляя пользователя без .app.
mkdir -p "$DIST_DIR"
FINAL_APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
if [[ -e "$FINAL_APP_BUNDLE" ]]; then
  mv "$FINAL_APP_BUNDLE" "$STAGING_PARENT/previous.app"
fi
if ! mv "$APP_BUNDLE" "$FINAL_APP_BUNDLE"; then
  if [[ -d "$STAGING_PARENT/previous.app" ]]; then
    mv "$STAGING_PARENT/previous.app" "$FINAL_APP_BUNDLE"
  fi
  exit 1
fi
APP_BUNDLE="$FINAL_APP_BUNDLE"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$PRODUCT_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

# Finder кэширует имя и иконку при повторном создании .app с тем же bundle ID.
# Обновляем только запись готового приложения, не очищая общий кэш системы.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" && "${ECOSYSTEM_SKIP_LSREGISTER:-0}" != "1" ]]; then
  "$LSREGISTER" -f "$APP_BUNDLE" || echo "Не удалось обновить локальную запись Athena в LaunchServices." >&2
fi

# Ошибка alpha в любом размере ICNS должна остановить выпуск установщика,
# а не обнаруживаться пользователем уже после установки приложения.
swift "$ROOT_DIR/script/verify_app_bundle.swift" "$APP_BUNDLE" "$ICONSET_PARENT/finder-preview.png"

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }

make_installer() {
  # Пакет содержит приложение и MCP-исполнитель в одном bundle. Он не пытается
  # установить себя: запись в /Applications требует отдельного решения пользователя.
  PAYLOAD_PARENT="$(mktemp -d)"
  PAYLOAD_ROOT="$PAYLOAD_PARENT/root"
  trap 'rm -rf "$ICONSET_PARENT" "$PAYLOAD_PARENT" "$STAGING_PARENT"' EXIT
  mkdir -p "$PAYLOAD_ROOT/Applications"
  # Не переносим resource forks и расширенные атрибуты в payload. Иначе APFS
  # может создать `._`-файлы, которые бесполезны для приложения и засоряют PKG.
  /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$APP_BUNDLE" "$PAYLOAD_ROOT/Applications/$APP_NAME.app"
  # AppleDouble-файлы не входят в состав приложения. Удаляем те, которые могли
  # попасть во временный payload при копировании. Современный macOS может
  # дополнительно сериализовать provenance в unsigned-пакет; это проверяется
  # отдельно перед публичным выпуском с Developer ID.
  /usr/bin/find "$PAYLOAD_ROOT" -type f -name '._*' -delete
  mkdir -p "$(dirname "$INSTALLER_PATH")"
  rm -f "$INSTALLER_PATH"
  /usr/bin/pkgbuild --root "$PAYLOAD_ROOT" --identifier "$BUNDLE_ID" --version "$APP_VERSION" --install-location / "$INSTALLER_PATH"
  # Для локального unsigned-пакета `pkgutil` намеренно завершает проверку
  # ненулевым статусом с «Status: no signature». Это предупреждение, а не
  # ошибка сборки: публичная подпись добавляется только владельцем Developer ID.
  if ! /usr/sbin/pkgutil --check-signature "$INSTALLER_PATH"; then
    echo "Установщик не подписан Developer ID; это ожидаемо для локальной сборки." >&2
  fi
  echo "Локальный установщик: $INSTALLER_PATH"
}

case "$MODE" in
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs) open_app; /usr/bin/log stream --info --style compact --predicate "process == \"$PRODUCT_NAME\"" ;;
  --telemetry|telemetry) open_app; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify) open_app; sleep 1; pgrep -x "$PRODUCT_NAME" >/dev/null ;;
  --package|package) /usr/bin/plutil -lint "$INFO_PLIST"; /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"; echo "Локальный релизный пакет: $APP_BUNDLE" ;;
  --installer|installer) /usr/bin/plutil -lint "$INFO_PLIST"; /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"; make_installer ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--package|--installer]" >&2; exit 2 ;;
esac
