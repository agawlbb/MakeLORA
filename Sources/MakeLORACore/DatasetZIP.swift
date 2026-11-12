import Foundation

/// A streaming, uncompressed ZIP writer. JPEGs are already compressed.
/// Classic ZIP limits are checked rather than producing a corrupt archive.
public enum DatasetZIP {
    public static func write(files: [(name: String, url: URL)], to destination: URL) throws {
        guard files.count <= Int(UInt16.max) else { throw ProjectError.invalid("The dataset has too many files for one ZIP. Split it into smaller projects.") }
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw ProjectError.invalid("Cannot create the export ZIP. Free storage and try Export again.") }
        let output = try FileHandle(forWritingTo: destination)
        var complete = false
        defer { try? output.close(); if !complete { try? fm.removeItem(at: destination) } }
        struct Entry { let name: Data; let crc: UInt32; let size: UInt32; let offset: UInt32 }
        var entries: [Entry] = []
        for file in files {
            try Task.checkCancellation()
            let name = Data(file.name.utf8)
            guard name.count <= Int(UInt16.max), !file.name.hasPrefix("/"), !file.name.split(separator: "/").contains("..") else { throw ProjectError.invalid("Invalid export filename.") }
            let input = try FileHandle(forReadingFrom: file.url)
            defer { try? input.close() }
            let start = try output.offset()
            guard start < UInt64(UInt32.max) else { throw tooLarge }
            // Data descriptor allows streaming without loading an entire JPEG in memory.
            try output.write(contentsOf: header([(.u32, 0x04034b50), (.u16, 20), (.u16, 0x0808), (.u16, 0), (.u16, 0), (.u16, 0x21), (.u32, 0), (.u32, 0), (.u32, 0), (.u16, UInt64(name.count)), (.u16, 0)]))
            try output.write(contentsOf: name)
            var crc: UInt32 = 0xffffffff
            var size: UInt64 = 0
            while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                size += UInt64(bytes.count)
                guard size < UInt64(UInt32.max) else { throw tooLarge }
                for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
                try output.write(contentsOf: bytes)
            }
            crc ^= 0xffffffff
            try output.write(contentsOf: header([(.u32, 0x08074b50), (.u32, UInt64(crc)), (.u32, size), (.u32, size)]))
            entries.append(Entry(name: name, crc: crc, size: UInt32(size), offset: UInt32(start)))
        }
        let centralStart = try output.offset()
        for entry in entries {
            try output.write(contentsOf: header([(.u32, 0x02014b50), (.u16, 20), (.u16, 20), (.u16, 0x0808), (.u16, 0), (.u16, 0), (.u16, 0x21), (.u32, UInt64(entry.crc)), (.u32, UInt64(entry.size)), (.u32, UInt64(entry.size)), (.u16, UInt64(entry.name.count)), (.u16, 0), (.u16, 0), (.u16, 0), (.u16, 0), (.u32, 0), (.u32, UInt64(entry.offset))]))
            try output.write(contentsOf: entry.name)
        }
        let end = try output.offset()
        guard end < UInt64(UInt32.max) else { throw tooLarge }
        try output.write(contentsOf: header([(.u32, 0x06054b50), (.u16, 0), (.u16, 0), (.u16, UInt64(entries.count)), (.u16, UInt64(entries.count)), (.u32, end-centralStart), (.u32, centralStart), (.u16, 0)]))
        try output.synchronize()
        complete = true
    }
    private static var tooLarge: ProjectError { .invalid("This dataset exceeds the 4 GB ZIP limit. Split it into smaller projects and export again.") }
    private enum Width: Int { case u16 = 2, u32 = 4 }
    private static func header(_ fields: [(Width, UInt64)]) -> Data {
        var data = Data()
        for (width, value) in fields { for i in 0..<width.rawValue { data.append(UInt8(truncatingIfNeeded: value >> (8*i))) } }
        return data
    }
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }
}
