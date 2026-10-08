import Foundation
import zlib

// MARK: - 轻量 ZIP 读写（纯 Swift，无 Process / 无第三方依赖）
//
// xlsx 本质是 ZIP 容器。这里实现读写 xlsx 所需的 ZIP 子集：
// - 写：store（不压缩）方式打包文件 —— 合法 ZIP，Excel/WPS/Numbers 均可打开
// - 读：支持 stored 与 deflate 两种压缩方式解包（Apple 系统内含 zlib）
//
// 结构依据 PKWARE APPNOTE：Local File Header + Central Directory + EOCD。

enum MiniZIP {

    struct Entry {
        let path: String          // zip 内相对路径，如 "xl/workbook.xml"
        let data: Data
    }

    // MARK: - 写（全部 store，不压缩；CRC32 保证合法）

    static func archive(entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        var crcTable = buildCRCTable()

        for entry in entries {
            let nameBytes = Array(entry.path.utf8)
            let crc = crc32(entry.data, table: &crcTable)
            let offset = UInt32(out.count)

            // Local File Header
            out.appendLE(UInt32(0x04034b50))       // signature
            out.appendLE(UInt16(20))               // version needed
            out.appendLE(UInt16(1 << 11))          // flags: UTF-8 文件名
            out.appendLE(UInt16(0))                // method: stored
            out.appendLE(UInt16(0))                // mod time
            out.appendLE(UInt16(0x21))             // mod date (1980-01-01，占位即可)
            out.appendLE(UInt32(crc))
            out.appendLE(UInt32(entry.data.count)) // compressed
            out.appendLE(UInt32(entry.data.count)) // uncompressed
            out.appendLE(UInt16(nameBytes.count))
            out.appendLE(UInt16(0))                // extra len
            out.append(contentsOf: nameBytes)
            out.append(entry.data)

            // Central directory record
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20))           // version made by
            central.appendLE(UInt16(20))           // version needed
            central.appendLE(UInt16(1 << 11))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0x21))
            central.appendLE(UInt32(crc))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))            // extra
            central.appendLE(UInt16(0))            // comment
            central.appendLE(UInt16(0))            // disk number
            central.appendLE(UInt16(0))            // internal attrs
            central.appendLE(UInt32(0))            // external attrs
            central.appendLE(UInt32(offset))
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)

        // End of Central Directory
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))                    // disk
        out.appendLE(UInt16(0))                    // cd disk
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count))
        out.appendLE(UInt32(centralOffset))
        out.appendLE(UInt16(0))                    // comment len
        return out
    }

    // MARK: - 读

    static func extract(data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ZIPError.invalid }
        // 从尾部找 EOCD（允许注释，向后扫描）
        var eocdOffset = -1
        let limit = max(0, data.count - 22 - 65_536)
        var i = data.count - 22
        while i >= limit {
            if data.readLE32(at: i) == 0x06054b50 { eocdOffset = i; break }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw ZIPError.invalid }

        let entryCount = Int(data.readLE16(at: eocdOffset + 10))
        var cdOffset = Int(data.readLE32(at: eocdOffset + 16))

        var entries: [Entry] = []
        for _ in 0..<entryCount {
            guard cdOffset + 46 <= data.count,
                  data.readLE32(at: cdOffset) == 0x02014b50 else { throw ZIPError.invalid }
            let method = Int(data.readLE16(at: cdOffset + 10))
            let compressedSize = Int(data.readLE32(at: cdOffset + 20))
            let nameLen = Int(data.readLE16(at: cdOffset + 28))
            let extraLen = Int(data.readLE16(at: cdOffset + 30))
            let commentLen = Int(data.readLE16(at: cdOffset + 32))
            let localOffset = Int(data.readLE32(at: cdOffset + 42))
            let name = String(data: data.subdata(in: (cdOffset + 46)..<(cdOffset + 46 + nameLen)),
                              encoding: .utf8) ?? ""
            cdOffset += 46 + nameLen + extraLen + commentLen

            // Local header：跳过其文件名/extra（长度可能与 central 不一致）
            guard localOffset + 30 <= data.count,
                  data.readLE32(at: localOffset) == 0x04034b50 else { throw ZIPError.invalid }
            let localNameLen = Int(data.readLE16(at: localOffset + 26))
            let localExtraLen = Int(data.readLE16(at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            guard dataStart + compressedSize <= data.count else { throw ZIPError.invalid }
            let payload = data.subdata(in: dataStart..<(dataStart + compressedSize))

            let content: Data
            switch method {
            case 0:
                content = payload
            case 8:
                guard let inflated = inflate(payload) else { throw ZIPError.invalid }
                content = inflated
            default:
                continue   // 未知压缩方式：跳过（xlsx 内用不到）
            }
            entries.append(Entry(path: name, data: content))
        }
        return entries
    }

    enum ZIPError: Error { case invalid }

    // MARK: - zlib deflate 解压

    private static func inflate(_ input: Data) -> Data? {
        // raw deflate（ZIP method 8 是 raw，无 zlib/gzip 头）→ windowBits = -15
        return inflateRaw(input, windowBits: -15)
            ?? inflateRaw(input, windowBits: 15 + 32)   // 兜底：zlib/gzip 头
    }

    private static func inflateRaw(_ input: Data, windowBits: Int32) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK,
              stream.state != nil else { return nil }
        defer { inflateEnd(&stream) }

        let src = [UInt8](input)
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 3 + 64)
        let chunk = 65_536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }

        return try? src.withUnsafeBufferPointer { srcBuf -> Data? in
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcBuf.baseAddress)
            stream.avail_in = uInt(src.count)
            repeat {
                stream.next_out = buffer
                stream.avail_out = uInt(chunk)
                let result = zlib.inflate(&stream, Z_NO_FLUSH)
                guard result == Z_OK || result == Z_STREAM_END else { return nil }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 { output.append(contentsOf: UnsafeBufferPointer(start: buffer, count: produced)) }
                if result == Z_STREAM_END { return Data(output) }
                if produced == 0 && stream.avail_in == 0 { return Data(output) }
            } while true
        }
    }

    // MARK: - CRC32

    private static func buildCRCTable() -> [UInt32] {
        (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            }
            return c
        }
    }

    private static func crc32(_ data: Data, table: inout [UInt32]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Data 小端读写

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
    func readLE16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }
    func readLE32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }
}
