import Darwin
import Foundation

/// A literal "contains" query. Whitespace separates tokens that must all appear somewhere in the name, in any
/// order; text in double quotes is one token, spaces included. Matching is case- and accent-insensitive and
/// nothing else: no word-prefix rules, no metadata, no content, so every hit visibly contains what you typed.
public struct SearchQuery: Sendable {
    public let raw: String
    /// Folded tokens, longest first (the longest one is the most selective to scan for).
    public let tokens: [[UInt8]]
    /// The whole query folded, for the bonus when it appears as one contiguous run.
    public let phrase: [UInt8]
    /// Original-case tokens, used by the UI to highlight matches.
    public let displayTokens: [String]

    public init(_ raw: String) {
        self.raw = raw
        var parts: [String] = []
        var current = ""
        var quoted = false
        for ch in raw {
            if ch == "\"" { quoted.toggle(); if !quoted && !current.isEmpty { parts.append(current); current = "" }; continue }
            if ch.isWhitespace && !quoted {
                if !current.isEmpty { parts.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        var seen = Set<[UInt8]>()
        var folded: [[UInt8]] = []
        var display: [String] = []
        for part in parts {
            let f = TextFold.fold(part)
            if !f.isEmpty, seen.insert(f).inserted { folded.append(f); display.append(part) }
        }
        // Drop tokens contained in a longer token ("re" inside "report" adds nothing).
        let kept = folded.enumerated().filter { i, t in
            !folded.enumerated().contains { j, other in j != i && other.count > t.count && Self.contains(other, t) }
        }
        tokens = kept.map(\.element).sorted { $0.count > $1.count }
        displayTokens = kept.map { display[$0.offset] }
        phrase = TextFold.fold(parts.joined(separator: " "))
    }

    public var isEmpty: Bool { tokens.isEmpty }
    var scanToken: [UInt8]? { tokens.first }

    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        hay.withUnsafeBufferPointer { h in needle.withUnsafeBufferPointer { n in find(h, n) != nil } }
    }

    @inline(__always) static func find(_ hay: UnsafeBufferPointer<UInt8>, _ needle: UnsafeBufferPointer<UInt8>) -> Int? {
        guard needle.count <= hay.count, let hb = hay.baseAddress, let nb = needle.baseAddress else { return needle.isEmpty ? 0 : nil }
        guard let m = memmem(hb, hay.count, nb, needle.count) else { return nil }
        return UnsafeRawPointer(m).assumingMemoryBound(to: UInt8.self) - hb
    }

    public func containsAll(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        for t in tokens.dropFirst() {
            let found = t.withUnsafeBufferPointer { Self.find(name, $0) != nil }
            if !found { return false }
        }
        return true
    }

    public func matches(_ name: String) -> Bool {
        let f = TextFold.fold(name)
        return f.withUnsafeBufferPointer { buf in
            tokens.allSatisfy { t in t.withUnsafeBufferPointer { Self.find(buf, $0) != nil } }
        }
    }

    /// Higher is better. Exact and whole-word matches beat matches buried mid-word; short, shallow and recently
    /// modified names win ties.
    public func score(_ name: UnsafeBufferPointer<UInt8>, depth: Int, isDirectory: Bool, ageDays: Double) -> Int32 {
        var score = 0
        let stemEnd: Int = {
            var i = name.count - 1
            while i > 0 { if name[i] == UInt8(ascii: ".") { return i }; i -= 1 }
            return name.count
        }()
        let phraseHit = phrase.withUnsafeBufferPointer { Self.find(name, $0) }
        if let pos = phraseHit {
            if phrase.count == name.count { score = 1000 }
            else if pos == 0 && phrase.count == stemEnd { score = 950 }
            else if pos == 0 { score = 720 }
            else if TextFold.isWordBoundary(name[pos - 1]) { score = 560 }
            else { score = 380 }
        } else {
            score = 220
            for t in tokens {
                if let pos = t.withUnsafeBufferPointer({ Self.find(name, $0) }), pos == 0 || TextFold.isWordBoundary(name[pos - 1]) {
                    score += 40
                }
            }
        }
        score -= min(220, max(0, name.count - phrase.count) * 3)
        score -= min(160, depth * 9)
        if ageDays < 2 { score += 90 } else if ageDays < 8 { score += 60 } else if ageDays < 31 { score += 30 } else if ageDays < 366 { score += 8 }
        if isDirectory { score += 12 }
        return Int32(score)
    }

    /// Ranges of `name` matching any token, for highlighting (case- and diacritic-insensitive like the search).
    public func highlightRanges(in name: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let terms = phrase.isEmpty ? displayTokens : [String(decoding: phrase, as: UTF8.self)] + displayTokens
        for term in terms where !term.isEmpty {
            var from = name.startIndex
            while from < name.endIndex,
                  let r = name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: from..<name.endIndex) {
                if !ranges.contains(where: { $0.overlaps(r) }) { ranges.append(r) }
                from = r.upperBound
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }
}
