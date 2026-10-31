// One-bit codec adapted from Meta's meta-sam parser at
// 9348a8a791d3e5b6417232227e32e10464cdf49f (mask-codec.ts).
// Copyright (c) Meta Platforms, Inc. and affiliates. All Rights Reserved.
// Codec adaptations are distributed under Resources/ThirdParty/SAM-LICENSE.txt.
// See LICENSING.md for Converse's additional permission to combine this codec.
import Foundation

enum SAMMask {
    static let alphabet = Array((33...126).compactMap { n -> UInt8? in
        [34, 92, 44, 59, 60, 62, 124].contains(n) ? nil : UInt8(n)
    })
    static func invalid() -> ImageAssistError { .invalid("SAM returned an invalid or unsupported mask. No rectangular substitute was used.") }
    static func pack(_ bytes: [UInt8]) -> String {
        var n = bytes.count, prefix = [UInt8](repeating: 33, count: 5)
        for i in (0..<5).reversed() { prefix[i] = alphabet[n % 85]; n /= 85 }
        var output = prefix
        for start in stride(from: 0, to: bytes.count, by: 4) {
            let count = min(4, bytes.count - start)
            var value: UInt64 = 0
            for i in 0..<4 { value = value * 256 + (i < count ? UInt64(bytes[start + i]) : 0) }
            var digits = [UInt8](repeating: 0, count: 5)
            for i in (0..<5).reversed() { digits[i] = alphabet[Int(value % 85)]; value /= 85 }
            output += digits.prefix(count == 4 ? 5 : count + 1)
        }
        return String(decoding: output, as: UTF8.self)
    }
    static func unpack(_ payload: String) throws -> [UInt8] {
        let chars = Array(payload.utf8)
        guard chars.count >= 5, chars.count <= 2_000_000 else { throw invalid() }
        func digit(_ c: UInt8) throws -> UInt64 {
            guard let index = alphabet.firstIndex(of: c), index < 85 else { throw invalid() }; return UInt64(index)
        }
        var length = 0
        for c in chars.prefix(5) { length = length * 85 + Int(try digit(c)) }
        let remainder = length % 4
        guard length <= 1_600_000, chars.count == 5 + length / 4 * 5 + (remainder == 0 ? 0 : remainder + 1) else { throw invalid() }
        var output: [UInt8] = [], source = 5
        for start in stride(from: 0, to: length, by: 4) {
            let count = min(4, length - start), used = count == 4 ? 5 : count + 1
            var value: UInt64 = 0
            for i in 0..<5 { value = value * 85 + (i < used ? try digit(chars[source + i]) : 84) }
            guard value <= UInt32.max else { throw invalid() }
            for i in 0..<count { output.append(UInt8((value >> (24 - i * 8)) & 255)) }; source += used
        }
        guard pack(output) == payload else { throw invalid() }; return output
    }
    struct RangeCoder {
        var low: UInt32 = 0, range: UInt32 = .max, code: UInt32 = 0
        var input: [UInt8] = [], position = 0, output: [UInt8] = []
        mutating func read() throws -> UInt32 {
            guard position < input.count else { throw SAMMask.invalid() }
            defer { position += 1 }; return UInt32(input[position])
        }
        mutating func start(_ bytes: [UInt8]) throws {
            input = bytes
            for _ in 0..<4 { code = (code << 8) | (try read()) }
        }
        mutating func step(_ cumulative: UInt32, _ frequency: UInt32, _ total: UInt32, decoding: Bool) throws {
            let scaled = range / total
            guard scaled > 0 else { throw SAMMask.invalid() }
            low = low &+ scaled &* cumulative; range = scaled &* frequency
            while true {
                if (low ^ (low &+ range)) >= (1 << 24) {
                    if range >= (1 << 16) { break }
                    range = (0 &- low) & 65535
                }
                if decoding { code = (code << 8) | (try read()) } else { output.append(UInt8(low >> 24)) }
                low <<= 8; range <<= 8
            }
        }
        mutating func finish() -> [UInt8] {
            for _ in 0..<4 { output.append(UInt8(low >> 24)); low <<= 8 }; return output
        }
    }
    static func context(_ raster: [UInt8], _ p: Int, _ w: Int) -> Int {
        let offsets = [-1, -2, -w-2, -w-1, -w, -w+1, -w+2, -2*w-2, -2*w-1, -2*w, -2*w+1, -2*w+2]
        var result = 0
        for (bit, offset) in offsets.enumerated() { result |= Int(raster[p + offset]) << bit }; return result
    }
    static func raster(_ payload: String?, input: [UInt8]?, width: Int, height: Int) throws -> ([UInt8], String) {
        guard width > 0, height > 0, width <= 2048, height <= 2048 else { throw invalid() }
        var decoder = RangeCoder(), encoder = RangeCoder()
        if let payload {
            guard payload.first == "!" else { throw invalid() }
            try decoder.start(unpack(String(payload.dropFirst())))
        }
        if let input, input.count != width * height { throw invalid() }
        var counts = [UInt32](repeating: 1, count: 8192), padded = [UInt8](repeating: 0, count: (width + 4) * (height + 2))
        var result = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let p = (y + 2) * (width + 4) + x + 2, c = context(padded, p, width + 4) * 2
            let zero = counts[c], one = counts[c + 1], total = zero + one
            let bit: UInt8
            if let input { bit = input[y * width + x]; guard bit <= 1 else { throw invalid() } }
            else {
                let scale = decoder.range / total; guard scale > 0 else { throw invalid() }
                let target = min(total - 1, (decoder.code &- decoder.low) / scale)
                bit = target < zero ? 0 : 1
                try decoder.step(bit == 0 ? 0 : zero, bit == 0 ? zero : one, total, decoding: true)
            }
            try encoder.step(bit == 0 ? 0 : zero, bit == 0 ? zero : one, total, decoding: false)
            padded[p] = bit; result[y * width + x] = bit; counts[c + Int(bit)] += 14
            if counts[c] + counts[c + 1] >= 4096 { counts[c] = max(1, counts[c] >> 1); counts[c + 1] = max(1, counts[c + 1] >> 1) }
        } }
        let encoded = "!" + pack(encoder.finish())
        if let payload, payload != encoded { throw invalid() }
        return (result, encoded)
    }
    static func decode(_ payload: String, width: Int, height: Int) throws -> [UInt8] { try raster(payload, input: nil, width: width, height: height).0 }
    static func encode(_ bytes: [UInt8], width: Int, height: Int) throws -> String { try raster(nil, input: bytes, width: width, height: height).1 }
}
