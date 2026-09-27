import Foundation
import Security

/// UUIDv7 generator (RFC 9562): 48-bit unix-ms timestamp, version/variant bits, random tail.
/// Used for event/telemetry idempotency ids and the session/process ids. Time-ordered ids keep
/// server-side dedup indexes friendly.
enum Uuid {
    static func v7(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fall back to the non-cryptographic generator: these are idempotency ids, not keys.
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }

        // 48-bit big-endian timestamp
        bytes[0] = UInt8(truncatingIfNeeded: now >> 40)
        bytes[1] = UInt8(truncatingIfNeeded: now >> 32)
        bytes[2] = UInt8(truncatingIfNeeded: now >> 24)
        bytes[3] = UInt8(truncatingIfNeeded: now >> 16)
        bytes[4] = UInt8(truncatingIfNeeded: now >> 8)
        bytes[5] = UInt8(truncatingIfNeeded: now)

        // version 7 (high nibble of byte 6), RFC 4122 variant (high bits 10 of byte 8)
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        var result = ""
        result.reserveCapacity(36)
        for (index, byte) in bytes.enumerated() {
            if index == 4 || index == 6 || index == 8 || index == 10 { result.append("-") }
            result.append(hex[Int(byte >> 4)])
            result.append(hex[Int(byte & 0x0F)])
        }
        return result
    }

    private static let hex = Array("0123456789abcdef")
}
