import Foundation

/// Zstandard frames, used by Anki's `collection.anki21b`.
///
/// The decoder is Meta's zstd 1.5.7 single-file decompressor (BSD).
enum Zstd {
    struct Error: LocalizedError {
        var errorDescription: String? { "The collection is zstd-compressed and could not be decoded." }
    }

    /// Little-endian frame magic `0xFD2FB528`.
    static func isFrame(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0x28
            && data[data.startIndex + 1] == 0xB5
            && data[data.startIndex + 2] == 0x2F
            && data[data.startIndex + 3] == 0xFD
    }

    static func decompress(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw Error() }
            var out: UnsafeMutableRawPointer?
            var size = 0
            let rc = AnkiZstdDecompress(base, data.count, &out, &size)
            guard rc == 0, let out else { throw Error() }
            defer { AnkiZstdFree(out) }
            return Data(bytes: out, count: size)
        }
    }

    /// If `url` is a zstd frame, replace it with the decoded bytes.
    static func expandInPlace(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let magic = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        guard isFrame(magic) else { return }
        let compressed = try Data(contentsOf: url)
        let plain = try decompress(compressed)
        try plain.write(to: url, options: .atomic)
    }
}
