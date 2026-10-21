import AppKit

// Однократная обработка существующего рисунка без перерисовки нейросетью.
// Геометрия соответствует именно рамке исходной иконки Афины, а не является
// универсальным удалением фона. Внутри рамки пиксели остаются неизменными.
guard CommandLine.arguments.count == 3 else {
    fatalError("usage: swift script/prepare_athena_icon.swift <input.png> <output.png>")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let data = try Data(contentsOf: input)
guard let bitmap = NSBitmapImageRep(data: data), let image = bitmap.cgImage else {
    fatalError("Не удалось прочитать исходную иконку")
}
let width = image.width
let height = image.height
guard width == height else { fatalError("Ожидается квадратная иконка") }
let side = Double(width)
guard let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let memory = context.data else {
    fatalError("Не удалось создать RGBA-буфер")
}
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
let pixels = memory.assumingMemoryBound(to: UInt8.self)
// Граница синей/фиолетовой плитки измерена на оригинале 1254×1254.
// Знаковое расстояние до скруглённого прямоугольника сохраняет светящуюся
// кромку и обеспечивает сглаживание вместо ступенчатых углов на Retina.
let left = side * 0.036
let top = side * 0.032
let right = side * 0.964
let bottom = side * 0.956
let radius = side * 0.208
let centerX = (left + right) / 2
let centerY = (top + bottom) / 2
let halfWidth = (right - left) / 2
let halfHeight = (bottom - top) / 2
let feather = side * 0.003
for y in 0..<height {
    for x in 0..<width {
        let dx = abs(Double(x) + 0.5 - centerX) - (halfWidth - radius)
        let dy = abs(Double(y) + 0.5 - centerY) - (halfHeight - radius)
        let distance = hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - radius
        let opacity = min(1, max(0, 1 - distance / feather))
        let offset = (y * width + x) * 4
        // Умножаются и premultiplied RGB, и alpha: иначе прозрачная кромка
        // даст тёмный/цветной ореол при масштабировании системным Dock.
        for channel in 0..<4 {
            pixels[offset + channel] = UInt8((Double(pixels[offset + channel]) * opacity).rounded())
        }
    }
}
guard let result = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else {
    fatalError("Не удалось сохранить прозрачную иконку")
}
try png.write(to: output, options: .atomic)
print("Прозрачная иконка: \(output.path)")
