import Foundation

/// DLAC (Data Link Application Coding) 6-bit text, used by FIS-B text
/// products. Four characters pack into three bytes.
public enum DLAC {
    /// The 64-character DLAC alphabet. Index 0 is ETX, 28 is the tab marker
    /// (followed by a space count, handled in `decode`), 29 the record
    /// separator.
    static let alphabet: [Character] = Array(
        "\u{03}ABCDEFGHIJKLMNOPQRSTUVWXYZ\u{1A}\t\u{1E}\n| !\"#$%&'()*+,-./0123456789:;<=>?"
    )

    public static let recordSeparator: Character = "\u{1E}"
    public static let etx: Character = "\u{03}"

    private static let codes: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (index, char) in alphabet.enumerated() { map[char] = UInt8(index) }
        return map
    }()

    /// Unpacks 6-bit characters. A code of 28 marks a tab run: the next
    /// code is a count of spaces rather than a character.
    public static func decode(_ bytes: [UInt8]) -> String {
        var result = ""
        var step = 0
        var index = 0
        var pendingTab = false
        while index < bytes.count {
            let code: UInt8
            switch step {
            case 0:
                code = bytes[index] >> 2
            case 1:
                let high = (bytes[index] & 0x03) << 4
                guard index + 1 < bytes.count else { return result }
                code = high | bytes[index + 1] >> 4
                index += 1
            case 2:
                let high = (bytes[index] & 0x0F) << 2
                guard index + 1 < bytes.count else { return result }
                code = high | bytes[index + 1] >> 6
                index += 1
            default:
                code = bytes[index] & 0x3F
                index += 1
            }
            if pendingTab {
                result.append(String(repeating: " ", count: Int(code)))
                pendingTab = false
            } else if code == 28 {
                pendingTab = true
            } else if code != 0 {
                // Code 0 is ETX — a terminator/padding byte, never content.
                result.append(alphabet[Int(code)])
            }
            step = (step + 1) % 4
        }
        return result
    }

    /// Packs text into 6-bit codes (no tab-run compression). Characters
    /// outside the alphabet are uppercased first, then dropped to a space.
    /// The final group is zero-padded, which decodes as trailing ETX.
    public static func encode(_ text: String) -> [UInt8] {
        var sixBit: [UInt8] = text.map { char in
            codes[char] ?? codes[Character(char.uppercased())] ?? 32
        }
        while sixBit.count % 4 != 0 { sixBit.append(0) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(sixBit.count / 4 * 3)
        for group in stride(from: 0, to: sixBit.count, by: 4) {
            let (c0, c1, c2, c3) = (sixBit[group], sixBit[group + 1], sixBit[group + 2], sixBit[group + 3])
            bytes.append(c0 << 2 | c1 >> 4)
            bytes.append((c1 & 0x0F) << 4 | c2 >> 2)
            bytes.append((c2 & 0x03) << 6 | c3)
        }
        return bytes
    }
}
