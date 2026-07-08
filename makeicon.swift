import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
let text = "☕️" as NSString
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 820)]
let size = text.size(withAttributes: attrs)
text.draw(at: NSPoint(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2),
          withAttributes: attrs)
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
rep.size = NSSize(width: canvas, height: canvas)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("wrote icon_1024.png \(png.count) bytes")
