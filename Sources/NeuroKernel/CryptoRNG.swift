import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("No SHA256 implementation available. Install CryptoKit (Apple) or swift-crypto.")
#endif

#if os(Linux)
import Glibc
#else
import Security
#endif

protocol NKRandom {
    mutating func fill(_ buffer: UnsafeMutableRawBufferPointer) throws
}

struct SecureRNG: NKRandom {
    mutating func fill(_ buffer: UnsafeMutableRawBufferPointer) throws {
        #if os(Linux)
        let fd = open("/dev/urandom", O_RDONLY)
        guard fd >= 0 else {
            throw NKError.runtime("open(/dev/urandom) failed")
        }
        defer { _ = close(fd) }

        var offset = 0
        while offset < buffer.count {
            let n = read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            guard n > 0 else {
                throw NKError.runtime("read(/dev/urandom) failed")
            }
            offset += n
        }
        #else
        let rc = SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        guard rc == errSecSuccess else {
            throw NKError.runtime("SecRandomCopyBytes failed: \(rc)")
        }
        #endif
    }
}

// Deterministic crypto PRNG: SHA256(seed || counterLE) blocks.
// Good for reproducible experiments; NOT meant to replace OS entropy.
struct DeterministicRNG: NKRandom, Codable {
    var seed: Data
    private var counter: UInt64 = 0

    init(seed: Data) {
        self.seed = seed
        self.counter = 0
    }

    mutating func fill(_ buffer: UnsafeMutableRawBufferPointer) throws {
        var offset = 0
        while offset < buffer.count {
            var ctrLE = counter.littleEndian
            var msg = Data()
            msg.append(seed)
            withUnsafeBytes(of: &ctrLE) { msg.append(contentsOf: $0) }

            let digest = SHA256.hash(data: msg)
            let block = Data(digest)
            let n = min(block.count, buffer.count - offset)
            _ = block.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<(offset + n)]))
            offset += n
            counter &+= 1
        }
    }
}

enum RNGUtil {
    static func hexToData(_ hex: String) throws -> Data {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count % 2 == 0 else { throw NKError.parse("hex must have even length") }
        var out = Data(capacity: s.count/2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            let byteStr = String(s[i..<j])
            guard let b = UInt8(byteStr, radix: 16) else { throw NKError.parse("bad hex byte: \(byteStr)") }
            out.append(b)
            i = j
        }
        return out
    }
}
