import Foundation

/// Minimal protobuf wire-format decoder.
///
/// AnkiWeb's shared-deck service speaks protobuf. The messages we need are
/// tiny and stable, so a hand-rolled reader avoids pulling SwiftProtobuf
/// into the app just to read a handful of fields.
struct ProtobufMessage: Sendable {
    enum Value: Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    struct Field: Sendable {
        let number: Int
        let value: Value
    }

    let fields: [Field]

    enum DecodeError: Error, Equatable {
        case truncated
        case unsupportedWireType(Int)
    }

    init(data: Data) throws {
        var fields: [Field] = []
        let bytes = [UInt8](data)
        var index = 0

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.count else { throw DecodeError.truncated }
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                guard shift < 64 else { throw DecodeError.truncated }
            }
        }

        while index < bytes.count {
            let key = try readVarint()
            let number = Int(key >> 3)
            let wireType = Int(key & 0x7)
            switch wireType {
            case 0:
                fields.append(Field(number: number, value: .varint(try readVarint())))
            case 1:
                guard index + 8 <= bytes.count else { throw DecodeError.truncated }
                var value: UInt64 = 0
                for offset in 0..<8 { value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset)) }
                index += 8
                fields.append(Field(number: number, value: .fixed64(value)))
            case 2:
                // Lengths are bounded by what's left in the buffer, so a
                // hostile or garbled value can't overflow the index math.
                let rawLength = try readVarint()
                guard let length = Int(exactly: rawLength), length <= bytes.count - index else {
                    throw DecodeError.truncated
                }
                fields.append(Field(number: number, value: .bytes(Data(bytes[index..<(index + length)]))))
                index += length
            case 5:
                guard index + 4 <= bytes.count else { throw DecodeError.truncated }
                var value: UInt32 = 0
                for offset in 0..<4 { value |= UInt32(bytes[index + offset]) << (8 * UInt32(offset)) }
                index += 4
                fields.append(Field(number: number, value: .fixed32(value)))
            default:
                throw DecodeError.unsupportedWireType(wireType)
            }
        }
        self.fields = fields
    }

    // MARK: - Typed accessors

    func varint(_ number: Int) -> UInt64? {
        for field in fields.reversed() where field.number == number {
            if case .varint(let v) = field.value { return v }
        }
        return nil
    }

    func int(_ number: Int) -> Int? {
        varint(number).map { Int(truncatingIfNeeded: $0) }
    }

    func bytes(_ number: Int) -> Data? {
        for field in fields.reversed() where field.number == number {
            if case .bytes(let d) = field.value { return d }
        }
        return nil
    }

    func string(_ number: Int) -> String? {
        bytes(number).flatMap { String(data: $0, encoding: .utf8) }
    }

    func message(_ number: Int) -> ProtobufMessage? {
        bytes(number).flatMap { try? ProtobufMessage(data: $0) }
    }

    func messages(_ number: Int) -> [ProtobufMessage] {
        fields.compactMap { field in
            guard field.number == number, case .bytes(let d) = field.value else { return nil }
            return try? ProtobufMessage(data: d)
        }
    }

    /// True when the field is present at all (needed for `oneof` bools).
    func has(_ number: Int) -> Bool {
        fields.contains { $0.number == number }
    }
}

/// Minimal protobuf encoder for the one or two request messages we send.
enum ProtobufWriter {
    static func appendVarint(_ value: UInt64, to data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    static func appendVarint(_ value: UInt64, field: Int, to data: inout Data) {
        appendVarint(UInt64(field << 3 | 0), to: &data)
        appendVarint(value, to: &data)
    }

    static func appendBytes(_ bytes: Data, field: Int, to data: inout Data) {
        appendVarint(UInt64(field << 3 | 2), to: &data)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    static func appendString(_ string: String, field: Int, to data: inout Data) {
        appendBytes(Data(string.utf8), field: field, to: &data)
    }

    /// Appends a nested message (identical wire form to bytes).
    static func appendMessage(_ message: Data, field: Int, to data: inout Data) {
        appendBytes(message, field: field, to: &data)
    }
}
