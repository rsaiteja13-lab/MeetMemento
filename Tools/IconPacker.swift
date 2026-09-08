import Foundation

@main
struct IconPacker {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileWriteInvalidFileName) }
        let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let entries = [
            ("icp4", "icon_16x16.png"),
            ("icp5", "icon_32x32.png"),
            ("icp6", "icon_32x32@2x.png"),
            ("ic07", "icon_128x128.png"),
            ("ic08", "icon_256x256.png"),
            ("ic09", "icon_512x512.png"),
            ("ic10", "icon_512x512@2x.png")
        ]

        var payload = Data()
        for (type, name) in entries {
            let image = try Data(contentsOf: iconset.appendingPathComponent(name))
            payload.append(Data(type.utf8))
            appendBigEndian(UInt32(image.count + 8), to: &payload)
            payload.append(image)
        }

        var result = Data("icns".utf8)
        appendBigEndian(UInt32(payload.count + 8), to: &result)
        result.append(payload)
        try result.write(to: output, options: .atomic)
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
