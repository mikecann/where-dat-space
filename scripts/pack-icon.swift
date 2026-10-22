// iconutil uses an image conversion service that can be unavailable in sandboxes.
// This fallback packs the same sips-generated PNGs in the standard ICNS container.
import Foundation

let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
func bigEndianBytes(_ value: Int) -> Data {
    var word = UInt32(value).bigEndian
    return withUnsafeBytes(of: &word) { Data($0) }
}
let representations = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png")
]
var chunks = Data()
for (type, name) in representations {
    let png = try Data(contentsOf: source.appendingPathComponent(name))
    chunks.append(Data(type.utf8)); chunks.append(bigEndianBytes(png.count + 8)); chunks.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndianBytes(chunks.count + 8)); icon.append(chunks)
try icon.write(to: destination)
