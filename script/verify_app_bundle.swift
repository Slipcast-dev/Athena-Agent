import AppKit

// Проверяем готовый bundle, а не только наличие исходного PNG. NSWorkspace
// использует тот же механизм разрешения иконки файла, который нужен Finder.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fatalError("usage: swift script/verify_app_bundle.swift <Athena.app> <icon-preview.png>")
}
let appURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
guard let bundle = Bundle(url: appURL),
      bundle.object(forInfoDictionaryKey: "CFBundleName") as? String == "Athena",
      bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Athena",
      bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String == "com.macassistant.app",
      bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "Athena.icns",
      bundle.object(forInfoDictionaryKey: "CFBundleIconName") == nil,
      let iconURL = bundle.url(forResource: "Athena", withExtension: "icns"),
      let icon = NSImage(contentsOf: iconURL), icon.isValid,
      let executable = bundle.executableURL,
      FileManager.default.isExecutableFile(atPath: executable.path) else {
    fatalError("Неверное имя, иконка или исполняемый файл Athena.app")
}
let finderIcon = NSWorkspace.shared.icon(forFile: appURL.path)
// Кэш Finder не должен скрывать непрозрачный фон внутри ICNS. Проверяем все
// размеры независимо: Dock и Finder выбирают разные растровые представления.
let iconBitmaps = icon.representations.compactMap { $0 as? NSBitmapImageRep }
guard !iconBitmaps.isEmpty else { fatalError("В ICNS отсутствуют растровые представления") }
for bitmap in iconBitmaps {
    guard bitmap.hasAlpha else { fatalError("ICNS должен содержать прозрачность") }
    for x in [0, bitmap.pixelsWide - 1] {
        for y in [0, bitmap.pixelsHigh - 1] {
            guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent < 0.01 else {
                fatalError("ICNS содержит непрозрачный внешний угол")
            }
        }
    }
}
finderIcon.size = NSSize(width: 256, height: 256)
guard let tiff = finderIcon.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Не удалось прочитать Finder-иконку Athena")
}
try png.write(to: URL(fileURLWithPath: arguments[2]))
print("Bundle: Athena; ICNS: \(iconURL.lastPathComponent); Finder icon rendered")
