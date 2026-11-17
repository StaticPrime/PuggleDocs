import Compression
import Foundation

public enum ZipError: Error, Equatable {
    case notAZipFile
    case corrupt(String)
    case unsupported(String)
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1) }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Raw DEFLATE (RFC 1951) via the Compression framework, as ZIP requires.
enum Deflate {
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 10 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }

    static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        if data.isEmpty { return Data() }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupt("Could not start decompression.")
        }
        defer { compression_stream_destroy(&stream) }
        let chunkSize = max(64 * 1024, min(expectedSize, 8 * 1024 * 1024))
        var output = Data()
        output.reserveCapacity(max(expectedSize, 0))
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        return try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = data.count
            while true {
                let status: compression_status = buffer.withUnsafeMutableBufferPointer { dst in
                    stream.dst_ptr = dst.baseAddress!
                    stream.dst_size = chunkSize
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = chunkSize - stream.dst_size
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.src_size == 0 { return output }
                default: throw ZipError.corrupt("The compressed data is damaged.")
                }
            }
        }
    }
}

/// Writes a ZIP archive in memory.
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count = 0
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        dosDate = UInt16(max((parts.year ?? 1980) - 1980, 0) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
    }

    mutating func add(path: String, data: Data, compress: Bool = true) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let deflated = compress ? Deflate.compress(data) : nil
        let useDeflate = deflated.map { $0.count < data.count } ?? false
        let payload = useDeflate ? deflated! : data
        let method: UInt16 = useDeflate ? 8 : 0
        let offset = UInt32(body.count)

        var local = Data()
        local.appendLE(UInt32(0x0403_4B50))
        local.appendLE(UInt16(20))
        local.appendLE(UInt16(0x0800))
        local.appendLE(method)
        local.appendLE(dosTime)
        local.appendLE(dosDate)
        local.appendLE(crc)
        local.appendLE(UInt32(payload.count))
        local.appendLE(UInt32(data.count))
        local.appendLE(UInt16(name.count))
        local.appendLE(UInt16(0))
        local.append(name)
        body.append(local)
        body.append(payload)

        var entry = Data()
        entry.appendLE(UInt32(0x0201_4B50))
        entry.appendLE(UInt16(20))
        entry.appendLE(UInt16(20))
        entry.appendLE(UInt16(0x0800))
        entry.appendLE(method)
        entry.appendLE(dosTime)
        entry.appendLE(dosDate)
        entry.appendLE(crc)
        entry.appendLE(UInt32(payload.count))
        entry.appendLE(UInt32(data.count))
        entry.appendLE(UInt16(name.count))
        entry.appendLE(UInt16(0))
        entry.appendLE(UInt16(0))
        entry.appendLE(UInt16(0))
        entry.appendLE(UInt16(0))
        entry.appendLE(UInt32(0))
        entry.appendLE(offset)
        entry.append(name)
        central.append(entry)
        count += 1
    }

    func finish() -> Data {
        var archive = body
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.appendLE(UInt32(0x0605_4B50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(count))
        archive.appendLE(UInt16(count))
        archive.appendLE(UInt32(central.count))
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        return archive
    }
}

/// Reads entries from a ZIP archive held in memory.
struct ZipReader {
    struct Entry {
        let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let data: Data
    private(set) var entries: [String: Entry] = [:]

    init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw ZipError.notAZipFile }
        // The end-of-central-directory record sits at the end, before an optional comment.
        var eocd = -1
        let lowest = max(0, data.count - 22 - 65_535)
        var index = data.count - 22
        while index >= lowest {
            if data.readLE32(at: index) == 0x0605_4B50 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZipFile }
        let total = Int(data.readLE16(at: eocd + 10))
        let centralOffset = Int(data.readLE32(at: eocd + 16))
        guard centralOffset != 0xFFFF_FFFF else { throw ZipError.unsupported("ZIP64 archives are not supported.") }
        var cursor = centralOffset
        for _ in 0..<total {
            guard cursor + 46 <= data.count, data.readLE32(at: cursor) == 0x0201_4B50 else { throw ZipError.corrupt("Bad central directory.") }
            let method = data.readLE16(at: cursor + 10)
            let compressed = Int(data.readLE32(at: cursor + 20))
            let uncompressed = Int(data.readLE32(at: cursor + 24))
            let nameLength = Int(data.readLE16(at: cursor + 28))
            let extraLength = Int(data.readLE16(at: cursor + 30))
            let commentLength = Int(data.readLE16(at: cursor + 32))
            let localOffset = Int(data.readLE32(at: cursor + 42))
            guard cursor + 46 + nameLength <= data.count else { throw ZipError.corrupt("Bad entry name.") }
            let nameData = data.subdata(in: (data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength))
            let path = String(decoding: nameData, as: UTF8.self)
            entries[path] = Entry(path: path, method: method, compressedSize: compressed,
                                  uncompressedSize: uncompressed, localHeaderOffset: localOffset)
            cursor += 46 + nameLength + extraLength + commentLength
        }
    }

    func contains(_ path: String) -> Bool { entries[path] != nil }

    /// Entry lookup is case-insensitive as a fallback, since some producers vary the case.
    func read(_ path: String) throws -> Data? {
        let entry = entries[path] ?? entries.first(where: { $0.key.caseInsensitiveCompare(path) == .orderedSame })?.value
        guard let entry else { return nil }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.readLE32(at: header) == 0x0403_4B50 else { throw ZipError.corrupt("Bad local header.") }
        let start = header + 30 + Int(data.readLE16(at: header + 26)) + Int(data.readLE16(at: header + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError.corrupt("Truncated entry.") }
        let payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0: return payload
        case 8: return try Deflate.decompress(payload, expectedSize: entry.uncompressedSize)
        default: throw ZipError.unsupported("Compression method \(entry.method) is not supported.")
        }
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLE16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func readLE32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }
}
