import Foundation

// ICNS containers support PNG payloads at these standard size identifiers.
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
func bigEndian(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
let representations = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]
var content = Data()
for (type, name) in representations {
    let payload = try Data(contentsOf: iconset.appendingPathComponent(name))
    content.append(Data(type.utf8))
    content.append(bigEndian(UInt32(payload.count + 8)))
    content.append(payload)
}
var archive = Data("icns".utf8)
archive.append(bigEndian(UInt32(content.count + 8)))
archive.append(content)
try archive.write(to: destination)
