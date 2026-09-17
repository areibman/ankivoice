import Foundation
import Compression

/// Minimal ZIP archive reader supporting the methods Anki `.apkg` files use:
/// stored (0) and deflate (8). Zstd-compressed entries (modern `.colpkg`
/// backups) are reported as unsupported with an actionable message.
///
/// Built for large packages: the archive is memory-mapped rather than read
/// into RAM, entries inflate through a streaming decoder, and
/// `extract(_:to:)` writes straight to disk so a 500 MB media deck never
/// needs 500 MB of memory. ZIP64 (more than 65,535 media files, or entries
/// above 4 GB) is understood.
public struct ZipReader {

    public enum ZipError: Error, LocalizedError {
        case notAZipFile
        case unsupportedMethod(method: UInt16, entry: String)
        case corruptEntry(String)
        case entryNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .notAZipFile:
                return "The file is not a ZIP archive."
            case .unsupportedMethod(let method, let entry):
                return String(
                    format: "'%@' uses compression method %d which is unsupported. Re-export from Anki using the legacy/compatible format.", entry, method
                )
            case .corruptEntry(let entry):
                return "The ZIP entry '\(entry)' is corrupt."
            case .entryNotFound(let entry):
                return "The ZIP entry '\(entry)' was not found."
            }
        }
    }

    public struct Entry {
        public let name: String
        public let method: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int
    }

    public let entries: [Entry]
    private let data: Data
    private let indexByName: [String: Int]

    public init(data: Data) throws {
        self.data = data
        let entries = try Self.readCentralDirectory(data)
        self.entries = entries
        var index: [String: Int] = [:]
        index.reserveCapacity(entries.count)
        for (i, entry) in entries.enumerated() where index[entry.name] == nil {
            index[entry.name] = i
        }
        self.indexByName = index
    }

    /// Maps the file instead of loading it: pages are faulted in as entries
    /// are read and can be evicted under memory pressure.
    public init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public func entry(named name: String) -> Entry? {
        indexByName[name].map { entries[$0] }
    }

    /// Extracts an entry by name into memory.
    public func extract(_ name: String) throws -> Data {
        guard let entry = entry(named: name) else { throw ZipError.entryNotFound(name) }
        return try extract(entry)
    }

    /// Extracts an entry into memory.
    public func extract(_ entry: Entry) throws -> Data {
        var out = Data()
        if entry.uncompressedSize > 0, entry.uncompressedSize < 256 * 1024 * 1024 {
            out.reserveCapacity(entry.uncompressedSize)
        }
        try read(entry) { chunk in out.append(chunk.bindMemory(to: UInt8.self)) }
        return out
    }

    /// Extracts an entry by name straight to `url`, replacing any file there.
    public func extract(_ name: String, to url: URL) throws {
        guard let entry = entry(named: name) else { throw ZipError.entryNotFound(name) }
        try extract(entry, to: url)
    }

    /// Streams an entry to `url` with bounded memory.
    public func extract(_ entry: Entry, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try read(entry) { chunk in try handle.write(contentsOf: chunk) }
    }

    /// Decodes an entry, delivering the uncompressed bytes in chunks.
    private func read(_ entry: Entry, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        var reader = DataReader(data)
        try reader.seek(entry.localHeaderOffset)

        // Local file header: signature 0x04034b50, then 22 fixed bytes + name + extra.
        let signature = try reader.readUInt32()
        guard signature == 0x04034b50 else { throw ZipError.corruptEntry(entry.name) }
        try reader.skip(22)
        let nameLength = Int(try reader.readUInt16())
        let extraLength = Int(try reader.readUInt16())
        try reader.skip(nameLength + extraLength)

        let range = try reader.range(ofLength: entry.compressedSize)
        let compressed = data[range]

        switch entry.method {
        case 0:  // stored
            try compressed.withUnsafeBytes { bytes in
                if !bytes.isEmpty { try sink(bytes) }
            }
        case 8:  // deflate
            do {
                try Self.inflate(compressed, sink: sink)
            } catch {
                throw ZipError.corruptEntry(entry.name)
            }
        default:
            throw ZipError.unsupportedMethod(method: entry.method, entry: entry.name)
        }
    }

    // MARK: - Central directory parsing

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        var reader = DataReader(data)
        // Find the End Of Central Directory record (search backwards; the
        // comment can be up to 64 KB).
        guard data.count >= 22 else { throw ZipError.notAZipFile }
        var eocdOffset = -1
        let searchStart = max(0, data.count - 66_000)
        var i = data.count - 22
        while i >= searchStart {
            if data[data.startIndex + i] == 0x50,
               data[data.startIndex + i + 1] == 0x4b,
               data[data.startIndex + i + 2] == 0x05,
               data[data.startIndex + i + 3] == 0x06 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError.notAZipFile }

        try reader.seek(eocdOffset + 4)
        try reader.skip(4)  // disk number, disk with CD
        var entryCount = Int(try reader.readUInt16())
        try reader.skip(2)  // total entries
        try reader.skip(4)  // CD size
        var cdOffset = Int(try reader.readUInt32())

        // ZIP64: the locator sits immediately before the EOCD record.
        if entryCount == 0xFFFF || cdOffset == 0xFFFF_FFFF, eocdOffset >= 20 {
            var locator = DataReader(data)
            try locator.seek(eocdOffset - 20)
            if try locator.readUInt32() == 0x07064b50 {
                try locator.skip(4)  // disk with the zip64 EOCD
                let zip64EOCDOffset = try Int(clamping: locator.readUInt64())
                var zip64 = DataReader(data)
                try zip64.seek(zip64EOCDOffset)
                guard try zip64.readUInt32() == 0x06064b50 else { throw ZipError.notAZipFile }
                try zip64.skip(8)   // size of record
                try zip64.skip(4)   // version made by / needed
                try zip64.skip(8)   // disk numbers
                entryCount = try Int(clamping: zip64.readUInt64())
                try zip64.skip(8)   // total entries
                try zip64.skip(8)   // CD size
                cdOffset = try Int(clamping: zip64.readUInt64())
            }
        }

        try reader.seek(cdOffset)
        var entries: [Entry] = []
        entries.reserveCapacity(min(entryCount, 1_000_000))
        for _ in 0..<entryCount {
            guard reader.remaining >= 46 else { break }
            let signature = try reader.readUInt32()
            guard signature == 0x02014b50 else { break }
            try reader.skip(6)  // version made by, version needed, flags
            let method = try reader.readUInt16()
            try reader.skip(8)  // time, date, crc
            var compressedSize = Int(try reader.readUInt32())
            var uncompressedSize = Int(try reader.readUInt32())
            let nameLength = Int(try reader.readUInt16())
            let extraLength = Int(try reader.readUInt16())
            let commentLength = Int(try reader.readUInt16())
            try reader.skip(8)  // disk start, internal attrs, external attrs
            var localOffset = Int(try reader.readUInt32())
            let nameData = try reader.readData(nameLength)
            let extra = try reader.readData(extraLength)
            try reader.skip(commentLength)

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                var extraReader = DataReader(extra)
                while extraReader.remaining >= 4 {
                    let headerID = try extraReader.readUInt16()
                    let size = Int(try extraReader.readUInt16())
                    if headerID == 0x0001 {
                        var field = DataReader(try extraReader.readData(size))
                        if uncompressedSize == 0xFFFF_FFFF, field.remaining >= 8 {
                            uncompressedSize = try Int(clamping: field.readUInt64())
                        }
                        if compressedSize == 0xFFFF_FFFF, field.remaining >= 8 {
                            compressedSize = try Int(clamping: field.readUInt64())
                        }
                        if localOffset == 0xFFFF_FFFF, field.remaining >= 8 {
                            localOffset = try Int(clamping: field.readUInt64())
                        }
                        break
                    }
                    try extraReader.skip(size)
                }
            }

            let name = String(decoding: nameData, as: UTF8.self)
            entries.append(
                Entry(
                    name: name, method: method, compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize, localHeaderOffset: localOffset
                )
            )
        }
        return entries
    }

    // MARK: - Deflate

    /// Streaming raw-DEFLATE decode (COMPRESSION_ZLIB is raw DEFLATE, which
    /// is exactly what ZIP stores). Output arrives in 256 KB chunks.
    static func inflate(_ compressed: Data, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard !compressed.isEmpty else { return }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw ZipError.corruptEntry("deflate")
        }
        defer { compression_stream_destroy(stream) }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        try compressed.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.baseAddress else { return }
            stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
            stream.pointee.src_size = source.count
            var status: compression_status
            repeat {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw ZipError.corruptEntry("deflate")
                }
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 {
                    try sink(UnsafeRawBufferPointer(start: buffer, count: produced))
                }
            } while status == COMPRESSION_STATUS_OK
        }
    }

    /// Convenience used by tests and small callers.
    static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        var out = Data()
        if expectedSize > 0, expectedSize < 256 * 1024 * 1024 { out.reserveCapacity(expectedSize) }
        do {
            try inflate(data) { out.append($0.bindMemory(to: UInt8.self)) }
        } catch {
            return nil
        }
        return out
    }
}

// MARK: - Data reader

/// Bounds-checked cursor over a `Data`; every read validates before touching
/// bytes so a truncated or hostile archive produces an error, not a trap.
struct DataReader {
    let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { max(0, data.count - offset) }

    mutating func seek(_ position: Int) throws {
        guard position >= 0, position <= data.count else { throw ZipReader.ZipError.notAZipFile }
        offset = position
    }

    mutating func skip(_ length: Int) throws {
        guard length >= 0, length <= remaining else { throw ZipReader.ZipError.notAZipFile }
        offset += length
    }

    /// The absolute range of the next `length` bytes, advancing past them.
    mutating func range(ofLength length: Int) throws -> Range<Data.Index> {
        guard length >= 0, length <= remaining else { throw ZipReader.ZipError.notAZipFile }
        let start = data.startIndex + offset
        offset += length
        return start..<(start + length)
    }

    mutating func readData(_ length: Int) throws -> Data {
        data.subdata(in: try range(ofLength: length))
    }

    mutating func readUInt16() throws -> UInt16 {
        let r = try range(ofLength: 2)
        return UInt16(data[r.lowerBound]) | (UInt16(data[r.lowerBound + 1]) << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let r = try range(ofLength: 4)
        return UInt32(data[r.lowerBound])
            | (UInt32(data[r.lowerBound + 1]) << 8)
            | (UInt32(data[r.lowerBound + 2]) << 16)
            | (UInt32(data[r.lowerBound + 3]) << 24)
    }

    mutating func readUInt64() throws -> UInt64 {
        let low = UInt64(try readUInt32())
        let high = UInt64(try readUInt32())
        return low | (high << 32)
    }
}

// MARK: - Minimal ZIP writer (stored entries) for local backups

public struct ZipWriter {
    private struct StoredEntry {
        let name: String
        let data: Data
        let crc32: UInt32
    }

    private var entries: [StoredEntry] = []
    private let crcTable: [UInt32]

    public init() {
        // Standard CRC-32 table.
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        self.crcTable = table
    }

    public mutating func add(name: String, data: Data) {
        entries.append(StoredEntry(name: name, data: data, crc32: crc32(data)))
    }

    public mutating func addFile(at url: URL, name: String? = nil) throws {
        let data = try Data(contentsOf: url)
        add(name: name ?? url.lastPathComponent, data: data)
    }

    public func finalize() -> Data {
        var out = Data()
        var central = Data()

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let offset = out.count

            // Local file header.
            out.appendLE(UInt32(0x04034b50))
            out.appendLE(UInt16(20))       // version needed
            out.appendLE(UInt16(0))        // flags
            out.appendLE(UInt16(0))        // method: stored
            out.appendLE(UInt16(0))        // time
            out.appendLE(UInt16(0))        // date
            out.appendLE(entry.crc32)
            out.appendLE(UInt32(entry.data.count))
            out.appendLE(UInt32(entry.data.count))
            out.appendLE(UInt16(nameBytes.count))
            out.appendLE(UInt16(0))        // extra length
            out.append(contentsOf: nameBytes)
            out.append(entry.data)

            // Central directory record.
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20))   // version made by
            central.appendLE(UInt16(20))   // version needed
            central.appendLE(UInt16(0))    // flags
            central.appendLE(UInt16(0))    // method
            central.appendLE(UInt16(0))    // time
            central.appendLE(UInt16(0))    // date
            central.appendLE(entry.crc32)
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))    // extra
            central.appendLE(UInt16(0))    // comment
            central.appendLE(UInt16(0))    // disk
            central.appendLE(UInt16(0))    // internal attrs
            central.appendLE(UInt32(0))    // external attrs
            central.appendLE(UInt32(offset))
            central.append(contentsOf: nameBytes)
        }

        let cdOffset = out.count
        out.append(central)

        // End of central directory.
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count))
        out.appendLE(UInt32(cdOffset))
        out.appendLE(UInt16(0))
        return out
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

extension Data {
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
}
