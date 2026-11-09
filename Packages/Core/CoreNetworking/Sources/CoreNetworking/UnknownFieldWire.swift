import Foundation
import SwiftProtobuf

/// One string carried as a length-delimited field the contracts don't
/// declare — the stopgap a client-proposed field rides until the backend
/// writes it: a voice post's voice (`PostVoiceWire`, #2206), a showcase's
/// embed (`PostEmbedWire`, #2216). Shared, so each proposal is its reference
/// format alone.
///
/// A client or server that doesn't know the field keeps it as an unknown
/// field and reads the message as it always did.
enum UnknownFieldWire {
    /// The string field `number` carries in `message`, if any — the LAST
    /// one, as a proto decoder keeps the last of a non-repeated field.
    static func string(field number: Int, in message: some SwiftProtobuf.Message) -> String? {
        string(field: number, in: message.unknownFields.data)
    }

    /// Adds `value` to `message` as field `number`.
    static func write<Message: SwiftProtobuf.Message>(_ value: String, field number: Int, to message: inout Message) {
        let payload = Data(value.utf8)
        var bytes = Data()
        appendVarint(UInt64(number << 3 | 2), to: &bytes)
        appendVarint(UInt64(payload.count), to: &bytes)
        bytes.append(payload)
        // Appended on the wire and read back: a decoder keeps a field it
        // doesn't know as an unknown field (`UnknownStorage.append` is not
        // public).
        guard let serialized = try? message.serializedData(),
              let decoded = try? Message(serializedBytes: serialized + bytes) else { return }
        message = decoded
    }

    /// The last length-delimited `field` in `data`, as UTF-8.
    static func string(field: Int, in data: Data) -> String? {
        var index = data.startIndex
        var found: String?
        while index < data.endIndex {
            guard let key = readVarint(data, &index) else { return found }
            let number = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0: guard readVarint(data, &index) != nil else { return found }
            case 1: index = data.index(index, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
            case 5: index = data.index(index, offsetBy: 4, limitedBy: data.endIndex) ?? data.endIndex
            case 2:
                guard let length = readVarint(data, &index),
                      let end = data.index(index, offsetBy: Int(length), limitedBy: data.endIndex) else { return found }
                if number == field { found = String(data: data[index..<end], encoding: .utf8) }
                index = end
            default: return found
            }
        }
        return found
    }

    private static func readVarint(_ data: Data, _ index: inout Data.Index) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index = data.index(after: index)
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
    }
}
