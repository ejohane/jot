import Foundation
import Security

enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func make(timestamp: Date = Date(), randomBytes suppliedBytes: [UInt8]? = nil) -> String {
        let milliseconds = UInt64(max(0, timestamp.timeIntervalSince1970 * 1_000))
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8((milliseconds >> 40) & 0xff)
        bytes[1] = UInt8((milliseconds >> 32) & 0xff)
        bytes[2] = UInt8((milliseconds >> 24) & 0xff)
        bytes[3] = UInt8((milliseconds >> 16) & 0xff)
        bytes[4] = UInt8((milliseconds >> 8) & 0xff)
        bytes[5] = UInt8(milliseconds & 0xff)

        if let suppliedBytes {
            precondition(suppliedBytes.count == 10)
            bytes.replaceSubrange(6..<16, with: suppliedBytes)
        } else {
            let status = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, 10, buffer.baseAddress!.advanced(by: 6))
            }
            if status != errSecSuccess {
                for index in 6..<16 { bytes[index] = UInt8.random(in: .min ... .max) }
            }
        }

        return encode(bytes)
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        var result = [Character]()
        result.reserveCapacity(26)
        var buffer: UInt32 = 0
        var bits = 2 // ULID is 128 bits represented in 130 bits; prepend two zero bits.

        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1f)])
                buffer &= bits == 0 ? 0 : (1 << UInt32(bits)) - 1
            }
        }

        if bits > 0 {
            result.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1f)])
        }
        return String(result.prefix(26))
    }
}
