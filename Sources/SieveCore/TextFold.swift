import Foundation

/// Case-, diacritic- and width-insensitive folding to UTF-8 bytes. Search and name sorting both compare folded
/// bytes, so "Résumé.PDF" matches "resume.pdf" and sorts next to it. ASCII names take a byte-level fast path.
public enum TextFold {
    public static func fold(_ string: String) -> [UInt8] {
        var out: [UInt8] = []
        let utf8 = Array(string.utf8)
        utf8.withUnsafeBytes { append($0, to: &out) }
        return out
    }

    /// Appends the folded form of the UTF-8 `bytes` to `out`.
    public static func append(_ bytes: UnsafeRawBufferPointer, to out: inout [UInt8]) {
        var ascii = true
        for b in bytes where b >= 0x80 { ascii = false; break }
        if ascii {
            out.reserveCapacity(out.count + bytes.count)
            for b in bytes { out.append(b >= 65 && b <= 90 ? b | 0x20 : b) }
            return
        }
        let string = String(decoding: bytes, as: UTF8.self)
        let folded = string
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
        out.append(contentsOf: folded.utf8)
    }

    /// Finder-style natural order on folded bytes: digit runs compare by value, so "file2" < "file10".
    public static func naturalCompare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in naturalCompare(pa, pb) } }
    }

    public static func naturalCompare(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
        var i = 0, j = 0
        while i < a.count && j < b.count {
            let ca = a[i], cb = b[j]
            if isDigit(ca) && isDigit(cb) {
                // Skip leading zeros, then the longer run is larger; equal lengths compare digit by digit.
                var si = i, sj = j
                while si < a.count && a[si] == 48 { si += 1 }
                while sj < b.count && b[sj] == 48 { sj += 1 }
                var ei = si, ej = sj
                while ei < a.count && isDigit(a[ei]) { ei += 1 }
                while ej < b.count && isDigit(b[ej]) { ej += 1 }
                let la = ei - si, lb = ej - sj
                if la != lb { return la < lb ? -1 : 1 }
                var k = 0
                while k < la {
                    if a[si + k] != b[sj + k] { return a[si + k] < b[sj + k] ? -1 : 1 }
                    k += 1
                }
                // Same value: fewer leading zeros first.
                if (ei - i) != (ej - j) { return (ei - i) < (ej - j) ? -1 : 1 }
                i = ei; j = ej
                continue
            }
            if ca != cb { return ca < cb ? -1 : 1 }
            i += 1; j += 1
        }
        if a.count - i == b.count - j { return 0 }
        return a.count - i < b.count - j ? -1 : 1
    }

    @inline(__always) static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    /// True when `byte` separates words in a filename (space, punctuation, path-like separators).
    @inline(__always) static func isWordBoundary(_ byte: UInt8) -> Bool {
        switch byte {
        case 32, 45, 95, 46, 40, 41, 91, 93, 44, 43, 38, 35, 64, 39, 34, 123, 125, 33, 126: return true
        default: return false
        }
    }
}
