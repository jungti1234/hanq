import AppKit

// Packaging artwork only. Coordinates are points; TIFF retains a 2x representation.
let args = CommandLine.arguments
precondition(args.count == 5, "Usage: render-background logo output-directory version build")
let output = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width = 720, height = 480
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.translateBy(x: 0, y: CGFloat(height))
context.cgContext.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ size: CGFloat,
          _ weight: NSFont.Weight = .regular, _ ink: UInt32 = 0x26364F, center: Bool = false) {
    let style = NSMutableParagraphStyle(); style.alignment = center ? .center : .left
    (value as NSString).draw(in: NSRect(x: x, y: y, width: w, height: size * 2), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(ink), .paragraphStyle: style])
}
let full = NSRect(x: 0, y: 0, width: width, height: height)
NSGradient(starting: color(0xEDF4FF), ending: color(0xFAFCFF))!.draw(in: full, angle: 90)
let logo = NSImage(contentsOfFile: args[1])!
func drawLogo(in bounds: NSRect, opacity: CGFloat) {
    let scale = min(bounds.width / logo.size.width, bounds.height / logo.size.height)
    let size = NSSize(width: logo.size.width * scale, height: logo.size.height * scale)
    let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    logo.draw(in: rect, from: .zero, operation: .sourceOver,
              fraction: opacity, respectFlipped: true, hints: nil)
}
drawLogo(in: NSRect(x: 555, y: -55, width: 230, height: 230), opacity: 0.055)
drawLogo(in: NSRect(x: 38, y: 28, width: 66, height: 66), opacity: 1)
text("한Q", 110, 37, 100, 27, .bold, 0x152D51)
text("복잡한 설정 없이, 맥의 한영 전환부터 한자 입력까지.", 111, 74, 560, 12, .regular, 0x637693)
text("Quick하게, 한큐에.", 111, 93, 560, 12, .regular, 0x637693)
text("한Q를 오른쪽 응용 프로그램 폴더로 드래그하세요.", 40, 148, 640, 21, .semibold, 0x162E52, center: true)
for x in [CGFloat(124), CGFloat(428)] {
    let rect = NSRect(x: x, y: 204, width: 168, height: 146)
    color(0xFFFFFF, 0.8).setFill()
    let path = NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24); path.fill()
    color(0xDDE7F5).setStroke(); path.lineWidth = 1; path.stroke()
}
let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 330, y: 260)); arrow.line(to: NSPoint(x: 390, y: 260))
arrow.move(to: NSPoint(x: 378, y: 249)); arrow.line(to: NSPoint(x: 390, y: 260)); arrow.line(to: NSPoint(x: 378, y: 271))
color(0x3F82E7).setStroke(); arrow.lineWidth = 2.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
let instruction = "응용 프로그램 폴더로 옮겨진 한Q를 실행하고 손쉬운 사용 권한을 허용해주세요."
let instructionStyle = NSMutableParagraphStyle(); instructionStyle.alignment = .center
let instructionText = NSMutableAttributedString(string: instruction, attributes: [
    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: color(0x63738A),
    .paragraphStyle: instructionStyle])
instructionText.addAttributes([
    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color(0x1762C4)
], range: (instruction as NSString).range(of: "손쉬운 사용 권한을 허용"))
instructionText.draw(in: NSRect(x: 36, y: 370, width: 648, height: 32))
color(0xDFE7F1).setFill(); NSRect(x: 40, y: 412, width: 640, height: 1).fill()
text("macOS 13 이상 · Apple Silicon", 40, 436, 300, 11, .medium, 0x78869A)
let footer = "\(args[3])  ·  빌드 \(args[4])"
let style = NSMutableParagraphStyle(); style.alignment = .right
(footer as NSString).draw(in: NSRect(x: 340, y: 436, width: 340, height: 22), withAttributes: [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: color(0x78869A), .paragraphStyle: style])
NSGraphicsContext.restoreGraphicsState()
try rep.tiffRepresentation!.write(to: output.appendingPathComponent("background.tiff"))
try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("background.png"))
