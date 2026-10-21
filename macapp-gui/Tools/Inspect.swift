import AppKit
import Foundation

// 用法: swift Inspect.swift <输入.png> <x> <y> <w> <h> <输出.png> [--probe]
// 坐标为 1x 逻辑像素，脚本内部按图片实际倍率换算。

let args = CommandLine.arguments
guard args.count >= 7,
      let image = NSImage(contentsOfFile: args[1]),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    print("用法: Inspect.swift <in.png> <x> <y> <w> <h> <out.png> [--probe]")
    exit(1)
}

let scale = Double(rep.pixelsWide) / image.size.width
var x = Int(Double(args[2])! * scale)
var y = Int(Double(args[3])! * scale)
let w = Int(Double(args[4])! * scale)
let h = Int(Double(args[5])! * scale)
let out = args[6]

// CGImage 坐标原点在左上，NSBitmapImageRep 的 colorAt 也是左上
guard let cg = rep.cgImage else { exit(1) }

if args.contains("--probe") {
    print("图片 \(rep.pixelsWide)x\(rep.pixelsHigh) scale=\(scale)")
    for dy in stride(from: 0, to: h, by: max(1, h / 12)) {
        let px = x + w / 2
        let py = y + dy
        if let color = rep.colorAt(x: px, y: py) {
            let r = Int(color.redComponent * 255)
            let g = Int(color.greenComponent * 255)
            let b = Int(color.blueComponent * 255)
            print(String(format: "  y=%4d (1x %5.1f)  rgb(%3d,%3d,%3d)", py, Double(py) / scale, r, g, b))
        }
    }
    exit(0)
}

guard let cropped = cg.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else {
    print("裁剪失败")
    exit(1)
}
let outRep = NSBitmapImageRep(cgImage: cropped)
if let data = outRep.representation(using: .png, properties: [:]) {
    try data.write(to: URL(fileURLWithPath: out))
    print("cropped \(w)x\(h) -> \(out)")
}
